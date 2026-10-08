import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// M4 bench (docs/BENCH_TEST_2026-10-08.md): the link connects and
// initialises before the user taps Start, and the recorder only writes link
// events while recording, so the file began with `poll` rows and no
// start-up `adapter` row. `lastInitEvents` keeps the latest connection's
// init so the recorder can write it at Start; `deliveredLinkEventCount`
// lets it skip, exactly, what it already got that way.

extension LinkEvent {
    /// Events that produce no rows and are never retained.
    var isDisplayOnly: Bool {
        switch self {
        case .session(.pollRate), .session(.needsReconnect): true
        default: false
        }
    }

    var bleTarget: LinkSample.BLEState? {
        if case .ble(_, let to, _, _) = self { to } else { nil }
    }

    var exchange: ELMExchange? {
        if case .session(.exchange(let exchange)) = self { exchange } else { nil }
    }

    /// A real ELM transition (not a note) into `state`.
    func isELMTransition(to state: ELMState) -> Bool {
        if case .session(.state(let from, let to, _, _)) = self { from != to && to == state } else { false }
    }

    var isAdapter: Bool {
        if case .session(.adapter) = self { true } else { false }
    }
}

/// What a recorder following `lastInitEvents`' dedup contract writes:
/// nothing before `start`; at `start`, `lastInitEvents`; after it, every
/// event it consumes except the first `deliveredLinkEventCount − consumed`
/// (delivered before Start, so either in the replay or not part of the
/// recording).
@MainActor
final class ContractRecorder {
    private(set) var written: [LinkEvent] = []
    private(set) var consumed = 0
    private var skip = 0
    private var started = false
    private var task: Task<Void, Never>?

    func consume(_ stream: AsyncStream<LinkEvent>) {
        task = Task { [weak self] in
            for await event in stream { self?.handle(event) }
        }
    }

    func start(_ link: any OBDLinkServicing) {
        written = link.lastInitEvents
        skip = link.deliveredLinkEventCount - consumed
        started = true
    }

    private func handle(_ event: LinkEvent) {
        consumed += 1
        guard started else { return }
        if skip > 0 {
            skip -= 1
            return
        }
        written.append(event)
    }
}

@MainActor
@Suite("OBDLinkService lastInitEvents (M4)", .serialized, .timeLimit(.minutes(1)))
struct LinkInitReplayTests {
    /// The span a recording running from the connect would have written for
    /// the init: from the BLE transition into `connecting` to the ELM
    /// transition into `polling`, display-only events left out.
    static func initSpan(_ events: [LinkEvent], connectingIndex: Int? = nil) throws -> [LinkEvent] {
        let start = try #require(connectingIndex ?? events.lastIndex { $0.bleTarget == .connecting })
        let end = try #require(events[start...].firstIndex { $0.isELMTransition(to: .polling) })
        return events[start...end].filter { !$0.isDisplayOnly }
    }

