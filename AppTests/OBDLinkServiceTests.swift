import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// The link service's state machine, against a scripted BLE central whose
// transports are `MockELMAdapter`s. No CoreBluetooth, no hardware: these
// tests prove the service logic only. What CoreBluetooth and the real
// adapter do is in docs/PLAN.md §6.

/// Wraps a `MockELMAdapter`; the first write of `failing` throws
/// `.writeFailed` without reaching the adapter, as `BLETransport.send` does
/// when `canSendWriteWithoutResponse` stays false for its readiness timeout.
/// The link itself stays up: no `.disconnected` follows.
actor WriteFailingTransport: ELMTransport {
    nonisolated let incoming: AsyncStream<ELMChunk>
    private let inner: MockELMAdapter
    private let failing: String
    private var failed = false

    init(_ inner: MockELMAdapter, failing: String) {
        self.inner = inner
        self.failing = failing
        incoming = inner.incoming
    }

    func send(_ command: ValidatedELMCommand) async throws -> Double {
        if !failed, command.wire.caseInsensitiveCompare(failing) == .orderedSame {
            failed = true
            throw ELMTransportError.writeFailed("not ready for a write without response within 1 s")
        }
        return try await inner.send(command)
    }
}

/// A `BLECentralClient` that connects at once and hands over a
/// `MockELMAdapter` per connection: `scripts[n]` for connection `n`, the
/// last one repeating. `writeFailures[n]` names a command whose first write
/// on connection `n` throws `.writeFailed` (`WriteFailingTransport`).
final class FakeBLECentral: BLECentralClient {
    static let adapterID = UUID(uuidString: "0BD0B0D0-1111-4222-8333-944455556666")!

    let events: AsyncStream<BLECentralEvent>
    private let continuation: AsyncStream<BLECentralEvent>.Continuation
    private let scripts: [[MockELMAdapter.Rule]]
    private let writeFailures: [Int: String]
    private let lock = NSLock()
    // Guarded by `lock`.
    private nonisolated(unsafe) var log: [String] = []
    // Guarded by `lock`.
    private nonisolated(unsafe) var made: [MockELMAdapter] = []
    // Guarded by `lock`.
    private nonisolated(unsafe) var current: MockELMAdapter?

    init(scripts: [[MockELMAdapter.Rule]], writeFailures: [Int: String] = [:], poweredOn: Bool = true) {
        self.scripts = scripts
        self.writeFailures = writeFailures
        (events, continuation) = AsyncStream.makeStream(of: BLECentralEvent.self)
        if poweredOn { send(.availability(.poweredOn, uptime: Self.now)) }
    }

    static var now: Double { ProcessInfo.processInfo.systemUptime }

    var calls: [String] { lock.withLock { log } }
    var adapters: [MockELMAdapter] { lock.withLock { made } }

    func send(_ event: BLECentralEvent) {
        continuation.yield(event)
    }

    func startScan() {
        lock.withLock { log.append("scan") }
        send(.discovered(DiscoveredAdapter(id: Self.adapterID, name: "IOS-Vlink", rssi: -60)))
    }

    func stopScan() {
        lock.withLock { log.append("stopScan") }
    }

    func connect(_ id: UUID) {
        let transport = lock.withLock { () -> any ELMTransport in
            log.append("connect")
            let script = scripts[min(made.count, scripts.count - 1)]
            let adapter = MockELMAdapter(rules: script)
            let failing = writeFailures[made.count]
            made.append(adapter)
            current = adapter
            return failing.map { WriteFailingTransport(adapter, failing: $0) } ?? adapter
        }
        send(.connected(id, uptime: Self.now))
        send(.ready(
            BLELinkReady(id: id, name: "IOS-Vlink", transport: transport, selection: SimulatedBLECentral.selection, table: SimulatedBLECentral.table),
            uptime: Self.now
        ))
    }

