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
///   the header at once, then estimates and pins, buffered and flushed
///   every `flushInterval` (10 s) on the actor, and flushed and closed when
///   the feed's stream ends (stop or write failure);
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
    }

    private struct Run {
        let feed: RecordingNavigationFeed
        var live: LiveNavigationRun
        let writer: NavSidecarWriter?
        let openFailure: String?
        var lastFlush: ContinuousClock.Instant
    }

    let flushInterval: Duration
    private var runs: [Int: Run] = [:]
    /// The newest recording's generation; snapshots follow it.
    private var current: Int?
    /// Engines built so far (one per recording).
    private(set) var runsStarted = 0
    private(set) var finished: [Finished] = []

    init(flushInterval: Duration = .seconds(10)) {
        self.flushInterval = flushInterval
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

    private func begin(_ feed: RecordingNavigationFeed) {
        let live = LiveNavigationRun(header: feed.header, appBuild: feed.header.app.build)
        var writer: NavSidecarWriter?
        var openFailure: String?
        do {
            writer = try NavSidecarWriter(url: feed.sidecarURL)
        } catch {
            openFailure = String(describing: error)
        }
        writer?.append(.header(live.header))
        writer?.flush()
        runs[feed.generation] = Run(feed: feed, live: live, writer: writer, openFailure: openFailure,
                                    lastFlush: ContinuousClock.now)
        current = feed.generation
        runsStarted += 1
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
        runs[generation] = run
    }

    private func end(_ generation: Int) {
        guard let run = runs.removeValue(forKey: generation) else { return }
        run.writer?.close()
        finished.append(Finished(
            generation: generation,
            sessionID: run.live.sessionID,
            sidecarURL: run.feed.sidecarURL,
            inputs: run.live.inputs,
            estimates: run.live.estimates,
            droppedInputs: run.feed.droppedInputs,
            sidecarBytes: run.writer?.bytesWritten ?? 0,
            sidecarLinesLost: run.writer?.linesLost ?? 0,
            sidecarFailure: run.openFailure ?? run.writer?.failure
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
