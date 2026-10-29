import Foundation

// NAV-NOOBD replay-side measures: the naive "last fix" baselines, the fix
// accounting and the per-run error aggregates. Report only: the engine
// never sees any of them, and none changes a number it produces.

// MARK: - Percentiles

/// Nearest-rank percentiles, the one definition every NAV-NOOBD aggregate
/// uses: the p-th percentile of n sorted values is the value at 1-based
/// rank ⌈p·n/100⌉ (rank 1 for p = 0). Always an observed value, never an
/// interpolation, so a percentile of checkpoint errors is the error of one
/// checkpoint. The median is p50: for an even n the lower of the two
/// middle values (the summary's older clean-fix median, `errors[n / 2]`,
/// takes the upper one; it is unchanged).
public enum NearestRank {
    /// The `percent`-th percentile (0…100, integer) of `values`; nil when
    /// there are none. Non-finite values are ignored.
    public static func percentile(_ values: [Double], _ percent: Int) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let p = min(100, max(0, percent))
        // ⌈p·n/100⌉ in integers, so 90 % of 10 values is rank 9 exactly.
        let rank = max(1, (p * sorted.count + 99) / 100)
        return sorted[rank - 1]
    }
}

// MARK: - Last-fix baseline

/// The naive baseline (NAV-NOOBD): at each checkpoint, the distance from
/// the truth to the newest location fix known at that moment, as if the
/// app showed only the last fix. Two variants on the same checkpoints:
///
/// - `delivered`: the newest fix the replay handed to the engine (it
///   passed the `--gps` mode and `--hold-out-acc`), whatever the engine
///   then did with it (held, dropped, rejected): what a "last fix" marker on
///   the map would show (UX-1 (d)).
/// - `accepted`: the newest fix the engine actually used
///   (`NavigationCounters.fixesUsed` grew at its ingest, or at the OBD
///   reply that applied it when it was held).
///
/// Latency convention, the engine's own: a fix is known from the moment it
/// is ingested, i.e. at its arrival (`NavigationInput.arrival`,
/// max(`receivedT`, `t`)), never from its `t`; a held fix counts as
/// accepted from the input that applied it. The replay updates the tracker
/// around each `engine.ingest` and measures each checkpoint at the moment
/// it scores it (before the input arriving at or after the checkpoint's
/// time is ingested), so the baseline knows exactly the fixes the engine
/// had been given when its own error was taken. "Newest" is by fix time
/// `t` (a later-arriving older fix, e.g. a cached one, does not replace a
/// newer one); ties go to the later one. A fix with no usable position
/// (`horizontalAccuracy` < 0 or not finite, coordinates not finite or out
/// of range) is never a baseline fix, nor is a fix the replay took off its
/// timeline as an implausible time jump. Distances are on the plane the
/// checkpoint is scored on (the engine's `tangentPlane`, else one at the
/// truth position before initialisation).
public struct LastFixBaseline: Hashable, Sendable, Codable {
    /// A fix the baseline may stand on.
    public struct Fix: Hashable, Sendable {
        /// Fix time, nanoseconds on the session clock.
        public var tNs: Int64
        public var latitude: Double
        public var longitude: Double

        public init(tNs: Int64, latitude: Double, longitude: Double) {
            self.tNs = tNs
            self.latitude = latitude
            self.longitude = longitude
        }

        /// The fix of `sample` at `t`; nil when it has no usable position.
        public init?(_ sample: LocationSample, at t: MonotonicTimestamp) {
            let accuracy = sample.horizontalAccuracy
            guard accuracy >= 0, accuracy.isFinite, sample.latitude.isFinite, sample.longitude.isFinite,
                  abs(sample.latitude) <= 90, abs(sample.longitude) <= 180 else { return nil }
            self.init(tNs: t.nanoseconds, latitude: sample.latitude, longitude: sample.longitude)
        }
    }

    /// The newest delivered and accepted fix so far, as the replay runs.
    public struct Tracker: Hashable, Sendable {
        public private(set) var delivered: Fix?
        public private(set) var accepted: Fix?

        public init() {}

        /// `fix` was handed to the engine.
        public mutating func deliver(_ fix: Fix) { delivered = Self.newer(delivered, fix) }

        /// The engine used `fix`.
        public mutating func accept(_ fix: Fix) { accepted = Self.newer(accepted, fix) }

        static func newer(_ current: Fix?, _ fix: Fix) -> Fix {
            guard let current, current.tNs > fix.tNs else { return fix }
            return current
        }

