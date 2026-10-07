import Foundation
import Testing

@testable import DriveLoggerCore

/// `ELM327ResponseParser.replies(in:headers:)`: per-ECU answers from raw
/// replies as the framer delivers them (prompt already stripped).
@Suite("ELM327ResponseParser replies, headers on")
struct ELMHeaderOnReplyTests {
    func parse(_ raw: String) throws -> [ECUReply] {
        try ELM327ResponseParser.replies(in: raw, headers: true)
    }

    @Test("11-bit header + PCI, spaces off (the logger's mode)")
    func elevenBitCompact() throws {
        #expect(try parse("7E803410D3C\r\r") == [ECUReply(header: "7E8", bytes: [0x41, 0x0D, 0x3C])])
    }

    @Test("11-bit header + PCI, spaces on")
    func elevenBitSpaced() throws {
        #expect(try parse("7E8 03 41 0D 3C \r\r") == [ECUReply(header: "7E8", bytes: [0x41, 0x0D, 0x3C])])
    }

    @Test("Bytes beyond the PCI length are CAN padding and are dropped")
    func dropsPadding() throws {
        #expect(try parse("7E8 03 41 0D 3C AA AA AA AA\r") == [ECUReply(header: "7E8", bytes: [0x41, 0x0D, 0x3C])])
    }

    @Test("29-bit header (18DAF110)")
    func twentyNineBit() throws {
        #expect(try parse("18DAF11003410D3C\r\r") == [ECUReply(header: "18DAF110", bytes: [0x41, 0x0D, 0x3C])])
        #expect(try parse("18 DA F1 10 03 41 0D 3C\r") == [ECUReply(header: "18DAF110", bytes: [0x41, 0x0D, 0x3C])])
    }

    @Test("Two ECUs answering 0100, in arrival order, after SEARCHING...")
    func multiECU() throws {
        let replies = try parse("SEARCHING...\r7E8064100BE3FA813\r7E906410098180001\r\r")
        #expect(replies == [
            ECUReply(header: "7E8", bytes: [0x41, 0x00, 0xBE, 0x3F, 0xA8, 0x13]),
            ECUReply(header: "7E9", bytes: [0x41, 0x00, 0x98, 0x18, 0x00, 0x01]),
        ])
    }

    @Test("Multi-PID reply in one frame")
    func multiPID() throws {
        #expect(try parse("7E806410D3C0C1AF8\r\r") == [ECUReply(header: "7E8", bytes: [0x41, 0x0D, 0x3C, 0x0C, 0x1A, 0xF8])])
    }

    @Test("Echo of the command is tolerated", arguments: ["010D", "010D0C1", "atrv", "0100"])
    func echoTolerated(echo: String) throws {
        #expect(try parse("\(echo)\r7E803410D3C\r\r") == [ECUReply(header: "7E8", bytes: [0x41, 0x0D, 0x3C])])
    }

    @Test("ISO-TP first + consecutive frame are reassembled per ECU")
    func isoTPSingleECU() throws {
        // FF: length 0x00B, 6 data bytes; CF #1: 5 more bytes then padding.
        let raw = "7E8100B4100BE3FA813\r7E8210D3C0C1AF8AAAA\r\r"
        #expect(try parse(raw) == [
            ECUReply(header: "7E8", bytes: [0x41, 0x00, 0xBE, 0x3F, 0xA8, 0x13, 0x0D, 0x3C, 0x0C, 0x1A, 0xF8]),
        ])
    }

    @Test("ISO-TP frames from two ECUs may interleave")
    func isoTPInterleaved() throws {
        let raw = "7E8100B4100BE3FA813\r7E903410D3B\r7E8210D3C0C1AF8AAAA\r\r"
        #expect(try parse(raw) == [
            ECUReply(header: "7E8", bytes: [0x41, 0x00, 0xBE, 0x3F, 0xA8, 0x13, 0x0D, 0x3C, 0x0C, 0x1A, 0xF8]),
            ECUReply(header: "7E9", bytes: [0x41, 0x0D, 0x3B]),
        ])
    }

    @Test("A missing consecutive frame is a truncated reply, not a short value")
    func isoTPMissingFrame() {
        #expect(throws: ELM327Error.truncatedFrame(expected: 11, actual: 6)) {
            try parse("7E8100B4100BE3FA813\r\r")
        }
    }

    @Test("A consecutive frame out of sequence is rejected")
    func isoTPWrongSequence() {
        #expect(throws: ELM327Error.malformedFrame("7E8220D3C0C1AF8AAAA")) {
            try parse("7E8100B4100BE3FA813\r7E8220D3C0C1AF8AAAA\r\r")
        }
    }

    @Test("A consecutive frame without a first frame is rejected")
    func isoTPOrphanConsecutive() {
        #expect(throws: ELM327Error.malformedFrame("7E8210D3C0C1AF8AAAA")) {
            try parse("7E8210D3C0C1AF8AAAA\r\r")
        }
    }

    @Test("A single frame shorter than its PCI length is truncated")
    func singleFrameTruncated() {
        #expect(throws: ELM327Error.truncatedFrame(expected: 6, actual: 3)) {
            try parse("7E806410D3C\r\r")
        }
    }

    @Test("A header-off line while headers are expected is malformed, not misattributed")
    func headerOffLineRejected() {
        #expect(throws: ELM327Error.self) { try parse("410D3C\r\r") }
    }

    @Test("Non-hex garbage is malformed")
    func garbageRejected() {
        #expect(throws: ELM327Error.malformedHex("7E8ZZ410D3C")) { try parse("7E8ZZ410D3C\r\r") }
    }

    @Test("An invalid PCI is malformed", arguments: ["7E800410D3C", "7E8F3410D3C"])
    func invalidPCI(line: String) {
        #expect(throws: ELM327Error.malformedFrame(line)) { try parse(line + "\r\r") }
    }
}

