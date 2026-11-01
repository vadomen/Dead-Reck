import DriveLoggerCore
import Foundation

/// What Navigate mode (UX-1) is doing: the engine fed from the same sources,
/// clock and link rows as a recording, with nothing written
/// (`RecordingSession`, "Navigate"). Observed through
/// `RecordingSession.navigateState`; Record has its own `state`, and while a
/// recording starts, runs or stops this is `.off`.
///
/// Two kinds of run (UX-7, prompt 47): an **OBD run** (`calibrating`,
/// `running`, `waitingForOBD`), started when the link reaches `polling`, and
/// a **no-OBD run** (`runningNoOBD`), started by the no-OBD start rule below
/// when no adapter reaches `polling`. Both are a `NavigateRun` with the same
/// sources, clock, rates, tap-only sink and background location; the no-OBD
/// run's engine is built with `NavigationConfig.noOBDLive(seed:)`
/// (`RecordingNavigationFeed.noOBD`).
///
/// **No-OBD start rule.** A timer of `NavigateConfiguration.noOBDStartAfter`
/// (30 s) on `ContinuousClock` runs while **all** of these hold: Navigate
/// enabled with a non-nil `noOBDStartAfter`; no Navigate run (`off`); no
/// recording starting, running or ending; the scene `.active` (the app is
/// open in the foreground); Location granted (When In Use or Always: no
/// source reports it denied, restricted or not yet asked); not held for the
/// demo drive; the link not `polling`; and no user Stop pending (below).
/// Any of them breaking cancels it; when all hold again it starts again from
/// 0. It fires only if all still hold. `polling` first means the normal OBD
/// start and no no-OBD run.
///
/// **User Stop** (`RecordingSession.stopNoOBDNavigate()`, the no-OBD run's
/// Stop control): ends the run and keeps the start rule off until the app
/// has been in the background and is `.active` again, or until an adapter
/// reaches `polling` (which starts an OBD run as always). Nothing else stops
/// a no-OBD run but the app closing: no time or parking auto-stop.
///
/// | From | Event | To |
/// |---|---|---|
/// | `off` | link reaches `polling` (Navigate enabled; no recording starting, running or ending; not held for the demo) | `calibrating`, or `running` when the speed at connect is > 0 |
/// | `off` | a recording ends (stop or write failure, or a Start that threw) with the link `polling` | as above: a fresh session |
/// | `off` | the no-OBD start rule's timer fires (all its conditions still hold) | `runningNoOBD`: a fresh session, no calibration phase |
/// | `calibrating` | speed at connect arrives and is > 0 | `running` |
/// | `calibrating` | `stillCalibration` (5 s) since the session started | `running` |
/// | `calibrating`, `running` | link leaves `polling` | `waitingForOBD(since: now)` |
/// | `waitingForOBD` | link back to `polling` | `running`: the same session, clock and feed, no second calibration or start-up replay |
/// | `waitingForOBD` | `autoStopAfter` (5 min) continuously without `polling`, on `ContinuousClock` (counts while suspended) | `off`: session ended, its estimate saved as engine off; the no-OBD start rule applies again |
/// | `runningNoOBD` | link reaches `polling` | `calibrating` or `running` (as from `off`): the no-OBD session ended and a fresh OBD session started in the same main-actor step, its engine seeded from the no-OBD engine's latest estimate (`RecordingNavigationFeed.restartCapture`, `NavigationPrior.noOBDRestart`) |
/// | `runningNoOBD` | link changes without reaching `polling` | `runningNoOBD` (nothing happens) |
/// | `runningNoOBD` | `stopNoOBDNavigate()` (the user's Stop) | `off`; the start rule stays off until background → active, or `polling` |
/// | any but `off` | Record starts | `off`: session ended before Record's clock exists |
/// | any but `off` | `willTerminate`, `disableNavigate()`, the demo's hold | `off` |
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
    /// UX-7: a no-OBD run (network/GNSS fixes, roads and the IMU; no
    /// adapter). No calibration phase, no auto-stop; see the type's doc.
    /// Its UI state is `RecordingSession.noOBDNavigation`.
    case runningNoOBD

    /// A session exists: every state but `off`.
    var isActive: Bool { self != .off }

    /// A no-OBD run (UX-7): `runningNoOBD`.
    var isNoOBD: Bool { self == .runningNoOBD }
}

/// Navigate's timings. The defaults are the decided ones (UX-1 (a), (c));
/// tests pass short ones.
struct NavigateConfiguration: Hashable, Sendable {
    /// The keep-still phase when the speed at connect is 0.
    var stillCalibration: Duration = .seconds(5)
    /// Navigate stops after this long continuously without `polling`.
    var autoStopAfter: Duration = .seconds(300)
    /// UX-7 no-OBD start rule (see `NavigateState`): a no-OBD run starts
    /// after this long with every condition holding. nil: never (the demo
    /// drive's session).
    var noOBDStartAfter: Duration? = .seconds(30)
}

/// UX-7: what the UI shows about the running no-OBD run
/// (`RecordingSession.noOBDNavigation`), read from the navigation service
/// once a second (`NavigationService.noOBDStatus(generation:)`). Display
/// only: nothing here reaches a sink or an engine.
struct NoOBDNavigationStatus: Hashable, Sendable {
    /// "Position uncertain": `LiveNavigationRun.positionUncertainAfterS`
    /// (120 s) or more without an accepted fix or pin
    /// (`LiveNavigationRun.positionUncertain(at:)`); false again from the
    /// next accepted fix or applied pin.
    var positionUncertain = false
    /// The engine's speed estimate, km/h: **estimated** (never an OBD or a
    /// GPS reading); nil while the engine has no estimate.
    var estimatedSpeedKmh: Double?
    /// The latest accepted fix or pin on the run's clock
    /// (`LiveNavigationRun.lastFixOrPinT`; the run's first input until one);
    /// nil before the first input.
    var lastFixOrPinT: MonotonicTimestamp?
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
    /// starts. True for a recording and for Navigate (D7 revised
    /// 2026-10-20: Navigate keeps running with the screen locked).
    var holdsBackgroundLocation: Bool { get }
    /// Whether `RecordingOnlySource`s start with this run: true for a
    /// recording, false for Navigate (R81.1-1: the altimeter, the only
    /// source behind Motion & Fitness, feeds no navigation input).
    var startsRecordingOnlySources: Bool { get }
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
    /// Why the session ended, for the estimate saved at its end (UX-20):
    /// the auto-stop marks the engine off. Handed to the service with the
    /// feed.
    let runEnd = NavigationRunEnd()
    /// D7 revised (2026-10-20): like a recording, so the estimate continues
    /// with the screen locked; released when the session ends (its sources
    /// stop: `disableNavigate`, auto-stop, Record's Start, `willTerminate`).
    let holdsBackgroundLocation = true
    /// No altimeter in Navigate (R81.1-1): its `baro` rows reach no
    /// navigation input, and starting it is what asks for Motion & Fitness.
    let startsRecordingOnlySources = false
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

    /// UX-7: a no-OBD run (`NavigateState.runningNoOBD`): its feed says
    /// so (`RecordingNavigationFeed.noOBD`), it has no calibration phase and
    /// no auto-stop.
    let noOBD: Bool

    init(generation: Int, clock: SessionClock, navigationTap: NavigationTap, noOBD: Bool = false) {
        self.generation = generation
        self.clock = clock
        self.navigationTap = navigationTap
        self.noOBD = noOBD
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
