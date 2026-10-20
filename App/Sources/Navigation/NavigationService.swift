import DriveLoggerCore
import Foundation

/// Live dead reckoning for the run in progress: a recording (N4 B) or a
/// Navigate run, which writes nothing (UX-1).
///
/// One actor for the app's lifetime, off the main thread. For every run,
/// `RecordingSession.onNavigationFeed` hands it a `RecordingNavigationFeed`
/// (`AppServices` wires `start(_:)` there); the service then:
/// - builds a **fresh** `LiveNavigationRun` (a new `NavigationEngine` with
///   the default config and the seed derived from the run's header,
///   `NavigationSeed`), so a relaunch mid-drive is a new run with a new
///   engine (R11.2-3 in practice);
/// - consumes the feed's inputs in tap order (a recording's file order) and
///   ingests each; a manual fix is the engine's own position reset;
/// - for a recording (`feed.output` `.recording`), writes the sidecar
///   `feed.sidecarURL` (`NavSidecar`, docs/NAV_SIDECAR.md): the header at
///   once, then estimates, pins and road lines, buffered and flushed every
///   `flushInterval` (10 s) on the actor and on `flush()` (the app going to
///   the background, R14.1-4), and, when the feed's stream ends (stop or
///   write failure), the closing `roadsSelection` lines
///   (`LiveNavigationRun.closingLines`), flushed and closed;
/// - for a Navigate run (`.navigateOnly`), does all of the above with no
///   writer: the same lines are produced and dropped, no file or directory
///   is created, `flush()` has nothing to do for it, and having no sidecar
///   is not a failure (`Finished.sidecarFailure` stays nil). One code path
///   with an optional writer, so the engine cannot be fed differently in
///   the two modes;
/// - selects and attaches road packs (N3.3) the same way in both: the
///   library rescan at the start, selection, mid-run attach. Only the
///   `roadPacks` row (`feed.recordRoadPacks`) has nowhere to go in Navigate;
/// - answers `snapshot(at:)` for the map and the debug overlay.
///
/// The per-run loop is Core's `LiveNavigationRun`, the same code
/// `replay_nav --as-live --compare` runs over a recording on a Mac.
///
/// If a new run starts while the previous feed is still draining (stop,
/// then Start at once; Navigate stopped for Record), both runs proceed,
/// each into its own sidecar if it has one; snapshots follow the newest.
actor NavigationService {
    /// What the service did with one run, kept for diagnostics and tests
    /// once its feed has ended.
    struct Finished: Sendable, Hashable {
        let generation: Int
        let sessionID: UUID
        /// nil: a Navigate run, no sidecar (its bytes, lines lost and
        /// failure are 0, 0 and nil).
        let sidecarURL: URL?
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

    /// Selection state of one run's roads (N3.3 item 5).
    private struct RoadsState {
        /// Bumped per selection started; a result with another token is stale.
        var token = 0
        var inFlight: Task<Void, Never>?
        /// The request `inFlight` is selecting for; the `unfinished`
        /// `roadsSelection` line at the end of the run names it.
        var inFlightRequest: RoadSelectionRequest?
        /// The latest request that arrived while one was in flight.
        var pending: RoadSelectionRequest?
        var names: [String] = []
        var refusal: String?
        /// Covering sets (file names, in candidate order) already refused.
        var knownRefusals: [RoadPackSelection.Refusal] = []
        /// How the latest finished attempt of this run ended.
        var lastOutcome: NavSidecar.RoadsSelection.Outcome?
        /// This run's own library rescan (started in `begin`) has returned
        /// (R34.1-3). Set with or without a sidecar.
        var libraryScanned = false
    }

    /// What Diagnostics and the map's roads warning show about roads in the
    /// current run, a recording or a Navigate run alike.
    struct RoadsStatus: Sendable, Hashable {
        /// A run is navigating (else this is the last finished one, or none).
        var active = false
        var packNames: [String] = []
        var packHashPrefixes: [String] = []
        var roadSetHashPrefix: String?
        /// Session time at which roads became active.
        var activeAtSessionS: Double?
        var refusal: String?
        var selectionPending = false
        var onRoadShare: Double?
        /// How the latest selection attempt of this run ended; nil before
        /// the first (the map's roads warning reads it).
        var lastOutcome: NavSidecar.RoadsSelection.Outcome?
        /// The library rescan this run started has returned, so the
        /// library's packs are as of this run, not an earlier scan
        /// (R34.1-3: the map's "no road packs" line waits for it). False
        /// without a library and for a finished run.
        var libraryScanned = false

        var inUse: Bool { !packNames.isEmpty }
        static let none = RoadsStatus()
    }

    private struct Run {
        let feed: RecordingNavigationFeed
        var live: LiveNavigationRun
        /// nil: no sidecar (Navigate) or it failed to open (`openFailure`).
        let writer: NavSidecarWriter?
        let openFailure: String?
        var lastFlush: ContinuousClock.Instant
        /// The matched edge's shape for snapshots, rebuilt only when the
        /// matched edge changes (N3.4 item 6).
        var edgeGeometry = MatchedEdgeGeometry.Cache()
    }

    let flushInterval: Duration
    /// Where road packs come from; nil: no roads (every run is the
    /// no-roads run).
    private let library: RoadPackLibrary?
    private var runs: [Int: Run] = [:]
    private var roadStates: [Int: RoadsState] = [:]
    /// The newest run's generation; snapshots follow it.
    private var current: Int?
    /// Engines built so far (one per run).
    private(set) var runsStarted = 0
    private(set) var finished: [Finished] = []
    /// Selection attempts finished so far, all runs (the
    /// `unfinished` ones too), and the latest one's outcome: lets tests wait
    /// for an attempt, which with repeats folded may write no line.
    /// Bounded: a count, not a list.
    private(set) var selectionAttempts = 0
    private(set) var lastAttemptOutcome: NavSidecar.RoadsSelection.Outcome?
    /// Selection attempts that came back with a built network (`selected`,
    /// attached or refused by the run), all runs: a set refused once
    /// is remembered (`RoadsState.knownRefusals`) and not built again. A
    /// count for tests (R33.1-3); no behaviour reads it.
    private(set) var networksBuilt = 0

    /// How a run's start rescans the library: `rescan()`. Tests
    /// inject a slow one (R34.1-3).
    typealias LibraryRescan = @Sendable (RoadPackLibrary) async -> [RoadPackLibrary.PackStatus]
    private let libraryRescan: LibraryRescan
    /// REL-DEMO: road candidates selected **inline** (`useInlineRoads`):
    /// a run's selection request is answered on this actor before its next
    /// input, like `replay_nav --as-live` (`LiveNavigationRun.ingest(_:
    /// selector:)`), so roads attach after the same input on every run.
    /// nil: the library's asynchronous selection (the app's runs).
    private var inlineCandidates: [RoadPackSelection.Candidate]?
    private var inlineSelectors: [Int: RoadPackSelector] = [:]

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

    /// Runs one run's navigation until its feed ends.
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
        // Navigate: no writer, no file; everything below runs the same.
        var writer: NavSidecarWriter?
        var openFailure: String?
        if let sidecarURL = feed.sidecarURL {
            do {
                writer = try NavSidecarWriter(url: sidecarURL)
            } catch {
                openFailure = String(describing: error)
            }
        }
        for line in live.openingLines { writer?.append(line) }
        writer?.flush()
        runs[feed.generation] = Run(feed: feed, live: live, writer: writer, openFailure: openFailure,
                                    lastFlush: ContinuousClock.now)
        current = feed.generation
        runsStarted += 1
        roadStates[feed.generation] = RoadsState()
        if let inlineCandidates {
            inlineSelectors[feed.generation] = RoadPackSelector(candidates: inlineCandidates)
            // No library to wait for: the candidates are open.
            roadStates[feed.generation]?.libraryScanned = true
        }
        // Rescan the packs (cache hits are cheap); never awaited here. Its
        // result goes into the recording once, as the `roadPacks` row (a
        // no-op in Navigate), and only then does the library count as
        // scanned for this run.
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
        guard let request else { return }
        if inlineSelectors[generation] != nil {
            selectInline(request, generation: generation)
        } else {
            requestRoads(request, generation: generation)
        }
    }

    /// REL-DEMO: road candidates for runs that start from now on, selected
    /// inline (see `inlineCandidates`). The demo service calls it before its
    /// first run; the app's service never does.
    func useInlineRoads(_ candidates: [RoadPackSelection.Candidate]) {
        inlineCandidates = candidates
    }

    /// The inline selection, between two inputs: the same attempt, attach
    /// and `roadsSelection` bookkeeping as `selectionFinished`, at once.
    private func selectInline(_ request: RoadSelectionRequest, generation: Int) {
        guard var selector = inlineSelectors[generation], var state = roadStates[generation],
              var run = runs[generation], run.live.roads == nil else { return }
        runs[generation] = nil
        let writer = run.writer
        let attempt = selector.attempt(for: request)
        let record = run.live.finishSelection(attempt) { writer?.append($0) }
        if attempt.network != nil, let refusal = record.refusal { selector.remember(refusal) }
        selectionAttempts += 1
        if attempt.network != nil { networksBuilt += 1 }
        lastAttemptOutcome = record.outcome
        state.lastOutcome = record.outcome
        if let refusal = record.refusal {
            state.refusal = (refusal.names.isEmpty ? "" : refusal.names.joined(separator: ", ") + ": ") + refusal.reason
        }
        if record.outcome == .selected {
            state.names = record.packs ?? []
            state.refusal = nil
        }
        runs[generation] = run
        roadStates[generation] = state
        inlineSelectors[generation] = selector
    }

    /// Flushes every running recording's sidecar now (R14.1-4); a Navigate
    /// run has none, so nothing happens for it. `AppServices`
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
    /// `roads` after a successful attach). A result for an ended run
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
        if attempt.network != nil { networksBuilt += 1 }
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

    /// Roads in the newest run (else the last finished one).
    func roadsStatus() -> RoadsStatus {
        if let generation = current, let run = runs[generation] {
            let state = roadStates[generation]
            var status = RoadsStatus(active: true, refusal: state?.refusal,
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
        return RoadsStatus(active: false, packNames: last.roadPackNames, packHashPrefixes: last.roadPackHashPrefixes,
                           roadSetHashPrefix: last.roadSetHashPrefix, activeAtSessionS: last.roadsActiveAtS,
                           refusal: last.roadsRefusal)
    }

    private func end(_ generation: Int) {
        guard var run = runs.removeValue(forKey: generation) else { return }
        let state = roadStates.removeValue(forKey: generation)
        inlineSelectors[generation] = nil
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

    /// The newest run's estimate at `t` (on that run's session clock,
    /// `clock`), the run's statistics (`stats.onRoadShare` included) and,
    /// with roads, the matched edge's shape (`matchedEdgeGeometry`, for the
    /// map's debug drawing). `.idle` when no run is navigating. Cost: one
    /// pass over the particles; the edge shape is rebuilt only when the
    /// matched edge changes.
    func snapshot(at t: MonotonicTimestamp) -> NavigationSnapshot {
        guard let generation = current, let run = runs[generation] else { return .idle(at: t) }
        var cache = run.edgeGeometry
        let snapshot = run.live.snapshot(at: t, droppedInputs: run.feed.droppedInputs, edgeGeometry: &cache)
        runs[generation]?.edgeGeometry = cache
        return snapshot
    }

    /// `snapshot(at: clock.now())` on the newest run's clock.
    func snapshot() -> NavigationSnapshot {
        guard let clock else { return .idle(at: .zero) }
        return snapshot(at: clock.now())
    }

    /// The session clock of the run snapshots follow; nil when none.
    var clock: SessionClock? {
        current.flatMap { runs[$0]?.feed.clock }
    }

    /// The generation (`RecordingNavigationFeed.generation`) snapshots follow.
    var currentGeneration: Int? { current }

    /// A run is being consumed (from its feed's start until the feed has
    /// drained): it may have road packs mapped. `RoadPackLibrary.remove`
    /// asks this before deleting a pack file.
    var hasActiveRun: Bool { !runs.isEmpty }
}
