import DriveLoggerCore
import Foundation
import Observation

/// Delay before reconnect attempt `n` (1-based): `initial × 2^(n−1)`, capped
/// at `maximum`. Reset after a successful initialisation.
struct ReconnectBackoff: Hashable, Sendable {
    var initial: Duration
    var maximum: Duration

    init(initial: Duration = .seconds(1), maximum: Duration = .seconds(30)) {
        self.initial = initial
        self.maximum = maximum
    }

    static let `default` = ReconnectBackoff()

    func delay(forAttempt attempt: Int) -> Duration {
        let exponent = min(max(attempt, 1) - 1, 16)
        return min(initial * (1 << exponent), maximum)
    }
}

/// `OBDLinkServicing` over a `BLECentralClient`: CoreBluetooth on the
/// device (`BLECentral`), `MockELMAdapter` behind `SimulatedOBDLink`.
///
/// ## BLE link state machine
///
/// Recorded as `LinkEvent.ble` with the frozen `LinkSample.BLEState` names,
/// stamped with the uptime the BLE layer read in its delegate callback:
///
/// ```
/// unavailable ⇄ idle                         (Bluetooth off/on)
/// idle → scanning → idle                     (startScan / stopScan)
/// idle|scanning|restoring → connecting       (connect, remembered adapter at launch)
/// connecting → discovering → connected       (didConnect, UART pair + notifications)
/// connected|discovering|connecting → disconnected
///     (link lost, connect failed, or the ELM session asked for a reconnect)
/// disconnected → reconnecting → connecting   (after the backoff delay)
/// idle → restoring                           (relaunched by the system with our adapter)
/// any → idle                                 (disconnect / forget, or an unusable GATT layout)
/// ```
///
/// ## Sessions and reconnects
///
/// - One `ELMSession` per connection, created when the transport is ready
///   and seeded with the previous session's `nextSeq`, read after that
///   session has shut down and its last event has been forwarded — so
///   `seq` is unique and increasing for the whole recording.
/// - Reconnect with backoff (`ReconnectBackoff`, 1 s doubling to 30 s) on a
///   link loss, a failed connect, a failed initialisation, and on the
///   session's `needsReconnect`. The attempt counter resets once an
///   initialisation succeeds. The connect itself never times out: iOS
///   keeps it pending until the adapter is back (unplugged and replugged),
///   in the background too.
/// - Every session event and BLE transition goes to the `linkEvents()`
///   subscriber, in the order this service handles them, and to the console.
@MainActor
@Observable
class OBDLinkService: OBDLinkServicing {
    static let restoreIdentifier = "DriveLogger.OBDLink"
    static let rememberedAdapterKey = "OBDLink.rememberedAdapterID"
    static let consoleLimit = 500

    private(set) var state: OBDLinkState = .idle
    private(set) var discovered: [DiscoveredAdapter] = []
    private(set) var rememberedAdapterID: UUID?
    private(set) var adapter: AdapterRecord?
    private(set) var plan: PollingPlan?
    private(set) var pollHz: Double = 0
    private(set) var console: [ConsoleLine] = []
    /// The BLE layer's state, as written in `link` rows.
    private(set) var bleState: LinkSample.BLEState = .idle

    @ObservationIgnored private let central: any BLECentralClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let uptime: any UptimeSource
    @ObservationIgnored private let sessionConfiguration: ELMSessionConfiguration
    @ObservationIgnored private let backoff: ReconnectBackoff
    @ObservationIgnored private var centralTask: Task<Void, Never>?
    @ObservationIgnored private var subscriber: AsyncStream<LinkEvent>.Continuation?
    /// The adapter the user wants connected; nil after `disconnect()`.
    @ObservationIgnored private var target: UUID?
    @ObservationIgnored private var available = false
    @ObservationIgnored private var wantsScan = false
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    /// Changes whenever a connection's transport is handed over or dropped;
    /// events and init results of an older connection don't touch the UI
    /// state any more (they are still forwarded and logged).
    @ObservationIgnored private var linkToken = 0
    @ObservationIgnored private var session: ELMSession?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var retiring: Task<Void, Never>?
    @ObservationIgnored private var nextSeq = 0
    /// What the BLE layer knows about the connected adapter.
    @ObservationIgnored private var bleRecord: AdapterRecord?
    @ObservationIgnored private var lastInfo: ELMAdapterInfo?
    @ObservationIgnored private var nextConsoleID = 0

