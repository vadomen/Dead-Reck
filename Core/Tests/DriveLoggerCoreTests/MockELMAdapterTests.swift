import Foundation
import Testing

@testable import DriveLoggerCore

@Suite("MockELMAdapter", .timeLimit(.minutes(1)))
struct MockELMAdapterTests {
    static func command(_ wire: String) throws -> ValidatedELMCommand {
        try ELMCommandPolicy.validate(wire, scope: .session)
    }

    @Test("Replies after the rule's delay on the injected clock, in fragments, stamped on arrival")
    func delayedFragmentedReply() async throws {
        let clock = TestClock()
        let mock = MockELMAdapter(
            rules: [.init(command: "ATRV", reply: "12.4V\r\r>", delay: .milliseconds(50), fragmentSizes: [2])],
            uptime: clock,
            clock: clock
        )
        let log = ChunkLog.start(mock.incoming)
        let sentAt = try await mock.send(Self.command("ATRV"))
        #expect(sentAt == 1_000)

        await clock.advance(by: .milliseconds(49))
        #expect(await log.chunks.isEmpty)

        await clock.advance(by: .milliseconds(1))
        #expect(await driveUntil(clock) { await log.chunks.count == 4 })
        let chunks = await log.chunks
        #expect(chunks.map { String(decoding: $0.bytes, as: UTF8.self) } == ["12", ".4", "V\r", "\r>"])
        #expect(chunks.allSatisfy { abs($0.uptime - 1_000.05) < 1e-9 })
    }

    @Test("Fragment sizes cycle")
    func cyclingFragments() async throws {
        let clock = TestClock()
        let mock = MockELMAdapter(
            rules: [.init(command: "010D", reply: "7E803410D3C\r\r>", delay: .zero, fragmentSizes: [1, 3])],
            uptime: clock,
            clock: clock
        )
        let log = ChunkLog.start(mock.incoming)
        _ = try await mock.send(Self.command("010D"))
        #expect(await driveUntil(clock) { await log.text == "7E803410D3C\r\r>" })
        #expect(await log.chunks.map(\.bytes.count) == [1, 3, 1, 3, 1, 3, 1, 1])
    }

    @Test("Unmatched commands get ?")
    func unmatched() async throws {
        let clock = TestClock()
        let mock = MockELMAdapter(rules: [], uptime: clock, clock: clock)
        let log = ChunkLog.start(mock.incoming)
        _ = try await mock.send(Self.command("ATDP"))
        #expect(await driveUntil(clock) { await log.text == "?\r\r>" })
    }

    @Test("A nil reply never answers")
    func silent() async throws {
        let clock = TestClock()
        let mock = MockELMAdapter(rules: [.init(command: "010D", reply: nil)], uptime: clock, clock: clock)
        let log = ChunkLog.start(mock.incoming)
        _ = try await mock.send(Self.command("010D"))
        await clock.advance(by: .seconds(30))
        #expect(await log.chunks.isEmpty)
    }

    @Test("Matching ignores case; first match wins; limited rules are used up")
    func matching() async throws {
        let clock = TestClock()
        let mock = MockELMAdapter(
            rules: [
                .init(command: "atrv", reply: "11.0V\r\r>", delay: .zero, times: 1),
                .init(command: "ATRV", reply: "12.4V\r\r>", delay: .zero),
                .init(command: "ATRV", reply: "13.0V\r\r>", delay: .zero),
            ],
            uptime: clock,
            clock: clock
        )
        let log = ChunkLog.start(mock.incoming)
        for _ in 0..<3 { _ = try await mock.send(Self.command("ATRV")) }
        #expect(await driveUntil(clock) { await log.text == "11.0V\r\r>12.4V\r\r>12.4V\r\r>" })
    }

    @Test("Records every command received, in order")
    func records() async throws {
        let clock = TestClock()
        let mock = MockELMAdapter(rules: MockELMAdapter.Rule.touaregInstant, uptime: clock, clock: clock)
        for wire in ["atz", "ATE0", "010d0c1"] { _ = try await mock.send(Self.command(wire)) }
        #expect(await mock.sentCommands == ["ATZ", "ATE0", "010D0C1"])
    }

    @Test("Replies are delivered in order even when a later one has a shorter delay")
    func ordered() async throws {
        let clock = TestClock()
        let mock = MockELMAdapter(
            rules: [
                .init(command: "ATI", reply: "slow\r\r>", delay: .milliseconds(100)),
                .init(command: "ATRV", reply: "fast\r\r>", delay: .milliseconds(10)),
            ],
            uptime: clock,
            clock: clock
        )
        let log = ChunkLog.start(mock.incoming)
        _ = try await mock.send(Self.command("ATI"))
        _ = try await mock.send(Self.command("ATRV"))
        #expect(await mock.overlappingSends == 1)
        #expect(await driveUntil(clock) { await log.text == "slow\r\r>fast\r\r>" })
    }

