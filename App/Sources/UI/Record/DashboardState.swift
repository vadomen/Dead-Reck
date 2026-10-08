import DriveLoggerCore
import Foundation

/// Everything the recording screen shows, as plain values. Built by
/// `DashboardState.make` from the services' state, or by hand in previews and
/// tests; the views never read a service.
struct DashboardState: Equatable {
    enum Phase: Equatable {
        case idle
        /// `secondsLeft` of the keep-still phase.
        case calibrating(secondsLeft: Int)
        case recording
        case stopping
        case failed(reason: String, unwrittenEvents: Int)
    }

    struct Notice: Equatable, Identifiable {
        var text: String
        var tone: Tone
        var id: String { text }
    }

    var phase: Phase = .idle
    var adapter = AdapterStatus(.idle)
    var obdSpeed = "--"
    var gpsSpeed = "--"
    /// The OBD tile is red while recording without a polling adapter.
    var obdTone: Tone = .neutral
    var obdHz = "0.0"
    var motionHz = "0.0"
    var elapsed = "0:00"
    var fileSize = "0 B"
    var notices: [Notice] = []
    var blocker: StartBlockerNotice?
    var allowsRecordingWithoutOBD = false
    /// "SIMULATED ADAPTER · SIMULATED SENSORS" on the simulator.
    var simulationBadge: String?

    var isActive: Bool {
        switch phase {
        case .calibrating, .recording, .stopping: true
        case .idle, .failed: false
        }
    }

    /// Big banner text and colour.
    var headline: (text: String, tone: Tone) {
        switch phase {
        case .idle: ("NOT RECORDING", .bad)
        case .calibrating(let left): ("KEEP STILL  \(left) s", .caution)
        case .recording: ("RECORDING", .good)
        case .stopping: ("STOPPING", .caution)
        case .failed: ("RECORDING FAILED", .bad)
        }
    }

    // MARK: - Building from the services

    struct Inputs {
        var state: RecordingState
        var live: LiveStatus
        var link: OBDLinkState
        var startBlocker: RecordingStartBlocker?
        var allowsRecordingWithoutOBD: Bool
        var backgroundRisk: String?
        var lastStopReason: RecordingStopReason?
        /// Sources whose `availability` is `.unavailable`: (name, reason).
        var unavailableSensors: [(name: String, reason: String)]
        var simulatedAdapter: Bool
        var simulatedSensors: Bool
        var calibrationSeconds: Int
    }

    static func make(_ i: Inputs) -> DashboardState {
        var s = DashboardState()
        s.adapter = AdapterStatus(i.link)
        s.obdSpeed = DisplayFormat.speed(i.live.obdSpeedKmh)
        s.gpsSpeed = DisplayFormat.speed(i.live.gpsSpeedKmh)
        s.obdHz = DisplayFormat.hz(i.live.obdHz)
        s.motionHz = DisplayFormat.hz(i.live.motionHz)
        s.elapsed = DisplayFormat.elapsed(i.live.elapsed)
        s.fileSize = DisplayFormat.bytes(i.live.fileBytes)
        s.allowsRecordingWithoutOBD = i.allowsRecordingWithoutOBD
        s.blocker = StartBlockerNotice(i.startBlocker)

        switch i.state {
        case .idle: s.phase = .idle
        case .calibrating:
            s.phase = .calibrating(secondsLeft: DisplayFormat.secondsLeft(total: i.calibrationSeconds, elapsed: i.live.elapsed))
        case .recording: s.phase = .recording
        case .stopping: s.phase = .stopping
        case .failed(let reason, let unwritten): s.phase = .failed(reason: reason, unwrittenEvents: unwritten)
        }

        if s.isActive, !s.adapter.isPolling { s.obdTone = .bad }
        else if s.adapter.isPolling { s.obdTone = .good }

        var notices: [Notice] = []
        switch s.phase {
        case .failed(let reason, let unwritten):
            notices.append(Notice(text: "Writing failed: \(reason). \(unwritten) events were not written.", tone: .bad))
        case .idle:
            if i.lastStopReason == .lowDiskSpace {
                notices.append(Notice(text: "Stopped automatically: disk space ran low.", tone: .bad))
            }
        default: break
        }
        if i.live.lowDiskSpaceWarning, s.isActive {
            let free = i.live.availableDiskBytes.map { " (\(DisplayFormat.bytes($0)) free)" } ?? ""
            notices.append(Notice(text: "Low disk space\(free). Recording stops automatically when it runs out.", tone: .bad))
        }
        if let risk = i.backgroundRisk {
            notices.append(Notice(text: risk, tone: .caution))
        }
        for sensor in i.unavailableSensors {
            notices.append(Notice(text: "\(SensorNames.display(sensor.name)) unavailable: \(sensor.reason)", tone: .caution))
        }
        s.notices = notices

        switch (i.simulatedAdapter, i.simulatedSensors) {
        case (true, true): s.simulationBadge = "SIMULATED ADAPTER · SIMULATED SENSORS"
        case (true, false): s.simulationBadge = "SIMULATED ADAPTER"
        case (false, true): s.simulationBadge = "SIMULATED SENSORS"
        case (false, false): s.simulationBadge = nil
        }
        return s
    }
}

/// Source names are identifiers (`deviceMotion`); this is what the user reads.
enum SensorNames {
    static func display(_ name: String) -> String {
        switch name {
        case "deviceMotion", "rawIMU", "simulatedMotion": "Motion"
        case "altimeter": "Barometer"
        case "referenceLocation", "simulatedLocation": "GPS"
        case "simulatedMagBaro": "Magnetometer/barometer"
        default: name
        }
    }
}
