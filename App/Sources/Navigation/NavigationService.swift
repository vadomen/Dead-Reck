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
/// - offers each library change to every running run (prompt 38): the run
///   watches the new verified packs and raises a `libraryChanged` request
///   at once, and its coverage trigger raises `coverageEntered` requests;
///   a selection with roads attached extends them to the larger covering
///   set (`LiveNavigationRun.finishSelection` → `extendRoads`). A run never
///   loses a pack it attached: a removal takes effect at the next start;
/// - answers `snapshot(at:)` for the map and the debug overlay;
/// - with a `restoreStore` (the app's service only, UX-20): saves every
///   run's estimate (Record's too) every `saveInterval` (5 s) from the
///   ingest path, at the run's end (`engineOff` from `feed.runEnd`: the
///   auto-stop) and on `flush()`; and seeds each **Navigate** run from the
///   saved estimate when it is younger than 24 h (`restorePrior`). A
///   recording never reads it: it always starts a fresh engine (UX-1).
///   A Navigate run waits for every earlier run to end first, so after
///   Record's Stop it restores from the estimate Record's engine saved at
///   its end (the store's serial queue orders that save before the read),
///   flagged as a hand-over (`NavigationPrior.handOver`): confirmed at once
///   when Record's estimate was converged and the gap is ≤ 10 s.
///   Without a store nothing of this runs and nothing is written.
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
        /// The latest extension to a larger set (session seconds); nil when
        /// never extended.
        var roadsExtendedAtS: Double?
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
        /// The attached set's names, the whole set after an extension.
        var names: [String] = []
        var refusal: String?
        /// Covering sets (file names, in candidate order) already refused.
        var knownRefusals: [RoadPackSelection.Refusal] = []
        /// How the latest finished attempt of this run ended.
        var lastOutcome: NavSidecar.RoadsSelection.Outcome?
        /// This run's own library rescan (started in `begin`) has returned
        /// (R34.1-3). Set with or without a sidecar.
        var libraryScanned = false
        /// The library's `candidatesRevision` the run's watched packs come
        /// from; nil until its first sync (after its own rescan).
        var libraryRevision: Int?
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
        /// Session time of the latest extension to a larger set; nil when
        /// never extended.
        var extendedAtSessionS: Double?
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
        /// The last estimate save (UX-20), or the run's start.
        var lastSave: ContinuousClock.Instant
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
    /// The library's change observer is registered (once, at the first run).
    private var observingLibrary = false
    /// Library syncs handed to runs (the first per run included), and the
    /// library changes among them that raised a `libraryChanged` request,
    /// all runs: counts for tests.
    private(set) var librarySyncs = 0
    private(set) var libraryChangesOffered = 0

    /// What a Navigate run's start did with the saved estimate (UX-20).
    /// Never holds a coordinate.
    enum RestoreAttempt: Sendable, Hashable {
        /// No saved estimate.
        case noSavedState
        /// Seeded from an estimate saved `ageS` seconds before the run's start.
        case restored(ageS: Double)
        /// The saved estimate was not used (and was deleted): unreadable, or
        /// its age outside −5 s…24 h.
        case refused(String)
    }

    /// The saved estimate (UX-20); nil: nothing is read or written (the
    /// demo's service, tests' services).
    nonisolated let restoreStore: NavigationRestoreStore?
    /// How often a run's estimate is saved from the ingest path.
    nonisolated let saveInterval: Duration
    /// Longest a Navigate run waits for earlier runs to end before it reads
    /// the store (their feeds have finished; draining takes milliseconds).
    nonisolated let handOverTimeout: Duration
    private let bootSessionID: @Sendable () -> String?
    /// The newest generation whose estimate was saved: an older run's save
    /// (one still draining) never replaces a newer run's.
    private var newestSavedGeneration: Int?
    /// Navigate starts waiting for earlier runs to end (`awaitEarlierRuns`).
    private var endWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextEndWaiter = 0
    /// The latest Navigate run's restore attempt, and its generation.
    private(set) var lastRestore: RestoreAttempt?
    private(set) var lastRestoreGeneration: Int?
    /// Whether the latest Navigate run's prior was a Record-stop hand-over
    /// (`NavigationPrior.handOver`).
    private(set) var lastRestoreHandOver = false
    /// A recording whose final save (at its run's end) is the newest save
    /// in this process: the next Navigate run's read takes over from it
    /// (the Record-stop hand-over). Cleared by any later save and by that
    /// read. In memory only, so a relaunch never has one.
    private var recordingEndSave: Int?

    init(flushInterval: Duration = .seconds(10), library: RoadPackLibrary? = nil,
         libraryRescan: @escaping LibraryRescan = { await $0.rescan() },
         restoreStore: NavigationRestoreStore? = nil, saveInterval: Duration = .seconds(5),
         handOverTimeout: Duration = .seconds(2),
         bootSessionID: @escaping @Sendable () -> String? = { BootSession.current }) {
        self.flushInterval = flushInterval
        self.library = library
        self.libraryRescan = libraryRescan
        self.restoreStore = restoreStore
        self.saveInterval = saveInterval
        self.handOverTimeout = handOverTimeout
        self.bootSessionID = bootSessionID
    }

    /// The `onNavigationFeed` hook's body: starts the task that consumes
    /// `feed` and returns at once.
    @discardableResult
    nonisolated func start(_ feed: RecordingNavigationFeed) -> Task<Void, Never> {
        Task(priority: .userInitiated) { await self.consume(feed) }
    }

    /// Runs one run's navigation until its feed ends.
    func consume(_ feed: RecordingNavigationFeed) async {
        // Without a store, or for a recording, `begin` runs at once as always.
        let prior = restoreStore != nil && feed.output == .navigateOnly ? await restorePrior(for: feed) : nil
        begin(feed, prior: prior)
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

    private func begin(_ feed: RecordingNavigationFeed, prior: NavigationPrior?) {
        let live = LiveNavigationRun(header: feed.header, appBuild: feed.header.app.build,
                                     buildConfiguration: Self.buildConfiguration, prior: prior)
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
        let started = ContinuousClock.now
        runs[feed.generation] = Run(feed: feed, live: live, writer: writer, openFailure: openFailure,
                                    lastFlush: started, lastSave: started)
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
            if !observingLibrary {
                observingLibrary = true
                Task(priority: .utility) { [weak self] in
                    await library.observeCandidates { [weak self] in
                        Task(priority: .utility) { await self?.libraryCandidatesChanged() }
                    }
                }
            }
        }
    }

    private func libraryRescanReturned(_ generation: Int) {
        roadStates[generation]?.libraryScanned = true
        syncLibrary(generation)
    }

    /// The library's verified packs changed: offered to every running run
    /// that has synced once (the others sync after their own rescan).
    private func libraryCandidatesChanged() {
        for generation in runs.keys where inlineSelectors[generation] == nil
            && roadStates[generation]?.libraryRevision != nil {
            syncLibrary(generation)
        }
    }

    /// Reads the library's candidates (off this actor) and hands them to
    /// the run (`librarySynced`).
    private func syncLibrary(_ generation: Int) {
        guard let library, inlineSelectors[generation] == nil else { return }
        Task(priority: .utility) { [self] in
            let (set, revision) = await library.candidatesWithRevision()
            let packs = set.candidates.map(RoadCoverageWatch.Pack.init)
            librarySynced(packs, revision: revision, generation: generation)
        }
    }

    /// Between two inputs: the run's first sync only sets the packs its
    /// coverage trigger watches; a later revision is a library change, a
    /// `libraryChanged` request at once (`LiveNavigationRun.libraryChanged`),
    /// selected like any other. A revision already seen is ignored.
    private func librarySynced(_ packs: [RoadCoverageWatch.Pack], revision: Int, generation: Int) {
        guard var state = roadStates[generation], var run = runs[generation] else { return }
        if let known = state.libraryRevision, known >= revision { return }
        let first = state.libraryRevision == nil
        state.libraryRevision = revision
        librarySyncs += 1
        runs[generation] = nil
        var request: RoadSelectionRequest?
        if first {
            run.live.setWatchedPacks(packs)
        } else {
            request = run.live.libraryChanged(packs)
            libraryChangesOffered += 1
        }
        runs[generation] = run
        roadStates[generation] = state
        if let request { requestRoads(request, generation: generation) }
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
        if restoreStore != nil, now - run.lastSave >= saveInterval {
            saveEstimate(of: run, generation: generation, engineOff: false)
            run.lastSave = now
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
    ///
    /// UX-20: with a store, also saves the newest run's estimate and
    /// returns once it is on disk (Navigate on background calls this too).
    func flush() async {
        let now = ContinuousClock.now
        for generation in runs.keys {
            runs[generation]?.writer?.flush()
            runs[generation]?.lastFlush = now
        }
        guard let restoreStore else { return }
        if let generation = current, let run = runs[generation] {
            saveEstimate(of: run, generation: generation, engineOff: false)
            runs[generation]?.lastSave = now
        }
        await restoreStore.drain()
    }

    // MARK: Restore (UX-20)

    /// Captures `run`'s estimate now and hands it to the store (encoded and
    /// written on its queue). Nothing before initialisation, and nothing
    /// from a run older than one that already saved.
    @discardableResult
    private func saveEstimate(of run: Run, generation: Int, engineOff: Bool) -> Bool {
        guard let restoreStore else { return false }
        if let newest = newestSavedGeneration, generation < newest { return false }
        let clock = run.feed.clock
        guard let state = run.live.restoreState(at: clock.now(), clock: clock, bootSessionID: bootSessionID(),
                                                engineOff: engineOff) else { return false }
        restoreStore.save(state)
        newestSavedGeneration = generation
        recordingEndSave = nil
        return true
    }

    /// The prior for a Navigate run: after every earlier run has ended (so
    /// a recording that just stopped has saved its final estimate), the
    /// store's state if its age at the run's start is within −5 s…24 h
    /// (Core's `age`). A refused state is deleted; an unreadable one the
    /// store deletes. When the newest save is a recording's final one made
    /// in this process, the prior is a hand-over (`handOver`): the engine
    /// confirms it at once if it was converged and the gap is ≤ 10 s.
    private func restorePrior(for feed: RecordingNavigationFeed) async -> NavigationPrior? {
        guard let restoreStore else { return nil }
        await awaitEarlierRuns(before: feed.generation)
        let loaded = await restoreStore.load()
        let handOver = recordingEndSave != nil
        recordingEndSave = nil
        lastRestoreGeneration = feed.generation
        lastRestoreHandOver = false
        switch loaded {
        case .none:
            lastRestore = .noSavedState
            return nil
        case .discarded(let reason):
            lastRestore = .refused("unreadable: \(reason)")
            return nil
        case .state(let state):
            let t = feed.clock.now()
            guard let prior = state.prior(at: t, clock: feed.clock, bootSessionID: bootSessionID(),
                                          handOver: handOver) else {
                restoreStore.delete()
                lastRestore = .refused("age outside −5 s…24 h")
                return nil
            }
            lastRestore = .restored(ageS: Double(t.nanoseconds - prior.savedT.nanoseconds) / 1e9)
            lastRestoreHandOver = handOver
            return prior
        }
    }

    /// Returns when no run older than `generation` is left (each one's end
    /// has saved its estimate), or after `handOverTimeout`.
    private func awaitEarlierRuns(before generation: Int) async {
        let deadline = ContinuousClock.now.advanced(by: handOverTimeout)
        while runs.keys.contains(where: { $0 < generation }), ContinuousClock.now < deadline {
            nextEndWaiter += 1
            let id = nextEndWaiter
            let timeout = Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                await self?.resumeEndWaiter(id)
            }
            await withCheckedContinuation { continuation in
                endWaiters[id] = continuation
            }
            timeout.cancel()
        }
    }

    private func resumeEndWaiter(_ id: Int) {
        endWaiters.removeValue(forKey: id)?.resume()
    }

    /// The newest run's engine counters (tests, diagnostics); nil when none.
    var currentCounters: NavigationCounters? {
        current.flatMap { runs[$0]?.live.engine.counters }
    }

    // MARK: Roads

    /// The run raised a selection request (with or without a network
    /// attached). One selection at a time; a request during one replaces
    /// the pending one.
    private func requestRoads(_ request: RoadSelectionRequest, generation: Int) {
        guard library != nil, runs[generation] != nil, var state = roadStates[generation] else { return }
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
        // With roads attached the attempt is an extension of this set (the
        // same open packs): one selection at a time, so it is still the
        // attached one when the attempt comes back.
        let attached = runs[generation]?.live.roads?.network, attachedNames = runs[generation]?.live.roadPackNames ?? []
        state.pending = nil
        state.inFlightRequest = request
        // Candidates (awaiting a scan), selection and the network build all
        // run off this actor; only the attach comes back.
        state.inFlight = Task.detached(priority: .utility) { [self] in
            let set = await library.candidates()
            guard !Task.isCancelled else { return }
            let attempt = RoadPackSelection.attempt(set.candidates, refusedAtScan: set.refused, request: request,
                                                    knownRefusals: known, attached: attached,
                                                    attachedNames: attachedNames)
            guard !Task.isCancelled else { return }
            await selectionFinished(attempt, generation: generation, token: token)
        }
    }

    /// Back on the actor, between two inputs: attach, or note why not, and
    /// record the attempt (`LiveNavigationRun.finishSelection`: its
    /// `roadsSelection` line unless it repeats the last one written, then
    /// `roads` after a successful attach or extension). A result for an
    /// ended run or a superseded selection is dropped. The request pending
    /// behind this one is not an attempt; after an attach it is dropped
    /// unless a library change or the coverage trigger raised it.
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
            if state.pending?.trigger == nil { state.pending = nil }
        }
        runs[generation] = run
        if let pending = state.pending {
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
                status.activeAtSessionS = run.live.attachments.first?.t?.seconds ?? 0
                if run.live.attachments.count > 1 { status.extendedAtSessionS = roads.t?.seconds ?? 0 }
                status.onRoadShare = run.live.engine.estimate(at: run.feed.clock.now())?.onRoadShare
            }
            return status
        }
        guard let last = finished.last else { return .none }
        return RoadsStatus(active: false, packNames: last.roadPackNames, packHashPrefixes: last.roadPackHashPrefixes,
                           roadSetHashPrefix: last.roadSetHashPrefix, activeAtSessionS: last.roadsActiveAtS,
                           extendedAtSessionS: last.roadsExtendedAtS, refusal: last.roadsRefusal)
    }

    private func end(_ generation: Int) {
        guard var run = runs[generation] else { return }
        // UX-20: the final save, before a waiting Navigate start reads the
        // store (same serial queue, so the read sees it). A recording's is
        // what the next Navigate run takes over from.
        if saveEstimate(of: run, generation: generation, engineOff: run.feed.runEnd.engineOff),
           run.feed.output != .navigateOnly {
            recordingEndSave = generation
        }
        runs[generation] = nil
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
            roadsActiveAtS: roads.map { _ in run.live.attachments.first?.t?.seconds ?? 0 },
            roadsExtendedAtS: run.live.attachments.count > 1 ? (roads?.t?.seconds ?? 0) : nil,
            roadsRefusal: state?.refusal,
            selectionAttempts: run.live.selectionLog.attempts,
            selectionLines: run.live.selectionLog.lines
        ))
        if current == generation { current = nil }
        let waiters = endWaiters
        endWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }

    // MARK: Reading

    /// The newest run's estimate at `t` (on that run's session clock,
    /// `clock`), the run's statistics (`stats.onRoadShare` included), the
    /// GPS state for the HUD (UX-22: `gnssInUse`, `gpsSwitchedOff`, from the
    /// engine) and, with roads, the matched edge's shape
    /// (`matchedEdgeGeometry`, for the map's debug drawing). `.idle` when no
    /// run is navigating (both GPS flags false). Cost: one
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
