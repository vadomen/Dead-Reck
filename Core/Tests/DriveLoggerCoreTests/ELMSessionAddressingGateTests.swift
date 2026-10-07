import Foundation
import Testing

@testable import DriveLoggerCore

/// Review R2.1-1: physical addressing (`ATSH7E0`) only on 11-bit ISO 15765-4
/// CAN with an engine (`7E8`) reply to `0100`, and abandoned when it reaches
/// nothing. A 3-digit `ATSH xyz` sets header `00 0x yz`: on 29-bit CAN or a
/// non-CAN protocol that is not an OBD request ID at all.

/// A generic adapter: every AT command OK, `ATDPN` → `dpn`, `0100` →
/// `supported`; mode 01 replies keyed by addressing (`7DF` / `7E0`); every
/// other mode 01 request → `NO DATA`.
func gateCarRules(
    dpn: String,
    supported: String,
    functional: [String: String],
    physical: [String: String] = [:]
) -> [MockELMAdapter.Rule] {
    func rule(_ command: String, _ reply: String, header: String? = nil) -> MockELMAdapter.Rule {
        MockELMAdapter.Rule(command: command, reply: reply, delay: .milliseconds(10), requestHeader: header)
    }
    let mode01 = ["010D0C1", "010D0C", "010D1", "010D", "010C1", "010C"]
    var rules: [MockELMAdapter.Rule] = [
        rule("ATZ", "ATZ\r\r\rELM327 v2.1\r\r>"),
        rule("ATDPN", dpn + "\r\r>"),
        rule("ATRV", "12.4V\r\r>"),
        rule("0100", supported + "\r\r>"),
    ]
    rules += ["ATE0", "ATL0", "ATS0", "ATH1", "ATSP0", "ATAT1", "ATAT2", "ATSH7E0", "ATSH7DF"].map { rule($0, "OK\r\r>") }
    for command in mode01 {
        rules.append(rule(command, (functional[command] ?? "NO DATA") + "\r\r>", header: "7DF"))
        rules.append(rule(command, (physical[command] ?? "NO DATA") + "\r\r>", header: "7E0"))
    }
    return rules
}

@Suite("Physical addressing gate (review R2.1-1)")
struct PhysicalAddressingGateTests {
    static let engine0100 = "SEARCHING...\r7E8064100BE3FA813\r7E906410098180001\r\r"

    @Test("11-bit ISO 15765-4 (6, A6, 8, A8) with a 7E8 reply to 0100 opens the gate", arguments: ["6", "A6", "8", "A8", "a6"])
    func opens(dpn: String) {
        #expect(ELMSession.physicalAddressingSkipReason(protocolNumber: dpn, supportedPIDs: Self.engine0100) == nil)
    }

    @Test("Any other protocol keeps it closed", arguments: ["7", "A7", "9", "A9", "1", "2", "3", "A3", "4", "5", "A5", "B", "0", "", "A"])
    func otherProtocols(dpn: String) {
        #expect(
            ELMSession.physicalAddressingSkipReason(protocolNumber: dpn, supportedPIDs: Self.engine0100)
                == "ATSH7E0 skipped: protocol \(dpn) is not 11-bit ISO 15765-4 CAN (6, A6, 8, A8); requests stay functional (7DF), no response-count suffix"
        )
    }

    @Test("0100 without a positive 7E8 line keeps it closed", arguments: [
        "7E906410098180001\r\r",                       // gearbox only
        "18DAF110064100BE3FA813\r\r",                   // 29-bit engine
        "7E803410D3C\r\r",                              // 7E8, but not 41 00
        "7E8037F0112\r\r",                              // 7E8 negative response
        "NO DATA\r\r",
    ] as [String?] + [nil])
    func noEngineReply(supported: String?) {
        #expect(
            ELMSession.physicalAddressingSkipReason(protocolNumber: "A6", supportedPIDs: supported)
                == "ATSH7E0 skipped: no 7E8 reply to 0100; requests stay functional (7DF), no response-count suffix"
        )
    }

    @Test("handshake is the unconditional steps; ATSH7E0 is separate")
    func handshakeList() {
        #expect(ELM327Command.handshake.map(\.wireFormat) == ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP0", "0100", "ATDPN", "ATRV"])
        #expect(ELM327Command.physicalAddressing == .setHeader(.engine))
        #expect(ELM327Command.physicalAddressing.wireFormat == "ATSH7E0")
    }
}

