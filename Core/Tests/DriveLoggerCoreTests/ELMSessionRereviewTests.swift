import Foundation
import Testing

@testable import DriveLoggerCore

/// Regressions from the M1 re-review. Each was written against the code that
/// had the bug.

@Suite("ELMSession probe keeps answered PIDs (re-review #1)", .timeLimit(.minutes(1)))
struct ELMSessionProbeNoDataTests {
    // Reviewer's probe: 010D answers OK on sample 1, NO DATA on sample 2;
    // the plan used to come out as [engineSpeed].
    @Test("A PID that answered OK during probing is not dropped by a later NO DATA")
    func probeKeepsAnsweredPID() async throws {
        let harness = SessionHarness(
            rules: [
                .init(command: "010D", reply: "7E803410D3C\r\r>", delay: .milliseconds(95), times: 1),
                .init(command: "010D", reply: "NO DATA\r\r>", delay: .milliseconds(95), times: 1),
            ] + MockELMAdapter.Rule.touareg,
            configuration: ELMSessionProbeTests.probing
        )
        let info = try await harness.initialise()
        #expect(info.plan.pids.contains(.vehicleSpeed))
        #expect(info.plan.pids.first == .vehicleSpeed)
    }

    @Test("A second initialise() in the same session doesn't drop a PID that answered OK before")
    func repeatedInitialiseKeepsAnsweredPID() async throws {
        // First init sends 010D six times (3 samples x 2 timing levels), all OK.
        let harness = SessionHarness(
            rules: [
                .init(command: "010D", reply: "7E803410D3C\r\r>", delay: .milliseconds(95), times: 6),
                .init(command: "010D", reply: "NO DATA\r\r>", delay: .milliseconds(95), times: 1),
            ] + MockELMAdapter.Rule.touareg,
            configuration: ELMSessionProbeTests.probing
        )
        let first = try await harness.initialise()
        #expect(first.plan.pids == [.vehicleSpeed, .engineSpeed])
        let second = try await harness.initialise()
        #expect(second.plan.pids.contains(.vehicleSpeed))
        #expect(await harness.log.exchanges.contains { $0.tx == "010D" && $0.outcome == .noData })
    }

    @Test("A PID that never answered OK is still left out by probing")
    func probeDropsNeverAnswered() async throws {
        let rules: [MockELMAdapter.Rule] = ["010C", "010C1"].map {
            .init(command: $0, reply: "NO DATA\r\r>", delay: .milliseconds(5))
        }
        let harness = SessionHarness(rules: rules + MockELMAdapter.Rule.touareg, configuration: ELMSessionProbeTests.probing)
        #expect(try await harness.initialise().plan.pids == [.vehicleSpeed])
    }
}

@Suite("ELMSession resync after a write-off (re-review #2)", .timeLimit(.minutes(1)))
struct ELMSessionResyncTests {
    // Reviewer's writeOffThenLatePrompt: X's reply comes after timeout + grace
    // (250 ms > 100 + 100). It used to resolve the next command.
    @Test("Single PID: a prompt arriving after the write-off never becomes data")
    func writeOffThenLatePromptSingle() async throws {
        let harness = SessionHarness(rules: pacedRules([
            .init(command: "010D", reply: "7E803410D01\r\r>", delay: .milliseconds(250), times: 1),
        ]))
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.readings.count >= 5 }
        try await harness.stopPolling()

