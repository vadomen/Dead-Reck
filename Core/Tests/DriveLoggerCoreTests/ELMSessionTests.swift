import Foundation
import Testing

@testable import DriveLoggerCore

/// A session wired to a mock adapter on a virtual clock.
struct SessionHarness {
    let clock: TestClock
    let mock: MockELMAdapter
    let session: ELMSession
    let log: EventLog

    init(
        rules: [MockELMAdapter.Rule] = MockELMAdapter.Rule.touaregInstant,
        configuration: ELMSessionConfiguration = .fastTest,
        firstSeq: Int = 0
    ) {
        clock = TestClock()
        mock = MockELMAdapter(rules: rules, uptime: clock, clock: clock)
        session = ELMSession(transport: mock, configuration: configuration, uptime: clock, clock: clock, firstSeq: firstSeq)
        log = EventLog.start(session.events)
    }

    func initialise() async throws -> ELMAdapterInfo {
        let session = session
        return try await drive(clock) { try await session.initialise() }
    }

    /// Runs until `condition` holds on the event log; fails the test if it never does.
    func run(
        until condition: @escaping @Sendable (EventLog) async -> Bool,
        limit: Duration = .seconds(60),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let log = log
        let reached = await driveUntil(clock, limit: limit) { await condition(log) }
        #expect(reached, "condition not reached within \(limit) of virtual time", sourceLocation: sourceLocation)
    }

    /// `stopPolling()` waits for the command in flight, which needs virtual
    /// time to pass, so it has to run under `drive`.
    func stopPolling() async throws {
        let session = session
        try await drive(clock) { await session.stopPolling() }
    }

    var pollCommands: [String] {
        get async { await mock.sentCommands.filter { $0.hasPrefix("01") && $0 != "0100" } }
    }
}

/// Fast replies with a small delay, so the poll loop is paced by the clock.
func pacedRules(
    _ overrides: [MockELMAdapter.Rule] = [],
    delay: Duration = .milliseconds(10)
) -> [MockELMAdapter.Rule] {
    overrides + MockELMAdapter.Rule.touareg.map { rule in
        var rule = rule
        rule.delay = delay
        return rule
    }
}

func singlePlan(
    _ pids: [OBDPID] = [.vehicleSpeed, .engineSpeed],
    responseCount: Int? = nil,
    rpmEvery: Int = 5,
    timeout: Duration = .milliseconds(100),
    requestHeader: CANRequestHeader? = .engine
) -> PollingPlan {
    PollingPlan(
        pids: pids, multiPID: false, responseCount: responseCount, adaptiveTiming: 1, rpmEvery: rpmEvery,
        timeout: timeout, requestHeader: requestHeader
    )
}

let handshakeWires = ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP0", "0100", "ATDPN", "ATRV", "ATSH7E0"]

@Suite("ELMSession initialisation", .timeLimit(.minutes(1)))
struct ELMSessionInitTests {
    @Test("Runs the handshake, records every exchange and transition, reports the adapter")
    func handshake() async throws {
        let harness = SessionHarness()
        let info = try await harness.initialise()

        #expect(info.elmVersion == "ELM327 v2.1")
        #expect(info.protocolNumber == "A6")
        #expect(info.voltage == 12.4)
        #expect(info.supportedPIDs == "SEARCHING...\r7E8064100BE3FA813\r7E906410098180001\r\r")
        #expect(info.plan == singlePlan(requestHeader: nil), "without probing: the functional baseline")
        #expect(await harness.mock.sentCommands == handshakeWires)
        #expect(await harness.session.state == .ready)

        await harness.run { await $0.adapterInfos.count == 1 }
        let exchanges = await harness.log.exchanges
        #expect(exchanges.map(\.tx) == handshakeWires)
        #expect(exchanges.map(\.seq) == Array(0..<10))
        #expect(exchanges.allSatisfy { $0.phase == .initialisation && $0.outcome == .ok && $0.rx != nil })
        #expect(exchanges[0].rx == "ATZ\r\r\rELM327 v2.1\r\r")
        #expect(await harness.log.states == [.resetting, .initialising, .searching, .initialising, .ready])
        #expect(await harness.log.adapterInfos == [info])
        #expect(await harness.session.nextSeq == 10)
    }

