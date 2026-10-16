import Foundation

/// One recording's live navigation (N4 B): a fresh `NavigationEngine` fed
/// the recording's inputs in file order, the sidecar lines it produces and
/// its timing. The app's NavigationService runs one per recording; tests
/// and `replay_nav --compare` run the same code over a recording file, so
/// the sidecar a replay expects is produced exactly as the app produced it.
///
/// For each input, `ingest`:
/// 1. checks it with `NavigationEngine.accepts(_:)`. An implausible forward
///    time jump is passed to the engine (which counts the rejection) and
///    produces nothing else: it neither moves the estimate grid nor emits.
/// 2. emits an `estimate` line for every whole session-clock second at or
///    before the input's arrival not emitted yet: `engine.estimate(at:)` at
///    that second, from the state before this input. Nothing is emitted
///    before initialisation. After a silence of more than
///    `maxEstimatesPerGap` seconds, the first `maxEstimatesPerGap` seconds
///    are emitted and the grid then resumes at the arrival.
/// 3. for a manual fix, emits a `pin` line with the estimate at its `t`,
///    the prior just before the engine ingests it;
/// 4. ingests it, timing the engine call with `ContinuousClock`;
/// 5. updates the road selection rule (`RoadSelectionRule`): while no
///    network is attached, an ingest at which the engine first initialises
///    or uses a position raises a `RoadSelectionRequest`
///    (`newSelectionRequest`).
///
/// **Roads (N3.3).** A network given at init is attached before the first
/// input; `attachRoads(_:emit:)` attaches one between two inputs, once. The
/// config never changes: a network that would change the validated config
/// is refused (`roadsRefusal`) and the run goes on without roads. Until the
/// attach every line is the no-roads run's. `ingest(_:droppedInputs:selectRoads:emit:)`
/// runs a synchronous selector at each request and attaches its network at
/// once: the rule `replay_nav --as-live --roads` uses.
/// `ingest(_:droppedInputs:selector:emit:)` does the same through a
/// `RoadPackSelector` and records each attempt for the `roadsSelection`
/// lines (`finishSelection(_:emit:)`, which the app calls when its
/// asynchronous selection finishes). A line is written when the outcome or
/// the candidates change; identical repeats are counted and written as one
/// line on the next change, at an attach, or at the end
/// (`closingLines(inFlight:)`, with the `unfinished` line of an attempt
/// still in flight): `selectionLog`. These lines never change any other
/// line.
///
/// Deterministic apart from the timing diagnostics: the same inputs, seed,
/// config and attach point give the same lines, bit for bit.
public struct LiveNavigationRun: Sendable {
    public private(set) var engine: NavigationEngine
    public let sessionID: UUID
    /// The sidecar's first line.
    public let header: NavSidecar.Header
    public private(set) var timing = StepTiming()
    /// Inputs handed to `ingest`.
    public private(set) var inputs = 0
    /// Estimate lines emitted.
    public private(set) var estimates = 0
    private var nextEstimateNs: Int64?
    /// The road selection rule's state.
    public private(set) var selectionRule = RoadSelectionRule()
    /// The request the latest `ingest` raised; nil if it raised none.
    public private(set) var newSelectionRequest: RoadSelectionRequest?
    /// The attached network and when; nil without roads.
    public private(set) var roads: RoadAttachment?
    /// The latest refused attach, if any.
    public private(set) var roadsRefusal: RoadAttachRefusal?
    /// Which `roadsSelection` lines were written, and the repeats pending.
    public private(set) var selectionLog = NavSidecar.RoadsSelectionLog()

    /// The latest selection request; nil before the first and once a
    /// network is attached.
    public var selectionRequest: RoadSelectionRequest? { selectionRule.request }

    /// Spacing of the estimate grid, ns (1 s).
    public static let estimateIntervalNs: Int64 = 1_000_000_000
    /// Most estimates emitted for one silence of every input (10 min).
    public static let maxEstimatesPerGap = 600

    /// The app's run: the default config with the seed derived from the
    /// recording's header. `buildConfiguration` goes into the sidecar
    /// header (`NavSidecar.Header.buildConfiguration`).
    /// `roads`: attached before the first input (`afterInputs` 0), or
    /// refused (`roadsRefusal`).
    public init(header: LogHeader, appBuild: String, buildConfiguration: String? = nil, roads: RoadNetwork? = nil) {
        self.init(sessionID: header.sessionID,
                  config: NavigationConfig(seed: NavigationSeed.derive(header: header)),
                  appBuild: appBuild, buildConfiguration: buildConfiguration, roads: roads)
    }