    /// - Parameters:
    ///   - central: nil creates the CoreBluetooth `BLECentral` with
    ///     `restoreIdentifier` — create the service at launch so state
    ///     restoration finds it.
    ///   - defaults: where `rememberedAdapterID` is kept.
    ///   - uptime: stamps the service's own transitions and the sessions;
    ///     the same timebase as the transport.
    init(
        central: (any BLECentralClient)? = nil,
        defaults: UserDefaults = .standard,
        uptime: any UptimeSource = SystemUptimeSource(),
        sessionConfiguration: ELMSessionConfiguration = .default,
        backoff: ReconnectBackoff = .default
    ) {
        self.central = central ?? BLECentral(restoreIdentifier: Self.restoreIdentifier, uptime: uptime)
        self.defaults = defaults
        self.uptime = uptime
        self.sessionConfiguration = sessionConfiguration
        self.backoff = backoff
        rememberedAdapterID = defaults.string(forKey: Self.rememberedAdapterKey).flatMap(UUID.init(uuidString:))
        // Reconnected automatically once Bluetooth is on.
        target = rememberedAdapterID
        let events = self.central.events
        centralTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    // MARK: OBDLinkServicing

    func startScan() {
        wantsScan = true
        discovered = []
        guard available else { return }
        central.startScan()
        if bleState == .idle {
            transition(to: .scanning, reason: nil)
            state = .scanning
        }
    }

    func stopScan() {
        wantsScan = false
        central.stopScan()
        if bleState == .scanning {
            transition(to: .idle, reason: nil)
            state = .idle
        }
    }

    func connect(to id: UUID) {
        stopScan()
        if let target, target != id { disconnect() }
        remember(id)
        let busy: Set<LinkSample.BLEState> = [.connecting, .discovering, .connected, .reconnecting, .restoring]
        if target == id, busy.contains(bleState) { return }
        target = id
        attempt = 0
        guard available else { return }   // connects on poweredOn
        connectNow(id, reason: "adapter \(name(of: id)) picked")
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        attempt = 0
        let id = target
        target = nil
        dropLink()
        if let id { central.cancelConnection(id) }
        if bleState != .unavailable {
            transition(to: .idle, reason: "disconnected by the user")
            state = .idle
        }
    }

    func forget() {
        disconnect()
        rememberedAdapterID = nil
        defaults.removeObject(forKey: Self.rememberedAdapterKey)
    }

    func sendManual(_ command: String) async throws(ELMSessionError) -> ELMExchange {
        guard let session else {
            // Same answer as the session would give for a forbidden command,
            // even with nothing connected.
            _ = try ELMCommandPolicy.validate(command, scope: .manual)
            throw .notInitialised
        }
        let token = linkToken
        do throws(ELMSessionError) {
            return try await session.sendManual(command)
        } catch {
            if case .desynchronised = error, token == linkToken {
                let polling = if case .polling = state { true } else { false }
                appendConsole(
                    .status,
                    "link desynchronised (a reply went missing): "
                        + (polling ? "re-initialising by itself" : "re-initialising") + "; retry when polling",
                    uptime.uptimeSeconds
                )
                // While polling the session re-initialises by itself.
                if !polling { Task { await self.reinitialise() } }
            }
            throw error
        }
    }

    func reinitialise() async {
        guard let session, bleState == .connected else { return }
        await initialiseAndPoll(session, token: linkToken)
    }

    func linkEvents() -> AsyncStream<LinkEvent> {
        subscriber?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
        subscriber = continuation
        return stream
    }

    // MARK: BLE events

    private func handle(_ event: BLECentralEvent) {
        switch event {
        case .availability(let availability, let at):
            handleAvailability(availability, at: at)
        case .restored(let ids, let at):
            guard let target, ids.contains(target), bleState == .idle || bleState == .unavailable else { return }
            transition(to: .restoring, reason: "relaunched by the system with the adapter", uptime: at)
        case .discovered(let found):
            discovered.removeAll { $0.id == found.id }
            discovered.append(found)
            discovered.sort(by: Self.listOrder)
        case .connected(let id, let at):
            guard id == target, [.connecting, .restoring].contains(bleState) else { return }
            transition(to: .discovering, reason: nil, uptime: at)
            state = .discoveringServices
        case .connectFailed(let id, let reason, let at):
            guard id == target, bleState == .connecting else { return }
            transition(to: .disconnected, reason: reason ?? "connect failed", uptime: at)
            scheduleReconnect()
        case .ready(let link, let at):
            guard link.id == target, [.connecting, .discovering, .restoring].contains(bleState) else {
                central.cancelConnection(link.id)
                return
            }
            let gatt = link.selection
            transition(
                to: .connected,
                reason: "\(gatt.service) notify \(gatt.notify) write \(gatt.write) \(gatt.writeType), \(gatt.maxWriteLength) B",
                uptime: at
            )
            bleRecord = AdapterRecord(
                name: link.name, identifier: link.id.uuidString, gatt: link.selection, gattTable: link.table
            )
            startSession(on: link.transport)
        case .unusable(let id, _, let reason, let at):
            guard id == target else { return }
            // Not retried: the adapter's GATT layout doesn't change between
            // attempts. The table is in the console line.
            transition(to: .disconnected, reason: reason, uptime: at)
            target = nil
            dropLink()
            central.cancelConnection(id)
            transition(to: .idle, reason: "no usable UART characteristics; pick another adapter")
            state = .failed(reason: reason)
        case .disconnected(let id, let reason, let at):
            guard id == target, [.connecting, .discovering, .connected, .restoring].contains(bleState) else { return }
            transition(to: .disconnected, reason: reason ?? "link lost", uptime: at)
            dropLink()
            scheduleReconnect()
        case .writeFailed(_, let reason, let at):
            appendConsole(.status, "ble: write failed: \(reason)", at)
        }
    }

    private func handleAvailability(_ availability: BLEAvailability, at: Double) {
        switch availability {
        case .poweredOn:
            available = true
            if bleState == .unavailable {
                transition(to: .idle, reason: "Bluetooth on", uptime: at)
                state = .idle
            }
            if wantsScan, bleState == .idle {
                central.startScan()
                transition(to: .scanning, reason: nil, uptime: at)
                state = .scanning
            }
            if let target, [.idle, .scanning, .restoring].contains(bleState) {
                connectNow(target, reason: bleState == .restoring ? "restoring" : "remembered adapter")
            }
        case .unavailable(let reason):
            available = false
            reconnectTask?.cancel()
            reconnectTask = nil
            dropLink()
            transition(to: .unavailable, reason: reason, uptime: at)
            state = .unavailable(reason: reason)
        }
    }

    private func connectNow(_ id: UUID, reason: String?) {
        transition(to: .connecting, reason: reason)
        state = attempt > 0 ? .reconnecting(attempt: attempt) : .connecting
        central.connect(id)
    }

    private func scheduleReconnect() {
        guard let target else {
            transition(to: .idle, reason: nil)
            state = .idle
            return
        }
        attempt += 1
        let attempt = attempt
        let delay = backoff.delay(forAttempt: attempt)
        transition(to: .reconnecting, reason: "attempt \(attempt) in \(delay)")
        state = .reconnecting(attempt: attempt)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.target == target, self.bleState == .reconnecting, self.available else {
                return
            }
            self.connectNow(target, reason: "reconnect attempt \(attempt)")
        }
    }

