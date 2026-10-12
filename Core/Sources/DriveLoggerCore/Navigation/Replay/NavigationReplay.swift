import Foundation

// The analysis behind `replay_nav`, in Core so `swift test` covers it. The
// CLI only parses arguments, reads files and prints.
//
// A replay feeds a recording's navigation inputs to a `NavigationEngine` in
// arrival order, withholding location fixes as the GPS mode says, and scores
// the engine only against information it did not receive.

/// Which location fixes the engine receives.
public enum GPSMode: Hashable, Sendable {
    /// Every fix.
    case use
    /// No fix whose time `t` is after this many session seconds.
    case maskAfter(seconds: Double)
    /// No fix whose time `t` is more than this many seconds after motion
    /// starts (`NavigationReplay.motionStart`). If the car never moves,
    /// nothing is masked.
    case maskAfterMotion(seconds: Double)
    /// No fixes; initialisation then comes from a manual fix, if any.
    case none

    /// `use`, `none`, or `mask-after` / `mask-after-motion` with seconds.
    public init?(_ name: String, seconds: Double? = nil) {
        switch name {
        case "use": self = .use
        case "none", "ignore": self = .none
        case "mask-after":
            guard let seconds, seconds.isFinite else { return nil }
            self = .maskAfter(seconds: seconds)
        case "mask-after-motion":
            guard let seconds, seconds.isFinite else { return nil }
            self = .maskAfterMotion(seconds: seconds)
        default: return nil
        }
    }

