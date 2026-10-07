import Foundation
import Testing

@testable import DriveLoggerCore

@Suite("ELM327Command")
struct ELM327CommandTests {
    @Test("AT commands render to their documented spellings")
    func rendersATCommands() {
        #expect(ELM327Command.reset.wireFormat == "ATZ")
        #expect(ELM327Command.echo(false).wireFormat == "ATE0")
        #expect(ELM327Command.echo(true).wireFormat == "ATE1")
        #expect(ELM327Command.lineFeeds(false).wireFormat == "ATL0")
        #expect(ELM327Command.spaces(false).wireFormat == "ATS0")
        #expect(ELM327Command.headers(false).wireFormat == "ATH0")
        #expect(ELM327Command.autoProtocol.wireFormat == "ATSP0")
        #expect(ELM327Command.describeProtocolNumber.wireFormat == "ATDPN")
        #expect(ELM327Command.readVoltage.wireFormat == "ATRV")
    }

    @Test("PID requests render as two uppercase hex bytes")
    func rendersRequests() {
        #expect(ELM327Command.currentData(.engineSpeed).wireFormat == "010C")
        #expect(ELM327Command.currentData(.vehicleSpeed).wireFormat == "010D")
        #expect(ELM327Command.currentData(.calculatedEngineLoad).wireFormat == "0104")
        #expect(ELM327Command.currentData(.fuelTankLevel).wireFormat == "012F")
    }

    @Test("Commands go out carriage-return terminated")
    func terminatesWithCarriageReturn() {
        #expect(ELM327Command.currentData(.vehicleSpeed).wireData == Data("010D\r".utf8))
    }

    @Test("Handshake follows the spec sequence with headers on")
    func handshakeFollowsSpec() {
        let spellings = ELM327Command.handshake.map(\.wireFormat)
        #expect(spellings == ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP0", "0100", "ATDPN", "ATRV", "ATSH7E0"])
    }

    @Test("New commands render to their documented spellings")
    func rendersNewCommands() {
        #expect(ELM327Command.headers(true).wireFormat == "ATH1")
        #expect(ELM327Command.adaptiveTiming(2).wireFormat == "ATAT2")
        #expect(ELM327Command.supportedPIDs.wireFormat == "0100")
        #expect(ELM327Command.currentDataMany([.vehicleSpeed, .engineSpeed], responseCount: nil).wireFormat == "010D0C")
        #expect(ELM327Command.currentDataMany([.vehicleSpeed], responseCount: 1).wireFormat == "010D1")
    }

    @Test("Every command the type can build passes the policy, including the handshake")
    func expressibleCommandsAreAllowed() throws {
        var commands = ELM327Command.handshake
        commands += [.echo(true), .lineFeeds(true), .spaces(true), .headers(false)]
        commands += (0...2).map(ELM327Command.adaptiveTiming)
        commands += OBDPID.allCases.map(ELM327Command.currentData)
        commands.append(.currentDataMany([.vehicleSpeed, .engineSpeed], responseCount: 1))
        commands += CANRequestHeader.all.map(ELM327Command.setHeader)
        for command in commands {
            let validated = try command.validated()
            #expect(validated.wireData == command.wireData)
        }
    }

    // Regression: responseCount 10 rendered "010D10", which passed the policy
    // as a request for PIDs 0x0D and 0x10.
    @Test("A response count outside 1-9 is rejected, not rendered as another PID", arguments: [0, 10, 12, -1, 99])
    func responseCountMustBeOneDigit(_ count: Int) {
        #expect(throws: ELMSessionError.self) {
            try ELM327Command.currentDataMany([.vehicleSpeed], responseCount: count).validated()
        }
        #expect(throws: ELMSessionError.self) {
            try ELM327Command.currentDataMany([.vehicleSpeed, .engineSpeed], responseCount: count).validated()
        }
    }

    @Test("Response counts 1-9 are accepted", arguments: 1...9)
    func responseCountsOneToNine(_ count: Int) throws {
        let validated = try ELM327Command.currentDataMany([.vehicleSpeed], responseCount: count).validated()
        #expect(validated.wire == "010D\(count)")
    }

    @Test("Out-of-range parameters are caught by the policy, not sent")
    func outOfRangeParametersRejected() {
        #expect(throws: ELMSessionError.self) { try ELM327Command.adaptiveTiming(3).validated() }
        let sevenPIDs = Array(repeating: OBDPID.vehicleSpeed, count: 7)
        #expect(throws: ELMSessionError.self) {
            try ELM327Command.currentDataMany(sevenPIDs, responseCount: nil).validated()
        }
    }
}

@Suite("ELM327ResponseParser line splitting")
struct ELM327LineTests {
    @Test("Strips the prompt and blank lines")
    func stripsPrompt() {
        #expect(ELM327ResponseParser.lines(in: "410C1AF8\r\r>") == ["410C1AF8"])
    }

    @Test("Handles CRLF from adapters left with ATL1")
    func handlesCRLF() {
        #expect(ELM327ResponseParser.lines(in: "41 0D 32\r\n>") == ["41 0D 32"])
    }

    @Test("Drops SEARCHING progress chatter")
    func dropsSearching() {
        let raw = "SEARCHING...\r410D32\r>"
        #expect(ELM327ResponseParser.lines(in: raw) == ["410D32"])
    }

