import DriveLoggerCore
import Foundation
import Observation
import UIKit

/// The services that live for the whole app run, created once at launch.
///
/// The link must exist at launch: CoreBluetooth state restoration only
/// reconnects to a central created with the same restore identifier during
/// `didFinishLaunching` (`OBDLinkService.restoreIdentifier`). The recording
/// session subscribes to the link's events in its `init`, so nothing the link
/// reports after launch is missed.
@MainActor
final class AppServices {
    let link: any OBDLinkServicing
    let sensors: SensorSuite
    let store: LogStore
    let session: RecordingSession
    /// Live dead reckoning for each recording (N4 B) and each Navigate
    /// session (UX-1): it consumes every feed and writes a recording's
    /// sidecar (none for Navigate).
    let navigation: NavigationService
    /// The road packs: the store in Application Support/RoadPacks (filled
    /// from the developer inbox Documents/RoadPacks at launch), verified
    /// once each.
    let roadPacks: RoadPackLibrary
    /// The road pack list (cached, fetched when Settings → Maps opens) and
    /// the downloads (UX-8). Record pauses downloads: see `RecordActiveObserver`.
    let manifest: PackManifestService
    let downloader: PackDownloader
    private let network = PackNetworkMonitor()
    private var recordObserver: RecordActiveObserver?

    init(
        link: any OBDLinkServicing = OBDLinkFactory.makeDefault(),
        sensors: SensorSuite = .makeDefault()
    ) {
        self.link = link
        self.sensors = sensors
        // If Documents/logs can't be created now, `start` tries again and
        // reports the error then.
        store = (try? LogStore.documents()) ?? LogStore(directory: LogStore.defaultDirectory)
        var notes = [sensors.note]
        if link is SimulatedOBDLink {
            notes.append("Simulated OBD adapter (MockELMAdapter with the bench-car script).")
        }
        session = RecordingSession(
            link: link,
            sources: sensors.sources,
            displayLocation: sensors.displayLocation,
            store: store,
            sensorConfiguration: sensors.configuration,
            notes: notes.compactMap { $0 }.joined(separator: " ").nilIfEmpty
        )
        let roadPacks = RoadPackLibrary.makeDefault()
        self.roadPacks = roadPacks
        let navigation = NavigationService(library: roadPacks)
        self.navigation = navigation
        // Remove (Settings → Maps) deletes only when no run may have a pack
        // mapped: no recording or Navigate run in the session (starting
        // included) and none still draining in the navigation service.
        let session = session
        let runActivity: RoadPackLibrary.RunActivity = {
            if await session.hasActiveRun { return true }
            return await navigation.hasActiveRun
        }
        // The first scan runs launch maintenance (inbox install, cleanup)
        // and verification off the main actor at .utility; never awaited
        // here. Sessions map packs only via `candidates()`, which awaits it.
        Task(priority: .utility) {
            await roadPacks.setRunActivity(runActivity)
            await roadPacks.rescan()
        }
        let manifest = PackManifestService.makeDefault()
        self.manifest = manifest
        let downloader = PackDownloader(
            directory: RoadPackStore.defaultDirectory(), library: roadPacks,
            cellularAllowed: UserDefaults.standard.bool(forKey: MapsSettings.cellularKey), runActive: runActivity)
        self.downloader = downloader
        Task(priority: .utility) { await manifest.loadCache() }
        network.start { connection in Task { await downloader.setConnection(connection) } }
        recordObserver = RecordActiveObserver(session: session) { active in
            Task { await downloader.setRecordActive(active) }
        }
        // Synchronous inside `start`, before any row: only start the task.
        session.onNavigationFeed = { feed in navigation.start(feed) }
        // The sidecar is flushed with the log on background (R14.1-4).
        session.onFlush = { await navigation.flush() }
        // UX-1: Navigate runs whenever the link polls and Record doesn't.
        // After the feed hook is set, so the first session's feed is seen.
        session.enableNavigate()
    }
}

/// Tells the downloader whether Record is active (calibrating, recording or
/// stopping): downloads pause while it is (UX-8). Navigate does not pause
/// them. A first version, observing `RecordingSession.state`.
@MainActor
final class RecordActiveObserver {
    private let session: RecordingSession
    private let onChange: @MainActor (Bool) -> Void

    nonisolated static func isActive(_ state: RecordingState) -> Bool {
        switch state {
        case .calibrating, .recording, .stopping: true
        case .idle, .failed: false
        }
    }

    init(session: RecordingSession, onChange: @escaping @MainActor (Bool) -> Void) {
        self.session = session
        self.onChange = onChange
        observe()
    }

    private func observe() {
        let session = session
        let active = withObservationTracking {
            Self.isActive(session.state)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        onChange(active)
    }
}

/// Which hardware produced a recording, for the header.
enum DeviceInfo {
    /// Model identifier (`iPhone16,1`, from `uname`; on the simulator
    /// `Simulator (iPhone16,1)`, so a simulated recording can't pass for a
    /// phone's sensor data), system name and version.
    @MainActor
    static func current() -> DeviceIdentity {
        DeviceIdentity(
            model: modelIdentifier(),
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion
        )
    }

    nonisolated static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "Simulator (\(simulated))"
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