    func cancelConnection(_ id: UUID) {
        let adapter = lock.withLock { () -> MockELMAdapter? in
            log.append("cancel")
            defer { current = nil }
            return current
        }
        Task {
            await adapter?.disconnect()
            send(.disconnected(id, reason: nil, uptime: Self.now))
        }
    }

    /// The adapter is unplugged.
    func loseLink() async {
        let adapter = lock.withLock { () -> MockELMAdapter? in
            defer { current = nil }
            return current
        }
        await adapter?.disconnect()
        send(.disconnected(Self.adapterID, reason: "The connection has timed out unexpectedly.", uptime: Self.now))
    }
}

/// Collects a link's events on the main actor.
@MainActor
final class LinkEventLog {
    private(set) var events: [LinkEvent] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<LinkEvent>) {
        task = Task { [weak self] in
            for await event in stream { self?.events.append(event) }
        }
    }

    var ble: [(from: LinkSample.BLEState, to: LinkSample.BLEState, reason: String?)] {
        events.compactMap { if case .ble(let from, let to, let reason, _) = $0 { (from, to, reason) } else { nil } }
    }

    var exchanges: [ELMExchange] {
        events.compactMap { if case .session(.exchange(let exchange)) = $0 { exchange } else { nil } }
    }

    var readings: [OBDReading] {
        events.compactMap { if case .session(.reading(let reading)) = $0 { reading } else { nil } }
    }
}

/// Polls `condition` on the main actor every 10 ms, for up to `seconds`.
@MainActor
func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

enum LinkTestSupport {
    /// The Touareg script with every delay set to `ms`, so polling runs on
    /// the real clock without spinning.
    static func touareg(ms: Int = 3, overrides: [MockELMAdapter.Rule] = []) -> [MockELMAdapter.Rule] {
        (overrides + MockELMAdapter.Rule.touareg).map { rule in
            var rule = rule
            rule.delay = .milliseconds(ms)
            return rule
        }
    }

    /// `touareg` with a 200 ms `ATZ` (inside the test `resetTimeout`), so a
    /// test can act while the first initialisation is running.
    static func slowReset() -> [MockELMAdapter.Rule] {
        [MockELMAdapter.Rule(command: "ATZ", reply: "ATZ\r\r\rELM327 v2.1\r\r>", delay: .milliseconds(200))] + touareg()
    }

    static func benchCar(ms: Int = 3) -> [MockELMAdapter.Rule] {
        MockELMAdapter.Rule.benchCar.map { rule in
            var rule = rule
            rule.delay = .milliseconds(ms)
            return rule
        }
    }

    static let configuration = ELMSessionConfiguration(
        commandTimeout: .milliseconds(150),
        resetTimeout: .milliseconds(400),
        searchTimeout: .seconds(1),
        failuresBeforeReinit: 3,
        reinitsBeforeReconnect: 2,
        probe: false,
        rateWindow: .milliseconds(500),
        retryDelay: .milliseconds(5),
        reinitBackoff: .milliseconds(10)
    )

    static var probing: ELMSessionConfiguration {
        var configuration = configuration
        configuration.probe = true
        return configuration
    }

    static let backoff = ReconnectBackoff(initial: .milliseconds(20), maximum: .milliseconds(80))

