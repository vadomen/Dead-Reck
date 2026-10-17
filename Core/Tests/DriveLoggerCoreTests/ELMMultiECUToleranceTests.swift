import Foundation
import Testing

@testable import DriveLoggerCore

// M1-E1 (user decision: fix): with functional addressing several ECUs answer
// one request. A malformed or status line from any of them used to fail the
// whole exchange, discarding the engine ECU's (7E8) good reading, and enough
// of them pushed the session into retry → re-init. Replies are now parsed
// per ECU: an ECU whose lines don't parse is left out, the others' answers
// are kept, and the exchange succeeds if the primary ECU's answer decoded.

@Suite("ELMSession per-ECU tolerant replies (M1-E1)", .timeLimit(.minutes(1)))
struct ELMSessionMultiECUToleranceTests {
    typealias Rule = MockELMAdapter.Rule

    /// No probing: the baseline plan polls `010D` functionally every cycle.
    /// Replies arrive in 7-byte BLE notifications.
    static func harness(speedReply: String) -> SessionHarness {
        SessionHarness(rules: [
            Rule(command: "010D", reply: speedReply, delay: .milliseconds(10), fragmentSizes: [7]),
        ] + pacedRules())
    }

    static func speedPolls(_ log: EventLog) async -> [ELMExchange] {
        await log.exchanges.filter { $0.phase == .poll && $0.tx == "010D" }
    }

    @Test(
        "7E8 good plus a bad line from another ECU: the exchange is ok, 7E8's value is kept, the raw reply is recorded whole",
        arguments: [
            // 7E9's single frame is cut short (PCI 03, two data bytes).
            "7E803410D3C\r7E903410D\r\r>",
            // The same, 7E9 first: arrival order doesn't matter.
            "7E903410D\r7E803410D3C\r\r>",
            // Non-hex garbage from a module, after SEARCHING... and an echo.
            "010D\rSEARCHING...\r7E803410D3C\r7E9#41@0D\r\r>",
            // NO DATA printed alongside 7E8's answer.
            "7E803410D3C\rNO DATA\r\r>",
            // Another status line.
            "7E803410D3C\rCAN ERROR\r\r>",
        ]
    )
    func primaryGoodOtherBad(reply: String) async throws {
        let harness = Self.harness(speedReply: reply)
        let info = try await harness.initialise()
        try await harness.session.startPolling(info.plan)
        await harness.run { await Self.speedPolls($0).count >= 4 }
        try await harness.stopPolling()

        let polls = await Self.speedPolls(harness.log)
        #expect(polls.allSatisfy { $0.outcome == .ok })
        let expectedRaw = String(reply.dropLast())   // the framer strips the prompt
        #expect(polls.allSatisfy { $0.rx == expectedRaw }, "never drop the raw response")
        let speed = await harness.log.readings.filter { $0.measurement.pid == .vehicleSpeed }
        #expect(speed.count >= 4)
        #expect(speed.allSatisfy { $0.ecu == "7E8" && $0.measurement.value == 60 && $0.raw == expectedRaw })
        #expect(!(await harness.log.states).contains(.retrying), "no retry, no re-init")
        #expect(await harness.log.reconnectRequests == 0)
    }

    @Test("7E8 and 7E9 good, a third ECU (7EA) cut short: both good answers are kept")
    func otherGoodAnswersKept() async throws {
        let harness = Self.harness(speedReply: "7E903410D3B\r7EA03410D\r7E803410D3C\r\r>")
        let info = try await harness.initialise()
        try await harness.session.startPolling(info.plan)
        await harness.run { await Self.speedPolls($0).count >= 3 }
        try await harness.stopPolling()

        #expect(await Self.speedPolls(harness.log).allSatisfy { $0.outcome == .ok })
        let speed = await harness.log.readings.filter { $0.measurement.pid == .vehicleSpeed }
        let byECU = Dictionary(grouping: speed, by: { $0.ecu ?? "" })
        #expect(Set(byECU.keys) == ["7E8", "7E9"], "nothing from 7EA")
        #expect(byECU["7E8"]?.allSatisfy { $0.measurement.value == 60 } == true)
        #expect(byECU["7E9"]?.allSatisfy { $0.measurement.value == 59 } == true)
    }

