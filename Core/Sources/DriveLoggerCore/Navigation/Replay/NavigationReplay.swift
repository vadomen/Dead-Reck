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

    public init(gps: GPSMode, holdOutAccuracyM: Double? = nil, config: NavigationConfig = NavigationConfig()) {
        self.gps = gps
        self.holdOutAccuracyM = holdOutAccuracyM
        self.config = config
    }

    public var label: String {
        var label = gps.label
        if let holdOutAccuracyM { label += "-holdout-\(GPSMode.format(holdOutAccuracyM))" }
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
    /// by `t`, location by `receivedT ?? t`, manual fixes by `t`. Ties keep
    /// file order.
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
        public var headingStdDeg: Double?
        /// The engine's 95 % ellipse at `t`: semi-axes (m) and bearing of
        /// the major axis (degrees).
        public var ellipseSemiMajorM: Double?
        public var ellipseSemiMinorM: Double?
        public var ellipseOrientationDeg: Double?
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
    public var steps: Int
    /// Engine wall time (ingest only, no I/O) per 10 Hz step, ms.
    public var msPerStep: Double
    /// Longest single `ingest` call, ms.
    public var maxIngestMs: Double
    public var counters: NavigationCounters
    public var fixes: [Fix]
    public var track: [TrackPoint]
    public var ellipses: [EllipseSample]

    public var heldOutFixes: [Fix] { fixes.filter { $0.withheld == .heldOut } }
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
    var engineNs: Int64 = 0
    var maxIngestNs: Int64 = 0
    let motionStart: MonotonicTimestamp?

    struct Scheduled {
        var t: Int64
        var kind: ReplayResult.Checkpoint.Kind
        var latitude: Double
        var longitude: Double
        var sigma: Double?
    }

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

        for input in inputs {
            let arrival = input.arrival.nanoseconds
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
                let reason = NavigationReplay.withholdReason(sample, at: t, options: options, motionStart: motionStart)
                fixes.append(ReplayResult.Fix(
                    t: t.seconds, arrivalT: input.arrival.seconds,
                    latitude: sample.latitude, longitude: sample.longitude,
                    accuracyM: sample.horizontalAccuracy, withheld: reason
                ))
                if reason != nil { continue }
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
        while nextCheckpoint < schedule.count {
            score(schedule[nextCheckpoint])
            nextCheckpoint += 1
        }
        sampleTrack(at: lastNs, withEllipse: true)

        return finish(firstNs: firstNs, lastNs: lastNs)
    }

    func buildSchedule(lastNs: Int64) -> [Scheduled] {
        var schedule: [Scheduled] = []
        for input in inputs {
            switch input {
            case .location(let sample, let t):
                guard NavigationReplay.withholdReason(sample, at: t, options: options, motionStart: motionStart) != nil,
                      sample.horizontalAccuracy >= 0,
                      sample.horizontalAccuracy <= options.config.cleanFixAccM else { continue }
                schedule.append(Scheduled(t: t.nanoseconds, kind: .cleanFix, latitude: sample.latitude,
                                          longitude: sample.longitude, sigma: sample.horizontalAccuracy))
            case .manualFix(let sample, let t):
                schedule.append(Scheduled(t: t.nanoseconds, kind: .manualFix, latitude: sample.latitude,
                                          longitude: sample.longitude, sigma: options.config.manualFixSigma(mapSpanM: sample.mapSpanM)))
            default:
                continue
            }
        }
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
        let t = MonotonicTimestamp(nanoseconds: item.t)
        let travelled = distance.distance(at: item.t)
        var checkpoint = ReplayResult.Checkpoint(
            kind: item.kind, t: t.seconds, latitude: item.latitude, longitude: item.longitude,
            truthSigmaM: item.sigma, distanceM: travelled
        )
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
            checkpoint.headingStdDeg = estimate.headingStdDeg
            checkpoint.ellipseSemiMajorM = estimate.ellipse.semiMajorM
            checkpoint.ellipseSemiMinorM = estimate.ellipse.semiMinorM
            checkpoint.ellipseOrientationDeg = estimate.ellipse.orientationDeg
        }
        checkpoints.append(checkpoint)
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
        ellipses.append(ReplayResult.EllipseSample(
            t: t.seconds, latitude: estimate.latitude, longitude: estimate.longitude,
            semiMajorM: e.semiMajorM, semiMinorM: e.semiMinorM, orientationDeg: e.orientationDeg, ring: ring
        ))
    }

    func finish(firstNs: Int64, lastNs: Int64) -> ReplayResult {
        let scored = checkpoints.filter { $0.errorM != nil }
        let worst = scored.max { $0.errorM! < $1.errorM! }
        let endCheckpoint = checkpoints.last { $0.kind == .truthEnd } ?? scored.last
        let convergence = Self.convergence(track, holdS: options.convergenceHoldS)
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
            steps: steps,
            msPerStep: steps > 0 ? Double(engineNs) / 1e6 / Double(steps) : 0,
            maxIngestMs: Double(maxIngestNs) / 1e6,
            counters: engine.counters,
            fixes: fixes,
            track: track,
            ellipses: ellipses
        )
    }

    /// The first track point from which `converged` holds for `holdS`
    /// seconds (to the end of the track if it ends sooner while converged
    /// for at least `holdS`).
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
/// added to the ellipse.
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

    public init(_ checkpoints: [ReplayResult.Checkpoint]) {
        var all = Count(inside: 0, scored: 0)
        var byKind: [String: Count] = [:]
        for checkpoint in checkpoints {
            guard let inside = checkpoint.inside95 else { continue }
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
