import Foundation

// MARK: - Restore the estimate (UX-20)
//
// A Navigate run can start from the estimate an earlier run left: after the
// app was killed mid-drive, or when Navigate starts again after parking.
// Three pieces, all pure and deterministic:
//
// 1. `NavigationRestoreState`: what is persisted (Codable, versioned,
//    validated on decode), captured from a running engine
//    (`capture(_:at:clock:bootSessionID:engineOff:)`), with its age
//    (`age(nowWall:nowUptimeSeconds:bootSessionID:)`) and the prior it
//    gives a new run (`prior(at:clock:bootSessionID:)`).
// 2. `NavigationPrior`: the saved belief on the new run's clock. The
//    engine (`NavigationEngine(config:roads:prior:)`) grows it for the gap
//    (`seed(gapS:movingAtStart:)`) and seeds the cloud at its first input.
// 3. `NavigationRestore`: the restore's status on the engine and the live
//    run's snapshot: unconfirmed until a fix or pin agrees with it, and
//    rejected (the engine reinitialises as without a prior) when one
//    disagrees. docs/NAVIGATION.md "Restored prior (UX-20)".

/// How the car was left when the estimate was saved
/// (`NavigationEngine.restoreClass(at:engineOff:)`).
public enum NavigationRestoreClass: String, Hashable, Sendable, Codable, CaseIterable {
    /// The last OBD speed was 0 and the engine was off: stale after the 0
    /// (no reply since, no IMU sign of motion), or the app said so
    /// (`engineOff`: ignition off, Navigate's auto-stop).
    case parked
    /// A fresh OBD 0 held for at least
    /// `NavigationRestoreModel.standingStopMinZeroS`.
    case standingStop
    /// Anything else: moving, or speed unknown (a run from a stopped-class
    /// prior keeps the prior's class until OBD or the IMU says otherwise).
    case moving
}

