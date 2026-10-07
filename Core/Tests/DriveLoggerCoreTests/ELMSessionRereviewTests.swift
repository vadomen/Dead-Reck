import Foundation
import Testing

@testable import DriveLoggerCore

/// Regressions from the M1 re-review. Each was written against the code that
/// had the bug.

@Suite("ELMSession probe keeps answered PIDs (re-review #1)", .timeLimit(.minutes(1)))
struct ELMSessionProbeNoDataTests {
    /// Refuses the multi-PID and suffix selection steps, so start-up
    /// selection reaches the plain single-PID requests.
    static let singlesOnly: [MockELMAdapter.Rule] = ["010D0C1", "010D0C", "010D1", "010C1"].map {
        .init(command: $0, reply: "?\r\r>", delay: .milliseconds(5))
    }

    // Reviewer's probe: 010D answers OK on sample 1, NO DATA on sample 2;
    // the plan used to come out as [engineSpeed].
    @Test("A PID that answered OK during probing is not dropped by a later NO DATA")
    func probeKeepsAnsweredPID() async throws {
        let harness = SessionHarness(
            rules: Self.singlesOnly + [
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
            rules: Self.singlesOnly + [
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
        // No RPM from this ECU: multi-PID requests return speed only.
        let rules: [MockELMAdapter.Rule] = ["010C", "010C1"].map {
            .init(command: $0, reply: "NO DATA\r\r>", delay: .milliseconds(5))
        } + ["010D0C1", "010D0C"].map {
            .init(command: $0, reply: "7E803410D3C\r\r>", delay: .milliseconds(5))
        }
        let harness = SessionHarness(rules: rules + MockELMAdapter.Rule.touareg, configuration: ELMSessionProbeTests.probing)
        #expect(try await harness.initialise().plan.pids == [.vehicleSpeed])
    }
}

@Suite("ELMSession re-review minors", .timeLimit(.minutes(1)))
struct ELMSessionRereviewMinorTests {
    // #3
    @Test(
        "Stale output never becomes the ATZ banner",
        arguments: [
            "7E803410D3C", "OK", "12.4V", "A6", "6", "410D3C", "7E8 03 41 0D 3C",
            // ATDP and AT@1 replies: letters and digits, but no version token.
            "AUTO, ISO 15765-4 (CAN 11/500)", "ISO 15765-4 (CAN 11/500)", "OBDII to RS232 Interpreter",
        ]
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
