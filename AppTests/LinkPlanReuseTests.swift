import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// M6.1-3 (user decision 3), link side: the plan and ATAT level chosen on an
// adapter are carried, in memory, into the next connection's `ELMSession`
// (like `nextSeq`), keyed by the peripheral identifier; the session checks
// the ATZ banner itself. A different adapter, or `forget()`, clears it.
// `disconnect()` keeps it: the adapter stays remembered.

extension LinkEvent {
    /// An ELM note (`from == to`).
    var elmNote: String? {
        if case .session(.state(let from, let to, let reason, _)) = self, from == to { reason } else { nil }
    }
}

@MainActor
@Suite("OBDLinkService remembered poll plan (M6.1-3)", .serialized, .timeLimit(.minutes(1)))
struct LinkPlanReuseTests {
    static let handshake = ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP0", "0100", "ATDPN", "ATRV", "ATSH7E0"]

    static func reuseNote(_ plan: PollingPlan) -> String {
        "poll plan reused from the previous connection: \(plan.primaryCommand.wireFormat), "
            + "ATAT\(plan.adaptiveTiming), requestHeader \(plan.requestHeader?.rawValue ?? "7DF")"
    }

    /// Events of the latest connection, from its `→ connected`.
    static func latestConnection(_ events: [LinkEvent]) -> ArraySlice<LinkEvent> {
        guard let start = events.lastIndex(where: { $0.bleTarget == .connected }) else { return [] }
        return events[start...]
    }

    static func probeTxs(_ events: ArraySlice<LinkEvent>) -> [String] {
        events.compactMap(\.exchange).filter { $0.phase == .probe }.map(\.tx)
    }

    static func reuseNotes(_ events: ArraySlice<LinkEvent>) -> [String] {
        events.compactMap(\.elmNote).filter {
            $0.hasPrefix("poll plan reused") || $0.hasPrefix("remembered poll plan") || $0.hasPrefix("reused plan failed")
        }
    }

    /// Waits for polling on connection number `count` with a few readings.
    static func pollingOnConnection(_ count: Int, _ link: OBDLinkService, _ central: FakeBLECentral, _ log: LinkEventLog) async -> Bool {
        await eventually {
            central.adapters.count == count && link.state.isPolling
                && Self.latestConnection(log.events).contains { if case .session(.reading) = $0 { true } else { false } }
        }
    }