    @Test("disconnect() finishes incoming and later sends fail")
    func disconnect() async throws {
        let clock = TestClock()
        let mock = MockELMAdapter(
            rules: [.init(command: "ATRV", reply: "12.4V\r\r>", delay: .seconds(1))],
            uptime: clock,
            clock: clock
        )
        let log = ChunkLog.start(mock.incoming)
        _ = try await mock.send(Self.command("ATRV"))
        await mock.disconnect()
        #expect(await driveUntil(clock) { await log.finished })
        await clock.advance(by: .seconds(2))
        #expect(await log.chunks.isEmpty)
        await #expect(throws: ELMTransportError.notConnected) {
            _ = try await mock.send(Self.command("ATRV"))
        }
    }

    @Test("The Touareg script answers the handshake, probes and polls as documented")
    func touareg() async throws {
        let clock = TestClock()
        let mock = MockELMAdapter(rules: MockELMAdapter.Rule.touaregInstant, uptime: clock, clock: clock)
        let incoming = mock.incoming
        var framer = ELMFramer()
        var iterator = incoming.makeAsyncIterator()

        func ask(_ wire: String) async throws -> String {
            _ = try await mock.send(Self.command(wire))
            while true {
                guard let chunk = await iterator.next() else { throw ELMTransportError.disconnected(nil) }
                if let reply = framer.append(chunk).first { return reply.text }
            }
        }

        #expect(try ELM327ResponseParser.textReply(to: "ATZ", raw: await ask("ATZ")) == .banner("ELM327 v2.1"))
        for wire in ["ATE0", "ATL0", "ATS0", "ATH1", "ATSP0", "ATAT1", "ATAT2"] {
            #expect(try ELM327ResponseParser.textReply(to: wire, raw: await ask(wire)) == .ok)
        }
        let supported = try ELM327ResponseParser.replies(in: await ask("0100"), headers: true)
        #expect(supported.map(\.header) == ["7E8", "7E9"])
        #expect(try ELM327ResponseParser.textReply(to: "ATDPN", raw: await ask("ATDPN")) == .protocolNumber("A6"))
        #expect(try ELM327ResponseParser.textReply(to: "ATRV", raw: await ask("ATRV")) == .voltage(12.4))

        for wire in ["010D0C", "010D0C1"] {
            let replies = try ELM327ResponseParser.replies(in: await ask(wire), headers: true)
            #expect(replies.map(\.header) == ["7E8"])
            let values = try OBDDecoder.decode(requested: [.vehicleSpeed, .engineSpeed], bytes: replies[0].bytes)
            #expect(values.map(\.pid) == [.vehicleSpeed, .engineSpeed])
        }
        for wire in ["010D", "010D1"] {
            let replies = try ELM327ResponseParser.replies(in: await ask(wire), headers: true)
            #expect(try OBDDecoder.decode(requested: [.vehicleSpeed], bytes: replies[0].bytes).count == 1)
        }
        let rawNoData = try await ask("010F")
        #expect(throws: ELM327Error.noData) { try ELM327ResponseParser.replies(in: rawNoData, headers: true) }
    }

    @Test("The Touareg script's latencies make the suffix and multi-PID faster")
    func touaregLatencies() {
        let delays = Dictionary(MockELMAdapter.Rule.touareg.map { ($0.command, $0.delay) }, uniquingKeysWith: { first, _ in first })
        #expect(delays["010D1"]! < delays["010D"]!)
        #expect(delays["010D0C1"]! < delays["010D0C"]!)
        #expect(delays["0100"]! > delays["010D"]!)
    }
}

/// Asks the mock one command at a time and returns each framed reply.
private struct MockAsker {
    let mock: MockELMAdapter
    let clock: TestClock
    let log: ChunkLog

    init(rules: [MockELMAdapter.Rule]) {
        clock = TestClock()
        mock = MockELMAdapter(rules: rules, uptime: clock, clock: clock)
        log = ChunkLog.start(mock.incoming)
    }

    /// The reply text without the prompt.
    func ask(_ wire: String) async throws -> String {
        let before = await log.text.count
        _ = try await mock.send(ELMCommandPolicy.validate(wire, scope: .session))
        let log = log
        let done = await driveUntil(clock) { await log.text.dropFirst(before).contains(">") }
        try #require(done, "no prompt for \(wire)")
        return String(await log.text.dropFirst(before).dropLast())
    }
}

@Suite("MockELMAdapter addressing", .timeLimit(.minutes(1)))
struct MockELMAdapterAddressingTests {
    static let rules: [MockELMAdapter.Rule] = [
        .init(command: "ATZ", reply: "ELM327 v2.3\r\r>", delay: .zero),
        .init(command: "ATSH7E0", reply: "OK\r\r>", delay: .zero),
        .init(command: "ATSH7DF", reply: "OK\r\r>", delay: .zero),
        .init(command: "010D1", reply: "7E903410D00\r\r>", delay: .zero, requestHeader: "7DF"),
        .init(command: "010D1", reply: "7E803410D00\r\r>", delay: .zero, requestHeader: "7E0"),
    ]

