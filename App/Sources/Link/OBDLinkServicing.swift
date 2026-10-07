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

    /// Clears `discovered` and scans for advertising adapters (every named
    /// peripheral, likely OBD adapters first). Needs Bluetooth on.
    func startScan()
    func stopScan()
    /// Connects, initialises and starts polling; remembers the adapter by
    /// identifier (`rememberedAdapterID`). After a link loss or an ELM
    /// session's `needsReconnect` it reconnects by itself, with backoff,
    /// until `disconnect()` or `forget()`.
    func connect(to id: UUID)
    /// Drops the link and stops reconnecting. The adapter stays remembered.
    func disconnect()
    /// Forgets the remembered adapter and disconnects.
    func forget()
    /// Debug console. Validated with `ELMCommandPolicy` scope **`.manual`**
    /// — the read-only queries `ATI`, `AT@1`, `ATDP`, `ATDPN`, `ATRV` and
    /// mode 01 — never `.session`: the settings the session relies on
    /// (echo, headers, protocol, addressing, timing) can't be changed from
    /// the console. A rejected command is recorded as a `rejected` exchange
    /// and throws `.forbiddenCommand`; nothing reaches the adapter. While
    /// polling, the command is queued between polls (one command in
    /// flight).
    ///
    /// Throws `.desynchronised` without sending when a written-off prompt
    /// has left replies unmatchable; the link then re-initialises (by
    /// itself while polling; otherwise the service starts `reinitialise()`)
    /// and the command can be retried once it is polling again. Throws
    /// `.notInitialised` when no adapter is connected.
    func sendManual(_ command: String) async throws(ELMSessionError) -> ELMExchange
    /// Re-runs the ELM init sequence on the current connection (from `ATZ`)
    /// and resumes polling; the console offers it after `.desynchronised`.
    /// If init fails the link reconnects with backoff. Does nothing without
    /// a connection.
    func reinitialise() async
    /// BLE transitions and ELM session events for the recorder, in order,
    /// across reconnects (each new `ELMSession` is seeded with the previous
    /// one's `nextSeq`). One subscriber at a time; a new call finishes the
    /// previous stream.
    func linkEvents() -> AsyncStream<LinkEvent>
}
