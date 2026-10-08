import Foundation
import Testing

@testable import DriveLoggerCore

// M6.1-3 (review run 6), user decision 3: every init sent 23 probe polls
// (selection plus the ATAT1/ATAT2 comparison), none of which yields an `obd`
// row, so every reconnect widened the OBD gap by ~1 s. A plan chosen on the
// same adapter is now remembered and reused: the handshake still runs in
// full (with the ATSH7E0 gate), then one ATATn applies the remembered level
// and one poll cycle checks the plan; selection and the timing comparison
// run only if that check fails, once per init.

@Suite("ELMSession remembered poll plan (M6.1-3)", .timeLimit(.minutes(1)))
struct ELMSessionPlanReuseTests {
    typealias Rule = MockELMAdapter.Rule

    static let probing = ELMSessionProbeTests.probing
    static let handshake = ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP0", "0100", "ATDPN", "ATRV", "ATSH7E0"]
    static let benchBanner = "ELM327 v2.3"

    /// What start-up selection picks on the bench car, at `level`.
    static func benchPlan(adaptiveTiming level: Int = 2) -> PollingPlan {
        PollingPlan(
            pids: [.vehicleSpeed, .engineSpeed], multiPID: true, responseCount: 1, adaptiveTiming: level,
            rpmEvery: 5, timeout: probing.commandTimeout, requestHeader: .engine
        )
    }

    static func remembered(_ plan: PollingPlan = benchPlan(), banner: String = benchBanner) -> RememberedPollingPlan {
        RememberedPollingPlan(plan: plan, elmVersion: banner)
    }

    static func notes(_ log: EventLog) async -> [String] {
        await log.transitions.filter { $0.from == $0.to }.compactMap(\.reason)
    }

    static func reuseNotes(_ log: EventLog) async -> [String] {
        await notes(log).filter {
            $0.hasPrefix("poll plan reused") || $0.hasPrefix("remembered poll plan") || $0.hasPrefix("reused plan failed")
        }
    }