    /// For file names and tables: `use`, `none`, `mask-after-30`.
    public var label: String {
        switch self {
        case .use: "use"
        case .none: "none"
        case .maskAfter(let s): "mask-after-\(Self.format(s))"
        case .maskAfterMotion(let s): "mask-after-motion-\(Self.format(s))"
        }
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

public struct ReplayOptions: Hashable, Sendable {
    public var gps: GPSMode
    /// Fixes with horizontal accuracy under this many metres are withheld,
    /// initialisation included.
    public var holdOutAccuracyM: Double?
    public var config: NavigationConfig
    /// Track sampling interval, seconds.
    public var trackIntervalS = 1.0
    /// 95 % ellipse output interval, seconds.
    public var ellipseIntervalS = 10.0
    /// Heading counts as converged once `converged` holds this long.
    public var convergenceHoldS = 30.0
    /// The run replays the live app (`replay_nav --as-live`): inputs in
    /// file order, the seed derived from the header, the default config.
    /// Only the label depends on it; the caller orders the inputs.
    public var asLive = false
    /// Inputs in file order with any seed and config (`replay_nav
    /// --file-order`): the live order, for seed sweeps. Only the label
    /// depends on it; `asLive` implies it.
    public var fileOrder = false
    /// Refinement pairs (`replay_nav --pin-pair-window`): a manual fix at
    /// most this many seconds after the previous manual fix is a refinement
    /// and is not scored; 0 scores every pin (the rule before N3.0). Scoring
    /// only: the engine ingests every pin either way. See
    /// `NavigationReplay.pinScoring`.
    public var pinPairWindowS = NavigationReplay.defaultPinPairWindowS

    public init(gps: GPSMode, holdOutAccuracyM: Double? = nil, config: NavigationConfig = NavigationConfig()) {
        self.gps = gps
        self.holdOutAccuracyM = holdOutAccuracyM
        self.config = config
    }

    public var label: String {
        var label = gps.label
        if let holdOutAccuracyM { label += "-holdout-\(GPSMode.format(holdOutAccuracyM))" }
        if asLive { label += "-as-live" } else if fileOrder { label += "-file-order" }
        return label
    }
}

/// Why a fix was not given to the engine.
public enum WithholdReason: String, Hashable, Sendable, Codable {
    case masked
    case gpsNone
    case heldOut
}

public enum NavigationReplay {
    /// The navigation inputs of a recording in arrival order: motion and OBD
    /// by `t`, location by `max(receivedT, t)` (`NavigationInput.arrival`),
    /// manual fixes by `t`. Ties keep file order.
    public static func inputs<S: Sequence>(from events: S) -> [NavigationInput] where S.Element == LogEvent {
        let indexed = events.compactMap(NavigationInput.init).enumerated().map { ($0.offset, $0.element) }
        return indexed.sorted {
            let a = $0.1.arrival, b = $1.1.arrival
            return a != b ? a < b : $0.0 < $1.0
        }.map(\.1)
    }

    /// Motion start rule: OBD vehicle speed from the primary ECU (or no
    /// ECU, v1) at or above `motionStartKmh`, held for `motionStartHoldS`
    /// with no reply gap over `motionStartMaxGapS`. 3 km/h ignores the
    /// 1–2 km/h creep of a car inching in a queue or a parking space.
    public static let motionStartKmh = 3.0
    public static let motionStartHoldS = 3.0
    public static let motionStartMaxGapS = 2.0

    /// When the car starts moving: the first OBD reply of the first run in
    /// which every reply is at least `motionStartKmh`, consecutive replies
    /// are at most `motionStartMaxGapS` apart, and the run lasts at least
    /// `motionStartHoldS`. nil if there is no such run. A replay-side
    /// definition (it looks `motionStartHoldS` ahead); the engine never
    /// sees it.
    public static func motionStart(_ inputs: [NavigationInput]) -> MonotonicTimestamp? {
        var runStart: MonotonicTimestamp?
        var previous: MonotonicTimestamp?
        for input in inputs {
            guard case .obd(let sample, let t) = input, sample.pid == .vehicleSpeed,
                  sample.ecu == nil || sample.ecu == NavigationEngine.primaryECU, sample.value.isFinite else { continue }
            defer { previous = t }
            guard sample.value >= motionStartKmh else {
                runStart = nil
                continue
            }
            if runStart == nil || previous.map({ $0.interval(to: t) > motionStartMaxGapS }) == true {
                runStart = t
            }
            if let start = runStart, start.interval(to: t) >= motionStartHoldS {
                return start
            }
        }
        return nil
    }

    /// Why `options` withholds this fix from the engine, or nil to ingest it.
    /// `motionStart` is needed only for `.maskAfterMotion`.
    public static func withholdReason(
        _ sample: LocationSample, at t: MonotonicTimestamp, options: ReplayOptions,
        motionStart: MonotonicTimestamp? = nil
    ) -> WithholdReason? {
        switch options.gps {
        case .none: return .gpsNone
        case .maskAfter(let seconds) where t.seconds > seconds: return .masked
        case .maskAfterMotion(let seconds):
            if let start = motionStart, start.interval(to: t) > seconds { return .masked }
        default: break
        }
        if let limit = options.holdOutAccuracyM, sample.horizontalAccuracy >= 0, sample.horizontalAccuracy < limit {
            return .heldOut
        }
        return nil
    }

    /// The navigation inputs of a recording in file order: the order the
    /// live app's tap delivered them (`LogSink`, "Tap"), for
    /// `replay_nav --as-live`. Unlike `inputs(from:)`, a location fix comes
    /// where it was written (on arrival), and a late CoreMotion batch where
    /// it was delivered, not at its own `t`.
    public static func fileOrderInputs<S: Sequence>(from events: S) -> [NavigationInput] where S.Element == LogEvent {
        events.compactMap(NavigationInput.init)
    }

    /// Navigation inputs the live app saw but the file does not hold: each
    /// `lifecycle` `error` row with detail `encodingFailed <kind>: …` for a
    /// navigation kind (a non-finite `Double` from a sensor). The tap hands
    /// the event to the engine before the writer encodes it, so the replay
    /// misses it: a known source of `--compare` differences.
    public static func encodingFailures<S: Sequence>(in events: S) -> [(t: MonotonicTimestamp, kind: String)]
        where S.Element == LogEvent {
        let kinds: Set<String> = ["motion", "location", "obd", "manualFix"]
        return events.compactMap { event in
            guard case .lifecycle(let sample) = event.payload, sample.event == LifecycleSample.Event.error.rawValue,
                  let detail = sample.detail, detail.hasPrefix("encodingFailed ") else { return nil }
            let kind = String(detail.dropFirst("encodingFailed ".count).prefix { $0 != ":" })
            return kinds.contains(kind) ? (event.timestamp, kind) : nil
        }
    }

    /// The sidecar lines `LiveNavigationRun` produces for `inputs` (in the
    /// order given), as the app would have written them with no drops: the
    /// reference for `--compare`.
    public static func liveLines(
        inputs: [NavigationInput], sessionID: UUID, config: NavigationConfig, appBuild: String = "replay"
    ) -> [NavSidecar.Line] {
        var run = LiveNavigationRun(sessionID: sessionID, config: config, appBuild: appBuild)
        var lines: [NavSidecar.Line] = [.header(run.header)]
        for input in inputs {
            run.ingest(input) { lines.append($0) }
        }
        return lines
    }

    // MARK: Pin scoring (replay-side, looks ahead)

    /// Default `ReplayOptions.pinPairWindowS`, seconds. The refinement pairs
    /// recorded so far are 0.95–1.60 s apart; the closest pins that are not
    /// a pair are 27.5 s apart. 3 s is about twice the widest pair and the
    /// length of the app's Undo toast, during which the user is still looking
    /// at the pin just placed; at 50 km/h the car covers 42 m in 3 s, about
    /// one pin σ, so a pin that soon after another is not an independent
    /// check of the estimate.
    public static let defaultPinPairWindowS = 3.0

    /// Why a manual fix is not scored.
    ///
    /// The rule (replay-side scoring, not causal: the classification of a pin
    /// uses the whole recording's manual fixes, and the engine never sees it):
    /// - Manual fixes are taken in `t` order (ties in input order).
    /// - **Refinement:** a pin whose `t` is at most `pairWindowS` after the
    ///   previous manual fix's `t` (any manual fix, scored or not), compared
    ///   in whole nanoseconds. The previous pin has just been ingested and
    ///   moved the estimate, so the prior at this one is an easy hit. A chain
    ///   (each pin within the window of the one before) therefore folds onto
    ///   its first pin, however long it is; pins 0, 2 and 4 s apart with a 3 s
    ///   window score only the first. `pairWindowS` ≤ 0 disables folding.
    /// - **Excluded:** each truth-file `excludePins` entry marks the manual
    ///   fix nearest its `t` within `TruthFile.excludePinToleranceS`. An
    ///   excluded pin is still the "previous manual fix" for the pair rule,
    ///   since the engine ingested it. A pin that is both is reported as
    ///   excluded.
    public struct NotScored: Hashable, Sendable, Codable {
        public enum Reason: String, Hashable, Sendable, Codable {
            case refinement
            case excluded
        }

        public var reason: Reason
        /// Refinement: `t` of the chain's first pin.
        public var firstPinT: Double?
        /// Excluded: the truth file's `reason`.
        public var note: String?

        public init(reason: Reason, firstPinT: Double? = nil, note: String? = nil) {
            self.reason = reason
            self.firstPinT = firstPinT
            self.note = note
        }

        /// "refinement of t 706.3 s, not scored", "excluded by truth (…), not scored".
        public var text: String {
            switch reason {
            case .refinement:
                return "refinement" + (firstPinT.map { String(format: " of t %.1f s", $0) } ?? "") + ", not scored"
            case .excluded:
                return "excluded by truth" + (note.map { " (\($0))" } ?? "") + ", not scored"
            }
        }
    }

    /// The pin-scoring decision for `manualFixTimes` (in any order): one
    /// entry per time, in the same order, nil for a scored pin; plus the
    /// `exclusions` that matched no pin. See `NotScored` for the rule.
    public static func pinScoring(
        manualFixTimes: [MonotonicTimestamp], pairWindowS: Double, exclusions: [TruthFile.ExcludedPin] = []
    ) -> (notScored: [NotScored?], unmatchedExclusions: [TruthFile.ExcludedPin]) {
        var result = [NotScored?](repeating: nil, count: manualFixTimes.count)
        let order = manualFixTimes.indices.sorted {
            manualFixTimes[$0] != manualFixTimes[$1] ? manualFixTimes[$0] < manualFixTimes[$1] : $0 < $1
        }
        if pairWindowS > 0 {
            let windowNs = (pairWindowS * 1e9).rounded()
            var chainStart: MonotonicTimestamp?
            var previous: MonotonicTimestamp?
            for index in order {
                let t = manualFixTimes[index]
                if let previous, let start = chainStart,
                   Double(t.nanoseconds) - Double(previous.nanoseconds) <= windowNs {
                    result[index] = NotScored(reason: .refinement, firstPinT: start.seconds)
                } else {
                    chainStart = t
                }
                previous = t
            }
        }
        var unmatched: [TruthFile.ExcludedPin] = []
        let toleranceNs = (TruthFile.excludePinToleranceS * 1e9).rounded()
        for exclusion in exclusions {
            let target = Double(MonotonicTimestamp(seconds: exclusion.t).nanoseconds)
            var best: (index: Int, distance: Double)?
            for index in order {
                let distance = abs(Double(manualFixTimes[index].nanoseconds) - target)
                if distance <= toleranceNs, best.map({ distance < $0.distance }) ?? true { best = (index, distance) }
            }
            if let best {
                result[best.index] = NotScored(reason: .excluded, note: exclusion.reason)
            } else {
                unmatched.append(exclusion)
            }
        }
        return (result, unmatched)
    }

    /// Replays `inputs` (arrival order, see `inputs(from:)`) through a fresh
    /// engine.
    public static func run(
        logName: String,
        inputs: [NavigationInput],
        options: ReplayOptions,
        truth: TruthFile.Entry? = nil
    ) -> ReplayResult {
        var run = ReplayRun(logName: logName, inputs: inputs, options: options, truth: truth)
        return run.execute()
    }
}

// MARK: - Result

public struct ReplayResult: Hashable, Sendable, Codable {
    public struct Checkpoint: Hashable, Sendable, Codable {
        public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
            /// A withheld GNSS fix at or under `cleanFixAccM`.
            case cleanFix
            /// A manual fix, scored on the prior just before it is ingested.
            case manualFix
            /// A `points` entry of the truth file.
            case truthPoint
            /// The truth file's `end`, at the last input.
            case truthEnd
        }

        public var kind: Kind
        public var t: Double
        public var latitude: Double
        public var longitude: Double
        public var truthSigmaM: Double?
        /// Distance travelled (∫ OBD speed) up to `t`, metres.
        public var distanceM: Double
        /// Engine estimate error, metres; nil before initialisation.
        public var errorM: Double?
        /// `errorM` as a percentage of `distanceM`.
        public var errorPercent: Double?
        public var estimateLatitude: Double?
        public var estimateLongitude: Double?
        /// Whether the truth lies inside the engine's 95 % ellipse.
        public var inside95: Bool?
        /// Whether the truth lies inside the 95 % ellipse of the engine's
        /// covariance plus the truth's own σ, P + σ_truth² I (Q3, the gated
        /// consistency since N3.0; `NavigationReplay.truthSigmaPerAxisM`).
        /// Optional so older metrics.json files decode.
        public var inside95WithTruthSigma: Bool?
        public var headingStdDeg: Double?
        /// The engine's 95 % ellipse at `t`: semi-axes (m) and bearing of
        /// the major axis (degrees).
        public var ellipseSemiMajorM: Double?
        public var ellipseSemiMinorM: Double?
        public var ellipseOrientationDeg: Double?
        /// Set for a manual fix that is not scored (a refinement or excluded
        /// by the truth file, `NavigationReplay.pinScoring`): its error is
        /// still measured and listed, but it is left out of max and end error
        /// and of consistency. Optional so older metrics.json files decode;
        /// nil (absent) for every scored checkpoint.
        public var notScored: NavigationReplay.NotScored?

        /// Whether the checkpoint counts in max/end error and consistency.
        public var isScored: Bool { notScored == nil }
    }

    /// How the manual fixes of a run were scored.
    public struct PinScoring: Hashable, Sendable, Codable {
        /// `ReplayOptions.pinPairWindowS`; 0: every pin scored.
        public var pairWindowS: Double
        public var manualFixes: Int
        public var scored: Int
        /// Folded into the pair (chain) of an earlier pin.
        public var refinements: Int
        /// Excluded by the truth file's `excludePins`.
        public var excluded: Int
        /// `excludePins` times that matched no manual fix.
        public var unmatchedExclusionsT: [Double]

        public init(pairWindowS: Double, manualFixes: Int = 0, scored: Int = 0, refinements: Int = 0,
                    excluded: Int = 0, unmatchedExclusionsT: [Double] = []) {
            self.pairWindowS = pairWindowS
            self.manualFixes = manualFixes
            self.scored = scored
            self.refinements = refinements
            self.excluded = excluded
            self.unmatchedExclusionsT = unmatchedExclusionsT
        }

        /// "12 manual fixes: 7 scored, 3 refinements folded into pairs (pair window 3 s), 2 excluded by truth".
        public var text: String {
            "\(manualFixes) manual fix\(manualFixes == 1 ? "" : "es"): \(scored) scored, \(refinements) refinement\(refinements == 1 ? "" : "s") folded into pairs (pair window "
                + (pairWindowS > 0 ? "\(GPSMode.format(pairWindowS)) s" : "off") + "), \(excluded) excluded by truth"
                + (unmatchedExclusionsT.isEmpty ? "" : "; excludePins matching no manual fix: "
                    + unmatchedExclusionsT.map { String(format: "t %.3f s", $0) }.joined(separator: ", "))
        }
    }

    public struct TrackPoint: Hashable, Sendable, Codable {
        public var t: Double
        public var latitude: Double
        public var longitude: Double
        public var headingDeg: Double
        public var headingStdDeg: Double
        public var converged: Bool
        public var distanceM: Double
        public var speedScale: Double
    }

    public struct EllipseSample: Hashable, Sendable, Codable {
        public var t: Double
        public var latitude: Double
        public var longitude: Double
        public var semiMajorM: Double
        public var semiMinorM: Double
        public var orientationDeg: Double
        /// Ring of the ellipse, (latitude, longitude) pairs, closed.
        public var ring: [[Double]]
    }

    public struct Fix: Hashable, Sendable, Codable {
        public var t: Double
        public var arrivalT: Double
        public var latitude: Double
        public var longitude: Double
        public var accuracyM: Double
        /// nil: given to the engine.
        public var withheld: WithholdReason?
    }

    public var logName: String
    public var mode: String
    public var config: NavigationConfig
    /// When the car started moving (`NavigationReplay.motionStart`).
    public var motionStartT: Double?
    /// First and last input arrival, session seconds.
    public var startT: Double
    public var endT: Double
    /// ∫ OBD speed (primary ECU, `v + 0.5` km/h when moving), metres.
    public var distanceM: Double
    public var checkpoints: [Checkpoint]
    /// Largest checkpoint error (m) and its percentage of distance so far.
    public var maxErrorM: Double?
    public var maxErrorPercent: Double?
    /// The truth `end` checkpoint, else the last scored checkpoint.
    public var endErrorM: Double?
    public var endErrorPercent: Double?
    public var endIsTruth: Bool
    /// First instant `converged` then holds for `convergenceHoldS`.
    public var convergedT: Double?
    public var convergedDistanceM: Double?
    public var finalHeadingStdDeg: Double?
    /// Ellipse consistency: scored checkpoints (all kinds) whose truth lies
    /// inside the engine's 95 % ellipse at their time.
    public var consistency: EllipseConsistency
    /// The same with the truth's own σ added to the engine's covariance
    /// (Q3): the consistency the adoption rule gates on since N3.0.
    public var consistencyWithTruthSigma: EllipseConsistency
    public var steps: Int
    /// Engine wall time (ingest only, no I/O) per 10 Hz step, ms.
    public var msPerStep: Double
    /// Longest single `ingest` call, ms.
    public var maxIngestMs: Double
    public var counters: NavigationCounters
    public var fixes: [Fix]
    public var track: [TrackPoint]
    public var ellipses: [EllipseSample]

    /// The engine's estimate at each manual fix, the prior just before it
    /// was ingested (what the live app writes as a sidecar `pin`), with its
    /// 95 % ellipse ring.
    public var pins: [PinEstimate] = []

    /// How the manual fixes were scored (pairs, truth exclusions).
    public var pinScoring = PinScoring(pairWindowS: 0)

    public var heldOutFixes: [Fix] { fixes.filter { $0.withheld == .heldOut } }
}

/// A manual fix with the dead-reckoning estimate just before it.
public struct PinEstimate: Hashable, Sendable, Codable {
    public var pin: NavSidecar.Pin
    /// The prior's 95 % ellipse as (latitude, longitude) pairs, closed; nil
    /// when the pin initialised the engine.
    public var ring: [[Double]]?
}

// MARK: - Run

private struct ReplayRun {
    let logName: String
    let inputs: [NavigationInput]
    let options: ReplayOptions
    let truth: TruthFile.Entry?

