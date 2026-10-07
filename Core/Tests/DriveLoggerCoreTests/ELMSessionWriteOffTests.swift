import Foundation
import Testing

@testable import DriveLoggerCore

/// After a write-off only `ATZ` may go out (user decision after the third
/// review). Each test was written against the ATRV-sync design it replaces.

@Suite("ELMSession write-off → ATZ", .timeLimit(.minutes(1)))
struct ELMSessionWriteOffTests {
    // Reviewer's scenario: the handshake ATRV answers late (250 ms against a
    // 100 ms timeout plus 100 ms grace). Its late voltage used to satisfy
    // the ATRV sync and bring back the off-by-one.
    @Test("Handshake ATRV late, then polling: re-init via ATZ, no shifted reply")
    func handshakeATRVLateThenPolling() async throws {
        let harness = SessionHarness(rules: pacedRules([
            .init(command: "ATRV", reply: "12.5V\r\r>", delay: .milliseconds(250), times: 1),
        ]))
        let info = try await harness.initialise()
        #expect(info.voltage == nil)
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.readings.count >= 4 }
        try await harness.stopPolling()

        let sent = await harness.mock.sentCommands
        #expect(sent.dropFirst(9).first == "ATZ", "nothing but ATZ after the write-off: \(Array(sent.dropFirst(9).prefix(3)))")
        let reinit = try #require(await harness.log.transitions.first { $0.to == .reinitialising })
        #expect(reinit.reason?.contains("desynchronised") == true)
        let exchanges = await harness.log.exchanges
        let late = try #require(exchanges.first { $0.rx == "12.5V\r\r" })
        #expect(late.tx == "ATRV")
        #expect(late.outcome == .timeout)
        #expect(await harness.log.readings.allSatisfy { $0.measurement.value == 60 })
        for ok in exchanges where ok.tx == "010D" && ok.outcome == .ok {
            #expect(ok.completedUptime - ok.requestUptime >= 0.01 - 1e-9)
        }
        #expect(await harness.mock.overlappingCommands.allSatisfy { $0 == "ATZ" })
    }

    // The earlier reviewer scenarios, now under the ATZ rule.
    @Test("A data reply after its write-off never becomes data (single and multi PID)", arguments: [false, true])
    func dataReplyAfterWriteOff(multiPID: Bool) async throws {
        let wire = multiPID ? "010D0C" : "010D"
        let stale = multiPID ? "7E806410D010C0004\r\r>" : "7E803410D01\r\r>"
        let harness = SessionHarness(rules: pacedRules([
            .init(command: wire, reply: stale, delay: .milliseconds(250), times: 1),
        ]))
        _ = try await harness.initialise()
        let plan = PollingPlan(
            pids: [.vehicleSpeed, .engineSpeed], multiPID: multiPID, responseCount: nil,
            adaptiveTiming: 1, rpmEvery: 1, timeout: .milliseconds(100)
        )
        try await harness.session.startPolling(plan)
        await harness.run { await $0.readings.count >= 6 }
        try await harness.stopPolling()

        let readings = await harness.log.readings
        #expect(readings.filter { $0.measurement.pid == .vehicleSpeed }.allSatisfy { $0.measurement.value == 60 })
        #expect(readings.filter { $0.measurement.pid == .engineSpeed }.allSatisfy { $0.measurement.value == 750 })
        let staleText = String(stale.dropLast())
        let late = try #require(await harness.log.exchanges.first { $0.rx == staleText })
        #expect(late.tx == wire)
        #expect(late.outcome == .timeout)
        #expect(await harness.mock.overlappingCommands.allSatisfy { $0 == "ATZ" })
    }

    @Test("A manual command after a written-off manual ATRV is refused, never answered with the stale voltage")
    func manualAfterWriteOff() async throws {
        let harness = SessionHarness(rules: [
            .init(command: "ATRV", reply: "12.4V\r\r>", delay: .zero, times: 1),               // handshake
            .init(command: "ATRV", reply: "12.5V\r\r>", delay: .milliseconds(250), times: 1),  // manual, late
        ] + MockELMAdapter.Rule.touaregInstant)
        _ = try await harness.initialise()
        let session = harness.session
        let first = try await drive(harness.clock) { try await session.sendManual("ATRV") }
        #expect(first.outcome == .timeout)

        await #expect(throws: ELMSessionError.desynchronised) {
            _ = try await drive(harness.clock) { try await session.sendManual("010D") }
        }
        await harness.run { await $0.exchanges.contains { $0.rx == "12.5V\r\r" } }
        let late = try #require(await harness.log.exchanges.first { $0.rx == "12.5V\r\r" })
        #expect(late.tx == "ATRV")
        #expect(!(await harness.mock.sentCommands.contains("010D")))
        #expect(!(await harness.log.exchanges.contains { $0.tx == "010D" }))

        // initialise() is the way back.
        _ = try await harness.initialise()
        let poll = try await drive(harness.clock) { try await session.sendManual("010D") }
        #expect(poll.outcome == .ok)
        #expect(poll.rx == "7E803410D3C\r\r")
    }

    // ATZ is the resync point, so it has to survive a written-off ATZ whose
    // banner arrives during the next ATZ.
    @Test("A written-off ATZ's late banner doesn't shift the next handshake")
    func writtenOffATZLateBanner() async throws {
        let harness = SessionHarness(rules: [
            .init(command: "ATZ", reply: "ATZ\r\r\rELM327 v1.0\r\r>", delay: .milliseconds(600), times: 1),
        ] + MockELMAdapter.Rule.touaregInstant)
        await #expect(throws: ELMSessionError.initFailed(step: "ATZ", reason: "timeout")) {
            _ = try await harness.initialise()
        }
        let info = try await harness.initialise()
        #expect(info.elmVersion == "ELM327 v2.1")

        let exchanges = await harness.log.exchanges
        let late = try #require(exchanges.first { $0.rx == "ATZ\r\r\rELM327 v1.0\r\r" })
        #expect(late.tx == "ATZ")
        #expect(late.outcome == .timeout)
        let second = try #require(exchanges.last { $0.tx == "ATZ" && $0.outcome == .ok })
        #expect(second.rx == "ATZ\r\r\rELM327 v2.1\r\r")
        let handshake = exchanges.filter { $0.seq > second.seq && $0.phase == .initialisation }
        #expect(handshake.map(\.tx) == Array(handshakeWires.dropFirst()))
        #expect(handshake.allSatisfy { $0.outcome == .ok })
        #expect(handshake.first?.rx == "ATE0\rOK\r\r")
        #expect(handshake.first { $0.tx == "ATDPN" }?.rx == "A6\r\r")
        #expect(await harness.mock.overlappingCommands == ["ATZ"])
    }

    @Test("A banner arriving while another handshake command waits is never taken as its reply")
    func bannerDuringATE0() async throws {
        let harness = SessionHarness(rules: [
            .init(command: "ATE0", reply: "ELM327 v2.1\r\r>ATE0\rOK\r\r>", delay: .zero),
        ] + MockELMAdapter.Rule.touaregInstant)
        _ = try await harness.initialise()
        let exchanges = await harness.log.exchanges
        #expect(exchanges.first { $0.tx == "ATE0" }?.rx == "ATE0\rOK\r\r")
        #expect(exchanges.contains { $0.tx == "" && $0.rx == "ELM327 v2.1\r\r" })
    }

    @Test("A write-off during initialise() restarts it from ATZ, and the late reply stays attributed")
    func initialiseRestarts() async throws {
        let harness = SessionHarness(
            rules: [.init(command: "010D0C1", reply: "7E806410D3C0C0BB8\r\r>", delay: .milliseconds(500), times: 1)]
                + MockELMAdapter.Rule.touareg,
            configuration: ELMSessionProbeTests.probing
        )
        let info = try await harness.initialise()
        #expect(info.plan.multiPID && info.plan.responseCount == 1)
        #expect(await harness.mock.sentCommands.filter { $0 == "ATZ" }.count == 2)
        #expect(await harness.log.transitions.contains { $0.from == $0.to && $0.reason?.contains("restarting from ATZ") == true })
        let late = try #require(await harness.log.exchanges.first { $0.tx == "010D0C1" && $0.outcome == .timeout && $0.rx != nil })
        #expect(late.rx == "7E806410D3C0C0BB8\r\r")
        #expect(await harness.mock.overlappingCommands.allSatisfy { $0 == "ATZ" })
    }

    @Test("initialise() restarts are bounded: a link that keeps losing prompts fails init")
    func initialiseRestartsBounded() async throws {
        let harness = SessionHarness(
            rules: [.init(command: "010D0C1", reply: nil)] + MockELMAdapter.Rule.touareg,
            configuration: ELMSessionProbeTests.probing
        )
        await #expect(throws: ELMSessionError.desynchronised) { _ = try await harness.initialise() }
        // One run plus reinitsBeforeReconnect (2) restarts.
        #expect(await harness.mock.sentCommands.filter { $0 == "ATZ" }.count == 3)
        #expect(await harness.session.state == .failed)
    }

    @Test("A wedged adapter still reaches one needsReconnect with backoff, and stops sending")
    func wedgedReachesReconnect() async throws {
        let harness = SessionHarness(rules: [
            .init(command: "010D", reply: nil),
            .init(command: "ATZ", reply: "ATZ\r\r\rELM327 v2.1\r\r>", delay: .zero, times: 1),
            .init(command: "ATZ", reply: nil),
        ] + MockELMAdapter.Rule.touaregInstant)
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.reconnectRequests == 1 }
        #expect(await harness.session.state == .failed)
        let atz = await harness.log.exchanges.filter { $0.tx == "ATZ" && $0.rx == nil }
        #expect(atz.count == 2)
        // Backoff before re-init attempt 2 is 100 ms (50 × 2).
        #expect(atz[1].requestUptime - atz[0].completedUptime >= 0.1 - 1e-9)
        let sent = await harness.mock.sentCommands.count
        await harness.clock.advance(by: .seconds(5))
        #expect(await harness.mock.sentCommands.count == sent)
        #expect(await harness.log.reconnectRequests == 1)
    }
}