    @Test("After connect and init: BLE connect, init and probe exchanges, ATSH7E0, the adapter event, in order, original uptimes")
    func afterConnectAndInit() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.benchCar()])
        let link = LinkTestSupport.service(central, configuration: LinkTestSupport.probing)
        let log = LinkEventLog(link.linkEvents())
        #expect(link.lastInitEvents.isEmpty)
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling && log.readings.count >= 4 })

        #expect(await eventually { log.events.count == link.deliveredLinkEventCount })
        let replay = link.lastInitEvents
        // Exactly the events the subscriber got for the init, unchanged.
        #expect(replay == (try Self.initSpan(log.events)))
        #expect(replay.compactMap(\.bleTarget) == [.connecting, .discovering, .connected])

        let exchanges = replay.compactMap(\.exchange)
        #expect(Array(exchanges.map(\.tx).prefix(10)) == [
            "ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP0", "0100", "ATDPN", "ATRV", "ATSH7E0",
        ])
        #expect(exchanges.prefix(10).allSatisfy { $0.phase == .initialisation })
        let atsh = try #require(exchanges.first { $0.tx == "ATSH7E0" })
        #expect(atsh.outcome == .ok)
        let probes = exchanges.filter { $0.phase == .probe }
        #expect(probes.contains { $0.tx == "010D0C1" })
        #expect(probes.contains { $0.tx == "ATAT2" })
        #expect(!exchanges.contains { $0.phase == .poll }, "no poll traffic")
        #expect(exchanges.map(\.seq) == Array(0..<exchanges.count))

        // Order: connected, then ATZ, … ATSH7E0, probes, adapter, ready, polling.
        let connected = try #require(replay.firstIndex { $0.bleTarget == .connected })
        let atz = try #require(replay.firstIndex { $0.exchange?.tx == "ATZ" })
        let atshIndex = try #require(replay.firstIndex { $0.exchange?.tx == "ATSH7E0" })
        let firstProbe = try #require(replay.firstIndex { $0.exchange?.phase == .probe })
        let adapter = try #require(replay.firstIndex { $0.isAdapter })
        let ready = try #require(replay.firstIndex { $0.isELMTransition(to: .ready) })
        #expect(connected < atz && atz < atshIndex && atshIndex < firstProbe && firstProbe < adapter && adapter < ready)
        #expect(replay.last?.isELMTransition(to: .polling) == true)
        if case .session(.adapter(let info, _)) = replay[adapter] {
            #expect(info.plan == link.plan)
            #expect(info.plan.requestHeader == .engine)
        }

        // Written through the recorder's mapping at a Start after the init:
        // the same rows as live, with negative `t`.
        let clock = SessionClock()
        let rows = replay.flatMap { LogEvent.rows(for: $0, adapter: link.adapter, clock: clock) }
        #expect(rows == (try Self.initSpan(log.events)).flatMap { LogEvent.rows(for: $0, adapter: link.adapter, clock: clock) })
        #expect(rows.count == replay.count, "one row per retained event")
        #expect(rows.allSatisfy { $0.timestamp.nanoseconds < 0 })
        #expect(rows.contains { $0.payload.kind == "adapter" })

        link.disconnect()
    }

    @Test("reinitialise() replaces it: the BLE connect stays, the init is the new one")
    func reinitialiseReplaces() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.benchCar()])
        let link = LinkTestSupport.service(central, configuration: LinkTestSupport.probing)
        let log = LinkEventLog(link.linkEvents())
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling && log.readings.count >= 2 })
        let first = link.lastInitEvents
        let firstSeqs = Set(first.compactMap(\.exchange).map(\.seq))

        await link.reinitialise()
        #expect(await eventually { link.state.isPolling && link.lastInitEvents.last?.isELMTransition(to: .polling) == true })
        let second = link.lastInitEvents
        #expect(second != first)
        #expect(second.compactMap(\.bleTarget) == [.connecting, .discovering, .connected])
        #expect(Array(second.prefix(3)) == Array(first.prefix(3)), "same connection")
        let init2 = Array(second.dropFirst(3))
        #expect(init2.first?.isELMTransition(to: .resetting) == true)
        let exchanges = init2.compactMap(\.exchange)
        #expect(exchanges.filter { $0.tx == "ATZ" }.count == 1)
        #expect(exchanges.contains { $0.tx == "ATSH7E0" && $0.outcome == .ok })
        #expect(firstSeqs.isDisjoint(with: exchanges.map(\.seq)), "none of the first init's exchanges")
        #expect(!exchanges.contains { $0.phase == .poll })
        #expect(init2.contains { $0.isAdapter })
        // The new init is the subscriber's events from its `resetting`,
        // once the log has consumed everything delivered.
        #expect(await eventually { log.events.count == link.deliveredLinkEventCount })
        let resetting = try #require(log.events.lastIndex { $0.isELMTransition(to: .resetting) })
        let end = try #require(log.events[resetting...].firstIndex { $0.isELMTransition(to: .polling) })
        #expect(init2 == log.events[resetting...end].filter { !$0.isDisplayOnly })
        link.disconnect()
    }

    @Test("The session's own re-init (retry → reinitialising) replaces it too")
    func sessionReinitReplaces() async throws {
        // Without probing the plan is 010D (+ 010C); the first three speed
        // polls fail, so the session re-initialises by itself.
        let script = LinkTestSupport.touareg(overrides: [
            MockELMAdapter.Rule(command: "010D", reply: "CAN ERROR\r\r>", times: 3),
        ])
        let central = FakeBLECentral(scripts: [script])
        let link = LinkTestSupport.service(central)
        let log = LinkEventLog(link.linkEvents())
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually {
            log.events.contains { $0.isELMTransition(to: .reinitialising) } && link.state.isPolling && !log.readings.isEmpty
        })

        let replay = link.lastInitEvents
        #expect(replay.compactMap(\.bleTarget) == [.connecting, .discovering, .connected])
        let init2 = Array(replay.dropFirst(3))
        #expect(init2.first?.isELMTransition(to: .reinitialising) == true)
        if case .session(.state(_, .polling, let reason, _)) = try #require(init2.last) {
            #expect(reason == "re-initialised")
        } else {
            Issue.record("the re-init ends in polling")
        }
        let exchanges = init2.compactMap(\.exchange)
        #expect(exchanges.first?.tx == "ATZ")
        #expect(exchanges.contains { $0.tx == "ATSH7E0" })
        #expect(!exchanges.contains { $0.phase == .poll }, "the failed polls are before the re-init")
        #expect(init2.contains { $0.isAdapter })
        link.disconnect()
    }

    @Test("A reconnect resets it: only the new connection's BLE transitions and init")
    func reconnectResets() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.touareg()])
        let link = LinkTestSupport.service(central)
        let log = LinkEventLog(link.linkEvents())
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling && log.readings.count >= 2 })
        let firstSeqs = Set(link.lastInitEvents.compactMap(\.exchange).map(\.seq))

        await central.loseLink()
        #expect(await eventually {
            central.adapters.count == 2 && link.state.isPolling
                && link.lastInitEvents.last?.isELMTransition(to: .polling) == true
        })
        let replay = link.lastInitEvents
        #expect(replay.compactMap(\.bleTarget) == [.connecting, .discovering, .connected])
        if case .ble(let from, _, let reason, _) = try #require(replay.first) {
            #expect(from == .reconnecting)
            #expect(reason == "reconnect attempt 1")
        }
        let seqs = replay.compactMap(\.exchange).map(\.seq)
        #expect(firstSeqs.isDisjoint(with: seqs))
        #expect(seqs.min()! > firstSeqs.max()!)
        #expect(await eventually { log.events.count == link.deliveredLinkEventCount })
        let secondConnecting = try #require(log.events.lastIndex { $0.bleTarget == .connecting })
        #expect(replay == (try Self.initSpan(log.events, connectingIndex: secondConnecting)))
        link.disconnect()
    }

    @Test("A connection that never initialises leaves its BLE transitions only")
    func failedInitKeepsConnection() async throws {
        let mute = LinkTestSupport.touareg(overrides: [MockELMAdapter.Rule(command: "ATZ", reply: nil)])
        let central = FakeBLECentral(scripts: [mute])
        // No reconnect within the test: the next `connecting` would reset it.
        let link = OBDLinkService(
            central: central, defaults: LinkTestSupport.defaults(),
            sessionConfiguration: LinkTestSupport.configuration,
            backoff: ReconnectBackoff(initial: .seconds(30), maximum: .seconds(30))
        )
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.lastInitEvents.contains { $0.isELMTransition(to: .failed) } })
        let replay = link.lastInitEvents
        #expect(Array(replay.compactMap(\.bleTarget).prefix(3)) == [.connecting, .discovering, .connected])
        #expect(replay.compactMap(\.exchange).first?.tx == "ATZ")
        #expect(!replay.contains { $0.isAdapter })
        #expect(await eventually { link.bleState == .reconnecting })
        #expect(link.lastInitEvents == replay, "the drop after connected is not part of it")
        link.disconnect()
    }

    @Test("Bounded: at most initEventLimit events, the newest kept")
    func bounded() async throws {
        // A normal init is ~20 events here (no probing); a limit of 12
        // keeps its last 12, the end of the init, adapter event included.
        #expect(OBDLinkService.defaultInitEventLimit >= 200, "room for a full init with fallbacks")
        let central = FakeBLECentral(scripts: [LinkTestSupport.touareg()])
        let link = OBDLinkService(
            central: central, defaults: LinkTestSupport.defaults(),
            sessionConfiguration: LinkTestSupport.configuration, backoff: LinkTestSupport.backoff,
            initEventLimit: 12
        )
        let log = LinkEventLog(link.linkEvents())
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling && log.readings.count >= 2 })
        #expect(await eventually { log.events.count == link.deliveredLinkEventCount })
        let replay = link.lastInitEvents
        #expect(replay.count == 12)
        let full = try Self.initSpan(log.events)
        #expect(full.count > 12)
        #expect(replay == Array(full.suffix(12)))
        #expect(replay.contains { $0.isAdapter })
        link.disconnect()
    }

    @Test("Dedup contract, Start after the init: init once, then only events delivered after Start; seq unique")
    func contractStartWhilePolling() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.benchCar()])
        let link = LinkTestSupport.service(central, configuration: LinkTestSupport.probing)
        let recorder = ContractRecorder()
        recorder.consume(link.linkEvents())
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling && link.deliveredLinkEventCount > link.lastInitEvents.count + 20 })

        let replayed = link.lastInitEvents
        recorder.start(link)
        let deliveredAtStart = link.deliveredLinkEventCount
        #expect(await eventually { recorder.consumed >= deliveredAtStart + 20 })

        let written = recorder.written
        #expect(Array(written.prefix(replayed.count)) == replayed)
        let seqs = written.compactMap(\.exchange).map(\.seq)
        #expect(Set(seqs).count == seqs.count, "no exchange written twice")
        #expect(seqs == seqs.sorted())
        #expect(written.filter { $0.bleTarget == .connected }.count == 1)
        #expect(written.filter { $0.isAdapter }.count == 1)
        // Pre-Start polls are not written: a gap between the init's last
        // seq and the first live one.
        let lastInitSeq = try #require(replayed.compactMap(\.exchange).last?.seq)
        let firstLive = try #require(written.dropFirst(replayed.count).compactMap(\.exchange).first?.seq)
        #expect(firstLive > lastInitSeq + 1)
        link.disconnect()
    }

    @Test("Dedup contract, Start mid-init with undelivered events buffered: every init event written exactly once")
    func contractStartMidInit() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.slowReset()])
        let link = LinkTestSupport.service(central, configuration: LinkTestSupport.probing)
        // The recorder subscribes now but only starts consuming after Start,
        // so everything delivered before Start is still buffered in its
        // stream: the race the contract must handle.
        let stream = link.linkEvents()
        let recorder = ContractRecorder()
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await eventually { link.console.contains { $0.text == "elm: idle → resetting" } })
        #expect(link.state == .initialising)

        recorder.start(link)
        #expect(recorder.written.contains { $0.bleTarget == .connected })
        #expect(!recorder.written.contains { $0.isAdapter }, "the init is not finished yet")
        recorder.consume(stream)
        #expect(await eventually { link.state.isPolling && recorder.written.contains { $0.exchange?.phase == .poll } })

        let written = recorder.written
        let seqs = written.compactMap(\.exchange).map(\.seq)
        #expect(seqs == Array(0..<seqs.count), "every exchange from ATZ on, once, in order")
        #expect(written.filter { $0.bleTarget == .connected }.count == 1)
        #expect(written.filter { $0.isELMTransition(to: .resetting) }.count == 1)
        #expect(written.filter { $0.isAdapter }.count == 1)
        link.disconnect()
    }
}