        let readings = await harness.log.readings
        #expect(readings.allSatisfy { $0.measurement.value == 60 }, "values: \(readings.map(\.measurement.value))")
        let exchanges = await harness.log.exchanges
        let late = try #require(exchanges.first { $0.rx == "7E803410D01\r\r" })
        #expect(late.tx == "010D")
        #expect(late.outcome == .timeout)
        let sync = try #require(exchanges.first { $0.tx == "ATRV" && $0.phase == .poll })
        #expect(sync.outcome == .ok)
        #expect(sync.rx == "12.4V\r\r")
        #expect(late.completedUptime <= sync.completedUptime)
        // The only command sent while X's reply was still pending is the sync.
        #expect(await harness.mock.overlappingCommands == ["ATRV"])
        for ok in exchanges where ok.tx == "010D" && ok.outcome == .ok {
            #expect(ok.completedUptime - ok.requestUptime >= 0.01 - 1e-9)
        }
    }

    @Test("Multi-PID: identical polls can't hide an offset either")
    func writeOffThenLatePromptMulti() async throws {
        let harness = SessionHarness(rules: pacedRules([
            .init(command: "010D0C", reply: "7E806410D010C0004\r\r>", delay: .milliseconds(250), times: 1),
        ]))
        _ = try await harness.initialise()
        let plan = PollingPlan(
            pids: [.vehicleSpeed, .engineSpeed], multiPID: true, responseCount: nil,
            adaptiveTiming: 1, rpmEvery: 5, timeout: .milliseconds(100)
        )
        try await harness.session.startPolling(plan)
        await harness.run { await $0.readings.count >= 8 }
        try await harness.stopPolling()

        let readings = await harness.log.readings
        #expect(readings.filter { $0.measurement.pid == .vehicleSpeed }.allSatisfy { $0.measurement.value == 60 })
        #expect(readings.filter { $0.measurement.pid == .engineSpeed }.allSatisfy { $0.measurement.value == 750 })
        #expect(await harness.log.exchanges.contains { $0.tx == "010D0C" && $0.rx == "7E806410D010C0004\r\r" && $0.outcome == .timeout })
        #expect(await harness.mock.overlappingCommands == ["ATRV"])
    }

    @Test("A prompt arriving during the sync is recorded as late, not as the sync's answer or data")
    func promptDuringSync() async throws {
        let harness = SessionHarness(rules: [
            .init(command: "ATRV", reply: "12.4V\r\r>", delay: .milliseconds(10), times: 1),   // handshake
            .init(command: "ATRV", reply: "12.5V\r\r>", delay: .milliseconds(80), times: 1),   // sync, within its 100 ms timeout
        ] + pacedRules([
            .init(command: "010D", reply: "7E803410D01\r\r>", delay: .milliseconds(250), times: 1),
        ]))
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.readings.count >= 2 }
        try await harness.stopPolling()

        let exchanges = await harness.log.exchanges
        let sync = try #require(exchanges.first { $0.tx == "ATRV" && $0.phase == .poll })
        let late = try #require(exchanges.first { $0.rx == "7E803410D01\r\r" })
        #expect(late.tx == "010D")
        #expect(late.completedUptime > sync.requestUptime, "arrived while the sync was in flight")
        #expect(late.completedUptime < sync.completedUptime)
        #expect(sync.rx == "12.5V\r\r")
        #expect(await harness.log.readings.allSatisfy { $0.measurement.value == 60 })
    }

    @Test("A sync that gets no voltage re-initialises via ATZ and counts toward the budget")
    func syncTimeoutReinitialises() async throws {
        let harness = SessionHarness(rules: [
            .init(command: "ATRV", reply: "12.4V\r\r>", delay: .milliseconds(10), times: 1),   // handshake
            .init(command: "ATRV", reply: nil, times: 1),                                      // sync: silent
        ] + pacedRules([.init(command: "010D", reply: nil, times: 1)]))
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.readings.count >= 1 }
        try await harness.stopPolling()

        let sent = await harness.mock.sentCommands
        #expect(Array(sent.dropFirst(9).prefix(3)) == ["010D", "ATRV", "ATZ"])
        let reinit = try #require(await harness.log.transitions.first { $0.to == .reinitialising })
        #expect(reinit.reason?.contains("sync") == true)
        // initialise(), the plan announced at startPolling, the re-init.
        #expect(await harness.log.adapterInfos.count == 3)
        #expect(await harness.log.transitions.contains { $0.reason?.hasPrefix("no voltage reply to the ATRV sync") == true })
        #expect(await harness.log.readings.first?.measurement.value == 60)
    }

    @Test("A wedged adapter that never resyncs still reaches needsReconnect with backoff")
    func wedgedReachesReconnect() async throws {
        let harness = SessionHarness(rules: [
            .init(command: "ATRV", reply: "12.4V\r\r>", delay: .zero, times: 1),
            .init(command: "010D", reply: nil),
            .init(command: "ATRV", reply: nil),
            .init(command: "ATZ", reply: "ATZ\r\r\rELM327 v2.1\r\r>", delay: .zero, times: 1),
            .init(command: "ATZ", reply: nil),
        ] + MockELMAdapter.Rule.touaregInstant)
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.reconnectRequests == 1 }
        #expect(await harness.session.state == .failed)
        let sent = await harness.mock.sentCommands.count
        await harness.clock.advance(by: .seconds(5))
        #expect(await harness.mock.sentCommands.count == sent)
    }
}