    @Test("A reconnect to the same adapter passes the plan: handshake, one ATATn, one check poll; no selection, no comparison; seq continues")
    func reconnectReuses() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.benchCar()])
        let link = LinkTestSupport.service(central, configuration: LinkTestSupport.probing)
        let log = LinkEventLog(link.linkEvents())
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await Self.pollingOnConnection(1, link, central, log))
        let plan = try #require(link.plan)
        #expect(Self.probeTxs(Self.latestConnection(log.events)).count > 20, "the first connection selects in full")

        await central.loseLink()
        #expect(await Self.pollingOnConnection(2, link, central, log))
        let second = Self.latestConnection(log.events)
        #expect(Self.reuseNotes(second) == [Self.reuseNote(plan)])
        #expect(Self.probeTxs(second) == ["ATAT\(plan.adaptiveTiming)", "010D0C1"])
        #expect(!second.compactMap(\.elmNote).contains { $0.hasPrefix("adaptive timing: ") })
        let sent = await central.adapters[1].sentCommands
        #expect(Array(sent.prefix(12)) == Self.handshake + ["ATAT\(plan.adaptiveTiming)", "010D0C1"])
        #expect(link.plan == plan)
        let adapterPlans = second.compactMap { if case .session(.adapter(let info, _)) = $0 { info.plan } else { nil } }
        #expect(adapterPlans == [plan], "the adapter event carries the plan in use")
        let seqs = log.exchanges.map(\.seq)
        #expect(seqs == Array(seqs.indices), "seq continues across the reconnect")
        #expect(link.rememberedPollPlan?.adapterID == FakeBLECentral.adapterID)
        #expect(link.rememberedPollPlan?.plan.plan == plan)
        link.disconnect()
    }

    @Test("A different adapter clears it: full selection on the new one, and nothing remembered for the old one")
    func differentAdapterClears() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.benchCar()])
        let link = LinkTestSupport.service(central, configuration: LinkTestSupport.probing)
        let log = LinkEventLog(link.linkEvents())
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await Self.pollingOnConnection(1, link, central, log))

        let other = UUID()
        link.connect(to: other)
        #expect(await Self.pollingOnConnection(2, link, central, log))
        let second = Self.latestConnection(log.events)
        #expect(Self.reuseNotes(second).isEmpty)
        #expect(Self.probeTxs(second).count > 20, "selection and the ATAT comparison ran")
        #expect(link.rememberedPollPlan == nil, "the old adapter's plan was dropped; the new one's is kept when its session ends")

        // Back to the first adapter: nothing remembered for it any more.
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await Self.pollingOnConnection(3, link, central, log))
        #expect(Self.reuseNotes(Self.latestConnection(log.events)).isEmpty)
        link.disconnect()
    }

    @Test("disconnect() keeps it; forget() clears it")
    func disconnectKeepsForgetClears() async throws {
        let central = FakeBLECentral(scripts: [LinkTestSupport.benchCar()])
        let link = LinkTestSupport.service(central, configuration: LinkTestSupport.probing)
        let log = LinkEventLog(link.linkEvents())
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await Self.pollingOnConnection(1, link, central, log))
        let plan = try #require(link.plan)

        link.disconnect()
        #expect(await eventually { link.rememberedPollPlan != nil })
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await Self.pollingOnConnection(2, link, central, log))
        #expect(Self.reuseNotes(Self.latestConnection(log.events)) == [Self.reuseNote(plan)])

        link.forget()
        #expect(link.rememberedPollPlan == nil)
        // The session retired by forget() must not store its plan afterwards.
        try await Task.sleep(for: .milliseconds(200))
        #expect(link.rememberedPollPlan == nil)
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await Self.pollingOnConnection(3, link, central, log))
        let third = Self.latestConnection(log.events)
        #expect(Self.reuseNotes(third).isEmpty)
        #expect(Self.probeTxs(third).count > 20)
        link.disconnect()
    }

    @Test("A reused plan that fails on the new connection falls back to selection, and the new selection is what is remembered")
    func failedReuseFallsBack() async throws {
        // Connection 2's adapter answers the first 010D0C1 with NO DATA.
        let second = [MockELMAdapter.Rule(command: "010D0C1", reply: "NO DATA\r\r>", delay: .milliseconds(3), times: 1)]
            + LinkTestSupport.benchCar()
        let central = FakeBLECentral(scripts: [LinkTestSupport.benchCar(), second, LinkTestSupport.benchCar()])
        let link = LinkTestSupport.service(central, configuration: LinkTestSupport.probing)
        let log = LinkEventLog(link.linkEvents())
        link.connect(to: FakeBLECentral.adapterID)
        #expect(await Self.pollingOnConnection(1, link, central, log))
        let plan = try #require(link.plan)

        await central.loseLink()
        #expect(await Self.pollingOnConnection(2, link, central, log))
        let connection2 = Self.latestConnection(log.events)
        #expect(Self.reuseNotes(connection2) == [
            Self.reuseNote(plan),
            "reused plan failed (010D0C1: noData); selecting again",
        ])
        #expect(Self.probeTxs(connection2).count > 20)
        let reselected = try #require(link.plan)

        await central.loseLink()
        #expect(await Self.pollingOnConnection(3, link, central, log))
        #expect(Self.reuseNotes(Self.latestConnection(log.events)) == [Self.reuseNote(reselected)])
        link.disconnect()
    }
}

@MainActor
@Suite("SimulatedOBDLink remembered poll plan (M6.1-3)", .serialized, .timeLimit(.minutes(1)))
struct SimulatedLinkPlanReuseTests {
    @Test("A simulated link loss reconnects with the remembered plan")
    func simulatedReconnectReuses() async throws {
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
        let plan = try #require(link.plan)

        await link.simulateLinkLoss()
        #expect(await eventually {
            log.ble.filter { $0.to == .connected }.count == 2 && link.state.isPolling
                && LinkPlanReuseTests.latestConnection(log.events).contains { if case .session(.reading) = $0 { true } else { false } }
        })
        let second = LinkPlanReuseTests.latestConnection(log.events)
        #expect(LinkPlanReuseTests.reuseNotes(second) == [LinkPlanReuseTests.reuseNote(plan)])
        #expect(LinkPlanReuseTests.probeTxs(second) == ["ATAT\(plan.adaptiveTiming)", "010D0C1"])
        #expect(link.plan == plan)
        link.disconnect()
    }
}
