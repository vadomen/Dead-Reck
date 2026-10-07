import CoreBluetooth
import DriveLoggerCore
import Foundation

/// Bluetooth availability as the link service sees it.
enum BLEAvailability: Hashable, Sendable {
    case poweredOn
    /// Off, unauthorised, unsupported (the simulator), resetting or unknown;
    /// the string says which.
    case unavailable(String)
}

/// A connected adapter with its UART pair selected and notifications on.
struct BLELinkReady: Sendable {
    var id: UUID
    var name: String
    var transport: any ELMTransport
    var selection: GATTSelection
    /// Every service and characteristic discovered.
    var table: [GATTServiceRecord]
}

/// What the BLE layer reports to `OBDLinkService`. Every case that the
/// service may record carries the uptime at which it happened, read in the
/// CoreBluetooth delegate callback.
enum BLECentralEvent: Sendable {
    case availability(BLEAvailability, uptime: Double)
    /// The system relaunched the app and handed back these peripherals
    /// (state restoration).
    case restored([UUID], uptime: Double)
    case discovered(DiscoveredAdapter)
    /// Connected; GATT discovery has started.
    case connected(UUID, uptime: Double)
    case connectFailed(UUID, reason: String?, uptime: Double)
    case ready(BLELinkReady, uptime: Double)
    /// Connected, but no usable UART pair (or notifications refused). The
    /// connection is being cancelled.
    case unusable(UUID, table: [GATTServiceRecord], reason: String, uptime: Double)
    case disconnected(UUID, reason: String?, uptime: Double)
    /// An acknowledged write failed (`didWriteValueFor` with an error).
    case writeFailed(UUID, reason: String, uptime: Double)
}

/// The BLE operations `OBDLinkService` needs. `BLECentral` implements it
/// over CoreBluetooth; `SimulatedBLECentral` over `MockELMAdapter`, and
/// tests over a scripted fake.
protocol BLECentralClient: AnyObject, Sendable {
    /// Single consumer.
    var events: AsyncStream<BLECentralEvent> { get }
    func startScan()
    func stopScan()
    /// Connects (or, after restoration, adopts an existing connection) and
    /// runs GATT discovery. A connection attempt doesn't time out: iOS keeps
    /// it pending until the adapter is in range, in the background too.
    func connect(_ id: UUID)
    /// Cancels an active or pending connection and closes its transport now.
    func cancelConnection(_ id: UUID)
}

/// CoreBluetooth central for the OBD adapter.
///
/// - One `CBCentralManager`, created at init with a restore identifier, on
///   a private serial queue: delegate callbacks (and the notification
///   timestamps taken in them) don't wait for the main thread.
/// - Scans for every advertiser (clones don't reliably advertise a service
///   UUID); the user picks; connects by `peripheral.identifier`.
/// - Discovers every service and characteristic, records the table, picks
///   the UART pair with `GATTDetection`, enables notifications, then hands a
///   `BLETransport` over in `.ready`.
/// - State restoration: peripherals handed back in `willRestoreState` are
///   retained and adopted by the next `connect` for that identifier,
///   whether still connected or pending.
/// - Every retained peripheral is dropped when Bluetooth goes resetting,
///   unknown, unauthorized or unsupported (`invalidatesPeripherals`); the
///   next `connect` retrieves the identifier again.
///
/// Threading: CoreBluetooth calls and delegate callbacks run on `queue`.
/// Mutable state is guarded by `lock` (docs/PLAN.md §4.0); CoreBluetooth is
/// never called with the lock held.
final class BLECentral: NSObject, BLECentralClient, Sendable {
    let events: AsyncStream<BLECentralEvent>

    private let continuation: AsyncStream<BLECentralEvent>.Continuation
    private let queue = DispatchQueue(label: "DriveLogger.BLECentral", qos: .userInitiated)
    private let uptime: any UptimeSource
    private let lock = NSLock()

    /// GATT discovery in progress for the target peripheral.
    private struct Discovery {
        var id: UUID
        var pendingServices: Int
        var choice: GATTChoice?
        var table: [GATTServiceRecord] = []
    }

