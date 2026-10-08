import Foundation
import Testing

@testable import DriveLoggerCore

/// `ELMSession` against `MockELMAdapter.Rule.benchCar`, the adapter and car
/// as transcribed on the bench (docs/BENCH_TEST_2026-10-07.md): init ends
/// with `ATSH7E0`, start-up selection tries `010D0C1` → `010D0C` → `010D1` →
/// `010D`, and the response-count suffix is never sent without physical
/// addressing.

/// A mode 01 request with the response-count suffix (`010D1`, `010D0C1`).
func hasResponseCountSuffix(_ wire: String) -> Bool {
    wire.hasPrefix("01") && !wire.count.isMultiple(of: 2)
}

/// First occurrences, in order.
func distinctInOrder(_ items: [String]) -> [String] {
    var seen: Set<String> = []
    return items.filter { seen.insert($0).inserted }
}

/// A rule answering `command` only while the mock's request header is
/// `header`, after 30 ms.
func benchRule(_ command: String, _ reply: String?, header: String? = nil, times: Int? = nil) -> MockELMAdapter.Rule {
    MockELMAdapter.Rule(command: command, reply: reply, delay: .milliseconds(30), times: times, requestHeader: header)
}

let refuseATSH7E0 = benchRule("ATSH7E0", "?\r\r>")

extension SessionHarness {
    /// Mode 01 commands sent in the probe phase, in order.
    var probedCommands: [String] {
        get async {
            await log.exchanges.filter { $0.phase == .probe && $0.tx.hasPrefix("01") }.map(\.tx)
        }
    }
}

@Suite("ELMSession on the bench car: init and selection", .timeLimit(.minutes(1)))
struct ELMSessionBenchInitTests {
    static let probing = ELMSessionProbeTests.probing

