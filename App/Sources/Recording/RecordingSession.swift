import DriveLoggerCore
import Foundation
import Observation
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
}

/// Live numbers for the dashboard. Display only — never written to the log.
struct LiveStatus: Hashable, Sendable {
    /// Latest vehicle speed from the engine ECU (`7E8`), any time the link
    /// polls — before a recording too. nil when the link isn't connected.
    var obdSpeedKmh: Double?
    /// Speed of the latest reference fix, while recording. Reference only,
    /// never written. From any `LiveReferenceFixReporting` source: the
    /// phone's `ReferenceLocationSource`, or on the simulator Core's
    /// `SimulatedLocationSource` (a constant 50 km/h, M2-S2). nil when not
    /// recording, before the first fix and whenever the fix has no valid
    /// speed.
    var gpsSpeedKmh: Double?
    /// The latest reference fix, while recording (for the Map tab). Display
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
/// `adapter`) — following that property's dedup contract: replay only at
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
/// builds), `calibrationStart` /
/// `calibrationEnd`, `stop` (detail = stop reason), `background` /
/// `foreground`, `memoryWarning`, `thermalState` (at start when not nominal,
/// and on every change), `protectedDataUnavailable`, `lowDiskSpace`, `error`
/// (a source that is unavailable or failed to start, no background location
/// session, a write failure, a writer queue backlog over 2 s of data), and a
/// `stats` row every `statsInterval` (10 s) plus a final one after the `stop`
/// row. Flushes on entering the background (inside a background task) and on
/// memory warnings. Keeps the screen awake (idle timer off) from start until
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
///    writer (R1-9): write a `lifecycle` `error` row (detail `write failed:
///    …`; it may not reach the disk), stop every source, call `finish()`,
///    enter `failed(reason:unwrittenEvents:)`. No `stop` row and no final
///    `stats` row. While *stopping* — from the moment `stop()` is called
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
/// recording is gone and neither writes `calibrationEnd` nor sets
/// `recording`. `isStarting` is cleared as soon as the recording exists
/// (R4.1-2), so once such a stop returns, `startBlocker` no longer reports
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
@MainActor
@Observable
final class RecordingSession {
    private(set) var state: RecordingState = .idle
    private(set) var live = LiveStatus()
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

    @ObservationIgnored private let link: any OBDLinkServicing
    @ObservationIgnored private let sources: [any SensorSource]
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

