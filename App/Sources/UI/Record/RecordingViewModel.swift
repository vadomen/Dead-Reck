import DriveLoggerCore
import Foundation
import Observation

/// Mark presets offered on the mark sheet.
enum MarkPreset {
    static let all = ["tunnel", "traffic jam", "junction", "bad road", "parking", "stop"]
}

/// State and actions of the Record tab. Reads the session and link, exposes a
/// plain `DashboardState`, and sequences the start flow. No hardware here.
@MainActor
@Observable
final class RecordingViewModel {
    /// Length of the keep-still phase passed to `start`.
    static let calibrationSeconds = 5

    var checklist: PreDriveChecklist
    var startError: String?
    var isMarkSheetPresented = false
    /// Last mark written, for a short confirmation under the buttons.
    private(set) var lastMark: String?
    /// Incremented per mark, for haptic feedback.
    private(set) var markCount = 0
    /// Bumped to re-read non-observable source availability.
    private(set) var refreshTick = 0

    @ObservationIgnored private let session: RecordingSession
    @ObservationIgnored private let link: any OBDLinkServicing
    @ObservationIgnored private let sources: [any SensorSource]
    @ObservationIgnored private let simulatedSensors: Bool
    @ObservationIgnored private let store: ChecklistStore
    @ObservationIgnored private var lastMarkTask: Task<Void, Never>?

    init(
        session: RecordingSession,
        link: any OBDLinkServicing,
        sources: [any SensorSource],
        simulatedSensors: Bool,
        store: ChecklistStore = ChecklistStore()
    ) {
        self.session = session
        self.link = link
        self.sources = sources
        self.simulatedSensors = simulatedSensors
        self.store = store
        checklist = store.load()
    }

    convenience init(services: AppServices) {
        self.init(
            session: services.session,
            link: services.link,
            sources: services.sensors.sources,
            simulatedSensors: services.sensors.note != nil
        )
    }

    var dashboard: DashboardState {
        _ = refreshTick
        return DashboardState.make(.init(
            state: session.state,
            live: session.live,
            link: link.state,
            startBlocker: session.startBlocker,
            allowsRecordingWithoutOBD: session.allowsRecordingWithoutOBD,
            backgroundRisk: session.backgroundRiskWarning,
            lastStopReason: session.lastStopReason,
            unavailableSensors: sources.compactMap { source in
                if case .unavailable(let reason) = source.availability { return (source.name, reason) }
                return nil
            },
            simulatedAdapter: link is SimulatedOBDLink,
            simulatedSensors: simulatedSensors,
            calibrationSeconds: Self.calibrationSeconds
        ))
    }

    var gate: StartGate {
        StartGate.evaluate(checklist: checklist, blocker: dashboard.blocker)
    }

    /// Re-reads things that are not observable (permission changes while the
    /// app was in Settings) and the disk reading.
    func refresh() {
        refreshTick += 1
        session.refreshBackgroundRisk()
        Task { await session.refreshDiskSpace() }
    }

    func setRecordWithoutOBD(_ allowed: Bool) {
        session.allowsRecordingWithoutOBD = allowed
    }

    func start() async {
        // `session.isStarting` and the state, not a flag of our own: a flag
        // held across the calibration ignored a re-Start after a stop and
        // let its late reset clear the next checklist (R5.1-3).
        guard gate.allowsStart, !session.isStarting, !ConsoleText.isRecordingActive(session.state) else { return }
        startError = nil
        store.save(checklist)
        // A scan left running, or pending while Bluetooth is off, would
        // compete with the OBD link for the radio or resume mid-drive (R5.2-2).
        link.stopScan()
        // Snapshot what this drive uses, then reset the per-drive choices
        // before awaiting the (5 s) calibration.
        let mount = checklist.mountForHeader
        let vehicle = checklist.vehicleForHeader
        let allowWithoutOBD = session.allowsRecordingWithoutOBD
        // "Record without OBD" is a per-recording choice, asked again next time.
        session.allowsRecordingWithoutOBD = false
        // Confirmations apply to one drive.
        checklist.mountConfirmed = false
        checklist.orientationConfirmed = false
        do {
            try await session.start(
                mount: mount,
                vehicle: vehicle,
                allowWithoutOBD: allowWithoutOBD,
                calibration: .seconds(Self.calibrationSeconds)
            )
        } catch {
            startError = StartErrorText.message(for: error)
        }
    }

    /// Markers are written during calibration and recording only.
    static func canMark(_ state: RecordingState) -> Bool {
        state == .calibrating || state == .recording
    }

    func stop() {
        Task { await session.stop() }
    }

    /// Writes a marker and confirms it. Does nothing, and confirms nothing,
    /// unless a recording is running: the session drops a marker after a stop
    /// or a failure, and "Marked" must not be shown for one that was not
    /// written (R5.1-6). The sheet closes either way.
    func mark(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard Self.canMark(session.state) else {
            isMarkSheetPresented = false
            return
        }
        session.mark(trimmed)
        markCount += 1
        lastMark = trimmed
        isMarkSheetPresented = false
        lastMarkTask?.cancel()
        lastMarkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.lastMark = nil }
        }
    }
}
