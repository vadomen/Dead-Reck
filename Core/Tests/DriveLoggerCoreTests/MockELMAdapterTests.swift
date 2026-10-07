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
