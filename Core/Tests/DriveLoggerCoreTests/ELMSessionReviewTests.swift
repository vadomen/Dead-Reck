import Foundation
import Testing

@testable import DriveLoggerCore

/// Regressions from the M1 review. Each test was written against the code
/// that had the bug and failed there.

@Suite("ELMSession late prompts (review #1)", .timeLimit(.minutes(1)))
struct ELMSessionLatePromptTests {
    // Reviewer's probe: 010D answers in 150 ms against a 100 ms timeout,
    // later 010Ds in 10 ms. The late reply used to be taken as the answer to
    // the next 010D (value 1 instead of 60, latency 0), shifting every
    // following reply by one command.
    @Test("A late reply is paid to the command that timed out, never to the next one")
    func lateReplyNotShifted() async throws {
        let harness = SessionHarness(rules: pacedRules([
            .init(command: "010D", reply: "7E803410D01\r\r>", delay: .milliseconds(150), times: 1),
        ]))
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.readings.count >= 3 }
        try await harness.stopPolling()

        let readings = await harness.log.readings
        #expect(readings.first?.measurement.value == 60)
        #expect(readings.allSatisfy { $0.measurement.value == 60 })
        let polls = await harness.log.exchanges.filter { $0.tx == "010D" }
        #expect(polls[0].outcome == .timeout)
        #expect(polls[0].rx == nil)
        let late = try #require(polls.first { $0.rx == "7E803410D01\r\r" })
        #expect(late.outcome == .timeout)
        #expect(late.requestUptime == polls[0].requestUptime)
        #expect(abs(late.completedUptime - late.requestUptime - 0.15) < 1e-9)
        for ok in polls where ok.outcome == .ok {
            #expect(ok.completedUptime - ok.requestUptime >= 0.01 - 1e-9, "latency \(ok.completedUptime - ok.requestUptime)")
        }
        #expect(await harness.mock.overlappingSends == 0)
    }

    @Test("A prompt that never comes is abandoned after the grace period, noted, and polling continues")
    func lostPromptAbandoned() async throws {
        let harness = SessionHarness(rules: pacedRules([.init(command: "010D", reply: nil, times: 1)]))
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.readings.count >= 2 }
        try await harness.stopPolling()

        let polls = await harness.log.exchanges.filter { $0.tx == "010D" }
        #expect(polls[0].outcome == .timeout)
        // The retry waited the timeout (100 ms) plus the grace (= commandTimeout).
        #expect(polls[1].requestUptime - polls[0].completedUptime >= 0.1 - 1e-9)
        let notes = await harness.log.transitions.filter { $0.reason?.contains("no prompt") == true }
        #expect(notes.count == 1)
        #expect(await harness.log.readings.first?.measurement.value == 60)
    }

    @Test("Output buffered before the first command is not taken as the ATZ banner")
    func staleOutputBeforeATZ() async throws {
        let harness = SessionHarness()
        await harness.mock.emitUnsolicited("7E803410D3C\r\r>")
        let info = try await harness.initialise()
        #expect(info.elmVersion == "ELM327 v2.1")
        let exchanges = await harness.log.exchanges
        let stale = try #require(exchanges.first { $0.rx == "7E803410D3C\r\r" })
        #expect(stale.tx == "")
        #expect(exchanges.filter { $0.tx == "ATE0" }.map(\.rx) == ["ATE0\rOK\r\r"])
    }

    @Test("A stale reply arriving right after ATZ is skipped until the banner")
    func staleReplyAfterATZ() async throws {
        let harness = SessionHarness(rules: [
            .init(command: "ATZ", reply: "7E803410D3C\r\r>ATZ\r\r\rELM327 v2.1\r\r>", delay: .zero),
        ] + MockELMAdapter.Rule.touaregInstant)
        let info = try await harness.initialise()
        #expect(info.elmVersion == "ELM327 v2.1")
        let atz = try #require(await harness.log.exchanges.first { $0.tx == "ATZ" })
        #expect(atz.rx == "ATZ\r\r\rELM327 v2.1\r\r")
        #expect(await harness.log.exchanges.contains { $0.tx == "" && $0.rx == "7E803410D3C\r\r" })
        #expect(await harness.log.exchanges.allSatisfy { $0.tx == "" || $0.outcome == .ok })
    }

    @Test("Probing with a slow, then late, reply never measures an instant answer")
    func probingNotFooledByLateReply() async throws {
        let harness = SessionHarness(
            rules: [.init(command: "010D", reply: "7E803410D3C\r\r>", delay: .milliseconds(250), times: 1)]
                + MockELMAdapter.Rule.touareg,
            configuration: ELMSessionProbeTests.probing
        )
        let info = try await harness.initialise()
        let probes = await harness.log.exchanges.filter { $0.phase == .probe && $0.tx.hasPrefix("01") && $0.outcome == .ok }
        // The fastest scripted PID reply takes 40 ms.
        for probe in probes {
            #expect(probe.completedUptime - probe.requestUptime >= 0.04 - 1e-9, "\(probe.tx) looked instant")
        }
        #expect(info.plan.multiPID == true)
        #expect(info.plan.responseCount == 1)
        #expect(await harness.mock.overlappingSends == 0)
        let atat = await harness.log.exchanges.filter { $0.tx.hasPrefix("ATAT") }
        #expect(atat.allSatisfy { $0.outcome == .ok })
    }
}

