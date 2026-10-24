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
    /// The road network the engine matches against (`replay_nav --roads`,
    /// N3.2); nil runs no road code at all, and every output is as before
    /// roads existed.
    public var roads: ReplayRoadSet?
    /// When the engine gets `roads` (N3.3): from the start (N3.2), the
    /// live rule, or after a sidecar's `afterInputs`. Unused without roads.
    public var roadAttach = ReplayRoadAttach.fromStart
    /// `replay_nav --wrong-road-tolerance`: a matched edge that is not the
    /// truth's road still counts as right when the truth fix is within this
    /// many metres of it (parallel geometry of one road, junction stubs).
    /// Scoring only, used only with `roads`.
    public var wrongRoadToleranceM = NavigationReplay.defaultWrongRoadToleranceM
    /// `replay_nav --inject-roads` (prompt 38, replay only): packs of
    /// `roads` that the live rule cannot select until the given input or
    /// time, when they arrive as a library change (`ReplayRoadInjection`).
    /// Used only with `roadAttach` `.live`; empty: every pack is ready at
    /// the start, as before.
    public var roadInjections: [ReplayRoadInjection] = []
    /// UX-20, replay only (`replay_nav --start-at`): inputs arriving before
    /// this session time are dropped (the app was not running); the label
    /// gets `-from-<s>`. nil: every input.
    public var startAtS: Double?
    /// UX-20, replay only (`replay_nav --prior`): the engine is seeded from
    /// this restored prior at its first input
    /// (`NavigationEngine(config:roads:prior:)`); the label gets
    /// `-restored`. nil: as before. Prompt 40: also the recording's own
    /// `navPrior` row (`ReplayRecordedPrior`, `priorSource` `.recording`),
    /// the start condition the live run had; the label then gets `-prior`.
    public var prior: NavigationPrior?
    /// Where `prior` comes from; the label part only.
    public var priorSource = ReplayPriorSource.savedState
    /// UX-20, replay only (`replay_nav --save-prior-at`): capture the
    /// restore state (`NavigationRestoreState.capture`) at this time;
    /// `ReplayResult.savedRestoreState`. Changes no number.
    public var savePrior: ReplaySavePrior?

    public init(gps: GPSMode, holdOutAccuracyM: Double? = nil, config: NavigationConfig = NavigationConfig()) {
        self.gps = gps
        self.holdOutAccuracyM = holdOutAccuracyM
        self.config = config
    }

    /// The mode: the `metrics.json` key with the log name, and the GeoJSON
    /// file name. Every option that changes a run's numbers and is not a
    /// config field gets its own part, so two such runs never overwrite
    /// each other's row in one `--out`; at their defaults the parts are
    /// absent and the label is as before them.
    /// - `-pair-window-<s>`: a `pinPairWindowS` other than the default
    ///   (R18.1-3).
    /// - `-attach-sidecar`: roads attached at a sidecar's `afterInputs`
    ///   (`--compare`), and `-attach-live`: the live rule without
    ///   `--as-live` (`--compare` with a sidecar that used no roads), so
    ///   neither overwrites the from-start or `--as-live` row (R32.1-5).
    ///   `--as-live` already names the live rule.
    /// - `-inject-<hash>-<when>` per `roadInjections` entry (prompt 38).
    public var label: String {
        var label = gps.label
        if let holdOutAccuracyM { label += "-holdout-\(GPSMode.format(holdOutAccuracyM))" }
        if asLive { label += "-as-live" } else if fileOrder { label += "-file-order" }
        if pinPairWindowS != NavigationReplay.defaultPinPairWindowS {
            label += "-pair-window-\(GPSMode.format(pinPairWindowS))"
        }
        if let roads {
            label += "-" + roads.labelSuffix
            switch roadAttach {
            case .fromStart: break
            case .live: if !asLive { label += "-attach-live" }
            case .afterInputs, .schedule: label += "-attach-sidecar"
            }
            if roadAttach == .live {
                for injection in roadInjections { label += "-" + injection.label }
            }
        }
        if let startAtS { label += "-from-\(GPSMode.format(startAtS))" }
        if prior != nil { label += priorSource == .recording ? "-prior" : "-restored" }
        return label
    }
}

/// Where a replay's `ReplayOptions.prior` comes from (its label part).
public enum ReplayPriorSource: String, Hashable, Sendable {
    /// `replay_nav --prior <state.json>`: a saved restore state; `-restored`.
    case savedState
    /// The recording's own `navPrior` row (prompt 40); `-prior`.
    case recording
}

/// What a replay does with a recording's `navPrior` row (format v5, the
/// Navigate → Record hand-over, prompt 40): `replay_nav` starts the engine
/// from it, as the live run did, unless `--prior` replaces it or
/// `--no-prior` drops it. A recording without the row is `.absent` and its
/// replay is exactly what it was before v5.
public enum ReplayRecordedPrior: Hashable, Sendable {
    /// No `navPrior` row.
    case absent
    /// The row's prior (`NavPriorSample.navigationPrior`) starts the run.
    case used(NavigationPrior)
    /// `--prior` given: the saved state replaces the row.
    case overridden
    /// `--no-prior`: the row is ignored, the run starts fresh.
    case ignored
    /// The row starts nothing (`NavPriorSample.invalidField`), live and in
    /// the replay alike.
    case invalid(field: String)
    /// R78.2-2, `--start-at` past the row's start input (`atCut`): the
    /// estimate at the cut starts the cut, as a Record started at `atS`
    /// from Navigate would: the hand-over the app would write
    /// (`NavPriorSample(handOver:clock:)`) from this replay's run of the
    /// inputs before `atS`, started from the row.
    case cut(NavigationPrior, atS: Double)
    /// R78.2-2: the run before the cut had no estimate to hand over (no
    /// position before `atS`, or its state not a valid row): the cut starts
    /// fresh, as `--no-prior`, never from the stale drive-start prior.
    case noEstimateAtCut(atS: Double)

    /// The choice for `row` (`NavigationReplay.recordedPrior(in:)`).
    /// `explicitPrior`: `--prior` was given; `noPrior`: `--no-prior`.
    /// `--prior` wins over `--no-prior` (which only drops the row).
    public static func choose(row: NavPriorSample?, explicitPrior: Bool, noPrior: Bool) -> Self {
        guard let row else { return .absent }
        if explicitPrior { return .overridden }
        if noPrior { return .ignored }
        guard let prior = row.navigationPrior else { return .invalid(field: row.invalidField ?? "restoreClass") }
        return .used(prior)
    }

    /// The prior the run starts from because of the row; nil otherwise.
    public var prior: NavigationPrior? {
        switch self {
        case .used(let prior), .cut(let prior, _): prior
        default: nil
        }
    }

    /// R78.2-2: the choice for a replay cut at `startAtS` (`--start-at`):
    /// `.used` whose prior applies at an input before the cut becomes the
    /// estimate at the cut (`.cut`), or `.noEstimateAtCut` when there is
    /// none; anything else is returned unchanged (`.used` with nothing the
    /// engine uses before the cut: the cut keeps the row's prior; no row,
    /// `--prior`, `--no-prior`, an invalid row: as without the cut).
    /// The estimate comes from `NavigationReplay.run` over `inputs`
    /// arriving before the cut with `options` (the cut's: same config,
    /// seed, GPS mode, roads, order; `startAtS`, `savePrior` and the prior
    /// replaced) started from the row, captured at its last step as the
    /// app's hand-over (`ReplaySavePrior.handOver`) and converted as the
    /// app writes a `navPrior` row (`NavPriorSample(handOver:clock:)`),
    /// on `clock` (the recording's, `SessionClock(header:)`). Causal: the
    /// run sees nothing at or after the cut. Replay only.
    public func atCut(startAtS: Double, inputs: [NavigationInput], options: ReplayOptions,
                      clock: SessionClock) -> Self {
        guard case .used(let prior) = self else { return self }
        let cut = MonotonicTimestamp(seconds: startAtS)
        guard let start = startInput(in: inputs), start < cut else { return self }
        var before = options
        before.startAtS = nil
        before.prior = prior
        before.priorSource = .recording
        var save = ReplaySavePrior(atS: .infinity, referenceUptimeSeconds: clock.referenceUptimeSeconds,
                                   wallClockStart: clock.wallClockStart)
        save.handOver = true
        before.savePrior = save
        let result = NavigationReplay.run(logName: "before-cut", inputs: inputs.filter { $0.arrival < cut },
                                          options: before)
        guard let state = result.savedRestoreState,
              let handed = NavPriorSample(handOver: state, clock: clock)?.navigationPrior else {
            return .noEstimateAtCut(atS: startAtS)
        }
        return .cut(handed, atS: startAtS)
    }

