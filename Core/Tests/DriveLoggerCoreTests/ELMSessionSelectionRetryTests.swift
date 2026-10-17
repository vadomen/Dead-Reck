import Foundation
import Testing

@testable import DriveLoggerCore

// B1-1 (user decision: fix): one timeout during start-up selection used to
// send the session to the next, slower step (`010D0C` instead of `010D0C1`)
// for the whole drive. A candidate's first sample that times out is now
// retried once before the step is given up. The retry goes through the
// normal path: if the timed-out command's prompt never comes, the write-off
// desynchronises the link and init restarts from ATZ (re-init).

@Suite("ELMSession start-up selection: one retry on a first-sample timeout (B1-1)", .timeLimit(.minutes(1)))
struct ELMSessionSelectionRetryTests {
    typealias Rule = MockELMAdapter.Rule

    /// commandTimeout 200 ms; the late-prompt grace is the same.
    static let probing = ELMSessionProbeTests.probing
    static let retryNote = "start-up selection: 010D0C1 timed out on its first sample; retrying once"

    /// `010D0C1` under 7E0 answered after 300 ms: past the 200 ms timeout,
    /// within the next command's grace, so its prompt is paid (a late row).
    static func late(times: Int) -> Rule {
        Rule(command: "010D0C1", reply: "7E806410D000C0A5C\r\r>", delay: .milliseconds(300), times: times, requestHeader: "7E0")
    }

    static func notes(_ log: EventLog) async -> [String] {
        await log.transitions.filter { $0.from == $0.to }.compactMap(\.reason)
    }

    @Test("A first 010D0C1 sample that times out is retried once: 010D0C1 at 7E0 is still chosen")
    func firstSampleTimeoutRetried() async throws {
        let harness = SessionHarness(rules: [Self.late(times: 1)] + MockELMAdapter.Rule.benchCar, configuration: Self.probing)
        let info = try await harness.initialise()

        #expect(info.plan.primaryCommand.wireFormat == "010D0C1")
        #expect(info.plan.requestHeader == .engine)
        #expect(await Self.notes(harness.log).filter { $0.hasPrefix("start-up selection: ") } == [Self.retryNote])
        let sent = await harness.mock.sentCommands
        #expect(sent.filter { $0 == "010D0C1" }.count == 1 + probeSendsOfChosenCommand, "the timed-out sample plus a full selection")
        #expect(!sent.contains("010D0C"), "no fallback to the slower step")
        #expect(!sent.contains("ATSH7DF"))
        #expect(sent.filter { $0 == "ATZ" }.count == 1, "the late prompt was paid: no restart")
        let probes = await harness.log.exchanges.filter { $0.phase == .probe && $0.tx == "010D0C1" }
        #expect(probes.prefix(2).map(\.outcome) == [.timeout, .timeout], "the timeout row, then its late row")
        #expect(probes[1].rx == "7E806410D000C0A5C\r\r", "the late reply is recorded on the timed-out command")
        #expect(probes.dropFirst(2).allSatisfy { $0.outcome == .ok })
    }

    @Test("Only one retry: a retry that times out too falls back to the next step, as before")
    func secondTimeoutFallsBack() async throws {
        let harness = SessionHarness(rules: [Self.late(times: 2)] + MockELMAdapter.Rule.benchCar, configuration: Self.probing)
        let info = try await harness.initialise()

        #expect(await Self.notes(harness.log).filter { $0.hasPrefix("start-up selection: ") } == [Self.retryNote])
        let sent = await harness.mock.sentCommands
        #expect(sent.filter { $0 == "010D0C1" }.count == 2, "the sample and its one retry")
        // The bench script has no other step under 7E0: functional selection.
        #expect(info.plan.primaryCommand.wireFormat == "010D0C")
        #expect(info.plan.requestHeader == nil)
    }

    @Test("A timeout on a later sample is not retried: the step is given up as before")
    func laterSampleTimeoutNotRetried() async throws {
        let harness = SessionHarness(
            rules: [
                Rule(command: "010D0C1", reply: "7E806410D000C0A5C\r\r>", delay: .milliseconds(45), times: 1, requestHeader: "7E0"),
                Self.late(times: 1),
            ] + MockELMAdapter.Rule.benchCar,
            configuration: Self.probing
        )
        let info = try await harness.initialise()

        #expect(!(await Self.notes(harness.log)).contains { $0.hasPrefix("start-up selection: ") })
        #expect(info.plan.primaryCommand.wireFormat == "010D0C")
        #expect(await harness.mock.sentCommands.filter { $0 == "010D0C1" }.count == 2)
    }

    @Test("A first-sample timeout whose prompt never comes: the retry hits the write-off, init restarts from ATZ and selects 010D0C1")
    func neverAnsweredGoesThroughReinit() async throws {
        let harness = SessionHarness(
            rules: [Rule(command: "010D0C1", reply: nil, times: 1, requestHeader: "7E0")] + MockELMAdapter.Rule.benchCar,
            configuration: Self.probing
        )
        let info = try await harness.initialise()

        #expect(info.plan.primaryCommand.wireFormat == "010D0C1")
        #expect(info.plan.requestHeader == .engine)
        let notes = await Self.notes(harness.log)
        #expect(notes.contains(Self.retryNote))
        #expect(notes.contains { $0.hasPrefix("link desynchronised during initialisation; restarting from ATZ") })
        #expect(await harness.mock.sentCommands.filter { $0 == "ATZ" }.count == 2)
    }
}
