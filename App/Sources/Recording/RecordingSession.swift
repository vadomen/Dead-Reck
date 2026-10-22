import DriveLoggerCore
import Foundation
import Observation
import os
import SwiftUI
import UIKit

/// What the recorder is doing.
enum RecordingState: Hashable, Sendable {
    case idle
    /// First phase of every recording: the clock, writer and sources are
    /// already running and the user keeps the car and phone still, so the
    /// samples needed for bias estimation are in the file, bracketed by
    /// `calibrationStart` / `calibrationEnd` rows.
    case calibrating
    case recording
    case stopping
    /// Writing failed (`ENOSPC`, I/O error — anything on
    /// `LogFileWriter.failures`, or a `failure` in the final `finish()`) and
    /// the recording was stopped. Shown to the user, because the failure row
    /// may not have reached the file. `unwrittenEvents` is
    /// `LogFileSummary.unwrittenEvents` plus anything the sink refused after
    /// `finish()` (`LogSink.dropped`). Never entered for low free space: that
    /// is a clean stop (rule 2 on `RecordingSession`).
    case failed(reason: String, unwrittenEvents: Int)
}

/// Why a recording ended through the normal stop path. The raw value is the
/// `detail` of the `lifecycle` `stop` row: an on-disk string, defined and
/// pinned in Core (`LifecycleSample.StopReason`, R3-4).
typealias RecordingStopReason = LifecycleSample.StopReason

/// Why `start` is refused right now. `canStart` is `startBlocker == nil`.
enum RecordingStartBlocker: Error, Hashable, Sendable {
    /// A recording is starting, running or stopping.
    case recordingInProgress
    /// Free space is strictly below `requiredBytes`, the warning threshold
    /// (rule 3 on `RecordingSession`). No user choice overrides it.
    case lowDiskSpace(availableBytes: Int64, requiredBytes: Int64)
    /// The link is not polling and the user has not chosen to record without
    /// OBD (docs/PLAN.md §3.3).
    case obdNotReady
    /// The demo drive (REL-DEMO) is running: stop it first. The session is
    /// held for it (`RecordingSession.holdForDemo()`).
    case demoDriveRunning
}

/// Live numbers for the dashboard. Display only — never written to the log.
struct LiveStatus: Hashable, Sendable {
    /// Latest vehicle speed from the engine ECU (`7E8`), any time the link
    /// polls — before a recording too. nil when the link isn't connected,
    /// and from Start until the recording's first speed reading (M8.1-3: a
    /// manual fix's `obdSpeedT` must be an `obd` row of its own file); the
    /// same from a Navigate session's start (UX-1), so its pins are staged
    /// exactly as a recording's.
    var obdSpeedKmh: Double?
    /// Speed of the latest reference fix, while recording or navigating
    /// (UX-1). Reference only,
    /// never written. From any `LiveReferenceFixReporting` source: the
    /// phone's `ReferenceLocationSource`, or on the simulator Core's
    /// `SimulatedLocationSource` (a constant 50 km/h, M2-S2). nil when not
    /// recording, before the first fix and whenever the fix has no valid
    /// speed.
    var gpsSpeedKmh: Double?
    /// The latest reference fix, while recording or navigating (UX-1; for
    /// the manual-fix gate; the Map tab reads `RecordingSession.latestFix`,
    /// set on arrival, R24.1-1). Display
    /// only: never written and never an input. Same source, 1 Hz cadence and
    /// nil rules as `gpsSpeedKmh` — nil when not recording and before the
    /// first fix. Unlike `gpsSpeedKmh` it is the whole fix, kept even when
    /// its speed is invalid (negative).
    var referenceFix: LocationSample?
    /// Successful polls per second, from the link.
    var obdHz: Double = 0
    /// `motion` rows per second over the last `stats` window (every 10 s).
    var motionHz: Double = 0
    var elapsed: TimeInterval = 0
    var fileBytes: Int = 0
    /// Set by a `.low` disk-space notice; drives the UI warning. Stays set
    /// until the recording ends: the writer re-arms silently, so a recovery
    /// is never observed.
    var lowDiskSpaceWarning: Bool = false
    /// Free bytes carried by the most recent `DiskSpaceNotice`, or by the
    /// start check. Not a live reading: the writer reports only at crossings.
    var availableDiskBytes: Int64?
}

/// A manual fix that has been tapped and is waiting out its undo window
/// (`RecordingSession.stageManualFix`). Written to the log when the window
/// closes, with `t` = `sample.pressedT` = the tap time.
struct PendingManualFix: Hashable, Identifiable, Sendable {
    /// Unique across recordings within one session object.
    let id: Int
    /// The recording whose clock `sample.pressedT` is on.
    let generation: Int
    /// The row as it will be written: coordinate, span and speeds as at the tap.
    let sample: ManualFixSample
}

/// What a live consumer of navigation input needs about one run (N4 A,
/// UX-1): a recording (Record mode) or a Navigate run, which writes nothing.
/// Handed to `RecordingSession.onNavigationFeed` once per run, at its start.
///
/// `inputs` carries every `motion`, `location`, `obd` and `manualFix` event of
/// the run in the order the sink saw them (`LogSink`, "Tap": a recording's
/// file order); it ends once the run's sink has finished (for a recording:
/// its writer) and the buffered inputs are taken. Single consumer. If the
/// consumer falls `NavigationTap.defaultBufferLimit` inputs behind, the
/// oldest are dropped and counted in `droppedInputs`; a log never loses a
/// row to the tap.
///
/// The two kinds differ only in `output`: the engine is fed the same way
/// (same seed from `header.sessionID`, same inputs in the same order), so
/// the same sources give bit-identical estimates in both.
struct RecordingNavigationFeed: Sendable {
    /// Where a run's files go.
    enum Output: Sendable, Hashable {
        /// Record: the `.jsonl.gz` being written and where its navigation
        /// sidecar goes (`LogStore.navSidecarURL(for:)`);
        /// `NavigationService` (N4 B) writes the sidecar.
        case recording(recordingURL: URL, sidecarURL: URL)
        /// Navigate (UX-1): no recording and no sidecar; the service creates
        /// no file and no directory for this run.
        case navigateOnly
    }

    /// The run this feed belongs to. Unique across every feed handed to one
    /// `NavigationService`, recordings and Navigate runs alike: the service
    /// keys its runs by it, and two runs can overlap while one drains.
    let generation: Int
    /// The run's header (seed: `sessionID`). For a recording, the header
    /// handed to the writer, which encodes it to the file's first line
    /// (`startedAt` here still has the sub-second part the file's ISO 8601
    /// date drops); in Navigate, built the same way and never written.
    let header: LogHeader
    /// The run's one clock: every input's `t` is on it.
    let clock: SessionClock
    let output: Output
    /// The tap behind `inputs`.
    let tap: NavigationTap
    /// Writes the `roadPacks` lifecycle row with this `detail` if the
    /// recording is still running; called by the navigation service when
    /// its library scan finishes. Does nothing after Stop and after the
    /// first call. Default: no-op (feeds built without a session, and
    /// Navigate runs: no recording, no row).
    var recordRoadPacks: @Sendable (String) -> Void = { _ in }
    /// How the run ended, as far as the session knows it (UX-20): set before
    /// the tap finishes, read by the navigation service at the run's end for
    /// the saved estimate's class (`engineOff`). Default: a fresh one,
    /// never set.
    let runEnd: NavigationRunEnd

    init(generation: Int, header: LogHeader, clock: SessionClock, output: Output, tap: NavigationTap,
         recordRoadPacks: @escaping @Sendable (String) -> Void = { _ in }, runEnd: NavigationRunEnd = NavigationRunEnd()) {
        self.generation = generation
        self.header = header
        self.clock = clock
        self.output = output
        self.tap = tap
        self.recordRoadPacks = recordRoadPacks
        self.runEnd = runEnd
    }

    /// A recording's feed: `output` is `.recording(recordingURL:sidecarURL:)`.
    init(generation: Int, header: LogHeader, clock: SessionClock, recordingURL: URL, sidecarURL: URL,
         tap: NavigationTap, recordRoadPacks: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(generation: generation, header: header, clock: clock,
                  output: .recording(recordingURL: recordingURL, sidecarURL: sidecarURL), tap: tap,
                  recordRoadPacks: recordRoadPacks)
    }

    /// The `.jsonl.gz` being written; nil in Navigate.
    var recordingURL: URL? {
        if case .recording(let url, _) = output { url } else { nil }
    }

    /// Where the navigation sidecar goes; nil in Navigate (none is written).
    var sidecarURL: URL? {
        if case .recording(_, let url) = output { url } else { nil }
    }

    var inputs: AsyncStream<NavigationInput> { tap.inputs }
    /// Inputs dropped so far because the consumer fell behind.
    var droppedInputs: Int { tap.droppedInputs }
}

/// What the session knows about why a run ended (UX-20), handed to the
/// navigation service with the feed (`RecordingNavigationFeed.runEnd`).
/// Written on the main actor before the run's tap finishes, read by the
/// service after the feed has drained.
final class NavigationRunEnd: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    init() {}

    /// The car's engine is known to be off: Navigate's auto-stop (no OBD
    /// for `autoStopAfter`). The saved estimate is then classed with
    /// `engineOff` (`NavigationEngine.restoreClass(at:engineOff:)`).
    var engineOff: Bool { state.withLock { $0 } }

    func markEngineOff() {
        state.withLock { $0 = true }
    }
}

