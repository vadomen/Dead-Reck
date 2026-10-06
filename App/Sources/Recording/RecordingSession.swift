import DriveLoggerCore
import Foundation
import Observation
import SwiftUI

/// What the recorder is doing.
enum RecordingState: Hashable, Sendable {
    case idle
    /// 5 s keep-still calibration before Start.
    case calibrating
    case recording
    case stopping
    case failed(reason: String)
}

/// Live numbers for the dashboard. Display only — never written to the log.
struct LiveStatus: Hashable, Sendable {
    var obdSpeedKmh: Double?
    var gpsSpeedKmh: Double?
    var obdHz: Double = 0
    var motionHz: Double = 0
    var elapsed: TimeInterval = 0
    var fileBytes: Int = 0
}

/// Wires sensors, the OBD link and the writer into one recording.
///
/// Owns exactly one `SessionClock` per recording and hands it to every
/// source; converts ELM uptimes with `clock.timestamp(uptimeSeconds:)`; writes
/// `lifecycle` rows for start/stop/background/foreground/calibration/errors and
/// a `stats` row every 10 s; flushes on background and memory warnings; keeps
/// the screen awake while recording. Implemented in M2.
@MainActor
@Observable
final class RecordingSession {
    private(set) var state: RecordingState = .idle
    private(set) var live = LiveStatus()
    private(set) var currentFile: URL?

    private let link: any OBDLinkServicing
    private let sources: [any SensorSource]
    private let store: LogStore
    private let uptime: any UptimeSource

    init(
        link: any OBDLinkServicing,
        sources: [any SensorSource],
        store: LogStore,
        uptime: any UptimeSource = SystemUptimeSource()
    ) {
        self.link = link
        self.sources = sources
        self.store = store
        self.uptime = uptime
    }

    /// Start is allowed when the link is polling, or when the user explicitly
    /// chose to record without OBD (docs/PLAN.md §3.3).
    var canStart: Bool {
        fatalError("M2: RecordingSession.canStart")
    }

    /// 5 s keep-still calibration. Writes `calibrationStart` and
    /// `calibrationEnd` into the next recording.
    func calibrate() async {
        fatalError("M2: RecordingSession.calibrate")
    }

    func start(mount: String, vehicle: String, allowWithoutOBD: Bool) async throws {
        fatalError("M2: RecordingSession.start")
    }

    /// Writes a `marker` row.
    func mark(_ text: String) {
        fatalError("M2: RecordingSession.mark")
    }

    func stop() async {
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