@Suite("ELMSession NO DATA rule (review #2)", .timeLimit(.minutes(1)))
struct ELMSessionNoDataRuleTests {
    // Reviewer's probe: one transient NO DATA used to drop speed for good.
    @Test("NO DATA from a PID that has answered OK is a failure; the PID keeps being polled")
    func onceOKNotDropped() async throws {
        let harness = SessionHarness(rules: pacedRules([
            .init(command: "010D", reply: "7E803410D3C\r\r>", delay: .milliseconds(10), times: 3),
            .init(command: "010D", reply: "NO DATA\r\r>", delay: .milliseconds(10), times: 1),
        ]))
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.readings.count >= 6 }
        try await harness.stopPolling()

        let polls = await harness.log.exchanges.filter { $0.tx == "010D" }
        let noDataIndex = try #require(polls.firstIndex { $0.outcome == .noData })
        #expect(noDataIndex == 3)
        #expect(polls.count > noDataIndex + 1)
        #expect(polls[noDataIndex + 1].outcome == .ok)
        #expect(await harness.log.transitions.contains { $0.to == .retrying && $0.reason == "noData" })
    }

    @Test("A PID that never answered OK is still dropped on NO DATA")
    func neverOKDropped() async throws {
        let harness = SessionHarness(rules: pacedRules())
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed, .intakeAirTemperature], rpmEvery: 1))
        await harness.run { await $0.readings.count >= 4 }
        try await harness.stopPolling()
        #expect(await harness.pollCommands.filter { $0 == "010F" }.count == 1)
        #expect(!(await harness.log.states.contains(.retrying)))
    }

    @Test("A once-OK PID absent from the 0100 bitmask is dropped on NO DATA")
    func absentFromBitmaskDropped() async throws {
        // 0x37 in byte B: 0x0D's bit is clear (0x0B, 0x0C, 0x0E-0x10 set).
        let harness = SessionHarness(rules: pacedRules([
            .init(command: "0100", reply: "7E8064100BE37A813\r\r>", delay: .milliseconds(10)),
            .init(command: "010D", reply: "7E803410D3C\r\r>", delay: .milliseconds(10), times: 2),
            .init(command: "010D", reply: "NO DATA\r\r>", delay: .milliseconds(10)),
        ]))
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.transitions.last?.to == .ready }
        #expect(await harness.pollCommands.count == 3)
        #expect(await harness.log.reconnectRequests == 0)
    }

    @Test("Repeated NO DATA from a once-OK PID escalates to re-init and needsReconnect, never dropping it")
    func repeatedNoDataEscalates() async throws {
        let harness = SessionHarness(rules: pacedRules([
            .init(command: "010D", reply: "7E803410D3C\r\r>", delay: .milliseconds(10), times: 1),
            .init(command: "010D", reply: "NO DATA\r\r>", delay: .milliseconds(10)),
        ]))
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.reconnectRequests == 1 }
        #expect(await harness.mock.sentCommands.filter { $0 == "ATZ" }.count == 3)
        #expect(await harness.pollCommands.count == 10)
        #expect(await harness.log.states.contains(.reinitialising))
        #expect(await harness.session.state == .failed)
    }

    @Test("A multi-PID command that has answered OK doesn't fall back on NO DATA")
    func multiOnceOKNoFallback() async throws {
        let harness = SessionHarness(rules: pacedRules([
            .init(command: "010D0C", reply: "7E806410D3C0C0BB8\r\r>", delay: .milliseconds(10), times: 2),
            .init(command: "010D0C", reply: "NO DATA\r\r>", delay: .milliseconds(10), times: 1),
        ]))
        _ = try await harness.initialise()
        let plan = PollingPlan(
            pids: [.vehicleSpeed, .engineSpeed], multiPID: true, responseCount: nil,
            adaptiveTiming: 1, rpmEvery: 5, timeout: .milliseconds(100)
        )
        try await harness.session.startPolling(plan)
        await harness.run { await $0.readings.count >= 8 }
        try await harness.stopPolling()
        #expect(Set(await harness.pollCommands) == ["010D0C"])
        #expect(await harness.log.transitions.contains { $0.to == .retrying && $0.reason == "noData" })
    }
}