@Suite("ELMSession timeout rows and partial text (round 4 minors)", .timeLimit(.minutes(1)))
struct ELMSessionTimeoutRowTests {
    // Minor 2 + M4: a reply landing between the timeout and run() resuming.
    @Test("The timeout row is emitted with the timeout; a reply right after it is its late row")
    func timeoutRowThenLateRow() async throws {
        let harness = SessionHarness(rules: [.init(command: "ATDP", reply: nil)] + MockELMAdapter.Rule.touaregInstant)
        _ = try await harness.initialise()
        let session = harness.session
        let manual = Task { try await session.sendManual("ATDP") }
        let mock = harness.mock
        await harness.run { _ in await mock.sentCommands.last == "ATDP" }
        await session.injectTimeoutThenReply("AUTO, ISO 15765-4 (CAN 11/500)\r\r>")
        let exchange = try await manual.value

        #expect(!(await harness.log.exchanges.contains { $0.tx == "" }), "reply recorded as unsolicited")
        let rows = await harness.log.exchanges.filter { $0.tx == "ATDP" }
        try #require(rows.count == 2)
        #expect(rows[0].seq == exchange.seq)
        #expect(rows[0].outcome == .timeout && rows[0].rx == nil)
        #expect(rows[1].outcome == .timeout && rows[1].rx == "AUTO, ISO 15765-4 (CAN 11/500)\r\r")
        #expect(rows[0].seq < rows[1].seq, "late row before its own timeout row")
    }