@Suite("ELM327ResponseParser replies, headers off")
struct ELMHeaderOffReplyTests {
    func parse(_ raw: String) throws -> [ECUReply] {
        try ELM327ResponseParser.replies(in: raw, headers: false)
    }

    @Test("Bare payload, spaces off and on")
    func barePayload() throws {
        #expect(try parse("410D3C\r\r") == [ECUReply(header: nil, bytes: [0x41, 0x0D, 0x3C])])
        #expect(try parse("41 0D 3C \r\r") == [ECUReply(header: nil, bytes: [0x41, 0x0D, 0x3C])])
    }

    @Test("Each line from several ECUs is its own reply, unattributed")
    func multiECU() throws {
        #expect(try parse("410D3C\r410D3B\r\r") == [
            ECUReply(header: nil, bytes: [0x41, 0x0D, 0x3C]),
            ECUReply(header: nil, bytes: [0x41, 0x0D, 0x3B]),
        ])
    }

    @Test("ISO-TP block: byte count line plus indexed lines, padding trimmed")
    func isoTP() throws {
        let raw = "00B\r0: 41 00 BE 3F A8 13\r1: 0D 3C 0C 1A F8 AA AA\r\r"
        #expect(try parse(raw) == [
            ECUReply(header: nil, bytes: [0x41, 0x00, 0xBE, 0x3F, 0xA8, 0x13, 0x0D, 0x3C, 0x0C, 0x1A, 0xF8]),
        ])
    }

    @Test("ISO-TP lines out of order are sorted by index")
    func isoTPOutOfOrder() throws {
        let raw = "008\r1: A8 13 00 00\r0: 41 00 BE 1F\r\r"
        #expect(try parse(raw) == [ECUReply(header: nil, bytes: [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13, 0x00, 0x00])])
    }

    @Test("Two ISO-TP blocks from two ECUs stay separate")
    func twoBlocks() throws {
        let raw = "008\r0: 41 00 BE 1F\r1: A8 13 00 00\r008\r0: 41 00 98 18\r1: 00 01 00 00\r\r"
        #expect(try parse(raw) == [
            ECUReply(header: nil, bytes: [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13, 0x00, 0x00]),
            ECUReply(header: nil, bytes: [0x41, 0x00, 0x98, 0x18, 0x00, 0x01, 0x00, 0x00]),
        ])
    }

    @Test("A short ISO-TP block is truncated")
    func isoTPTruncated() {
        #expect(throws: ELM327Error.truncatedFrame(expected: 20, actual: 4)) {
            try parse("014\r0: 41 00 BE 1F\r\r")
        }
    }

    @Test("Echo is tolerated with headers off too")
    func echo() throws {
        #expect(try parse("010D\r410D3C\r\r") == [ECUReply(header: nil, bytes: [0x41, 0x0D, 0x3C])])
    }

    @Test("An odd number of digits is malformed")
    func oddDigits() {
        #expect(throws: ELM327Error.malformedHex("410D3")) { try parse("410D3\r\r") }
    }
}