    var engine: NavigationEngine
    var distance = DistanceIntegrator()
    var fixes: [ReplayResult.Fix] = []
    var checkpoints: [ReplayResult.Checkpoint] = []
    var track: [ReplayResult.TrackPoint] = []
    var ellipses: [ReplayResult.EllipseSample] = []
    var pins: [PinEstimate] = []
    var engineNs: Int64 = 0
    var maxIngestNs: Int64 = 0
    let motionStart: MonotonicTimestamp?

    struct Scheduled {
        var t: Int64
        var kind: ReplayResult.Checkpoint.Kind
        var latitude: Double
        var longitude: Double
        var sigma: Double?
        var notScored: NavigationReplay.NotScored?
        /// Index in `inputs` of the input this checkpoint comes from (a
        /// withheld clean fix, a manual fix); nil for truth-file entries.
        var inputIndex: Int?
    }

    /// Inputs the engine would reject as implausible forward time jumps
    /// (`NavigationEngine.accepts`), by index in `inputs` (R14.2-3).
    var skippedInputs: Set<Int> = []

    var pinScoring = ReplayResult.PinScoring(pairWindowS: 0)

    init(logName: String, inputs: [NavigationInput], options: ReplayOptions, truth: TruthFile.Entry?) {
        self.logName = logName
        self.inputs = inputs
        self.options = options
        self.truth = truth
        engine = NavigationEngine(config: options.config)
        motionStart = NavigationReplay.motionStart(inputs)
    }

