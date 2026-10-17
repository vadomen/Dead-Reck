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

    /// The bench car as the handshake sees it: `ATDPN` `A6`, 7E8's `0100`
    /// bitmask `BE1CA813` (M7.1-3).
    static let benchVehicle = RememberedPollingPlan.VehicleKey(protocolNumber: "A6", supportedPIDs: "BE1CA813")

    static func remembered(
        _ plan: PollingPlan = benchPlan(),
        banner: String = benchBanner,
        vehicle: RememberedPollingPlan.VehicleKey? = benchVehicle
    ) -> RememberedPollingPlan {
        RememberedPollingPlan(plan: plan, elmVersion: banner, vehicle: vehicle)
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

// Review run 7, round 1 follow-ups (M7.1-1, M7.1-2, M7.1-6).
@Suite("ELMSession remembered poll plan follow-ups (M7.1)", .timeLimit(.minutes(1)))
struct ELMSessionPlanReuseFollowUpTests {
    typealias Rule = MockELMAdapter.Rule
    typealias Reuse = ELMSessionPlanReuseTests

    static let probing = ELMSessionProbeTests.probing
    static let checkOK = "7E806410D000C0A5C\r\r>"

    // MARK: M7.1-1

    @Test("M7.1-1: a selection that dropped a PID on NO DATA is not remembered, so the PID gets a fresh chance next time")
    func droppedPIDNotRemembered() async throws {
        // Under 7E0 RPM never answers: every step with 010C fails, and the
        // plain 010C's NO DATA drops it (never answered OK). 010D1 then wins.
        let noRPM = [
            Rule(command: "010D0C1", reply: "NO DATA\r\r>", delay: .milliseconds(30), requestHeader: "7E0"),
            Rule(command: "010C1", reply: "NO DATA\r\r>", delay: .milliseconds(30), requestHeader: "7E0"),
            Rule(command: "010D", reply: "7E803410D00\r\r>", delay: .milliseconds(60), requestHeader: "7E0"),
            Rule(command: "010C", reply: "NO DATA\r\r>", delay: .milliseconds(60), requestHeader: "7E0"),
        ]
        let harness = SessionHarness(rules: noRPM + MockELMAdapter.Rule.benchCar, configuration: Self.probing)
        let info = try await harness.initialise()

        #expect(info.plan.pids == [.vehicleSpeed], "RPM dropped for this session")
        #expect(info.plan.primaryCommand.wireFormat == "010D1")
        #expect(await harness.session.rememberedPlan == nil, "a degraded plan is not carried to the next connection")
    }

    @Test("M7.1-1: a remembered plan is replaced by nil when this init's selection dropped a PID")
    func droppedPIDClearsRemembered() async throws {
        // The remembered plan's check fails (RPM NO DATA), selection drops RPM.
        let noRPM = [
            Rule(command: "010D0C1", reply: "NO DATA\r\r>", delay: .milliseconds(30), requestHeader: "7E0"),
            Rule(command: "010C1", reply: "NO DATA\r\r>", delay: .milliseconds(30), requestHeader: "7E0"),
            Rule(command: "010D", reply: "7E803410D00\r\r>", delay: .milliseconds(60), requestHeader: "7E0"),
            Rule(command: "010C", reply: "NO DATA\r\r>", delay: .milliseconds(60), requestHeader: "7E0"),
        ]
        let harness = SessionHarness(
            rules: noRPM + MockELMAdapter.Rule.benchCar, configuration: Self.probing, rememberedPlan: Reuse.remembered()
        )
        let info = try await harness.initialise()
        #expect(info.plan.pids == [.vehicleSpeed])
        #expect(await harness.session.rememberedPlan == nil)
    }

    // MARK: M7.1-2

    /// The remembered bench plan passes its check, then every poll fails.
    static func failingAfterCheck() -> [Rule] {
        [
            Rule(command: "010D0C1", reply: checkOK, delay: .milliseconds(20), times: 1, requestHeader: "7E0"),
            Rule(command: "010D0C1", reply: "CAN ERROR\r\r>", delay: .milliseconds(20), requestHeader: "7E0"),
        ] + MockELMAdapter.Rule.benchCar
    }

    @Test("M7.1-2: polling that escalates to failed + needsReconnect clears the remembered plan")
    func pollFailureClearsRememberedPlan() async throws {
        let harness = SessionHarness(rules: Self.failingAfterCheck(), configuration: Self.probing, rememberedPlan: Reuse.remembered())
        let info = try await harness.initialise()
        #expect(await harness.session.rememberedPlan == Reuse.remembered(), "the check passed: reused and kept")
        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.reconnectRequests == 1 }

        #expect(await harness.session.state == .failed)
        #expect(await harness.session.rememberedPlan == nil, "the next connection selects again")
    }

    @Test("M7.1-2: a transport loss while polling keeps the remembered plan")
    func transportLossKeepsRememberedPlan() async throws {
        let harness = SessionHarness(rules: MockELMAdapter.Rule.benchCar, configuration: Self.probing, rememberedPlan: Reuse.remembered())
        let info = try await harness.initialise()
        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.readings.count >= 4 }
        await harness.mock.disconnect()
        await harness.run { await $0.states.last == .failed }

        #expect(await harness.log.reconnectRequests == 0)
        #expect(await harness.session.rememberedPlan == Reuse.remembered())
    }

    // MARK: M7.1-6

    @Test("M7.1-6: reuse fails when ATAT<n> is not accepted; the full selection runs")
    func refusedATATFallsBack() async throws {
        let harness = SessionHarness(
            rules: [Rule(command: "ATAT2", reply: "?\r\r>", delay: .milliseconds(10), times: 1)] + MockELMAdapter.Rule.benchCar,
            configuration: Self.probing,
            rememberedPlan: Reuse.remembered()
        )
        let info = try await harness.initialise()

        #expect(await Reuse.reuseNotes(harness.log) == [
            "poll plan reused from the previous connection: 010D0C1, ATAT2, requestHeader 7E0",
            "reused plan failed (ATAT2 not accepted (notRecognised)); selecting again",
        ])
        let probes = await harness.log.exchanges.filter { $0.phase == .probe }.map(\.tx)
        #expect(Array(probes.prefix(2)) == ["ATAT2", "ATAT1"], "no check poll after the refused ATAT2")
        #expect(info.plan == Reuse.benchPlan(adaptiveTiming: 1))
        #expect(await harness.session.rememberedPlan == Reuse.remembered(info.plan))
    }

    @Test("M7.1-6: a single-PID remembered plan checks every PID once (cycle 0) and is reused")
    func singlePIDPlanReused() async throws {
        var single = Reuse.benchPlan(adaptiveTiming: 1)
        single.multiPID = false
        let harness = SessionHarness(
            rules: [Rule(command: "010C1", reply: "7E804410C0A5C\r\r>", delay: .milliseconds(40), requestHeader: "7E0")]
                + MockELMAdapter.Rule.benchCar,
            configuration: Self.probing,
            rememberedPlan: Reuse.remembered(single)
        )
        let info = try await harness.initialise()

        #expect(info.plan == single)
        #expect(await harness.mock.sentCommands == Reuse.handshake + ["ATAT1", "010D1", "010C1"])
        #expect(await Reuse.reuseNotes(harness.log) == [
            "poll plan reused from the previous connection: 010D1, ATAT1, requestHeader 7E0",
        ])
        #expect(await harness.session.rememberedPlan == Reuse.remembered(single))
    }

    @Test("M7.1-6: a late ATSH7E0 OK is settled before the reuse check, so a 7E0 plan is reused")
    func lateATSHSettledBeforeReuse() async throws {
        // 300 ms: past the 200 ms timeout, inside the grace period.
        let harness = SessionHarness(
            rules: [Rule(command: "ATSH7E0", reply: "OK\r\r>", delay: .milliseconds(300), times: 1)] + MockELMAdapter.Rule.benchCar,
            configuration: Self.probing,
            rememberedPlan: Reuse.remembered()
        )
        let info = try await harness.initialise()

        let notes = await Reuse.notes(harness.log)
        let late = try #require(notes.firstIndex { $0.hasPrefix("late OK for ATSH7E0") })
        let reused = try #require(notes.firstIndex { $0.hasPrefix("poll plan reused from the previous connection") })
        #expect(late < reused, "the late OK landed before the reuse decision")
        #expect(!notes.contains { $0.hasPrefix("remembered poll plan not reused") })
        #expect(info.plan == Reuse.benchPlan())
        #expect(await harness.mock.sentCommands == Reuse.handshake + ["ATAT2", "010D0C1"])
    }
}

