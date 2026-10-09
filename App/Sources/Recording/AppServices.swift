import DriveLoggerCore
import Foundation
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
    /// Live dead reckoning for each recording (N4 B): it consumes every
    /// recording's navigation feed and writes its sidecar.
    let navigation: NavigationService

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
            store: store,
            sensorConfiguration: sensors.configuration,
            notes: notes.compactMap { $0 }.joined(separator: " ").nilIfEmpty
        )
        let navigation = NavigationService()
        self.navigation = navigation
        // Synchronous inside `start`, before any row: only start the task.
        session.onNavigationFeed = { feed in navigation.start(feed) }
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