/// The numbers of the restore model, in one place. Not `NavigationConfig`
/// keys: the config is written into every sidecar header and replay
/// result, and a run without a prior must stay byte-identical.
public enum NavigationRestoreModel {
    /// A saved state older than this is not restored (24 h, the user's
    /// window).
    public static let maxAgeS = 24.0 * 3600
    /// Parked: per-axis position σ added in quadrature, metres. The car was
    /// stopped with the engine off when saved and OBD reads 0 again at the
    /// start; this covers GNSS-free drift of a parked estimate, not a car
    /// moved by someone else (the disagreement test catches that).
    public static let parkedPositionSigmaM = 10.0
    /// Standing stop (engine running, OBD 0 for ≥ 3 s): per-axis σ added,
    /// metres. A guess, no recording measures it: the car may have crept or
    /// moved a little before the relaunch.
    public static let standingStopPositionSigmaM = 50.0
    /// Stopped classes: heading σ added in quadrature, degrees.
    /// Stopped classes never grow more than a moving car would over the
    /// same gap (`seed`): a hand-over within a second (Record stopped at a
    /// light, Navigate resumes) adds about 11 m and 3°·gap, not 50 m.
    public static let stoppedHeadingSigmaDeg = 3.0
    /// Moving: the gap is driven at no less than this, m/s (40 km/h); the
    /// last speed when it was higher. Per-axis σ added = speed × gap.
    public static let movingMinSpeedMps = 11.1
    /// Moving: heading is uniform for a gap longer than this, s.
    public static let movingUniformHeadingAfterS = 5.0
    /// Moving, gap up to `movingUniformHeadingAfterS`: heading σ added per
    /// second of gap, degrees, in quadrature. Measured: the RMS of the gyro
    /// heading change over windows of 0.5, 1, 2, 3 and 5 s while moving
    /// (OBD ≥ 10 km/h at both ends) on seven acceptance drives (≈ 13 000
    /// windows each) is 5.4, 5.3, 5.1, 4.9 and 4.5 °/s × the window; 5.5
    /// covers every one. The distribution is heavy-tailed (1 s: median
    /// 0.5°, p95 13°, p99 22°): a turn during the gap can fall outside, and
    /// the next clean fix's no-support reseed is what catches it.
    public static let movingHeadingRateDegPerS = 5.5
    /// Moving, gap up to this: the mean is carried forward along the saved
    /// heading by the last speed × gap (dead reckoning over the gap, as
    /// `estimate(at:)` extrapolates), s. Longer gaps (uniform heading):
    /// the mean is not shifted.
    public static let movingShiftMaxGapS = 5.0
    /// A grown heading σ above this seeds headings stratified uniformly
    /// over 360°, degrees (the engine's `reseedHeadingStdDeg` default).
    public static let uniformHeadingAboveDeg = 30.0
    /// A grown prior whose major-axis σ is above this is not used: the run
    /// starts fresh, metres.
    public static let maxSigmaM = 1500.0
    /// A fix or pin disagrees with an unconfirmed prior when
    /// rᵀ (Σ_prior + σ² I)⁻¹ r is above this (χ², 2 dof, 99 %).
    public static let rejectChi2 = 9.21
    /// An agreeing fix confirms only with σ ≤ max(the prior's major-axis σ,
    /// this), metres.
    public static let confirmMinSigmaM = 50.0
    /// A network fix (no valid speed) with an accuracy above this is a
    /// cell-tower fix, metres: it never confirms (it can still reject).
    /// The replay set's network fixes are bimodal: Wi-Fi under ~300 m,
    /// towers from ~500 m (typically 1.2–1.5 km).
    public static let towerAccuracyM = 400.0
    /// A fresh OBD 0 held at least this long is a standing stop, s.
    public static let standingStopMinZeroS = 3.0
    /// A parked or standing-stop prior whose first OBD reply is below this
    /// is kept (a slow pull-out while the adapter connects), km/h; at or
    /// above it the prior is regrown as moving (user decision 2026-10-22).
    public static let slowPullOutMaxKmh = 10.0
    /// A kept slow pull-out adds (v_first × this)² to each axis of the
    /// position variance for the roll before the first reply, s.
    public static let slowPullOutRollS = 5.0
    /// A hand-over (`NavigationPrior.handOver`) from a converged estimate
    /// with a gap up to this is confirmed at once, s.
    public static let handOverConfirmMaxGapS = 10.0
    /// A wall-clock age down to minus this is taken as 0 (clock skew
    /// between the save and the read), s; below it the state is refused.
    public static let maxNegativeAgeS = 5.0
}

