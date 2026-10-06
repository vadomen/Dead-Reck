import DriveLoggerCore
import Foundation
import Observation

/// An adapter seen during a scan.
struct DiscoveredAdapter: Identifiable, Hashable, Sendable {
    /// `CBPeripheral.identifier`.
    let id: UUID
    let name: String
    let rssi: Int
}

/// Link status as the UI shows it.
enum OBDLinkState: Hashable, Sendable {
    /// Bluetooth off, unauthorised, or not present (the simulator).
    case unavailable(reason: String)
    case idle
    case scanning
    case connecting
    case discoveringServices
    case initialising
    /// Initialised, not polling.
    case ready
    case polling(protocolNumber: String, voltage: Double?)
    case reconnecting(attempt: Int)
    case failed(reason: String)
}

/// One line in the debug console.
struct ConsoleLine: Identifiable, Hashable, Sendable {
    enum Direction: Hashable, Sendable {
        case tx
        case rx
        /// State changes, timeouts, rejections.
        case status
    }

    let id: Int
    let direction: Direction
    let text: String
    /// Seconds since boot.
    let uptime: Double
}

/// The OBD link as the rest of the app sees it: scan, pick, remember,
/// connect, initialise, poll, and expose the ELM session's events.
///
/// `OBDLinkService` implements it over CoreBluetooth; `SimulatedOBDLink` over
/// `MockELMAdapter`, chosen automatically on the simulator.
@MainActor
protocol OBDLinkServicing: AnyObject, Observable {
    var state: OBDLinkState { get }
    var discovered: [DiscoveredAdapter] { get }
    /// Adapter remembered from a previous session, reconnected automatically.
    var rememberedAdapterID: UUID? { get }
    /// What the BLE layer and the last successful init know about the adapter
    /// — name, identifier, GATT selection and table, ELM version, protocol,
    /// voltage. Nil until initialised. Goes into the log header.
    var adapter: AdapterRecord? { get }
    /// Polling combination chosen by the last init.
    var plan: PollingPlan? { get }
    /// Successful polls per second, last window.
    var pollHz: Double { get }
    /// Most recent console lines, bounded.
    var console: [ConsoleLine] { get }

    func startScan()
    func stopScan()
    /// Connects, initialises and starts polling; remembers the adapter.
    func connect(to id: UUID)
    func disconnect()
    /// Forgets the remembered adapter and disconnects.
    func forget()
    /// Debug console. Rejected unless `ELMCommandPolicy` allows it.
    func sendManual(_ command: String) async throws(ELMSessionError) -> ELMExchange
    /// Every ELM session event for the recorder, across reconnects. One
    /// subscriber at a time; a new call finishes the previous stream.
    func sessionEvents() -> AsyncStream<ELMSessionEvent>
}