    mutating func execute() -> ReplayResult {
        let firstNs = inputs.first?.arrival.nanoseconds ?? 0
        let lastNs = inputs.last?.arrival.nanoseconds ?? 0
        var schedule = buildSchedule(lastNs: lastNs)
        schedule.sort { $0.t < $1.t }
        var nextCheckpoint = 0

        let trackNs = Int64((options.trackIntervalS * 1e9).rounded())
        let ellipseEvery = max(1, Int((options.ellipseIntervalS / options.trackIntervalS).rounded()))
        var nextTrackNs = NavigationEngine.floorToGrid(firstNs, trackNs) + trackNs
        var trackIndex = 0

        let clock = ContinuousClock()
        var endNs = firstNs

        for (index, input) in inputs.enumerated() {
            let arrival = input.arrival.nanoseconds
            var reason: WithholdReason?
            if case .location(let sample, let t) = input {
                reason = NavigationReplay.withholdReason(sample, at: t, options: options, motionStart: motionStart)
            }
            // R14.2-3: an input the engine would reject as an implausible
            // forward time jump (a corrupt huge `t`) is not on the replay's
            // timeline. Scoring and sampling up to its arrival would mean one
            // `estimate` per second up to that `t`, and its fix, distance and
            // pin are as corrupt as its time. The engine still counts it
            // (`inputsRejectedTimeJump`) unless it is a withheld fix, which the
            // engine never receives. Its pending checkpoints are dropped.
            guard engine.accepts(input) else {
                skippedInputs.insert(index)
                if reason == nil { engine.ingest(input) }
                continue
            }
            endNs = arrival
            // Score and sample everything due at or before this arrival, from
            // the state before it is ingested.
            while true {
                let checkpointDue = nextCheckpoint < schedule.count && schedule[nextCheckpoint].t <= arrival
                let trackDue = nextTrackNs <= arrival
                guard checkpointDue || trackDue else { break }
                if checkpointDue && (!trackDue || schedule[nextCheckpoint].t <= nextTrackNs) {
                    score(schedule[nextCheckpoint])
                    nextCheckpoint += 1
                } else {
                    sampleTrack(at: nextTrackNs, withEllipse: trackIndex % ellipseEvery == 0)
                    trackIndex += 1
                    nextTrackNs += trackNs
                }
            }

            if case .location(let sample, let t) = input {
                fixes.append(ReplayResult.Fix(
                    t: t.seconds, arrivalT: input.arrival.seconds,
                    latitude: sample.latitude, longitude: sample.longitude,
                    accuracyM: sample.horizontalAccuracy, withheld: reason
                ))
                if reason != nil { continue }
            }
            if case .manualFix(let sample, let t) = input {
                recordPin(sample, at: t)
            }
            if case .obd(let sample, let t) = input {
                distance.observe(sample, at: t.nanoseconds, maxAgeS: options.config.obdMaxAgeS,
                                 offsetKmh: options.config.obdSpeedOffsetKmh)
            }
            let start = clock.now
            engine.ingest(input)
            let elapsed = clock.now - start
            let ns = elapsed.components.seconds * 1_000_000_000 + elapsed.components.attoseconds / 1_000_000_000
            engineNs += ns
            maxIngestNs = max(maxIngestNs, ns)
        }
        // The end is the last input on the timeline: the last one, unless
        // trailing inputs were skipped (then the truth `end` is scored there).
        while nextCheckpoint < schedule.count {
            var item = schedule[nextCheckpoint]
            if item.kind == .truthEnd { item.t = endNs }
            score(item)
            nextCheckpoint += 1
        }
        sampleTrack(at: endNs, withEllipse: true)

        return finish(firstNs: firstNs, lastNs: endNs)
    }