/// A saved belief to start a run from, on the new run's session clock
/// (`NavigationRestoreState.prior(at:clock:bootSessionID:)`). The engine
/// grows it for the gap from `savedT` to its first input (`seed`).
public struct NavigationPrior: Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Position covariance when saved, east/north, m².
    public var covEE: Double
    public var covEN: Double
    public var covNN: Double
    /// Heading of travel when saved, degrees clockwise from north, and its
    /// circular std, degrees.
    public var headingDeg: Double
    public var headingStdDeg: Double
    /// When the state was saved, on the new run's session clock (negative:
    /// before the run started).
    public var savedT: MonotonicTimestamp
    /// Estimated speed when saved, m/s.
    public var lastSpeedMps: Double
    public var restoreClass: NavigationRestoreClass
    /// The saved estimate's `converged` (information: the restored run's
    /// `converged` is its grown heading σ under the threshold, the same
    /// rule as always; equal to this whenever the growth keeps σ under it).
    public var converged: Bool
    /// Set by the app only: the state was saved, in this process, by a
    /// recording that has just ended and this run takes over from it (the
    /// Record-stop hand-over). With `converged` and a gap up to
    /// `NavigationRestoreModel.handOverConfirmMaxGapS` the restore is
    /// confirmed at once (`.handOver`); otherwise the normal rule. Never set
    /// for a relaunch or a state read from an earlier process.
    public var handOver: Bool

    public init(latitude: Double, longitude: Double, covEE: Double, covEN: Double, covNN: Double,
                headingDeg: Double, headingStdDeg: Double, savedT: MonotonicTimestamp, lastSpeedMps: Double,
                restoreClass: NavigationRestoreClass, converged: Bool = false, handOver: Bool = false) {
        self.converged = converged
        self.handOver = handOver
        self.latitude = latitude
        self.longitude = longitude
        self.covEE = covEE
        self.covEN = covEN
        self.covNN = covNN
        self.headingDeg = headingDeg
        self.headingStdDeg = headingStdDeg
        self.savedT = savedT
        self.lastSpeedMps = lastSpeedMps
        self.restoreClass = restoreClass
    }

    /// The grown prior the engine seeds from.
    public struct Seed: Hashable, Sendable {
        /// Position covariance, m².
        public var covEE: Double
        public var covEN: Double
        public var covNN: Double
        /// Heading mean and σ, radians; nil: stratified uniform.
        public var headingRadians: Double?
        public var headingSigmaRadians: Double?
        /// The mean carried forward over the gap, metres (moving, short gap).
        public var shiftEastM = 0.0
        public var shiftNorthM = 0.0

        /// Major-axis σ, metres.
        public var majorSigmaM: Double { NavigationPrior.majorVariance(covEE, covEN, covNN).squareRoot() }
    }

    /// Finite, in range, and a positive semi-definite covariance.
    public var isValid: Bool {
        let values = [latitude, longitude, covEE, covEN, covNN, headingDeg, headingStdDeg, lastSpeedMps]
        guard values.allSatisfy(\.isFinite), abs(latitude) <= 90, abs(longitude) <= 180,
              covEE >= 0, covNN >= 0, covEE * covNN - covEN * covEN >= -1e-9 * max(1, covEE * covNN),
              headingStdDeg >= 0, lastSpeedMps >= 0 else { return false }
        return true
    }

    /// The prior grown for `gapS` seconds since `savedT`
    /// (docs/NAVIGATION.md "Restored prior (UX-20)"), with g = max(last
    /// speed, 11.1 m/s) · gap the distance a moving car may cover:
    /// - moving (or a stopped class whose first OBD reply is moving:
    ///   `movingAtStart`): per-axis σ² + g²; heading uniform for a gap
    ///   over 5 s, else σ² + (5.5°/s · gap)² and the mean carried forward
    ///   by last speed · gap along the saved heading;
    /// - parked: per-axis σ² + min(10 m, g)², heading σ² + min(3°, 5.5°/s ·
    ///   gap)²;
    /// - standing stop: per-axis σ² + min(50 m, g)², heading as parked.
    /// A grown heading σ over 30° is uniform. nil (no prior: start fresh)
    /// when the grown major-axis σ is over 1.5 km, or the prior is invalid.
    public func seed(gapS: Double, movingAtStart: Bool = false) -> Seed? {
        guard isValid, gapS.isFinite else { return nil }
        let gap = max(0, gapS)
        typealias M = NavigationRestoreModel
        let moving = restoreClass == .moving || movingAtStart
        let movingSigma = max(lastSpeedMps, M.movingMinSpeedMps) * gap
        let turn = M.movingHeadingRateDegPerS * gap
        let addSigma: Double
        var headingSigmaDeg: Double?
        var shift = 0.0
        if moving {
            addSigma = movingSigma
            if gap <= M.movingUniformHeadingAfterS {
                headingSigmaDeg = (headingStdDeg * headingStdDeg + turn * turn).squareRoot()
            }
            if gap <= M.movingShiftMaxGapS { shift = lastSpeedMps * gap }
        } else {
            addSigma = min(restoreClass == .parked ? M.parkedPositionSigmaM : M.standingStopPositionSigmaM, movingSigma)
            let add = min(M.stoppedHeadingSigmaDeg, turn)
            headingSigmaDeg = (headingStdDeg * headingStdDeg + add * add).squareRoot()
        }
        if let s = headingSigmaDeg, s > M.uniformHeadingAboveDeg { headingSigmaDeg = nil }
        let add = addSigma * addSigma
        let h = headingDeg * .pi / 180
        var seed = Seed(covEE: covEE + add, covEN: covEN, covNN: covNN + add,
                        headingRadians: headingSigmaDeg.map { _ in h },
                        headingSigmaRadians: headingSigmaDeg.map { $0 * .pi / 180 })
        if shift > 0, headingSigmaDeg != nil {
            seed.shiftEastM = shift * sin(h)
            seed.shiftNorthM = shift * cos(h)
        }
        guard seed.majorSigmaM.isFinite, seed.majorSigmaM <= M.maxSigmaM else { return nil }
        return seed
    }

    /// The larger eigenvalue of [[ee, en], [en, nn]].
    static func majorVariance(_ ee: Double, _ en: Double, _ nn: Double) -> Double {
        let mean = (ee + nn) / 2
        let radius = (((ee - nn) / 2) * ((ee - nn) / 2) + en * en).squareRoot()
        return max(0, mean + radius)
    }
}