// M7.1-3 (user decision: fix): the reuse key was the peripheral and the ATZ
// banner, which identify the adapter, not the car. The plan now also carries
// ATDPN and the primary ECU's 0100 bitmask; a mismatch, or a plan without
// them, means it is not reused.
@Suite("ELMSession remembered poll plan: vehicle key (M7.1-3)", .timeLimit(.minutes(1)))
struct ELMSessionPlanReuseVehicleTests {
    typealias Reuse = ELMSessionPlanReuseTests
    typealias Key = RememberedPollingPlan.VehicleKey

    static let probing = ELMSessionProbeTests.probing

    @Test("Selection remembers the vehicle key from ATDPN and 7E8's 0100 answer")
    func selectionRecordsKey() async throws {
        let harness = SessionHarness(rules: MockELMAdapter.Rule.benchCar, configuration: Self.probing)
        let info = try await harness.initialise()
        let remembered = try #require(await harness.session.rememberedPlan)
        #expect(remembered.vehicle == Reuse.benchVehicle)
        #expect(remembered == Reuse.remembered(info.plan))
    }

    @Test(
        "A different vehicle, or a plan without a key, is not reused; selection runs and the new key is remembered",
        arguments: [
            (Key(protocolNumber: "A8", supportedPIDs: "BE1CA813") as Key?,
             "chosen on protocol A8, this vehicle reports A6"),
            (Key(protocolNumber: "A6", supportedPIDs: "BE3FA813") as Key?,
             "chosen on a vehicle whose 7E8 0100 bitmask is BE3FA813, this one reports BE1CA813"),
            (Key(protocolNumber: "A6", supportedPIDs: nil) as Key?,
             "chosen on a vehicle whose 7E8 0100 bitmask is absent, this one reports BE1CA813"),
            (nil, "chosen without a vehicle key (ATDPN, 7E8 0100 bitmask)"),
        ]
    )
    func otherVehicleNotReused(vehicle: Key?, why: String) async throws {
        let harness = SessionHarness(
            rules: MockELMAdapter.Rule.benchCar, configuration: Self.probing,
            rememberedPlan: Reuse.remembered(vehicle: vehicle)
        )
        let info = try await harness.initialise()

        #expect(await Reuse.reuseNotes(harness.log) == ["remembered poll plan not reused: \(why); selecting again"])
        let probes = await harness.log.exchanges.filter { $0.phase == .probe }
        #expect(probes.first?.tx == "ATAT1", "selection, not the remembered ATAT2 and a check poll")
        #expect(info.plan == Reuse.benchPlan(adaptiveTiming: 1), "selected again")
        #expect(await harness.session.rememberedPlan == Reuse.remembered(info.plan), "now keyed on this vehicle")
    }

