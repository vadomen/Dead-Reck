import DriveLoggerCore
import Foundation

/// Live dead reckoning for the recording in progress (N4 B).
///
/// One actor for the app's lifetime, off the main thread. For every
/// recording, `RecordingSession.onNavigationFeed` hands it a
/// `RecordingNavigationFeed` (`AppServices` wires `start(_:)` there); the
/// service then:
/// - builds a **fresh** `LiveNavigationRun` (a new `NavigationEngine` with
///   the default config and the seed derived from the recording's header,
///   `NavigationSeed`), so a relaunch mid-drive is a new recording with a
///   new engine (R11.2-3 in practice);
/// - consumes the feed's inputs in file order and ingests each; a manual
///   fix is the engine's own position reset;
/// - writes the sidecar `feed.sidecarURL` (`NavSidecar`, docs/NAV_SIDECAR.md):
///   the header at once, then estimates, pins and road lines, buffered and
///   flushed every `flushInterval` (10 s) on the actor and on `flush()`
///   (the app going to the background, R14.1-4), and, when the
///   feed's stream ends (stop or write failure), the closing
///   `roadsSelection` lines (`LiveNavigationRun.closingLines`), flushed and
///   closed;
/// - answers `snapshot(at:)` for the map and the debug overlay.
///
/// The per-recording loop is Core's `LiveNavigationRun`, the same code
/// `replay_nav --as-live --compare` runs over the recording on a Mac.
///
/// If a new recording starts while the previous feed is still draining
/// (stop, then Start at once), both runs proceed, each into its own
/// sidecar; snapshots follow the newest.
actor NavigationService {
    /// What the service did with one recording, kept for diagnostics and
    /// tests once its feed has ended.
    struct Finished: Sendable, Hashable {
        let generation: Int
        let sessionID: UUID
        let sidecarURL: URL
        let inputs: Int
        let estimates: Int
        let droppedInputs: Int
        let sidecarBytes: Int
        let sidecarLinesLost: Int
        let sidecarFailure: String?
        /// Roads (N3.3): the pack files used, their hash prefixes, when they
        /// became active (session seconds), and a refused set's reason.
        var roadPackNames: [String] = []
        var roadPackHashPrefixes: [String] = []
        var roadSetHashPrefix: String?
        var roadsActiveAtS: Double?
        var roadsRefusal: String?
        /// Road selection attempts recorded (the `unfinished` one too), and
        /// the `roadsSelection` lines written for them: identical repeats
        /// share one line (`NavSidecar.RoadsSelectionLog`).
        var selectionAttempts = 0
        var selectionLines = 0
    }

    /// Selection state of one recording's roads (N3.3 item 5).
    private struct RoadsState {
        /// Bumped per selection started; a result with another token is stale.
        var token = 0
        var inFlight: Task<Void, Never>?
        /// The request `inFlight` is selecting for; the `unfinished`
        /// `roadsSelection` line at the end of the recording names it.
        var inFlightRequest: RoadSelectionRequest?
        /// The latest request that arrived while one was in flight.
        var pending: RoadSelectionRequest?
        var names: [String] = []
        var refusal: String?
        /// Covering sets (file names, in candidate order) already refused.
        var knownRefusals: [RoadPackSelection.Refusal] = []
        /// How the latest finished attempt of this recording ended.
        var lastOutcome: NavSidecar.RoadsSelection.Outcome?
        /// This recording's own library rescan (started in `begin`) has
        /// returned (R34.1-3).
        var libraryScanned = false
    }

    /// What Diagnostics shows about roads in the recording.
    struct RoadsStatus: Sendable, Hashable {
        /// A recording is navigating (else this is the last finished one).
        var recording = false
        var packNames: [String] = []
        var packHashPrefixes: [String] = []
        var roadSetHashPrefix: String?
        /// Session time at which roads became active.
        var activeAtSessionS: Double?
        var refusal: String?
        var selectionPending = false
        var onRoadShare: Double?
        /// How the latest selection attempt of this recording ended; nil
        /// before the first (the map's roads warning reads it).
        var lastOutcome: NavSidecar.RoadsSelection.Outcome?
        /// The library rescan this recording started has returned, so the
        /// library's packs are as of this recording, not an earlier scan
        /// (R34.1-3: the map's "no road packs" line waits for it). False
        /// without a library and for a finished recording.
        var libraryScanned = false

        var inUse: Bool { !packNames.isEmpty }
        static let none = RoadsStatus()
    }

    private struct Run {
        let feed: RecordingNavigationFeed
        var live: LiveNavigationRun
        let writer: NavSidecarWriter?
        let openFailure: String?
        var lastFlush: ContinuousClock.Instant
    }

    let flushInterval: Duration
    /// Where road packs come from; nil: no roads (every recording is the
    /// no-roads run).
    private let library: RoadPackLibrary?
    private var runs: [Int: Run] = [:]
    private var roadStates: [Int: RoadsState] = [:]
    /// The newest recording's generation; snapshots follow it.
    private var current: Int?
    /// Engines built so far (one per recording).
    private(set) var runsStarted = 0
    private(set) var finished: [Finished] = []
    /// Selection attempts finished so far, all recordings (the
    /// `unfinished` ones too), and the latest one's outcome: lets tests wait
    /// for an attempt, which with repeats folded may write no line.
    /// Bounded: a count, not a list.
    private(set) var selectionAttempts = 0
    private(set) var lastAttemptOutcome: NavSidecar.RoadsSelection.Outcome?

    /// How a recording's start rescans the library: `rescan()`. Tests
    /// inject a slow one (R34.1-3).
    typealias LibraryRescan = @Sendable (RoadPackLibrary) async -> [RoadPackLibrary.PackStatus]
    private let libraryRescan: LibraryRescan

    init(flushInterval: Duration = .seconds(10), library: RoadPackLibrary? = nil,
         libraryRescan: @escaping LibraryRescan = { await $0.rescan() }) {
        self.flushInterval = flushInterval
        self.library = library
        self.libraryRescan = libraryRescan
    }

    /// The `onNavigationFeed` hook's body: starts the task that consumes
    /// `feed` and returns at once.
    @discardableResult
    nonisolated func start(_ feed: RecordingNavigationFeed) -> Task<Void, Never> {
        Task(priority: .userInitiated) { await self.consume(feed) }
    }

    /// Runs one recording's navigation until its feed ends.
    func consume(_ feed: RecordingNavigationFeed) async {
        begin(feed)
        for await input in feed.inputs {
            ingest(input, generation: feed.generation)
        }
        end(feed.generation)
    }

    /// This build's configuration, for the sidecar header next to
    /// `appBuild`: `msPerStep` is only meaningful in Release.
    static let buildConfiguration: String = {
        #if DEBUG
        NavSidecar.Header.debugBuild
        #else
        NavSidecar.Header.releaseBuild
        #endif
    }()

    private func begin(_ feed: RecordingNavigationFeed) {
        let live = LiveNavigationRun(header: feed.header, appBuild: feed.header.app.build,
                                     buildConfiguration: Self.buildConfiguration)
        var writer: NavSidecarWriter?
        var openFailure: String?
        do {
            writer = try NavSidecarWriter(url: feed.sidecarURL)
        } catch {
            openFailure = String(describing: error)
        }
        for line in live.openingLines { writer?.append(line) }
        writer?.flush()
        runs[feed.generation] = Run(feed: feed, live: live, writer: writer, openFailure: openFailure,
                                    lastFlush: ContinuousClock.now)
        current = feed.generation
        runsStarted += 1
        roadStates[feed.generation] = RoadsState()
        // Rescan the packs (cache hits are cheap); never awaited here. Its
        // result goes into the recording once, as the `roadPacks` row, and
        // only then does the library count as scanned for this recording.
        if let library {
            let report = feed.recordRoadPacks, rescan = libraryRescan, generation = feed.generation
            Task(priority: .utility) { [self] in
                let packs = await rescan(library)
                libraryRescanReturned(generation)
                report(RoadPackLibrary.roadPacksDetail(packs))
            }
        }
    }

    private func libraryRescanReturned(_ generation: Int) {
        roadStates[generation]?.libraryScanned = true
    }

    private func ingest(_ input: NavigationInput, generation: Int) {
        guard var run = runs[generation] else { return }
        // Out of the dictionary while it mutates, so the engine's arrays
        // are not copied.
        runs[generation] = nil
        let writer = run.writer
        run.live.ingest(input, droppedInputs: run.feed.droppedInputs) { writer?.append($0) }
        let now = ContinuousClock.now
        if now - run.lastFlush >= flushInterval {
            writer?.flush()
            run.lastFlush = now
        }
        let request = run.live.newSelectionRequest
        runs[generation] = run
        if let request { requestRoads(request, generation: generation) }
    }

    /// Flushes every running recording's sidecar now (R14.1-4). `AppServices`
    /// calls it from the recording's own flush on `.background` and on a
    /// memory warning, inside that flush's background task: otherwise a
    /// kill in the background would lose up to `flushInterval` of lines the
    /// log (flushed on background) still has inputs for.
    func flush() {
        let now = ContinuousClock.now
        for generation in runs.keys {
            runs[generation]?.writer?.flush()
            runs[generation]?.lastFlush = now
        }
    }

    // MARK: Roads

    /// The run raised a selection request (no network attached). One
    /// selection at a time; a request during one replaces the pending one.
    private func requestRoads(_ request: RoadSelectionRequest, generation: Int) {
        guard library != nil, runs[generation]?.live.roads == nil, var state = roadStates[generation] else { return }
        if state.inFlight != nil {
            state.pending = request
        } else {
            startSelection(request, generation: generation, state: &state)
        }
        roadStates[generation] = state
    }

    private func startSelection(_ request: RoadSelectionRequest, generation: Int, state: inout RoadsState) {
        guard let library else { return }
        state.token += 1
        let token = state.token, known = state.knownRefusals
        state.pending = nil
        state.inFlightRequest = request
        // Candidates (awaiting a scan), selection and the network build all
        // run off this actor; only the attach comes back.
        state.inFlight = Task.detached(priority: .utility) { [self] in
            let set = await library.candidates()
            guard !Task.isCancelled else { return }
            let attempt = RoadPackSelection.attempt(set.candidates, refusedAtScan: set.refused, request: request,
                                                    knownRefusals: known)
            guard !Task.isCancelled else { return }
            await selectionFinished(attempt, generation: generation, token: token)
        }
    }

    /// Back on the actor, between two inputs: attach, or note why not, and
    /// record the attempt (`LiveNavigationRun.finishSelection`: its
    /// `roadsSelection` line unless it repeats the last one written, then
    /// `roads` after a successful attach). A result for an ended recording
    /// or a superseded selection is dropped. The request pending behind
    /// this one is not an attempt.
    private func selectionFinished(_ attempt: RoadSelectionAttempt, generation: Int, token: Int) {
        guard var state = roadStates[generation], state.token == token, var run = runs[generation] else { return }
        state.inFlight = nil
        state.inFlightRequest = nil
        runs[generation] = nil
        let writer = run.writer
        let record = run.live.finishSelection(attempt) { writer?.append($0) }
        selectionAttempts += 1
        lastAttemptOutcome = record.outcome
        state.lastOutcome = record.outcome
        if let refusal = record.refusal {
            state.refusal = (refusal.names.isEmpty ? "" : refusal.names.joined(separator: ", ") + ": ") + refusal.reason
            if !state.knownRefusals.contains(where: { $0.names == refusal.names }) {
                state.knownRefusals.append(refusal)
            }
        }
        if record.outcome == .selected {
            writer?.flush()
            run.lastFlush = ContinuousClock.now
            state.names = record.packs ?? []
            state.refusal = nil
            state.pending = nil
        }
        runs[generation] = run
        if run.live.roads == nil, let pending = state.pending {
            startSelection(pending, generation: generation, state: &state)
        }
        roadStates[generation] = state
    }

    /// Roads in the newest recording (else the last finished one).
    func roadsStatus() -> RoadsStatus {
        if let generation = current, let run = runs[generation] {
            let state = roadStates[generation]
            var status = RoadsStatus(recording: true, refusal: state?.refusal,
                                     selectionPending: run.live.roads == nil && run.live.selectionRequest != nil,
                                     lastOutcome: state?.lastOutcome, libraryScanned: state?.libraryScanned ?? false)
            if let roads = run.live.roads {
                status.packNames = state?.names ?? []
                status.packHashPrefixes = roads.network.packs.map { String(NavigationSeed.hex($0.contentHash).prefix(8)) }
                status.roadSetHashPrefix = String(roads.network.roadSetHashHex.prefix(8))
                status.activeAtSessionS = roads.t?.seconds ?? 0
                status.onRoadShare = run.live.engine.estimate(at: run.feed.clock.now())?.onRoadShare
            }
            return status
        }
        guard let last = finished.last else { return .none }
        return RoadsStatus(recording: false, packNames: last.roadPackNames, packHashPrefixes: last.roadPackHashPrefixes,
                           roadSetHashPrefix: last.roadSetHashPrefix, activeAtSessionS: last.roadsActiveAtS,
                           refusal: last.roadsRefusal)
    }

    private func end(_ generation: Int) {
        guard var run = runs.removeValue(forKey: generation) else { return }
        let state = roadStates.removeValue(forKey: generation)
        state?.inFlight?.cancel()
        // The pending repeats' line, then the `unfinished` line of a
        // selection still in flight (an attempt that never finished), then
        // close.
        let inFlight = state?.inFlight != nil ? state?.inFlightRequest : nil
        for line in run.live.closingLines(inFlight: inFlight) { run.writer?.append(line) }
        if inFlight != nil {
            selectionAttempts += 1
            lastAttemptOutcome = .unfinished
        }
        run.writer?.close()
        let roads = run.live.roads
        finished.append(Finished(
            generation: generation,
            sessionID: run.live.sessionID,
            sidecarURL: run.feed.sidecarURL,
            inputs: run.live.inputs,
            estimates: run.live.estimates,
            droppedInputs: run.feed.droppedInputs,
            sidecarBytes: run.writer?.bytesWritten ?? 0,
            sidecarLinesLost: run.writer?.linesLost ?? 0,
            sidecarFailure: run.openFailure ?? run.writer?.failure,
            roadPackNames: roads == nil ? [] : state?.names ?? [],
            roadPackHashPrefixes: roads?.network.packs.map { String(NavigationSeed.hex($0.contentHash).prefix(8)) } ?? [],
            roadSetHashPrefix: roads.map { String($0.network.roadSetHashHex.prefix(8)) },
            roadsActiveAtS: roads.map { $0.t?.seconds ?? 0 },
            roadsRefusal: state?.refusal,
            selectionAttempts: run.live.selectionLog.attempts,
            selectionLines: run.live.selectionLog.lines
        ))
        if current == generation { current = nil }
    }

    // MARK: Reading

    /// The newest recording's estimate at `t` (on that recording's session
    /// clock, `clock`) and the run's statistics. `.idle` when no recording
    /// is navigating. Cost: one pass over the particles.
    func snapshot(at t: MonotonicTimestamp) -> NavigationSnapshot {
        guard let generation = current, let run = runs[generation] else { return .idle(at: t) }
        return run.live.snapshot(at: t, droppedInputs: run.feed.droppedInputs)
    }

    /// `snapshot(at: clock.now())` on the newest recording's clock.
    func snapshot() -> NavigationSnapshot {
        guard let clock else { return .idle(at: .zero) }
        return snapshot(at: clock.now())
    }

    /// The session clock of the recording snapshots follow; nil when none.
    var clock: SessionClock? {
        current.flatMap { runs[$0]?.feed.clock }
    }

    /// The generation (`RecordingSession` recording) snapshots follow.
    var currentGeneration: Int? { current }
}