        /// Distances (m) from the truth at (`latitude`, `longitude`) to the
        /// delivered and the accepted fix on `plane`; nil: none yet.
        public func measure(latitude: Double, longitude: Double, plane: LocalTangentPlane)
            -> (delivered: Double?, accepted: Double?) {
            let truth = plane.enu(latitude: latitude, longitude: longitude)
            func distance(_ fix: Fix?) -> Double? {
                guard let fix else { return nil }
                let p = plane.enu(latitude: fix.latitude, longitude: fix.longitude)
                let dEast = truth.east - p.east, dNorth = truth.north - p.north
                return (dEast * dEast + dNorth * dNorth).squareRoot()
            }
            return (distance(delivered), distance(accepted))
        }
    }

    /// One variant over a run's checkpoints.
    public struct Variant: Hashable, Sendable, Codable {
        /// Per checkpoint, in the order of the run's `checkpoints` (same
        /// index): the distance in metres, nil (JSON null) when no fix was
        /// known yet. Listed for every checkpoint, scored or not.
        public var perCheckpointM: [Double?]
        /// Scored checkpoints (`Checkpoint.isScored`) with a fix known.
        public var count: Int
        /// Scored checkpoints with no fix known yet: counted, not scored.
        public var countNone: Int
        /// Over the `count` values, nearest rank (`NearestRank`); nil
        /// when `count` is 0.
        public var medianM: Double?
        public var p90M: Double?
        public var maxM: Double?

        /// The aggregates of `perCheckpointM` over the checkpoints `scored`
        /// marks (same length).
        public init(perCheckpointM: [Double?], scored: [Bool]) {
            precondition(perCheckpointM.count == scored.count, "one value per checkpoint")
            self.perCheckpointM = perCheckpointM
            let values = zip(perCheckpointM, scored).filter(\.1).map(\.0)
            let known = values.compactMap { $0 }
            count = known.count
            countNone = values.count - known.count
            medianM = NearestRank.percentile(known, 50)
            p90M = NearestRank.percentile(known, 90)
            maxM = known.max()
        }

        /// "median 120 m, p90 480 m, max 900 m over 40 (2 none yet)".
        public var text: String {
            guard count > 0 else { return "no scored checkpoint with a fix (\(countNone) none yet)" }
            return String(format: "median %.0f m, p90 %.0f m, max %.0f m over %d", medianM ?? .nan, p90M ?? .nan,
                          maxM ?? .nan, count) + " (\(countNone) none yet)"
        }
    }

    public var delivered: Variant
    public var accepted: Variant

    /// From per-checkpoint (delivered, accepted) distances and each
    /// checkpoint's `isScored` (same length).
    public init(perCheckpoint: [(delivered: Double?, accepted: Double?)], scored: [Bool]) {
        delivered = Variant(perCheckpointM: perCheckpoint.map(\.delivered), scored: scored)
        accepted = Variant(perCheckpointM: perCheckpoint.map(\.accepted), scored: scored)
    }
}

// MARK: - Fix accounting

