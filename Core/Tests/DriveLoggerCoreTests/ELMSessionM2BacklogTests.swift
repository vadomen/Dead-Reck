import Foundation
import Testing

@testable import DriveLoggerCore

// Regression tests for the ELM backlog items closed in M2 part 1
// (docs/BACKLOG.md): M1-E4, M1-E5, B1-3, R2.1-2, R2.2-1, R2.2-2, R2.2-3.

/// M1-E4: late replies in double-failure cases go to the command that
/// produced them.
@Suite("ELMSession late-row labelling (M1-E4, M1-E5)", .timeLimit(.minutes(1)))
struct ELMSessionLateRowLabellingTests {
    /// Writes `010D` off: it times out (never answered), then the next manual
    /// command finds its prompt missing and throws `.desynchronised`.
    static func writeOff(_ command: String, in harness: SessionHarness) async throws {
        let session = harness.session
        let first = try await drive(harness.clock) { try await session.sendManual(command) }
        #expect(first.outcome == .timeout)
        await #expect(throws: ELMSessionError.desynchronised) {
            _ = try await drive(harness.clock) { try await session.sendManual("ATRV") }
        }
    }

    // M1-E4 (1): a timed-out ATZ's banner used to be paid to an older
    // written-off data command.
    @Test("A timed-out ATZ's late banner is ATZ's late row, not an older written-off data command's")
    func timedOutATZBanner() async throws {
        let harness = SessionHarness(rules: [
            .init(command: "ATZ", reply: "ATZ\r\r\rELM327 v2.1\r\r>", delay: .zero, times: 1),
            .init(command: "010D", reply: nil, times: 1),
            .init(command: "ATZ", reply: "ATZ\r\r\rELM327 v1.9\r\r>", delay: .milliseconds(500), times: 1),
        ] + MockELMAdapter.Rule.touaregInstant)
        _ = try await harness.initialise()
        try await Self.writeOff("010D", in: harness)
        await #expect(throws: ELMSessionError.initFailed(step: "ATZ", reason: "timeout")) {
            _ = try await harness.initialise()
        }
        await harness.run { await $0.exchanges.contains { $0.rx == "ATZ\r\r\rELM327 v1.9\r\r" } }

        let exchanges = await harness.log.exchanges
        let banner = try #require(exchanges.first { $0.rx == "ATZ\r\r\rELM327 v1.9\r\r" })
        #expect(banner.tx == "ATZ")
        #expect(banner.outcome == .timeout)
        #expect(!exchanges.contains { $0.tx == "010D" && $0.rx != nil }, "010D never answered")
    }

    // M1-E4 (2): output right after the ATZ banner, before run() resumed,
    // used to be paid to a written-off command.
    @Test("Output right behind the ATZ banner is unsolicited, not a written-off command's reply")
    func outputBehindBanner() async throws {
        let harness = SessionHarness(rules: [
            .init(command: "ATZ", reply: "ATZ\r\r\rELM327 v2.1\r\r>", delay: .zero, times: 1),
            .init(command: "010D", reply: nil, times: 1),
            .init(command: "ATZ", reply: "ATZ\r\r\rELM327 v2.1\r\r>7E803410D3C\r\r>", delay: .milliseconds(10), times: 1),
        ] + MockELMAdapter.Rule.touaregInstant)
        _ = try await harness.initialise()
        try await Self.writeOff("010D", in: harness)
        let info = try await harness.initialise()
        #expect(info.elmVersion == "ELM327 v2.1")

        let exchanges = await harness.log.exchanges
        let stray = try #require(exchanges.first { $0.rx == "7E803410D3C\r\r" })
        #expect(stray.tx == "", "the adapter was reset: nothing is owed any more")
        #expect(!exchanges.contains { $0.tx == "010D" && $0.rx != nil })
    }

    // M1-E4 (3): shutdown while ATZ waits out its full window used to record
    // ATZ's own held banner as unsolicited.
    @Test("Shutdown during a full-window ATZ: held banners go to the written-off ATI and to the ATZ itself")
    func shutdownDuringFullWindowATZ() async throws {
        let harness = SessionHarness(rules: [
            .init(command: "ATZ", reply: "ATZ\r\r\rELM327 v2.1\r\r>", delay: .zero, times: 1),
            .init(command: "ATI", reply: "ELM327 v2.1\r\r>", delay: .milliseconds(250), times: 1),
            .init(command: "ATZ", reply: "ATZ\r\r\rELM327 v2.2\r\r>", delay: .milliseconds(50), times: 1),
        ] + MockELMAdapter.Rule.touaregInstant)
        _ = try await harness.initialise()
        try await Self.writeOff("ATI", in: harness)

        let session = harness.session
        let mock = harness.mock
        let initialising = Task { try await session.initialise() }
        await harness.run { _ in await mock.sentCommands.filter { $0 == "ATZ" }.count == 2 }
        // Both banners are in and held; the 300 ms window is still open.
        await harness.clock.advance(by: .milliseconds(150))
        await session.shutdown()
        _ = try? await initialising.value
        await harness.run { await $0.finished }

        let exchanges = await harness.log.exchanges
        #expect(exchanges.first { $0.rx == "ELM327 v2.1\r\r" }?.tx == "ATI")
        let own = try #require(exchanges.first { $0.rx == "ATZ\r\r\rELM327 v2.2\r\r" })
        #expect(own.tx == "ATZ")
        #expect(own.outcome == .timeout)
        #expect(!exchanges.contains { $0.tx == "" && $0.rx != nil }, "nothing unsolicited")
        let atzTimeout = try #require(exchanges.last { $0.tx == "ATZ" && $0.rx == nil })
        #expect(atzTimeout.seq < own.seq, "the abandoned ATZ's row comes before its late banner")
    }

    // M1-E5 (1): kills the mutant "resynchronised() keeps writtenOff".
    @Test("After ATZ resynchronises, a stray reply is unsolicited, not the written-off command's")
    func resyncClearsWrittenOff() async throws {
        let harness = SessionHarness(rules: [
            .init(command: "010D", reply: nil, times: 1),
        ] + MockELMAdapter.Rule.touaregInstant)
        _ = try await harness.initialise()
        try await Self.writeOff("010D", in: harness)
        _ = try await harness.initialise()

        await harness.mock.emitUnsolicited("7E803410D3C\r\r>")
        await harness.run { await $0.exchanges.contains { $0.rx == "7E803410D3C\r\r" } }
        #expect(await harness.log.exchanges.first { $0.rx == "7E803410D3C\r\r" }?.tx == "")
    }

    // M1-E5 (2): kills the mutant "pay owed before written-off while
    // desynchronised". ATI was written off before the ATZ timed out, so a
    // banner pays ATI first.
    @Test("While desynchronised, a reply pays the written-off command before the owed one")
    func writtenOffBeforeOwed() async throws {
        let harness = SessionHarness(rules: [
            .init(command: "ATZ", reply: "ATZ\r\r\rELM327 v2.1\r\r>", delay: .zero, times: 1),
            .init(command: "ATI", reply: nil, times: 1),
            .init(command: "ATZ", reply: nil, times: 1),
        ] + MockELMAdapter.Rule.touaregInstant)
        _ = try await harness.initialise()
        try await Self.writeOff("ATI", in: harness)
        await #expect(throws: ELMSessionError.initFailed(step: "ATZ", reason: "timeout")) {
            _ = try await harness.initialise()
        }

        await harness.mock.emitUnsolicited("ELM327 v2.1\r\r>")
        await harness.mock.emitUnsolicited("ATZ\r\r\rELM327 v2.1\r\r>")
        await harness.run { await $0.exchanges.filter { $0.rx != nil && $0.outcome == .timeout }.count >= 2 }
        let late = await harness.log.exchanges.filter { $0.rx != nil && $0.outcome == .timeout }
        #expect(late.map(\.tx) == ["ATI", "ATZ"])
    }
}

