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

/// The reasons the link services give for `OBDLinkState.failed(reason:)`
/// (and the `Bluetooth state <n>` fallback of `.unavailable`), typed.
///
/// `text` is what the services write: the state's string, the `ble` link
/// rows and the console lines. It is on-disk English: never reword it (the
/// tests pin every form). `display` is the same reason in the app's
/// language, for the screen only. The state keeps carrying the English
/// string, so the screens read it back with `init?(text:)` (through
/// `LinkReasonText.display`); a reason that is not one of these (an
/// `ELMSession` failure from Core, an iOS error text) is shown as written.
enum LinkReason: Hashable, Sendable {
    /// GATT discovery found no notify + write pair (`GATTDetection.select`).
    case noUARTPair(services: Int)
    /// The chosen characteristic (normalised UUID) was gone when needed.
    case characteristicVanished(String)
    /// `didDiscoverServices` with an error (its `localizedDescription`).
    case serviceDiscoveryFailed(String)
    case noServices
    /// Notifications on the chosen characteristic did not turn on: the
    /// error's `localizedDescription`, nil when there was no error but the
    /// characteristic is not notifying.
    case notificationsRefused(characteristic: String, error: String?)
    /// The ELM session failed without a reason of its own.
    case sessionFailed
    /// A `CBManagerState` raw value newer than this build knows.
    case bluetoothState(Int)

    var text: String {
        switch self {
        case .noUARTPair(let services): "no notify + write characteristic pair in \(services) service(s)"
        case .characteristicVanished(let uuid): "characteristic \(uuid) vanished"
        case .serviceDiscoveryFailed(let error): "service discovery failed: \(error)"
        case .noServices: "no GATT services"
        case .notificationsRefused(let uuid, let error): "notifications on \(uuid) refused: \(error ?? Self.notNotifying)"
        case .sessionFailed: "ELM session failed"
        case .bluetoothState(let raw): "Bluetooth state \(raw)"
        }
    }

    var display: String {
        switch self {
        case .noUARTPair(let services):
            String(localized: "no notify + write characteristic pair (services: \(services))",
                   comment: "Adapter failed: the adapter's Bluetooth layout has no usable notify + write pair")
        case .characteristicVanished(let uuid):
            String(localized: "characteristic \(uuid) vanished",
                   comment: "Adapter failed: a Bluetooth characteristic (UUID) disappeared")
        case .serviceDiscoveryFailed(let error):
            String(localized: "service discovery failed: \(error)",
                   comment: "Adapter failed: Bluetooth service discovery failed; %@ is the iOS error text")
        case .noServices:
            String(localized: "no GATT services", comment: "Adapter failed: the adapter offers no Bluetooth services")
        case .notificationsRefused(let uuid, let error):
            notificationsRefused(uuid, error ?? String(localized: "not notifying", comment: "Adapter failed: notifications did not turn on, no error given"))
        case .sessionFailed:
            String(localized: "ELM session failed", comment: "Adapter failed: the ELM327 session failed without a reason")
        case .bluetoothState(let raw):
            String(localized: "Bluetooth state \(raw)", comment: "Bluetooth unavailable: a Bluetooth state this build does not know; %lld is its number")
        }
    }

    /// Reads a `text` back; nil for any other string.
    init?(text: String) {
        if text == Self.noServicesText { self = .noServices; return }
        if text == Self.sessionFailedText { self = .sessionFailed; return }
        if let middle = Self.between(text, "no notify + write characteristic pair in ", " service(s)"),
           let services = Int(middle), String(services) == middle {
            self = .noUARTPair(services: services); return
        }
        if let uuid = Self.between(text, "characteristic ", " vanished"), Self.isUUID(uuid) {
            self = .characteristicVanished(uuid); return
        }
        if text.hasPrefix("service discovery failed: ") {
            self = .serviceDiscoveryFailed(String(text.dropFirst("service discovery failed: ".count))); return
        }
        if text.hasPrefix("notifications on "), let refused = text.range(of: " refused: ") {
            let uuid = String(text[text.index(text.startIndex, offsetBy: "notifications on ".count)..<refused.lowerBound])
            let error = String(text[refused.upperBound...])
            guard Self.isUUID(uuid) else { return nil }
            self = .notificationsRefused(characteristic: uuid, error: error == Self.notNotifying ? nil : error); return
        }
        if let middle = Self.between(text, "Bluetooth state ", ""), let raw = Int(middle), String(raw) == middle {
            self = .bluetoothState(raw); return
        }
        return nil
    }

    private func notificationsRefused(_ uuid: String, _ detail: String) -> String {
        String(localized: "notifications on \(uuid) refused: \(detail)",
               comment: "Adapter failed: the adapter refused notifications; %1$@ characteristic UUID, %2$@ iOS error text or 'not notifying'")
    }

    private static let notNotifying = "not notifying"
    private static let noServicesText = LinkReason.noServices.text
    private static let sessionFailedText = LinkReason.sessionFailed.text