    @Test("The primary ECU's line is bad, 7E9's is good: the exchange fails (malformed), nothing is read, retry follows")
    func primaryBadFails() async throws {
        let harness = Self.harness(speedReply: "7E903410D3B\r7E803410D\r\r>")
        let info = try await harness.initialise()
        try await harness.session.startPolling(info.plan)
        await harness.run { await $0.states.contains(.retrying) }
        try await harness.stopPolling()

        let polls = await Self.speedPolls(harness.log)
        #expect(!polls.isEmpty)
        #expect(polls.allSatisfy { $0.outcome == .malformed && $0.rx == "7E903410D3B\r7E803410D\r\r" })
        #expect(await harness.log.readings.filter { $0.measurement.pid == .vehicleSpeed }.isEmpty)
        #expect(await harness.log.transitions.contains { $0.to == .retrying && $0.reason == "malformed" })
    }

    @Test("Init: a bad 7E9 line in the 0100 reply no longer fails init; the 7E8 line opens the ATSH7E0 gate")
    func supportedPIDsTolerant() async throws {
        let harness = SessionHarness(
            rules: [
                Rule(command: "0100", reply: "SEARCHING...\r7E9064100\r7E8064100BE1CA813\r\r>", delay: .milliseconds(30), requestHeader: "7DF"),
            ] + MockELMAdapter.Rule.benchCar,
            configuration: ELMSessionProbeTests.probing
        )
        let info = try await harness.initialise()
        #expect(info.supportedPIDs == "SEARCHING...\r7E9064100\r7E8064100BE1CA813\r\r")
        let search = try #require(await harness.log.exchanges.first { $0.tx == "0100" })
        #expect(search.outcome == .ok)
        #expect(await harness.log.exchanges.contains { $0.tx == "ATSH7E0" && $0.outcome == .ok })
        #expect(info.plan.primaryCommand.wireFormat == "010D0C1")
        #expect(info.plan.requestHeader == .engine)
    }
}

@Suite("ELM327ResponseParser.scanReplies: per-ECU tolerant parsing (M1-E1)")
struct ELMReplyScanTests {
    func scan(_ raw: String, headers: Bool = true) -> ECUReplyScan {
        ELM327ResponseParser.scanReplies(in: raw, headers: headers)
    }

    static let speed7E8 = ECUReply(header: "7E8", bytes: [0x41, 0x0D, 0x3C])

    @Test("A clean multi-ECU reply: the same answers as replies(in:headers:), no faults")
    func cleanMatchesStrict() throws {
        for raw in ["SEARCHING...\r7E8064100BE3FA813\r7E906410098180001\r\r", "7E8100B4100BE3FA813\r7E903410D3B\r7E8210D3C0C1AF8AAAA\r\r"] {
            let result = scan(raw)
            #expect(result.replies == (try ELM327ResponseParser.replies(in: raw, headers: true)))
            #expect(result.faults.isEmpty)
            #expect(result.error == nil)
        }
    }

    @Test("7E8 good, 7E9 cut short: 7E8 kept, the fault blames 7E9")
    func otherTruncated() {
        let result = scan("7E803410D3C\r7E903410D\r\r")
        #expect(result.replies == [Self.speed7E8])
        #expect(result.faults == [ECUReplyFault(header: "7E9", line: "7E903410D", error: .truncatedFrame(expected: 3, actual: 2))])
        #expect(result.error == .truncatedFrame(expected: 3, actual: 2))
    }