/// B1-3, R2.1-2: what goes out is checked against the plan's addressing
/// after late prompts have settled, not before.
@Suite("ELMSession addressing settles before a poll (B1-3, R2.1-2)", .timeLimit(.minutes(1)))
struct ELMSessionAddressingSettleTests {
    // B1-3: probe off, ATSH7E0 answered late (inside the grace period), so
    // the adapter is physical while the plan says functional.
    @Test("probe off, late ATSH7E0 OK: ATSH7DF goes out before the first poll")
    func lateATSH7E0WithoutProbe() async throws {
        let harness = SessionHarness(rules: [
            .init(command: "ATSH7E0", reply: "OK\r\r>", delay: .milliseconds(150), times: 1),
        ] + MockELMAdapter.Rule.touaregInstant)
        let info = try await harness.initialise()
        #expect(info.plan.requestHeader == nil)
        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.readings.count >= 2 }
        try await harness.stopPolling()

        let sent = await harness.mock.sentCommands
        let firstPoll = try #require(sent.firstIndex(of: "010D"))
        #expect(sent[handshakeWires.count..<firstPoll].contains("ATSH7DF"), "sent: \(sent)")
        #expect(await harness.log.transitions.contains { $0.reason == "late OK for ATSH7E0; requests go to 7E0" })
        #expect(await harness.mock.requestHeader == "7DF")
    }

    // R2.1-2: a late ATSH7DF OK flips the adapter to functional just before
    // a suffixed poll.
    @Test("A late ATSH7DF OK before a suffixed poll: ATSH7E0 again, the suffix never goes out functionally")
    func lateATSH7DFBeforeSuffixPoll() async throws {
        let harness = SessionHarness(rules: [
            .init(command: "ATSH7DF", reply: "OK\r\r>", delay: .milliseconds(150), times: 1),
        ] + MockELMAdapter.Rule.benchCarInstant)
        let info = try await harness.initialise()
        #expect(await harness.mock.requestHeader == "7E0")
        // A functional plan: the loop sends ATSH7DF, which times out.
        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.exchanges.contains { $0.tx == "ATSH7DF" && $0.outcome == .timeout } }
        try await harness.stopPolling()

        let physical = PollingPlan(
            pids: [.vehicleSpeed, .engineSpeed], multiPID: true, responseCount: 1,
            adaptiveTiming: 1, rpmEvery: 5, timeout: .milliseconds(100), requestHeader: .engine
        )
        try await harness.session.startPolling(physical)
        await harness.run { await $0.readings.count >= 2 }
        try await harness.stopPolling()

        let sent = await harness.mock.sentCommands
        let tail = Array(sent[(try #require(sent.firstIndex(of: "ATSH7DF")) + 1)...])
        let firstSuffix = try #require(tail.firstIndex(where: hasResponseCountSuffix))
        #expect(tail[..<firstSuffix].contains("ATSH7E0"), "sent after ATSH7DF: \(tail)")
        #expect(!(await harness.log.exchanges.contains { $0.outcome == .rejected }))
        let readings = await harness.log.readings
        #expect(readings.allSatisfy { $0.ecu == "7E8" && $0.command == "010D0C1" })
    }
}

/// R2.2-1, R2.2-2: the plan polled follows the gate at every re-init, both
/// ways, and an `adapter` row never announces a plan that isn't polled.
@Suite("ELMSession effective plan follows the gate (R2.2-1, R2.2-2)", .timeLimit(.minutes(1)))
struct ELMSessionEffectivePlanTests {
    static let probing = ELMSessionProbeTests.probing

    @Test("Gate closes at one re-init and reopens at the next: functional, then physical again; no stale adapter row")
    func gateClosesThenReopens() async throws {
        let ok7E8 = "7E806410D3C0C0BB8\r\r>"
        let harness = SessionHarness(
            rules: [
                .init(command: "0100", reply: "SEARCHING...\r7E8064100BE3FA813\r7E906410098180001\r\r>", delay: .milliseconds(30), times: 1),
                .init(command: "0100", reply: "7E906410098180001\r\r>", delay: .milliseconds(30), times: 1),
                .init(command: "010D0C1", reply: ok7E8, delay: .milliseconds(30), times: probeSendsOfChosenCommand + 2, requestHeader: "7E0"),
                .init(command: "010D0C1", reply: "CAN ERROR\r\r>", delay: .milliseconds(30), times: 3, requestHeader: "7E0"),
                .init(command: "010D0C", reply: ok7E8, delay: .milliseconds(30), times: 2, requestHeader: "7DF"),
                .init(command: "010D0C", reply: "CAN ERROR\r\r>", delay: .milliseconds(30), times: 3, requestHeader: "7DF"),
            ] + MockELMAdapter.Rule.touareg,
            configuration: Self.probing
        )
        let info = try await harness.initialise()
        #expect(info.plan.primaryCommand.wireFormat == "010D0C1")
        try await harness.session.startPolling(info.plan)
        await harness.run { log in
            let readings = await log.readings
            return await log.adapterInfos.count >= 3 && readings.count >= 8 && readings.last?.command == "010D0C1"
        }
        try await harness.stopPolling()

        let plans = await harness.log.adapterInfos.map(\.plan)
        #expect(plans.map(\.requestHeader) == [.engine, nil, .engine], "plans: \(plans)")
        #expect(plans.map(\.primaryCommand.wireFormat) == ["010D0C1", "010D0C", "010D0C1"])
        let sent = await harness.mock.sentCommands
        let lastATZ = try #require(sent.lastIndex(of: "ATZ"))
        #expect(!sent[lastATZ...].contains("ATSH7DF"), "reopened gate: no detour through functional")
        #expect(sent[lastATZ...].contains("ATSH7E0"))
        let notes = await harness.log.transitions.filter { $0.from == $0.to }.compactMap(\.reason)
        #expect(notes.contains { $0.hasPrefix("physical addressing unavailable") })
        #expect(notes.contains { $0.hasPrefix("physical addressing available again") })
        #expect(await harness.log.readings.last?.command == "010D0C1")
    }

    @Test("A physical plan passed to startPolling on a gate-closed car is never announced")
    func physicalPlanNeverAnnounced() async throws {
        let harness = SessionHarness(
            rules: gateCarRules(
                dpn: "A7",
                supported: "18DAF110064100BE3FA813",
                functional: ["010D0C": "18DAF11006410D3C0C0BB8"]
            )
        )
        _ = try await harness.initialise()
        let plan = PollingPlan(
            pids: [.vehicleSpeed, .engineSpeed], multiPID: true, responseCount: 1,
            adaptiveTiming: 1, rpmEvery: 5, timeout: .milliseconds(100), requestHeader: .engine
        )
        try await harness.session.startPolling(plan)
        await harness.run { await $0.readings.count >= 2 }
        try await harness.stopPolling()

        let plans = await harness.log.adapterInfos.map(\.plan)
        #expect(plans.allSatisfy { $0.requestHeader == nil && $0.responseCount == nil }, "plans: \(plans)")
        #expect(plans.last?.primaryCommand.wireFormat == "010D0C")
        #expect(await harness.log.transitions.contains { $0.reason?.hasPrefix("physical addressing unavailable") == true })
    }
}

/// R2.2-3: the functional re-selection's `ATSH7DF` has a fallback.
@Suite("ELMSession ATSH7DF fallback (R2.2-3)", .timeLimit(.minutes(1)))
struct ELMSessionFunctionalFallbackTests {
    static let probing = ELMSessionProbeTests.probing

    static func rules(atsh7df: MockELMAdapter.Rule?) -> [MockELMAdapter.Rule] {
        (atsh7df.map { [$0] } ?? []) + gateCarRules(
            dpn: "A6",
            supported: PhysicalAddressingGateTests.engine0100,
            functional: ["010D0C": "7E806410D3C0C0BB8\r7E906410D3B0C0BB8"]
        )
    }

    @Test("ATSH7DF times out but its OK comes late: the functional pass still runs")
    func lateOK() async throws {
        let harness = SessionHarness(
            rules: Self.rules(atsh7df: .init(command: "ATSH7DF", reply: "OK\r\r>", delay: .milliseconds(300), times: 1)),
            configuration: Self.probing
        )
        let info = try await harness.initialise()
        #expect(info.plan.primaryCommand.wireFormat == "010D0C", "not the baseline")
        #expect(info.plan.requestHeader == nil)
        #expect(await harness.mock.sentCommands.filter { $0 == "ATZ" }.count == 1)
        #expect(await harness.log.transitions.contains { $0.reason == "late OK for ATSH7DF; requests go to 7DF" })
    }

    @Test("ATSH7DF refused or never answered: re-initialise without ATSH7E0, then the functional pass", arguments: [true, false])
    func refusedOrLost(refused: Bool) async throws {
        let rule = MockELMAdapter.Rule(command: "ATSH7DF", reply: refused ? "?\r\r>" : nil, delay: .milliseconds(10))
        let harness = SessionHarness(rules: Self.rules(atsh7df: rule), configuration: Self.probing)
        let info = try await harness.initialise()
        #expect(info.plan.primaryCommand.wireFormat == "010D0C")
        #expect(info.plan.requestHeader == nil)

        let sent = await harness.mock.sentCommands
        #expect(sent.filter { $0 == "ATZ" }.count == 2)
        let secondATZ = try #require(sent.lastIndex(of: "ATZ"))
        #expect(!sent[secondATZ...].contains { $0.hasPrefix("ATSH") }, "physical addressing disabled: no ATSH at all")
        let notes = await harness.log.transitions.filter { $0.from == $0.to }.compactMap(\.reason)
        #expect(notes.contains { $0.contains("physical addressing disabled for this session") })
        #expect(notes.contains { $0.hasPrefix("ATSH7E0 skipped: physical addressing disabled for this session") })

        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.readings.count >= 4 }
        try await harness.stopPolling()
        #expect(await harness.log.reconnectRequests == 0)
        #expect(!(await harness.mock.sentCommands[secondATZ...].contains { $0.hasPrefix("ATSH") }))
    }

    @Test("While polling, ATSH7DF refused after a re-init re-enabled 7E0: re-init without ATSH7E0, no reconnect")
    func refusedWhilePolling() async throws {
        let harness = SessionHarness(
            rules: [
                benchRule("ATSH7E0", "?\r\r>", times: 1),
                benchRule("010D", "CAN ERROR\r\r>", header: "7DF", times: 3),
                benchRule("ATSH7DF", "?\r\r>"),
                // Not in the bench transcript; the baseline polls RPM singly.
                benchRule("010C", "7E904410C0A5C\r7E804410C0A5C\r\r>", header: "7DF"),
            ] + MockELMAdapter.Rule.benchCarInstant
        )
        let info = try await harness.initialise()
        #expect(info.plan.requestHeader == nil)
        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.readings.count >= 4 }
        try await harness.stopPolling()

        let sent = await harness.mock.sentCommands
        #expect(sent.filter { $0 == "ATSH7DF" }.count == 1)
        let lastATZ = try #require(sent.lastIndex(of: "ATZ"))
        #expect(!sent[lastATZ...].contains { $0.hasPrefix("ATSH") })
        #expect(await harness.log.reconnectRequests == 0)
        #expect(await harness.mock.requestHeader == "7DF")
        #expect(await harness.log.readings.allSatisfy { $0.command == "010D" || $0.command == "010C" })
    }
}