    mutating func buildSchedule(lastNs: Int64) -> [Scheduled] {
        var schedule: [Scheduled] = []
        var manualIndices: [Int] = []
        for (index, input) in inputs.enumerated() {
            switch input {
            case .location(let sample, let t):
                guard NavigationReplay.withholdReason(sample, at: t, options: options, motionStart: motionStart) != nil,
                      sample.horizontalAccuracy >= 0,
                      sample.horizontalAccuracy <= options.config.cleanFixAccM else { continue }
                schedule.append(Scheduled(t: t.nanoseconds, kind: .cleanFix, latitude: sample.latitude,
                                          longitude: sample.longitude, sigma: sample.horizontalAccuracy,
                                          inputIndex: index))
            case .manualFix(let sample, let t):
                manualIndices.append(schedule.count)
                schedule.append(Scheduled(t: t.nanoseconds, kind: .manualFix, latitude: sample.latitude,
                                          longitude: sample.longitude, sigma: options.config.manualFixSigma(mapSpanM: sample.mapSpanM),
                                          inputIndex: index))
            default:
                continue
            }
        }
        let decision = NavigationReplay.pinScoring(
            manualFixTimes: manualIndices.map { MonotonicTimestamp(nanoseconds: schedule[$0].t) },
            pairWindowS: options.pinPairWindowS, exclusions: truth?.excludePins ?? [])
        for (index, notScored) in zip(manualIndices, decision.notScored) {
            schedule[index].notScored = notScored
        }
        pinScoring = ReplayResult.PinScoring(
            pairWindowS: max(0, options.pinPairWindowS), manualFixes: manualIndices.count,
            scored: decision.notScored.filter { $0 == nil }.count,
            refinements: decision.notScored.filter { $0?.reason == .refinement }.count,
            excluded: decision.notScored.filter { $0?.reason == .excluded }.count,
            unmatchedExclusionsT: decision.unmatchedExclusions.map(\.t))
        for point in truth?.points ?? [] {
            schedule.append(Scheduled(t: MonotonicTimestamp(seconds: point.t).nanoseconds, kind: .truthPoint,
                                      latitude: point.latitude, longitude: point.longitude, sigma: point.sigmaM))
        }
        if let end = truth?.end {
            schedule.append(Scheduled(t: lastNs, kind: .truthEnd, latitude: end.latitude,
                                      longitude: end.longitude, sigma: end.sigmaM))
        }
        return schedule
    }

