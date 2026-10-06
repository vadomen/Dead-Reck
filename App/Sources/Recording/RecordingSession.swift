import DriveLoggerCore
import Foundation
import Observation
import SwiftUI

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
    /// `LogFileWriter.failures`) and the recording was stopped. Shown to the
    /// user, because the failure row may not have reached the file.
    /// `unwrittenEvents` comes from `LogFileSummary`. Never entered for low
    /// free space: that is a clean stop (rule 2 on `RecordingSession`).
    case failed(reason: String, unwrittenEvents: Int)
}

/// Why a recording ended through the normal stop path. The raw value is the
/// `detail` of the `lifecycle` `stop` row: an on-disk string, never rename it.
enum RecordingStopReason: String, Hashable, Sendable {
    /// The user tapped Stop.
    case user
    /// Free space fell below the stop floor (rule 2 on `RecordingSession`).
    case lowDiskSpace
}

/// Why `start` is refused right now. `canStart` is `startBlocker == nil`.
enum RecordingStartBlocker: Error, Hashable, Sendable {
    /// Free space is strictly below `requiredBytes`, the warning threshold
    /// (rule 3 on `RecordingSession`). No user choice overrides it.
    case lowDiskSpace(availableBytes: Int64, requiredBytes: Int64)
    /// The link is not polling and the user has not chosen to record without
    /// OBD (docs/PLAN.md §3.3).
    case obdNotReady
}

/// Live numbers for the dashboard. Display only — never written to the log.
struct LiveStatus: Hashable, Sendable {
    var obdSpeedKmh: Double?
    var gpsSpeedKmh: Double?
    var obdHz: Double = 0
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
/// Owns exactly one `SessionClock` per recording and hands it to every
/// source; converts ELM uptimes with `clock.timestamp(uptimeSeconds:)`; writes
/// `lifecycle` rows for start/stop/background/foreground/calibration/errors and
/// a `stats` row every 10 s; flushes on background and memory warnings; keeps
/// the screen awake while recording. Implemented in M2.
///
/// **Disk space: warn, then stop at a floor.** This is the recorder's one
/// low-disk policy. The thresholds are `warningFreeBytes` (default 200 MB)
/// and `stopFreeBytes` (default 50 MB), handed unchanged to `LogFileWriter`,
/// whose `diskSpaceNotices` drive rules 1 and 2:
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
///    When one reading yields both notices, both rows are written, warning
///    first. A `.critical` while already `stopping` writes its row and does
///    not start a second stop.
/// 3. **Start** — refused strictly below `warningFreeBytes`
///    (`DiskSpacePolicy.canStart`): `canStart` is false and `startBlocker`
///    is `.lowDiskSpace(availableBytes:requiredBytes:)`. `start` re-reads
///    free space before creating anything and throws that blocker if it is
///    now below; no file is created. A `diskSpace` provider that throws does
///    not block start (the writer treats an unreadable volume the same way);
///    rule 4 remains the backstop.
/// 4. **Write failures** — anything on `LogFileWriter.failures` (`ENOSPC`,
///    I/O errors, a failed truncate): write a `lifecycle` `error` row, call
///    `finish()`, enter `failed(reason:unwrittenEvents:)`. This is the only
///    way into `failed`; it also applies when the final `finish()` of a
///    rule-2 stop reports a `failure`.
///
/// Disk-space notices are advisory and never lead to `failed`; write
/// failures never produce a warning.
@MainActor
@Observable
final class RecordingSession {
    private(set) var state: RecordingState = .idle
    private(set) var live = LiveStatus()
    private(set) var currentFile: URL?
    /// How the last recording ended through `stop`, for the UI ("Stopped:
    /// low disk space"). `nil` before the first stop and after a write
    /// failure, which `state` reports instead.
    private(set) var lastStopReason: RecordingStopReason?

    private let link: any OBDLinkServicing
    private let sources: [any SensorSource]
    private let store: LogStore
    private let uptime: any UptimeSource
    private let diskSpace: any DiskSpaceProvider
    private let warningFreeBytes: Int64
    private let stopFreeBytes: Int64

    /// - Precondition: `stopFreeBytes < warningFreeBytes`.
    init(
        link: any OBDLinkServicing,
        sources: [any SensorSource],
        store: LogStore,
        uptime: any UptimeSource = SystemUptimeSource(),
        diskSpace: any DiskSpaceProvider = VolumeDiskSpaceProvider(),
        warningFreeBytes: Int64 = DiskSpacePolicy.defaultWarningFreeBytes,
        stopFreeBytes: Int64 = DiskSpacePolicy.defaultStopFreeBytes
    ) {
        precondition(stopFreeBytes < warningFreeBytes, "stopFreeBytes must be below warningFreeBytes")
        self.link = link
        self.sources = sources
        self.store = store
        self.uptime = uptime
        self.diskSpace = diskSpace
        self.warningFreeBytes = warningFreeBytes
        self.stopFreeBytes = stopFreeBytes
    }

    /// `startBlocker == nil`. Start is allowed when free space is at or
    /// above `warningFreeBytes` (rule 3) and the link is polling or the user
    /// explicitly chose to record without OBD (docs/PLAN.md §3.3).
    var canStart: Bool {
        fatalError("M2: RecordingSession.canStart")
    }

    /// Why start is refused, `nil` when it is allowed. `.lowDiskSpace` is
    /// checked first, because no user choice overrides it. Reads `diskSpace`
    /// against `store.directory` each time it is evaluated.
    var startBlocker: RecordingStartBlocker? {
        fatalError("M2: RecordingSession.startBlocker")
    }

    /// Creates the clock, the file and starts every source, then runs the
    /// keep-still calibration as the recording's first phase (`calibrating`),
    /// then moves to `recording`. Pass `calibration: .zero` to skip it; the
    /// rows are still written, back to back, so a reader can tell.
    ///
    /// Throws `RecordingStartBlocker.lowDiskSpace` if free space is below
    /// `warningFreeBytes` when it is called (rule 3), before any clock, file
    /// or source exists. Clears `lastStopReason` and the disk-space fields of
    /// `live`.
    func start(
        mount: String,
        vehicle: String,
        allowWithoutOBD: Bool,
        calibration: Duration = .seconds(5)
    ) async throws {
        fatalError("M2: RecordingSession.start")
    }

    /// Writes a `marker` row.
    func mark(_ text: String) {
        fatalError("M2: RecordingSession.mark")
    }

    /// The normal stop path, used by the user and by rule 2: writes the
    /// `stop` row with `reason.rawValue` as its detail and the final `stats`
    /// row, calls `finish()`, returns to `idle` and sets `lastStopReason`.
    /// If `finish()` reports a `failure`, rule 4 applies instead.
    func stop(reason: RecordingStopReason = .user) async {
        fatalError("M2: RecordingSession.stop")
    }

    /// Writes `background`/`foreground` rows; flushes on background.
    func handleScenePhase(_ phase: ScenePhase) {
        fatalError("M2: RecordingSession.handleScenePhase")
    }

    /// Writes a `memoryWarning` row and flushes.
    func handleMemoryWarning() {
        fatalError("M2: RecordingSession.handleMemoryWarning")
    }
}