/// Wires sensors, the OBD link and the writer into one recording.
///
/// **One clock.** Each recording creates exactly one `SessionClock` (on
/// `uptime`, CoreMotion's timebase) and hands it to every source; link events
/// are converted with `clock.timestamp(uptimeSeconds:)` from the uptime they
/// carry (`LogEvent.rows(for:adapter:clock:)`); the recorder's own rows use
/// `clock.now()`. `Date()` is read once per recording, for the header.
///
/// **Link events.** The session subscribes to `link.linkEvents()` once, at
/// init, and keeps the subscription for its lifetime (the stream has one
/// subscriber; nothing else may call `linkEvents()`). Events are written
/// while a recording is calibrating or recording and drive `live.obdSpeedKmh`
/// / `live.obdHz` at all times.
///
/// **Start-up init (M4).** The link usually connects and initialises before
/// Start, so at Start the session writes `link.lastInitEvents` — the current
/// connection's BLE `→ connected` and init (`ATZ` … `ATSH7E0`, probe,
/// `adapter`, then the latest `adapter` and transition after it) — following that property's dedup contract: replay only at
/// Start, live events after that. In one synchronous main-actor step (no
/// suspension between the reads and the writes) it reads `lastInitEvents`
/// and `deliveredLinkEventCount`, writes the replay rows through
/// `LogEvent.rows(for:adapter:clock:)` with `adapter: link.adapter` on the
/// recording's clock — stamped from each event's own uptime, so they have
/// negative `t`, never clamped — and then lets its link-event loop skip the
/// next `deliveredLinkEventCount − consumed` events (delivered before Start:
/// either in the replay or pre-Start poll traffic, which is not written).
/// Placement: right after the `start` row, before any other row; the `start`
/// row stays the first line, and the first `stats` window still starts at
/// `t ≈ 0` (the writer starts it at the first row it sees). Each recording
/// replays once, at its own Start; an init during a recording arrives live.
/// Nothing is replayed when the link isn't connected at Start (M6.1-1: the
/// link then returns an empty `lastInitEvents`); the skip still applies, so
/// no pre-Start event is written either way.
///
/// **Rows it writes** (`lifecycle` unless noted): `start` (detail `without
/// OBD: …` when started without a polling link), the replayed start-up
/// init (`link`, `elm`, `adapter`; above), `locationAuthorization` (one per
/// `LocationAuthorizationReporting` source, after the source rows: phone
/// builds), `roadPacks` (once, when the road-pack library scan started at
/// Start finishes while the recording is still running; none after Stop and
/// none without a library), `calibrationStart` /
/// `calibrationEnd`, `stop` (detail = stop reason), `manualFix` (format v3,
/// `stageManualFix`, written when its undo window closes or at Stop), `background` /
/// `foreground`, `memoryWarning`, `thermalState` (at start when not nominal,
/// and on every change), `protectedDataUnavailable`, `lowDiskSpace`, `error`
/// (a source that is unavailable or failed to start, no background location
/// session, a write failure, a writer queue backlog over `max(2 s of data,
/// 200)`), and a `stats` row every `statsInterval` (10 s) plus a final one
/// after the `stop` row. Flushes on entering the background (inside a
/// background task), on memory warnings, and on `willTerminate` (waiting for
/// it; no row). Keeps the screen awake (idle timer off) from start until
/// the recording ends.
///
/// **Ending a recording.** Two paths, each run once however many callers
/// race into it (later callers wait for it):
/// - *Stop* (`stop(reason:)`, the user or rule 2): state `stopping`, set
///   synchronously by `stop` before it first suspends (R4.1-1); every
///   source is stopped (no event reaches the sink after that) and link rows
///   are no longer written; an in-flight `stats` row is awaited so it lands
///   before the `stop` row; `calibrationEnd` (detail `interrupted by stop`)
///   if still calibrating; the `stop` row; the final `stats` row;
///   `finish()`. Then `idle` with `lastStopReason`, or rule 4's `failed`.
/// - *Write failure* (rule 4).
///
/// Each path holds a background task (`DriveLogger.stop`,
/// `DriveLogger.writeFailure`) from before its sources stop until the file
/// is finished (R4.1-3): stopping the location source ends the background
/// location session that kept a locked phone running.
///
/// **Disk space: warn, then stop at a floor.** This is the recorder's one
/// low-disk policy. The thresholds are `warningFreeBytes` (default 200 MB)
/// and `stopFreeBytes` (default 50 MB), handed unchanged to `LogFileWriter`,
/// whose `diskSpaceNotices` drive rules 1 and 2. Notices from a writer that is
/// not the current recording's are ignored (R3-2), and so is every notice that
/// arrives after the `stop` row was queued (R3-1).
///
/// 1. **Warning** — on `.low(availableBytes:)`: write a `lifecycle`
///    `lowDiskSpace` row with detail `"warning: <bytes> free"`, set
///    `live.lowDiskSpaceWarning` and `live.availableDiskBytes`, and **keep
///    recording**.
/// 2. **Floor** — on `.critical(availableBytes:)`: write a `lifecycle`
///    `lowDiskSpace` row with detail `"floor: <bytes> free"`, then
///    `stop(reason: .lowDiskSpace)`. This is the normal stop path, not
///    `failed`: the `stop` row (detail `"lowDiskSpace"`) and the final
///    `stats` row are written, `finish()` closes the file normally, `state`
///    returns to `idle` and `lastStopReason` is `.lowDiskSpace` for the UI.
///    The floor row **precedes the `stop` row in write order**; rows of other
///    kinds may sit between them. When one reading yields both notices, both
///    rows are written, warning first. Applies while calibrating too. A
///    `.critical` while already stopping (before the `stop` row is queued)
///    writes its row and does not start a second stop; after the `stop` row
///    is queued it is ignored (R3-1).
/// 3. **Start** — refused strictly below `warningFreeBytes`
///    (`DiskSpacePolicy.canStart`): `canStart` is false and `startBlocker`
///    is `.lowDiskSpace(availableBytes:requiredBytes:)`, derived from the
///    stored `availableDiskBytes` (R3-5: refreshed off the main actor at
///    init, on becoming active, after `deleteRecording`, after each
///    recording and every `diskRefreshInterval`). `start` re-reads free space
///    before creating anything and throws that blocker if it is now below;
///    no file is created. A `diskSpace` provider that throws does not block
///    start (the writer treats an unreadable volume the same way); rule 4
///    remains the backstop.
/// 4. **Write failures** — anything on `LogFileWriter.failures` (`ENOSPC`,
///    I/O errors, a failed truncate or `fsync`), each reported once by the
///    writer (R1-9): stop every source, then write a `lifecycle` `error` row
///    (detail `write failed: …`; it may not reach the disk), both before the
///    first suspension, so no row of any kind follows it (R32.2-1); call
///    `finish()`, enter `failed(reason:unwrittenEvents:)`. No `stop` row and
///    no final `stats` row; a `stats` row in flight and a pending manual fix
///    are dropped. While *stopping* — from the moment `stop()` is called
///    (it sets `stopping` synchronously, R4.1-1), or while any end path is
///    in progress — a delivered failure only writes its `error` row and is
///    remembered; the stop path then ends in `failed` (R3-2). A final `finish()` that reports a `failure` — after any stop,
///    user or rule 2 — also ends in `failed`, with no further row (R3-3).
///    This is the only way into `failed`. `flush()` throws are not reports
///    (the writer delivers each failure once on `failures`) and are ignored.
///
/// Disk-space notices are advisory and never lead to `failed`; write
/// failures never produce a warning.
///
/// **Start and calibration (R3-2).** `start` re-checks the state after every
/// suspension. Stop (or rule 2, or rule 4) during `calibrating` ends the
/// recording; when the calibration wait then returns, `start` sees the
/// recording is gone, stopping, or past its last row (rule 4's error row is
/// queued before the state changes, R32.3-2) and neither writes
/// `calibrationEnd` nor sets `recording`. `isStarting` is cleared as soon
/// as the recording exists (R4.1-2), so once such a stop returns, `startBlocker` no longer reports
/// `.recordingInProgress` and a new recording can start while the old
/// `start` call is still in its calibration wait.
///
/// **Background execution (R4.1-5).** The app keeps running with the phone
/// locked only while a `BackgroundExecutionProviding` source runs (on a
/// phone: `ReferenceLocationSource`, which holds a
/// `CLBackgroundActivitySession`). When the sources include at least one
/// such source and none of them can provide it — location denied or
/// restricted, or (during a recording) it did not start —
/// `backgroundRiskWarning` says so, before Start and during the recording,
/// and the recording gets one `lifecycle` `error` row with detail
/// `backgroundRiskDetail` ("no background location session; recording may
/// pause while locked"): right after the source rows at start, or when the
/// source's availability is lost mid-recording. The recording itself goes
/// on. A suite with no such source (the simulator's, tests') makes no claim
/// and produces neither.
///
/// **Navigation feed (N4 A).** Each recording creates one `NavigationTap` and
/// hands its closure to the writer's sink, so every navigation input the
/// sink accepts is also yielded, in file order, to a bounded stream. The seam
/// for a live consumer is `onNavigationFeed`: set it once (`AppServices`),
/// and it is called with a `RecordingNavigationFeed` synchronously in
/// `start`, after the file exists and before the `start` row or any source
/// sample — so no input of the recording precedes the hand-off. The feed's
/// stream ends when the recording's writer has finished (either end path).
/// The writer, the rows and the `stats` rows are unchanged by the tap.
///
/// **Navigate (UX-1).** Off until `enableNavigate(_:)` (the app enables it
/// at launch; tests that don't are Record-only and see exactly the session
/// they always did). Then, whenever the link is `polling` and no recording
/// is starting, running or ending, a Navigate session runs: one
/// `SessionClock` on the same `uptime`, a `LogHeader` built by the same
/// `makeHeader` as a recording's (never written; its `sessionID` seeds the
/// engine), a `NavigationTap` behind a `LogSink.tapOnly` sink, every source
/// started by the same `startSources` and link events forwarded and
/// replayed by the same `handleLinkEvent` / `replayStartupInit` as in a
/// recording — so the engine's inputs are those of a recording of the same
/// sensors — and the feed (`output: .navigateOnly`) handed to
/// `onNavigationFeed` before any input. No file, directory, sidecar, marker
/// or `stats` row exists for it: `lifecycle` rows go into the tap-only sink
/// and are discarded there, and none of the Record-only rows (`start`,
/// thermal, authorisation, background risk, `stats`, …) is even built.
/// States and transitions: `NavigateState`. Generations come from the same
/// counter as recordings', so the service never sees two runs with one key.
///
/// - Pins work as in a recording (same gate, same undo window); a committed
///   fix goes into the tap-only sink, so the engine resets on it and nothing
///   stores it. A fix still in its undo window when the session ends, or
///   when the app enters the background, is committed then (as Stop and
///   R14.3-3 do for a recording).
/// - The link leaving `polling` doesn't stop anything; when it returns the
///   same session goes on and the new connection's rows arrive live. After
///   `autoStopAfter` continuously without `polling` the session ends:
///   timers cancelled, pending fixes committed, sources stopped, sink and
///   tap finished (so the service's run ends). A later `polling` starts a
///   fresh session (new clock, generation and `sessionID`).
/// - Record's Start ends the Navigate session completely, after Start's
///   own checks pass and before Record's clock exists, then starts the
///   recording exactly as from idle (its own Start, clock and start-up
///   replay; the dedup skip is taken afresh). When the recording ends (stop
///   or write failure) or a Start throws after that, Navigate resumes with a
///   fresh session if the link is `polling`.
/// - The screen stays awake while either mode runs; the idle timer is only
///   set when that changes, so the Navigate → Record → Navigate switch never
///   turns it off in between.
/// - Background location as in Record (D7 revised 2026-10-20):
///   `BackgroundLocationConfigurable` sources start with
///   `holdsBackgroundLocation` true, so the session keeps running with the
///   screen locked; it is released when the session's sources stop.
///   Background and foreground reset nothing and write nothing: the engine
///   keeps its state, and any time the app is suspended anyway is a gap in
///   every stream like any other. On background `onFlush` runs inside a
///   background task (UX-20: the service saves the estimate it restores
///   from after a kill). `backgroundRiskWarning` stays a Record
///   concern.
/// - `willTerminate` ends the session.
@MainActor
@Observable
final class RecordingSession {
    private(set) var state: RecordingState = .idle
    private(set) var live = LiveStatus()
    /// The latest reference fix of the live run (recording or Navigate), set
    /// the moment a `LiveReferenceFixReporting` source shows it — on
    /// arrival, not on the 1 s `live` tick (R24.1-1). **For the Map tab
    /// only**: never written, never an input, and the manual-fix gate keeps
    /// reading `live.referenceFix`. Set from the source's own display hook,
    /// after the fix went to the sink, so nothing that reaches the sink or
    /// the navigation tap changes. Its own property, outside `live`, so a fix
    /// re-renders only views that read it. nil when no run is live, and from
    /// a run's start until its first fix.
    private(set) var latestFix: LocationSample?
    /// The plain GPS position while **no run is live** (R61.1-4): from the
    /// map-only `DisplayLocationProviding` feed, which runs only when the
    /// app is active, Navigate has no session, no recording is starting or
    /// running, and location is already allowed. Separate from `latestFix`
    /// so that stays "the live run's fix": the two are never both non-nil
    /// (a run's start stops the feed and clears this first). For the Map tab
    /// only: never written, never an input, no sink, no tap. nil when the
    /// feed does not run, and from its start until its first fix.
    private(set) var displayFix: LocationSample?
    /// REL-DEMO: the demo drive runs on its own session, so this one is held
    /// (`holdForDemo()`): no Navigate session, no map-only position feed
    /// (none of this session's sensors run), and Start refused with
    /// `.demoDriveRunning`. Memory only; `releaseDemoHold()` ends it.
    private(set) var isHeldForDemo = false
    /// The file being written, nil when no recording is active.
    private(set) var currentFile: URL?
    /// How the last recording ended through `stop`, for the UI ("Stopped:
    /// low disk space"). `nil` before the first stop and after a write
    /// failure, which `state` reports instead.
    private(set) var lastStopReason: RecordingStopReason?
    /// Free bytes on the recordings volume from the last refresh (R3-5);
    /// nil until the first reading or while the provider can't read it.
    /// `startBlocker` is derived from it.
    private(set) var availableDiskBytes: Int64?
    /// The user's explicit choice to record without OBD (docs/PLAN.md §3.3),
    /// for `startBlocker`. `start(allowWithoutOBD:)` takes its own argument.
    var allowsRecordingWithoutOBD = false
    /// A `start` call is between its checks and creating the file.
    private(set) var isStarting = false
    /// Record is active (UX-8: road-pack downloads pause while it is): from
    /// the first line of `start`, before its first suspension and so before
    /// any clock, file, writer or source exists, until the recording's end
    /// path has returned — the writer's `finish()` done and the state `idle`
    /// or `failed`. A `start` that throws clears it when it throws. Exactly
    /// `isStarting || recording != nil || ending != nil`; never set by
    /// Navigate. Changes are also handed to `onRecordActiveChange`.
    private(set) var isRecordActive = false
    /// Called synchronously on the main actor with every change of
    /// `isRecordActive`, in order, at the moment it changes (nothing is
    /// coalesced). Set it once, before any `start` (`AppServices`, at
    /// launch); it is not called with the current value when set. Keep it
    /// cheap: it runs inside `start` and the end path.
    @ObservationIgnored var onRecordActiveChange: (@MainActor (Bool) -> Void)?
    /// Why the app may be suspended while the phone is locked, so the
    /// recording may pause; nil when nothing is known to be wrong (R4.1-5).
    /// For the dashboard to warn on, before Start and during a recording.
    /// It does not block Start.
    ///
    /// Non-nil when the sources include at least one
    /// `BackgroundExecutionProviding` source (on a phone,
    /// `ReferenceLocationSource`) and none of them can keep the app running:
    /// each is unavailable (location denied or restricted) or, during a
    /// recording, did not start. The text is user-facing: a sentence that
    /// begins "No background location session" followed by each source's
    /// reason. Always nil when no source provides background execution (the
    /// simulator suite).
    ///
    /// Kept current without the UI's help: refreshed at init, whenever such
    /// a source reports an availability change (the location prompt
    /// answered, authorisation changed, or — M4 — a `kCLErrorDenied` while
    /// authorisation reads denied or restricted; a `kCLErrorDenied` while
    /// authorised is transient and changes nothing, since `availability`
    /// still reads available), on `handleScenePhase(.active)`
    /// (back from Settings), and when a recording starts and ends.
    private(set) var backgroundRiskWarning: String?
    /// Called once per recording with its navigation feed (see the type's
    /// doc, "Navigation feed"), and once per Navigate session with its
    /// `.navigateOnly` feed (UX-1). Runs synchronously on the main actor
    /// inside `start` (or the Navigate start), before any row is written or
    /// any input tapped: keep it cheap (start a task to consume `inputs`,
    /// don't consume here). nil: nobody listens, and the tap's buffer simply
    /// drops the oldest inputs; the log is unaffected.
    @ObservationIgnored var onNavigationFeed: (@MainActor (RecordingNavigationFeed) -> Void)?
    /// Awaited inside the background task of the flush on `.background` and
    /// on a memory warning, after the log's own flush (R14.1-4): `AppServices`
    /// flushes the navigation sidecar here, which is otherwise flushed only
    /// every 10 s, and the service saves the estimate (UX-20). Also awaited
    /// on `.background` while Navigate runs (no log to flush first).
    @ObservationIgnored var onFlush: (@Sendable () async -> Void)?
    /// Navigate mode (UX-1; see the type's doc and `NavigateState`). Always
    /// `.off` until `enableNavigate(_:)`.
    private(set) var navigateState: NavigateState = .off
    /// When the current Navigate session began its still phase (UX-1 part 2:
    /// the map's countdown is `stillCalibration` from here). Display only;
    /// set at the session's start, nil when no session runs.
    private(set) var navigateStartedAt: ContinuousClock.Instant?