/// The restore's state in a run (`NavigationEngine.restore`,
/// `NavigationSnapshot.restore`). Never written to the sidecar or the log.
public struct NavigationRestore: Hashable, Sendable, Codable {
    public enum Status: String, Hashable, Sendable, Codable {
        /// No prior was given, or it was too uncertain to use
        /// (`reason` `.tooUncertain`): the run started fresh.
        case none
        /// The cloud was seeded from the prior; no fix or pin has decided.
        case unconfirmed
        /// An agreeing fix (GNSS or Wi-Fi, σ small enough) or pin.
        case confirmed
        /// A disagreeing fix or pin (or the first OBD reply said moving
        /// and the grown prior was too wide): the engine reinitialised as a
        /// run without a prior would have.
        case rejected
    }

    public enum Reason: String, Hashable, Sendable, Codable {
        case fix
        case pin
        /// A stopped-class prior whose first OBD reply was moving, grown
        /// as moving beyond `NavigationRestoreModel.maxSigmaM`.
        case movingAtStart
        /// Confirmed at once: a Record-stop hand-over (`NavigationPrior.handOver`)
        /// from a converged estimate within
        /// `NavigationRestoreModel.handOverConfirmMaxGapS`.
        case handOver
        /// The grown prior was beyond `NavigationRestoreModel.maxSigmaM` at
        /// the first input.
        case tooUncertain
    }

    public var status: Status = .none
    /// When the restored state was saved (the run's clock); nil without a
    /// prior.
    public var savedT: MonotonicTimestamp?
    /// What confirmed or rejected it, or why it was not used.
    public var reason: Reason?
    /// When it was confirmed or rejected (input arrival).
    public var decidedT: MonotonicTimestamp?
    /// A stopped-class prior regrown as moving at its first OBD reply.
    public var regrownAsMoving = false
    /// A stopped-class prior kept at a slow first OBD reply (below
    /// `NavigationRestoreModel.slowPullOutMaxKmh`): that reply, km/h; nil
    /// otherwise (absent in JSON).
    public var slowPullOutKmh: Double?
    /// Fixes ignored because their own time is before `savedT` (a cached
    /// fix older than the restored state).
    public var fixesOlderThanSave = 0
    /// Inputs ignored before the prior was applied because they arrived
    /// before `savedT` (prompt 40: the start-up init replay's `obd` rows,
    /// stamped when the link connected); nil when none (absent in JSON).
    public var inputsOlderThanSave: Int?

    public init() {}

    /// Seconds from the save to `t`; nil without a prior.
    public func ageS(at t: MonotonicTimestamp) -> Double? {
        savedT.map { (Double(t.nanoseconds) - Double($0.nanoseconds)) / 1e9 }
    }
}

/// The persisted Navigate estimate (UX-20): small, versioned, Foundation
/// only. The app stores the bytes (`encoded()` / `decode(_:)`); this type
/// owns the content, its validation, its age and the prior it gives.
public struct NavigationRestoreState: Hashable, Sendable, Codable {
    /// The only version this build writes and reads.
    public static let currentVersion = 1

    public var version: Int
    /// Wall clock at the save, from the saving run's
    /// `SessionClock.wallClock(for:)` (never `Date()` per sample).
    public var savedAt: Date
    /// The phone's boot session when saved (the app reads it; nil when
    /// unknown). With the same boot, uptime bounds the age from below.
    public var bootSessionID: String?
    /// Seconds since boot at the save (`referenceUptimeSeconds + t`).
    public var uptimeSeconds: Double
    public var latitude: Double
    public var longitude: Double
    /// Position covariance, east/north, m² (from the 95 % ellipse).
    public var covEE: Double
    public var covEN: Double
    public var covNN: Double
    public var headingDeg: Double
    public var headingStdDeg: Double
    public var converged: Bool
    public var restoreClass: NavigationRestoreClass
    /// The estimate's speed, m/s.
    public var speedMps: Double
    /// The last OBD vehicle speed (raw km/h) and its age at the save, s;
    /// nil without a reply.
    public var lastOBDSpeedKmh: Double?
    public var lastOBDAgeS: Double?
    /// The attached road packs' content-hash prefixes (diagnostics only).
    public var roadPacks: [String]

