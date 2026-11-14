import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// Reconnect attempts of `OBDLinkService` on a virtual clock: a scripted BLE
// central that answers only when told, and `ManualLinkClock` for every
// timer. No real sleeps. What CoreBluetooth itself does with a pending
// connect, a cancel and a re-issue is a device check (docs/PLAN.md §6).

/// A `Clock` and `UptimeSource` that only moves when told. Sleepers wake in
/// deadline order; `settle()` lets woken main-actor tasks run (yields only).
final class ManualLinkClock: Clock, UptimeSource {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        var id: UInt64
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    let baseUptime: Double
    private let lock = NSLock()
    // All guarded by `lock`.
    private nonisolated(unsafe) var current = Instant(offset: .zero)
    private nonisolated(unsafe) var sleepers: [Sleeper] = []
    private nonisolated(unsafe) var nextID: UInt64 = 0
    private nonisolated(unsafe) var cancelledBeforeRegistration: Set<UInt64> = []

    init(baseUptime: Double = 600) {
        self.baseUptime = baseUptime
    }

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .nanoseconds(1) }
    var uptimeSeconds: Double {
        let components = now.offset.components
        return baseUptime + Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        let id = lock.withLock {
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Action { case resume, cancel, wait }
                let action: Action = lock.withLock {
                    if cancelledBeforeRegistration.remove(id) != nil { return .cancel }
                    if deadline <= current { return .resume }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .wait
                }
                switch action {
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
                if let index = sleepers.firstIndex(where: { $0.id == id }) {
                    return sleepers.remove(at: index).continuation
                }
                cancelledBeforeRegistration.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward by `duration`, waking sleepers in deadline order
    /// and letting each one's work run before the next.
    func advance(by duration: Duration) async {
        let target = now.advanced(by: duration)
        while true {
            await settle()
            let due: [Sleeper]? = lock.withLock {
                guard let earliest = sleepers.map(\.deadline).min(), earliest <= target else { return nil }
                if current < earliest { current = earliest }
                let due = sleepers.filter { $0.deadline <= current }
                sleepers.removeAll { $0.deadline <= current }
                return due
            }
            guard let due else { break }
            for sleeper in due { sleeper.continuation.resume() }
        }
        lock.withLock { if current < target { current = target } }
        await settle()
    }

    /// Lets woken tasks and stream consumers run. Yields only.
    func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }
}

/// A `BLECentralClient` that never answers on its own. It records every
/// `connect` and `cancelConnection` with the virtual time, tracks whether a
/// CoreBluetooth connect is pending (issued, not cancelled, not answered),
/// and lets the test deliver the callbacks, stamped with the generation of
/// the attempt they belong to, as `BLECentral` does.
final class ScriptedBLECentral: BLECentralClient {
    static let adapterID = FakeBLECentral.adapterID

    enum Call: Equatable {
        case connect(generation: Int)
        case cancel(generation: Int?)
    }

    struct Entry {
        var call: Call
        var uptime: Double
    }

    let events: AsyncStream<BLECentralEvent>
    private let continuation: AsyncStream<BLECentralEvent>.Continuation
    private let clock: ManualLinkClock
    private let lock = NSLock()
    // All guarded by `lock`.
    private nonisolated(unsafe) var log: [Entry] = []
    private nonisolated(unsafe) var pendingGeneration: Int?
    private nonisolated(unsafe) var connectedGeneration: Int?
    private nonisolated(unsafe) var doubles = 0
    /// Uncovered virtual time: no connect pending and no connection, summed.
    private nonisolated(unsafe) var uncoveredSince: Double?
    private nonisolated(unsafe) var uncovered = 0.0

    init(clock: ManualLinkClock, poweredOn: Bool = true) {
        self.clock = clock
        (events, continuation) = AsyncStream.makeStream(of: BLECentralEvent.self)
        if poweredOn { send(.availability(.poweredOn, uptime: clock.uptimeSeconds)) }
    }

    func send(_ event: BLECentralEvent) {
        continuation.yield(event)
    }

    var calls: [Entry] { lock.withLock { log } }
    var connectTimes: [Double] { calls.compactMap { if case .connect = $0.call { $0.uptime } else { nil } } }
    var connectCount: Int { connectTimes.count }
    /// Generations whose connect or connection was cancelled, in order.
    var cancelledGenerations: [Int] { calls.compactMap { if case .cancel(let generation?) = $0.call { generation } else { nil } } }
    /// The generation of the pending connect, if one is.
    var pending: Int? { lock.withLock { pendingGeneration } }
    var connected: Int? { lock.withLock { connectedGeneration } }
    /// A connect issued while another was still pending (never cancelled).
    var doubleConnects: Int { lock.withLock { doubles } }
    /// Virtual seconds spent with neither a pending connect nor a connection,
    /// since the first connect; `now` closes an open gap.
    func uncoveredSeconds(now: Double) -> Double {
        lock.withLock { uncovered + (uncoveredSince.map { now - $0 } ?? 0) }
    }

    func startScan() {}
    func stopScan() {}

    func connect(_ id: UUID, generation: Int) {
        let now = clock.uptimeSeconds
        lock.withLock {
            if pendingGeneration != nil { doubles += 1 }
            pendingGeneration = generation
            log.append(Entry(call: .connect(generation: generation), uptime: now))
            closeGap(now)
        }
    }

    func cancelConnection(_ id: UUID) {
        let now = clock.uptimeSeconds
        lock.withLock {
            log.append(Entry(call: .cancel(generation: pendingGeneration ?? connectedGeneration), uptime: now))
            pendingGeneration = nil
            connectedGeneration = nil
            openGap(now)
        }
    }

    /// The pending connect completes (`didConnect`).
    func answerConnect() {
        let now = clock.uptimeSeconds
        let generation = lock.withLock { () -> Int? in
            defer { pendingGeneration = nil }
            connectedGeneration = pendingGeneration
            return pendingGeneration
        }
        guard let generation else { return }
        send(.connected(Self.adapterID, generation: generation, uptime: now))
    }

    /// The pending connect fails (`didFailToConnect`).
    func failConnect(_ reason: String) {
        let now = clock.uptimeSeconds
        let generation = lock.withLock { () -> Int? in
            defer {
                pendingGeneration = nil
                openGap(now)
            }
            return pendingGeneration
        }
        guard let generation else { return }
        send(.connectFailed(Self.adapterID, generation: generation, reason: reason, uptime: now))
    }

    /// The connection's UART pair is ready, with `transport`.
    func ready(_ transport: any ELMTransport) {
        guard let generation = connected else { return }
        send(.ready(
            BLELinkReady(
                id: Self.adapterID, generation: generation, name: "IOS-Vlink", transport: transport,
                selection: SimulatedBLECentral.selection, table: SimulatedBLECentral.table
            ),
            uptime: clock.uptimeSeconds
        ))
    }

    /// The connection drops (CoreBluetooth supervision timeout).
    func loseLink() {
        let now = clock.uptimeSeconds
        let generation = lock.withLock { () -> Int? in
            defer {
                connectedGeneration = nil
                openGap(now)
            }
            return connectedGeneration
        }
        guard let generation else { return }
        send(.disconnected(Self.adapterID, generation: generation, reason: "The connection has timed out unexpectedly.", uptime: now))
    }

    // Under `lock`.
    private func openGap(_ now: Double) {
        if pendingGeneration == nil, connectedGeneration == nil, uncoveredSince == nil { uncoveredSince = now }
    }

    // Under `lock`.
    private func closeGap(_ now: Double) {
        if let since = uncoveredSince { uncovered += now - since }
        uncoveredSince = nil
    }
}

/// A link service on the virtual clock with the documented backoff (1 s
/// doubling to 30 s) and connect timeout (10 s).
@MainActor
struct ReconnectRig {
    let clock = ManualLinkClock()
    let central: ScriptedBLECentral
    let link: OBDLinkService
    let log: LinkEventLog

    init(defaults: UserDefaults = LinkTestSupport.defaults(), poweredOn: Bool = true) {
        central = ScriptedBLECentral(clock: clock, poweredOn: poweredOn)
        link = OBDLinkService(
            central: central, defaults: defaults, uptime: clock, sessionConfiguration: LinkTestSupport.configuration,
            clock: clock
        )
        log = LinkEventLog(link.linkEvents())
    }

    var now: Double { clock.uptimeSeconds }

    /// Picks the adapter, lets the connect complete, then loses the link;
    /// returns the uptime of the loss.
    func connectAndLose() async -> Double {
        link.connect(to: ScriptedBLECentral.adapterID)
        await clock.settle()
        central.answerConnect()
        await clock.settle()
        let loss = now
        central.loseLink()
        await clock.settle()
        return loss
    }

    /// Steps the virtual clock by `step` until `condition` holds, at most
    /// `limit` of virtual time.
    func advance(until condition: () -> Bool, step: Duration = .milliseconds(50), limit: Duration = .seconds(30)) async -> Bool {
        let deadline = clock.now.advanced(by: limit)
        while clock.now < deadline {
            if condition() { return true }
            await clock.advance(by: step)
        }
        return condition()
    }

    var console: [String] { link.console.map(\.text) }
}

@MainActor
@Suite("OBDLinkService reconnect attempts", .serialized, .timeLimit(.minutes(1)))
struct OBDLinkReconnectTests {
    // Field drive, prompt 49: after a supervision timeout the first
    // reconnect's connect never completed, and nothing re-armed it: no link
    // row for 169 s until the recording ended.
    @Test("Link lost, attempt 1's connect never answers: over 170 s the connect is re-issued every backoff + 10 s, each attempt and outcome in the link rows")
    func unansweredReconnectIsReissued() async throws {
        let rig = ReconnectRig()
        let loss = await rig.connectAndLose()
        await rig.clock.advance(by: .seconds(170))

        // Every connect after the pick.
        let reconnects = rig.central.connectTimes.dropFirst().map { $0 - loss }
        #expect(reconnects == [0, 11, 23, 37, 55, 81, 121, 161], "re-issued at once after each unanswered attempt")
        let ble = rig.log.ble
        let lost = try #require(ble.firstIndex { $0.reason == "The connection has timed out unexpectedly." })
        let after = ble[(lost + 1)...]
        #expect(after.filter { $0.to == .reconnecting }.compactMap(\.reason).map { $0.components(separatedBy: " in ").first } == [
            "attempt 1", "attempt 2", "attempt 3", "attempt 4", "attempt 5", "attempt 6", "attempt 7", "attempt 8",
        ])
        #expect(after.filter { $0.to == .connecting }.map(\.reason) == (1...7).map { "reconnect attempt \($0)" })
        #expect(after.filter { $0.to == .disconnected }.map(\.reason) == (1...7).map {
            "reconnect attempt \($0): no answer in 10.0 seconds, cancelled and re-issued"
        })
        #expect(rig.central.pending != nil, "a connect is pending at the end")
        #expect(rig.central.doubleConnects == 0)
        #expect(rig.central.uncoveredSeconds(now: rig.now) == 0, "never a moment without a pending connect")
        #expect(rig.link.console.contains { $0.text == "ble: connecting → disconnected (reconnect attempt 7: no answer in 10.0 seconds, cancelled and re-issued)" })
        rig.link.disconnect()
    }

    // (ii) A watchdog re-issue cancels the old attempt; CoreBluetooth may
    // still report it afterwards, as cancelled, lost, failed or connected.
    @Test("After a watchdog re-issue, late callbacks of the replaced attempt neither end nor pass for the new one; the new one stays pending, then connects; its real loss is reported")
    func lateCallbacksOfReplacedAttempt() async throws {
        let rig = ReconnectRig()
        let id = ScriptedBLECentral.adapterID
        _ = await rig.connectAndLose()
        await rig.clock.advance(by: .seconds(11))   // attempt 1 unanswered: cancelled, attempt 2 issued
        let replaced = try #require(rig.central.cancelledGenerations.last)
        let current = try #require(rig.central.pending)
        #expect(current > replaced)
        #expect(rig.link.bleState == .reconnecting)
        let calls = rig.central.calls.count
        let rows = rig.log.ble.count

        // While attempt 2 waits for its backoff…
        rig.central.send(.cancelled(id, generation: replaced, uptime: rig.now))
        rig.central.send(.connectFailed(id, generation: replaced, reason: "late failure", uptime: rig.now))
        rig.central.send(.connected(id, generation: replaced, uptime: rig.now))
        await rig.clock.settle()
        #expect(rig.link.bleState == .reconnecting)
        // …and while it is reported as connecting.
        await rig.clock.advance(by: .seconds(2.5))
        #expect(rig.link.bleState == .connecting)
        let connectingRows = rig.log.ble.count
        rig.central.send(.disconnected(id, generation: replaced, reason: "late loss", uptime: rig.now))
        rig.central.send(.connectFailed(id, generation: replaced, reason: "late failure", uptime: rig.now))
        rig.central.send(.connected(id, generation: replaced, uptime: rig.now))
        await rig.clock.settle()

        #expect(rig.central.calls.count == calls, "no cancel or connect caused by them")
        #expect(rig.log.ble.count == connectingRows && connectingRows == rows + 1, "only attempt 2's own → connecting")
        #expect(rig.link.bleState == .connecting)
        #expect(rig.central.pending == current, "attempt 2's connect is still the pending one")
        #expect(rig.central.doubleConnects == 0)
        #expect(rig.console.contains("ble: requested disconnect completed"))
        #expect(rig.console.filter { $0.contains("of an earlier attempt ignored") }.count == 5)

        rig.central.answerConnect()
        await rig.clock.settle()
        #expect(rig.link.bleState == .discovering, "the new attempt is alive")
        #expect(rig.log.ble.last.map { [$0.from, $0.to] } == [.connecting, .discovering])

        // A real loss of the current attempt is not swallowed.
        rig.central.loseLink()
        await rig.clock.settle()
        let tail = rig.log.ble.suffix(2)
        #expect(tail.map(\.to) == [.disconnected, .reconnecting])
        #expect(tail.first?.reason == "The connection has timed out unexpectedly.")
        #expect(rig.central.pending != nil)
        rig.link.disconnect()
    }

    // (iii) In the background a timer may not fire before the app is
    // suspended; a pending CoreBluetooth connect still wakes it.
    @Test("Restored in the background, the connect never completes: a connect is pending at every moment, re-issued at most every 40 s (30 s backoff + 10 s)")
    func pendingConnectThroughout() async throws {
        let defaults = LinkTestSupport.defaults()
        defaults.set(ScriptedBLECentral.adapterID.uuidString, forKey: OBDLinkService.rememberedAdapterKey)
        let rig = ReconnectRig(defaults: defaults, poweredOn: false)
        rig.central.send(.restored([ScriptedBLECentral.adapterID], uptime: rig.now))
        rig.central.send(.availability(.poweredOn, uptime: rig.now))
        await rig.clock.settle()
        #expect(rig.link.bleState == .connecting)
        let start = rig.now

        var uncoveredAt: [Double] = []
        for _ in 0..<900 {
            await rig.clock.advance(by: .seconds(2))
            if rig.central.pending == nil { uncoveredAt.append(rig.now - start) }
        }
        #expect(uncoveredAt.isEmpty, "a connect was pending at every step")
        #expect(rig.central.uncoveredSeconds(now: rig.now) == 0, "and in between: cancel and re-issue in one step")
        #expect(rig.central.doubleConnects == 0)
        let times = rig.central.connectTimes.map { $0 - start }
        let spacing = zip(times, times.dropFirst()).map { $1 - $0 }
        #expect(Array(spacing.prefix(7)) == [10, 11, 12, 14, 18, 26, 40])
        #expect(spacing.dropFirst(6).allSatisfy { $0 == 40 }, "capped at backoff 30 s + watchdog 10 s")
        #expect(times.count == 49, "0, 10, 21, 33, 47, 65, 91, then every 40 s to 1771 s")
        let first = try #require(rig.log.ble.first { $0.to == .disconnected })
        #expect(first.reason == "connect: no answer in 10.0 seconds, cancelled and re-issued")
        #expect(rig.log.ble.first?.reason == "relaunched by the system with the adapter")
        #expect(rig.log.ble.dropFirst().first?.reason == "restoring")
        rig.link.disconnect()
    }

    enum Stop: String, CaseIterable, Sendable {
        case disconnect, forget, holdForDemo
    }

    // (iv) The user's Disconnect/Forget and the demo hold end every attempt,
    // also one the watchdog has just re-issued.
    @Test(
        "Disconnect, Forget or the demo hold during a watchdog re-issue: the re-issued connect is cancelled and nothing connects again",
        arguments: Stop.allCases, [11.0, 13.5]
    )
    func stopDuringReissue(_ stop: Stop, at seconds: Double) async throws {
        let rig = ReconnectRig()
        let id = ScriptedBLECentral.adapterID
        _ = await rig.connectAndLose()
        await rig.clock.advance(by: .seconds(seconds))   // 11 s: reconnecting, 13.5 s: connecting, watchdog armed
        let reissued = try #require(rig.central.pending)
        #expect(rig.link.bleState == (seconds < 13 ? .reconnecting : .connecting))

        switch stop {
        case .disconnect: rig.link.disconnect()
        case .forget: rig.link.forget()
        case .holdForDemo: rig.link.holdForDemo()
        }
        await rig.clock.settle()
        #expect(rig.central.pending == nil, "the re-issued connect is cancelled")
        #expect(rig.central.cancelledGenerations.last == reissued)
        #expect(rig.link.bleState == .idle && rig.link.state == .idle)
        let connects = rig.central.connectCount

        // Late callbacks of the cancelled attempts revive nothing.
        for generation in rig.central.cancelledGenerations {
            rig.central.send(.cancelled(id, generation: generation, uptime: rig.now))
        }
        rig.central.send(.connected(id, generation: reissued, uptime: rig.now))
        rig.central.send(.connectFailed(id, generation: reissued, reason: "late", uptime: rig.now))
        await rig.clock.advance(by: .seconds(600))
        #expect(rig.central.connectCount == connects, "no connect after the stop")
        #expect(rig.link.bleState == .idle && rig.link.state == .idle)
        #expect(rig.link.rememberedAdapterID == (stop == .forget ? nil : id))
    }

    // (v) The session asks for a reconnect (here: its handshake write
    // failed with BLE still up); the attempt it starts is the only one.
    @Test("A reconnect requested by the ELM session starts one attempt; a late loss of the dropped connection and a reinitialise() don't add a second")
    func sessionRequestStartsOneAttempt() async throws {
        let rig = ReconnectRig()
        let id = ScriptedBLECentral.adapterID
        rig.link.connect(to: id)
        await rig.clock.settle()
        rig.central.answerConnect()
        await rig.clock.settle()
        let dropped = try #require(rig.central.connected)
        let adapter = MockELMAdapter(rules: LinkTestSupport.touareg(), uptime: rig.clock, clock: rig.clock)
        rig.central.ready(WriteFailingTransport(adapter, failing: "ATZ"))
        #expect(await rig.advance(until: { rig.link.bleState == .reconnecting }))
        let request = try #require(rig.log.ble.last { $0.to == .disconnected })
        #expect(request.reason?.hasPrefix("initialisation failed") == true)
        #expect(rig.central.calls.suffix(2).map(\.call) == [.cancel(generation: dropped), .connect(generation: dropped + 2)])
        let calls = rig.central.calls.count

        // CoreBluetooth reports the dropped connection as lost, not cancelled.
        rig.central.send(.disconnected(id, generation: dropped, reason: "The connection has timed out unexpectedly.", uptime: rig.now))
        await rig.link.reinitialise()
        await rig.clock.advance(by: .seconds(1))
        #expect(rig.link.bleState == .connecting)
        #expect(rig.central.calls.count == calls, "the pending connect is the attempt; nothing else was issued")
        #expect(rig.central.doubleConnects == 0)
        #expect(rig.log.ble.filter { $0.to == .reconnecting }.compactMap(\.reason) == ["attempt 1 in 1.0 seconds, connect pending"])

        rig.central.answerConnect()
        await rig.clock.settle()
        #expect(rig.link.bleState == .discovering)
        rig.link.disconnect()
    }

    // `.connectFailed` is an answer, and it can repeat at once (pairing
    // removed, an unknown peripheral): re-issuing it at once could spin.
    @Test("A connect that fails quickly is re-issued when the next backoff ends, not at once")
    func quickConnectFailureWaitsForBackoff() async throws {
        let rig = ReconnectRig()
        let loss = await rig.connectAndLose()
        await rig.clock.advance(by: .milliseconds(200))
        rig.central.failConnect("Peer removed pairing information.")
        await rig.clock.settle()
        #expect(rig.log.ble.suffix(2).map(\.reason) == ["Peer removed pairing information.", "attempt 2 in 2.0 seconds"])
        #expect(rig.central.pending == nil)
        let before = rig.central.connectCount
        await rig.clock.advance(by: .milliseconds(1900))
        #expect(rig.central.connectCount == before, "no connect before the backoff ends")
        await rig.clock.advance(by: .milliseconds(100))
        #expect(rig.central.connectCount == before + 1)
        let reissued = try #require(rig.central.connectTimes.last)
        #expect(abs(reissued - loss - 2.2) < 1e-9, "0.2 s + the 2 s backoff")
        #expect(rig.link.bleState == .connecting)
        #expect(rig.log.ble.last?.reason == "reconnect attempt 2")
        rig.link.disconnect()
    }

    @Test("A connect that fails after being pending at least the next backoff is re-issued at once")
    func slowConnectFailureReissuesAtOnce() async throws {
        let rig = ReconnectRig()
        let loss = await rig.connectAndLose()
        await rig.clock.advance(by: .seconds(5))   // connecting since +1 s, watchdog due at +11 s
        rig.central.failConnect("Connection failed to be established.")
        await rig.clock.settle()
        #expect(rig.central.connectTimes.last.map { $0 - loss } == 5)
        #expect(rig.central.pending != nil)
        #expect(rig.log.ble.suffix(2).map(\.reason) == ["Connection failed to be established.", "attempt 2 in 2.0 seconds, connect pending"])
        #expect(rig.central.uncoveredSeconds(now: rig.now) == 0)
        rig.link.disconnect()
    }
}