    @Test("Full init ends with ATSH7E0 OK and selects 010D0C1 with physical addressing")
    func selects010D0C1() async throws {
        let harness = SessionHarness(rules: MockELMAdapter.Rule.benchCar, configuration: Self.probing)
        let info = try await harness.initialise()

        #expect(info.elmVersion == "ELM327 v2.3")
        #expect(info.protocolNumber == "A6", "the script answers A6, as after our own ATSP0")
        #expect(info.voltage == 11.0, "ATRV is read before ATSH7E0, under functional addressing")
        #expect(info.supportedPIDs == BenchTranscript.supportedPIDs0100)
        #expect(info.plan == PollingPlan(
            pids: [.vehicleSpeed, .engineSpeed], multiPID: true, responseCount: 1,
            adaptiveTiming: 1, rpmEvery: 5, timeout: .milliseconds(200), requestHeader: .engine
        ))
        #expect(info.plan.primaryCommand.wireFormat == "010D0C1")
        #expect(PollingRecord(info.plan).requestHeader == "7E0")

        let sent = await harness.mock.sentCommands
        #expect(Array(sent.prefix(10)) == handshakeWires)
        #expect(handshakeWires.last == "ATSH7E0")
        let atsh = try #require(await harness.log.exchanges.first { $0.tx == "ATSH7E0" })
        #expect(atsh.outcome == .ok)
        #expect(atsh.rx == BenchTranscript.atsh7E0)
        #expect(atsh.phase == .initialisation)
        #expect(await harness.mock.requestHeader == "7E0")
        #expect(await harness.probedCommands.first == "010D0C1")
        #expect(Set(await harness.probedCommands) == ["010D0C1"])
        #expect(!(await harness.log.transitions.contains { $0.reason?.contains("ATSH") == true }))
        #expect(await harness.log.adapterInfos == [info])
        #expect(await harness.session.state == .ready)
    }

    @Test("ATSH7E0 refused (?): 010D0C without the suffix, a note, and init still succeeds")
    func refusedHeaderFallsBackToFunctional() async throws {
        let harness = SessionHarness(rules: [refuseATSH7E0] + MockELMAdapter.Rule.benchCar, configuration: Self.probing)
        let info = try await harness.initialise()

        #expect(info.plan == PollingPlan(
            pids: [.vehicleSpeed, .engineSpeed], multiPID: true, responseCount: nil,
            adaptiveTiming: 1, rpmEvery: 5, timeout: .milliseconds(200), requestHeader: nil
        ))
        #expect(info.plan.primaryCommand.wireFormat == "010D0C")
        #expect(PollingRecord(info.plan).requestHeader == nil)
        let note = try #require(await harness.log.transitions.first { $0.reason?.hasPrefix("ATSH7E0") == true })
        #expect(note.from == note.to)
        #expect(note.reason == "ATSH7E0 not accepted (notRecognised); requests stay functional (7DF), no response-count suffix")
        #expect(await harness.log.exchanges.first { $0.tx == "ATSH7E0" }?.outcome == .notRecognised)
        #expect(await harness.session.state == .ready)
        #expect(await harness.mock.requestHeader == "7DF")
        #expect(!(await harness.mock.sentCommands.contains(where: hasResponseCountSuffix)))
        #expect(await harness.probedCommands.first == "010D0C")
    }

    @Test(
        "Physical addressing: each fallback step is taken when the earlier ones don't parse",
        arguments: [
            // 010D0C1 refused → 010D0C.
            (
                [benchRule("010D0C1", "?\r\r>"), benchRule("010D0C", "7E806410D000C0A5C\r\r>", header: "7E0")],
                "010D0C", ["010D0C1", "010D0C"]
            ),
            // 010D0C1 answered by the wrong ECU only, 010D0C NO DATA → 010D1 (+ 010C1).
            (
                [
                    benchRule("010D0C1", "7E906410D000C0000\r\r>", header: "7E0"),
                    benchRule("010D0C", "NO DATA\r\r>", header: "7E0"),
                    benchRule("010C1", "7E804410C0A5C\r\r>", header: "7E0"),
                ],
                "010D1", ["010D0C1", "010D0C", "010D1", "010C1"]
            ),
            // Multi-PID and the suffix all fail → 010D (+ 010C).
            (
                [
                    benchRule("010D0C1", "CAN ERROR\r\r>", header: "7E0"),
                    benchRule("010D0C", "?\r\r>", header: "7E0"),
                    benchRule("010D1", "?\r\r>", header: "7E0"),
                    benchRule("010D", "7E803410D00\r\r>", header: "7E0"),
                    benchRule("010C", "7E804410C0A5C\r\r>", header: "7E0"),
                ],
                "010D", ["010D0C1", "010D0C", "010D1", "010D", "010C"]
            ),
            // A reply with 7E8's speed but no RPM doesn't count for 010D0C1.
            (
                [
                    benchRule("010D0C1", "7E803410D00\r\r>", header: "7E0"),
                    benchRule("010D0C", "7E806410D000C0A5C\r\r>", header: "7E0"),
                ],
                "010D0C", ["010D0C1", "010D0C"]
            ),
        ] as [([MockELMAdapter.Rule], String, [String])]
    )
    func physicalFallbacks(overrides: [MockELMAdapter.Rule], chosen: String, order: [String]) async throws {
        let harness = SessionHarness(rules: overrides + MockELMAdapter.Rule.benchCar, configuration: Self.probing)
        let info = try await harness.initialise()
        #expect(info.plan.primaryCommand.wireFormat == chosen)
        #expect(info.plan.requestHeader == .engine)
        #expect(info.plan.pids == [.vehicleSpeed, .engineSpeed])
        #expect(distinctInOrder(await harness.probedCommands) == order)
    }

    @Test("Functional addressing: 010D0C → 010D, and no suffix step is ever tried")
    func functionalFallback() async throws {
        let harness = SessionHarness(
            rules: [
                refuseATSH7E0,
                benchRule("010D0C", "?\r\r>", header: "7DF"),
                // Not transcribed: RPM alone, both ECUs.
                benchRule("010C", "7E904410C0000\r7E804410C0000\r\r>", header: "7DF"),
            ] + MockELMAdapter.Rule.benchCar,
            configuration: Self.probing
        )
        let info = try await harness.initialise()
        #expect(info.plan.primaryCommand.wireFormat == "010D")
        #expect(info.plan.multiPID == false)
        #expect(info.plan.responseCount == nil)
        #expect(info.plan.requestHeader == nil)
        #expect(distinctInOrder(await harness.probedCommands) == ["010D0C", "010D", "010C"])
        #expect(!(await harness.mock.sentCommands.contains(where: hasResponseCountSuffix)))
    }

    @Test("Functional addressing and nothing parses: the baseline plan, functional, no suffix")
    func functionalNothingParses() async throws {
        let harness = SessionHarness(
            rules: [refuseATSH7E0, benchRule("010D0C", "?\r\r>"), benchRule("010D", "?\r\r>")]
                + MockELMAdapter.Rule.benchCar,
            configuration: Self.probing
        )
        let info = try await harness.initialise()
        var expected = PollingPlan.baseline
        expected.timeout = .milliseconds(200)
        #expect(info.plan == expected)
        #expect(!(await harness.mock.sentCommands.contains(where: hasResponseCountSuffix)))
    }

    @Test("Without probing the plan is the functional baseline, whatever ATSH7E0 answered", arguments: [true, false])
    func noProbe(accepted: Bool) async throws {
        let rules = (accepted ? [] : [refuseATSH7E0]) + MockELMAdapter.Rule.benchCarInstant
        let harness = SessionHarness(rules: rules)
        let info = try await harness.initialise()
        #expect(await harness.mock.requestHeader == (accepted ? "7E0" : "7DF"))
        #expect(info.plan.requestHeader == nil)
        #expect(info.plan.responseCount == nil)
        #expect(info.plan.primaryCommand.wireFormat == "010D")
    }

    // ATSH7E0 answers after its timeout but within the grace period: the
    // late OK is paid to it, so the adapter is physically addressed after all.
    @Test("A late OK for ATSH7E0 is believed: noted, and selection uses physical addressing")
    func lateOK() async throws {
        let harness = SessionHarness(
            rules: [benchRule("ATSH7E0", "OK\r\r>", times: 1).with(delay: .milliseconds(250))] + MockELMAdapter.Rule.benchCar,
            configuration: Self.probing
        )
        let info = try await harness.initialise()
        let reasons = await harness.log.transitions.filter { $0.from == $0.to }.compactMap(\.reason)
        #expect(reasons.contains("ATSH7E0 not accepted (timeout); requests stay functional (7DF), no response-count suffix"))
        #expect(reasons.contains("late OK for ATSH7E0; requests go to 7E0"))
        #expect(info.plan.requestHeader == .engine)
        #expect(info.plan.primaryCommand.wireFormat == "010D0C1")
        let late = try #require(await harness.log.exchanges.first { $0.tx == "ATSH7E0" && $0.rx != nil })
        #expect(late.outcome == .timeout)
        #expect(late.rx == "OK\r\r")
    }
}