    public init(sessionID: UUID, config: NavigationConfig, appBuild: String,
                buildConfiguration: String? = nil, roads: RoadNetwork? = nil) {
        engine = NavigationEngine(config: config)
        self.sessionID = sessionID
        header = NavSidecar.Header(sessionID: sessionID, config: engine.config, appBuild: appBuild,
                                   buildConfiguration: buildConfiguration)
        if let roads {
            var lines: [NavSidecar.Line] = []
            try? attachRoads(roads) { lines.append($0) }
            initialLines = lines
        }
    }

    /// The `roads` line of a network given at init, written after the header.
    private var initialLines: [NavSidecar.Line] = []

    /// What a sidecar starts with, before any input: the header, then the
    /// `roads` line of a network given at init.
    public var openingLines: [NavSidecar.Line] { [.header(header)] + initialLines }

    /// Attaches `network` now, between two inputs (`afterInputs` = `inputs`).
    /// Refused, run unchanged, when a network is already attached or when
    /// the network would change the validated config
    /// (`NavigationEngine.attachRoads`); the refusal is kept in
    /// `roadsRefusal`. No selection request is raised after an attach.
    /// `emit` receives the sidecar's `roads` line.
    public mutating func attachRoads(_ network: RoadNetwork, emit: (NavSidecar.Line) -> Void) throws(RoadAttachRefusal) {
        do {
            try engine.attachRoads(network)
        } catch {
            roadsRefusal = error
            throw error
        }
        let attachment = RoadAttachment(network: network, afterInputs: inputs, t: inputs > 0 ? engine.latestArrival : nil)
        roads = attachment
        selectionRule.attached()
        newSelectionRequest = nil
        emit(.roads(NavSidecar.Roads(attachment)))
    }

    /// Records a finished road selection attempt, between two inputs: a
    /// `selected` attempt's network is attached now (`attachRoads`). Then
    /// `emit` gets the `roadsSelection` lines `selectionLog` writes for it
    /// (recorded after `inputs` inputs): none for a repeat of the last line
    /// written, else the pending repeats' line and then the attempt's; and,
    /// after a successful attach, whose line is always written, the `roads`
    /// line right after it. An attach the run refuses (`RoadAttachRefusal`)
    /// is recorded as `refused` with the attempt's packs and the refusal's
    /// description. Returns the attempt's line, written or not: its
    /// `refusal` is the set to remember so it is not built again.
    @discardableResult
    public mutating func finishSelection(_ attempt: RoadSelectionAttempt,
                                         emit: (NavSidecar.Line) -> Void) -> NavSidecar.RoadsSelection {
        var record = attempt.line(recordedAfterInputs: inputs)
        var roadsLines: [NavSidecar.Line] = []
        if let network = attempt.network {
            do {
                try attachRoads(network) { roadsLines.append($0) }
            } catch {
                record.outcome = .refused
                record.reason = error.description
            }
        }
        for line in selectionLog.record(record, alwaysWrite: !roadsLines.isEmpty) { emit(.roadsSelection(line)) }
        for line in roadsLines { emit(line) }
        return record
    }

    /// The lines that close the run's `roadsSelection` record, to write
    /// last, before closing the sidecar: the pending repeats' line, if any,
    /// then, for `inFlight`, the `unfinished` line of an attempt for that
    /// request still in flight (recorded after `inputs` inputs, counted as
    /// an attempt). Call once, at the end.
    public mutating func closingLines(inFlight request: RoadSelectionRequest? = nil) -> [NavSidecar.Line] {
        let lines: [NavSidecar.RoadsSelection]
        if let request {
            lines = selectionLog.record(NavSidecar.RoadsSelection(unfinished: request, recordedAfterInputs: inputs),
                                        alwaysWrite: true)
        } else {
            lines = selectionLog.flush().map { [$0] } ?? []
        }
        return lines.map { .roadsSelection($0) }
    }

    /// `ingest(_:droppedInputs:emit:)`, then, if it raised a selection
    /// request, `selector` is asked at once and the attempt is finished
    /// before the next input (`finishSelection`): its `roadsSelection`
    /// lines, and the `roads` line if its network attached. An attach the
    /// run refuses is remembered by the selector. The rule `replay_nav
    /// --as-live --roads` and `--write-sidecar` use; end with
    /// `closingLines(inFlight: nil)`.
    public mutating func ingest(
        _ input: NavigationInput, droppedInputs: Int = 0, selector: inout RoadPackSelector,
        emit: (NavSidecar.Line) -> Void
    ) {
        ingest(input, droppedInputs: droppedInputs, emit: emit)
        guard let request = newSelectionRequest else { return }
        let attempt = selector.attempt(for: request)
        let record = finishSelection(attempt, emit: emit)
        if attempt.network != nil, let refusal = record.refusal { selector.remember(refusal) }
    }