    // Guarded by `lock`. Set once, at init or by the first callback.
    private nonisolated(unsafe) var manager: CBCentralManager?
    // Guarded by `lock`. Peripherals must be retained or CoreBluetooth
    // forgets them: everything discovered, retrieved or restored.
    private nonisolated(unsafe) var known: [UUID: CBPeripheral] = [:]
    // Guarded by `lock`. The peripheral the service wants connected.
    private nonisolated(unsafe) var target: UUID?
    // Guarded by `lock`.
    private nonisolated(unsafe) var wantsScan = false
    // Guarded by `lock`.
    private nonisolated(unsafe) var discovery: Discovery?
    // Guarded by `lock`. The transport of the connected target, if ready.
    private nonisolated(unsafe) var transport: (id: UUID, transport: BLETransport)?
    // Guarded by `lock`. Cancelled while connected: the disconnect callback
    // is still due, and a new connect waits for it.
    private nonisolated(unsafe) var awaitingDisconnect: Set<UUID> = []
    // Guarded by `lock`. A connect requested while `awaitingDisconnect`.
    private nonisolated(unsafe) var deferredConnect: UUID?

    /// - Parameter restoreIdentifier: enables CoreBluetooth state
    ///   restoration; requires the `bluetooth-central` background mode.
    init(restoreIdentifier: String?, uptime: any UptimeSource = SystemUptimeSource()) {
        self.uptime = uptime
        (events, continuation) = AsyncStream.makeStream(of: BLECentralEvent.self)
        super.init()
        var options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: true]
        if let restoreIdentifier { options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier }
        let manager = CBCentralManager(delegate: self, queue: queue, options: options)
        lock.withLock { if self.manager == nil { self.manager = manager } }
    }

    // MARK: BLECentralClient

    func startScan() {
        queue.async { self.scanIfPossible(start: true) }
    }

    func stopScan() {
        queue.async {
            let manager = self.lock.withLock { () -> CBCentralManager? in
                self.wantsScan = false
                return self.manager
            }
            if manager?.state == .poweredOn { manager?.stopScan() }
        }
    }

    func connect(_ id: UUID) {
        queue.async {
            let deferred = self.lock.withLock { () -> Bool in
                self.target = id
                guard self.awaitingDisconnect.contains(id) else { return false }
                self.deferredConnect = id
                return true
            }
            if deferred {
                // Don't let a late disconnect callback for the cancelled
                // connection look like the new one dropping; give up waiting
                // after 2 s.
                self.queue.asyncAfter(deadline: .now() + 2) { self.connectDeferred(id, force: true) }
            } else {
                self.connectNow(id)
            }
        }
    }

    func cancelConnection(_ id: UUID) {
        queue.async {
            let (manager, peripheral, closing) = self.lock.withLock { () -> (CBCentralManager?, CBPeripheral?, BLETransport?) in
                if self.target == id { self.target = nil }
                if self.deferredConnect == id { self.deferredConnect = nil }
                if self.discovery?.id == id { self.discovery = nil }
                var closing: BLETransport?
                if self.transport?.id == id {
                    closing = self.transport?.transport
                    self.transport = nil
                }
                let peripheral = self.known[id]
                if peripheral?.state == .connected { self.awaitingDisconnect.insert(id) }
                return (self.manager, peripheral, closing)
            }
            closing?.close(reason: "disconnect requested")
            if let peripheral, manager?.state == .poweredOn {
                manager?.cancelPeripheralConnection(peripheral)
            }
        }
    }

    // MARK: Private, on `queue`

    private func emit(_ event: BLECentralEvent) {
        continuation.yield(event)
    }

    private func scanIfPossible(start: Bool) {
        let (manager, wanted) = lock.withLock { () -> (CBCentralManager?, Bool) in
            if start { wantsScan = true }
            return (self.manager, wantsScan)
        }
        guard wanted, let manager, manager.state == .poweredOn else { return }
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func connectDeferred(_ id: UUID, force: Bool) {
        let go = lock.withLock { () -> Bool in
            guard deferredConnect == id else { return false }
            deferredConnect = nil
            if force { awaitingDisconnect.remove(id) }
            return true
        }
        if go { connectNow(id) }
    }

    private func connectNow(_ id: UUID) {
        let (manager, targetStill) = lock.withLock { (self.manager, self.target == id) }
        guard targetStill, let manager, manager.state == .poweredOn else { return }   // retried on poweredOn
        let peripheral = lock.withLock { known[id] } ?? manager.retrievePeripherals(withIdentifiers: [id]).first
        guard let peripheral else {
            emit(.connectFailed(id, reason: "not known to this phone; scan and pick it again", uptime: uptime.uptimeSeconds))
            return
        }
        lock.withLock { known[id] = peripheral }
        peripheral.delegate = self
        if peripheral.state == .connected {
            // Restored by the system, or connected by another app: adopt it.
            startDiscovery(peripheral)
        } else {
            manager.connect(peripheral, options: nil)
        }
    }

    private func startDiscovery(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        lock.withLock { discovery = Discovery(id: id, pendingServices: 0) }
        emit(.connected(id, uptime: uptime.uptimeSeconds))
        peripheral.discoverServices(nil)
    }

    private func isDiscovering(_ peripheral: CBPeripheral) -> Bool {
        lock.withLock { discovery?.id == peripheral.identifier && target == peripheral.identifier }
    }

    /// No usable pair: report and cancel the connection.
    private func giveUp(_ peripheral: CBPeripheral, table: [GATTServiceRecord], reason: String) {
        let id = peripheral.identifier
        let manager = lock.withLock { () -> CBCentralManager? in
            if discovery?.id == id { discovery = nil }
            awaitingDisconnect.insert(id)
            return self.manager
        }
        emit(.unusable(id, table: table, reason: reason, uptime: uptime.uptimeSeconds))
        manager?.cancelPeripheralConnection(peripheral)
    }

    private static func table(of peripheral: CBPeripheral) -> [GATTServiceRecord] {
        (peripheral.services ?? []).map { service in
            GATTServiceRecord(
                service: GATTDetection.normalise(service.uuid.uuidString),
                characteristics: (service.characteristics ?? []).map { characteristic in
                    GATTCharacteristicRecord(
                        uuid: GATTDetection.normalise(characteristic.uuid.uuidString),
                        properties: propertyNames(characteristic.properties)
                    )
                }
            )
        }
    }

    /// CoreBluetooth property names, as recorded in `gattTable`.
    static func propertyNames(_ properties: CBCharacteristicProperties) -> [String] {
        let names: [(CBCharacteristicProperties, String)] = [
            (.broadcast, "broadcast"),
            (.read, "read"),
            (.writeWithoutResponse, "writeWithoutResponse"),
            (.write, "write"),
            (.notify, "notify"),
            (.indicate, "indicate"),
            (.authenticatedSignedWrites, "authenticatedSignedWrites"),
            (.extendedProperties, "extendedProperties"),
            (.notifyEncryptionRequired, "notifyEncryptionRequired"),
            (.indicateEncryptionRequired, "indicateEncryptionRequired"),
        ]
        return names.filter { properties.contains($0.0) }.map(\.1)
    }

    private static func characteristic(_ uuid: String, service: String, in peripheral: CBPeripheral) -> CBCharacteristic? {
        peripheral.services?
            .first { GATTDetection.normalise($0.uuid.uuidString) == service }?
            .characteristics?
            .first { GATTDetection.normalise($0.uuid.uuidString) == uuid }
    }

    private func finishDiscovery(_ peripheral: CBPeripheral) {
        let table = Self.table(of: peripheral)
        guard let choice = GATTDetection.select(from: table) else {
            giveUp(peripheral, table: table, reason: "no notify + write characteristic pair in \(table.count) service(s)")
            return
        }
        guard let notify = Self.characteristic(choice.notify, service: choice.service, in: peripheral) else {
            giveUp(peripheral, table: table, reason: "characteristic \(choice.notify) vanished")
            return
        }
        lock.withLock {
            discovery?.choice = choice
            discovery?.table = table
        }
        peripheral.setNotifyValue(true, for: notify)
    }

    private func notificationsEnabled(_ peripheral: CBPeripheral, discovery: Discovery, choice: GATTChoice) {
        guard let write = Self.characteristic(choice.write, service: choice.service, in: peripheral) else {
            giveUp(peripheral, table: discovery.table, reason: "characteristic \(choice.write) vanished")
            return
        }
        let type: CBCharacteristicWriteType = choice.writeType == .withResponse ? .withResponse : .withoutResponse
        // Never more than one ATT packet per write, even acknowledged: a
        // longer acknowledged write becomes a prepared (long) write, which
        // cheap clones may not implement.
        let maxLength = min(
            peripheral.maximumWriteValueLength(for: type),
            peripheral.maximumWriteValueLength(for: .withoutResponse)
        )
        let selection = GATTSelection(
            service: choice.service,
            notify: choice.notify,
            write: choice.write,
            writeType: choice.writeType.rawValue,
            maxWriteLength: maxLength
        )
        let transport = BLETransport(
            peripheral: peripheral, characteristic: write, writeType: type, selection: selection, queue: queue, uptime: uptime
        )
        let id = peripheral.identifier
        let current = lock.withLock { () -> Bool in
            guard self.discovery?.id == id, target == id else { return false }
            self.discovery = nil
            self.transport = (id, transport)
            return true
        }
        guard current else {
            transport.close(reason: "superseded")
            return
        }
        let name = peripheral.name ?? ""
        emit(.ready(
            BLELinkReady(id: id, name: name, transport: transport, selection: selection, table: discovery.table),
            uptime: uptime.uptimeSeconds
        ))
    }

    /// Whether moving to `state` invalidates every `CBPeripheral` obtained
    /// from the manager. CoreBluetooth: once the state drops below
    /// `poweredOff` (resetting — bluetoothd restarted —, unknown,
    /// unauthorized, unsupported) peripherals "become invalid and must be
    /// retrieved or discovered again". `poweredOff` only disconnects them.
    /// Unknown future states are treated as invalidating: re-retrieving a
    /// peripheral costs nothing, a stale one can stall the drive.
    nonisolated static func invalidatesPeripherals(_ state: CBManagerState) -> Bool {
        switch state {
        case .poweredOn, .poweredOff: false
        case .resetting, .unknown, .unauthorized, .unsupported: true
        @unknown default: true
        }
    }

    private func closeTransport(for id: UUID?, reason: String) -> UUID? {
        let closing = lock.withLock { () -> (UUID, BLETransport)? in
            guard let current = transport, id == nil || current.id == id else { return nil }
            transport = nil
            return current
        }
        closing?.1.close(reason: reason)
        return closing?.0
    }
}