    @Test("Byte-by-byte notifications and echoes don't disturb the handshake")
    func byteByByte() async throws {
        let rules = MockELMAdapter.Rule.touaregInstant.map { rule in
            var rule = rule
            rule.fragmentSizes = [1]
            return rule
        }
        let harness = SessionHarness(rules: rules)
        let info = try await harness.initialise()
        #expect(info.elmVersion == "ELM327 v2.1")
        #expect(await harness.log.exchanges.allSatisfy { $0.outcome == .ok })
    }

    @Test("ATZ gets resetTimeout and 0100 gets searchTimeout, not the command timeout")
    func longTimeouts() async throws {
        let harness = SessionHarness(rules: [
            .init(command: "ATZ", reply: "\r\rELM327 v2.1\r\r>", delay: .milliseconds(250)),
            .init(command: "0100", reply: "SEARCHING...\r7E8064100BE3FA813\r\r>", delay: .milliseconds(450)),
        ] + MockELMAdapter.Rule.touaregInstant)
        let info = try await harness.initialise()
        #expect(info.elmVersion == "ELM327 v2.1")
        let exchanges = await harness.log.exchanges
        #expect(abs(exchanges[0].completedUptime - exchanges[0].requestUptime - 0.25) < 1e-9)
        #expect(abs(exchanges[6].completedUptime - exchanges[6].requestUptime - 0.45) < 1e-9)
    }

    @Test("A silent ATZ times out after resetTimeout and fails init")
    func resetTimeout() async throws {
        let harness = SessionHarness(rules: [.init(command: "ATZ", reply: nil)])
        await #expect(throws: ELMSessionError.initFailed(step: "ATZ", reason: "timeout")) {
            _ = try await harness.initialise()
        }
        let exchange = try #require(await harness.log.exchanges.first)
        #expect(exchange.outcome == .timeout)
        #expect(exchange.rx == nil)
        #expect(abs(exchange.completedUptime - exchange.requestUptime - 0.3) < 1e-9)
        #expect(await harness.session.state == .failed)
        #expect(await harness.mock.sentCommands == ["ATZ"])
    }

    @Test("UNABLE TO CONNECT on 0100 fails init at that step")
    func unableToConnect() async throws {
        let harness = SessionHarness(rules: [
            .init(command: "0100", reply: "SEARCHING...\rUNABLE TO CONNECT\r\r>", delay: .zero),
        ] + MockELMAdapter.Rule.touaregInstant)
        await #expect(throws: ELMSessionError.initFailed(step: "0100", reason: "unableToConnect")) {
            _ = try await harness.initialise()
        }
        #expect(await harness.log.exchanges.last?.outcome == .unableToConnect)
        #expect(await harness.session.state == .failed)
    }

    @Test("A missing ATRV voltage doesn't fail init")
    func voltageOptional() async throws {
        let harness = SessionHarness(rules: [.init(command: "ATRV", reply: "?\r\r>", delay: .zero)] + MockELMAdapter.Rule.touaregInstant)
        let info = try await harness.initialise()
        #expect(info.voltage == nil)
        #expect(await harness.log.exchanges.first { $0.tx == "ATRV" }?.outcome == .notRecognised)
    }

    @Test("Concurrent initialise() calls share one handshake")
    func concurrentInitialise() async throws {
        let harness = SessionHarness(rules: pacedRules())
        let session = harness.session
        let (first, second) = try await drive(harness.clock) {
            async let a = session.initialise()
            async let b = session.initialise()
            return try await (a, b)
        }
        #expect(first == second)
        #expect(await harness.mock.sentCommands.filter { $0 == "ATZ" }.count == 1)
    }
}

@Suite("ELMSession probing", .timeLimit(.minutes(1)))
struct ELMSessionProbeTests {
    static let probing = ELMSessionConfiguration(
        commandTimeout: .milliseconds(200),
        resetTimeout: .seconds(1),
        searchTimeout: .seconds(2),
        probe: true,
        rateWindow: .seconds(1),
        retryDelay: .milliseconds(10),
        reinitBackoff: .milliseconds(50)
    )