    /// The ELM side asked for a fresh connection (`needsReconnect`, or
    /// initialisation failed): drop the BLE link and reconnect with backoff.
    private func requestReconnect(reason: String) {
        guard let target, bleState == .connected else { return }
        transition(to: .disconnected, reason: reason)
        dropLink()
        central.cancelConnection(target)
        scheduleReconnect()
    }

    // MARK: ELM sessions

    private func startSession(on transport: any ELMTransport) {
        linkToken += 1
        let token = linkToken
        state = .initialising
        Task {
            // The previous connection's session must be gone, and its last
            // `seq` known, before this one numbers anything.
            await retireSession()
            guard token == linkToken else { return }
            let session = ELMSession(
                transport: transport,
                configuration: sessionConfiguration,
                uptime: uptime,
                firstSeq: nextSeq
            )
            self.session = session
            let events = session.events
            // Ends when the session's events finish (shutdown or link loss).
            sessionTask = Task {
                for await event in events {
                    self.handleSession(event, token: token)
                }
            }
            await initialiseAndPoll(session, token: token)
        }
    }

    private func initialiseAndPoll(_ session: ELMSession, token: Int) async {
        do throws(ELMSessionError) {
            let info = try await session.initialise()
            guard token == linkToken else { return }
            attempt = 0
            try await session.startPolling(info.plan)
        } catch {
            guard token == linkToken else { return }
            switch error {
            case .transport, .cancelled:
                // Link loss: the BLE layer reports it and reconnects.
                return
            default:
                appendConsole(.status, "init failed: \(error)", uptime.uptimeSeconds)
                requestReconnect(reason: "initialisation failed: \(error)")
            }
        }
    }

    /// Stops using the current connection: UI state no longer follows its
    /// session, which is shut down in the background (`retireSession`).
    private func dropLink() {
        linkToken += 1
        pollHz = 0
        Task { await retireSession() }
    }

    /// Shuts the current session down, waits until its last event has been
    /// forwarded, and keeps its `nextSeq`. Concurrent calls share one run.
    private func retireSession() async {
        if let old = session {
            session = nil
            let consumer = sessionTask
            sessionTask = nil
            let previous = retiring
            retiring = Task {
                await previous?.value
                await old.shutdown()
                await consumer?.value
                self.nextSeq = max(self.nextSeq, await old.nextSeq)
            }
        }
        await retiring?.value
    }