    @ObservationIgnored private let link: any OBDLinkServicing
    @ObservationIgnored private let sources: [any SensorSource]
    /// The map-only position feed (R61.1-4); see `updateDisplayLocation`.
    @ObservationIgnored private let displayLocation: (any DisplayLocationProviding)?
    @ObservationIgnored private let store: LogStore
    @ObservationIgnored private let uptime: any UptimeSource
    @ObservationIgnored private let diskSpace: any DiskSpaceProvider
    @ObservationIgnored private let warningFreeBytes: Int64
    @ObservationIgnored private let stopFreeBytes: Int64
    @ObservationIgnored private let sensorConfiguration: SensorConfigRecord?
    @ObservationIgnored private let notes: String?
    @ObservationIgnored private let app: AppIdentity
    @ObservationIgnored private let device: DeviceIdentity
    @ObservationIgnored private let flushInterval: Duration
    @ObservationIgnored private let statsInterval: Duration
    @ObservationIgnored private let diskRefreshInterval: Duration
    @ObservationIgnored private let setIdleTimerDisabled: @MainActor (Bool) -> Void
    /// Begins a background task with the given name and returns the call
    /// that ends it (idempotent).
    @ObservationIgnored private let beginBackgroundTask: @MainActor (String) -> @MainActor () -> Void
    /// How long a staged manual fix can be undone before it is written.
    @ObservationIgnored let manualFixUndoWindow: Duration
    @ObservationIgnored private var nextPendingFixID = 0

    @ObservationIgnored private var recording: ActiveRecording?
    /// The running Navigate session (UX-1); never at the same time as
    /// `recording`.
    @ObservationIgnored private var navigate: NavigateRun?
    /// Non-nil while Navigate is enabled.
    @ObservationIgnored private var navigateConfiguration: NavigateConfiguration?
    /// Bumped by `enableNavigate`/`disableNavigate`: a link-state observation
    /// armed under an older token stops re-arming.
    @ObservationIgnored private var linkObservationToken = 0
    /// The last value handed to `setIdleTimerDisabled`.
    @ObservationIgnored private var idleTimerDisabled = false
    /// Every header's `sessionID` (a recording's and a Navigate session's).
    @ObservationIgnored private let makeSessionID: @MainActor () -> UUID
    /// One counter for recordings and Navigate sessions alike.
    @ObservationIgnored private var generation = 0
    /// The end path in progress (stop or write failure); later callers wait.
    @ObservationIgnored private var ending: Task<Void, Never>?
    @ObservationIgnored private var lastScenePhase: ScenePhase?
    @ObservationIgnored private var linkTask: Task<Void, Never>?
    @ObservationIgnored private var diskRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Events the `linkEvents()` loop has handled since the subscription,
    /// whether or not a recording was running: `consumed` in the
    /// `lastInitEvents` dedup contract. Internal for tests.
    @ObservationIgnored private(set) var consumedLinkEvents = 0
    /// `replyUptime` of the reading behind `live.obdSpeedKmh`: the OBD age
    /// in the `manualFix` row's `obdSpeedT`. Set and
    /// cleared with it, at Start too (M8.1-3).
    @ObservationIgnored private var obdSpeedUptime: Double?

    /// `detail` of the `lifecycle` `error` row written when a recording has
    /// no background execution (R4.1-5). Free text under the existing
    /// `error` event, not new on-disk vocabulary; docs/LOG_FORMAT.md lists
    /// it with the other `error` details.
    nonisolated static let backgroundRiskDetail = "no background location session; recording may pause while locked"