    @Test("7E8 good plus NO DATA: 7E8 kept; the status is the reply's error, attributed to no ECU")
    func statusLine() {
        let result = scan("7E803410D3C\rNO DATA\r\r")
        #expect(result.replies == [Self.speed7E8])
        #expect(result.faults == [ECUReplyFault(header: nil, line: "NO DATA", error: .noData)])
        #expect(result.error == .noData)
    }

    @Test("A status line is the reply's error even after a frame fault, as replies(in:headers:) reports it")
    func statusWinsForError() {
        let result = scan("7E903410D\rNO DATA\r\r")
        #expect(result.replies.isEmpty)
        #expect(result.error == .noData)
    }

    @Test("Non-hex garbage can't be attributed: it drops nothing")
    func unattributableGarbage() {
        let result = scan("7E803410D3C\r7E9#41@0D\r7E903410D3B\r\r")
        #expect(result.replies == [Self.speed7E8, ECUReply(header: "7E9", bytes: [0x41, 0x0D, 0x3B])])
        #expect(result.faults.map(\.header) == [nil])
        #expect(result.faults.first?.error == .malformedHex("7E9#41@0D"))
    }

    @Test("One bad line from an ECU drops every answer from it, earlier good ones included")
    func brokenHeaderDropsAll() {
        let result = scan("7E903410D3B\r7E803410D3C\r7E900410D3B\r\r")
        #expect(result.replies == [Self.speed7E8])
        #expect(result.faults == [ECUReplyFault(header: "7E9", line: "7E900410D3B", error: .malformedFrame("7E900410D3B"))])
    }

    @Test("An ISO-TP transfer left unfinished by one ECU drops only that ECU")
    func unfinishedTransfer() {
        let result = scan("7E9100B4100BE3FA813\r7E803410D3C\r\r")
        #expect(result.replies == [Self.speed7E8])
        #expect(result.faults == [
            ECUReplyFault(header: "7E9", line: "7E9100B4100BE3FA813", error: .truncatedFrame(expected: 11, actual: 6)),
        ])
    }

    @Test("A consecutive frame out of sequence drops that ECU's transfer")
    func outOfSequence() {
        let result = scan("7E9100B4100BE3FA813\r7E803410D3C\r7E9220D3C0C1AF8AAAA\r\r")
        #expect(result.replies == [Self.speed7E8])
        #expect(result.faults.map(\.header) == ["7E9"])
    }

    @Test("The primary ECU's own bad line: nothing from it")
    func primaryBad() {
        let result = scan("7E903410D3B\r7E803410D\r\r")
        #expect(result.replies == [ECUReply(header: "7E9", bytes: [0x41, 0x0D, 0x3B])])
        #expect(!result.replies.contains { $0.isFromPrimaryECU })
        #expect(result.faults.map(\.header) == ["7E8"])
    }

    @Test("Echo and SEARCHING... are dropped, not faults; an empty reply is an empty scan with emptyResponse")
    func echoAndEmpty() {
        let result = scan("010D\rSEARCHING...\r7E803410D3C\r\r")
        #expect(result.replies == [Self.speed7E8])
        #expect(result.faults.isEmpty)
        #expect(scan("\r\r").replies.isEmpty)
        #expect(scan("\r\r").faults.isEmpty)
        #expect(scan("\r\r").error == .emptyResponse)
    }

    @Test("Headers off: status lines are faults, the rest parses; an unparseable rest is one fault")
    func headersOff() {
        let good = scan("410D3C\rNO DATA\r\r", headers: false)
        #expect(good.replies == [ECUReply(header: nil, bytes: [0x41, 0x0D, 0x3C])])
        #expect(good.faults.map(\.error) == [.noData])
        let bad = scan("410D3\r\r", headers: false)
        #expect(bad.replies.isEmpty)
        #expect(bad.faults == [ECUReplyFault(header: nil, line: "410D3", error: .malformedHex("410D3"))])
    }
}