    mutating func score(_ item: Scheduled) {
        // A checkpoint from a skipped input (R14.2-3) is not scored. One that
        // falls due before its own input is reached (a fix whose `t` is
        // plausible but whose arrival is not) was already scored on its `t`.
        if let index = item.inputIndex, skippedInputs.contains(index) { return }
        let t = MonotonicTimestamp(nanoseconds: item.t)
        let travelled = distance.distance(at: item.t)
        var checkpoint = ReplayResult.Checkpoint(
            kind: item.kind, t: t.seconds, latitude: item.latitude, longitude: item.longitude,
            truthSigmaM: item.sigma, distanceM: travelled
        )
        checkpoint.notScored = item.notScored
        if let estimate = engine.estimate(at: t), let plane = engine.tangentPlane {
            let truth = plane.enu(latitude: item.latitude, longitude: item.longitude)
            let dEast = truth.east - estimate.east
            let dNorth = truth.north - estimate.north
            let error = (dEast * dEast + dNorth * dNorth).squareRoot()
            checkpoint.errorM = error
            checkpoint.errorPercent = travelled > 0 ? 100 * error / travelled : nil
            checkpoint.estimateLatitude = estimate.latitude
            checkpoint.estimateLongitude = estimate.longitude
            checkpoint.inside95 = estimate.ellipse.contains(dEast: dEast, dNorth: dNorth)
            let truthSigma = NavigationReplay.truthSigmaPerAxisM(kind: item.kind, truthSigmaM: item.sigma)
            checkpoint.inside95WithTruthSigma = estimate.ellipse.adding(isotropicSigmaM: truthSigma)
                .contains(dEast: dEast, dNorth: dNorth)
            checkpoint.headingStdDeg = estimate.headingStdDeg
            checkpoint.ellipseSemiMajorM = estimate.ellipse.semiMajorM
            checkpoint.ellipseSemiMinorM = estimate.ellipse.semiMinorM
            checkpoint.ellipseOrientationDeg = estimate.ellipse.orientationDeg
        }
        checkpoints.append(checkpoint)
    }