    /// `ingest(_:droppedInputs:emit:)`, then, if it raised a selection
    /// request, `selectRoads` is asked at once and the network it returns
    /// (if any) is attached before the next input. A refused attach leaves
    /// the run without roads; later requests ask again. Writes no
    /// `roadsSelection` line (the closure tells no outcome): see
    /// `ingest(_:droppedInputs:selector:emit:)`.
    public mutating func ingest(
        _ input: NavigationInput, droppedInputs: Int = 0,
        selectRoads: (RoadSelectionRequest) -> RoadNetwork?, emit: (NavSidecar.Line) -> Void
    ) {
        ingest(input, droppedInputs: droppedInputs, emit: emit)
        if let request = newSelectionRequest, let network = selectRoads(request) {
            try? attachRoads(network, emit: emit)
        }
    }

    /// Feeds one input; `emit` receives the lines it produces, in order.
    /// `droppedInputs` is the live feed's drop count now (0 in a replay).
    public mutating func ingest(
        _ input: NavigationInput, droppedInputs: Int = 0, emit: (NavSidecar.Line) -> Void
    ) {
        inputs += 1
        newSelectionRequest = nil
        guard engine.accepts(input) else {
            engine.ingest(input)
            return
        }
        let arrival = input.arrival.nanoseconds
        let interval = Self.estimateIntervalNs
        if nextEstimateNs == nil {
            nextEstimateNs = NavigationEngine.floorToGrid(arrival, interval) + interval
        }
        if var next = nextEstimateNs, next <= arrival {
            var emitted = 0
            while next <= arrival {
                if emitted == Self.maxEstimatesPerGap {
                    // A long silence: skip to the arrival's own second.
                    next = NavigationEngine.floorToGrid(arrival, interval)
                    emitted = -1
                }
                if let estimate = engine.estimate(at: MonotonicTimestamp(nanoseconds: next)) {
                    emit(.estimate(line(estimate, droppedInputs: droppedInputs)))
                    estimates += 1
                }
                if emitted >= 0 { emitted += 1 }
                next += interval
            }
            nextEstimateNs = next
        }
        if case .manualFix(let sample, let t) = input {
            let prior = engine.estimate(at: t).map { line($0, droppedInputs: droppedInputs) }
            emit(.pin(NavSidecar.Pin(sample, at: t, prior: prior)))
        }
        let stepsBefore = engine.counters.steps
        let before = RoadSelectionRule.Before(engine)
        let start = ContinuousClock.now
        engine.ingest(input)
        let elapsed = ContinuousClock.now - start
        timing.observe(elapsed: elapsed, steps: engine.counters.steps - stepsBefore)
        newSelectionRequest = selectionRule.observe(engine, before: before, inputs: inputs)
    }

    private func line(_ estimate: NavigationEstimate, droppedInputs: Int) -> NavSidecar.Estimate {
        // Timing to the microsecond: diagnostics, not compared.
        func us(_ ms: Double) -> Double { (ms * 1_000).rounded() / 1_000 }
        return NavSidecar.Estimate(estimate, droppedInputs: droppedInputs,
                                   msPerStep: timing.steps > 0 ? us(timing.msPerStepEMA) : nil,
                                   maxStepMs: timing.steps > 0 ? us(timing.maxMsPerStep) : nil)
    }

    /// What the live map shows at `t` (`engine.estimate(at:)`) and the
    /// run's statistics. `droppedInputs`: the live feed's drop count.
    public func snapshot(at t: MonotonicTimestamp, droppedInputs: Int) -> NavigationSnapshot {
        let estimate = engine.estimate(at: t)
        return NavigationSnapshot(
            t: t,
            sessionID: sessionID,
            estimate: estimate,
            stats: NavigationSnapshot.Stats(
                msPerStep: timing.msPerStepEMA,
                maxMsPerStep: timing.maxMsPerStep,
                maxIngestMs: timing.maxIngestMs,
                effectiveSampleSize: estimate?.effectiveSampleSize,
                headingStdDeg: estimate?.headingStdDeg,
                speedScale: estimate?.speedScaleMean,
                droppedInputs: droppedInputs,
                inputs: inputs,
                steps: engine.counters.steps,
                rejectedInputs: engine.counters.inputsRejectedTimeJump
            )
        )
    }