    /// The text strictly between `prefix` and `suffix`, nil if empty or absent.
    private static func between(_ text: String, _ prefix: String, _ suffix: String) -> String? {
        guard text.hasPrefix(prefix), text.hasSuffix(suffix), text.count > prefix.count + suffix.count else { return nil }
        return String(text.dropFirst(prefix.count).dropLast(suffix.count))
    }

    /// A normalised characteristic UUID: hex digits and dashes only.
    private static func isUUID(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { $0 == "-" || ("0"..."9").contains($0) || ("A"..."F").contains($0) }
    }
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
    /// The remembered adapter's advertised name (UX-34: Settings shows it
    /// while nothing is connected). Kept with `rememberedAdapterID`, nil
    /// when the name was never seen; cleared by `forget()`.
    var rememberedAdapterName: String? { get }
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

    /// The current connection's initialisation, for the recorder to write at
    /// Start: the link usually connects and initialises before the user taps
    /// Start, and those events have already gone by on `linkEvents()` (M4
    /// bench, docs/BENCH_TEST_2026-10-08.md).
    ///
    /// **Only while connected (M6.1-1, user decision).** Empty whenever BLE
    /// isn't `connected`: disconnected, reconnecting, idle after
    /// `disconnect()`/`forget()`, unavailable, or a connection attempt in
    /// progress (`connecting`, `discovering`, `restoring`). A connection that
    /// has dropped is never replayed: its rows would end at `polling`, and
    /// the live rows after Start (`reconnecting → connecting` …) would not
    /// follow from them. A recording started then gets no replay; the
    /// connection that comes up later is written live.
    ///
    /// **Contents.** `LinkEvent`s exactly as delivered on `linkEvents()`,
    /// unchanged — same values, same original uptimes, same `seq` — in
    /// delivery order, in three parts:
    /// 1. **Connection:** the BLE transition into `connected` that started
    ///    the current connection (its reason names the GATT selection). The
    ///    `connecting` and `discovering` transitions before it are not kept.
    /// 2. **Init:** the latest initialisation on that connection, from its
    ///    first ELM event up to and including the ELM transition into
    ///    `polling` (or into `failed`): every `.exchange` (phases `init` and
    ///    `probe`: `ATZ` … `ATRV`, `ATSH7E0`, selection and the
    ///    `ATAT1`/`ATAT2` comparison, or the remembered plan's `ATATn` and
    ///    check poll), every `.state` transition and note, and the
    ///    `.adapter` event. For the first init after connecting it starts
    ///    with the session's first event (`idle → resetting`, or output the
    ///    adapter had buffered); for a re-init with `→ resetting`
    ///    (`reinitialise()`) or `→ reinitialising` (the session's own
    ///    retry → re-init path), and its handshake has no probe.
    /// 3. **After the init** (M7.1-5): the latest `.adapter` event and the
    ///    latest ELM transition (`from != to`) delivered after the init
    ///    ended, at most one of each, in arrival order — e.g. the `.adapter`
    ///    re-announced when a PID was dropped on NO DATA, or `polling →
    ///    retrying`. So the last `adapter` row replayed is the plan polled
    ///    at Start, which is what `adapter`/`plan` (the header) say. Notes,
    ///    exchanges and readings after the init are not kept.
    ///
    /// `.pollRate` and `.needsReconnect` are never kept: they produce no
    /// rows. Poll traffic after the transition into `polling` is not kept
    /// (part 3 aside).
    /// Writing these events through `LogEvent.rows(for:adapter:clock:)`
    /// with `adapter: self.adapter` gives exactly the rows a recording
    /// running at the time would have written (the `adapter` row merges
    /// ELM facts from the event itself, so it matches): no new kinds, no new
    /// strings. Stamped with `clock.timestamp(uptimeSeconds:)` from their own
    /// uptimes, which is what the mapping does, they get negative `t` when
    /// they precede Start. That is legal and must not be clamped.
    ///
    /// **Lifetime.** Starts again at every BLE transition into `connected`
    /// and is emptied when BLE leaves `connected`. A new init on the same
    /// connection (`reinitialise()`, or the session's own `reinitialising`)
    /// replaces the init part and keeps the `connected` event. Nothing from
    /// a previous connection's session delivered after that is kept.
    /// Bounded (`OBDLinkService.defaultInitEventLimit`, 1 000; a full init
    /// with selection fallbacks is ~100–200 events): beyond that the oldest
    /// are dropped, so the end of the init (the `adapter` event) is always
    /// kept.
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
    /// The same steps apply when the replay is empty (the link is down at
    /// Start): nothing is replayed, and the skip still keeps every event
    /// delivered before Start out of the file.
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

/// A link the demo drive (REL-DEMO) can take down and hold down while it
/// runs, so a real adapter reconnecting or autoconnecting cannot take over
/// the session, and bring back afterwards. `OBDLinkService` (and so
/// `SimulatedOBDLink`) implements it.
@MainActor
protocol OBDLinkHolding: AnyObject {
    /// Held: nothing connects until `releaseDemoHold()`.
    var isHeldForDemo: Bool { get }
    func holdForDemo()
    func releaseDemoHold()
}