    @Test("Touareg timings: multi-PID with the 1 suffix wins; ATAT1 is kept on a tie")
    func touaregPicksMultiPIDWithSuffix() async throws {
        let harness = SessionHarness(rules: MockELMAdapter.Rule.touareg, configuration: Self.probing)
        let info = try await harness.initialise()
        #expect(info.plan == PollingPlan(
            pids: [.vehicleSpeed, .engineSpeed],
            multiPID: true,
            responseCount: 1,
            adaptiveTiming: 1,
            rpmEvery: 5,
            timeout: .milliseconds(200),
            requestHeader: .engine
        ))
        let sent = await harness.mock.sentCommands
        #expect(Array(sent.prefix(10)) == handshakeWires)
        #expect(sent.contains("ATAT2"))
        #expect(sent.last == "ATAT1", "adapter must be left at the chosen timing level")
        let probes = await harness.log.exchanges.filter { $0.phase == .probe }
        #expect(!probes.isEmpty)
        #expect(await harness.log.states.contains(.probing))
    }

    @Test("ATAT2 is kept when it makes polls faster")
    func aggressiveTimingWins() async throws {
        // At level 1 every PID command takes 95 ms; once ATAT2 is on, 50 ms
        // (the mock tracks the level). The suffix and multi-PID are refused.
        let level1: [MockELMAdapter.Rule] = [
            .init(command: "010D", reply: "7E803410D3C\r\r>", delay: .milliseconds(95), adaptiveTiming: 1),
            .init(command: "010C", reply: "7E804410C0BB8\r\r>", delay: .milliseconds(95), adaptiveTiming: 1),
        ]
        let refused: [MockELMAdapter.Rule] = ["010D1", "010C1", "010D0C", "010D0C1"].map {
            .init(command: $0, reply: "?\r\r>", delay: .milliseconds(5))
        }
        let level2: [MockELMAdapter.Rule] = [
            .init(command: "010D", reply: "7E803410D3C\r\r>", delay: .milliseconds(50)),
            .init(command: "010C", reply: "7E804410C0BB8\r\r>", delay: .milliseconds(50)),
        ]
        let harness = SessionHarness(
            rules: level1 + refused + level2 + MockELMAdapter.Rule.touareg,
            configuration: Self.probing
        )
        let info = try await harness.initialise()
        #expect(info.plan.adaptiveTiming == 2)
        #expect(info.plan.multiPID == false)
        #expect(info.plan.responseCount == nil)
        #expect(await harness.mock.sentCommands.last != "ATAT1")
    }

    @Test("A fast reply that doesn't parse is not chosen")
    func fastButMalformed() async throws {
        let bogus: [MockELMAdapter.Rule] = [
            // Fast, but a negative response: not a usable combination.
            .init(command: "010D0C1", reply: "7E8037F0112\r\r>", delay: .milliseconds(5)),
            // Fast, but from the wrong ECU only.
            .init(command: "010D1", reply: "7E903410D3C\r\r>", delay: .milliseconds(5)),
        ]
        let harness = SessionHarness(rules: bogus + MockELMAdapter.Rule.touareg, configuration: Self.probing)
        let info = try await harness.initialise()
        #expect(info.plan.multiPID == true)
        #expect(info.plan.responseCount == nil)
    }

    @Test("When nothing parses, the baseline plan is used")
    func fallsBackToBaseline() async throws {
        let broken: [MockELMAdapter.Rule] = ["010D", "010C", "010D1", "010C1", "010D0C", "010D0C1"].map {
            .init(command: $0, reply: "CAN ERROR\r\r>", delay: .milliseconds(5))
        }
        let harness = SessionHarness(rules: broken + MockELMAdapter.Rule.touareg, configuration: Self.probing)
        let info = try await harness.initialise()
        // Physical addressing reached nothing: back to 7DF, and the
        // baseline is functional (review R2.1-1).
        var expected = PollingPlan.baseline
        expected.timeout = .milliseconds(200)
        #expect(info.plan == expected)
        #expect(await harness.mock.sentCommands.contains("ATSH7DF"))
    }

    @Test("A PID that answers NO DATA while probing is left out of the plan")
    func noDataPIDExcluded() async throws {
        // The ECU doesn't implement RPM: multi-PID requests return speed only.
        let rules: [MockELMAdapter.Rule] = ["010C", "010C1"].map {
            .init(command: $0, reply: "NO DATA\r\r>", delay: .milliseconds(5))
        } + ["010D0C1", "010D0C"].map {
            .init(command: $0, reply: "7E803410D3C\r\r>", delay: .milliseconds(5))
        }
        let harness = SessionHarness(rules: rules + MockELMAdapter.Rule.touareg, configuration: Self.probing)
        let info = try await harness.initialise()
        #expect(info.plan.pids == [.vehicleSpeed])
        #expect(info.plan.multiPID == false)
        #expect(info.plan.responseCount == 1)
    }
}

