import DriveLoggerCore
import Foundation

/// What Navigate mode (UX-1) is doing: the engine fed from the same sources,
/// clock and link rows as a recording, with nothing written
/// (`RecordingSession`, "Navigate"). Observed through
/// `RecordingSession.navigateState`; Record has its own `state`, and while a
/// recording starts, runs or stops this is `.off`.
///
/// | From | Event | To |
/// |---|---|---|
/// | `off` | link reaches `polling` (Navigate enabled; no recording starting, running or ending) | `calibrating`, or `running` when the speed at connect is > 0 |
/// | `off` | a recording ends (stop or write failure, or a Start that threw) with the link `polling` | as above: a fresh session |
/// | `calibrating` | speed at connect arrives and is > 0 | `running` |
/// | `calibrating` | `stillCalibration` (5 s) since the session started | `running` |
/// | `calibrating`, `running` | link leaves `polling` | `waitingForOBD(since: now)` |
/// | `waitingForOBD` | link back to `polling` | `running`: the same session, clock and feed, no second calibration or start-up replay |
/// | `waitingForOBD` | `autoStopAfter` (5 min) continuously without `polling`, on `ContinuousClock` (counts while suspended) | `off`: session ended |
/// | any but `off` | Record starts | `off`: session ended before Record's clock exists |
/// | any but `off` | `willTerminate`, `disableNavigate()` | `off` |
///
/// **Speed at connect** (calibration rule (a)): the latest primary-ECU
/// (`7E8`) vehicle-speed reading the session had when Navigate started, or,
/// if it had none, the first one to arrive. 0 keeps the 5 s still phase; > 0
/// skips it at once. If no reading arrives within the still phase, it simply
/// ends after its 5 s: no reading is no evidence of motion. Only that first
/// value decides; later readings don't restart or cut the phase.
///
/// Calibration here is the same keep-still phase the engine sees at the
/// start of a recording: the engine runs throughout (it never sees the
/// `calibrationStart`/`calibrationEnd` rows), so this state is for the UI.
enum NavigateState: Hashable, Sendable {
    case off
    /// Keep the car and phone still (rule (a)); the engine is already running.
    case calibrating
    case running
    /// The link left `polling` at `since`; sources and engine keep running.
    case waitingForOBD(since: ContinuousClock.Instant)

    /// A session exists: every state but `off`.
    var isActive: Bool { self != .off }
}

/// Navigate's timings. The defaults are the decided ones (UX-1 (a), (c));
/// tests pass short ones.
struct NavigateConfiguration: Hashable, Sendable {
    /// The keep-still phase when the speed at connect is 0.
    var stillCalibration: Duration = .seconds(5)
    /// Navigate stops after this long continuously without `polling`.
    var autoStopAfter: Duration = .seconds(300)
}

/// What Record and Navigate share about a running session, so the code that
/// starts sources, replays the link's start-up init, forwards link rows and
/// stages pins is one function for both: a recording (`ActiveRecording`,
/// whose sink is its writer's) or a Navigate session (`NavigateRun`, whose
/// sink is `LogSink.tapOnly`).
@MainActor
protocol SessionRun: AnyObject {
    /// Unique across recordings and Navigate sessions of one
    /// `RecordingSession` (one counter): the feed's generation.
    var generation: Int { get }
    /// The session's one clock.
    var clock: SessionClock { get }
    /// Where every source and link row goes.
    var sink: LogSink { get }
    /// Handed to every `BackgroundLocationConfigurable` source before it
    /// starts: true for a recording, false for Navigate (D7).
    var holdsBackgroundLocation: Bool { get }
    var startedSources: [any SensorSource] { get set }
    /// Link events are forwarded while true.
    var acceptsLinkEvents: Bool { get set }
    /// The start-up init has been replayed (once, at the session's start).
    var replayedStartupInit: Bool { get set }
    /// Link events still to be skipped by the loop: delivered before the
    /// session started (M4 dedup contract).
    var linkEventsToSkip: Int { get set }
    /// Undo-window timers of pending manual fixes, by `PendingManualFix.id`.
    var pendingFixTimers: [Int: Task<Void, Never>] { get set }
    /// False once nothing more may reach `sink`.
    var isWritable: Bool { get }
    /// A `lifecycle` row at `clock.now()`.
    func record(_ sample: LifecycleSample)
}

/// One Navigate session: its clock, its tap-only sink and its timers. Nothing
/// it records is kept; the tap feeds `NavigationService`.
@MainActor
final class NavigateRun: SessionRun {
    let generation: Int
    let clock: SessionClock
    /// `LogSink.tapOnly(navigationTap.tap)`.
    let sink: LogSink
    let navigationTap: NavigationTap
    let holdsBackgroundLocation = false
    var startedSources: [any SensorSource] = []
    var acceptsLinkEvents = true
    var replayedStartupInit = false
    var linkEventsToSkip = 0
    var pendingFixTimers: [Int: Task<Void, Never>] = [:]
    /// Set when the session ends: the sink is finished.
    var ended = false
    /// Calibration rule (a) has been decided (or no longer matters).
    var speedDecided = false
    var calibrationTimer: Task<Void, Never>?
    var autoStopTimer: Task<Void, Never>?
    var liveTimer: Task<Void, Never>?

    init(generation: Int, clock: SessionClock, navigationTap: NavigationTap) {
        self.generation = generation
        self.clock = clock
        self.navigationTap = navigationTap
        sink = .tapOnly(navigationTap.tap)
    }

    var isWritable: Bool { !ended }

    /// Same as a recording's; the tap-only sink discards it.
    func record(_ sample: LifecycleSample) {
        sink.record(LogEvent(timestamp: clock.now(), payload: .lifecycle(sample)))
    }

    func cancelTimers() {
        calibrationTimer?.cancel()
        autoStopTimer?.cancel()
        liveTimer?.cancel()
    }
}