    enum CodingKeys: String, CodingKey {
        case version, savedAt, bootSessionID, uptimeSeconds, latitude, longitude, covEE, covEN, covNN
        case headingDeg, headingStdDeg, converged, restoreClass = "class", speedMps, lastOBDSpeedKmh, lastOBDAgeS
        case roadPacks
    }

    public init(savedAt: Date, bootSessionID: String?, uptimeSeconds: Double, latitude: Double, longitude: Double,
                covEE: Double, covEN: Double, covNN: Double, headingDeg: Double, headingStdDeg: Double,
                converged: Bool, restoreClass: NavigationRestoreClass, speedMps: Double,
                lastOBDSpeedKmh: Double?, lastOBDAgeS: Double?, roadPacks: [String] = []) {
        version = Self.currentVersion
        self.savedAt = savedAt
        self.bootSessionID = bootSessionID
        self.uptimeSeconds = uptimeSeconds
        self.latitude = latitude
        self.longitude = longitude
        self.covEE = covEE
        self.covEN = covEN
        self.covNN = covNN
        self.headingDeg = headingDeg
        self.headingStdDeg = headingStdDeg
        self.converged = converged
        self.restoreClass = restoreClass
        self.speedMps = speedMps
        self.lastOBDSpeedKmh = lastOBDSpeedKmh
        self.lastOBDAgeS = lastOBDAgeS
        self.roadPacks = roadPacks
    }

    public enum DecodeError: Error, Hashable, Sendable, CustomStringConvertible {
        /// Not JSON of this shape.
        case malformed(String)
        /// A version this build does not read (newer or unknown).
        case unsupportedVersion(Int)
        /// A field out of range or not finite.
        case invalid(field: String)

        public var description: String {
            switch self {
            case .malformed(let detail): "malformed restore state: \(detail)"
            case .unsupportedVersion(let v): "unsupported restore state version \(v)"
            case .invalid(let field): "invalid restore state field \(field)"
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else { throw DecodeError.unsupportedVersion(version) }
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        bootSessionID = try c.decodeIfPresent(String.self, forKey: .bootSessionID)
        uptimeSeconds = try c.decode(Double.self, forKey: .uptimeSeconds)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        covEE = try c.decode(Double.self, forKey: .covEE)
        covEN = try c.decode(Double.self, forKey: .covEN)
        covNN = try c.decode(Double.self, forKey: .covNN)
        headingDeg = try c.decode(Double.self, forKey: .headingDeg)
        headingStdDeg = try c.decode(Double.self, forKey: .headingStdDeg)
        converged = try c.decode(Bool.self, forKey: .converged)
        restoreClass = try c.decode(NavigationRestoreClass.self, forKey: .restoreClass)
        speedMps = try c.decode(Double.self, forKey: .speedMps)
        lastOBDSpeedKmh = try c.decodeIfPresent(Double.self, forKey: .lastOBDSpeedKmh)
        lastOBDAgeS = try c.decodeIfPresent(Double.self, forKey: .lastOBDAgeS)
        roadPacks = try c.decodeIfPresent([String].self, forKey: .roadPacks) ?? []
        if let field = invalidField { throw DecodeError.invalid(field: field) }
    }

    /// The first field out of range or not finite; nil when valid.
    public var invalidField: String? {
        if version != Self.currentVersion { return "version" }
        if !savedAt.timeIntervalSince1970.isFinite { return "savedAt" }
        if let b = bootSessionID, b.isEmpty || b.count > 64 { return "bootSessionID" }
        if !uptimeSeconds.isFinite || uptimeSeconds < 0 { return "uptimeSeconds" }
        if !latitude.isFinite || abs(latitude) > 90 { return "latitude" }
        if !longitude.isFinite || abs(longitude) > 180 { return "longitude" }
        if !covEE.isFinite || covEE < 0 { return "covEE" }
        if !covNN.isFinite || covNN < 0 { return "covNN" }
        if !covEN.isFinite || covEE * covNN - covEN * covEN < -1e-9 * max(1, covEE * covNN) { return "covEN" }
        if !headingDeg.isFinite || headingDeg < 0 || headingDeg >= 360 { return "headingDeg" }
        if !headingStdDeg.isFinite || headingStdDeg < 0 { return "headingStdDeg" }
        if !speedMps.isFinite || speedMps < 0 { return "speedMps" }
        if let v = lastOBDSpeedKmh, !v.isFinite || v < 0 { return "lastOBDSpeedKmh" }
        if let a = lastOBDAgeS, !a.isFinite || a < 0 { return "lastOBDAgeS" }
        if roadPacks.count > 64 || roadPacks.contains(where: { $0.count > 16 }) { return "roadPacks" }
        return nil
    }

    /// JSON, sorted keys, `savedAt` in seconds since 1970 (sub-second).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(self)
    }