@MainActor
@Suite("SimulatedOBDLink lastInitEvents (M4)", .serialized, .timeLimit(.minutes(1)))
struct SimulatedLinkInitReplayTests {
    @Test("The simulated link retains its start-up init the same way")
    func simulated() async throws {
        let link = SimulatedOBDLink(
            rules: LinkTestSupport.benchCar(),
            defaults: LinkTestSupport.defaults(),
            sessionConfiguration: LinkTestSupport.probing,
            backoff: LinkTestSupport.backoff,
            latency: .milliseconds(10)
        )
        let log = LinkEventLog(link.linkEvents())
        link.connect(to: SimulatedBLECentral.adapterID)
        #expect(await eventually { link.state.isPolling && log.readings.count >= 2 })
        #expect(await eventually { log.events.count == link.deliveredLinkEventCount })

        let replay = link.lastInitEvents
        #expect(replay == (try LinkInitReplayTests.initSpan(log.events)))
        #expect(replay.compactMap(\.bleTarget) == [.connecting, .discovering, .connected])
        let exchanges = replay.compactMap(\.exchange)
        #expect(exchanges.first?.tx == "ATZ")
        #expect(exchanges.contains { $0.tx == "ATSH7E0" && $0.outcome == .ok })
        #expect(replay.contains { $0.isAdapter })
        link.disconnect()
    }
}