@Suite("ELMSession polling", .timeLimit(.minutes(1)))
struct ELMSessionPollingTests {
    @Test("Single-PID plan: speed every cycle, RPM every rpmEvery-th, readings carry seq, raw and both stamps")
    func singlePIDSchedule() async throws {
        let harness = SessionHarness(rules: pacedRules())
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan(rpmEvery: 2))
        await harness.run { await $0.readings.count >= 7 }
        try await harness.stopPolling()

        let polls = await harness.pollCommands
        #expect(Array(polls.prefix(7)) == ["010D", "010C", "010D", "010D", "010C", "010D", "010D"])

        let exchanges = await harness.log.exchanges.filter { $0.phase == .poll }
        let readings = await harness.log.readings
        for reading in readings {
            let exchange = try #require(exchanges.first { $0.seq == reading.seq })
            #expect(reading.command == exchange.tx)
            #expect(reading.raw == exchange.rx)
            #expect(reading.requestUptime == exchange.requestUptime)
            #expect(reading.replyUptime == exchange.completedUptime)
            #expect(abs(reading.replyUptime - reading.requestUptime - 0.01) < 1e-9)
            #expect(reading.ecu == "7E8")
        }
        #expect(readings.first?.measurement == OBDMeasurement(pid: .vehicleSpeed, value: 60, unit: .kilometersPerHour))
        #expect(readings.first { $0.measurement.pid == .engineSpeed }?.measurement.value == 750)
        #expect(await harness.session.state == .ready)
    }

    @Test("Multi-PID plan with suffix: one command per cycle, two readings sharing seq")
    func multiPID() async throws {
        let harness = SessionHarness(rules: pacedRules())
        _ = try await harness.initialise()
        let plan = PollingPlan(
            pids: [.vehicleSpeed, .engineSpeed], multiPID: true, responseCount: 1,
            adaptiveTiming: 1, rpmEvery: 5, timeout: .milliseconds(100), requestHeader: .engine
        )
        try await harness.session.startPolling(plan)
        await harness.run { await $0.readings.count >= 6 }
        try await harness.stopPolling()

        #expect(Set(await harness.pollCommands) == ["010D0C1"])
        let readings = await harness.log.readings
        let bySeq = Dictionary(grouping: readings, by: \.seq)
        for (_, group) in bySeq where group.count == 2 {
            #expect(group.map(\.measurement.pid) == [.vehicleSpeed, .engineSpeed])
            #expect(Set(group.map(\.raw)).count == 1)
        }
        #expect(bySeq.values.contains { $0.count == 2 })
    }

    @Test("Every ECU's reading is kept; the 7E8 one is marked primary")
    func multiECU() async throws {
        let harness = SessionHarness(rules: pacedRules([
            .init(command: "010D", reply: "7E803410D3C\r7E903410D3B\r\r>", delay: .milliseconds(10)),
        ]))
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.readings.count >= 2 }
        try await harness.stopPolling()

        let readings = Array(await harness.log.readings.prefix(2))
        #expect(readings.map(\.ecu) == ["7E8", "7E9"])
        #expect(readings.map(\.measurement.value) == [60, 59])
        #expect(readings.map(\.isFromPrimaryECU) == [true, false])
        #expect(readings[0].seq == readings[1].seq)
    }

    @Test("NO DATA is recorded once and that PID is no longer polled")
    func noDataStopsPID() async throws {
        let harness = SessionHarness(rules: pacedRules())
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed, .intakeAirTemperature], rpmEvery: 1))
        await harness.run { await $0.readings.count >= 5 }
        try await harness.stopPolling()

        let polls = await harness.pollCommands
        #expect(polls.filter { $0 == "010F" } == ["010F"])
        let noData = await harness.log.exchanges.filter { $0.outcome == .noData }
        #expect(noData.map(\.tx) == ["010F"])
        #expect(noData.first?.rx == "NO DATA\r\r")
        #expect(!(await harness.log.states.contains(.retrying)))
    }

    @Test("NO DATA for a multi-PID request falls back to single PIDs")
    func noDataMultiFallsBack() async throws {
        let harness = SessionHarness(rules: pacedRules([
            .init(command: "010D0F", reply: "NO DATA\r\r>", delay: .milliseconds(10)),
        ]))
        _ = try await harness.initialise()
        let plan = PollingPlan(
            pids: [.vehicleSpeed, .intakeAirTemperature], multiPID: true, responseCount: nil,
            adaptiveTiming: 1, rpmEvery: 1, timeout: .milliseconds(100)
        )
        try await harness.session.startPolling(plan)
        await harness.run { await $0.readings.count >= 3 }
        try await harness.stopPolling()
        let polls = await harness.pollCommands
        #expect(Array(polls.prefix(3)) == ["010D0F", "010D", "010F"])
        #expect(polls.dropFirst(3).allSatisfy { $0 == "010D" })
    }

    @Test("When every PID answers NO DATA, polling ends in ready")
    func allNoData() async throws {
        let harness = SessionHarness(rules: pacedRules())
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.intakeAirTemperature]))
        await harness.run { await $0.transitions.last?.to == .ready }
        #expect(await harness.session.state == .ready)
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.readings.count >= 1 }
        try await harness.stopPolling()
    }

    @Test("A timeout is recorded with the session's stamp, retried, and polling recovers")
    func timeoutRetry() async throws {
        // 150 ms: past the 100 ms timeout, within the 100 ms grace, so the
        // late prompt is paid and the retry needs no re-init.
        let harness = SessionHarness(rules: pacedRules([
            .init(command: "010D", reply: "7E803410D3C\r\r>", delay: .milliseconds(150), times: 1),
        ]))
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.readings.count >= 2 }
        try await harness.stopPolling()

        let polls = await harness.log.exchanges.filter { $0.phase == .poll && !($0.outcome == .timeout && $0.rx != nil) }
        #expect(polls[0].outcome == .timeout)
        #expect(polls[0].rx == nil)
        #expect(abs(polls[0].completedUptime - polls[0].requestUptime - 0.1) < 1e-9)
        #expect(polls[1].outcome == .ok)
        #expect(polls[1].requestUptime - polls[0].completedUptime >= 0.01 - 1e-9, "retry waits retryDelay")
        #expect(!(await harness.log.states.contains(.reinitialising)))
        let transitions = await harness.log.transitions
        #expect(transitions.contains { $0.from == .polling && $0.to == .retrying && $0.reason == "timeout" })
        #expect(transitions.contains { $0.from == .retrying && $0.to == .polling })
    }

    @Test("failuresBeforeReinit consecutive failures re-run the handshake, then polling resumes")
    func reinit() async throws {
        // Errors that come with a prompt (a silent command is a write-off,
        // which re-initialises at once; see ELMSessionWriteOffTests).
        let harness = SessionHarness(rules: pacedRules([
            .init(command: "010D", reply: "CAN ERROR\r\r>", delay: .milliseconds(10), times: 3),
        ]))
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.readings.count >= 1 }
        try await harness.stopPolling()

        let sent = await harness.mock.sentCommands
        #expect(Array(sent.prefix(24)) == handshakeWires + ["010D", "010D", "010D"] + handshakeWires + ["010D"])
        #expect(await harness.log.states.contains(.reinitialising))
        // initialise(), startPolling with a plan other than info.plan, re-init.
        #expect(await harness.log.adapterInfos.count == 3)
        let reinitExchanges = await harness.log.exchanges.filter { $0.phase == .initialisation }
        #expect(reinitExchanges.count == 20)
        #expect(await harness.log.reconnectRequests == 0)
    }

    @Test("Re-inits that don't restore polling end in failed, then needsReconnect, and stop sending")
    func needsReconnectAfterUselessReinits() async throws {
        let harness = SessionHarness(rules: pacedRules([.init(command: "010D", reply: nil)]))
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.reconnectRequests == 1 }

        let sentAtFailure = await harness.mock.sentCommands.count
        await harness.clock.advance(by: .seconds(5))
        #expect(await harness.mock.sentCommands.count == sentAtFailure, "no tight loop after failing")

        // 1 init + 2 re-inits. A silent poll is written off after its grace
        // and goes straight to re-init, so one poll per attempt.
        #expect(await harness.mock.sentCommands.filter { $0 == "ATZ" }.count == 3)
        #expect(await harness.pollCommands.count == 3)
        let events = await harness.log.events
        let failedIndex = try #require(events.firstIndex {
            if case .state(_, .failed, _, _) = $0 { true } else { false }
        })
        let reconnectIndex = try #require(events.firstIndex {
            if case .needsReconnect = $0 { true } else { false }
        })
        #expect(failedIndex < reconnectIndex)
        #expect(await harness.session.state == .failed)
        #expect(await harness.log.reconnectRequests == 1)
    }

    @Test("A re-init that itself fails counts too, with growing backoff")
    func failingReinit() async throws {
        let harness = SessionHarness(rules: pacedRules([
            .init(command: "010D", reply: nil),
            .init(command: "ATZ", reply: "ATZ\r\r\rELM327 v2.1\r\r>", delay: .milliseconds(10), times: 1),
            .init(command: "ATZ", reply: nil),
        ]))
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.reconnectRequests == 1 }

        #expect(await harness.mock.sentCommands.filter { $0 == "ATZ" }.count == 3)
        let atz = await harness.log.exchanges.filter { $0.tx == "ATZ" }
        #expect(atz.dropFirst().allSatisfy { $0.outcome == .timeout })
        // Backoff before attempt n is 50 ms × 2^(n-1); the gap between the two
        // failed ATZ attempts includes the 300 ms ATZ timeout plus 100 ms.
        #expect(atz[2].requestUptime - atz[1].completedUptime >= 0.1 - 1e-9)
        #expect(await harness.session.state == .failed)
    }

    @Test("An adapter that answers every poll instantly with an error is not hammered")
    func instantErrorsBackOff() async throws {
        let harness = SessionHarness(rules: [.init(command: "010D", reply: "CAN ERROR\r\r>", delay: .zero)] + MockELMAdapter.Rule.touaregInstant)
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.reconnectRequests == 1 }
        let polls = await harness.log.exchanges.filter { $0.tx == "010D" }
        #expect(polls.count == 9)
        #expect(polls.allSatisfy { $0.outcome == .canError })
        for (earlier, later) in zip(polls, polls.dropFirst()) {
            #expect(later.requestUptime - earlier.completedUptime >= 0.01 - 1e-9)
        }
    }

    @Test("seq starts at firstSeq, has no gaps, and nextSeq continues it")
    func seqContinuity() async throws {
        let harness = SessionHarness(rules: pacedRules([.init(command: "010D", reply: nil, times: 1)]), firstSeq: 1_000)
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan(rpmEvery: 1))
        await harness.run { await $0.readings.count >= 6 }
        _ = try? await harness.session.sendManual("04")
        await harness.session.shutdown()

        let seqs = await harness.log.exchanges.map(\.seq)
        #expect(seqs.first == 1_000)
        #expect(seqs == Array(1_000..<(1_000 + seqs.count)))
        #expect(await harness.session.nextSeq == 1_000 + seqs.count)
        let readingSeqs = Set(await harness.log.readings.map(\.seq))
        #expect(readingSeqs.isSubset(of: Set(seqs)))
    }

    @Test("Poll rate is reported every rateWindow")
    func pollRate() async throws {
        let harness = SessionHarness(rules: pacedRules())
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.pollRates.count >= 2 }
        try await harness.stopPolling()
        let rates = await harness.log.pollRates
        // 10 ms per reply, back to back: about 100 Hz.
        #expect(rates.allSatisfy { (80...100).contains($0) }, "rates: \(rates)")
    }

    @Test("Starting needs ready and a valid plan; nothing is sent otherwise")
    func startPreconditions() async throws {
        let harness = SessionHarness()
        await #expect(throws: ELMSessionError.notInitialised) { try await harness.session.startPolling(.baseline) }
        _ = try await harness.initialise()
        var bad = PollingPlan.baseline
        bad.responseCount = 10
        await #expect(throws: ELMSessionError.self) { try await harness.session.startPolling(bad) }
        #expect(await harness.mock.sentCommands == handshakeWires)
        #expect(await harness.log.exchanges.count == 10)
    }

    @Test("A plan with ATAT2 applies it before polling and again after a re-init")
    func appliesAdaptiveTiming() async throws {
        let harness = SessionHarness(rules: pacedRules([
            .init(command: "010D", reply: "CAN ERROR\r\r>", delay: .milliseconds(10), times: 3),
        ]))
        _ = try await harness.initialise()
        var plan = singlePlan([.vehicleSpeed])
        plan.adaptiveTiming = 2
        try await harness.session.startPolling(plan)
        await harness.run { await $0.readings.count >= 1 }
        try await harness.stopPolling()
        let sent = Array(await harness.mock.sentCommands.dropFirst(10))
        #expect(Array(sent.prefix(4)) == ["ATAT2", "010D", "010D", "010D"])
        #expect(Array(sent.dropFirst(4).prefix(12)) == handshakeWires + ["ATAT2", "010D"])
    }
}