    @Test("Drops informational BUS INIT but keeps the failing one")
    func filtersBusInit() {
        #expect(ELM327ResponseParser.lines(in: "BUS INIT: ...OK\r410D32\r>") == ["410D32"])
        #expect(ELM327ResponseParser.lines(in: "BUS INIT: ERROR\r>") == ["BUS INIT: ERROR"])
    }
}

@Suite("ELM327ResponseParser status lines")
struct ELM327StatusTests {
    @Test(
        "Adapter status strings map to errors",
        arguments: [
            ("NO DATA", ELM327Error.noData),
            ("UNABLE TO CONNECT", .unableToConnect),
            ("STOPPED", .stopped),
            ("BUS ERROR", .busError),
            ("CAN ERROR", .canError),
            ("BUFFER FULL", .bufferFull),
            ("DATA ERROR", .dataError),
            ("?", .notRecognised),
        ]
    )
    func classifiesStatus(line: String, expected: ELM327Error) {
        #expect(ELM327ResponseParser.error(for: line) == expected)
    }

    @Test("Spacing differences between firmwares don't change classification")
    func ignoresSpacing() {
        #expect(ELM327ResponseParser.error(for: "BUFFERFULL") == .bufferFull)
        #expect(ELM327ResponseParser.error(for: "no data") == .noData)
    }

    @Test("Firmware ERR codes are preserved verbatim")
    func preservesErrCodes() {
        #expect(ELM327ResponseParser.error(for: "ERR94") == .adapter("ERR94"))
    }

    @Test("Payload lines are not mistaken for errors")
    func passesPayloadThrough() {
        #expect(ELM327ResponseParser.error(for: "410D32") == nil)
        #expect(ELM327ResponseParser.error(for: "OK") == nil)
    }
}

@Suite("ELM327ResponseParser payload extraction")
struct ELM327PayloadTests {
    @Test("Extracts data bytes with spaces off")
    func parsesCompactReply() throws {
        let payload = try ELM327ResponseParser.dataBytes(in: "410C1AF8\r>", mode: 0x01, pid: 0x0C)
        #expect(payload == [0x1A, 0xF8])
    }

    @Test("Extracts data bytes with spaces on")
    func parsesSpacedReply() throws {
        let payload = try ELM327ResponseParser.dataBytes(in: "41 0C 1A F8\r>", mode: 0x01, pid: 0x0C)
        #expect(payload == [0x1A, 0xF8])
    }

    @Test("Reassembles an out-of-order multi-frame reply and trims padding")
    func reassemblesMultiFrame() throws {
        // Declared length 0x08 covers 41 00 BE 1F A8 13 plus two data bytes;
        // the remaining 00 00 in the second frame is ISO-TP padding.
        let raw = """
            008\r1: A8 13 00 00\r0: 41 00 BE 1F\r>
            """
        let payload = try ELM327ResponseParser.dataBytes(in: raw, mode: 0x01, pid: 0x00)
        #expect(payload == [0xBE, 0x1F, 0xA8, 0x13, 0x00, 0x00])
    }

    @Test("Rejects a multi-frame reply shorter than its declared length")
    func rejectsTruncatedMultiFrame() {
        let raw = "014\r0: 41 00 BE 1F\r>"
        #expect(throws: ELM327Error.truncatedFrame(expected: 20, actual: 4)) {
            try ELM327ResponseParser.dataBytes(in: raw, mode: 0x01, pid: 0x00)
        }
    }

    @Test("A status line in the reply surfaces as that error")
    func propagatesStatus() {
        #expect(throws: ELM327Error.noData) {
            try ELM327ResponseParser.dataBytes(in: "NO DATA\r>", mode: 0x01, pid: 0x0C)
        }
    }

    @Test("An empty reply is an error, not an empty payload")
    func rejectsEmpty() {
        #expect(throws: ELM327Error.emptyResponse) {
            try ELM327ResponseParser.dataBytes(in: "\r\r>", mode: 0x01, pid: 0x0C)
        }
    }

    @Test("A reply for the wrong PID is rejected rather than mislabelled")
    func rejectsMismatchedPID() {
        // Guards against a late reply being paired with the next request in
        // flight, which would silently record engine speed as vehicle speed.
        #expect(throws: ELM327Error.unexpectedPID(expected: 0x0D, actual: 0x0C)) {
            try ELM327ResponseParser.dataBytes(in: "410C1AF8\r>", mode: 0x01, pid: 0x0D)
        }
    }

    @Test("A reply for the wrong service is rejected")
    func rejectsMismatchedMode() {
        #expect(throws: ELM327Error.unexpectedMode(expected: 0x41, actual: 0x49)) {
            try ELM327ResponseParser.dataBytes(in: "490201\r>", mode: 0x01, pid: 0x02)
        }
    }

    @Test("Non-hex payload is rejected")
    func rejectsNonHex() {
        #expect(throws: ELM327Error.malformedHex("41ZZ32")) {
            try ELM327ResponseParser.dataBytes(in: "41ZZ32\r>", mode: 0x01, pid: 0x0D)
        }
    }

    @Test("An odd number of hex digits is rejected")
    func rejectsOddDigits() {
        #expect(throws: ELM327Error.malformedHex("410D3")) {
            try ELM327ResponseParser.dataBytes(in: "410D3\r>", mode: 0x01, pid: 0x0D)
        }
    }
}
