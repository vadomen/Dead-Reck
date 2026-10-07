import Foundation
import Testing

@testable import DriveLoggerCore

/// BLE notifications arrive in arbitrary fragments; a reply is complete only
/// at the `>` prompt.
@Suite("ELMFramer")
struct ELMFramerTests {
    static func chunk(_ text: String, at uptime: Double = 0) -> ELMChunk {
        ELMChunk(bytes: Data(text.utf8), uptime: uptime)
    }

    @Test("One complete reply in one chunk keeps its line endings and drops the prompt")
    func singleChunk() {
        var framer = ELMFramer()
        let replies = framer.append(Self.chunk("7E803410D3C\r\r>", at: 5))
        #expect(replies == [ELMRawReply(text: "7E803410D3C\r\r", completedUptime: 5)])
    }

    @Test("Nothing is emitted until the prompt arrives")
    func waitsForPrompt() {
        var framer = ELMFramer()
        #expect(framer.append(Self.chunk("7E80341", at: 1)).isEmpty)
        #expect(framer.append(Self.chunk("0D3C\r\r", at: 2)).isEmpty)
        let replies = framer.append(Self.chunk(">", at: 3))
        #expect(replies == [ELMRawReply(text: "7E803410D3C\r\r", completedUptime: 3)])
    }

    @Test("Byte-by-byte delivery yields the same reply, stamped with the prompt's chunk")
    func byteByByte() {
        let raw = "SEARCHING...\r7E8064100BE3FA813\r7E906410098180001\r\r>"
        var framer = ELMFramer()
        var replies: [ELMRawReply] = []
        for (index, byte) in raw.utf8.enumerated() {
            replies += framer.append(ELMChunk(bytes: Data([byte]), uptime: Double(index)))
        }
        #expect(replies == [ELMRawReply(text: String(raw.dropLast()), completedUptime: Double(raw.utf8.count - 1))])
    }

    @Test("Random splits of a stream of replies reassemble identically", arguments: 0..<25)
    func randomSplits(seed: Int) {
        let stream = "ATZ\r\r\rELM327 v2.1\r\r>ATE0\rOK\r\r>OK\r\r>7E803410D3C\r\r>NO DATA\r\r>"
        let expected = ["ATZ\r\r\rELM327 v2.1\r\r", "ATE0\rOK\r\r", "OK\r\r", "7E803410D3C\r\r", "NO DATA\r\r"]
        var generator = SplitMix64(seed: UInt64(seed))
        let bytes = Array(stream.utf8)
        var framer = ELMFramer()
        var texts: [String] = []
        var index = 0
        while index < bytes.count {
            let size = Int(generator.next() % 23) + 1
            let end = min(bytes.count, index + size)
            texts += framer.append(ELMChunk(bytes: Data(bytes[index..<end]), uptime: 0)).map(\.text)
            index = end
        }
        #expect(texts == expected)
    }

    @Test("Several replies completed by one chunk come out in order")
    func multipleRepliesPerChunk() {
        var framer = ELMFramer()
        #expect(framer.append(Self.chunk("OK\r", at: 1)).isEmpty)
        let replies = framer.append(Self.chunk("\r>A6\r\r>12.4V\r", at: 2))
        #expect(replies.map(\.text) == ["OK\r\r", "A6\r\r"])
        #expect(replies.allSatisfy { $0.completedUptime == 2 })
        #expect(framer.append(Self.chunk("\r>", at: 3)) == [ELMRawReply(text: "12.4V\r\r", completedUptime: 3)])
    }

    @Test("NUL bytes some clones pad notifications with are stripped")
    func stripsNUL() {
        var framer = ELMFramer()
        let bytes: [UInt8] = [0x00] + Array("41 0D 3C".utf8) + [0x00, 0x0D, 0x00, 0x3E, 0x00]
        let replies = framer.append(ELMChunk(bytes: Data(bytes), uptime: 0))
        #expect(replies.map(\.text) == ["41 0D 3C\r"])
    }

    @Test("CRLF from an adapter left on ATL1 is kept verbatim")
    func keepsCRLF() {
        var framer = ELMFramer()
        #expect(framer.append(Self.chunk("OK\r\n\r\n>")).map(\.text) == ["OK\r\n\r\n"])
    }

    @Test("Garbage before the reply stays in the raw text for the parser to judge")
    func keepsLeadingGarbage() {
        var framer = ELMFramer()
        #expect(framer.append(Self.chunk("\r\u{7F}\r7E803410D3C\r\r>")).map(\.text) == ["\r\u{7F}\r7E803410D3C\r\r"])
    }

    @Test("A prompt with nothing before it is an empty reply, not skipped")
    func emptyReply() {
        var framer = ELMFramer()
        #expect(framer.append(Self.chunk(">", at: 4)) == [ELMRawReply(text: "", completedUptime: 4)])
    }

    @Test("reset() discards a partial reply")
    func resetDiscardsPartial() {
        var framer = ELMFramer()
        _ = framer.append(Self.chunk("7E80341"))
        #expect(framer.pendingText == "7E80341")
        framer.reset()
        #expect(framer.pendingText.isEmpty)
        #expect(framer.append(Self.chunk("OK\r\r>")).map(\.text) == ["OK\r\r"])
    }

    @Test("Invalid UTF-8 doesn't lose the reply")
    func invalidUTF8() {
        var framer = ELMFramer()
        let bytes: [UInt8] = [0xFF] + Array("OK\r>".utf8)
        let replies = framer.append(ELMChunk(bytes: Data(bytes), uptime: 0))
        #expect(replies.count == 1)
        #expect(replies[0].text.hasSuffix("OK\r"))
    }
}

/// Deterministic generator so the random-split test is reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