    @Test("Starts functional; ATSH answered OK switches the header; ATZ resets it")
    func headerState() async throws {
        let asker = MockAsker(rules: Self.rules)
        #expect(await asker.mock.requestHeader == "7DF")
        #expect(try await asker.ask("010D1") == "7E903410D00\r\r")
        #expect(try await asker.ask("ATSH7E0") == "OK\r\r")
        #expect(await asker.mock.requestHeader == "7E0")
        #expect(try await asker.ask("010D1") == "7E803410D00\r\r")
        #expect(try await asker.ask("ATSH7DF") == "OK\r\r")
        #expect(await asker.mock.requestHeader == "7DF")
        #expect(try await asker.ask("ATSH7E0") == "OK\r\r")
        #expect(try await asker.ask("ATZ") == "ELM327 v2.3\r\r")
        #expect(await asker.mock.requestHeader == "7DF")
        #expect(try await asker.ask("010D1") == "7E903410D00\r\r")
    }

    @Test("ATSH answered with anything but OK leaves the header alone")
    func refusedHeader() async throws {
        let asker = MockAsker(rules: [.init(command: "ATSH7E0", reply: "?\r\r>", delay: .zero)] + Self.rules)
        #expect(try await asker.ask("ATSH7E0") == "?\r\r")
        #expect(await asker.mock.requestHeader == "7DF")
        #expect(try await asker.ask("010D1") == "7E903410D00\r\r")
    }

    @Test("A rule scoped to another header doesn't match: the command gets ?")
    func scopedRuleDoesNotMatch() async throws {
        let asker = MockAsker(rules: [
            .init(command: "010D0C1", reply: "7E806410D000C0A5C\r\r>", delay: .zero, requestHeader: "7E0"),
        ])
        #expect(try await asker.ask("010D0C1") == "?\r\r")
    }
}

@Suite("MockELMAdapter bench-car script", .timeLimit(.minutes(1)))
struct MockELMAdapterBenchCarTests {
    typealias T = BenchTranscript

    @Test("Block 1, functional: every reply exactly as transcribed")
    func functionalBlock() async throws {
        let asker = MockAsker(rules: MockELMAdapter.Rule.benchCarInstant)
        #expect(try await asker.ask("ATI") == T.ati)
        #expect(try await asker.ask("ATRV") == T.atrvEngineOff)
        #expect(try await asker.ask("ATDPN") == "A6\r\r", "deliberately A6, not the transcribed 6: see benchCar")
        #expect(try await asker.ask("ATH1") == T.ath1)
        #expect(try await asker.ask("0100") == T.supportedPIDs0100)
        #expect(try await asker.ask("010D") == T.speed010D)
        #expect(try await asker.ask("010D1") == T.speedFunctionalSuffix010D1)
        #expect(try await asker.ask("010D0C") == T.speedRPM010D0C)
    }

    @Test("Block 2, after ATSH7E0: every reply exactly as transcribed")
    func physicalBlock() async throws {
        let asker = MockAsker(rules: MockELMAdapter.Rule.benchCarInstant)
        #expect(try await asker.ask("ATSH7E0") == T.atsh7E0)
        #expect(await asker.mock.requestHeader == "7E0")
        #expect(try await asker.ask("010D1") == T.speedPhysicalSuffix010D1)
        #expect(try await asker.ask("010D0C1") == T.speedRPMPhysicalSuffix010D0C1)
        #expect(try await asker.ask("ATRV") == T.atrvIdling)
    }

    @Test("ATZ answers the v2.3 banner and returns to functional addressing")
    func resetBanner() async throws {
        let asker = MockAsker(rules: MockELMAdapter.Rule.benchCarInstant)
        _ = try await asker.ask("ATSH7E0")
        #expect(try ELM327ResponseParser.textReply(to: "ATZ", raw: await asker.ask("ATZ")) == .banner("ELM327 v2.3"))
        #expect(await asker.mock.requestHeader == "7DF")
        #expect(try await asker.ask("010D1") == T.speedFunctionalSuffix010D1)
    }

    @Test("The suffix with a functional header is not scripted beyond the transcript: 010D0C1 gets ?")
    func untranscribed() async throws {
        let asker = MockAsker(rules: MockELMAdapter.Rule.benchCarInstant)
        #expect(try await asker.ask("010D0C1") == "?\r\r")
    }

    // The script carries the 22F40D transcript for completeness, but the
    // read-only guard means it can never be asked.
    @Test("22F40D is scripted as NO DATA but can't be sent: the policy rejects mode 22")
    func modeTwentyTwoUnreachable() throws {
        let rule = try #require(MockELMAdapter.Rule.benchCar.first { $0.command == "22F40D" })
        #expect(rule.reply == T.udsSpeed22F40D + ">")
        #expect(throws: ELMSessionError.forbiddenCommand("22F40D")) { try ELMCommandPolicy.validate("22F40D", scope: .session) }
    }

    @Test("Every transcribed reply is in the script, for the right header")
    func coversTranscript() {
        let rules = MockELMAdapter.Rule.benchCar
        for (command, reply) in BenchTranscript.all where command != "ATDPN" {
            #expect(rules.contains { $0.command == command && $0.reply == reply + ">" }, "\(command) → \(reply.debugDescription)")
        }
    }
}
