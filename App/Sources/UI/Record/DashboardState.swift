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
    var obdHz = DisplayFormat.hz(0)
    var motionHz = DisplayFormat.hz(0)
    var elapsed = "0:00"
    var fileSize = DisplayFormat.bytes(0)
    var notices: [Notice] = []
    var blocker: StartBlockerNotice?
    var allowsRecordingWithoutOBD = false
    /// "SIMULATED ADAPTER · SIMULATED SENSORS" on the simulator.
    var simulationBadge: String?

    /// Show the "Record without OBD" toggle (R5.1-2): while the blocker offers
    /// it, and for as long as it is on, so the choice stays visible (the
    /// blocker clears once it is on).
    var showsRecordWithoutOBD: Bool {
        allowsRecordingWithoutOBD || blocker?.offersRecordWithoutOBD == true
    }

    var isActive: Bool {
        switch phase {
        case .calibrating, .recording, .stopping: true
        case .idle, .failed: false
        }
    }

    /// Big banner text and colour.
    var headline: (text: String, tone: Tone) {
        switch phase {
        case .idle: (String(localized: "NOT RECORDING"), .bad)
        case .calibrating(let left): (String(localized: "KEEP STILL  \(left) s"), .caution)
        case .recording: (String(localized: "RECORDING"), .good)
        case .stopping: (String(localized: "STOPPING"), .caution)
        case .failed: (String(localized: "RECORDING FAILED"), .bad)
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
            notices.append(Notice(text: String(localized: "Writing failed: \(reason). \(unwritten) events were not written."), tone: .bad))
        case .idle:
            if i.lastStopReason == .lowDiskSpace {
                notices.append(Notice(text: String(localized: "Stopped automatically: disk space ran low."), tone: .bad))
            }
        default: break
        }
        if i.live.lowDiskSpaceWarning, s.isActive {
            let text = if let available = i.live.availableDiskBytes {
                String(localized: "Low disk space (\(DisplayFormat.bytes(available)) free). Recording stops automatically when it runs out.")
            } else {
                String(localized: "Low disk space. Recording stops automatically when it runs out.")
            }
            notices.append(Notice(text: text, tone: .bad))
        }
        if let risk = i.backgroundRisk {
            notices.append(Notice(text: risk, tone: .caution))
        }
        for sensor in i.unavailableSensors {
            notices.append(Notice(text: String(localized: "\(SensorNames.display(sensor.name)) unavailable: \(sensor.reason)"), tone: .caution))
        }
        s.notices = notices

        switch (i.simulatedAdapter, i.simulatedSensors) {
        case (true, true): s.simulationBadge = String(localized: "SIMULATED ADAPTER · SIMULATED SENSORS")
        case (true, false): s.simulationBadge = String(localized: "SIMULATED ADAPTER")
        case (false, true): s.simulationBadge = String(localized: "SIMULATED SENSORS")
        case (false, false): s.simulationBadge = nil
        }
        return s
    }
}

/// Source names are identifiers (`deviceMotion`); this is what the user reads.
enum SensorNames {
    static func display(_ name: String) -> String {
        switch name {
        case "deviceMotion", "rawIMU", "simulatedMotion": String(localized: "Motion")
        case "altimeter": String(localized: "Barometer")
        case "referenceLocation", "simulatedLocation": String(localized: "GPS")
        case "simulatedMagBaro": String(localized: "Magnetometer/barometer")
        default: name
        }
    }
}