@Suite("ELMSession boundary and lifecycle", .timeLimit(.minutes(1)))
struct ELMSessionBoundaryTests {
    @Test(
        "A forbidden manual command is a rejected exchange and never reaches the adapter",
        arguments: ["04", "0400", "ATZ", "ATCAF0", "ATSH7E0", "ATST32", "2EF190", "010D\r04", "01\u{FF10}\u{FF14}"]
    )
    func manualRejected(command: String) async throws {
        let harness = SessionHarness()
        _ = try await harness.initialise()
        await harness.clock.advance(by: .milliseconds(7))
        await #expect(throws: ELMSessionError.forbiddenCommand(command)) {
            _ = try await harness.session.sendManual(command)
        }
        await harness.run { await $0.exchanges.count == 11 }
        let rejected = try #require(await harness.log.exchanges.last)
        #expect(rejected.outcome == .rejected)
        #expect(rejected.tx == command)
        #expect(rejected.phase == .manual)
        #expect(rejected.rx == nil)
        #expect(rejected.requestUptime == harness.clock.uptimeSeconds)
        #expect(rejected.completedUptime == rejected.requestUptime)
        #expect(await harness.mock.sentCommands == handshakeWires)
    }

    @Test("Allowed manual commands go out uppercased and are recorded")
    func manualAllowed() async throws {
        let harness = SessionHarness()
        _ = try await harness.initialise()
        let exchange = try await harness.session.sendManual("atrv")
        #expect(exchange.tx == "ATRV")
        #expect(exchange.rx == "12.4V\r\r")
        #expect(exchange.outcome == .ok)
        #expect(exchange.phase == .manual)
        let poll = try await harness.session.sendManual("010d")
        #expect(poll.outcome == .ok)
        #expect(await harness.mock.sentCommands.suffix(2) == ["ATRV", "010D"])
    }

    @Test("Manual commands queue between polls: never two commands in flight")
    func oneInFlight() async throws {
        let harness = SessionHarness(rules: pacedRules(delay: .milliseconds(20)))
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan(rpmEvery: 1))
        let session = harness.session
        let manual = try await drive(harness.clock) {
            async let a = session.sendManual("ATRV")
            async let b = session.sendManual("ATDPN")
            async let c = session.sendManual("010D")
            return try await [a, b, c]
        }
        await harness.run { await $0.readings.count >= 8 }
        try await harness.stopPolling()

        #expect(manual.map(\.outcome) == [.ok, .ok, .ok])
        #expect(await harness.mock.overlappingSends == 0)
        // Exchanges never overlap in time.
        let exchanges = await harness.log.exchanges.sorted { $0.requestUptime < $1.requestUptime }
        for (earlier, later) in zip(exchanges, exchanges.dropFirst()) {
            #expect(later.requestUptime >= earlier.completedUptime)
        }
    }

    // R1-8: a session-originated command that fails validation.
    @Test("A session command that fails validation is rejected, sends nothing, fails the session, never retries")
    func sessionCommandRejected() async throws {
        let harness = SessionHarness()
        _ = try await harness.initialise()
        await #expect(throws: ELMSessionError.forbiddenCommand("adaptiveTiming(7)")) {
            _ = try await harness.session.perform(.adaptiveTiming(7), phase: .poll)
        }
        await harness.run { await $0.states.last == .failed }
        let rejected = try #require(await harness.log.exchanges.last)
        #expect(rejected.outcome == .rejected)
        #expect(rejected.tx == "ATAT7")
        #expect(rejected.phase == .poll)
        let failed = try #require(await harness.log.transitions.last)
        #expect(failed.to == .failed)
        #expect(failed.reason?.contains("ATAT7") == true)
        await harness.clock.advance(by: .seconds(5))
        #expect(await harness.mock.sentCommands == handshakeWires)
        #expect(await harness.log.reconnectRequests == 0)
    }

    @Test("A reply that arrives after its timeout is recorded as a late timeout row, not lost")
    func lateReply() async throws {
        // ATDP: not part of the handshake, so init can't use up the slow rule.
        let harness = SessionHarness(rules: [
            .init(command: "ATDP", reply: "AUTO, ISO 15765-4 (CAN 11/500)\r\r>", delay: .milliseconds(150), times: 1),
        ] + MockELMAdapter.Rule.touaregInstant)
        _ = try await harness.initialise()
        let session = harness.session
        let exchange = try await drive(harness.clock) { try await session.sendManual("ATDP") }
        #expect(exchange.outcome == .timeout)
        #expect(exchange.rx == nil)

        await harness.run { await $0.exchanges.count == 12 }
        let late = try #require(await harness.log.exchanges.last)
        #expect(late.outcome == .timeout)
        #expect(late.rx == "AUTO, ISO 15765-4 (CAN 11/500)\r\r")
        #expect(late.tx == "ATDP")
        #expect(late.seq == exchange.seq + 1)
        #expect(late.requestUptime == exchange.requestUptime)
        #expect(abs(late.completedUptime - exchange.requestUptime - 0.15) < 1e-9)
        #expect(await harness.log.readings.isEmpty)
    }

    @Test("shutdown() stops polling, goes idle, finishes events; later calls are cancelled")
    func shutdown() async throws {
        let harness = SessionHarness(rules: pacedRules())
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan())
        await harness.run { await $0.readings.count >= 3 }
        await harness.session.shutdown()
        await harness.run { await $0.finished }
        #expect(await harness.session.state == .idle)
        let sent = await harness.mock.sentCommands.count
        await harness.clock.advance(by: .seconds(1))
        #expect(await harness.mock.sentCommands.count == sent)
        await #expect(throws: ELMSessionError.cancelled) { _ = try await harness.session.sendManual("ATRV") }
        await harness.session.shutdown()
    }

    @Test("Shutdown with a command in flight doesn't hang")
    func shutdownInFlight() async throws {
        let harness = SessionHarness(rules: [.init(command: "010D", reply: nil)] + MockELMAdapter.Rule.touaregInstant)
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed], timeout: .seconds(10)))
        let mock = harness.mock
        await harness.run { _ in await mock.sentCommands.count == 11 }
        await harness.session.shutdown()
        await harness.run { await $0.finished }
        #expect(await harness.session.state == .idle)
    }

    @Test("Losing the transport fails the session and finishes events")
    func transportLost() async throws {
        let harness = SessionHarness(rules: pacedRules())
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan())
        await harness.run { await $0.readings.count >= 2 }
        await harness.mock.disconnect()
        await harness.run { await $0.finished }
        let last = try #require(await harness.log.transitions.last)
        #expect(last.to == .failed)
        #expect(last.reason == "transport closed")
        await #expect(throws: ELMSessionError.self) { try await harness.session.startPolling(.baseline) }
    }

    @Test("stopPolling returns to ready and polling can restart")
    func stopAndRestart() async throws {
        let harness = SessionHarness(rules: pacedRules())
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan())
        await harness.run { await $0.readings.count >= 2 }
        try await harness.stopPolling()
        #expect(await harness.session.state == .ready)
        let count = await harness.log.readings.count
        try await harness.session.startPolling(singlePlan())
        await harness.run { await $0.readings.count >= count + 2 }
        try await harness.stopPolling()
    }
}