@Suite("ELM327ResponseParser replies, status lines")
struct ELMReplyStatusTests {
    @Test(
        "Status lines throw in both header modes",
        arguments: [
            ("NO DATA\r\r", ELM327Error.noData),
            ("SEARCHING...\rNO DATA\r\r", .noData),
            ("STOPPED\r\r", .stopped),
            ("?\r\r", .notRecognised),
            ("CAN ERROR\r\r", .canError),
            ("BUS INIT: ...ERROR\r\r", .busInitFailed),
            ("SEARCHING...\rUNABLE TO CONNECT\r\r", .unableToConnect),
            ("7E803410D3C\rBUFFER FULL\r\r", .bufferFull),
            ("ERR94\r\r", .adapter("ERR94")),
            ("BUS ERROR\r\r", .busError),
            ("DATA ERROR\r\r", .dataError),
        ]
    )
    func statusThrows(raw: String, expected: ELM327Error) {
        #expect(throws: expected) { try ELM327ResponseParser.replies(in: raw, headers: true) }
        #expect(throws: expected) { try ELM327ResponseParser.replies(in: raw, headers: false) }
    }

    @Test("An empty reply or one that is only SEARCHING... is an error")
    func empty() {
        #expect(throws: ELM327Error.emptyResponse) { try ELM327ResponseParser.replies(in: "\r\r", headers: true) }
        #expect(throws: ELM327Error.emptyResponse) { try ELM327ResponseParser.replies(in: "SEARCHING...\r", headers: false) }
        #expect(throws: ELM327Error.emptyResponse) { try ELM327ResponseParser.replies(in: "010D\r\r", headers: true) }
    }

    @Test("CRLF line endings split on the scalar view")
    func crlf() throws {
        #expect(try ELM327ResponseParser.replies(in: "7E803410D3C\r\n7E903410D3B\r\n\r\n", headers: true).count == 2)
    }
}

@Suite("ELM327ResponseParser text replies")
struct ELMTextReplyTests {
    @Test(
        "AT replies are classified",
        arguments: [
            ("ATZ", "ATZ\r\r\rELM327 v2.1\r\r", ELMTextReply.banner("ELM327 v2.1")),
            ("ATZ", "\r\rELM327 v2.1\r\r", .banner("ELM327 v2.1")),
            ("ATZ", "\r\rOBDII v1.5\r\r", .banner("OBDII v1.5")),
            ("ATI", "ELM327 v2.1\r\r", .banner("ELM327 v2.1")),
            ("ATE0", "ATE0\rOK\r\r", .ok),
            ("ATH1", "OK\r\r", .ok),
            ("ATL0", "OK\r\n\r\n", .ok),
            ("atsp0", "OK\r\r", .ok),
            ("ATDPN", "A6\r\r", .protocolNumber("A6")),
            ("ATDPN", "6\r\r", .protocolNumber("6")),
            ("ATRV", "12.4V\r\r", .voltage(12.4)),
            ("ATRV", "11.9v\r\r", .voltage(11.9)),
            ("atrv", "ATRV\r14.2 V\r\r", .voltage(14.2)),
            ("ATRV", "garbage\r\r", .other("garbage")),
            ("ATDP", "AUTO, ISO 15765-4 (CAN 11/500)\r\r", .other("AUTO, ISO 15765-4 (CAN 11/500)")),
            ("AT@1", "OBDII to RS232 Interpreter\r\r", .other("OBDII to RS232 Interpreter")),
        ]
    )
    func classifies(command: String, raw: String, expected: ELMTextReply) throws {
        #expect(try ELM327ResponseParser.textReply(to: command, raw: raw) == expected)
    }

    @Test("A status line throws")
    func statusThrows() {
        #expect(throws: ELM327Error.notRecognised) { try ELM327ResponseParser.textReply(to: "ATAT2", raw: "?\r\r") }
        #expect(throws: ELM327Error.adapter("ERR71")) { try ELM327ResponseParser.textReply(to: "ATRV", raw: "ERR71\r\r") }
    }

    @Test("Nothing but the echo is an empty reply")
    func empty() {
        #expect(throws: ELM327Error.emptyResponse) { try ELM327ResponseParser.textReply(to: "ATZ", raw: "\r\r") }
        #expect(throws: ELM327Error.emptyResponse) { try ELM327ResponseParser.textReply(to: "ATE0", raw: "ATE0\r\r") }
    }
}