    @ObservationIgnored private var recording: ActiveRecording?
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
    /// - Precondition: `stopFreeBytes < warningFreeBytes`.
    init(
        link: any OBDLinkServicing,
        sources: [any SensorSource],
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
        setIdleTimerDisabled: @escaping @MainActor (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }
    ) {
        precondition(stopFreeBytes < warningFreeBytes, "stopFreeBytes must be below warningFreeBytes")
        self.link = link
        self.sources = sources
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
        isStarting = true
        // Cleared on every throw before the recording exists, and as soon as
        // it does (R4.1-2): from then on `recording` blocks a second start,
        // and a stop or failure during calibration must free Start at once,
        // not when the calibration wait returns. Never cleared on behalf of
        // a later `start` that set it again meanwhile.
        var ownsStartingFlag = true
        defer { if ownsStartingFlag { isStarting = false } }

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
        try store.createDirectory()
        let clock = SessionClock(source: uptime, wallClockStart: Date())
        let header = LogHeader(
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
        let (writer, url) = try makeWriter(header: header, start: clock.wallClockStart)

        generation += 1
        let rec = ActiveRecording(generation: generation, clock: clock, writer: writer, url: url)
        recording = rec
        isStarting = false
        ownsStartingFlag = false
        currentFile = url
        lastStopReason = nil
        live = LiveStatus(obdSpeedKmh: live.obdSpeedKmh, obdHz: live.obdHz, availableDiskBytes: nil)
        state = .calibrating
        setIdleTimerDisabled(true)

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
        guard recording === rec, state == .calibrating else { return }
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

    /// Writes `background`/`foreground` rows while recording; flushes on
    /// background inside a background task. Refreshes free space on becoming
    /// active.
    func handleScenePhase(_ phase: ScenePhase) {
        let previous = lastScenePhase
        lastScenePhase = phase
        switch phase {
        case .background:
            guard let rec = recording, rec.isWritable else { return }
            rec.record(LifecycleSample(.background))
            flushInBackgroundTask(rec, reason: "background")
        case .active, .inactive:
            if phase == .active {
                Task { await refreshDiskSpace() }
                // Back from Settings, or from a permission alert.
                backgroundAvailabilityChanged()
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

    /// Creates the file exclusively, moving to the next collision index if a
    /// file of that name appeared since `newFileURL` looked.
    private func makeWriter(header: LogHeader, start: Date) throws -> (LogFileWriter, URL) {
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
                    diskSpace: diskSpace
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
    /// can suspend.
    private func replayStartupInit(_ rec: ActiveRecording) {
        // Once per recording, never again while it runs.
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

    private func startSources(_ rec: ActiveRecording) {
        for source in sources {
            if case .unavailable(let reason) = source.availability {
                rec.record(LifecycleSample(.error, detail: "\(source.name) unavailable: \(reason)"))
                continue
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

    /// Writes one periodic `stats` row, and an `error` row if the writer
    /// queue held more than 2 s of data at its peak (docs/PLAN.md §4.3).
    private func writeStatsRow(_ rec: ActiveRecording) async {
        guard recording === rec, rec.isWritable else { return }
        let end = rec.clock.now()
        let sample = await rec.writer.closeStatsWindow(at: end)
        guard rec.isWritable else { return }
        rec.sink.record(LogEvent(timestamp: end, payload: .stats(sample)))
        live.motionHz = sample.motionHz
        let total = sample.counts.values.reduce(0, +)
        if sample.windowS > 0 {
            let twoSeconds = Int((2 * Double(total) / sample.windowS).rounded(.up))
            if sample.queueDepthMax > max(twoSeconds, 200) {
                rec.record(LifecycleSample(
                    .error,
                    detail: "writer queue peaked at \(sample.queueDepthMax) events, more than 2 s of data (\(twoSeconds))"
                ))
            }
        }
    }

    private func updateLive(_ rec: ActiveRecording) async {
        guard recording === rec else { return }
        live.elapsed = max(0, rec.clock.now().seconds)
        let fix = sources.lazy.compactMap { ($0 as? any LiveReferenceFixReporting)?.latestReferenceFix }.first
        live.gpsSpeedKmh = fix.flatMap { $0.speed >= 0 ? $0.speed * 3.6 : nil }
        live.referenceFix = fix
        let bytes = await rec.writer.bytesWritten
        if recording === rec { live.fileBytes = bytes }
    }

    private func flushInBackgroundTask(_ rec: ActiveRecording, reason: String) {
        let writer = rec.writer
        let task = BackgroundTask(name: "DriveLogger.flush.\(reason)")
        Task {
            // A throw is this call's result, not a report: the writer
            // delivers each failure once on `failures` (rule 4).
            try? await writer.flush()
            task.end()
        }
    }

    // MARK: - Internals: ending

    /// Runs `body` as the one end path; concurrent callers wait for it.
    private func end(_ rec: ActiveRecording, _ body: @escaping @MainActor (RecordingSession) async -> Void) async {
        if let ending {
            await ending.value
            return
        }
        let task = Task { await body(self) }
        ending = task
        await task.value
        ending = nil
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
        quiesce(rec)
        rec.stopRowQueued = true   // no row of any kind after the error row
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

    private func finishRecording(_ rec: ActiveRecording) {
        guard recording === rec else { return }
        recording = nil
        currentFile = nil
        live.gpsSpeedKmh = nil
        live.referenceFix = nil
        setIdleTimerDisabled(false)
        refreshBackgroundRisk()
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
        rec.record(LifecycleSample(.error, detail: "write failed: \(Self.describe(failure))"))
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

    private func handleLinkEvent(_ event: LinkEvent) {
        consumedLinkEvents += 1
        switch event {
        case .session(.reading(let reading)) where reading.measurement.pid == .vehicleSpeed && reading.isFromPrimaryECU:
            live.obdSpeedKmh = reading.measurement.value
        case .session(.pollRate(let hz, _)):
            live.obdHz = hz
        case .ble(_, let to, _, _) where to != .connected:
            live.obdSpeedKmh = nil
            live.obdHz = 0
        default:
            break
        }
        guard let rec = recording, rec.acceptsLinkEvents else { return }
        if rec.linkEventsToSkip > 0 {
            // Delivered before Start: replayed already, or not part of the
            // recording (M4 dedup contract).
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
    }

    private func readDiskSpace() async -> Int64? {
        let provider = diskSpace
        let url = store.directory
        return await Task.detached(priority: .utility) {
            try? provider.availableBytes(for: url)
        }.value
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
private final class ActiveRecording {
    let generation: Int
    /// The recording's one clock.
    let clock: SessionClock
    let writer: LogFileWriter
    let url: URL
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
    var statsTimer: Task<Void, Never>?
    var statsTick: Task<Void, Never>?
    var liveTimer: Task<Void, Never>?

    init(generation: Int, clock: SessionClock, writer: LogFileWriter, url: URL) {
        self.generation = generation
        self.clock = clock
        self.writer = writer
        self.url = url
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