    /// The input the prior is applied at: the first one (not a
    /// GPS switch) arriving at or after the estimate's time; earlier ones
    /// (the init replay's readings) are ignored by the engine.
    public func startInput(in inputs: [NavigationInput]) -> MonotonicTimestamp? {
        guard let prior else { return nil }
        return inputs.first { !$0.isGPSSwitch && $0.arrival >= prior.savedT }?.arrival
    }

    /// The line `replay_nav` prints, nil for `.absent`. Times relative to
    /// `firstInput` (`startInput(in:)`), never a position.
    public func note(firstInput: MonotonicTimestamp?) -> String? {
        switch self {
        case .absent:
            return nil
        case .used(let prior):
            let gap = firstInput.map { String(format: ", %.2f s before the input it starts at (t %.2f s)",
                                              $0.seconds - prior.savedT.seconds, $0.seconds) } ?? ""
            return "Prior         the recording's navPrior row (hand-over): estimate at t "
                + String(format: "%.3f s", prior.savedT.seconds) + gap
                + ", class \(prior.restoreClass.rawValue), converged \(prior.converged)"
                + String(format: ", σhead %.1f°", prior.headingStdDeg)
        case .overridden:
            return "note: --prior replaces the recording's navPrior row (the live run started from the row)"
        case .ignored:
            return "note: --no-prior: the recording's navPrior row is ignored; the run starts fresh (not as live)"
        case .invalid(let field):
            return "note: the recording's navPrior row is invalid (\(field)): no prior, as the live run"
        case .cut(let prior, let atS):
            let gap = firstInput.map { String(format: ", %.2f s before the input the cut starts at (t %.2f s)",
                                              $0.seconds - prior.savedT.seconds, $0.seconds) } ?? ""
            return "Prior         the estimate at the cut (--start-at \(GPSMode.format(atS)) s, hand-over from this replay's run "
                + "of the inputs before it, started from the recording's navPrior row): estimate at t "
                + String(format: "%.3f s", prior.savedT.seconds) + gap
                + ", class \(prior.restoreClass.rawValue), converged \(prior.converged)"
                + String(format: ", σhead %.1f°", prior.headingStdDeg)
        case .noEstimateAtCut(let atS):
            return "note: --start-at \(GPSMode.format(atS)) s: no estimate at the cut (the run of the inputs before it, "
                + "started from the recording's navPrior row, had no position to hand over); the cut starts fresh, "
                + "as --no-prior, not from the drive-start prior"
        }
    }
}

/// When and with which clock a replay captures the restore state
/// (`replay_nav --save-prior`, UX-20).
public struct ReplaySavePrior: Hashable, Sendable {
    /// Session seconds; `.infinity`: at the last input.
    public var atS: Double
    /// The recording's clock (`SessionClock(header:)`'s two values).
    public var referenceUptimeSeconds: Double
    public var wallClockStart: Date
    /// The car's engine is known to be off (`restoreClass`).
    public var engineOff: Bool
    /// R78.2-2: capture as the app's Navigate → Record hand-over does
    /// (`NavigationService.publishHandOver`): stamped at the engine's last
    /// step (`lastStepTime`), not at `atS`; nothing before initialisation;
    /// `converged` false while the run is itself an unconfirmed restore.
    /// `ReplayRecordedPrior.atCut` uses it; false: as before.
    public var handOver = false

    public init(atS: Double, referenceUptimeSeconds: Double, wallClockStart: Date, engineOff: Bool = false) {
        self.atS = atS
        self.referenceUptimeSeconds = referenceUptimeSeconds
        self.wallClockStart = wallClockStart
        self.engineOff = engineOff
    }

    public init(atS: Double, header: LogHeader, engineOff: Bool = false) {
        self.init(atS: atS, referenceUptimeSeconds: header.referenceUptimeSeconds, wallClockStart: header.startedAt,
                  engineOff: engineOff)
    }

    var clock: SessionClock {
        SessionClock(referenceUptimeSeconds: referenceUptimeSeconds, wallClockStart: wallClockStart)
    }
}

/// When a replay's engine gets its road network (N3.3).
public enum ReplayRoadAttach: Hashable, Sendable {
    /// From the first input: `NavigationEngine(config:roads:)`, the N3.2
    /// replays. Not what the app does.
    case fromStart
    /// As the app with its packs ready (`replay_nav --as-live --roads`):
    /// the engine starts without roads; at each selection request
    /// (`RoadSelectionRule`) the packs covering the request's circle are
    /// selected from the given ones (`RoadPackSelector`) and attached at
    /// once, at that input boundary.
    case live
    /// The whole given set, attached after this many inputs given to the
    /// engine (one `roads` line of the whole set).
    case afterInputs(Int)
    /// A sidecar's `roads` lines (`replay_nav --compare`, prompt 38): each
    /// point's packs, taken from the given set (the same open instances),
    /// attached after that many inputs, the first by `attachRoads`, each
    /// later one by `extendRoads`. A point whose packs are not all given is
    /// skipped.
    case schedule([ReplayRoadAttachPoint])

    /// The attach points this mode follows; nil for `.fromStart` and
    /// `.live`. `.afterInputs(k)` is one point of the whole given set.
    func points(given: ReplayRoadSet?) -> [ReplayRoadAttachPoint]? {
        switch self {
        case .fromStart, .live: nil
        case .afterInputs(let k): [ReplayRoadAttachPoint(afterInputs: k, contentHashes: given?.network.packs.map(\.contentHash) ?? [])]
        case .schedule(let points): points
        }
    }
}

/// One `roads` line of a sidecar as a replay follows it: after how many
/// inputs, and which packs (content hashes).
public struct ReplayRoadAttachPoint: Hashable, Sendable {
    public var afterInputs: Int
    public var contentHashes: [UInt64]

    public init(afterInputs: Int, contentHashes: [UInt64]) {
        self.afterInputs = afterInputs
        self.contentHashes = contentHashes
    }

    /// From a sidecar `roads` line; nil when a hash is not 16 hex digits.
    public init?(_ line: NavSidecar.Roads) {
        var hashes: [UInt64] = []
        for pack in line.roads {
            guard pack.contentHash.count == 16, let value = UInt64(pack.contentHash, radix: 16) else { return nil }
            hashes.append(value)
        }
        self.init(afterInputs: line.afterInputs, contentHashes: hashes)
    }
}

/// A pack that becomes selectable only during the run (`replay_nav
/// --inject-roads`, prompt 38, replay only): the app's library change, at a
/// given input or time. At that boundary the selector gets the packs, the
/// run watches them and raises a `libraryChanged` request, which the live
/// rule answers at once (an attach, or an extension of the attached set).
public struct ReplayRoadInjection: Hashable, Sendable {
    public enum When: Hashable, Sendable {
        /// Before the first input (accepted by the engine) arriving at or
        /// after this session time, seconds.
        case time(seconds: Double)
        /// Before input number n + 1 given to the engine (after n).
        case afterInputs(Int)
    }

    public var when: When
    /// The packs' content hashes; they must be in the given set.
    public var contentHashes: [UInt64]

    public init(when: When, contentHashes: [UInt64]) {
        self.when = when
        self.contentHashes = contentHashes
    }

    /// The mode label's part: `inject-<first 8 hex of the packs' road set
    /// hash>-at-<s>s` or `-after-<n>`.
    public var label: String {
        let hash = String(NavigationSeed.hex(RoadPackFormat.roadSetHash(contentHashes.sorted())).prefix(8))
        switch when {
        case .time(let seconds): return "inject-\(hash)-at-\(GPSMode.format(seconds))s"
        case .afterInputs(let n): return "inject-\(hash)-after-\(n)"
        }
    }