/// What happened to the location fixes the replay handed to the engine
/// (NAV-NOOBD), from the engine's public counters; replay side only.
///
/// - `delivered`: location inputs the replay gave the engine, i.e. that
///   passed `--gps` and `--hold-out-acc` (time-jump inputs included).
/// - `accepted` = the engine's `counters.fixesUsed` at the end of the run
///   (the replay's engine starts at 0): fixes that initialised the cloud or
///   updated it as a position measurement, network fixes and held fixes
///   applied at an OBD 0 (`heldFixesUsed`) included. A held fix that is
///   applied is counted once, here, not as held. Pins are not fixes.
/// - `droppedHeldTimeout`, `droppedHeldMoving`, `droppedHeldReplaced`: the
///   engine's `heldFixesDroppedTimeout`, `heldFixesDroppedMoving`,
///   `heldFixesReplaced` (N4B-1: a stale fix held because OBD could not
///   say whether the car was stopped, then dropped).
/// - `ignoredStale`: `fixesIgnoredStale` minus the three held drops above
///   (which it includes): stale fixes rejected on arrival (fresh OBD said
///   moving, or the car moved after the fix, `staleFixesIgnoredMoved`).
/// - `ignoredInvalid`: `fixesIgnoredInvalid`.
/// - `olderThanSave`: older than a restored prior (UX-20): the restore's
///   `fixesOlderThanSave` plus the location inputs among its
///   `inputsOlderThanSave` (ignored before the prior was applied).
/// - `rejectedOffRoad`: `fixesRejectedOffRoad`; nil (absent) in a run
///   without roads, so no road key reaches its outputs.
/// - `withheldByGPSSwitch`: `fixesWithheldByGPSSwitch` (the recording's
///   own switch, UX-9 a; a held fix dropped at a switch-off included); nil
///   (absent) in a run without a switch input, as `gpsSwitch` is.
/// - `rejectedTimeJump`: location inputs among `inputsRejectedTimeJump`.
/// - `stillHeld`: 1 when the input ended with a fix held
///   (`NavigationEngine.hasHeldFix`), else 0.
///
/// Every delivered fix ends in exactly one of these, so `unaccounted`
/// (delivered minus their sum) is 0; a non-zero value means the engine
/// gained a path this list does not know.
public struct FixAccounting: Hashable, Sendable, Codable {
    public var delivered = 0
    public var accepted = 0
    public var droppedHeldTimeout = 0
    public var droppedHeldMoving = 0
    public var droppedHeldReplaced = 0
    public var ignoredStale = 0
    public var ignoredInvalid = 0
    public var olderThanSave = 0
    public var rejectedOffRoad: Int?
    public var withheldByGPSSwitch: Int?
    public var rejectedTimeJump = 0
    public var stillHeld = 0

    public init() {}

    /// Every outcome but `accepted`.
    public var notAccepted: Int {
        droppedHeldTimeout + droppedHeldMoving + droppedHeldReplaced + ignoredStale + ignoredInvalid + olderThanSave
            + (rejectedOffRoad ?? 0) + (withheldByGPSSwitch ?? 0) + rejectedTimeJump + stillHeld
    }

    /// `delivered` minus every outcome; 0 when the books balance.
    public var unaccounted: Int { delivered - accepted - notAccepted }

    /// "delivered 120: accepted 100, held dropped timeout 3 / moving 0 /
    /// replaced 0, stale 2, invalid 0, older than save 0, time jump 0,
    /// still held 0", then ", off-road 15" with roads and ", GPS off 4"
    /// with a GPS switch.
    public var text: String {
        "delivered \(delivered): accepted \(accepted), held dropped timeout \(droppedHeldTimeout) / moving "
            + "\(droppedHeldMoving) / replaced \(droppedHeldReplaced), " + otherText
    }

    /// The outcomes after the held ones: "stale 2, invalid 0, older than
    /// save 0, time jump 0, still held 0[, off-road 15][, GPS off 4]".
    public var otherText: String {
        "stale \(ignoredStale), invalid \(ignoredInvalid), older than save \(olderThanSave), time jump \(rejectedTimeJump), "
            + "still held \(stillHeld)" + (rejectedOffRoad.map { ", off-road \($0)" } ?? "")
            + (withheldByGPSSwitch.map { ", GPS off \($0)" } ?? "")
            + (unaccounted == 0 ? "" : ", UNACCOUNTED \(unaccounted)")
    }
}

// MARK: - Per-run error aggregates

/// The NAV-NOOBD per-run aggregates over the scored checkpoints
/// (`Checkpoint.isScored` with an engine error), nearest rank
/// (`NearestRank`). nil where nothing qualifies.
public struct ReplayErrorAggregates: Hashable, Sendable, Codable {
    public var errorMedianM: Double?
    public var errorP90M: Double?
    /// Over the scored checkpoints with a percentage (distance so far > 0).
    public var errorMedianPercent: Double?
    public var errorP90Percent: Double?
    /// Median 95 % ellipse semi-major axis.
    public var ellipseSemiMajorMedianM: Double?

    public init(_ checkpoints: [ReplayResult.Checkpoint]) {
        let scored = checkpoints.filter { $0.isScored && $0.errorM != nil }
        let errors = scored.compactMap(\.errorM)
        let percents = scored.compactMap(\.errorPercent)
        let axes = scored.compactMap(\.ellipseSemiMajorM)
        errorMedianM = NearestRank.percentile(errors, 50)
        errorP90M = NearestRank.percentile(errors, 90)
        errorMedianPercent = NearestRank.percentile(percents, 50)
        errorP90Percent = NearestRank.percentile(percents, 90)
        ellipseSemiMajorMedianM = NearestRank.percentile(axes, 50)
    }
}