    // Minor 5 / M8: while desynchronised, partial text belongs to the oldest
    // written-off command, not to a newer owed one.
    @Test("Partial text at the end goes to the oldest written-off command", arguments: [false, true])
    func partialGoesToWrittenOff(linkLoss: Bool) async throws {
        let harness = SessionHarness(rules: [
            .init(command: "ATDP", reply: "AUTO, ISO 15765-4", delay: .milliseconds(250), times: 1),   // no prompt
            .init(command: "ATZ", reply: "ATZ\r\r\rELM327 v2.1\r\r>", delay: .zero, times: 1),
            .init(command: "ATZ", reply: nil, times: 1),
        ] + MockELMAdapter.Rule.touaregInstant)
        _ = try await harness.initialise()
        let session = harness.session
        _ = try await drive(harness.clock) { try await session.sendManual("ATDP") }   // times out, owed
        await #expect(throws: ELMSessionError.desynchronised) {
            _ = try await drive(harness.clock) { try await session.sendManual("ATI") }  // ATDP written off
        }
        await #expect(throws: ELMSessionError.self) { _ = try await harness.initialise() }  // ATZ times out: owed
        await harness.clock.advance(by: .milliseconds(100))   // ATDP's partial text has arrived by now
        if linkLoss {
            await harness.mock.disconnect()
        } else {
            await harness.session.shutdown()
        }
        await harness.run { await $0.finished }
        let partial = try #require(await harness.log.exchanges.first { $0.rx == "AUTO, ISO 15765-4" })
        #expect(partial.tx == "ATDP")
    }
}