    @Test("A reused plan skips selection and the ATAT comparison: handshake, one ATATn, one check poll; polls at the remembered level")
    func reusedPlanSkipsSelection() async throws {
        let remembered = Self.remembered()
        let harness = SessionHarness(
            rules: MockELMAdapter.Rule.benchCar, configuration: Self.probing, firstSeq: 40, rememberedPlan: remembered
        )
        let info = try await harness.initialise()

        #expect(info.plan == remembered.plan, "the adapter event carries the plan in use")
        #expect(await harness.log.adapterInfos == [info])
        #expect(await harness.mock.sentCommands == Self.handshake + ["ATAT2", "010D0C1"])
        #expect(await harness.mock.adaptiveTiming == 2)
        #expect(await Self.reuseNotes(harness.log) == [
            "poll plan reused from the previous connection: 010D0C1, ATAT2, requestHeader 7E0",
        ])
        #expect(!(await Self.notes(harness.log)).contains { $0.hasPrefix("adaptive timing: ") }, "no timing comparison")
        #expect(await harness.session.rememberedPlan == remembered)
        let probes = await harness.log.exchanges.filter { $0.phase == .probe }
        #expect(probes.map(\.tx) == ["ATAT2", "010D0C1"])
        #expect(probes.allSatisfy { $0.outcome == .ok })
        #expect(await harness.log.states.suffix(2) == [.probing, .ready])

        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.readings.count >= 6 }
        try await harness.stopPolling()
        let polls = await harness.log.exchanges.filter { $0.phase == .poll }
        #expect(!polls.isEmpty)
        #expect(polls.allSatisfy { $0.tx == "010D0C1" }, "no ATAT/ATSH needed before the first poll")
        #expect(await harness.mock.adaptiveTiming == 2)
        let readings = await harness.log.readings
        #expect(readings.allSatisfy { $0.ecu == "7E8" })
        #expect(readings.contains { $0.measurement.pid == .engineSpeed && $0.measurement.value == 663 })
        let seqs = await harness.log.exchanges.map(\.seq)
        #expect(seqs == Array(40..<(40 + seqs.count)), "seq continues from firstSeq without gaps")
    }

    @Test(
        "A reused plan whose check poll fails falls back to the full selection, exactly once",
        arguments: [
            ("NO DATA\r\r>", "010D0C1: noData"),
            ("7E906410D000C0A5C\r\r>", "010D0C1: no primary-ECU value for every requested PID"),
            ("CAN ERROR\r\r>", "010D0C1: canError"),
        ] as [(String, String)]
    )
    func failedCheckFallsBack(reply: String, reason: String) async throws {
        let harness = SessionHarness(
            rules: [Rule(command: "010D0C1", reply: reply, delay: .milliseconds(20), times: 1)] + MockELMAdapter.Rule.benchCar,
            configuration: Self.probing,
            rememberedPlan: Self.remembered()
        )
        let info = try await harness.initialise()

        #expect(await Self.reuseNotes(harness.log) == [
            "poll plan reused from the previous connection: 010D0C1, ATAT2, requestHeader 7E0",
            "reused plan failed (\(reason)); selecting again",
        ])
        // The full selection ran after the failed check: ATAT1 first, then
        // selection's samples and the comparison.
        let probes = await harness.log.exchanges.filter { $0.phase == .probe }
        #expect(Array(probes.map(\.tx).prefix(3)) == ["ATAT2", "010D0C1", "ATAT1"])
        #expect(probes.filter { $0.tx == "010D0C1" }.count == 1 + probeSendsOfChosenCommand)
        #expect((await Self.notes(harness.log)).contains { $0.hasPrefix("adaptive timing: ATAT1 kept") })
        #expect(info.plan == Self.benchPlan(adaptiveTiming: 1), "selected again: ATAT1 on the bench script")
        #expect(await harness.mock.adaptiveTiming == 1)
        #expect(await harness.log.adapterInfos.map(\.plan) == [info.plan], "one adapter event, with the plan in use")
        #expect(await harness.session.rememberedPlan == Self.remembered(info.plan), "the new selection replaces it")
    }

    @Test("A check poll that times out (and desynchronises the link) still falls back only once; the ATZ restart selects")
    func timedOutCheckFallsBackOnce() async throws {
        let harness = SessionHarness(
            rules: [Rule(command: "010D0C1", reply: nil, times: 1)] + MockELMAdapter.Rule.benchCar,
            configuration: Self.probing,
            rememberedPlan: Self.remembered()
        )
        let info = try await harness.initialise()

        #expect(await Self.reuseNotes(harness.log) == [
            "poll plan reused from the previous connection: 010D0C1, ATAT2, requestHeader 7E0",
            "reused plan failed (010D0C1: timeout); selecting again",
        ])
        #expect(info.plan == Self.benchPlan(adaptiveTiming: 1))
        let sent = await harness.mock.sentCommands
        #expect(sent.filter { $0 == "ATZ" }.count == 2, "the write-off restarted init from ATZ")
        #expect((await Self.notes(harness.log)).contains { $0.hasPrefix("link desynchronised during initialisation; restarting from ATZ") })
        #expect(await harness.session.rememberedPlan == Self.remembered(info.plan))
    }

    @Test("A second initialise() on the same session reuses the plan its own selection chose")
    func sameSessionReinitReuses() async throws {
        let harness = SessionHarness(rules: MockELMAdapter.Rule.benchCar, configuration: Self.probing)
        let first = try await harness.initialise()
        let sentFirst = await harness.mock.sentCommands.count
        let second = try await harness.initialise()

        #expect(second.plan == first.plan)
        #expect(Array(await harness.mock.sentCommands.dropFirst(sentFirst)) == Self.handshake + ["ATAT1", "010D0C1"])
        #expect(await Self.reuseNotes(harness.log) == [
            "poll plan reused from the previous initialisation: 010D0C1, ATAT1, requestHeader 7E0",
        ])
    }

    @Test("ATSH7E0 refused on re-init invalidates a remembered 7E0 plan: full functional selection, no suffix")
    func refusedATSHInvalidatesPhysicalPlan() async throws {
        let harness = SessionHarness(
            rules: [Rule(command: "ATSH7E0", reply: "?\r\r>", delay: .milliseconds(10))] + MockELMAdapter.Rule.benchCar,
            configuration: Self.probing,
            rememberedPlan: Self.remembered()
        )
        let info = try await harness.initialise()

        #expect(await Self.reuseNotes(harness.log) == [
            "remembered poll plan not reused: chosen with requestHeader 7E0, this handshake left requests at 7DF; selecting again",
        ])
        #expect(info.plan.requestHeader == nil)
        #expect(info.plan.responseCount == nil)
        #expect(info.plan.primaryCommand.wireFormat == "010D0C")
        let sent = await harness.mock.sentCommands
        #expect(!sent.contains("010D0C1"), "no suffix under functional addressing")
        #expect(!sent.contains("ATAT2") || sent.firstIndex(of: "ATAT2")! > sent.firstIndex(of: "010D0C")!,
                "ATAT2 only in the comparison, not as the remembered level")
        #expect(await harness.session.rememberedPlan == Self.remembered(info.plan))
    }

    @Test("A remembered functional plan is not reused when ATSH7E0 is accepted this time")
    func functionalPlanInvalidWhenGateOpens() async throws {
        var functional = Self.benchPlan(adaptiveTiming: 1)
        functional.responseCount = nil
        functional.requestHeader = nil
        let harness = SessionHarness(
            rules: MockELMAdapter.Rule.benchCar, configuration: Self.probing, rememberedPlan: Self.remembered(functional)
        )
        let info = try await harness.initialise()
        #expect(await Self.reuseNotes(harness.log) == [
            "remembered poll plan not reused: chosen with requestHeader 7DF, this handshake left requests at 7E0; selecting again",
        ])
        #expect(info.plan == Self.benchPlan(adaptiveTiming: 1))
    }

    @Test("A different ATZ banner invalidates the remembered plan")
    func bannerChangeInvalidates() async throws {
        let harness = SessionHarness(
            rules: MockELMAdapter.Rule.benchCar, configuration: Self.probing,
            rememberedPlan: Self.remembered(banner: "ELM327 v1.5")
        )
        let info = try await harness.initialise()
        #expect(await Self.reuseNotes(harness.log) == [
            "remembered poll plan not reused: chosen on ELM327 v1.5, this adapter reports ELM327 v2.3; selecting again",
        ])
        #expect(info.plan == Self.benchPlan(adaptiveTiming: 1))
        #expect(await harness.session.rememberedPlan == Self.remembered(info.plan))
    }

    @Test("A remembered plan that fails validate() is not reused, even when the addressing matches")
    func invalidPlanNotReused() async throws {
        var suffixFunctional = Self.benchPlan(adaptiveTiming: 1)
        suffixFunctional.requestHeader = nil
        let harness = SessionHarness(
            rules: [Rule(command: "ATSH7E0", reply: "?\r\r>", delay: .milliseconds(10))] + MockELMAdapter.Rule.benchCar,
            configuration: Self.probing,
            rememberedPlan: Self.remembered(suffixFunctional)
        )
        let info = try await harness.initialise()
        let notes = await Self.reuseNotes(harness.log)
        #expect(notes.count == 1)
        #expect(notes.first?.hasPrefix("remembered poll plan not reused: invalid (") == true)
        #expect(info.plan.primaryCommand.wireFormat == "010D0C")
        #expect(!(await harness.mock.sentCommands).contains("010D0C1"))
    }

    @Test("No remembered plan: selection and the comparison as before; the chosen plan becomes the remembered one")
    func noRememberedPlan() async throws {
        let harness = SessionHarness(rules: MockELMAdapter.Rule.benchCar, configuration: Self.probing)
        let info = try await harness.initialise()
        #expect(await Self.reuseNotes(harness.log).isEmpty)
        let probes = await harness.log.exchanges.filter { $0.phase == .probe }
        #expect(probes.first?.tx == "ATAT1")
        #expect(probes.filter { $0.tx == "010D0C1" }.count == probeSendsOfChosenCommand)
        #expect(info.plan == Self.benchPlan(adaptiveTiming: 1))
        #expect(await harness.session.rememberedPlan == Self.remembered(info.plan))
    }

    @Test("Without probing the remembered plan is ignored and kept")
    func probeOffIgnoresIt() async throws {
        let remembered = Self.remembered()
        let harness = SessionHarness(rules: MockELMAdapter.Rule.benchCarInstant, configuration: .fastTest, rememberedPlan: remembered)
        let info = try await harness.initialise()
        #expect(await Self.reuseNotes(harness.log).isEmpty)
        #expect(info.plan.primaryCommand.wireFormat == "010D")
        #expect(await harness.session.rememberedPlan == remembered)
    }

    @Test("NO DATA rule after a reuse: the check poll counts as answered OK, so a later NO DATA is a failure, nothing dropped")
    func noDataAfterReuseIsFailure() async throws {
        let ok = "7E806410D000C0A5C\r\r>"
        let harness = SessionHarness(
            rules: [
                Rule(command: "010D0C1", reply: ok, delay: .milliseconds(20), times: 1),
                Rule(command: "010D0C1", reply: "NO DATA\r\r>", delay: .milliseconds(20), times: 1),
            ] + MockELMAdapter.Rule.benchCar,
            configuration: Self.probing,
            rememberedPlan: Self.remembered()
        )
        let info = try await harness.initialise()
        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.readings.count >= 4 }
        try await harness.stopPolling()

        let polls = await harness.log.exchanges.filter { $0.phase == .poll }
        #expect(polls.first?.outcome == .noData)
        #expect(polls.allSatisfy { $0.tx == "010D0C1" }, "multi-PID kept, nothing dropped")
        #expect(await harness.log.transitions.contains { $0.to == .retrying && $0.reason == "noData" })
        #expect(await harness.log.adapterInfos.count == 1, "no re-announcement: the plan did not change")
    }
}
