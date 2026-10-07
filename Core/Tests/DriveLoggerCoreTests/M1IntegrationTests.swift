import Foundation
import Testing

@testable import DriveLoggerCore

/// Contracts between the ELM layer and the log layer, which were built on
/// separate branches in M1.
@Suite("M1 integration")
struct M1IntegrationTests {
    static func elm(_ seq: Int, outcome: ELMOutcome, rx: String?, tx: String = "010D", at ms: Int64) -> LogEvent {
        LogEvent(
            timestamp: MonotonicTimestamp(nanoseconds: ms * 1_000_000),
            payload: .elm(ELMTrafficSample(
                seq: seq,
                phase: ELMPhase.poll.rawValue,
                tx: tx,
                requestT: MonotonicTimestamp(nanoseconds: (ms - 100) * 1_000_000),
                rx: rx,
                outcome: outcome.rawValue
            ))
        )
    }

    // A command that times out and whose reply arrives late produces two
    // `timeout` rows: the timeout itself (no rx) and the late row (rx). Only
    // the first is a timeout; unsolicited rows (tx "", rx set) aren't either.
    @Test("stats.timeouts counts each timed-out command once, not its late or unsolicited rows")
    func timeoutsCountedOnce() {
        var stats = StatsAccumulator()
        stats.observe(Self.elm(1, outcome: .timeout, rx: nil, at: 100))
        stats.observe(Self.elm(2, outcome: .timeout, rx: "7E803410D3C\r\r", at: 250))
        stats.observe(Self.elm(3, outcome: .timeout, rx: "STRAY\r\r", tx: "", at: 260))
        stats.observe(Self.elm(4, outcome: .timeout, rx: nil, at: 500))
        stats.observe(Self.elm(5, outcome: .ok, rx: "7E803410D3C\r\r", at: 600))

        let row = stats.closeWindow(at: MonotonicTimestamp(nanoseconds: 1_000_000_000), queueDepthMax: 0, dropped: 0, bytesWritten: 0)
        #expect(row.timeouts == 2)
    }

    @Test("PollingRecord.command is exactly what the session sends", arguments: [
        PollingPlan(pids: [.vehicleSpeed, .engineSpeed], multiPID: true, responseCount: 1, adaptiveTiming: 2, rpmEvery: 1, timeout: .seconds(1)),
        PollingPlan(pids: [.vehicleSpeed, .engineSpeed], multiPID: true, responseCount: nil, adaptiveTiming: 1, rpmEvery: 1, timeout: .seconds(1)),
        PollingPlan(pids: [.vehicleSpeed, .engineSpeed], multiPID: false, responseCount: 1, adaptiveTiming: 2, rpmEvery: 5, timeout: .milliseconds(500)),
        PollingPlan.baseline,
    ])
    func pollingRecordMatchesPrimaryCommand(_ plan: PollingPlan) {
        #expect(PollingRecord(plan).command == plan.primaryCommand.wireFormat)
    }

    @Test("A plan with no PIDs records an empty command, not 01")
    func emptyPlanRecordsEmptyCommand() {
        let plan = PollingPlan(pids: [], multiPID: false, responseCount: nil, adaptiveTiming: 1, rpmEvery: 5, timeout: .seconds(1))
        #expect(plan.primaryCommand.wireFormat == "01")
        #expect(PollingRecord(plan).command == "")
    }
}