    /// The prior at a manual fix, as the live app's sidecar records it.
    mutating func recordPin(_ sample: ManualFixSample, at t: MonotonicTimestamp) {
        let estimate = engine.estimate(at: t)
        let ring = estimate.flatMap { e in engine.tangentPlane.map { Self.ring(e, plane: $0) } }
        pins.append(PinEstimate(pin: NavSidecar.Pin(sample, at: t, prior: estimate.map { NavSidecar.Estimate($0) }),
                                ring: ring))
    }

    /// The 95 % ellipse of `estimate` as a closed ring of 37
    /// (latitude, longitude) pairs.
    static func ring(_ estimate: NavigationEstimate, plane: LocalTangentPlane) -> [[Double]] {
        let e = estimate.ellipse
        let b = e.orientationDeg * .pi / 180
        var ring: [[Double]] = []
        for k in 0...36 {
            let a = Double(k) / 36 * 2 * .pi
            let along = e.semiMajorM * cos(a)
            let across = e.semiMinorM * sin(a)
            let dEast = along * sin(b) - across * cos(b)
            let dNorth = along * cos(b) + across * sin(b)
            let p = plane.geodetic(east: estimate.east + dEast, north: estimate.north + dNorth)
            ring.append([p.latitude, p.longitude])
        }
        return ring
    }

    mutating func sampleTrack(at ns: Int64, withEllipse: Bool) {
        let t = MonotonicTimestamp(nanoseconds: ns)
        guard let estimate = engine.estimate(at: t), let plane = engine.tangentPlane else { return }
        if let last = track.last, last.t >= t.seconds { return }
        track.append(ReplayResult.TrackPoint(
            t: t.seconds, latitude: estimate.latitude, longitude: estimate.longitude,
            headingDeg: estimate.headingDeg, headingStdDeg: estimate.headingStdDeg,
            converged: estimate.converged, distanceM: distance.distance(at: ns),
            speedScale: estimate.speedScaleMean
        ))
        guard withEllipse else { return }
        let e = estimate.ellipse
        let ring = Self.ring(estimate, plane: plane)
        ellipses.append(ReplayResult.EllipseSample(
            t: t.seconds, latitude: estimate.latitude, longitude: estimate.longitude,
            semiMajorM: e.semiMajorM, semiMinorM: e.semiMinorM, orientationDeg: e.orientationDeg, ring: ring
        ))
    }

    func finish(firstNs: Int64, lastNs: Int64) -> ReplayResult {
        let scored = checkpoints.filter { $0.errorM != nil && $0.isScored }
        let worst = scored.max { $0.errorM! < $1.errorM! }
        let endCheckpoint = checkpoints.last { $0.kind == .truthEnd } ?? scored.last
        let convergence = NavigationReplay.convergence(track, holdS: options.convergenceHoldS)
        let steps = engine.counters.steps
        return ReplayResult(
            logName: logName,
            mode: options.label,
            config: options.config,
            motionStartT: motionStart?.seconds,
            startT: MonotonicTimestamp(nanoseconds: firstNs).seconds,
            endT: MonotonicTimestamp(nanoseconds: lastNs).seconds,
            distanceM: distance.distance(at: lastNs),
            checkpoints: checkpoints,
            maxErrorM: worst?.errorM,
            maxErrorPercent: worst?.errorPercent,
            endErrorM: endCheckpoint?.errorM,
            endErrorPercent: endCheckpoint?.errorPercent,
            endIsTruth: endCheckpoint?.kind == .truthEnd,
            convergedT: convergence?.t,
            convergedDistanceM: convergence?.distanceM,
            finalHeadingStdDeg: track.last?.headingStdDeg,
            consistency: EllipseConsistency(checkpoints),
            consistencyWithTruthSigma: EllipseConsistency(checkpoints, withTruthSigma: true),
            steps: steps,
            msPerStep: steps > 0 ? Double(engineNs) / 1e6 / Double(steps) : 0,
            maxIngestMs: Double(maxIngestNs) / 1e6,
            counters: engine.counters,
            fixes: fixes,
            track: track,
            ellipses: ellipses,
            pins: pins,
            pinScoring: pinScoring
        )
    }

}

extension NavigationReplay {
    /// CoreLocation's `horizontalAccuracy` is a 68 % radius; for a circular
    /// Gaussian that is 1.51 σ per axis. Fixed here, not taken from the
    /// config, so a `--set` cannot move the truth.
    public static let accuracyPerSigma = 1.51

    /// The truth's own σ per axis, metres, for the consistency with the
    /// truth's σ added (Q3):
    /// - a withheld clean fix: its `horizontalAccuracy` / `accuracyPerSigma`
    ///   (3.3 m at 5 m accuracy);
    /// - a manual fix: its pin σ (`truthSigmaM`, `manualFixSigma` of the run's
    ///   config, 30–104 m on the replay set);
    /// - a truth point or `end`: its `sigmaM` from the truth file.
    /// 0 when the truth gives none: that checkpoint scores as without it.
    public static func truthSigmaPerAxisM(kind: ReplayResult.Checkpoint.Kind, truthSigmaM: Double?) -> Double {
        guard let sigma = truthSigmaM, sigma.isFinite, sigma > 0 else { return 0 }
        return kind == .cleanFix ? sigma / accuracyPerSigma : sigma
    }