@Suite("ELMSession on the bench car: polling and re-init", .timeLimit(.minutes(1)))
struct ELMSessionBenchPollingTests {
    static let probing = ELMSessionProbeTests.probing

    @Test("Polling 010D0C1: one 7E8 reading each of speed 0 and RPM 663 per cycle, all primary")
    func pollsSelectedPlan() async throws {
        let harness = SessionHarness(rules: MockELMAdapter.Rule.benchCar, configuration: Self.probing)
        let info = try await harness.initialise()
        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.readings.count >= 6 }
        try await harness.stopPolling()

        #expect(Set(await harness.pollCommands) == ["010D0C1"])
        let readings = await harness.log.readings
        #expect(readings.allSatisfy { $0.ecu == "7E8" && $0.isFromPrimaryECU })
        #expect(readings.filter { $0.measurement.pid == .vehicleSpeed }.allSatisfy { $0.measurement.value == 0 })
        #expect(readings.filter { $0.measurement.pid == .engineSpeed }.allSatisfy { $0.measurement.value == 663 })
        #expect(readings.allSatisfy { $0.raw == BenchTranscript.speedRPMPhysicalSuffix010D0C1 })
        #expect(await harness.log.adapterInfos.count == 1, "the selected plan was already announced")
    }

    @Test("Functional polling, verbatim: both ECUs are recorded; the primary reading is 7E8's")
    func functionalVerbatim() async throws {
        let harness = SessionHarness(rules: [refuseATSH7E0] + MockELMAdapter.Rule.benchCar, configuration: Self.probing)
        let info = try await harness.initialise()
        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.readings.count >= 8 }
        try await harness.stopPolling()

        let readings = await harness.log.readings
        let bySeq = Dictionary(grouping: readings, by: \.seq)
        for (_, group) in bySeq where group.count == 4 {
            #expect(group.map(\.ecu) == ["7E9", "7E9", "7E8", "7E8"])
        }
        #expect(readings.filter { $0.isFromPrimaryECU }.allSatisfy { $0.ecu == "7E8" })
        #expect(readings.filter { $0.isFromPrimaryECU }.count * 2 == readings.count)
    }

    @Test("Functional polling, synthetic: 7E9 answers first with 0, 7E8 with 60 km/h; the primary speed is 60")
    func functionalDifferentSpeeds() async throws {
        let harness = SessionHarness(
            rules: [refuseATSH7E0, benchRule("010D0C", "7E906410D000C0000\r7E806410D3C0C0A5C\r\r>", header: "7DF")]
                + MockELMAdapter.Rule.benchCar,
            configuration: Self.probing
        )
        let info = try await harness.initialise()
        #expect(info.plan.primaryCommand.wireFormat == "010D0C")
        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.readings.count >= 8 }
        try await harness.stopPolling()

        let speeds = await harness.log.readings.filter { $0.measurement.pid == .vehicleSpeed }
        #expect(speeds.first?.ecu == "7E9", "arrival order alone would pick the gearbox")
        #expect(speeds.filter { $0.isFromPrimaryECU }.map(\.measurement.value).allSatisfy { $0 == 60 })
        #expect(speeds.filter { !$0.isFromPrimaryECU }.map(\.measurement.value).allSatisfy { $0 == 0 })
        #expect(!speeds.filter { $0.isFromPrimaryECU }.isEmpty)
    }

    @Test("A re-init re-applies ATSH7E0 and polling resumes with 010D0C1 (after failures or a write-off)", arguments: [false, true])
    func reinitReappliesHeader(writeOff: Bool) async throws {
        // Init sends 010D0C1 `probeSendsOfChosenCommand` times: selection's
        // samples, then the ATAT1/ATAT2 comparison's.
        let failure = writeOff ? benchRule("010D0C1", nil, header: "7E0", times: 1)
            : benchRule("010D0C1", "CAN ERROR\r\r>", header: "7E0", times: 3)
        let harness = SessionHarness(
            rules: [
                benchRule("010D0C1", BenchTranscript.speedRPMPhysicalSuffix010D0C1 + ">", header: "7E0", times: probeSendsOfChosenCommand),
                failure,
            ] + MockELMAdapter.Rule.benchCar,
            configuration: Self.probing
        )
        let info = try await harness.initialise()
        #expect(await harness.mock.sentCommands.filter { $0 == "010D0C1" }.count == probeSendsOfChosenCommand)
        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.readings.count >= 2 }
        try await harness.stopPolling()

        let sent = await harness.mock.sentCommands
        let reinitATZ = try #require(sent.indices.dropFirst().first { sent[$0] == "ATZ" })
        #expect(Array(sent[reinitATZ...].prefix(11)) == handshakeWires + ["010D0C1"])
        #expect(!sent[reinitATZ...].contains { $0.hasPrefix("ATSH") && $0 != "ATSH7E0" })
        #expect(await harness.mock.requestHeader == "7E0")
        #expect(await harness.log.states.contains(.reinitialising))
        #expect(await harness.log.adapterInfos.last?.plan == info.plan)
        let readings = await harness.log.readings
        #expect(readings.allSatisfy { $0.ecu == "7E8" })
        #expect(readings.contains { $0.measurement == OBDMeasurement(pid: .engineSpeed, value: 663, unit: .revolutionsPerMinute) })
    }

    @Test("Physical plan, ATSH7E0 refused on re-init: escalates to failed; the suffix never goes out unaddressed")
    func reinitHeaderRefused() async throws {
        let harness = SessionHarness(
            rules: [
                benchRule("010D0C1", BenchTranscript.speedRPMPhysicalSuffix010D0C1 + ">", header: "7E0", times: probeSendsOfChosenCommand),
                benchRule("010D0C1", "CAN ERROR\r\r>", header: "7E0", times: 3),
                benchRule("ATSH7E0", "OK\r\r>", times: 1),
                refuseATSH7E0,
            ] + MockELMAdapter.Rule.benchCar,
            configuration: Self.probing
        )
        let info = try await harness.initialise()
        #expect(info.plan.primaryCommand.wireFormat == "010D0C1")
        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.reconnectRequests == 1 }

        let sent = await harness.mock.sentCommands
        let reinitATZ = try #require(sent.indices.dropFirst().first { sent[$0] == "ATZ" })
        #expect(!sent[reinitATZ...].contains(where: hasResponseCountSuffix))
        #expect(sent[reinitATZ...].filter { $0 == "ATSH7E0" }.count > 1, "the poll loop asks for the plan's header again")
        #expect(await harness.mock.requestHeader == "7DF")
        #expect(await harness.session.state == .failed)
        #expect(await harness.log.transitions.contains { $0.to == .retrying && $0.reason == "ATSH7E0: notRecognised" })
    }

    @Test("Functional plan, ATSH7E0 accepted on re-init: ATSH7DF restores functional addressing before polling")
    func reinitRestoresFunctional() async throws {
        let harness = SessionHarness(
            rules: [
                benchRule("ATSH7E0", "?\r\r>", times: 1),
                benchRule("010D", "CAN ERROR\r\r>", header: "7DF", times: 3),
            ] + MockELMAdapter.Rule.benchCarInstant
        )
        let info = try await harness.initialise()
        #expect(info.plan.requestHeader == nil)
        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.readings.count >= 2 }
        try await harness.stopPolling()

        let sent = await harness.mock.sentCommands
        let reinitATZ = try #require(sent.indices.dropFirst().first { sent[$0] == "ATZ" })
        #expect(Array(sent[reinitATZ...].prefix(12)) == handshakeWires + ["ATSH7DF", "010D"])
        #expect(await harness.mock.requestHeader == "7DF")
        #expect(await harness.log.adapterInfos.last?.plan.requestHeader == nil)
        #expect(await harness.log.exchanges.first { $0.tx == "ATSH7DF" }?.phase == .poll)
    }

    @Test("A suffix plan on an adapter that refused ATSH7E0: ATSH7E0 is retried, 010D0C1 is never sent")
    func suffixPlanOnFunctionalAdapter() async throws {
        let harness = SessionHarness(rules: [refuseATSH7E0] + MockELMAdapter.Rule.benchCarInstant)
        _ = try await harness.initialise()
        let plan = PollingPlan(
            pids: [.vehicleSpeed, .engineSpeed], multiPID: true, responseCount: 1,
            adaptiveTiming: 1, rpmEvery: 5, timeout: .milliseconds(100), requestHeader: .engine
        )
        try await harness.session.startPolling(plan)
        await harness.run { await $0.reconnectRequests == 1 }
        let sent = await harness.mock.sentCommands
        #expect(!sent.contains(where: hasResponseCountSuffix))
        #expect(sent.dropFirst(10).first == "ATSH7E0")
        #expect(await harness.session.state == .failed)
    }

    // Defence in depth: beginPolling skips validate(), so the poll loop
    // itself must refuse a suffix without physical addressing.
    @Test("A suffix plan without a request header that slips past validate() is refused, never sent")
    func suffixWithoutHeaderRefused() async throws {
        let harness = SessionHarness(rules: [refuseATSH7E0] + MockELMAdapter.Rule.benchCarInstant)
        _ = try await harness.initialise()
        let plan = PollingPlan(
            pids: [.vehicleSpeed, .engineSpeed], multiPID: true, responseCount: 1,
            adaptiveTiming: 1, rpmEvery: 5, timeout: .milliseconds(100)
        )
        #expect(throws: ELMSessionError.self) { try plan.validate() }
        try await harness.session.beginPolling(plan)
        await harness.run { await $0.states.last == .failed }
        await harness.clock.advance(by: .seconds(2))

        #expect(await harness.mock.sentCommands == handshakeWires)
        let rejected = try #require(await harness.log.exchanges.last)
        #expect(rejected.tx == "010D0C1")
        #expect(rejected.outcome == .rejected)
        #expect(rejected.phase == .poll)
        #expect(await harness.log.transitions.last?.reason?.contains("physical addressing") == true)
        #expect(await harness.log.reconnectRequests == 0)
    }

    @Test("22F40D from the console is rejected and never reaches the adapter")
    func modeTwentyTwoRejected() async throws {
        let harness = SessionHarness(rules: MockELMAdapter.Rule.benchCarInstant)
        _ = try await harness.initialise()
        await #expect(throws: ELMSessionError.forbiddenCommand("22F40D")) {
            _ = try await harness.session.sendManual("22F40D")
        }
        #expect(!(await harness.mock.sentCommands.contains("22F40D")))
        await harness.run { await $0.exchanges.last?.outcome == .rejected }
        #expect(await harness.log.exchanges.last?.tx == "22F40D")
    }

    @Test("ATSH can't be typed in the console, even mid-session", arguments: ["ATSH7E0", "ATSH7DF", "atsh7e1"])
    func consoleCannotReaddress(command: String) async throws {
        let harness = SessionHarness(rules: MockELMAdapter.Rule.benchCarInstant)
        _ = try await harness.initialise()
        await #expect(throws: ELMSessionError.forbiddenCommand(command)) {
            _ = try await harness.session.sendManual(command)
        }
        #expect(await harness.mock.sentCommands == handshakeWires)
        #expect(await harness.mock.requestHeader == "7E0")
    }
}

extension MockELMAdapter.Rule {
    func with(delay: Duration) -> MockELMAdapter.Rule {
        var rule = self
        rule.delay = delay
        return rule
    }
}
