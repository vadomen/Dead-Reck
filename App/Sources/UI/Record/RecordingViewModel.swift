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
    private(set) var isStartRequested = false

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
        guard gate.allowsStart, !isStartRequested else { return }
        isStartRequested = true
        startError = nil
        store.save(checklist)
        // A scan left running would compete with the OBD link for the radio.
        if link.state == .scanning { link.stopScan() }
        let allowWithoutOBD = session.allowsRecordingWithoutOBD
        defer {
            isStartRequested = false
            // "Record without OBD" is a per-recording choice, asked again next time.
            session.allowsRecordingWithoutOBD = false
            // Confirmations apply to one drive.
            checklist.mountConfirmed = false
            checklist.orientationConfirmed = false
        }
        do {
            try await session.start(
                mount: checklist.mountForHeader,
                vehicle: checklist.vehicleForHeader,
                allowWithoutOBD: allowWithoutOBD,
                calibration: .seconds(Self.calibrationSeconds)
            )
        } catch {
            startError = StartErrorText.message(for: error)
        }
    }

    func stop() {
        Task { await session.stop() }
    }

    func mark(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
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