    /// Heading convergence: the first track point from which `converged`
    /// holds for at least `holdS` seconds (track times, inclusive), with its
    /// distance. A run of `converged` points shorter than `holdS` does not
    /// count, and nil if no run is long enough (the track ending inside a
    /// run included).
    static func convergence(_ track: [ReplayResult.TrackPoint], holdS: Double) -> (t: Double, distanceM: Double)? {
        var start: ReplayResult.TrackPoint?
        for point in track {
            if point.converged {
                if start == nil { start = point }
                if let s = start, point.t - s.t >= holdS { return (s.t, s.distanceM) }
            } else {
                start = nil
            }
        }
        return nil
    }
}

/// ∫ OBD vehicle speed from the primary ECU, zero-order hold, as the
/// reference "distance travelled" (independent of the engine's scale).
struct DistanceIntegrator {
    private var total = 0.0
    private var lastNs: Int64?
    private var speed = 0.0
    private var maxAgeNs: Int64 = 2_000_000_000

    mutating func observe(_ sample: OBDSample, at ns: Int64, maxAgeS: Double, offsetKmh: Double) {
        guard sample.pid == .vehicleSpeed,
              sample.ecu == nil || sample.ecu == NavigationEngine.primaryECU,
              sample.value.isFinite, sample.value >= 0 else { return }
        maxAgeNs = Int64(maxAgeS * 1e9)
        total = distance(at: ns)
        lastNs = ns
        speed = sample.value > 0 ? (sample.value + offsetKmh) / 3.6 : 0
    }

    func distance(at ns: Int64) -> Double {
        guard let lastNs, ns > lastNs else { return total }
        return total + speed * Double(min(ns - lastNs, maxAgeNs)) / 1e9
    }
}

/// How often the truth lies inside the engine's 95 % ellipse: over every
/// scored checkpoint (withheld clean fixes, manual-fix priors, truth points
/// and end), and per checkpoint kind. A calibrated filter scores about 95 %;
/// much lower means the ellipse is overconfident. The truth's own σ is not
/// added to the ellipse. A checkpoint that is not scored (`notScored`: a
/// refinement pin, or one the truth file excludes) is not counted.
///
/// **The one denominator (R13.1-8):** a checkpoint counts when it is scored
/// and the engine had an estimate at its time (`inside95` set). One before
/// initialisation has no ellipse and is in neither count. Every "inside
/// 95 %" figure `replay_nav` prints, per kind included (the clean-fix line
/// of the summary and `metrics.md`), is taken from here.
public struct EllipseConsistency: Hashable, Sendable, Codable {
    public struct Count: Hashable, Sendable, Codable {
        public var inside: Int
        public var scored: Int

        public init(inside: Int, scored: Int) {
            self.inside = inside
            self.scored = scored
        }

        /// inside / scored in %, nil when nothing was scored.
        public var percent: Double? { scored > 0 ? 100 * Double(inside) / Double(scored) : nil }
    }

    public var all: Count
    /// Keyed by `ReplayResult.Checkpoint.Kind` raw value.
    public var byKind: [String: Count]

    /// `withTruthSigma`: count `inside95WithTruthSigma` (the engine's
    /// covariance plus the truth's σ, Q3) instead of `inside95`. The
    /// denominator is the same: both are set exactly when the engine had an
    /// estimate.
    public init(_ checkpoints: [ReplayResult.Checkpoint], withTruthSigma: Bool = false) {
        var all = Count(inside: 0, scored: 0)
        var byKind: [String: Count] = [:]
        for checkpoint in checkpoints {
            guard let inside = withTruthSigma ? checkpoint.inside95WithTruthSigma : checkpoint.inside95,
                  checkpoint.isScored else { continue }
            all.scored += 1
            byKind[checkpoint.kind.rawValue, default: Count(inside: 0, scored: 0)].scored += 1
            if inside {
                all.inside += 1
                byKind[checkpoint.kind.rawValue, default: Count(inside: 0, scored: 0)].inside += 1
            }
        }
        self.all = all
        self.byKind = byKind
    }
}

extension ErrorEllipse {
    /// The 95 % ellipse of this ellipse's covariance P plus σ² I. P + σ² I
    /// has P's principal axes and eigenvalues λ + σ², so each semi-axis
    /// √(χ² λ) becomes √(semi-axis² + χ² σ²) and the orientation is kept.
    /// Replay scoring only (Q3).
    func adding(isotropicSigmaM sigma: Double) -> ErrorEllipse {
        let extra = Self.chiSquare95 * sigma * sigma
        return ErrorEllipse(semiMajorM: (semiMajorM * semiMajorM + extra).squareRoot(),
                            semiMinorM: (semiMinorM * semiMinorM + extra).squareRoot(),
                            orientationDeg: orientationDeg)
    }
}