    private func handleSession(_ event: ELMSessionEvent, token: Int) {
        let current = token == linkToken
        if current {
            switch event {
            case .state(let from, let to, let reason, _) where from != to:
                applySessionState(to, reason: reason)
            case .adapter(let info, _):
                lastInfo = info
                var record = bleRecord ?? AdapterRecord(name: "", identifier: "")
                record.elmVersion = info.elmVersion
                record.protocolNumber = info.protocolNumber
                record.voltage = info.voltage
                adapter = record
                plan = info.plan
                if case .polling = state { state = .polling(protocolNumber: info.protocolNumber, voltage: info.voltage) }
            case .pollRate(let hz, _):
                pollHz = hz
            default:
                break
            }
        }
        // After the state above, so a subscriber reading `adapter` when it
        // handles an `.adapter` event sees this one's BLE half.
        subscriber?.yield(.session(event))
        appendConsole(for: event)
        if current, case .needsReconnect = event {
            requestReconnect(reason: "ELM session asked for a reconnect")
        }
    }

    private func applySessionState(_ elm: ELMState, reason: String?) {
        switch elm {
        case .resetting, .initialising, .searching, .probing, .reinitialising:
            state = .initialising
        case .ready:
            state = .ready
            pollHz = 0
        case .polling, .retrying:
            state = .polling(protocolNumber: lastInfo?.protocolNumber ?? "", voltage: lastInfo?.voltage)
        case .failed:
            // A reconnect, if one follows, sets `.reconnecting`.
            state = .failed(reason: reason ?? "ELM session failed")
            pollHz = 0
        case .idle:
            break
        }
    }

    // MARK: Console and log

    private func transition(to new: LinkSample.BLEState, reason: String?, uptime at: Double? = nil) {
        guard new != bleState else { return }
        let old = bleState
        bleState = new
        let stamp = at ?? uptime.uptimeSeconds
        subscriber?.yield(.ble(from: old, to: new, reason: reason, uptime: stamp))
        appendConsole(.status, "ble: \(old.rawValue) → \(new.rawValue)" + (reason.map { " (\($0))" } ?? ""), stamp)
    }

    private func appendConsole(for event: ELMSessionEvent) {
        switch event {
        case .exchange(let exchange):
            let tx = exchange.tx.isEmpty ? "(unsolicited)" : exchange.tx
            appendConsole(.tx, tx, exchange.requestUptime)
            let rx = exchange.rx.map { ELM327ResponseParser.lines(in: $0).joined(separator: " | ") }
            let outcome = exchange.outcome == .ok ? "" : " [\(exchange.outcome.rawValue)]"
            appendConsole(.rx, (rx ?? "—") + outcome, exchange.completedUptime)
        case .state(let from, let to, let reason, let at):
            let text = from == to ? "elm: \(reason ?? "")" : "elm: \(from.rawValue) → \(to.rawValue)" + (reason.map { " (\($0))" } ?? "")
            appendConsole(.status, text, at)
        case .adapter(let info, let at):
            let plan = info.plan
            appendConsole(
                .status,
                "adapter: \(info.elmVersion), protocol \(info.protocolNumber), "
                    + (info.voltage.map { String(format: "%.1f V", $0) } ?? "no voltage")
                    + ", polling \(plan.primaryCommand.wireFormat) at \(plan.requestHeader?.rawValue ?? "7DF"), ATAT\(plan.adaptiveTiming)",
                at
            )
        case .needsReconnect(let at):
            appendConsole(.status, "elm: needs reconnect", at)
        case .reading, .pollRate:
            break
        }
    }

    private func appendConsole(_ direction: ConsoleLine.Direction, _ text: String, _ at: Double) {
        console.append(ConsoleLine(id: nextConsoleID, direction: direction, text: text, uptime: at))
        nextConsoleID += 1
        if console.count > Self.consoleLimit { console.removeFirst(console.count - Self.consoleLimit) }
    }

    // MARK: Helpers

    private func remember(_ id: UUID) {
        rememberedAdapterID = id
        defaults.set(id.uuidString, forKey: Self.rememberedAdapterKey)
    }

    private func name(of id: UUID) -> String {
        discovered.first { $0.id == id }?.name ?? id.uuidString
    }

    /// Name fragments of OBD adapters, listed first in the picker.
    nonisolated static let adapterNameHints = ["vlink", "icar", "vgate", "obd", "elm", "veepeak"]

    nonisolated static func isLikelyAdapter(_ adapter: DiscoveredAdapter) -> Bool {
        let name = adapter.name.lowercased()
        return adapterNameHints.contains { name.contains($0) }
    }

    /// Likely adapters first, then strongest signal, then name.
    nonisolated static func listOrder(_ lhs: DiscoveredAdapter, _ rhs: DiscoveredAdapter) -> Bool {
        let (left, right) = (isLikelyAdapter(lhs), isLikelyAdapter(rhs))
        if left != right { return left }
        if lhs.rssi != rhs.rssi { return lhs.rssi > rhs.rssi }
        return lhs.name < rhs.name
    }
}