    static func defaults() -> UserDefaults {
        let name = "OBDLinkServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @MainActor
    static func service(
        _ central: FakeBLECentral,
        defaults: UserDefaults = defaults(),
        configuration: ELMSessionConfiguration = configuration
    ) -> OBDLinkService {
        OBDLinkService(central: central, defaults: defaults, sessionConfiguration: configuration, backoff: backoff)
    }
}

extension OBDLinkState {
    var isPolling: Bool {
        if case .polling = self { true } else { false }
    }
}

@MainActor
@Suite("OBDLinkService", .serialized, .timeLimit(.minutes(1)))
struct OBDLinkServiceTests {
    @Test("Scan, pick, connect: initialises, polls, remembers the adapter, records BLE transitions in order")
    func connectAndPoll() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.benchCar()])
        let defaults = LinkTestSupport.defaults()
        let link = LinkTestSupport.service(central, defaults: defaults, configuration: LinkTestSupport.probing)
        let log = LinkEventLog(link.linkEvents())
        #expect(await eventually { central.calls.isEmpty && link.bleState == .idle })

        link.startScan()
        #expect(await eventually { !link.discovered.isEmpty })
        #expect(link.bleState == .scanning)
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling && log.readings.count >= 4 })

        #expect(link.state == .polling(protocolNumber: "A6", voltage: 11.0))
        #expect(link.rememberedAdapterID == FakeBLECentral.adapterID)
        #expect(defaults.string(forKey: OBDLinkService.rememberedAdapterKey) == FakeBLECentral.adapterID.uuidString)
        let adapter = try #require(link.adapter)
        #expect(adapter.name == "IOS-Vlink")
        #expect(adapter.identifier == FakeBLECentral.adapterID.uuidString)
        #expect(adapter.gatt == SimulatedBLECentral.selection)
        #expect(adapter.gattTable == SimulatedBLECentral.table)
        #expect(adapter.elmVersion == "ELM327 v2.3")
        #expect(adapter.protocolNumber == "A6")
        #expect(link.plan?.primaryCommand.wireFormat == "010D0C1")
        #expect(link.plan?.requestHeader == .engine)
        #expect(log.ble.map(\.to) == [.scanning, .idle, .connecting, .discovering, .connected])
        #expect(log.readings.filter(\.isFromPrimaryECU).contains { $0.measurement.value == 663 })
        #expect(link.console.contains { $0.direction == .tx && $0.text == "ATSH7E0" })
        #expect(link.console.contains { $0.direction == .status && $0.text.hasPrefix("ble: discovering → connected") })
        let seqs = log.exchanges.map(\.seq)
        #expect(seqs == Array(seqs.indices), "seq starts at 0 and has no gaps")
        link.disconnect()
    }

    @Test("Link loss: disconnected → reconnecting → connected, a new session, seq continues without repeats")
    func linkLossReconnects() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.touareg()])
        let link = LinkTestSupport.service(central)
        let log = LinkEventLog(link.linkEvents())
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { log.readings.count >= 3 })
        let before = log.exchanges.count

        await central.loseLink()
        #expect(await eventually { central.adapters.count == 2 && link.state.isPolling && log.exchanges.count > before + 12 })

        let transitions = log.ble.map(\.to)
        #expect(transitions == [.connecting, .discovering, .connected, .disconnected, .reconnecting, .connecting, .discovering, .connected])
        #expect(log.ble[3].reason == "The connection has timed out unexpectedly.")
        let seqs = log.exchanges.map(\.seq)
        #expect(Set(seqs).count == seqs.count, "no seq used twice")
        #expect(seqs == seqs.sorted(), "emitted in increasing order across the reconnect")
        let firstOfSecond = try #require(await central.adapters[1].sentCommands.first)
        #expect(firstOfSecond == "ATZ")
        #expect(log.events.contains {
            if case .session(.state(_, .failed, "transport closed", _)) = $0 { true } else { false }
        })
        link.disconnect()
    }

    @Test("needsReconnect from the session drops the link and reconnects with backoff")
    func needsReconnect() async throws {
        // Connection 1: every speed poll fails, so retries and re-inits run
        // out. Connection 2: healthy.
        let failing = LinkTestSupport.touareg(overrides: [MockELMAdapter.Rule(command: "010D", reply: "CAN ERROR\r\r>")])
        let central = FakeBLECentral(scripts: [failing, LinkTestSupport.touareg()])
        let link = LinkTestSupport.service(central)
        let log = LinkEventLog(link.linkEvents())
        link.connect(to: FakeBLECentral.adapterID)

        #expect(await eventually { central.adapters.count == 2 && link.state.isPolling && !log.readings.isEmpty })
        #expect(central.calls.contains("cancel"))
        #expect(log.events.contains { if case .session(.needsReconnect) = $0 { true } else { false } })
        let drop = try #require(log.ble.first { $0.to == .disconnected })
        #expect(drop.reason == "ELM session asked for a reconnect")
        #expect(log.ble.contains { $0.to == .reconnecting && $0.reason?.hasPrefix("attempt 1 in") == true })
        link.disconnect()
    }

    @Test("A failed initialisation reconnects too")
    func initFailureReconnects() async throws {
        let mute = LinkTestSupport.touareg(overrides: [MockELMAdapter.Rule(command: "ATZ", reply: nil)])
        let central = FakeBLECentral(scripts: [mute, LinkTestSupport.touareg()])
        let link = LinkTestSupport.service(central)
        let log = LinkEventLog(link.linkEvents())
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { central.adapters.count == 2 && link.state.isPolling })
        #expect(log.ble.contains { $0.to == .disconnected && $0.reason?.hasPrefix("initialisation failed") == true })
        link.disconnect()
    }

    // R3.1-1: a write error is not link loss. BLE stays connected and no
    // `.disconnected` ever arrives, so the service must reconnect itself.
    @Test("A write failure during the handshake, with BLE still connected, reconnects; the next connection polls")
    func initWriteFailureReconnects() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.touareg()], writeFailures: [0: "ATZ"])
        let link = LinkTestSupport.service(central)
        let log = LinkEventLog(link.linkEvents())
        link.connect(to: FakeBLECentral.adapterID)

        #expect(await eventually { central.adapters.count == 2 && link.state.isPolling && !log.readings.isEmpty })
        #expect(central.calls.filter { $0 == "connect" }.count == 2)
        #expect(central.calls.contains("cancel"), "the stuck connection is cancelled")
        #expect(log.ble.map(\.to).prefix(8) == [
            .connecting, .discovering, .connected, .disconnected, .reconnecting, .connecting, .discovering, .connected,
        ])
        let drop = try #require(log.ble.first { $0.to == .disconnected })
        #expect(drop.reason?.hasPrefix("initialisation failed") == true)
        #expect(drop.reason?.contains("writeFailed") == true)
        #expect(await central.adapters[0].sentCommands.isEmpty, "the failed ATZ never reached the adapter")
        #expect(await central.adapters[1].sentCommands.first == "ATZ")
        link.disconnect()
    }

    @Test("Console commands are validated with the .manual scope; nothing forbidden reaches the adapter")
    func manualScope() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.touareg()])
        let link = LinkTestSupport.service(central)
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling })

        let voltage = try await link.sendManual("atrv")
        #expect(voltage.phase == .manual)
        #expect(voltage.outcome == .ok)
        #expect(voltage.rx == "12.4V\r\r")
        // ATZ, ATSH and ATE1 are session commands; 04 clears DTCs, 03 and
        // 09 are other modes; 22 is UDS.
        for forbidden in ["ATZ", "ATSH7E0", "ATE1", "04", "03", "0902", "22F40D"] {
            await #expect(throws: ELMSessionError.forbiddenCommand(forbidden)) { _ = try await link.sendManual(forbidden) }
        }
        let sent = await central.adapters[0].sentCommands
        #expect(!sent.contains { ["04", "03", "0902", "22F40D", "ATE1"].contains($0) })
        #expect(sent.filter { $0 == "ATZ" }.count == 1, "only the session's own ATZ")
        #expect(sent.contains("ATRV"))
        link.disconnect()
    }

    @Test("Without a connection: forbidden commands are still forbidden, allowed ones are notInitialised")
    func manualWithoutConnection() async {
        let link = LinkTestSupport.service(FakeBLECentral(scripts: [LinkTestSupport.touareg()]))
        await #expect(throws: ELMSessionError.forbiddenCommand("04")) { _ = try await link.sendManual("04") }
        await #expect(throws: ELMSessionError.notInitialised) { _ = try await link.sendManual("ATRV") }
    }

    // M1-E6: a desynchronised link refuses manual commands; the service
    // catches it and re-initialises when the session isn't polling.
    @Test("sendManual on a desynchronised, non-polling link throws .desynchronised and re-initialises")
    func desynchronisedManual() async throws {
        // Every PID answers NO DATA (never OK), so polling ends in `ready`.
        // The first manual ATRV never gets its prompt.
        let script = LinkTestSupport.touareg(overrides: [
            MockELMAdapter.Rule(command: "010D", reply: "NO DATA\r\r>"),
            MockELMAdapter.Rule(command: "010C", reply: "NO DATA\r\r>"),
            MockELMAdapter.Rule(command: "ATRV", reply: "12.4V\r\r>", times: 1),   // handshake
            MockELMAdapter.Rule(command: "ATRV", reply: nil, times: 1),            // manual: lost
        ])
        let central = FakeBLECentral(scripts: [script])
        let link = LinkTestSupport.service(central)
        link.connect(to: FakeBLECentral.adapterID)
        let ended = { link.console.filter { $0.text.contains("every polled PID answered NO DATA") }.count }
        #expect(await eventually { link.state == .ready && ended() == 1 })

        let lost = try await link.sendManual("ATRV")
        #expect(lost.outcome == .timeout)
        await #expect(throws: ELMSessionError.desynchronised) { _ = try await link.sendManual("ATI") }
        #expect(link.console.contains { $0.text.hasPrefix("link desynchronised") })
        #expect(await eventually {
            link.state == .ready && ended() == 2 && link.console.filter { $0.direction == .tx && $0.text == "ATZ" }.count == 2
        })
        let info = try await link.sendManual("ATI")
        #expect(info.outcome == .ok)
        #expect(info.rx == "ELM327 v2.1\r\r")
        link.disconnect()
    }

    // R3.1-4: a reinitialise() during the first initialisation used to join
    // the session's init run; both callers then called startPolling, the
    // second got .notInitialised, and the service reconnected a healthy link.
    @Test("reinitialise() during the first initialisation joins it: polls, no reconnect, one ATZ")
    func reinitialiseDuringFirstInit() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.slowReset()])
        let link = LinkTestSupport.service(central)
        let log = LinkEventLog(link.linkEvents())
        link.connect(to: FakeBLECentral.adapterID)
        // The session exists and its ATZ is in flight (200 ms).
        #expect(await eventually { link.console.contains { $0.text == "elm: idle → resetting" } })
        #expect(link.state == .initialising)

        await link.reinitialise()
        #expect(await eventually { link.state.isPolling && !log.readings.isEmpty })
        try await Task.sleep(for: .milliseconds(300))

        #expect(link.state.isPolling)
        #expect(!log.ble.contains { $0.to == .disconnected }, "the healthy link is not torn down")
        #expect(central.calls.filter { $0 == "connect" }.count == 1)
        #expect(!central.calls.contains("cancel"))
        #expect(!link.console.contains { $0.text.hasPrefix("init failed") })
        #expect(await central.adapters[0].sentCommands.filter { $0 == "ATZ" }.count == 1, "one init run, shared")
        link.disconnect()
    }

    @Test("Two concurrent reinitialise() calls while polling share one run: one ATZ, polling again, no reconnect")
    func concurrentReinitialise() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.slowReset()])
        let link = LinkTestSupport.service(central)
        let log = LinkEventLog(link.linkEvents())
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling && !log.readings.isEmpty })

        let first = Task { await link.reinitialise() }
        let second = Task { await link.reinitialise() }
        await first.value
        await second.value
        let readings = log.readings.count
        #expect(await eventually { link.state.isPolling && log.readings.count > readings })
        try await Task.sleep(for: .milliseconds(300))

        #expect(link.state.isPolling)
        #expect(!log.ble.contains { $0.to == .disconnected })
        #expect(central.calls.filter { $0 == "connect" }.count == 1)
        #expect(!link.console.contains { $0.text.hasPrefix("init failed") })
        #expect(await central.adapters[0].sentCommands.filter { $0 == "ATZ" }.count == 2, "connect + one shared re-init")
        link.disconnect()
    }

    @Test("reinitialise() after the first initialisation has finished runs a fresh one")
    func reinitialiseAfterInit() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.touareg()])
        let link = LinkTestSupport.service(central)
        let log = LinkEventLog(link.linkEvents())
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling && !log.readings.isEmpty })

        await link.reinitialise()
        await link.reinitialise()
        #expect(await eventually { link.state.isPolling })
        #expect(await central.adapters[0].sentCommands.filter { $0 == "ATZ" }.count == 3, "connect + two sequential re-inits")
        #expect(!log.ble.contains { $0.to == .disconnected })
        link.disconnect()
    }

    @Test("disconnect() stops reconnecting; forget() also clears the remembered adapter")
    func disconnectAndForget() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.touareg()])
        let defaults = LinkTestSupport.defaults()
        let link = LinkTestSupport.service(central, defaults: defaults)
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling })

        link.disconnect()
        #expect(link.bleState == .idle)
        #expect(link.state == .idle)
        try await Task.sleep(for: .milliseconds(300))
        #expect(central.calls.filter { $0 == "connect" }.count == 1, "no reconnect after a user disconnect")
        #expect(link.rememberedAdapterID == FakeBLECentral.adapterID)

        link.forget()
        #expect(link.rememberedAdapterID == nil)
        #expect(defaults.string(forKey: OBDLinkService.rememberedAdapterKey) == nil)
    }

    @Test("A remembered adapter is reconnected automatically once Bluetooth is on")
    func rememberedAutoConnect() async throws {
        let defaults = LinkTestSupport.defaults()
        defaults.set(FakeBLECentral.adapterID.uuidString, forKey: OBDLinkService.rememberedAdapterKey)
        let central = FakeBLECentral(scripts: [LinkTestSupport.touareg()], poweredOn: false)
        let link = LinkTestSupport.service(central, defaults: defaults)
        #expect(link.rememberedAdapterID == FakeBLECentral.adapterID)
        try await Task.sleep(for: .milliseconds(50))
        #expect(central.calls.isEmpty)

        central.send(.availability(.poweredOn, uptime: FakeBLECentral.now))
        #expect(await eventually { link.state.isPolling })
        link.disconnect()
    }

    @Test("Bluetooth off: unavailable with the reason; the link drops and comes back when it is on again")
    func bluetoothOff() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.touareg()])
        let link = LinkTestSupport.service(central)
        let log = LinkEventLog(link.linkEvents())
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling })

        await central.loseLink()
        central.send(.availability(.unavailable("Bluetooth is off"), uptime: FakeBLECentral.now))
        #expect(await eventually { link.state == .unavailable(reason: "Bluetooth is off") })
        #expect(link.bleState == .unavailable)
        central.send(.availability(.poweredOn, uptime: FakeBLECentral.now))
        #expect(await eventually { link.state.isPolling && central.adapters.count >= 2 })
        #expect(log.ble.contains { $0.to == .unavailable && $0.reason == "Bluetooth is off" })
        link.disconnect()
    }

    @Test("A GATT layout without a UART pair fails without retrying")
    func unusableGATT() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.touareg()])
        let link = LinkTestSupport.service(central)
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling })
        // Simulate a later connection to a peripheral with nothing usable.
        link.disconnect()
        link.connect(to: FakeBLECentral.adapterID)
        central.send(.unusable(FakeBLECentral.adapterID, table: [], reason: "no notify + write characteristic pair in 0 service(s)", uptime: FakeBLECentral.now))
        #expect(await eventually { if case .failed = link.state { true } else { false } })
        #expect(link.bleState == .idle)
    }

    @Test("A new linkEvents() call finishes the previous stream")
    func singleSubscriber() async {
        let link = LinkTestSupport.service(FakeBLECentral(scripts: [LinkTestSupport.touareg()]))
        let first = link.linkEvents()
        _ = link.linkEvents()
        var iterator = first.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
}