    /// Engine wall time per 10 Hz step. The time of every `ingest` since
    /// the last one that stepped is spread over the steps the next one
    /// runs; that per-step value feeds an EMA and a maximum.
    public struct StepTiming: Hashable, Sendable {
        /// EMA weight of a new per-step value (about 1 s at 10 Hz).
        public static let emaWeight = 0.1

        public private(set) var msPerStepEMA = 0.0
        public private(set) var maxMsPerStep = 0.0
        /// The longest single engine call, ms (a catch-up after a silence).
        public private(set) var maxIngestMs = 0.0
        public private(set) var steps = 0
        private var unattributedMs = 0.0

        public init() {}

        public mutating func observe(elapsed: Duration, steps count: Int) {
            let (seconds, attoseconds) = elapsed.components
            let ms = Double(seconds) * 1e3 + Double(attoseconds) / 1e15
            maxIngestMs = max(maxIngestMs, ms)
            unattributedMs += ms
            guard count > 0 else { return }
            let perStep = unattributedMs / Double(count)
            unattributedMs = 0
            msPerStepEMA = steps == 0 ? perStep : msPerStepEMA + Self.emaWeight * (perStep - msPerStepEMA)
            maxMsPerStep = max(maxMsPerStep, perStep)
            steps += count
        }
    }
}

/// What the live navigation believes at one instant, for the map and the
/// debug overlay (N4 B → C). `t` is on the recording's session clock.
public struct NavigationSnapshot: Hashable, Sendable {
    public struct Stats: Hashable, Sendable {
        /// Engine time per 10 Hz step, ms: EMA and the largest so far.
        public var msPerStep: Double
        public var maxMsPerStep: Double
        /// The longest single engine call, ms.
        public var maxIngestMs: Double
        /// nil before initialisation.
        public var effectiveSampleSize: Double?
        public var headingStdDeg: Double?
        public var speedScale: Double?
        /// Navigation inputs the live feed dropped because the engine fell
        /// behind (`NavigationTap.droppedInputs`).
        public var droppedInputs: Int
        /// Inputs the engine has been handed, steps it ran, and inputs it
        /// rejected as implausible time jumps.
        public var inputs: Int
        public var steps: Int
        public var rejectedInputs: Int

        public init(msPerStep: Double = 0, maxMsPerStep: Double = 0, maxIngestMs: Double = 0,
                    effectiveSampleSize: Double? = nil, headingStdDeg: Double? = nil, speedScale: Double? = nil,
                    droppedInputs: Int = 0, inputs: Int = 0, steps: Int = 0, rejectedInputs: Int = 0) {
            self.msPerStep = msPerStep
            self.maxMsPerStep = maxMsPerStep
            self.maxIngestMs = maxIngestMs
            self.effectiveSampleSize = effectiveSampleSize
            self.headingStdDeg = headingStdDeg
            self.speedScale = speedScale
            self.droppedInputs = droppedInputs
            self.inputs = inputs
            self.steps = steps
            self.rejectedInputs = rejectedInputs
        }
    }

    /// The time the snapshot is for (the recording's session clock).
    public var t: MonotonicTimestamp
    /// The recording this belongs to; nil when no recording is navigating.
    public var sessionID: UUID?
    /// The full estimate; nil before initialisation or without a recording.
    public var estimate: NavigationEstimate?
    public var stats: Stats

    public init(t: MonotonicTimestamp, sessionID: UUID?, estimate: NavigationEstimate?, stats: Stats) {
        self.t = t
        self.sessionID = sessionID
        self.estimate = estimate
        self.stats = stats
    }

    /// No recording is navigating.
    public static func idle(at t: MonotonicTimestamp) -> NavigationSnapshot {
        NavigationSnapshot(t: t, sessionID: nil, estimate: nil, stats: Stats())
    }

    /// The engine has a position (first fix or pin seen).
    public var initialized: Bool { estimate != nil }
    public var latitude: Double? { estimate?.latitude }
    public var longitude: Double? { estimate?.longitude }
    /// 95 % position ellipse.
    public var ellipse: ErrorEllipse? { estimate?.ellipse }
    /// Heading of travel, degrees clockwise from north, and its std.
    public var headingDeg: Double? { estimate?.headingDeg }
    public var headingStdDeg: Double? { estimate?.headingStdDeg }
    /// Heading std under the converged threshold; false before
    /// initialisation. While false the map shows "calibrating heading".
    public var converged: Bool { estimate?.converged ?? false }
}
