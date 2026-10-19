import DriveLoggerCore
import Foundation
import Network

/// The raw report of the path monitor (UX-17): kept next to the mapped
/// `Connection` so Diagnostics can show what the system said, not only what
/// the policy made of it. `connection` is Core's mapping
/// (`PackDownloadRules.connection`): no path → `.none`; the cellular
/// interface → `.cellular`; expensive or constrained Wi-Fi (Personal Hotspot,
/// Low Data Mode) → `.meteredWiFi`; else `.unmetered`.
struct PackPath: Hashable, Sendable {
    var satisfied: Bool
    var usesWiFi: Bool
    var usesCellular: Bool
    var usesWired: Bool
    var expensive: Bool
    var constrained: Bool

    init(satisfied: Bool, usesWiFi: Bool = false, usesCellular: Bool = false, usesWired: Bool = false,
         expensive: Bool = false, constrained: Bool = false) {
        self.satisfied = satisfied
        self.usesWiFi = usesWiFi
        self.usesCellular = usesCellular
        self.usesWired = usesWired
        self.expensive = expensive
        self.constrained = constrained
    }

    init(_ path: NWPath) {
        self.init(satisfied: path.status == .satisfied, usesWiFi: path.usesInterfaceType(.wifi),
                  usesCellular: path.usesInterfaceType(.cellular), usesWired: path.usesInterfaceType(.wiredEthernet),
                  expensive: path.isExpensive, constrained: path.isConstrained)
    }

    /// A path that maps to `connection` (fakes and tests).
    init(connection: PackDownloadRules.Connection) {
        switch connection {
        case .none: self.init(satisfied: false)
        case .unmetered: self.init(satisfied: true, usesWiFi: true)
        case .cellular: self.init(satisfied: true, usesCellular: true, expensive: true)
        case .meteredWiFi: self.init(satisfied: true, usesWiFi: true, expensive: true)
        }
    }

    var connection: PackDownloadRules.Connection {
        PackDownloadRules.connection(satisfied: satisfied, cellular: usesCellular, expensive: expensive,
                                     constrained: constrained)
    }

    /// "Wi-Fi", "cellular", "Wi-Fi + cellular", "wired", "other"; "none" when unsatisfied.
    var interfaces: String {
        guard satisfied else { return "none" }
        var names: [String] = []
        if usesWiFi { names.append("Wi-Fi") }
        if usesCellular { names.append("cellular") }
        if usesWired { names.append("wired") }
        return names.isEmpty ? "other" : names.joined(separator: " + ")
    }
}

/// Owns an `NWPathMonitor` for the life of the app.
final class PackNetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "drivelogger.pack-network", qos: .utility)

    func start(onChange: @escaping @Sendable (PackPath) -> Void) {
        monitor.pathUpdateHandler = { path in onChange(PackPath(path)) }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