// MARK: - CBCentralManagerDelegate

extension BLECentral: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let now = uptime.uptimeSeconds
        lock.withLock { if manager == nil { manager = central } }
        let availability: BLEAvailability = switch central.state {
        case .poweredOn: .poweredOn
        case .poweredOff: .unavailable("Bluetooth is off")
        case .unauthorized: .unavailable("Bluetooth permission denied")
        case .unsupported: .unavailable("Bluetooth LE is not supported on this device")
        case .resetting: .unavailable("Bluetooth is resetting")
        case .unknown: .unavailable("Bluetooth state unknown")
        @unknown default: .unavailable("Bluetooth state \(central.state.rawValue)")
        }
        if case .unavailable(let reason) = availability {
            // Connections are gone without a didDisconnect callback.
            if let id = closeTransport(for: nil, reason: reason) {
                emit(.disconnected(id, reason: reason, uptime: now))
            }
            let stale = lock.withLock { () -> [CBPeripheral] in
                discovery = nil
                awaitingDisconnect.removeAll()
                deferredConnect = nil
                // Below poweredOff every peripheral of this manager is
                // invalid; a connect on one can hang for good. Forget them
                // so `connectNow` retrieves fresh objects (R3.1-2).
                guard Self.invalidatesPeripherals(central.state) else { return [] }
                defer { known.removeAll() }
                return Array(known.values)
            }
            for peripheral in stale { peripheral.delegate = nil }
        }
        emit(.availability(availability, uptime: now))
        guard availability == .poweredOn else { return }
        scanIfPossible(start: false)
        if let target = lock.withLock({ target }) { connectNow(target) }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let now = uptime.uptimeSeconds
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        lock.withLock {
            if manager == nil { manager = central }
            for peripheral in peripherals { known[peripheral.identifier] = peripheral }
        }
        for peripheral in peripherals { peripheral.delegate = self }
        emit(.restored(peripherals.map(\.identifier), uptime: now))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name = peripheral.name ?? advertised, !name.isEmpty else { return }
        lock.withLock { known[peripheral.identifier] = peripheral }
        emit(.discovered(DiscoveredAdapter(id: peripheral.identifier, name: name, rssi: RSSI.intValue)))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let wanted = lock.withLock { target == peripheral.identifier }
        guard wanted else {
            // A connect that outlived its request.
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.delegate = self
        startDiscovery(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        let now = uptime.uptimeSeconds
        emit(.connectFailed(peripheral.identifier, reason: error?.localizedDescription, uptime: now))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        let now = uptime.uptimeSeconds
        let id = peripheral.identifier
        let reason = error?.localizedDescription
        _ = closeTransport(for: id, reason: reason ?? "disconnected")
        lock.withLock {
            if discovery?.id == id { discovery = nil }
            awaitingDisconnect.remove(id)
        }
        emit(.disconnected(id, reason: reason, uptime: now))
        connectDeferred(id, force: false)
    }
}