    /// Decodes and validates `data`; throws `DecodeError` for anything this
    /// build must not restore from.
    public static func decode(_ data: Data) throws(DecodeError) -> NavigationRestoreState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(NavigationRestoreState.self, from: data)
        } catch let error as DecodeError {
            throw error
        } catch {
            throw .malformed(String(describing: error))
        }
    }

    /// Seconds since the save, or nil when the state must not be restored
    /// (age below −`NavigationRestoreModel.maxNegativeAgeS` (5 s) or above
    /// `NavigationRestoreModel.maxAgeS`, 24 h). An age in [−5 s, 0) is
    /// clock skew and returned as 0.
    /// Same boot (`bootSessionID` equal and non-nil): max(wall Δ, uptime
    /// Δ), so a wall clock set back cannot make the state look younger.
    /// Otherwise the wall Δ.
    public func age(nowWall: Date, nowUptimeSeconds: Double, bootSessionID now: String?) -> Double? {
        var age = nowWall.timeIntervalSince(savedAt)
        if let now, let saved = bootSessionID, now == saved, nowUptimeSeconds.isFinite {
            age = max(age, nowUptimeSeconds - uptimeSeconds)
        }
        guard age.isFinite, age >= -NavigationRestoreModel.maxNegativeAgeS, age <= NavigationRestoreModel.maxAgeS
        else { return nil }
        return max(0, age)
    }

    /// The prior for a run whose clock is `clock`, starting at `t`
    /// (`savedT` = t − age); nil when `age` refuses the state or it is
    /// invalid. The engine grows it for the gap at its first input.
    /// `handOver`: `NavigationPrior.handOver` (the app's Record-stop
    /// hand-over only).
    public func prior(at t: MonotonicTimestamp, clock: SessionClock, bootSessionID: String?,
                      handOver: Bool = false) -> NavigationPrior? {
        guard invalidField == nil,
              let age = age(nowWall: clock.wallClock(for: t), nowUptimeSeconds: clock.referenceUptimeSeconds + t.seconds,
                            bootSessionID: bootSessionID) else { return nil }
        let prior = NavigationPrior(
            latitude: latitude, longitude: longitude, covEE: covEE, covEN: covEN, covNN: covNN,
            headingDeg: headingDeg, headingStdDeg: headingStdDeg,
            savedT: MonotonicTimestamp(nanoseconds: t.nanoseconds - Int64((age * 1e9).rounded())),
            lastSpeedMps: speedMps, restoreClass: restoreClass, converged: converged, handOver: handOver)
        return prior.isValid ? prior : nil
    }

    /// The state of `engine` at `t` (its `estimate(at:)`), stamped with
    /// `clock`'s wall clock and uptime for `t`; nil before initialisation.
    /// `engineOff`: the app knows the car's engine is off (ignition off,
    /// Navigate's auto-stop), see `NavigationEngine.restoreClass`.
    public static func capture(_ engine: NavigationEngine, at t: MonotonicTimestamp, clock: SessionClock,
                               bootSessionID: String?, engineOff: Bool) -> NavigationRestoreState? {
        guard let estimate = engine.estimate(at: t) else { return nil }
        let cov = estimate.ellipse.covariance
        let obd = engine.lastOBDSpeed
        var heading = estimate.headingDeg
        if !(heading >= 0 && heading < 360) { heading = 0 }
        let state = NavigationRestoreState(
            savedAt: clock.wallClock(for: t), bootSessionID: bootSessionID,
            uptimeSeconds: clock.referenceUptimeSeconds + t.seconds,
            latitude: estimate.latitude, longitude: estimate.longitude,
            covEE: cov.ee, covEN: cov.en, covNN: cov.nn,
            headingDeg: heading, headingStdDeg: estimate.headingStdDeg, converged: estimate.converged,
            restoreClass: engine.restoreClass(at: t, engineOff: engineOff),
            speedMps: max(0, estimate.speedMps),
            lastOBDSpeedKmh: obd?.kmh, lastOBDAgeS: obd.map { max(0, (Double(t.nanoseconds) - Double($0.t.nanoseconds)) / 1e9) },
            roadPacks: engine.roadNetwork?.packs.map { String(NavigationSeed.hex($0.contentHash).prefix(8)) } ?? [])
        return state.invalidField == nil ? state : nil
    }
}

