import Foundation

/// The one path from the "Use cellular data" switch to the downloader
/// (UX-17). The switch is an `@AppStorage` UserDefault written from several
/// places (Settings → Maps, the first-launch step); this observes the
/// UserDefault itself, so every write reaches `PackDownloader` whether or
/// not Settings → Maps is on screen, and in the order written (one
/// `OrderedRelay`, not one `Task` per change). The downloader and the
/// switch therefore end on the same value.
final class CellularSettingObserver: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let relay: OrderedRelay<Bool>
    private let lock = NSLock()
    private var last: Bool?
    private var token: NSObjectProtocol?

    /// Reads the current value and sends it, then sends every change.
    init(defaults: UserDefaults = .standard, key: String = MapsSettings.cellularKey, downloader: PackDownloader) {
        self.defaults = defaults
        self.key = key
        relay = OrderedRelay { await downloader.setCellularAllowed($0) }
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in self?.sync() }
        sync()
    }

    /// Sends the UserDefault's value when it differs from the last one sent.
    func sync() {
        let value = defaults.bool(forKey: key)
        let changed = lock.withLock { () -> Bool in
            if last == value { return false }
            last = value
            return true
        }
        // Sent outside the lock; `send` is ordered by the relay's stream, and
        // two racing syncs read the same stored value in either order.
        if changed { relay.send(value) }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