    @Test("ATDPN 6 and A6 are the same protocol (A only means auto-detected): reused")
    func autoPrefixIgnored() async throws {
        let harness = SessionHarness(
            rules: MockELMAdapter.Rule.benchCar, configuration: Self.probing,
            rememberedPlan: Reuse.remembered(vehicle: Key(protocolNumber: "6", supportedPIDs: "BE1CA813"))
        )
        let info = try await harness.initialise()
        #expect(info.plan == Reuse.benchPlan())
        #expect(await harness.mock.sentCommands == Reuse.handshake + ["ATAT2", "010D0C1"])
    }

    @Test("The bitmask comes from 7E8's intact answer: 7E9's answer, and a bad 7E9 line, don't change it")
    func bitmaskFromPrimary() {
        #expect(ELMSession.primarySupportedPIDs("7E906410098180001\r7E8064100BE1CA813\r\r") == "BE1CA813")
        #expect(ELMSession.primarySupportedPIDs("SEARCHING...\r7E9064100\r7E8064100BE1CA813\r\r") == "BE1CA813")
        #expect(ELMSession.primarySupportedPIDs("7E906410098180001\r\r") == nil, "no 7E8 answer")
        #expect(ELMSession.primarySupportedPIDs("7E80641\r\r") == nil, "7E8 cut short")
        #expect(ELMSession.primarySupportedPIDs(nil) == nil)
    }

    @Test("A key-less plan built with the old initialiser still constructs and compares; it just isn't reusable")
    func keylessPlanIsHarmless() {
        let old = RememberedPollingPlan(plan: Reuse.benchPlan(), elmVersion: Reuse.benchBanner)
        #expect(old.vehicle == nil)
        #expect(old != Reuse.remembered())
    }
}