    /// Whether it is due before an input arriving at `arrival` (accepted by
    /// the engine), with `given` inputs given so far.
    func isDue(given: Int, arrival: MonotonicTimestamp) -> Bool {
        switch when {
        case .time(let seconds): arrival.seconds >= seconds
        case .afterInputs(let n): given == n
        }
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

    /// The state a Navigate run hands to a Record started now, as the app's
    /// `NavigationService.publishHandOver`: the engine's estimate at its
    /// last step (`lastStepTime`), nil before initialisation; `converged`
    /// false while the run is itself an unconfirmed restore (Record then
    /// stays unconfirmed). Replay only (`ReplaySavePrior.handOver`, R78.2-2).
    public static func handOverState(_ engine: NavigationEngine, clock: SessionClock) -> NavigationRestoreState? {
        guard engine.isInitialized, let t = engine.lastStepTime else { return nil }
        var state = NavigationRestoreState.capture(engine, at: t, clock: clock, bootSessionID: nil, engineOff: false)
        if engine.restore.status == .unconfirmed { state?.converged = false }
        return state
    }

    /// The recording's `navPrior` row (format v5, prompt 40): the first one
    /// in file order, nil when there is none. A recorder writes at most one,
    /// before every engine input.
    public static func recordedPrior<S: Sequence>(in events: S) -> NavPriorSample? where S.Element == LogEvent {
        for event in events {
            if case .navPrior(let sample) = event.payload { return sample }
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
        let kinds: Set<String> = ["motion", "location", "obd", "manualFix", "gpsSwitch"]
        return events.compactMap { event in
            guard case .lifecycle(let sample) = event.payload, sample.event == LifecycleSample.Event.error.rawValue,
                  let detail = sample.detail, detail.hasPrefix("encodingFailed ") else { return nil }
            let kind = String(detail.dropFirst("encodingFailed ".count).prefix { $0 != ":" })
            return kinds.contains(kind) ? (event.timestamp, kind) : nil
        }
    }

    /// The sidecar lines `LiveNavigationRun` produces for `inputs` (in the
    /// order given), as the app would have written them with no drops: the
    /// reference for `--compare`. `roads`/`attach`: see `runLive`.
    public static func liveLines(
        inputs: [NavigationInput], sessionID: UUID, config: NavigationConfig, appBuild: String = "replay",
        roads: ReplayRoadSet? = nil, attach: ReplayRoadAttach = .live, injections: [ReplayRoadInjection] = [],
        prior: NavigationPrior? = nil
    ) -> [NavSidecar.Line] {
        var lines: [NavSidecar.Line] = []
        runLive(inputs: inputs, sessionID: sessionID, config: config, appBuild: appBuild, roads: roads,
                attach: attach, injections: injections, prior: prior) { lines.append($0) }
        return lines
    }

    /// The app's loop (`LiveNavigationRun`) over `inputs`; `emit` gets every
    /// sidecar line, the opening lines first. With `roads`: `.live` selects
    /// from them at each selection request (`RoadPackSelector`) and attaches
    /// at once, recording each attempt for the `roadsSelection` lines
    /// (repeats folded, the pending ones written last:
    /// `LiveNavigationRun.closingLines(inFlight:)`, as the app at stop),
    /// the given packs watched by the coverage trigger, and `injections`
    /// (packs held back until then, then a library change: watched, a
    /// `libraryChanged` request answered at once);
    /// `.afterInputs(k)` attaches the whole set after k inputs, and
    /// `.schedule` each point's packs after its inputs (the first attached,
    /// the later ones extending it); `.fromStart` gives it at init.
    /// `prior` (prompt 40): the recording's `navPrior` row
    /// (`NavPriorSample.navigationPrior`), the live run's start condition,
    /// as the app's `LiveNavigationRun(header:…prior:)`; nil: as before.
    /// Returns the finished run.
    @discardableResult
    public static func runLive(
        inputs: [NavigationInput], sessionID: UUID, config: NavigationConfig, appBuild: String = "replay",
        roads: ReplayRoadSet? = nil, attach: ReplayRoadAttach = .live, injections: [ReplayRoadInjection] = [],
        prior: NavigationPrior? = nil, emit: (NavSidecar.Line) -> Void
    ) -> LiveNavigationRun {
        var run = LiveNavigationRun(sessionID: sessionID, config: config, appBuild: appBuild,
                                    roads: attach == .fromStart ? roads?.network : nil, prior: prior)
        for line in run.openingLines { emit(line) }
        guard let roads, attach != .fromStart else {
            for input in inputs { run.ingest(input, emit: emit) }
            return run
        }
        if let points = attach.points(given: roads) {
            var next = 0
            func attachIfDue() {
                while next < points.count && points[next].afterInputs == run.inputs {
                    if let network = roads.network(containing: points[next].contentHashes).network {
                        try? run.attachOrExtendRoads(network, emit: emit)
                    }
                    next += 1
                }
                while next < points.count && points[next].afterInputs < run.inputs { next += 1 }
            }
            for input in inputs {
                attachIfDue()
                run.ingest(input, emit: emit)
            }
            attachIfDue()
            return run
        }
        let held = Set(injections.flatMap(\.contentHashes))
        var selector = roads.selector(excluding: held)
        var pending = injections
        for input in inputs {
            if !pending.isEmpty && run.engine.accepts(input) {
                for injection in pending where injection.isDue(given: run.inputs, arrival: input.arrival) {
                    selector.add(roads.candidates(for: Set(injection.contentHashes)), sortByName: roads.namedByFile)
                    run.libraryChanged(selector.watchedPacks)
                    run.select(with: &selector, emit: emit)
                }
                pending.removeAll { $0.isDue(given: run.inputs, arrival: input.arrival) }
            }
            run.ingest(input, selector: &selector, emit: emit)
        }
        for line in run.closingLines(inFlight: nil) { emit(line) }
        return run
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

    /// How a checkpoint after the truth file's `scoreUntilT` is labelled.
    public static let afterScoreUntilText = "after scoreUntilT, not scored"

    /// Default `ReplayOptions.wrongRoadToleranceM`, metres (docs/N3_PLAN.md,
    /// "Metrics added to replay_nav").
    public static let defaultWrongRoadToleranceM = 20.0

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
        // `--start-at`: the app was not running before then.
        let given = options.startAtS.map { start in
            inputs.filter { $0.arrival >= MonotonicTimestamp(seconds: start) }
        } ?? inputs
        var run = ReplayRun(logName: logName, inputs: given, options: options, truth: truth)
        return run.execute()
    }
}

// MARK: - Result

public struct ReplayResult: Hashable, Sendable, Codable {
    public struct Checkpoint: Hashable, Sendable, Codable {
        public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
            /// A withheld GNSS fix at or under the frozen
            /// `NavigationReplay.cleanFixTruthAccM` (15 m), not the run's
            /// `cleanFixAccM` (R19.2-1).
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
        /// The truth's own error, metres, as given by the truth: a clean
        /// fix's `horizontalAccuracy` (68 % radius), a manual fix's frozen
        /// truth σ (`NavigationReplay.manualFixTruthSigmaM`, not the σ the
        /// run's config gives the engine, R19.1-1), a truth-file `sigmaM`.
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
        /// true for a checkpoint after the truth file's `scoreUntilT` (any
        /// kind): its error is still measured and listed, but it counts in
        /// no aggregate. Optional so older metrics.json files decode; nil
        /// (absent) for every checkpoint at or before the cutoff and in every
        /// run without one.
        public var afterScoreUntilT: Bool?

        /// Whether the checkpoint counts in max/end error, consistency and
        /// every other aggregate.
        public var isScored: Bool { notScored == nil && afterScoreUntilT != true }

        /// Why the checkpoint is not scored, for reports: "refinement of t
        /// 706.3 s, not scored", "after scoreUntilT, not scored", or both
        /// joined; nil for a scored checkpoint.
        public var notScoredText: String? {
            switch (notScored, afterScoreUntilT == true) {
            case (nil, false): nil
            case (let reason?, false): reason.text
            case (nil, true): NavigationReplay.afterScoreUntilText
            case (let reason?, true): reason.text + "; " + NavigationReplay.afterScoreUntilText
            }
        }
    }

    /// The truth file's `excludeFixes` in a run: its ranges and how many
    /// location fixes they covered (`TruthFile.ExcludedFixRange`). Scoring
    /// only: the engine received exactly the fixes the GPS mode gives it.
    public struct FixExclusion: Hashable, Sendable, Codable {
        public var ranges: [TruthFile.ExcludedFixRange]
        /// Location fixes in the ranges, used or withheld, any accuracy.
        public var fixes: Int
        /// Of those, at or under `NavigationReplay.cleanFixTruthAccM`: kept
        /// out of the offline road truth (residuals) and, when withheld, out
        /// of the checkpoints.
        public var cleanFixes: Int
        /// Withheld clean fixes that are not clean-fix checkpoints because
        /// of the ranges.
        public var cleanFixCheckpoints: Int

        public init(ranges: [TruthFile.ExcludedFixRange], fixes: Int = 0, cleanFixes: Int = 0,
                    cleanFixCheckpoints: Int = 0) {
            self.ranges = ranges
            self.fixes = fixes
            self.cleanFixes = cleanFixes
            self.cleanFixCheckpoints = cleanFixCheckpoints
        }

        /// "t -1.0 … 251.0 s (reason): 840 fixes, 812 clean (≤ 15 m), 0
        /// withheld clean-fix checkpoints; never truth".
        public var text: String {
            ranges.map { String(format: "t %.1f … %.1f s", $0.fromT, $0.toT) + ($0.reason.map { " (\($0))" } ?? "") }
                .joined(separator: ", ")
                + ": \(fixes) fix\(fixes == 1 ? "" : "es"), \(cleanFixes) clean (≤ \(GPSMode.format(NavigationReplay.cleanFixTruthAccM)) m), "
                + "\(cleanFixCheckpoints) withheld clean-fix checkpoint\(cleanFixCheckpoints == 1 ? "" : "s"); never truth"
        }
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
        /// Pins the pair and exclusion rules would score that are after the
        /// truth file's `scoreUntilT`, so not scored (not in `scored`).
        /// nil (absent) in a run without a cutoff and in older files.
        public var afterScoreUntil: Int?

        public init(pairWindowS: Double, manualFixes: Int = 0, scored: Int = 0, refinements: Int = 0,
                    excluded: Int = 0, unmatchedExclusionsT: [Double] = [], afterScoreUntil: Int? = nil) {
            self.pairWindowS = pairWindowS
            self.manualFixes = manualFixes
            self.scored = scored
            self.refinements = refinements
            self.excluded = excluded
            self.unmatchedExclusionsT = unmatchedExclusionsT
            self.afterScoreUntil = afterScoreUntil
        }

        /// "12 manual fixes: 7 scored, 3 refinements folded into pairs (pair window 3 s), 2 excluded by truth".
        public var text: String {
            "\(manualFixes) manual fix\(manualFixes == 1 ? "" : "es"): \(scored) scored, \(refinements) refinement\(refinements == 1 ? "" : "s") folded into pairs (pair window "
                + (pairWindowS > 0 ? "\(GPSMode.format(pairWindowS)) s" : "off") + "), \(excluded) excluded by truth"
                + (afterScoreUntil.map { ", \($0) after scoreUntilT" } ?? "")
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

    /// The engine's matched road edge at an ellipse sample (every
    /// `ellipseIntervalS`), with roads only (N3.2b; GeoJSON `matchedEdge`).
    public struct MatchedEdgeSample: Hashable, Sendable, Codable {
        public var t: Double
        public var onRoadShare: Double?
        public var edge: MatchedRoadEdge
        /// OSM `highway` value, `_link` appended for a link.
        public var roadClass: String
        /// The edge's shape, (latitude, longitude) pairs in order.
        public var points: [[Double]]
    }

    public struct Fix: Hashable, Sendable, Codable {
        public var t: Double
        public var arrivalT: Double
        public var latitude: Double
        public var longitude: Double
        public var accuracyM: Double
        /// nil: given to the engine.
        public var withheld: WithholdReason?
        /// Given to the engine and ignored as off-road (the road fix gate,
        /// `fixesRejectedOffRoad`); nil otherwise.
        public var rejectedOffRoad: Bool? = nil
        /// Given to the engine while the driver's GPS switch was off and
        /// withheld by it (UX-9 a, `NavigationEngine.fixesWithheldByGPSSwitch`);
        /// nil otherwise. Not a checkpoint: `withheld` is the replay's own
        /// choice, this is the recording's.
        public var withheldByGPSSwitch: Bool? = nil
    }

    /// The driver's GPS switch in a recording (UX-9 a, log v4): when GPS
    /// was off and how many fixes the engine withheld because of it.
    public struct GPSSwitchReport: Hashable, Sendable, Codable {
        public struct Interval: Hashable, Sendable, Codable {
            /// The switch-off input's `t`, s.
            public var offT: Double
            /// The switch-on input's `t`, s; nil: still off at the end.
            public var onT: Double?

            public init(offT: Double, onT: Double? = nil) {
                self.offT = offT
                self.onT = onT
            }
        }

        /// Off intervals, in order (a repeat of the current state is not a
        /// change).
        public var offIntervals: [Interval]
        /// `NavigationEngine.fixesWithheldByGPSSwitch` at the end.
        public var fixesWithheld: Int
        /// Switch inputs given to the engine, repeats included.
        public var switches: Int

        public init(offIntervals: [Interval] = [], fixesWithheld: Int = 0, switches: Int = 0) {
            self.offIntervals = offIntervals
            self.fixesWithheld = fixesWithheld
            self.switches = switches
        }

        /// "GPS off 2 interval(s): t 120.0 … 180.5 s, t 300.0 s … end; 57 fixes withheld by the switch (not checkpoints); 3 switch inputs".
        public var text: String {
            let intervals = offIntervals.map {
                String(format: "t %.1f", $0.offT) + ($0.onT.map { String(format: " … %.1f s", $0) } ?? " s … end")
            }
            return "GPS off \(offIntervals.count) interval\(offIntervals.count == 1 ? "" : "s")"
                + (intervals.isEmpty ? "" : ": " + intervals.joined(separator: ", "))
                + "; \(fixesWithheld) fix\(fixesWithheld == 1 ? "" : "es") withheld by the switch (not checkpoints)"
                + "; \(switches) switch input\(switches == 1 ? "" : "s")"
        }
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
    /// Largest checkpoint error (m) over every scored checkpoint, pins and
    /// truth points included, and its percentage of distance so far.
    /// Per kind, and the largest percentage: `maxErrorByKind`.
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

    /// The truth file's `scoreUntilT`, session seconds: checkpoints after it
    /// are listed (`afterScoreUntilT`) but not scored. nil: no cutoff.
    public var scoreUntilT: Double? = nil
    /// Checkpoints after `scoreUntilT`; nil without a cutoff.
    public var checkpointsAfterScoreUntil: Int? = nil

    /// What the truth file's `excludeFixes` kept from being truth; nil
    /// without it.
    public var fixesExcludedByTruth: FixExclusion? = nil

    /// The worst scored checkpoint per kind (`Checkpoint.Kind` raw value;
    /// a kind with no scored checkpoint with an error is absent), R19.1-2.
    /// `cleanFix`'s `maxPercent` is the gated figure of drive-7 and drive-8.
    public var maxErrorByKind: [String: KindMaxError] = [:]

    /// The road set the engine used (N3.2): per pack in canonical order
    /// (ascending content hash), and FNV-1a 64 over their content hashes.
    /// nil without roads.
    public var roads: [ReplayRoadPack]? = nil
    public var roadSetHash: String? = nil
    /// The road metrics (docs/N3_PLAN.md, "Metrics added to replay_nav");
    /// nil without roads.
    public var roadMetrics: ReplayRoadMetrics? = nil
    /// The matched edge every `ellipseIntervalS` (GeoJSON only); empty
    /// without roads.
    public var matchedEdges: [MatchedEdgeSample] = []
    /// With roads attached as live (N3.3, `ReplayRoadAttach.live` or
    /// `.afterInputs`): the number of inputs given to the engine before the
    /// network was attached, and the attached set's roadSetHash (a live
    /// selection may attach a subset of `roads`); nil when none was
    /// attached, and for `.fromStart`.
    public var roadsAttachedAfterInputs: Int? = nil
    public var attachedRoadSetHash: String? = nil
    /// Prompt 38: the inputs given before each extension of the attached
    /// network (`attachedRoadSetHash` is then the final set's); empty when
    /// it was never extended.
    public var roadsExtendedAfterInputs: [Int] = []
    /// UX-9 a: the recording's GPS switch; nil without a `gpsSwitch` input.
    public var gpsSwitch: GPSSwitchReport? = nil
    /// UX-20: the restore's outcome with `ReplayOptions.prior`; nil without.
    public var restore: NavigationRestore? = nil
    /// UX-20: the state captured at `ReplayOptions.savePrior`; nil without
    /// it, and when the engine had no estimate then.
    public var savedRestoreState: NavigationRestoreState? = nil

    public var heldOutFixes: [Fix] { fixes.filter { $0.withheld == .heldOut } }
}

/// A manual fix with the dead-reckoning estimate just before it.
public struct PinEstimate: Hashable, Sendable, Codable {
    public var pin: NavSidecar.Pin
    /// The prior's 95 % ellipse as (latitude, longitude) pairs, closed; nil
    /// when the pin initialised the engine.
    public var ring: [[Double]]?
    /// What the engine decided about each GNSS source at this pin
    /// (N3-FIXPIN); nil while both pin checks are off and when the pin
    /// initialised the engine.
    public var fixPin: FixPinDecision? = nil
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
    /// The truth file's `scoreUntilT` in nanoseconds: anything later is not
    /// scored. nil: no cutoff, and the run is exactly as before it existed.
    let scoreUntilNs: Int64?

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

    /// Withheld clean fixes the truth file's `excludeFixes` keeps from being
    /// checkpoints, by index in `inputs`.
    var excludedCheckpointInputs: Set<Int> = []

    /// Roads (N3.2): the offline truth matcher and what the run collects
    /// for the road metrics. nil / empty without roads.
    let roadTruth: RoadTruthMatcher?
    var roadMetrics: ReplayRoadMetrics?
    var onRoadShareSum = 0.0
    var matchedEdges: [ReplayResult.MatchedEdgeSample] = []

    /// Roads attached as live (`ReplayRoadAttach.live`, `.afterInputs`,
    /// `.schedule`): inputs given to the engine so far
    /// (`LiveNavigationRun.inputs`), the selection rule, the selector, when
    /// the network was attached and extended, and the attached packs'
    /// names (`LiveNavigationRun.roadPackNames`).
    var givenInputs = 0
    var selectionRule = RoadSelectionRule()
    var selector: RoadPackSelector?
    var attachedAfterInputs: Int?
    var extendedAfterInputs: [Int] = []
    var attachedNames: [String] = []
    /// `.afterInputs`, `.schedule`: the attach points not yet reached.
    var attachPoints: [ReplayRoadAttachPoint] = []
    /// `.live`: injections not yet due (`ReplayOptions.roadInjections`).
    var pendingInjections: [ReplayRoadInjection] = []
    /// UX-9 a: the GPS switch as given; nil until the first switch input.
    var gpsSwitch: ReplayResult.GPSSwitchReport?
    /// UX-20: the state captured at `options.savePrior`.
    var savedRestoreState: NavigationRestoreState?
    var restoreStateCaptured = false

    init(logName: String, inputs: [NavigationInput], options: ReplayOptions, truth: TruthFile.Entry?) {
        self.logName = logName
        self.inputs = inputs
        self.options = options
        self.truth = truth
        let fromStart = options.roadAttach == .fromStart
        engine = NavigationEngine(config: options.config, roads: fromStart ? options.roads?.network : nil,
                                  prior: options.prior)
        if let roads = options.roads, options.roadAttach == .live {
            // As `LiveNavigationRun.ingest(_:selector:emit:)`: the selector's
            // packs are watched from the first input on.
            let held = Set(options.roadInjections.flatMap(\.contentHashes))
            let selector = roads.selector(excluding: held)
            selectionRule.setWatchedPacks(selector.watchedPacks)
            self.selector = selector
            pendingInjections = options.roadInjections
        }
        attachPoints = options.roadAttach.points(given: options.roads) ?? []
        motionStart = NavigationReplay.motionStart(inputs)
        scoreUntilNs = truth?.scoreUntilT.map { MonotonicTimestamp(seconds: $0).nanoseconds }
        roadTruth = options.roads.map { RoadTruthMatcher(network: $0.network) }
        roadMetrics = options.roads.map { _ in ReplayRoadMetrics(wrongRoadToleranceM: options.wrongRoadToleranceM) }
    }

    mutating func execute() -> ReplayResult {
        // The timeline is the measurements': a GPS switch moves no clock.
        let firstNs = inputs.first { !$0.isGPSSwitch }?.arrival.nanoseconds ?? 0
        let lastNs = inputs.last { !$0.isGPSSwitch }?.arrival.nanoseconds ?? 0
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
            if case .gpsSwitch(_, let t) = input {
                // As `LiveNavigationRun.ingest`: handed to the engine only,
                // after the roads due before it (`runLive`); nothing is
                // scored, sampled or selected at it.
                attachIfDue()
                injectIfDue(arrival: input.arrival)
                applyGPSSwitch(input, at: t)
                givenInputs += 1
                continue
            }
            let arrival = input.arrival.nanoseconds
            if let save = options.savePrior, !restoreStateCaptured, save.atS.isFinite,
               arrival > MonotonicTimestamp(seconds: save.atS).nanoseconds {
                captureRestoreState(at: MonotonicTimestamp(seconds: save.atS))
            }
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
                if reason == nil {
                    attachIfDue()
                    engine.ingest(input)
                    givenInputs += 1
                }
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
            let pinIndex: Int?
            if case .manualFix(let sample, let t) = input {
                recordPin(sample, at: t)
                pinIndex = pins.count - 1
            } else {
                pinIndex = nil
            }
            if case .obd(let sample, let t) = input {
                distance.observe(sample, at: t.nanoseconds, maxAgeS: options.config.obdMaxAgeS,
                                 offsetKmh: options.config.obdSpeedOffsetKmh)
            }
            let rejectedBefore = engine.counters.fixesRejectedOffRoad
            let switchWithheldBefore = engine.fixesWithheldByGPSSwitch
            attachIfDue()
            injectIfDue(arrival: input.arrival)
            let before = RoadSelectionRule.Before(engine)
            let start = clock.now
            engine.ingest(input)
            let elapsed = clock.now - start
            givenInputs += 1
            selectLive(before: before)
            if engine.counters.fixesRejectedOffRoad != rejectedBefore, case .location = input {
                fixes[fixes.count - 1].rejectedOffRoad = true
            }
            if engine.fixesWithheldByGPSSwitch != switchWithheldBefore, case .location = input {
                fixes[fixes.count - 1].withheldByGPSSwitch = true
            }
            if let pinIndex { pins[pinIndex].fixPin = engine.lastFixPinDecision }
            let ns = elapsed.components.seconds * 1_000_000_000 + elapsed.components.attoseconds / 1_000_000_000
            engineNs += ns
            maxIngestNs = max(maxIngestNs, ns)
        }
        attachIfDue()
        // The end is the last input on the timeline: the last one, unless
        // trailing inputs were skipped (then the truth `end` is scored there).
        while nextCheckpoint < schedule.count {
            var item = schedule[nextCheckpoint]
            if item.kind == .truthEnd { item.t = endNs }
            score(item)
            nextCheckpoint += 1
        }
        sampleTrack(at: endNs, withEllipse: true)
        if let save = options.savePrior, !restoreStateCaptured {
            let atNs = save.atS.isFinite ? min(MonotonicTimestamp(seconds: save.atS).nanoseconds, endNs) : endNs
            captureRestoreState(at: MonotonicTimestamp(nanoseconds: atNs))
        }

        return finish(firstNs: firstNs, lastNs: endNs)
    }

    /// The restore state at `t`, from the state before the first input
    /// arriving after it (UX-20, `--save-prior`).
    mutating func captureRestoreState(at t: MonotonicTimestamp) {
        guard let save = options.savePrior else { return }
        restoreStateCaptured = true
        if save.handOver {
            savedRestoreState = NavigationReplay.handOverState(engine, clock: save.clock)
            return
        }
        savedRestoreState = NavigationRestoreState.capture(engine, at: t, clock: save.clock, bootSessionID: nil,
                                                           engineOff: save.engineOff)
    }

    /// A GPS switch input given to the engine, and the off intervals.
    mutating func applyGPSSwitch(_ input: NavigationInput, at t: MonotonicTimestamp) {
        let wasOn = engine.gpsOn
        engine.ingest(input)
        var report = gpsSwitch ?? ReplayResult.GPSSwitchReport()
        report.switches += 1
        if wasOn && !engine.gpsOn {
            report.offIntervals.append(.init(offT: t.seconds))
        } else if !wasOn && engine.gpsOn, !report.offIntervals.isEmpty {
            report.offIntervals[report.offIntervals.count - 1].onT = t.seconds
        }
        gpsSwitch = report
    }

    /// `.afterInputs(k)`, `.schedule`: each point's packs, before the
    /// engine's input `afterInputs` + 1 (the first attached, later ones
    /// extending it), as `NavigationReplay.runLive` does.
    mutating func attachIfDue() {
        while let point = attachPoints.first, point.afterInputs <= givenInputs {
            attachPoints.removeFirst()
            guard point.afterInputs == givenInputs,
                  let network = options.roads?.network(containing: point.contentHashes).network else { continue }
            apply(network)
        }
    }

    /// Attaches `network`, or extends the attached one to it; records when.
    /// Throws the engine's refusal.
    @discardableResult
    mutating func apply(_ network: RoadNetwork) -> RoadAttachRefusal? {
        do {
            if engine.roadNetwork == nil {
                try engine.attachRoads(network)
                attachedAfterInputs = givenInputs
            } else {
                try engine.extendRoads(network)
                extendedAfterInputs.append(givenInputs)
            }
            selectionRule.attached()
            return nil
        } catch {
            return error
        }
    }

    /// `.live`: a pack injected now arrives as a library change, before the
    /// next input (`LiveNavigationRun.libraryChanged` and `select(with:)`
    /// in `NavigationReplay.runLive`, on the same inputs).
    mutating func injectIfDue(arrival: MonotonicTimestamp) {
        guard !pendingInjections.isEmpty, let roads = options.roads else { return }
        let due = pendingInjections.filter { $0.isDue(given: givenInputs, arrival: arrival) }
        guard !due.isEmpty else { return }
        pendingInjections.removeAll { $0.isDue(given: givenInputs, arrival: arrival) }
        for injection in due {
            selector?.add(roads.candidates(for: Set(injection.contentHashes)), sortByName: roads.namedByFile)
            guard let packs = selector?.watchedPacks,
                  let request = selectionRule.libraryChanged(packs, engine: engine, inputs: givenInputs) else { continue }
            select(request)
        }
    }

    /// `.live`: the rule `LiveNavigationRun.ingest(_:droppedInputs:selector:emit:)`
    /// applies, on the same inputs.
    mutating func selectLive(before: RoadSelectionRule.Before) {
        guard selector != nil, let request = selectionRule.observe(engine, before: before, inputs: givenInputs) else {
            return
        }
        select(request)
    }

    /// The selector's attempt for `request`, attached or extending at once;
    /// a refused set is remembered (`LiveNavigationRun.select(with:)`).
    mutating func select(_ request: RoadSelectionRequest) {
        guard let attempt = selector?.attempt(for: request, attached: engine.roadNetwork, attachedNames: attachedNames),
              let network = attempt.network else { return }
        if let refusal = apply(network) {
            if case .notSuperset = refusal { return }
            selector?.remember(RoadPackSelection.Refusal(names: attempt.packs ?? [], reason: refusal.description))
        } else {
            attachedNames = attempt.packs ?? []
        }
    }

    /// An estimate whose matched edge is numbered in the engine's network,
    /// renumbered into the given set's (the truth matcher's): a live
    /// selection may attach a subset of the given packs.
    func inTruthFrame(_ estimate: NavigationEstimate) -> NavigationEstimate {
        guard var edge = estimate.matchedEdge, let attached = engine.roadNetwork, let given = options.roads?.network,
              attached !== given else { return estimate }
        let hash = attached.packs[edge.pack].contentHash
        guard let index = given.packs.firstIndex(where: { $0.contentHash == hash }) else { return estimate }
        edge.pack = index
        var out = estimate
        out.matchedEdge = edge
        return out
    }

    mutating func buildSchedule(lastNs: Int64) -> [Scheduled] {
        var schedule: [Scheduled] = []
        var manualIndices: [Int] = []
        for (index, input) in inputs.enumerated() {
            switch input {
            case .location(let sample, let t):
                guard NavigationReplay.withholdReason(sample, at: t, options: options, motionStart: motionStart) != nil,
                      sample.horizontalAccuracy >= 0,
                      sample.horizontalAccuracy <= NavigationReplay.cleanFixTruthAccM else { continue }
                // Truth `excludeFixes`: still withheld (or not) as the GPS
                // mode says, but never a checkpoint.
                if truth?.excludesFix(at: t) == true {
                    excludedCheckpointInputs.insert(index)
                    continue
                }
                schedule.append(Scheduled(t: t.nanoseconds, kind: .cleanFix, latitude: sample.latitude,
                                          longitude: sample.longitude, sigma: sample.horizontalAccuracy,
                                          inputIndex: index))
            case .manualFix(let sample, let t):
                manualIndices.append(schedule.count)
                schedule.append(Scheduled(t: t.nanoseconds, kind: .manualFix, latitude: sample.latitude,
                                          longitude: sample.longitude,
                                          sigma: NavigationReplay.manualFixTruthSigmaM(mapSpanM: sample.mapSpanM),
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
        // Pins the rules above score but the cutoff does not; nil without one.
        let afterCutoff = scoreUntilNs.map { cut in
            zip(manualIndices, decision.notScored).filter { $0.1 == nil && schedule[$0.0].t > cut }.count
        }
        pinScoring = ReplayResult.PinScoring(
            pairWindowS: max(0, options.pinPairWindowS), manualFixes: manualIndices.count,
            scored: decision.notScored.filter { $0 == nil }.count - (afterCutoff ?? 0),
            refinements: decision.notScored.filter { $0?.reason == .refinement }.count,
            excluded: decision.notScored.filter { $0?.reason == .excluded }.count,
            unmatchedExclusionsT: decision.unmatchedExclusions.map(\.t), afterScoreUntil: afterCutoff)
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
        // The cutoff is applied on the final `t` (a truth `end` moved to the
        // last input on the timeline included); exactly at it is scored.
        let afterCutoff = isAfterCutoff(item.t)
        if afterCutoff { checkpoint.afterScoreUntilT = true }
        let estimate = engine.estimate(at: t)
        if let estimate, let plane = engine.tangentPlane {
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
        if roadTruth != nil, !afterCutoff, item.kind == .cleanFix, let index = item.inputIndex,
           case .location(let sample, _) = inputs[index] {
            scoreRoad(sample, checkpoint: checkpoint, estimate: estimate.map(inTruthFrame))
        }
        checkpoints.append(checkpoint)
    }

    /// What the truth file's `excludeFixes` took out of truth; nil without
    /// a (non-empty) `excludeFixes`. Counts the location fixes on the
    /// replay's timeline (a skipped input, R14.2-3, is not counted).
    func fixExclusion() -> ReplayResult.FixExclusion? {
        guard let ranges = truth?.excludeFixes, !ranges.isEmpty else { return nil }
        var exclusion = ReplayResult.FixExclusion(ranges: ranges)
        for (index, input) in inputs.enumerated() where !skippedInputs.contains(index) {
            guard case .location(let sample, let t) = input, truth?.excludesFix(at: t) == true else { continue }
            exclusion.fixes += 1
            if sample.horizontalAccuracy >= 0, sample.horizontalAccuracy <= NavigationReplay.cleanFixTruthAccM {
                exclusion.cleanFixes += 1
            }
            if excludedCheckpointInputs.contains(index) { exclusion.cleanFixCheckpoints += 1 }
        }
        return exclusion
    }

    /// Whether session time `ns` is after the truth file's `scoreUntilT`
    /// (false without one).
    func isAfterCutoff(_ ns: Int64) -> Bool {
        scoreUntilNs.map { ns > $0 } ?? false
    }

    // MARK: Roads (N3.2b)

    /// The road side of a withheld clean fix: its offline truth edge, the
    /// engine's last road update at its time, the verdict, and whether it
    /// is unmapped (and captured).
    mutating func scoreRoad(_ sample: LocationSample, checkpoint: ReplayResult.Checkpoint,
                            estimate: NavigationEstimate?) {
        guard let matcher = roadTruth else { return }
        typealias T = NavigationReplay.RoadTruth
        let match = matcher.match(latitude: sample.latitude, longitude: sample.longitude,
                                  accuracyM: sample.horizontalAccuracy, courseDeg: NavigationReplay.RoadTruth.course(of: sample),
                                  courseAccuracyDeg: sample.courseAccuracy)
        var fix = ReplayRoadFix(t: checkpoint.t, distanceM: checkpoint.distanceM, accuracyM: sample.horizontalAccuracy,
                                truth: match.status)
        fix.nearestEdgeM = match.nearestM
        fix.unmappedReason = UnmappedReason.of(truth: match.status, nearestEdgeM: match.nearestM)
        fix.unmapped = fix.unmappedReason != nil
        if let edge = match.edge {
            fix.truthEdge = edge
            fix.truthClass = matcher.roadClass(of: edge)
            fix.crossTrackM = match.crossTrackM
            fix.logLikelihoodRatio = match.logLikelihoodRatio
        }
        if let estimate {
            fix.onRoadShare = estimate.onRoadShare
            fix.matchedEdge = estimate.matchedEdge
            fix.inside95 = checkpoint.inside95
            if let matched = estimate.matchedEdge {
                fix.matchedEdgeDistanceM = matcher.nearestSegment(latitude: sample.latitude, longitude: sample.longitude,
                                                                  of: matched).distance
                fix.crossTrackSemiAxisM = matcher.semiAxisAcross(estimate.ellipse, latitude: estimate.latitude,
                                                                 longitude: estimate.longitude, edge: matched)
            }
            if match.status == .matched, let truthEdge = match.edge {
                if let share = estimate.onRoadShare {
                    if share < T.onRoadShare {
                        fix.verdict = .off
                    } else if let matched = estimate.matchedEdge, matched.osmWayID == truthEdge.osmWayID
                                || (fix.matchedEdgeDistanceM ?? .infinity) <= options.wrongRoadToleranceM {
                        fix.verdict = .right
                    } else {
                        fix.verdict = .wrong
                    }
                } else {
                    fix.verdict = .notEngaged
                }
            }
            if fix.unmapped {
                let onEdge = (estimate.onRoadShare ?? 0) >= T.onRoadShare && estimate.matchedEdge != nil
                fix.captured = onEdge && (fix.crossTrackSemiAxisM ?? .infinity) < T.capturedCrossTrackM
                    && checkpoint.inside95 == false
            }
        }
        roadMetrics?.fixes.append(fix)
    }

    /// The road metrics' totals, once the run is over.
    func finishRoadMetrics() -> ReplayRoadMetrics? {
        guard var m = roadMetrics, let matcher = roadTruth else { return nil }
        // Weights: OBD distance since the previous fix with a usable course.
        var previous: Double?
        for i in m.fixes.indices where m.fixes[i].truth != .noCourse {
            m.fixes[i].weightM = previous.map { max(0, m.fixes[i].distanceM - $0) } ?? 0
            previous = m.fixes[i].distanceM
        }
        m.withheldCleanFixes = m.fixes.count
        m.unmappedNoRoadWithin15 = 0
        m.unmappedNoCompatibleRoadWithin15 = 0
        m.unmappedCapturedNoRoadWithin15 = 0
        m.unmappedCapturedNoCompatibleRoadWithin15 = 0
        for fix in m.fixes {
            m.truth[fix.truth.rawValue, default: 0] += 1
            if let verdict = fix.verdict {
                m.verdicts[verdict.rawValue, default: ReplayRoadMetrics.Count()].fixes += 1
                m.verdicts[verdict.rawValue, default: ReplayRoadMetrics.Count()].distanceM += fix.weightM
            }
            if fix.unmapped {
                m.unmapped += 1
                let far = fix.unmappedReason == .noRoadWithin15
                if far { m.unmappedNoRoadWithin15! += 1 } else { m.unmappedNoCompatibleRoadWithin15! += 1 }
                if let captured = fix.captured {
                    m.unmappedWithEstimate += 1
                    if captured {
                        m.unmappedCaptured += 1
                        if far { m.unmappedCapturedNoRoadWithin15! += 1 } else { m.unmappedCapturedNoCompatibleRoadWithin15! += 1 }
                    }
                }
            }
        }
        let matched = m.truth[RoadTruthStatus.matched.rawValue] ?? 0
        let ambiguous = m.truth[RoadTruthStatus.ambiguous.rawValue] ?? 0
        m.ambiguousShare = matched + ambiguous > 0 ? Double(ambiguous) / Double(matched + ambiguous) : nil
        let scored = m.scored
        let scoredDistance = WrongRoadVerdict.allCases.reduce(0.0) { $0 + m.count($1).distanceM }
        if scored > 0 {
            m.wrongShare = Double(m.count(.wrong).fixes) / Double(scored)
            m.offShare = Double(m.count(.off).fixes) / Double(scored)
        }
        if scoredDistance > 0 {
            m.wrongShareByDistance = m.count(.wrong).distanceM / scoredDistance
            m.offShareByDistance = m.count(.off).distanceM / scoredDistance
        }
        m.meanOnRoadShare = m.trackEngaged > 0 ? onRoadShareSum / Double(m.trackEngaged) : nil
        let c = engine.counters
        if c.roadUpdates > 0 {
            m.candidateTestsPerUpdate = Double(c.roadCandidateTests) / Double(c.roadUpdates)
            m.candidateTestsPerParticle = Double(c.roadCandidateTests) / Double(c.roadUpdates)
                / Double(max(1, options.config.particleCount))
        }
        m.rejectedFixes = fixes.filter { $0.rejectedOffRoad == true }.map { [$0.t, $0.accuracyM] }
        // Offline residuals: every clean fix of the recording on the
        // replay's timeline, used or withheld, with a usable course and a
        // matched truth edge, except those the truth file's `excludeFixes`
        // covers.
        var byClass: [String: [Double]] = [:]
        var all: [Double] = []
        for (index, input) in inputs.enumerated() where !skippedInputs.contains(index) {
            guard case .location(let sample, let t) = input, !isAfterCutoff(t.nanoseconds), sample.horizontalAccuracy >= 0,
                  sample.horizontalAccuracy <= NavigationReplay.cleanFixTruthAccM, truth?.excludesFix(at: t) != true,
                  let course = NavigationReplay.RoadTruth.course(of: sample) else { continue }
            let match = matcher.match(latitude: sample.latitude, longitude: sample.longitude,
                                      accuracyM: sample.horizontalAccuracy, courseDeg: course,
                                      courseAccuracyDeg: sample.courseAccuracy)
            guard match.status == .matched, let edge = match.edge, let d = match.crossTrackM else { continue }
            byClass[matcher.roadClass(of: edge), default: []].append(d)
            all.append(d)
        }
        m.residuals = byClass.compactMapValues { DistanceStats($0) }
        m.residualsAll = DistanceStats(all)
        return m
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
        if roadMetrics != nil, !isAfterCutoff(ns) {
            roadMetrics!.trackSamples += 1
            if let share = estimate.onRoadShare {
                roadMetrics!.trackEngaged += 1
                onRoadShareSum += share
                if share >= NavigationReplay.RoadTruth.onRoadShare { roadMetrics!.trackOnRoad += 1 }
            }
        }
        guard withEllipse else { return }
        if let matcher = roadTruth, let edge = inTruthFrame(estimate).matchedEdge {
            matchedEdges.append(ReplayResult.MatchedEdgeSample(
                t: t.seconds, onRoadShare: estimate.onRoadShare, edge: edge, roadClass: matcher.roadClass(of: edge),
                points: matcher.points(of: edge).map { [$0.latitude, $0.longitude] }
            ))
        }
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
        // A truth `end` after `scoreUntilT` is not scored: the last scored
        // checkpoint stands in, as when there is no truth `end`.
        let endCheckpoint = checkpoints.last { $0.kind == .truthEnd && $0.isScored } ?? scored.last
        // Heading convergence is judged on the track up to the cutoff.
        let scoredTrack = scoreUntilNs == nil ? track
            : track.filter { !isAfterCutoff(MonotonicTimestamp(seconds: $0.t).nanoseconds) }
        let convergence = NavigationReplay.convergence(scoredTrack, holdS: options.convergenceHoldS)
        let steps = engine.counters.steps
        var result = ReplayResult(
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
        result.fixesExcludedByTruth = fixExclusion()
        if var report = gpsSwitch {
            report.fixesWithheld = engine.fixesWithheldByGPSSwitch
            result.gpsSwitch = report
        }
        if options.prior != nil { result.restore = engine.restore }
        result.savedRestoreState = savedRestoreState
        result.maxErrorByKind = KindMaxError.byKind(checkpoints)
        if let scoreUntilT = truth?.scoreUntilT {
            result.scoreUntilT = scoreUntilT
            result.checkpointsAfterScoreUntil = checkpoints.filter { $0.afterScoreUntilT == true }.count
        }
        if let roads = options.roads {
            result.roads = roads.packs
            result.roadSetHash = roads.roadSetHashHex
            result.roadMetrics = finishRoadMetrics()
            result.matchedEdges = matchedEdges
            result.roadsAttachedAfterInputs = attachedAfterInputs
            result.attachedRoadSetHash = attachedAfterInputs == nil ? nil : engine.roadNetwork?.roadSetHashHex
            result.roadsExtendedAfterInputs = extendedAfterInputs
        }
        return result
    }

}

extension NavigationReplay {
    /// CoreLocation's `horizontalAccuracy` is a 68 % radius; for a circular
    /// Gaussian that is 1.51 σ per axis. Fixed here, not taken from the
    /// config (`fixSigmaPerAccuracy`), so a `--set` cannot move a clean
    /// fix's truth. A pin's truth σ is frozen the same way, below.
    public static let accuracyPerSigma = 1.51

    /// Largest `horizontalAccuracy` (m, inclusive) of a withheld fix that is
    /// scored as clean-fix truth. Frozen at `NavigationConfig.cleanFixAccM`'s
    /// value when Q3 was decided (N3.0); not read from the config (R19.2-1).
    ///
    /// Which fixes are truth is a property of the fixes, not of the run. The
    /// engine still calls a fix clean by its own `cleanFixAccM` (whether its
    /// course may set the heading), but a run that lowers it (`--set
    /// cleanFixAccM=…`, a sweep, a new default) must not drop its worst
    /// 10–15 m checkpoints from the max error and the consistency
    /// denominators, nor a run that raises it add 15–30 m fixes as truth.
    /// Changing this constant is a change to the metric and needs its own
    /// decision and re-baseline.
    public static let cleanFixTruthAccM = 15.0

    /// Smallest truth σ of a manual fix, metres, and the σ without a usable
    /// span. Frozen at `NavigationConfig.manualFixSigmaMinM`'s value when Q3
    /// was decided (N3.0); not read from the config (R19.1-1).
    public static let manualFixTruthSigmaMinM = 30.0
    /// Frozen at `NavigationConfig.manualFixSpanDivisor`'s value when Q3 was
    /// decided (N3.0).
    public static let manualFixTruthSpanDivisor = 12.0

    /// A manual fix's truth σ for scoring, metres: max(30, mapSpanM / 12),
    /// or 30 when the span is missing, not finite or not positive.
    ///
    /// This is how wide the truth is, a property of the pin, not of the run.
    /// It is deliberately not `options.config.manualFixSigma` (the σ the
    /// engine weights the pin with), nor `NavigationConfig()`'s defaults:
    /// either would let a candidate config widen its own truth. A run that
    /// raises the pin σ (`--set manualFixSigmaMinM=…`, a sweep, a new
    /// default, a speed term) would then pass "consistency must not drop" by
    /// moving the truth while the engine's estimate and ellipse at the pin
    /// are unchanged (R19.1-1). Same arithmetic as the engine's rule with
    /// its N3.0 defaults, so the two agree on a default-config run today;
    /// a change to the engine's rule or defaults leaves this one alone.
    public static func manualFixTruthSigmaM(mapSpanM: Double?) -> Double {
        guard let span = mapSpanM, span.isFinite, span > 0 else { return manualFixTruthSigmaMinM }
        return max(manualFixTruthSigmaMinM, span / manualFixTruthSpanDivisor)
    }

    /// The truth's own σ per axis, metres, for the consistency with the
    /// truth's σ added (Q3):
    /// - a withheld clean fix: its `horizontalAccuracy` / `accuracyPerSigma`
    ///   (3.3 m at 5 m accuracy);
    /// - a manual fix: its frozen truth σ (`truthSigmaM`,
    ///   `manualFixTruthSigmaM`, independent of the run's config; 30–104 m on
    ///   the replay set);
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

/// The worst scored checkpoints of one kind (R19.1-2). The run's
/// `maxErrorM` covers every kind together, so on a drive with pins it can
/// be a pin's; the drives gated on their withheld clean fixes (drive-7,
/// drive-8: every one within 2.5 % of the distance travelled from the start
/// at its time) need the clean fixes alone, and the largest percentage,
/// which need not be the largest error in metres.
public struct KindMaxError: Hashable, Sendable, Codable {
    /// Scored checkpoints of the kind with an error (the engine had an
    /// estimate at their time).
    public var scored: Int
    /// The largest error, metres, and its checkpoint's `t`.
    public var maxErrorM: Double
    public var maxErrorT: Double
    /// The largest `errorPercent` (error as a percentage of the distance
    /// travelled from the start at its time), and its checkpoint's `t`;
    /// nil when none of them had a distance yet.
    public var maxPercent: Double?
    public var maxPercentT: Double?

    public init(scored: Int, maxErrorM: Double, maxErrorT: Double, maxPercent: Double? = nil, maxPercentT: Double? = nil) {
        self.scored = scored
        self.maxErrorM = maxErrorM
        self.maxErrorT = maxErrorT
        self.maxPercent = maxPercent
        self.maxPercentT = maxPercentT
    }

    /// Per kind over the scored checkpoints with an error (`isScored`:
    /// refinements, excluded pins and checkpoints after `scoreUntilT` do
    /// not count); ties keep the earliest checkpoint.
    public static func byKind(_ checkpoints: [ReplayResult.Checkpoint]) -> [String: KindMaxError] {
        var out: [String: KindMaxError] = [:]
        for cp in checkpoints where cp.isScored {
            guard let error = cp.errorM else { continue }
            let key = cp.kind.rawValue
            var m = out[key] ?? KindMaxError(scored: 0, maxErrorM: error, maxErrorT: cp.t)
            m.scored += 1
            if error > m.maxErrorM { m.maxErrorM = error; m.maxErrorT = cp.t }
            if let percent = cp.errorPercent, percent > (m.maxPercent ?? -.infinity) {
                m.maxPercent = percent
                m.maxPercentT = cp.t
            }
            out[key] = m
        }
        return out
    }
}

/// How often the truth lies inside the engine's 95 % ellipse: over every
/// scored checkpoint (withheld clean fixes, manual-fix priors, truth points
/// and end), and per checkpoint kind. A calibrated filter scores about 95 %;
/// much lower means the ellipse is overconfident. With `withTruthSigma:
/// false` (`consistency`) the truth's own σ is not added to the ellipse; with
/// `withTruthSigma: true` (`consistencyWithTruthSigma`, the gated variant,
/// Q3) it is: P + σ_truth² I, σ_truth frozen in replay code. A checkpoint
/// that is not scored (`notScored`: a refinement pin, or one the truth file
/// excludes; `afterScoreUntilT`: after the truth file's cutoff) is not
/// counted.
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