@Suite("ELMSession physical addressing gate (review R2.1-1)", .timeLimit(.minutes(1)))
struct ELMSessionAddressingGateTests {
    static let probing = ELMSessionProbeTests.probing
    static let unconditionalWires = Array(handshakeWires.dropLast())

    /// Index just past the last `ATSHxxx` of `header` in `sent`, or 0.
    static func after(_ wire: String, in sent: [String]) -> Int {
        sent.lastIndex(of: wire).map { $0 + 1 } ?? 0
    }

    // Reviewer's probe: protocol A7 (29-bit 500k), engine answers 0100 as
    // 18DAF110, every physical request NO DATA. Before the fix: ATSH7E0 OK,
    // a 7E0 baseline plan, then "every polled PID answered NO DATA".
    @Test("29-bit car: no ATSH7E0, a note, functional selection, and polling yields readings")
    func twentyNineBit() async throws {
        let harness = SessionHarness(
            rules: gateCarRules(
                dpn: "A7",
                supported: "SEARCHING...\r18DAF110064100BE3FA813",
                functional: [
                    "010D0C": "18DAF11006410D3C0C0BB8",
                    "010D": "18DAF11003410D3C",
                    "010C": "18DAF11004410C0BB8",
                ]
            ),
            configuration: Self.probing
        )
        let info = try await harness.initialise()
        let sent = await harness.mock.sentCommands
        #expect(!sent.contains { $0.hasPrefix("ATSH") })
        #expect(Array(sent.prefix(9)) == Self.unconditionalWires)
        #expect(await harness.log.transitions.contains {
            $0.from == $0.to && $0.reason == "ATSH7E0 skipped: protocol A7 is not 11-bit ISO 15765-4 CAN (6, A6, 8, A8); "
                + "requests stay functional (7DF), no response-count suffix"
        })
        #expect(info.plan.requestHeader == nil)
        #expect(info.plan.primaryCommand.wireFormat == "010D0C")

        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.readings.count >= 4 }
        try await harness.stopPolling()
        let readings = await harness.log.readings
        #expect(readings.allSatisfy { $0.ecu == "18DAF110" && $0.isFromPrimaryECU })
        #expect(readings.contains { $0.measurement == OBDMeasurement(pid: .vehicleSpeed, value: 60, unit: .kilometersPerHour) })
        #expect(!(await harness.mock.sentCommands.contains { $0.hasPrefix("ATSH") || hasResponseCountSuffix($0) }))
    }

    @Test("11-bit car whose 7E0 answers nothing: ATSH7DF, functional selection, readings, no suffix while functional")
    func physicalReachesNothing() async throws {
        let harness = SessionHarness(
            rules: gateCarRules(
                dpn: "A6",
                supported: PhysicalAddressingGateTests.engine0100,
                functional: ["010D0C": "7E806410D3C0C0BB8\r7E906410D3B0C0BB8"]
            ),
            configuration: Self.probing
        )
        let info = try await harness.initialise()
        #expect(info.plan.requestHeader == nil)
        #expect(info.plan.primaryCommand.wireFormat == "010D0C")
        #expect(info.plan.pids == [.vehicleSpeed, .engineSpeed], "PIDs dropped under 7E0 get a fresh chance")

        let sent = await harness.mock.sentCommands
        #expect(Array(sent.prefix(10)) == handshakeWires, "the gate is open: ATSH7E0 is sent")
        let functionalFrom = Self.after("ATSH7DF", in: sent)
        #expect(functionalFrom > 10, "ATSH7DF sent after the physical selection")
        #expect(!sent[functionalFrom...].contains(where: hasResponseCountSuffix))
        #expect(await harness.log.exchanges.first { $0.tx == "ATSH7DF" }?.phase == .probe)
        #expect(await harness.log.transitions.contains {
            $0.from == $0.to && $0.reason?.hasPrefix("no poll command parsed with physical addressing (7E0)") == true
        })
        #expect(await harness.mock.requestHeader == "7DF")

        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.readings.count >= 4 }
        try await harness.stopPolling()
        let primary = await harness.log.readings.filter { $0.isFromPrimaryECU }
        #expect(!primary.isEmpty)
        #expect(primary.allSatisfy { $0.ecu == "7E8" })
        #expect(primary.filter { $0.measurement.pid == .vehicleSpeed }.allSatisfy { $0.measurement.value == 60 })
        let all = await harness.mock.sentCommands
        #expect(!all[functionalFrom...].contains(where: hasResponseCountSuffix))
        #expect(all.filter { $0 == "ATSH7E0" }.count == 1, "physical addressing is not re-applied while polling")
    }

    // 7E0 answers RPM but never speed: a physical plan would have polled
    // RPM alone for the whole drive.
    @Test("Physical selection that keeps only RPM is abandoned: functional selection keeps speed")
    func physicalWithoutSpeedAbandoned() async throws {
        let harness = SessionHarness(
            rules: gateCarRules(
                dpn: "A6",
                supported: PhysicalAddressingGateTests.engine0100,
                functional: ["010D0C": "7E806410D3C0C0BB8\r7E906410D3B0C0BB8"],
                physical: ["010C1": "7E804410C0BB8", "010C": "7E804410C0BB8"]
            ),
            configuration: Self.probing
        )
        let info = try await harness.initialise()
        #expect(info.plan.pids == [.vehicleSpeed, .engineSpeed])
        #expect(info.plan.primaryCommand.wireFormat == "010D0C")
        #expect(info.plan.requestHeader == nil)
        #expect(await harness.mock.sentCommands.contains("ATSH7DF"))
    }

    @Test("0100 without a 7E8 line: ATSH7E0 skipped, a note, functional plan")
    func noEngineIn0100() async throws {
        let harness = SessionHarness(
            rules: gateCarRules(
                dpn: "A6",
                supported: "7E906410098180001",
                functional: ["010D0C": "7E806410D3C0C0BB8\r7E906410D3B0C0BB8"]
            ),
            configuration: Self.probing
        )
        let info = try await harness.initialise()
        #expect(!(await harness.mock.sentCommands.contains { $0.hasPrefix("ATSH") }))
        #expect(await harness.log.transitions.contains {
            $0.reason == "ATSH7E0 skipped: no 7E8 reply to 0100; requests stay functional (7DF), no response-count suffix"
        })
        #expect(info.plan.requestHeader == nil)
        #expect(info.plan.primaryCommand.wireFormat == "010D0C")
    }

    @Test("Bench car, ATDPN A6 (after our ATSP0) or 6 (verbatim): unchanged, 010D0C1 at 7E0", arguments: ["A6", "6"])
    func benchCarUnchanged(dpn: String) async throws {
        let rules = [MockELMAdapter.Rule(command: "ATDPN", reply: dpn + "\r\r>", delay: .milliseconds(30))]
            + MockELMAdapter.Rule.benchCar
        let harness = SessionHarness(rules: rules, configuration: Self.probing)
        let info = try await harness.initialise()
        #expect(info.protocolNumber == dpn)
        #expect(info.plan.primaryCommand.wireFormat == "010D0C1")
        #expect(info.plan.requestHeader == .engine)
        #expect(Array(await harness.mock.sentCommands.prefix(10)) == handshakeWires)
        #expect(!(await harness.mock.sentCommands.contains("ATSH7DF")))
    }

    @Test("The bench script answers ATDPN with A6, as an ELM327 does after ATSP0")
    func benchScriptA6() async throws {
        let harness = SessionHarness(rules: MockELMAdapter.Rule.benchCar, configuration: Self.probing)
        #expect(try await harness.initialise().protocolNumber == "A6")
    }

    // The engine stops answering 0100 at a re-init: the gate closes, ATSH7E0
    // is not sent, and the physical plan degrades to functional without
    // the suffix instead of re-sending ATSH7E0 from the poll loop.
    @Test("A re-init re-evaluates the gate: closed → no ATSH7E0, the plan degrades to functional, readings resume")
    func reinitReevaluatesGate() async throws {
        let harness = SessionHarness(
            rules: [
                .init(command: "0100", reply: "SEARCHING...\r7E8064100BE3FA813\r7E906410098180001\r\r>", delay: .milliseconds(30), times: 1),
                .init(command: "0100", reply: "7E906410098180001\r\r>", delay: .milliseconds(30)),
                .init(command: "010D0C1", reply: "7E806410D3C0C0BB8\r\r>", delay: .milliseconds(30), times: 6, requestHeader: "7E0"),
                .init(command: "010D0C1", reply: "CAN ERROR\r\r>", delay: .milliseconds(30), times: 3, requestHeader: "7E0"),
            ] + MockELMAdapter.Rule.touareg,
            configuration: Self.probing
        )
        let info = try await harness.initialise()
        #expect(info.plan.primaryCommand.wireFormat == "010D0C1")
        #expect(info.plan.requestHeader == .engine)
        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.readings.count >= 6 }
        try await harness.stopPolling()

        let sent = await harness.mock.sentCommands
        let reinitATZ = try #require(sent.indices.dropFirst().first { sent[$0] == "ATZ" })
        let afterReinit = Array(sent[reinitATZ...])
        #expect(Array(afterReinit.prefix(9)) == Self.unconditionalWires)
        #expect(!afterReinit.contains { $0.hasPrefix("ATSH7E0") || hasResponseCountSuffix($0) })
        #expect(afterReinit.dropFirst(9).first == "010D0C")
        let notes = await harness.log.transitions.filter { $0.from == $0.to }.compactMap(\.reason)
        #expect(notes.contains("ATSH7E0 skipped: no 7E8 reply to 0100; requests stay functional (7DF), no response-count suffix"))
        #expect(notes.contains { $0.hasPrefix("physical addressing unavailable") })
        let latest = try #require(await harness.log.adapterInfos.last)
        #expect(latest.plan.requestHeader == nil)
        #expect(latest.plan.responseCount == nil)
        #expect(latest.plan.multiPID)
        #expect(await harness.log.readings.last?.command == "010D0C")
    }

    // startPolling with a physical plan on a car where the gate is closed:
    // the poll loop must not send ATSH7E0 to reconcile.
    @Test("A physical plan on a gate-closed car is polled functionally, never ATSH7E0")
    func physicalPlanGateClosed() async throws {
        let harness = SessionHarness(
            rules: gateCarRules(
                dpn: "A7",
                supported: "18DAF110064100BE3FA813",
                functional: ["010D0C": "18DAF11006410D3C0C0BB8"]
            )
        )
        _ = try await harness.initialise()
        let plan = PollingPlan(
            pids: [.vehicleSpeed, .engineSpeed], multiPID: true, responseCount: 1,
            adaptiveTiming: 1, rpmEvery: 5, timeout: .milliseconds(100), requestHeader: .engine
        )
        try await harness.session.startPolling(plan)
        await harness.run { await $0.readings.count >= 2 }
        try await harness.stopPolling()
        let sent = await harness.mock.sentCommands
        #expect(!sent.contains { $0.hasPrefix("ATSH") || hasResponseCountSuffix($0) })
        #expect(Set(await harness.pollCommands) == ["010D0C"])
    }
}