// MARK: - CBPeripheralDelegate

extension BLECentral: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard isDiscovering(peripheral) else { return }
        if let error {
            giveUp(peripheral, table: Self.table(of: peripheral), reason: "service discovery failed: \(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            giveUp(peripheral, table: [], reason: "no GATT services")
            return
        }
        lock.withLock { discovery?.pendingServices = services.count }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard isDiscovering(peripheral) else { return }
        // A service whose characteristics failed to load is simply absent
        // from the choice; its entry in the table shows no characteristics.
        let remaining = lock.withLock { () -> Int in
            discovery?.pendingServices -= 1
            return discovery?.pendingServices ?? -1
        }
        if remaining == 0 { finishDiscovery(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard isDiscovering(peripheral), let current = lock.withLock({ discovery }), let choice = current.choice,
              GATTDetection.normalise(characteristic.uuid.uuidString) == choice.notify else { return }
        guard error == nil, characteristic.isNotifying else {
            let detail = error?.localizedDescription ?? "not notifying"
            giveUp(peripheral, table: current.table, reason: "notifications on \(choice.notify) refused: \(detail)")
            return
        }
        notificationsEnabled(peripheral, discovery: current, choice: choice)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        // The OBD reply timestamp: first thing, before anything else runs.
        let now = uptime.uptimeSeconds
        guard error == nil, let value = characteristic.value, !value.isEmpty else { return }
        let current = lock.withLock { () -> BLETransport? in
            guard let transport, transport.id == peripheral.identifier else { return nil }
            return transport.transport
        }
        guard let current, GATTDetection.normalise(characteristic.uuid.uuidString) == current.selection.notify else { return }
        current.receive(value, uptime: now)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard let error else { return }
        emit(.writeFailed(peripheral.identifier, reason: error.localizedDescription, uptime: uptime.uptimeSeconds))
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        let current = lock.withLock { transport?.id == peripheral.identifier ? transport?.transport : nil }
        current?.readyToSend()
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        let current = lock.withLock { transport?.id == peripheral.identifier ? transport?.transport : nil }
        guard let current else { return }
        let invalidated = invalidatedServices.map { GATTDetection.normalise($0.uuid.uuidString) }
        guard invalidated.contains(current.selection.service) else { return }
        // The UART service went away under us: drop the link; the service
        // reconnects and rediscovers.
        let manager = lock.withLock { () -> CBCentralManager? in
            awaitingDisconnect.insert(peripheral.identifier)
            return self.manager
        }
        _ = closeTransport(for: peripheral.identifier, reason: "GATT service \(current.selection.service) invalidated")
        manager?.cancelPeripheralConnection(peripheral)
    }
}
