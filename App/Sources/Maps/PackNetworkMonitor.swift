import DriveLoggerCore
import Foundation
import Network

/// The path monitor behind the download policy (UX-8): maps the system path
/// to Core's `PackDownloadRules.Connection` and tells the downloader on every
/// change. No path: `.none`. Cellular, expensive (a hotspot) or constrained
/// (Low Data Mode): `.cellularOrExpensive`. Else `.unmetered`.
enum PackNetwork {
    static func connection(satisfied: Bool, expensive: Bool, constrained: Bool, cellular: Bool)
        -> PackDownloadRules.Connection {
        guard satisfied else { return .none }
        return expensive || constrained || cellular ? .cellularOrExpensive : .unmetered
    }

    static func connection(_ path: NWPath) -> PackDownloadRules.Connection {
        connection(satisfied: path.status == .satisfied, expensive: path.isExpensive,
                   constrained: path.isConstrained, cellular: path.usesInterfaceType(.cellular))
    }
}

/// Owns an `NWPathMonitor` for the life of the app.
final class PackNetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "drivelogger.pack-network", qos: .utility)

    func start(onChange: @escaping @Sendable (PackDownloadRules.Connection) -> Void) {
        monitor.pathUpdateHandler = { path in onChange(PackNetwork.connection(path)) }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