@Suite("ELMSession re-review minors", .timeLimit(.minutes(1)))
struct ELMSessionRereviewMinorTests {
    // #3
    @Test(
        "Stale output never becomes the ATZ banner",
        arguments: ["7E803410D3C", "OK", "12.4V", "A6", "6", "410D3C", "7E8 03 41 0D 3C"]
    )
    func staleNeverBanner(text: String) async throws {
        let harness = SessionHarness(rules: [.init(command: "ATZ", reply: "\(text)\r\r>", delay: .zero)])
        await #expect(throws: ELMSessionError.initFailed(step: "ATZ", reason: "timeout")) {
            _ = try await harness.initialise()
        }
        #expect(await harness.log.exchanges.contains { $0.tx == "" && $0.rx == "\(text)\r\r" })
    }

    @Test("Banner-shaped text still counts", arguments: ["OBDII v1.5", "OBDII to RS232 v2.3", "Vgate iCar Pro V2.3"])
    func bannerShaped(text: String) async throws {
        let harness = SessionHarness(rules: [
            .init(command: "ATZ", reply: "ATZ\r\r\r\(text)\r\r>", delay: .zero),
        ] + MockELMAdapter.Rule.touaregInstant)
        #expect(try await harness.initialise().elmVersion == text)
    }

    // #4: a reply landing at the same virtual instant as its timeout.
    @Test("A reply landing together with its timeout is never unsolicited and never written off", arguments: 0..<10)
    func timeoutAndReplyTogether(_: Int) async throws {
        let harness = SessionHarness(rules: pacedRules([
            .init(command: "010D", reply: "7E803410D3C\r\r>", delay: .milliseconds(100), times: 1),
        ]))
        _ = try await harness.initialise()
        try await harness.session.startPolling(singlePlan([.vehicleSpeed]))
        await harness.run { await $0.readings.count >= 3 }
        try await harness.stopPolling()
        let exchanges = await harness.log.exchanges
        #expect(!exchanges.contains { $0.tx == "" }, "late reply recorded as unsolicited")
        #expect(!(await harness.log.transitions.contains { $0.reason?.hasPrefix("no prompt") == true }))
        #expect(await harness.log.readings.allSatisfy { $0.measurement.value == 60 })
    }

    // #6
    @Test("startPolling with a plan other than the announced one emits an adapter row; the same plan doesn't")
    func adapterOnDifferentPlan() async throws {
        let harness = SessionHarness(rules: pacedRules())
        let info = try await harness.initialise()
        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.readings.count >= 1 }
        try await harness.stopPolling()
        #expect(await harness.log.adapterInfos.count == 1)

        let other = singlePlan([.vehicleSpeed], responseCount: 1)
        try await harness.session.startPolling(other)
        await harness.run { await $0.adapterInfos.count == 2 }
        try await harness.stopPolling()
        #expect(await harness.log.adapterInfos.last?.plan == other)
        #expect(await harness.log.adapterInfos.last?.elmVersion == info.elmVersion)
    }
}