/// Distance driven by OBD vehicle speed (UX-20, R77.4-3): each reply from
/// the primary ECU (`NavigationEngine.primaryECU`, or no ECU) held until the
/// next one, at most `maxHoldS`, with whole km/h truncation corrected
/// (v + 0.5 for v > 0). Replies out of time order are skipped. Pure
/// bookkeeping: it feeds nothing in the engine. The app uses `metres > 0`
/// (the car drove) to invalidate a saved estimate a run could not replace.
public struct OBDOdometer: Hashable, Sendable {
    /// Longest a reply's speed is held, s (the engine's `obdMaxAgeS` default).
    public static let maxHoldS = 2.0

    public private(set) var metres = 0.0
    private var lastKmh: Double?
    private var lastNs: Int64?

    public init() {}

    /// Whether the car has moved by OBD.
    public var drove: Bool { metres > 0 }

    public mutating func observe(_ input: NavigationInput) {
        guard case .obd(let sample, let t) = input, sample.pid == .vehicleSpeed,
              sample.ecu == nil || sample.ecu == NavigationEngine.primaryECU,
              sample.value.isFinite, sample.value >= 0 else { return }
        let ns = t.nanoseconds
        if let lastNs, ns < lastNs { return }
        if let lastKmh, let lastNs, lastKmh > 0 {
            let dt = min(Self.maxHoldS, (Double(ns) - Double(lastNs)) / 1e9)
            metres += (lastKmh + 0.5) / 3.6 * dt
        }
        lastKmh = sample.value
        lastNs = ns
    }
}

extension NavigationRestoreState {
    /// The same state with its position moved `east`/`north` metres
    /// (`replay_nav --prior-offset`: a car moved while the app was not
    /// running, synthetic). Offline tools only.
    public func shifted(eastM: Double, northM: Double) -> NavigationRestoreState {
        var copy = self
        let p = LocalTangentPlane(latitude: latitude, longitude: longitude).geodetic(east: eastM, north: northM)
        copy.latitude = p.latitude
        copy.longitude = p.longitude
        return copy
    }
}

extension ErrorEllipse {
    /// The covariance this 95 % ellipse was made from, east/north, m²
    /// (`init(covarianceEE:en:nn:)` inverted).
    public var covariance: (ee: Double, en: Double, nn: Double) {
        let major = semiMajorM * semiMajorM / Self.chiSquare95
        let minor = semiMinorM * semiMinorM / Self.chiSquare95
        let b = orientationDeg * .pi / 180
        let ue = sin(b), un = cos(b)
        // Major axis u = (ue, un), minor v = (−un, ue).
        return (major * ue * ue + minor * un * un,
                (major - minor) * ue * un,
                major * un * un + minor * ue * ue)
    }
}