    /// - Parameters:
    ///   - sensorConfiguration: written to the header's `sensors` section.
    ///   - notes: written to the header's `notes` (e.g. "simulated sensors").
    ///   - flushInterval, statsInterval, diskRefreshInterval: 2 s, 10 s and
    ///     60 s in the app; shorter in tests.
    ///   - setIdleTimerDisabled: `UIApplication.shared.isIdleTimerDisabled`
    ///     in the app; injectable for tests.
    ///   - beginBackgroundTask: `UIApplication.beginBackgroundTask` in the
    ///     app (`systemBackgroundTask`); injectable for tests.
    ///   - makeSessionID: every header's `sessionID`; `UUID()` in the app,
    ///     fixed in tests that compare engine output across sessions.
    /// - Precondition: `stopFreeBytes < warningFreeBytes`.
    init(
        link: any OBDLinkServicing,
        sources: [any SensorSource],
        displayLocation: (any DisplayLocationProviding)? = nil,
        store: LogStore,
        uptime: any UptimeSource = SystemUptimeSource(),
        diskSpace: any DiskSpaceProvider = VolumeDiskSpaceProvider(),
        warningFreeBytes: Int64 = DiskSpacePolicy.defaultWarningFreeBytes,
        stopFreeBytes: Int64 = DiskSpacePolicy.defaultStopFreeBytes,
        sensorConfiguration: SensorConfigRecord? = nil,
        notes: String? = nil,
        app: AppIdentity = AppInfo.read().identity,
        device: DeviceIdentity = DeviceInfo.current(),
        flushInterval: Duration = .seconds(2),
        statsInterval: Duration = .seconds(10),
        diskRefreshInterval: Duration = .seconds(60),
        manualFixUndoWindow: Duration = .seconds(3),
        setIdleTimerDisabled: @escaping @MainActor (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 },
        beginBackgroundTask: @escaping @MainActor (String) -> @MainActor () -> Void = RecordingSession.systemBackgroundTask,
        makeSessionID: @escaping @MainActor () -> UUID = { UUID() }
    ) {
        precondition(stopFreeBytes < warningFreeBytes, "stopFreeBytes must be below warningFreeBytes")
        self.link = link
        self.sources = sources
        self.displayLocation = displayLocation
        self.store = store
        self.uptime = uptime
        self.diskSpace = diskSpace
        self.warningFreeBytes = warningFreeBytes
        self.stopFreeBytes = stopFreeBytes
        self.sensorConfiguration = sensorConfiguration
        self.notes = notes
        self.app = app
        self.device = device
        self.flushInterval = flushInterval
        self.statsInterval = statsInterval
        self.diskRefreshInterval = diskRefreshInterval
        self.setIdleTimerDisabled = setIdleTimerDisabled
        self.beginBackgroundTask = beginBackgroundTask
        self.manualFixUndoWindow = manualFixUndoWindow
        self.makeSessionID = makeSessionID

        // The one subscription, taken now so nothing the link reports after
        // launch is missed (single subscriber; see the type's doc).
        let events = link.linkEvents()
        linkTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handleLinkEvent(event)
            }
        }
        let refreshEvery = diskRefreshInterval
        diskRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshDiskSpace()
                try? await Task.sleep(for: refreshEvery)
            }
        }
        observeSystemNotifications()
        for source in sources {
            guard let keeper = source as? any BackgroundExecutionProviding else { continue }
            keeper.onAvailabilityChange = { [weak self] in self?.backgroundAvailabilityChanged() }
        }
        refreshBackgroundRisk()
        displayLocation?.onFix = { [weak self] fix in self?.displayFixArrived(fix) }
        displayLocation?.onAuthorizationChange = { [weak self] in self?.updateDisplayLocation() }
    }

    // MARK: - Start

    /// `startBlocker == nil`. Start is allowed when nothing is recording,
    /// free space is at or above `warningFreeBytes` (rule 3) and the link is
    /// polling or the user explicitly chose to record without OBD
    /// (`allowsRecordingWithoutOBD`, docs/PLAN.md §3.3).
    var canStart: Bool {
        startBlocker == nil
    }

    /// Why start is refused, `nil` when it is allowed. `.lowDiskSpace` comes
    /// before `.obdNotReady`, because no user choice overrides it. Derived
    /// from the stored `availableDiskBytes` (R3-5), never a synchronous disk
    /// query; an unknown reading does not block.
    var startBlocker: RecordingStartBlocker? {
        if isStarting || recording != nil { return .recordingInProgress }
        if isHeldForDemo { return .demoDriveRunning }
        if let available = availableDiskBytes,
           !DiskSpacePolicy.canStart(availableBytes: available, warningFreeBytes: warningFreeBytes) {
            return .lowDiskSpace(availableBytes: available, requiredBytes: warningFreeBytes)
        }
        if !allowsRecordingWithoutOBD, !isLinkPolling { return .obdNotReady }
        return nil
    }

    /// Creates the clock, the file and starts every source, then runs the
    /// keep-still calibration as the recording's first phase (`calibrating`),
    /// then moves to `recording`. Returns when calibration is over (or the
    /// recording ended during it). Pass `calibration: .zero` to skip it; the
    /// rows are still written, back to back, so a reader can tell.
    ///
    /// Throws `RecordingStartBlocker.lowDiskSpace` if free space is below
    /// `warningFreeBytes` when it is called (rule 3), `.obdNotReady` if the
    /// link isn't polling and `allowWithoutOBD` is false, and
    /// `.recordingInProgress` while another recording is active — each before
    /// any clock, file or source exists. Rethrows a failure to create the
    /// file. Clears `lastStopReason` and the disk-space fields of `live`.
    ///
    /// A source that is unavailable or fails to start does not stop the
    /// recording: it is written as a `lifecycle` `error` row.
    func start(
        mount: String,
        vehicle: String,
        allowWithoutOBD: Bool,
        calibration: Duration = .seconds(5)
    ) async throws {
        guard !isStarting, recording == nil, ending == nil else { throw RecordingStartBlocker.recordingInProgress }
        // REL-DEMO: before anything changes; a hold cannot begin later (it
        // needs `isRecordActive` false, which is set on the next line).
        guard !isHeldForDemo else { throw RecordingStartBlocker.demoDriveRunning }
        isStarting = true
        // UX-8: downloads pause before the first suspension, so before the
        // clock, file, writer and sources below exist.
        updateRecordActive()
        // The recording's source owns location from here (R61.1-4).
        updateDisplayLocation()
        // Cleared on every throw before the recording exists, and as soon as
        // it does (R4.1-2): from then on `recording` blocks a second start,
        // and a stop or failure during calibration must free Start at once,
        // not when the calibration wait returns. Never cleared on behalf of
        // a later `start` that set it again meanwhile.
        var ownsStartingFlag = true
        defer {
            if ownsStartingFlag {
                isStarting = false
                updateRecordActive()
                // UX-1: a Start that threw after ending Navigate (or while
                // it ran, which changes nothing) leaves Navigate as it would
                // be without the attempt.
                resumeNavigate()
            }
        }

        // Rule 3, with a fresh reading.
        let reading = await readDiskSpace()
        if let reading { availableDiskBytes = reading }
        guard recording == nil, ending == nil else { throw RecordingStartBlocker.recordingInProgress }
        if let reading, !DiskSpacePolicy.canStart(availableBytes: reading, warningFreeBytes: warningFreeBytes) {
            throw RecordingStartBlocker.lowDiskSpace(availableBytes: reading, requiredBytes: warningFreeBytes)
        }
        let polling = isLinkPolling
        if !allowWithoutOBD, !polling { throw RecordingStartBlocker.obdNotReady }

        // From here to the calibration wait nothing suspends.
        // UX-1: Navigate ends completely (sources stopped, sink and feed
        // finished) before this recording's clock exists; no hand-over. The
        // idle timer stays as it is: the recording keeps it off.
        if let nav = navigate { endNavigate(nav) }
        try store.createDirectory()
        let clock = SessionClock(source: uptime, wallClockStart: Date())
        let header = makeHeader(clock: clock, polling: polling, mount: mount, vehicle: vehicle)
        let navigationTap = NavigationTap()
        let (writer, url) = try makeWriter(header: header, start: clock.wallClockStart, tap: navigationTap.tap)

        generation += 1
        let rec = ActiveRecording(generation: generation, clock: clock, writer: writer, url: url, navigationTap: navigationTap)
        recording = rec
        isStarting = false
        ownsStartingFlag = false
        updateRecordActive()   // stays true: `recording` now holds it
        currentFile = url
        lastStopReason = nil
        // No speed carried over from before Start (M8.1-3): a manual fix's
        // `obdSpeedT` names an `obd` row, and pre-Start readings aren't in
        // this file. The recording's first reading sets it again.
        live = LiveStatus(obdSpeedKmh: nil, obdHz: live.obdHz, availableDiskBytes: nil)
        latestFix = nil
        obdSpeedUptime = nil
        state = .calibrating
        updateIdleTimer()
        onNavigationFeed?(RecordingNavigationFeed(
            generation: rec.generation,
            header: header,
            clock: clock,
            recordingURL: url,
            sidecarURL: LogStore.navSidecarURL(for: url),
            tap: navigationTap,
            recordRoadPacks: { [weak self] detail in
                Task { @MainActor in self?.recordRoadPacks(detail, in: rec) }
            }
        ))

        rec.record(LifecycleSample(.start, detail: polling ? nil : "without OBD: link \(Self.describe(link.state))"))
        // Still the same synchronous step: no suspension since `polling` was
        // read, so no link event can be consumed between the reads and the
        // replay rows, and no live link row precedes them.
        replayStartupInit(rec)
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal != .nominal {
            rec.record(LifecycleSample(.thermalState, detail: Self.name(of: thermal)))
        }
        watchWriter(rec)
        startSources(rec)
        recordLocationAuthorization(rec)
        noteBackgroundRisk(rec)
        startTimers(rec)

        let seconds = Self.seconds(calibration)
        rec.record(LifecycleSample(.calibrationStart, detail: "keep still for \(Self.format(seconds)) s"))
        let calibrationStart = clock.now()
        if calibration > .zero {
            try? await Task.sleep(for: calibration)
        }
        // Stopped, failed or replaced meanwhile (R3-2): nothing more to do.
        // `isWritable` too (R32.3-2): a write failure queues its error row
        // and the end path before the state leaves `calibrating`, and a
        // wake-up already queued must not write after that row.
        guard recording === rec, state == .calibrating, rec.isWritable else { return }
        let lasted = calibrationStart.interval(to: clock.now())
        rec.record(LifecycleSample(
            .calibrationEnd,
            detail: lasted + 0.05 < seconds ? "cut short after \(Self.format(lasted)) s" : nil
        ))
        state = .recording
    }

    // MARK: - During a recording

    /// Writes a `marker` row. Ignored when no recording is active.
    func mark(_ text: String) {
        guard let rec = recording, rec.isWritable else { return }
        rec.sink.record(.marker(text, at: rec.clock.now()))
    }

    // MARK: - GPS switch (UX-9a)

    /// Generation of the run in which the driver turned GPS off; nil while
    /// it is on. Keyed by run, so every recording and every Navigate session
    /// starts with GPS on (not persisted, user decision 2026-10-20) without
    /// a reset anywhere: a new run has a new generation.
    private var gpsOffGeneration: Int?

    /// The driver's "GPS off" switch for the current run (Record, else
    /// Navigate). True with no run. Observed.
    var isGPSSwitchOn: Bool {
        guard let generation = currentRunGeneration else { return true }
        return gpsOffGeneration != generation
    }

    /// Sets the driver's "GPS off" switch on the current run and records a
    /// `gpsSwitch` row (format v4, `source` "driver") at `clock.now()`, the
    /// tap, through the run's sink like a marker. In Record the row is
    /// written to the file; in Navigate the sink is tap-only, so it reaches
    /// navigation and nothing stores it. Location rows keep being recorded
    /// while off: the switch only gates what navigation may use.
    ///
    /// Returns the row's `t`, or nil when nothing was recorded: no run, the
    /// run takes no more rows (stop row queued, write failure, Navigate
    /// ended), or `on` is already the current state.
    @discardableResult
    func setGPSSwitch(on: Bool) -> MonotonicTimestamp? {
        guard let run = currentRun, run.isWritable, on != isGPSSwitchOn else { return nil }
        let t = run.clock.now()
        run.sink.record(LogEvent(timestamp: t, payload: .gpsSwitch(GPSSwitchSample(on: on, source: .driver))))
        gpsOffGeneration = on ? nil : run.generation
        return t
    }

    // MARK: - Manual position fix (double tap)

    /// Manual fixes tapped and not yet written, in tap order. Observed: the
    /// map draws them as pending. Empty outside a recording or Navigate
    /// session.
    private(set) var pendingManualFixes: [PendingManualFix] = []

    /// Ids of fixes that were dropped without being written (write failure,
    /// recording gone). Ids are never reused, so the set only grows; the map
    /// must not draw these (R14.3-4).
    private(set) var droppedManualFixIDs: Set<PendingManualFix.ID> = []

    /// Read-only, for the map's stopped check: `replyUptime` of the reading
    /// behind `live.obdSpeedKmh`, nil when there is none.
    var obdSpeedReplyUptime: Double? { obdSpeedUptime }

    /// Read-only: the uptime clock the OBD reply uptimes are on.
    var currentUptimeSeconds: Double { uptime.uptimeSeconds }

    /// The current recording's clock time, to hand to `stageManualFix` as
    /// `tapT`. nil when no recording is calibrating or recording and no
    /// Navigate session runs (in Navigate: its clock, UX-1 (e)).
    func manualFixTapTime() -> MonotonicTimestamp? {
        manualFixRun?.clock.now()
    }

    /// Stages a manual fix taken at `tapT` (from `manualFixTapTime()`, in the
    /// same main-actor turn). The speeds are captured now, at the tap; the
    /// row is written when `manualFixUndoWindow` has passed, unless
    /// `cancelPendingManualFix` is called first. It is written with
    /// `t` = `pressedT` = `tapT` and no note, in tap order with other pending
    /// fixes. A pending fix is also written by Stop (before the `stop` row);
    /// a write failure drops it.
    ///
    /// There is no speed limit. Returns nil, and stages nothing, when no
    /// recording is calibrating or recording (and no Navigate session runs),
    /// or the coordinate is not a finite WGS 84 position. A non-finite or
    /// negative `mapSpanM` is dropped from the row. The 300 m span rule is
    /// the map's.
    ///
    /// In Navigate (UX-1 (e)) the same: staged, undoable for the same
    /// window, then recorded into the session's tap-only sink — the engine
    /// resets on it and nothing stores it.
    @discardableResult
    func stageManualFix(
        latitude: Double,
        longitude: Double,
        tapT: MonotonicTimestamp,
        mapSpanM: Double?
    ) -> PendingManualFix.ID? {
        guard let rec = manualFixRun else { return nil }
        let obdSpeedKmh = live.obdSpeedKmh
        let obdSpeedT = obdSpeedKmh == nil ? nil : obdSpeedUptime.map { rec.clock.timestamp(uptimeSeconds: $0) }
        guard let sample = ManualFixGate.sample(
            now: tapT,
            latitude: latitude,
            longitude: longitude,
            pressedT: tapT,
            mapSpanM: mapSpanM,
            obdSpeedKmh: obdSpeedKmh,
            obdSpeedT: obdSpeedT,
            referenceFix: live.referenceFix
        ) else { return nil }
        let pending = PendingManualFix(id: nextPendingFixID, generation: rec.generation, sample: sample)
        nextPendingFixID += 1
        pendingManualFixes.append(pending)
        let window = manualFixUndoWindow
        rec.pendingFixTimers[pending.id] = Task { [weak self] in
            try? await Task.sleep(for: window)
            if Task.isCancelled { return }
            self?.commitPendingManualFixes(through: pending.id)
        }
        return pending.id
    }

    /// Undo: the fix is never written. False when it is already written,
    /// dropped or unknown.
    @discardableResult
    func cancelPendingManualFix(_ id: PendingManualFix.ID) -> Bool {
        guard let index = pendingManualFixes.firstIndex(where: { $0.id == id }) else { return false }
        pendingManualFixes.remove(at: index)
        currentRun?.pendingFixTimers.removeValue(forKey: id)?.cancel()
        return true
    }

    /// Writes pending fixes in tap order up to and including `id`.
    private func commitPendingManualFixes(through id: PendingManualFix.ID) {
        guard let last = pendingManualFixes.firstIndex(where: { $0.id == id }) else { return }
        writePending(Array(pendingManualFixes[...last]))
    }

    /// Writes every pending fix (Stop). Call before the `stop` row.
    private func commitAllPendingManualFixes() {
        writePending(pendingManualFixes)
    }

    private func writePending(_ fixes: [PendingManualFix]) {
        let ids = Set(fixes.map(\.id))
        pendingManualFixes.removeAll { ids.contains($0.id) }
        for fix in fixes {
            currentRun?.pendingFixTimers.removeValue(forKey: fix.id)?.cancel()
            // Not writable: a fix whose window closes between a write
            // failure's error row and `performFail` (R15.1-3). The recording
            // and generation checks can't fail today — every end path's
            // `finishRecording` drops the ending recording's fixes and cancels
            // their timers before `recording` changes — and stay as guards.
            guard let rec = currentRun, rec.generation == fix.generation, rec.isWritable else {
                droppedManualFixIDs.insert(fix.id)
                continue
            }
            rec.sink.record(LogEvent(timestamp: fix.sample.pressedT, payload: .manualFix(fix.sample)))
        }
    }

    /// Nothing more can be written (write failure) or the session is gone.
    private func dropPendingManualFixes(_ rec: some SessionRun) {
        for timer in rec.pendingFixTimers.values { timer.cancel() }
        rec.pendingFixTimers = [:]
        for fix in pendingManualFixes where fix.generation == rec.generation {
            droppedManualFixIDs.insert(fix.id)
        }
        pendingManualFixes.removeAll { $0.generation == rec.generation }
    }

    /// The session a manual fix may be written to: the recording while it
    /// is calibrating or recording and its stop row is not yet queued; with
    /// no recording, the Navigate session (UX-1 (e)) while it runs.
    private var manualFixRun: (any SessionRun)? {
        if let rec = recording {
            guard state == .calibrating || state == .recording, rec.isWritable else { return nil }
            return rec
        }
        guard let nav = navigate, nav.isWritable else { return nil }
        return nav
    }

    /// The session link rows and pins go to: the recording, else the
    /// Navigate session. Never both (Start ends Navigate first).
    private var currentRun: (any SessionRun)? {
        recording ?? navigate
    }

    /// A recording or a Navigate run exists, or Start is in progress: the
    /// run may map road packs (N3.4: Remove then marks instead of deleting).
    var hasActiveRun: Bool { recording != nil || navigate != nil || isStarting }

    /// Writes `background`/`foreground` rows while recording; flushes on
    /// background inside a background task. Refreshes free space on becoming
    /// active.
    func handleScenePhase(_ phase: ScenePhase) {
        let previous = lastScenePhase
        lastScenePhase = phase
        // Only `.active` runs the map-only position feed (R61.1-4):
        // `.inactive` (control centre, app switcher, a call) stops it too,
        // and `.background` must (it is never background location). A run's
        // own sources are not touched: they keep running when locked (D7 revised).
        updateDisplayLocation()
        switch phase {
        case .background:
            // UX-1: a Navigate fix in its undo window reaches the engine
            // before the app is suspended, as a recording's is written.
            // No row and nothing reset; UX-20: the navigation service saves
            // the estimate (`onFlush`) inside a background task, so a kill
            // in the background restores from now, not from the last 5 s
            // save.
            if navigate != nil {
                commitAllPendingManualFixes()
                flushNavigationInBackgroundTask()
            }
            guard let rec = recording, rec.isWritable else { return }
            // A fix in its undo window is written now (R14.3-3): iOS may kill
            // the app after this, and the driver saw the fix as recorded.
            // `.inactive` does nothing; a fix staged later, while in the
            // background, is written by its timer.
            commitAllPendingManualFixes()
            rec.record(LifecycleSample(.background))
            flushInBackgroundTask(rec, reason: "background")
        case .active, .inactive:
            if phase == .active {
                Task { await refreshDiskSpace() }
                // Back from Settings, or from a permission alert.
                backgroundAvailabilityChanged()
                // UX-1: the auto-stop deadline may have passed while
                // suspended; its timer would fire too, this is at once.
                if let nav = navigate { stopNavigateIfDue(nav) }
            }
            guard previous == .background, let rec = recording, rec.isWritable else { return }
            rec.record(LifecycleSample(.foreground))
        @unknown default:
            break
        }
    }

    /// Writes a `memoryWarning` row and flushes.
    func handleMemoryWarning() {
        guard let rec = recording, rec.isWritable else { return }
        rec.record(LifecycleSample(.memoryWarning))
        flushInBackgroundTask(rec, reason: "memoryWarning")
    }

    /// Longest `handleWillTerminate` waits for its flush. iOS allows about
    /// 5 s after `willTerminate` before it kills the app.
    nonisolated static let willTerminateFlushTimeout: DispatchTimeInterval = .seconds(3)

    /// `UIApplication.willTerminateNotification` (R4.1-4), e.g. the app
    /// swiped away while recording in the background: flushes everything
    /// recorded so far and **returns only when it is on disk** (or after
    /// `willTerminateFlushTimeout`), because the process ends when this
    /// returns. Flush only: no row is written and the recording isn't
    /// stopped, so the file ends like a crash (no `stop` row, no final
    /// `stats` row) but without losing the last unflushed seconds. Blocks
    /// the main thread; the writer runs off it.
    func handleWillTerminate() {
        // UX-1: the app closing ends Navigate (nothing to flush).
        if let nav = navigate {
            endNavigate(nav)
            updateIdleTimer()
        }
        guard let rec = recording else { return }
        let writer = rec.writer
        let flushed = DispatchSemaphore(value: 0)
        Task.detached {
            // A throw is this call's result, not a report (rule 4).
            try? await writer.flush()
            flushed.signal()
        }
        _ = flushed.wait(timeout: .now() + Self.willTerminateFlushTimeout)
    }

    // MARK: - Stop

    /// The normal stop path, used by the user and by rule 2: writes the
    /// `stop` row with `reason.rawValue` as its detail and the final `stats`
    /// row, calls `finish()`, returns to `idle` and sets `lastStopReason`.
    /// If `finish()` reports a `failure`, or a failure was delivered while
    /// stopping, rule 4 applies instead (`failed`). Waits for an end already
    /// in progress; does nothing when idle or failed.
    func stop(reason: RecordingStopReason = .user) async {
        if let ending {
            await ending.value
            return
        }
        guard let rec = recording, state == .calibrating || state == .recording else { return }
        // Held until the file is finished, from before `quiesce` stops the
        // sources and with them the location background session (R4.1-3):
        // a stop with the phone locked must not be suspended mid-tail.
        let endBackgroundTask = beginBackgroundTask("DriveLogger.stop")
        defer { endBackgroundTask() }
        // `stopping` from the moment stop is called, not when the end path's
        // body first runs (R4.1-1): a write failure delivered in between is
        // then remembered, and the UI never shows `recording` after Stop.
        let wasCalibrating = state == .calibrating
        state = .stopping
        await end(rec) { session in await session.performStop(rec, reason: reason, wasCalibrating: wasCalibrating) }
    }

    /// Deletes a recording through `store`, refusing the one being written,
    /// then refreshes `availableDiskBytes` (R3-5).
    func deleteRecording(_ file: RecordingFile) async throws {
        if let rec = recording, rec.url.standardizedFileURL.path == file.url.standardizedFileURL.path {
            throw LogStoreError.recordingInProgress(path: file.url.path)
        }
        try store.delete(file)
        await refreshDiskSpace()
    }

    /// Re-evaluates `backgroundRiskWarning` from the background-execution
    /// sources' `availability` and, during a recording, whether they
    /// started. Writes no row. The session calls it itself (see
    /// `backgroundRiskWarning`); the UI may call it too.
    func refreshBackgroundRisk() {
        let warning = currentBackgroundRisk()
        if warning != backgroundRiskWarning { backgroundRiskWarning = warning }
    }

    /// Reads free space off the main actor and stores it in
    /// `availableDiskBytes` (R3-5). A provider that throws leaves the last
    /// reading in place.
    func refreshDiskSpace() async {
        if let bytes = await readDiskSpace() {
            availableDiskBytes = bytes
        }
    }

    // MARK: - Internals: the recording

    private var isLinkPolling: Bool {
        if case .polling = link.state { return true }
        return false
    }

    /// The header of a session about to start, a recording's or (UX-1) a
    /// Navigate session's, which is built the same way and never written.
    private func makeHeader(clock: SessionClock, polling: Bool, mount: String, vehicle: String) -> LogHeader {
        LogHeader(
            sessionID: makeSessionID(),
            clock: clock,
            app: app,
            device: device,
            notes: notes,
            adapter: polling ? link.adapter : nil,
            polling: polling ? link.plan.map(PollingRecord.init) : nil,
            sensors: sensorConfiguration,
            mount: mount.isEmpty ? nil : mount,
            vehicle: vehicle.isEmpty ? nil : vehicle,
            timeZone: TimeZone.current.identifier
        )
    }

    /// Creates the file exclusively, moving to the next collision index if a
    /// file of that name appeared since `newFileURL` looked. `tap` goes to the
    /// writer's sink (the recording's `NavigationTap`).
    private func makeWriter(
        header: LogHeader,
        start: Date,
        tap: @escaping @Sendable (LogEvent) -> Void
    ) throws -> (LogFileWriter, URL) {
        var attempts = 0
        while true {
            let url = store.newFileURL(startingAt: start, timeZone: .current)
            do {
                let writer = try LogFileWriter(
                    url: url,
                    header: header,
                    flushInterval: flushInterval,
                    warningFreeBytes: warningFreeBytes,
                    stopFreeBytes: stopFreeBytes,
                    diskSpace: diskSpace,
                    tap: tap
                )
                return (writer, url)
            } catch .fileExists where attempts < 20 {
                attempts += 1
            }
        }
    }

    /// The start-up init, written once per recording, at Start (M4; see the
    /// type's doc and `OBDLinkServicing.lastInitEvents`). Must run in the
    /// same synchronous main-actor step as the `start` row, before anything
    /// can suspend. A Navigate session (UX-1) replays the same way, once, at
    /// its own start, so its link rows and dedup skip are a recording's.
    private func replayStartupInit(_ rec: some SessionRun) {
        // Once per session, never again while it runs.
        guard !rec.replayedStartupInit else { return }
        rec.replayedStartupInit = true
        let replay = link.lastInitEvents
        let delivered = link.deliveredLinkEventCount
        // Delivered before Start and not yet handled by the loop: each is in
        // the replay or is pre-Start traffic. `delivered < consumed` can't
        // happen with one subscription; never skip a negative count.
        rec.linkEventsToSkip = max(0, delivered - consumedLinkEvents)
        let adapter = link.adapter
        for event in replay {
            for row in LogEvent.rows(for: event, adapter: adapter, clock: rec.clock) {
                rec.sink.record(row)
            }
        }
    }

    /// The `roadPacks` row: the road-pack library scan the navigation
    /// service started at Start, written when it finishes. Only while `rec`
    /// is still the running recording (never after Stop began: a scan that
    /// finishes later leaves no row) and at most once.
    private func recordRoadPacks(_ detail: String, in rec: ActiveRecording) {
        guard recording === rec, state == .calibrating || state == .recording,
              rec.isWritable, !rec.roadPacksRecorded else { return }
        rec.roadPacksRecorded = true
        rec.record(LifecycleSample(.roadPacks, detail: detail))
    }

    /// After `startSources`: one `locationAuthorization` row per source that
    /// reports location authorisation (on a phone, `ReferenceLocationSource`),
    /// started or not, so a recording always says what the authorisation
    /// was. Informational; problems get their own `error` rows.
    private func recordLocationAuthorization(_ rec: ActiveRecording) {
        for source in sources {
            guard let reporter = source as? any LocationAuthorizationReporting else { continue }
            rec.record(LifecycleSample(.locationAuthorization, detail: reporter.locationAuthorizationDetail))
        }
    }

    /// After `startSources`: remembers which background-execution sources
    /// started, refreshes the warning and writes the row if there is none.
    private func noteBackgroundRisk(_ rec: ActiveRecording) {
        rec.backgroundSources = Set(rec.startedSources.filter { $0 is any BackgroundExecutionProviding }.map(ObjectIdentifier.init))
        refreshBackgroundRisk()
        recordBackgroundRiskIfNeeded(rec)
    }

    /// A background-execution source's availability may have changed, or
    /// the app became active.
    private func backgroundAvailabilityChanged() {
        refreshBackgroundRisk()
        if let rec = recording, state == .calibrating || state == .recording {
            recordBackgroundRiskIfNeeded(rec)
        }
    }

    /// The `error` row, at most once per recording, while `rec` is writable.
    private func recordBackgroundRiskIfNeeded(_ rec: ActiveRecording) {
        guard backgroundRiskWarning != nil, !rec.backgroundRiskRecorded, rec.isWritable else { return }
        rec.backgroundRiskRecorded = true
        rec.record(LifecycleSample(.error, detail: Self.backgroundRiskDetail))
    }

    private func currentBackgroundRisk() -> String? {
        let keepers = sources.filter { $0 is any BackgroundExecutionProviding }
        guard !keepers.isEmpty else { return nil }
        var reasons: [String] = []
        for keeper in keepers {
            if case .unavailable(let reason) = keeper.availability {
                reasons.append(reason)
            } else if let rec = recording, !rec.backgroundSources.contains(ObjectIdentifier(keeper)) {
                reasons.append("\(keeper.name) did not start")
            } else {
                return nil
            }
        }
        let because = reasons.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
        return "No background location session, so the recording may pause while the phone is locked. \(because)"
    }

    /// Starts every source on the session's clock and sink, a recording's
    /// or (UX-1) a Navigate session's: one function, so the two start the
    /// same sources in the same order, both with background location (D7
    /// revised).
    private func startSources(_ rec: some SessionRun) {
        for source in sources {
            if case .unavailable(let reason) = source.availability {
                rec.record(LifecycleSample(.error, detail: "\(source.name) unavailable: \(reason)"))
                continue
            }
            if let configurable = source as? any BackgroundLocationConfigurable {
                configurable.holdsBackgroundLocation = rec.holdsBackgroundLocation
            }
            if let reporting = source as? any LiveReferenceFixReporting {
                let generation = rec.generation
                reporting.onReferenceFix = { [weak self] fix in
                    self?.referenceFixArrived(fix, generation: generation)
                }
            }
            do {
                try source.start(clock: rec.clock, sink: rec.sink)
                rec.startedSources.append(source)
            } catch {
                rec.record(LifecycleSample(.error, detail: "\(source.name) failed to start: \(error)"))
            }
        }
    }

    /// Failures and notices, each handled only while `rec` is current.
    private func watchWriter(_ rec: ActiveRecording) {
        let writer = rec.writer
        let generation = rec.generation
        Task { [weak self] in
            for await failure in writer.failures {
                await self?.handleWriteFailure(failure, generation: generation)
            }
        }
        Task { [weak self] in
            for await notice in writer.diskSpaceNotices {
                await self?.handleDiskSpaceNotice(notice, generation: generation)
            }
        }
    }

    private func startTimers(_ rec: ActiveRecording) {
        let interval = statsInterval
        rec.statsTimer = Task { [weak self, weak rec] in
            let clock = ContinuousClock()
            let base = clock.now
            var window = 1
            while !Task.isCancelled {
                try? await Task.sleep(until: base + interval * window, clock: clock)
                guard !Task.isCancelled, let self, let rec else { return }
                window += 1
                let tick = Task { await self.writeStatsRow(rec) }
                rec.statsTick = tick
                await tick.value
            }
        }
        rec.liveTimer = Task { [weak self, weak rec] in
            while !Task.isCancelled {
                guard let self, let rec else { return }
                await self.updateLive(rec)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopTimers(_ rec: ActiveRecording) {
        rec.statsTimer?.cancel()
        rec.liveTimer?.cancel()
    }

    /// Writes one periodic `stats` row, then an `error` row if the writer
    /// queue's peak in that window was above `max(2 s of data, 200)`
    /// (`WriterQueueAlarm`; docs/LOG_FORMAT.md). Not on the stop path: the
    /// final `stats` row is the last row.
    private func writeStatsRow(_ rec: ActiveRecording) async {
        guard recording === rec, rec.isWritable else { return }
        let end = rec.clock.now()
        let sample = await rec.writer.closeStatsWindow(at: end)
        guard rec.isWritable else { return }
        rec.sink.record(LogEvent(timestamp: end, payload: .stats(sample)))
        live.motionHz = sample.motionHz
        if let detail = WriterQueueAlarm.detail(for: sample) {
            rec.record(LifecycleSample(.error, detail: detail))
        }
    }

    private func updateLive(_ rec: ActiveRecording) async {
        guard recording === rec else { return }
        live.elapsed = max(0, rec.clock.now().seconds)
        updateLiveReferenceFix()
        let bytes = await rec.writer.bytesWritten
        if recording === rec { live.fileBytes = bytes }
    }

    /// A source showed `fix` (R24.1-1): the map's `latestFix`, if it belongs
    /// to the live run and that run's sources still run. A fix shown late,
    /// after its run stopped its sources or ended, is dropped. Display only.
    private func referenceFixArrived(_ fix: LocationSample, generation: Int) {
        guard let run = currentRun, run.generation == generation, !run.startedSources.isEmpty else { return }
        latestFix = fix
    }

    /// `live.gpsSpeedKmh` and `live.referenceFix` from the sources, once a
    /// second while a recording or (UX-1) a Navigate session runs.
    private func updateLiveReferenceFix() {
        let fix = sources.lazy.compactMap { ($0 as? any LiveReferenceFixReporting)?.latestReferenceFix }.first
        live.gpsSpeedKmh = fix.flatMap { $0.speed >= 0 ? $0.speed * 3.6 : nil }
        live.referenceFix = fix
    }

    private func flushInBackgroundTask(_ rec: ActiveRecording, reason: String) {
        let writer = rec.writer
        let alsoFlush = onFlush
        let endBackgroundTask = beginBackgroundTask("DriveLogger.flush.\(reason)")
        Task {
            // A throw is this call's result, not a report: the writer
            // delivers each failure once on `failures` (rule 4).
            try? await writer.flush()
            await alsoFlush?()
            endBackgroundTask()
        }
    }

    /// Navigate on `.background` (UX-20): `onFlush` (the navigation
    /// service saves the estimate and waits for the file) inside a
    /// background task. No log, so nothing else to flush.
    private func flushNavigationInBackgroundTask() {
        guard let alsoFlush = onFlush else { return }
        let endBackgroundTask = beginBackgroundTask("DriveLogger.flush.navigate")
        Task {
            await alsoFlush()
            endBackgroundTask()
        }
    }

    /// The app's `beginBackgroundTask`: a `UIApplication` background task,
    /// ended by the returned call or by expiry, whichever comes first.
    static func systemBackgroundTask(_ name: String) -> @MainActor () -> Void {
        let task = BackgroundTask(name: name)
        return { task.end() }
    }

    // MARK: - Internals: ending

    /// Re-derives `isRecordActive` after `isStarting`, `recording` or
    /// `ending` changed, and reports a change to `onRecordActiveChange`.
    private func updateRecordActive() {
        let active = isStarting || recording != nil || ending != nil
        guard active != isRecordActive else { return }
        isRecordActive = active
        onRecordActiveChange?(active)
    }

    /// Runs `body` as the one end path; concurrent callers wait for it.
    private func end(_ rec: ActiveRecording, _ body: @escaping @MainActor (RecordingSession) async -> Void) async {
        if let ending {
            await ending.value
            return
        }
        let task = Task { await body(self) }
        ending = task
        updateRecordActive()
        await task.value
        ending = nil
        // UX-8: Record ends here, after the writer's `finish()`.
        updateRecordActive()
        Task { await refreshDiskSpace() }
    }

    /// Stops every source and the link forwarding: after this, nothing but
    /// the session's own final rows reaches the sink (R1-9).
    private func quiesce(_ rec: ActiveRecording) {
        rec.acceptsLinkEvents = false
        stopTimers(rec)
        for source in rec.startedSources { source.stop() }
        rec.startedSources = []
    }

    private func performStop(_ rec: ActiveRecording, reason: RecordingStopReason, wasCalibrating: Bool) async {
        state = .stopping
        quiesce(rec)
        // A periodic stats row in flight lands before the stop row.
        await rec.statsTick?.value
        if wasCalibrating {
            rec.record(LifecycleSample(.calibrationEnd, detail: "interrupted by stop"))
        }
        // A fix still in its undo window is the driver's mark: write it, before the stop row.
        commitAllPendingManualFixes()
        rec.record(LifecycleSample.stop(reason))
        rec.stopRowQueued = true
        let end = rec.clock.now()
        let stats = await rec.writer.closeStatsWindow(at: end)
        rec.sink.record(LogEvent(timestamp: end, payload: .stats(stats)))
        let summary = await rec.writer.finish()
        if let failure = summary.failure ?? rec.pendingFailure {
            enterFailed(rec, failure: failure, summary: summary)
        } else {
            finishRecording(rec)
            state = .idle
            lastStopReason = reason
        }
    }

    private func performFail(_ rec: ActiveRecording, failure: LogWriteError) async {
        state = .stopping
        // Already done by `handleWriteFailure` before the error row
        // (R32.2-1); repeated here so this path stands on its own.
        quiesce(rec)
        rec.stopRowQueued = true   // no row of any kind after the error row
        dropPendingManualFixes(rec)
        await rec.statsTick?.value
        let summary = await rec.writer.finish()
        enterFailed(rec, failure: summary.failure ?? rec.pendingFailure ?? failure, summary: summary)
    }

    private func enterFailed(_ rec: ActiveRecording, failure: LogWriteError, summary: LogFileSummary) {
        finishRecording(rec)
        lastStopReason = nil
        state = .failed(
            reason: Self.describe(failure),
            unwrittenEvents: summary.unwrittenEvents + rec.sink.dropped
        )
    }

    /// Called by both end paths after the writer's `finish()`: the sink
    /// accepts nothing more, so the navigation feed ends here, after its
    /// last input. Then (UX-1) back to Navigate if the link still polls,
    /// before the idle timer is re-evaluated, so it never flickers off.
    private func finishRecording(_ rec: ActiveRecording) {
        rec.navigationTap.finish()
        dropPendingManualFixes(rec)
        guard recording === rec else { return }
        recording = nil
        updateRecordActive()   // stays true while `ending` runs
        currentFile = nil
        live.gpsSpeedKmh = nil
        live.referenceFix = nil
        latestFix = nil
        startNavigateIfPossible()
        updateIdleTimer()
        refreshBackgroundRisk()
        updateDisplayLocation()
    }

    // MARK: - Map-only position feed (R61.1-4)

    /// The display feed runs exactly when the app is active, no Navigate
    /// session exists, no recording is starting or running, and the feed
    /// itself is allowed to (location already granted). Every run's sources
    /// are stopped before this can start it, and it is stopped before a
    /// run's sources start: one location consumer at a time. Idempotent;
    /// called at every transition (scene phase, Record start and end,
    /// Navigate start and end, authorisation change).
    private var wantsDisplayLocation: Bool {
        lastScenePhase == .active && navigate == nil && recording == nil && !isStarting && !isHeldForDemo
    }

    private func updateDisplayLocation() {
        guard let displayLocation else { return }
        if wantsDisplayLocation {
            displayLocation.start()
        } else {
            displayLocation.stop()
            displayFix = nil
        }
    }

    /// A fix from the display feed. Dropped unless the feed is still wanted
    /// (a fix hopped over just as a run took location).
    private func displayFixArrived(_ fix: LocationSample) {
        guard wantsDisplayLocation else { return }
        displayFix = fix
    }

    /// Keeps the screen awake while a recording or a Navigate session
    /// exists. Calls `setIdleTimerDisabled` only when that changes.
    private func updateIdleTimer() {
        let wanted = recording != nil || navigate != nil
        guard wanted != idleTimerDisabled else { return }
        idleTimerDisabled = wanted
        setIdleTimerDisabled(wanted)
    }

    // MARK: - Internals: writer reports (internal for tests)

    /// Rule 4. Ignored for a writer that isn't the current recording's.
    func handleWriteFailure(_ failure: LogWriteError, generation: Int) async {
        guard let rec = recording, rec.generation == generation else { return }
        if state == .stopping || ending != nil {
            // An end path is already finishing the file (R3-2) — including
            // one that `stop()` has queued but whose body hasn't run yet
            // (R4.1-1): remember the failure so it ends in `failed`, and
            // explain it in the file unless the last row is already queued
            // (R3-3).
            if !rec.stopRowQueued {
                rec.record(LifecycleSample(.error, detail: "write failed: \(Self.describe(failure))"))
            }
            rec.pendingFailure = rec.pendingFailure ?? failure
            return
        }
        // Synchronously, before the end path's first suspension (R32.2-1,
        // R5.1-4): stop every source, then the error row, then nothing. A
        // source ticking on its own queue, a link row, a manual fix or an
        // in-flight `stats` row would otherwise land after the error row
        // until `performFail` runs. `performFail`'s own `quiesce` is then a
        // no-op, and a second report writes no row. A background task is
        // held from before `quiesce` until the file is finished (R4.1-3).
        let endBackgroundTask = beginBackgroundTask("DriveLogger.writeFailure")
        defer { endBackgroundTask() }
        quiesce(rec)
        rec.record(LifecycleSample(.error, detail: "write failed: \(Self.describe(failure))"))
        rec.stopRowQueued = true
        await end(rec) { session in await session.performFail(rec, failure: failure) }
    }

    /// Rules 1 and 2. Ignored for a writer that isn't the current
    /// recording's, and once the `stop` row is queued (R3-1).
    func handleDiskSpaceNotice(_ notice: DiskSpaceNotice, generation: Int) async {
        guard let rec = recording, rec.generation == generation, !rec.stopRowQueued else { return }
        switch notice {
        case .low(let available):
            rec.record(.lowDiskSpaceWarning(availableBytes: available))
            live.lowDiskSpaceWarning = true
            live.availableDiskBytes = available
            availableDiskBytes = available
        case .critical(let available):
            rec.record(.lowDiskSpaceFloor(availableBytes: available))
            live.availableDiskBytes = available
            availableDiskBytes = available
            if state == .calibrating || state == .recording {
                await stop(reason: .lowDiskSpace)
            }
        }
    }

    /// The current recording's generation, for tests driving the handlers.
    var currentGeneration: Int? { recording?.generation }

    // MARK: - Internals: link and system events

    /// One function for both modes: link rows go to the recording or, with
    /// none, the Navigate session (UX-1), with the same skip and mapping.
    private func handleLinkEvent(_ event: LinkEvent) {
        consumedLinkEvents += 1
        let run = currentRun
        // Delivered before Start but handled after it (M4 dedup contract):
        // replayed already, or not part of the recording.
        let skipped = run.map { $0.acceptsLinkEvents && $0.linkEventsToSkip > 0 } ?? false
        switch event {
        case .session(.reading(let reading)) where reading.measurement.pid == .vehicleSpeed && reading.isFromPrimaryECU:
            // UX-1 rule (a): the speed at connect, if Navigate is waiting
            // for it. A skipped reading is still the car's speed.
            if let nav = navigate, !nav.speedDecided { decideCalibration(nav, speedKmh: reading.measurement.value) }
            // A skipped reading has no `obd` row in this file, so it can't be
            // a manual fix's speed (M8.1-3).
            guard !skipped else { break }
            live.obdSpeedKmh = reading.measurement.value
            obdSpeedUptime = reading.replyUptime
        case .session(.pollRate(let hz, _)):
            live.obdHz = hz
        case .ble(_, let to, _, _) where to != .connected:
            live.obdSpeedKmh = nil
            obdSpeedUptime = nil
            live.obdHz = 0
        default:
            break
        }
        guard let rec = run, rec.acceptsLinkEvents else { return }
        if skipped {
            rec.linkEventsToSkip -= 1
            return
        }
        for row in LogEvent.rows(for: event, adapter: link.adapter, clock: rec.clock) {
            rec.sink.record(row)
        }
    }

    private func observeSystemNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let rec = self?.recording, rec.isWritable else { return }
                rec.record(LifecycleSample(.thermalState, detail: Self.name(of: ProcessInfo.processInfo.thermalState)))
            }
        })
        observers.append(center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let rec = self?.recording, rec.isWritable else { return }
                rec.record(LifecycleSample(.protectedDataUnavailable, detail: "device locked; recording continues (files are completeUntilFirstUserAuthentication)"))
            }
        })
        // `queue: nil`: run on the posting thread (UIKit posts it on the main
        // thread) before `post` returns, so the flush is done before the
        // process can end.
        observers.append(center.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillTerminate() }
        })
    }

    private func readDiskSpace() async -> Int64? {
        let provider = diskSpace
        let url = store.directory
        return await Task.detached(priority: .utility) {
            try? provider.availableBytes(for: url)
        }.value
    }

    // MARK: - Navigate (UX-1)

    /// Turns Navigate on (see the type's doc): from now on a Navigate
    /// session runs whenever the link is `polling` and no recording is
    /// starting, running or ending — at once, if that is the case now. Call
    /// after `onNavigationFeed` is set. Calling it again replaces the
    /// configuration for the next session.
    func enableNavigate(_ configuration: NavigateConfiguration = NavigateConfiguration()) {
        navigateConfiguration = configuration
        linkObservationToken += 1
        observeLinkState(token: linkObservationToken)
        startNavigateIfPossible()
        updateIdleTimer()
    }

    /// Turns Navigate off and ends a running session. Record is unaffected.
    func disableNavigate() {
        navigateConfiguration = nil
        linkObservationToken += 1
        if let nav = navigate {
            endNavigate(nav)
            updateIdleTimer()
        }
    }

    // MARK: - Demo drive hold (REL-DEMO)

    /// Holds this session for the demo drive, which runs on its own session
    /// (`DemoDriveController`): a running Navigate session ends now (its
    /// sources stop), the map-only position feed stops, and until
    /// `releaseDemoHold()` no Navigate session starts and Start throws
    /// `.demoDriveRunning`. Navigate stays enabled with its configuration.
    /// Refused (returns false, nothing changes) while Record is active
    /// (`isRecordActive`: starting, running or ending). Idempotent.
    @discardableResult
    func holdForDemo() -> Bool {
        guard !isRecordActive else { return false }
        guard !isHeldForDemo else { return true }
        isHeldForDemo = true
        if let nav = navigate { endNavigate(nav) }
        updateIdleTimer()
        updateDisplayLocation()
        return true
    }

    /// Ends the hold: exactly the state without it. Navigate starts again if
    /// it is enabled and the link polls, and the position feed runs if the
    /// app is active. Idempotent.
    func releaseDemoHold() {
        guard isHeldForDemo else { return }
        isHeldForDemo = false
        resumeNavigate()
    }

    /// Read-only, for the map: the generation of the run that is live now
    /// (the recording, else the Navigate session); nil when none. One
    /// counter, so Navigate, Record, Navigate each give a different value.
    var currentRunGeneration: Int? { currentRun?.generation }

    /// Navigate's timings while it is enabled (the map's countdowns); nil when not.
    var navigateTimings: NavigateConfiguration? { navigateConfiguration }

    /// The running Navigate session's generation (its feed's), for tests.
    var navigateGeneration: Int? { navigate?.generation }

    /// Re-evaluates Navigate on every `link.state` change while this
    /// token's observation is current.
    private func observeLinkState(token: Int) {
        withObservationTracking {
            _ = link.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.linkObservationToken == token else { return }
                self.navigateLinkStateChanged()
                self.observeLinkState(token: token)
            }
        }
    }

    private func navigateLinkStateChanged() {
        guard let configuration = navigateConfiguration else { return }
        if isLinkPolling {
            guard let nav = navigate else {
                startNavigateIfPossible()
                updateIdleTimer()
                return
            }
            if case .waitingForOBD = navigateState {
                // Reconnected: the same session goes on.
                nav.autoStopTimer?.cancel()
                nav.autoStopTimer = nil
                navigateState = .running
            }
        } else if let nav = navigate {
            switch navigateState {
            case .calibrating, .running:
                // The still phase is over: back to `running` on reconnect.
                nav.calibrationTimer?.cancel()
                nav.speedDecided = true
                let since = ContinuousClock.now
                navigateState = .waitingForOBD(since: since)
                nav.autoStopTimer = Task { [weak self, weak nav] in
                    try? await Task.sleep(until: since + configuration.autoStopAfter, clock: .continuous)
                    guard !Task.isCancelled, let self, let nav else { return }
                    self.stopNavigateIfDue(nav)
                }
            case .waitingForOBD, .off:
                break
            }
        }
    }

    /// Ends `nav` if it has been without `polling` for `autoStopAfter`.
    private func stopNavigateIfDue(_ nav: NavigateRun) {
        guard navigate === nav, case .waitingForOBD(let since) = navigateState,
              let configuration = navigateConfiguration,
              since.duration(to: .now) >= configuration.autoStopAfter else { return }
        // UX-20: no OBD for the auto-stop's 5 min: the engine is off, which
        // the estimate saved at the run's end records as its class.
        nav.runEnd.markEngineOff()
        endNavigate(nav)
        updateIdleTimer()
    }

    /// After a recording ends or a Start throws: a fresh Navigate session if
    /// the link polls, and the idle timer for whatever now runs.
    private func resumeNavigate() {
        startNavigateIfPossible()
        updateIdleTimer()
        updateDisplayLocation()
    }

    /// Starts a Navigate session when Navigate is enabled, none runs, no
    /// recording is starting, running or ending, and the link is `polling`.
    /// One synchronous main-actor step, like Record's Start: header, feed,
    /// start-up replay and sources, in Record's order. The caller updates
    /// the idle timer.
    private func startNavigateIfPossible() {
        guard let configuration = navigateConfiguration, navigate == nil, recording == nil, !isStarting,
              !isHeldForDemo, isLinkPolling else { return }
        // Rule (a): the speed the session had before this start.
        let speedAtConnect = live.obdSpeedKmh
        let clock = SessionClock(source: uptime, wallClockStart: Date())
        let header = makeHeader(clock: clock, polling: true, mount: "", vehicle: "")
        let navigationTap = NavigationTap()
        generation += 1
        let nav = NavigateRun(generation: generation, clock: clock, navigationTap: navigationTap)
        navigate = nav
        // The session's source owns location from here (R61.1-4): the
        // display feed is stopped before `startSources` below.
        updateDisplayLocation()
        // As at Record's Start (M8.1-3): pins take the session's own readings.
        live.obdSpeedKmh = nil
        obdSpeedUptime = nil
        live.gpsSpeedKmh = nil
        live.referenceFix = nil
        latestFix = nil
        navigateState = .calibrating
        navigateStartedAt = .now
        onNavigationFeed?(RecordingNavigationFeed(
            generation: nav.generation, header: header, clock: clock, output: .navigateOnly, tap: navigationTap,
            runEnd: nav.runEnd))
        replayStartupInit(nav)
        startSources(nav)
        nav.liveTimer = Task { [weak self, weak nav] in
            while !Task.isCancelled {
                guard let self, let nav, self.navigate === nav else { return }
                self.updateLiveReferenceFix()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let still = configuration.stillCalibration
        if still > .zero {
            nav.calibrationTimer = Task { [weak self, weak nav] in
                try? await Task.sleep(for: still)
                guard !Task.isCancelled, let self, let nav else { return }
                self.endCalibration(nav)
            }
            if let speedAtConnect { decideCalibration(nav, speedKmh: speedAtConnect) }
        } else {
            endCalibration(nav)
        }
    }

    /// Rule (a), once per session: moving at connect skips the still phase.
    private func decideCalibration(_ nav: NavigateRun, speedKmh: Double) {
        guard !nav.speedDecided else { return }
        nav.speedDecided = true
        if speedKmh > 0 { endCalibration(nav) }
    }

    private func endCalibration(_ nav: NavigateRun) {
        nav.speedDecided = true
        nav.calibrationTimer?.cancel()
        guard navigate === nav, navigateState == .calibrating else { return }
        navigateState = .running
    }

    /// Ends `nav` completely: timers cancelled, a fix still in its undo
    /// window committed (the driver's mark reaches the engine, as Stop
    /// writes a recording's), sources stopped, then the sink and the tap
    /// finished, so the service's run ends after its last input. The caller
    /// updates the idle timer.
    private func endNavigate(_ nav: NavigateRun) {
        guard navigate === nav else { return }
        nav.cancelTimers()
        commitAllPendingManualFixes()
        nav.acceptsLinkEvents = false
        for source in nav.startedSources { source.stop() }
        nav.startedSources = []
        nav.ended = true
        nav.sink.finish()
        nav.navigationTap.finish()
        dropPendingManualFixes(nav)
        navigate = nil
        navigateState = .off
        navigateStartedAt = nil
        live.gpsSpeedKmh = nil
        live.referenceFix = nil
        latestFix = nil
        // Sources are stopped above; if nothing else runs, the display feed
        // takes over (not while a Record Start is in progress).
        updateDisplayLocation()
    }

    // MARK: - Formatting

    static func describe(_ failure: LogWriteError) -> String {
        switch failure {
        case .diskFull: "disk full"
        case .writeFailed(let description): description
        case .encodingFailed(let kind, let description): "could not encode \(kind): \(description)"
        case .fileExists(let path): "file exists: \(path)"
        case .couldNotCreate(let path, let description): "could not create \(path): \(description)"
        case .alreadyFinished: "already finished"
        }
    }

    static func describe(_ state: OBDLinkState) -> String {
        switch state {
        case .unavailable(let reason): "unavailable (\(reason))"
        case .idle: "idle"
        case .scanning: "scanning"
        case .connecting: "connecting"
        case .discoveringServices: "discovering services"
        case .initialising: "initialising"
        case .ready: "ready"
        case .polling: "polling"
        case .reconnecting(let attempt): "reconnecting (attempt \(attempt))"
        case .failed(let reason): "failed (\(reason))"
        }
    }

    static func name(of state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    private static func format(_ seconds: Double) -> String {
        String(format: "%.1f", seconds)
    }
}

/// One recording in progress: its clock, writer and timers.
@MainActor
private final class ActiveRecording: SessionRun {
    let generation: Int
    /// The recording's one clock.
    let clock: SessionClock
    let writer: LogFileWriter
    let url: URL
    /// Feeds navigation input from `writer.sink`; finished with the writer.
    let navigationTap: NavigationTap
    /// A recording holds background location (unchanged by UX-1, D7a).
    let holdsBackgroundLocation = true
    var startedSources: [any SensorSource] = []
    /// Link events are written while true.
    var acceptsLinkEvents = true
    /// The start-up init has been written (once, at Start).
    var replayedStartupInit = false
    /// Link events still to be skipped by the loop: delivered before Start
    /// (M4 dedup contract).
    var linkEventsToSkip = 0
    /// The `stop` (or failure) end path has queued its last rows; nothing
    /// else may be written.
    var stopRowQueued = false
    /// A failure delivered while stopping (R3-2).
    var pendingFailure: LogWriteError?
    /// The `BackgroundExecutionProviding` sources that started (R4.1-5).
    /// Unlike `startedSources`, not cleared when the sources are stopped.
    var backgroundSources: Set<ObjectIdentifier> = []
    /// The `backgroundRiskDetail` row has been written.
    var backgroundRiskRecorded = false
    /// The `roadPacks` row has been written (once per recording).
    var roadPacksRecorded = false
    var statsTimer: Task<Void, Never>?
    var statsTick: Task<Void, Never>?
    var liveTimer: Task<Void, Never>?
    /// Undo-window timers of pending manual fixes, by `PendingManualFix.id`.
    var pendingFixTimers: [Int: Task<Void, Never>] = [:]

    init(generation: Int, clock: SessionClock, writer: LogFileWriter, url: URL, navigationTap: NavigationTap) {
        self.generation = generation
        self.clock = clock
        self.writer = writer
        self.url = url
        self.navigationTap = navigationTap
    }

    nonisolated var sink: LogSink { writer.sink }

    var isWritable: Bool { !stopRowQueued }

    /// A `lifecycle` row at `clock.now()`.
    func record(_ sample: LifecycleSample) {
        sink.record(LogEvent(timestamp: clock.now(), payload: .lifecycle(sample)))
    }
}

/// `UIApplication.beginBackgroundTask` around one piece of work, ended once
/// either by the work or by expiry.
@MainActor
private final class BackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