@MainActor
@Suite("SimulatedOBDLink", .serialized, .timeLimit(.minutes(1)))
struct SimulatedOBDLinkTests {
    @Test("Simulated Vlink: scan, connect, bench-car polling, link loss and reconnect with seq continuing")
    func endToEnd() async throws {
        let link = SimulatedOBDLink(
            rules: LinkTestSupport.benchCar(),
            defaults: LinkTestSupport.defaults(),
            sessionConfiguration: LinkTestSupport.probing,
            backoff: LinkTestSupport.backoff,
            latency: .milliseconds(10)
        )
        let log = LinkEventLog(link.linkEvents())
        link.startScan()
        #expect(await eventually { link.discovered.map(\.name) == ["Simulated Vlink"] })
        link.connect(to: SimulatedBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling && log.readings.count >= 4 })
        #expect(link.adapter?.name == "Simulated Vlink")
        #expect(link.adapter?.gatt?.service == GATTDetection.vgateService)
        #expect(link.plan?.primaryCommand.wireFormat == "010D0C1")
        let speeds = log.readings.filter { $0.measurement.pid == .vehicleSpeed }
        #expect(speeds.allSatisfy { $0.ecu == "7E8" && $0.measurement.value == 0 })

        let before = log.exchanges.count
        await link.simulateLinkLoss()
        #expect(await eventually { link.state.isPolling && log.exchanges.count > before + 15 })
        #expect(log.ble.map(\.to).suffix(5) == [.disconnected, .reconnecting, .connecting, .discovering, .connected])
        let seqs = log.exchanges.map(\.seq)
        #expect(Set(seqs).count == seqs.count && seqs == seqs.sorted())
        link.disconnect()
    }

    // R3.1-4 through the simulator's link, which the console runs against.
    @Test("Simulated Vlink: reinitialise() during the first initialisation joins it, no reconnect")
    func reinitialiseDuringFirstInit() async throws {
        let slowReset = MockELMAdapter.Rule(command: "ATZ", reply: "ATZ\r\r\rELM327 v2.3\r\r>", delay: .milliseconds(200))
        let link = SimulatedOBDLink(
            rules: [slowReset] + LinkTestSupport.benchCar(),
            defaults: LinkTestSupport.defaults(),
            // The bench car only answers the probed plan (010D0C1 at 7E0).
            sessionConfiguration: LinkTestSupport.probing,
            backoff: LinkTestSupport.backoff,
            latency: .milliseconds(10)
        )
        let log = LinkEventLog(link.linkEvents())
        link.connect(to: SimulatedBLECentral.adapterID)
        #expect(await eventually { link.console.contains { $0.text == "elm: idle → resetting" } })

        await link.reinitialise()
        #expect(await eventually { link.state.isPolling && !log.readings.isEmpty })
        try await Task.sleep(for: .milliseconds(300))

        #expect(link.state.isPolling)
        #expect(!log.ble.contains { $0.to == .disconnected })
        #expect(link.console.filter { $0.direction == .tx && $0.text == "ATZ" }.count == 1)
        link.disconnect()
    }

    @Test("The factory picks the simulated link on the simulator")
    func factory() {
        #if targetEnvironment(simulator)
        #expect(OBDLinkFactory.makeDefault() is SimulatedOBDLink)
        #endif
    }
}
