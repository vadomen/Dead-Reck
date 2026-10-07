import Foundation
import Testing

@testable import DriveLoggerCore

@Suite("PollingPlan")
struct PollingPlanTests {
    static func plan(
        pids: [OBDPID] = [.vehicleSpeed, .engineSpeed],
        multiPID: Bool = false,
        responseCount: Int? = nil,
        adaptiveTiming: Int = 1,
        rpmEvery: Int = 5,
        timeout: Duration = .seconds(1)
    ) -> PollingPlan {
        PollingPlan(
            pids: pids,
            multiPID: multiPID,
            responseCount: responseCount,
            adaptiveTiming: adaptiveTiming,
            rpmEvery: rpmEvery,
            timeout: timeout
        )
    }

    // The rule PollingRecord.command relies on: multiPID → all PIDs in one
    // request; otherwise the first PID alone; the suffix either way.
    @Test(
        "primaryCommand follows the recorded-command rule",
        arguments: [
            (false, nil, "010D"),
            (false, 1, "010D1"),
            (true, nil, "010D0C"),
            (true, 1, "010D0C1"),
        ] as [(Bool, Int?, String)]
    )
    func primaryCommandRule(multiPID: Bool, responseCount: Int?, wire: String) throws {
        let plan = Self.plan(multiPID: multiPID, responseCount: responseCount)
        let expectedPIDs: [OBDPID] = multiPID ? [.vehicleSpeed, .engineSpeed] : [.vehicleSpeed]
        #expect(plan.primaryCommand == .currentDataMany(expectedPIDs, responseCount: responseCount))
        #expect(plan.primaryCommand.wireFormat == wire)
        #expect(try plan.primaryCommand.validated().wire == wire)
    }

    @Test("The baseline plan is valid and polls 010D")
    func baseline() throws {
        try PollingPlan.baseline.validate()
        #expect(PollingPlan.baseline.primaryCommand.wireFormat == "010D")
    }

    // R1-5: a String primaryCommand rendered responseCount 10 as "010D10",
    // which the policy accepts as PIDs 0x0D and 0x10.
    @Test("primaryCommand can't smuggle a two-digit count past validation", arguments: [0, 10, 12, -1])
    func badCountFailsValidation(count: Int) {
        let plan = Self.plan(responseCount: count)
        #expect(throws: ELMSessionError.self) { try plan.primaryCommand.validated() }
        #expect(throws: ELMSessionError.self) { try plan.validate() }
    }

    @Test("Range edges are accepted")
    func edges() throws {
        try Self.plan(responseCount: 1).validate()
        try Self.plan(responseCount: 9).validate()
        try Self.plan(adaptiveTiming: 0).validate()
        try Self.plan(adaptiveTiming: 2).validate()
        try Self.plan(rpmEvery: 1).validate()
        try Self.plan(pids: [.vehicleSpeed]).validate()
        try Self.plan(pids: Array(OBDPID.allCases.prefix(6)), multiPID: true).validate()
    }

    @Test(
        "Out-of-range plans are rejected before anything is sent",
        arguments: [
            plan(responseCount: 0),
            plan(responseCount: 10),
            plan(adaptiveTiming: -1),
            plan(adaptiveTiming: 3),
            plan(pids: []),
            plan(pids: Array(OBDPID.allCases.prefix(7))),
            plan(pids: [.vehicleSpeed, .vehicleSpeed]),
            plan(rpmEvery: 0),
            plan(rpmEvery: -5),
            plan(timeout: .zero),
        ]
    )
    func rejects(plan: PollingPlan) {
        #expect(throws: ELMSessionError.self) { try plan.validate() }
    }

    @Test("An empty plan's primaryCommand fails validation instead of trapping")
    func emptyPlan() {
        let empty = Self.plan(pids: [])
        #expect(empty.primaryCommand == .currentDataMany([], responseCount: nil))
        #expect(empty.primaryCommand.wireFormat == "01")
        #expect(throws: ELMSessionError.self) { try empty.primaryCommand.validated() }
        #expect(throws: ELMSessionError.invalidPlan("0 PIDs; 1-6 allowed")) { try empty.validate() }
        #expect(throws: ELMSessionError.self) { try Self.plan(pids: [], responseCount: 1).primaryCommand.validated() }
    }
}