@Suite("ELMSession review minors", .timeLimit(.minutes(1)))
struct ELMSessionReviewMinorTests {
    // #3: the adapter row must say what is actually polled.
    @Test("Dropping a PID re-emits the adapter info with the plan in use")
    func adapterAfterDrop() async throws {
        let harness = SessionHarness(rules: pacedRules())
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed, .intakeAirTemperature], rpmEvery: 1))
        await harness.run { await $0.adapterInfos.count == 2 }
        try await harness.stopPolling()
        let latest = try #require(await harness.log.adapterInfos.last)
        #expect(latest.plan.pids == [.vehicleSpeed])
        #expect(latest.plan.multiPID == false)
        #expect(latest.elmVersion == "ELM327 v2.1")
    }

    @Test("Falling back from multi-PID re-emits the adapter info with multiPID off; re-init reports the plan in use")
    func adapterAfterFallbackAndReinit() async throws {
        let harness = SessionHarness(rules: pacedRules([
            .init(command: "010D0F", reply: "NO DATA\r\r>", delay: .milliseconds(10)),
            .init(command: "010D", reply: nil, times: 3),
        ]))
        _ = try await harness.initialise()
        let plan = PollingPlan(
            pids: [.vehicleSpeed, .intakeAirTemperature], multiPID: true, responseCount: nil,
            adaptiveTiming: 1, rpmEvery: 1, timeout: .milliseconds(100)
        )
        try await harness.session.startPolling(plan)
        await harness.run { await $0.readings.count >= 1 }
        try await harness.stopPolling()
        let infos = await harness.log.adapterInfos
        #expect(infos.count >= 3)
        #expect(infos[1].plan.multiPID == false)
        #expect(infos[1].plan.pids == [.vehicleSpeed, .intakeAirTemperature])
        // After the re-init (3 timeouts on 010D) the row reports the singles plan.
        #expect(infos.last?.plan.multiPID == false)
    }

    // #4
    @Test("A command in flight at shutdown gets a final timeout row")
    func inFlightAtShutdown() async throws {
        let harness = SessionHarness(rules: [.init(command: "010D", reply: nil)] + MockELMAdapter.Rule.touaregInstant)
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed], timeout: .seconds(10)))
        let mock = harness.mock
        await harness.run { _ in await mock.sentCommands.count == 10 }
        await harness.clock.advance(by: .milliseconds(30))
        await harness.session.shutdown()
        await harness.run { await $0.finished }
        let last = try #require(await harness.log.exchanges.last)
        #expect(last.tx == "010D")
        #expect(last.outcome == .timeout)
        #expect(last.rx == nil)
        #expect(last.completedUptime == harness.clock.uptimeSeconds)
        #expect(last.completedUptime - last.requestUptime >= 0.03 - 1e-9)
    }

    @Test("A command in flight when the link drops gets a final timeout row")
    func inFlightAtLinkLoss() async throws {
        let harness = SessionHarness(rules: [.init(command: "010D", reply: nil)] + MockELMAdapter.Rule.touaregInstant)
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed], timeout: .seconds(10)))
        let mock = harness.mock
        await harness.run { _ in await mock.sentCommands.count == 10 }
        await harness.mock.disconnect()
        await harness.run { await $0.finished }
        let last = try #require(await harness.log.exchanges.last)
        #expect(last.tx == "010D")
        #expect(last.outcome == .timeout)
        #expect(last.rx == nil)
        #expect(await harness.log.transitions.last?.reason == "transport closed")
    }

    // #5
    @Test("stopPolling() while the poll loop waits behind a manual command lets no further poll out")
    func stopBehindManual() async throws {
        let harness = SessionHarness(rules: pacedRules([
            .init(command: "ATDP", reply: "AUTO, ISO 15765-4 (CAN 11/500)\r\r>", delay: .milliseconds(50)),
        ], delay: .milliseconds(20)))
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.readings.count >= 2 }
        let session = harness.session
        let manual = Task { try await session.sendManual("ATDP") }
        let mock = harness.mock
        await harness.run { _ in await mock.sentCommands.last == "ATDP" }
        try await harness.stopPolling()
        _ = try await manual.value
        let sent = await harness.mock.sentCommands
        let manualIndex = try #require(sent.lastIndex(of: "ATDP"))
        #expect(sent[(manualIndex + 1)...].isEmpty, "sent after stop: \(sent[(manualIndex + 1)...])")
        #expect(await harness.session.state == .ready)
    }

    // #6: R1-8 through the poll loop, not just perform().
    @Test("An invalid plan that slips past validate() ends the poll loop in failed, never retried")
    func invalidPlanThroughLoop() async throws {
        let harness = SessionHarness(rules: pacedRules())
        _ = try await harness.initialise()
        var plan = singlePlan([.vehicleSpeed])
        plan.adaptiveTiming = 7
        try await harness.session.beginPolling(plan)
        await harness.run { await $0.states.last == .failed }
        await harness.clock.advance(by: .seconds(2))
        let rejected = try #require(await harness.log.exchanges.last)
        #expect(rejected.tx == "ATAT7")
        #expect(rejected.outcome == .rejected)
        #expect(rejected.phase == .poll)
        #expect(await harness.mock.sentCommands == handshakeWires)
        #expect(await harness.log.exchanges.filter { $0.outcome == .rejected }.count == 1)
        #expect(await harness.log.reconnectRequests == 0)
        #expect(await harness.session.state == .failed)
        await #expect(throws: ELMSessionError.notInitialised) { try await harness.session.startPolling(singlePlan()) }
    }
}
