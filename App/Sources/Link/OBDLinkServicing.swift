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
    /// a connection. While an initialisation is already running on this
    /// connection (the one after connecting, or an earlier
    /// `reinitialise()`), it starts no second one: it waits for that run
    /// and returns when it has ended (polling, or the failure handled), so
    /// pressing it repeatedly is harmless.
    func reinitialise() async
    /// BLE transitions and ELM session events for the recorder, in order,
    /// across reconnects (each new `ELMSession` is seeded with the previous
    /// one's `nextSeq`). One subscriber at a time; a new call finishes the
    /// previous stream.
    func linkEvents() -> AsyncStream<LinkEvent>

    /// The latest connection's initialisation, for the recorder to write at
    /// Start: the link usually connects and initialises before the user taps
    /// Start, and those events have already gone by on `linkEvents()` (M4
    /// bench, docs/BENCH_TEST_2026-10-08.md).
    ///
    /// **Contents.** `LinkEvent`s exactly as delivered on `linkEvents()`,
    /// unchanged — same values, same original uptimes, same `seq` — in
    /// delivery order, in two parts:
    /// 1. **Connection:** the BLE transitions of the current connection
    ///    attempt, from the one into `connecting` (or `restoring`) up to and
    ///    including the one into `connected` (its reason names the GATT
    ///    selection) — or, for an attempt that failed, the one that ended
    ///    it.
    /// 2. **Init:** the latest initialisation on that connection, from its
    ///    first ELM event up to and including the ELM transition into
    ///    `polling` (or into `failed`): every `.exchange` (phases `init` and
    ///    `probe`: `ATZ` … `ATRV`, `ATSH7E0`, selection, the `ATAT1`/`ATAT2`
    ///    comparison), every `.state` transition and note, and the
    ///    `.adapter` event. For the first init after connecting it starts
    ///    with the session's first event (`idle → resetting`, or output the
    ///    adapter had buffered); for a re-init with `→ resetting`
    ///    (`reinitialise()`) or `→ reinitialising` (the session's own
    ///    retry → re-init path), and its handshake has no probe.
    ///
    /// `.pollRate` and `.needsReconnect` are never kept: they produce no
    /// rows. Poll traffic after the transition into `polling` is not kept.
    /// Writing these events through `LogEvent.rows(for:adapter:clock:)`
    /// with `adapter: self.adapter` gives exactly the rows a recording
    /// running at the time would have written (the `adapter` row merges
    /// ELM facts from the event itself, so it matches): no new kinds, no new
    /// strings. Stamped with `clock.timestamp(uptimeSeconds:)` from their own
    /// uptimes, which is what the mapping does, they get negative `t` when
    /// they precede Start. That is legal and must not be clamped.
    ///
    /// **Lifetime.** Reset when a new connection attempt starts (BLE `→
    /// connecting`, `→ restoring`): both parts start again. A new init on
    /// the same connection (`reinitialise()`, or the session's own
    /// `reinitialising`) replaces the init part and keeps the connection
    /// part. A connection that drops keeps its events until the next
    /// attempt starts; an init cut short by the drop still gets its own
    /// session's last events (`→ failed`, the abandoned command's row). The
    /// BLE transitions after `connected` are not kept, and neither is
    /// anything from a previous connection's session delivered after the
    /// reset. Bounded (`OBDLinkService.defaultInitEventLimit`, 1 000; a full
    /// init with selection fallbacks is ~100–200 events): beyond that the
    /// oldest are dropped, so the end of the init (the `adapter` event) is
    /// always kept.
    ///
    /// **Dedup contract for the recorder** ("replay only at Start; live
    /// events after that"). Every event here has already been delivered on
    /// `linkEvents()`, and may still sit unconsumed in the recorder's stream
    /// buffer. At Start, in one synchronous main-actor step (no `await`
    /// between them):
    /// 1. read `lastInitEvents` and `deliveredLinkEventCount`;
    /// 2. write the replay rows, in this order, before any live row;
    /// 3. let `skip = deliveredLinkEventCount − consumed`, where `consumed`
    ///    is how many events the recorder's `linkEvents()` loop has handled
    ///    so far; the next `skip` events that loop handles were delivered
    ///    before Start — each is either in the replay or (poll traffic
    ///    before Start) not part of the recording — so it writes none of
    ///    them, and writes every event after them.
    ///
    /// No event is then written twice, none delivered after Start is lost,
    /// and an init still running at Start is complete: its first part from
    /// the replay, the rest live. `seq` stays unique and increasing in write
    /// order: the replay's exchanges were all emitted before Start, every
    /// live exchange after it, and each new session continues from its
    /// predecessor's `nextSeq`. Never replay again while the
    /// same recording runs: an init that happens during a recording reaches
    /// the recorder live.
    var lastInitEvents: [LinkEvent] { get }

    /// How many events have been delivered on the current `linkEvents()`
    /// stream since it was created (reset to 0 by each `linkEvents()`
    /// call). For the dedup step in `lastInitEvents`.
    var deliveredLinkEventCount: Int { get }
}
