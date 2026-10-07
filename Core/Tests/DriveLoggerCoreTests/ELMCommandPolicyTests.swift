import Foundation
import Testing

@testable import DriveLoggerCore

/// Guards the car-safety invariant: only allowlisted AT commands and mode 01
/// requests can ever reach the adapter.
@Suite("ELMCommandPolicy")
struct ELMCommandPolicyTests {
    @Test("Allowlisted commands pass", arguments: [
        "ATZ", "ATI", "AT@1", "ATE0", "ATE1", "ATL0", "ATL1", "ATS0", "ATS1",
        "ATH0", "ATH1", "ATSP0", "ATDP", "ATDPN", "ATRV",
        "ATAT0", "ATAT1", "ATAT2",
        "0100", "010D", "010C", "010D0C", "010D1", "010D0C1", "0104",
        "01000102030405", "010D0C9",
        "atz", "010d",
    ])
    func allows(_ wire: String) throws {
        let validated = try ELMCommandPolicy.validate(wire, scope: .session)
        #expect(validated.wire == wire.uppercased())
        #expect(validated.wireData == Data((wire.uppercased() + "\r").utf8))
    }

    @Test("Commands that write to the vehicle are rejected", arguments: [
        "04",          // clear DTCs
        "0400",
        "08", "0801",  // control of on-board systems
        "2E", "2EF190",  // UDS write data by identifier
        "31", "3101FF00",  // UDS routine control
        "3B", "3B90",  // KWP write data by local identifier
        "10", "1003",  // UDS diagnostic session control
        "11", "1101",  // ECU reset
        "14FFFFFF",    // clear diagnostic information (UDS)
        "27", "2701",  // security access
        "02", "020D00", "03", "07", "09", "0902", "0A",  // read-only, but not mode 01
    ])
    func rejectsOtherModes(_ wire: String) {
        #expect(throws: ELMSessionError.forbiddenCommand(wire)) {
            try ELMCommandPolicy.validate(wire, scope: .session)
        }
        #expect(throws: ELMSessionError.forbiddenCommand(wire)) {
            try ELMCommandPolicy.validate(wire, scope: .manual)
        }
    }

    @Test("AT commands that can make a mode 01 request unsafe are rejected", arguments: [
        "ATCAF0", "ATCAF1",  // raw CAN formatting: "0104" would go out as service 04
        "ATSH18DB33F1", "ATSH7E8", "ATSH6F1",  // set header: only 7DF/7E0-7E7, see ELMCommandPolicyHeaderTests
        "ATCRA7E8", "ATCRA",  // receive address filter
        "ATCEA", "ATCEA01",  // CAN extended address
        "ATPP0CSV01", "ATPP0CON", "ATPPS",  // programmable parameters (EEPROM)
        "ATMA", "ATMR01", "ATMT01",  // monitor modes: never return a prompt
        "ATBRD23", "ATBRT00",  // baud rate changes
        "ATWS", "ATD", "ATLP",  // warm start, defaults, low power
        "ATSP6", "ATSPA6", "ATTP6",  // protocol: only ATSP0 is allowed for now
        "ATAT3", "ATST", "ATST1", "ATST123", "ATSTGG",
        "ATSW00", "ATFCSH7E0", "ATFCSD300000", "ATFCSM1",
        "AT", "ATE2", "ATH",
    ])
    func rejectsDangerousAT(_ wire: String) {
        #expect(!ELMCommandPolicy.isAllowed(wire, scope: .session))
    }

    @Test("Malformed or padded input is rejected, not cleaned up", arguments: [
        "", " ", "01", "010", "01 0D", " 010D", "010D ", "010D\r", "010D\n",
        "010DZZ", "010D0", "010D0C0", "010D0CA", "0101020304050607",
        "010D\r04", "ATZ\r04", "ATZ;04", "ATZ 04",
    ])
    func rejectsMalformed(_ wire: String) {
        #expect(!ELMCommandPolicy.isAllowed(wire, scope: .session))
    }

    // Regression: Character.isHexDigit is true for fullwidth digits, and
    // uppercased() maps ligatures and dotless i, so lookalikes used to pass
    // and multibyte UTF-8 reached the adapter.
    @Test("Non-ASCII lookalikes are rejected, not normalised", arguments: [
        "01\u{FF10}\u{FF14}",        // fullwidth "04"
        "\u{FF10}\u{FF11}0D",         // fullwidth "01"
        "010\u{FF24}",               // fullwidth "D"
        "ATST\u{FF13}\u{FF12}",       // fullwidth "32"
        "01\u{0660}\u{0664}",         // Arabic-Indic "04"
        "01\u{2070}\u{2074}",         // superscript "04"
        "01\u{FB00}",                // "ﬀ" ligature, uppercases to "FF"
        "at\u{0131}",                // dotless i, uppercases to "ATI"
        "010D\u{00A0}",              // no-break space
        "010D\u{200B}",              // zero-width space
        "ATZ\u{0000}",
    ])
    func rejectsNonASCII(_ wire: String) {
        #expect(!ELMCommandPolicy.isAllowed(wire, scope: .session))
        #expect(!ELMCommandPolicy.isAllowed(wire, scope: .manual))
    }

    // R1-6: ATST was allowlisted but no code path could send it. It is no
    // longer allowed at any value: a too-short adapter timeout cuts off slow
    // ECUs, a supported PID then answers NO DATA, and by convention that PID
    // stops being polled for the rest of the drive. ATAT is the tuning knob.
    @Test("ATST is not allowlisted at any value", arguments: [
        "ATST00", "ATST01", "ATST0A", "ATST18", "ATST19", "ATST32", "ATSTFF", "atst3c",
    ])
    func rejectsATST(_ wire: String) {
        #expect(!ELMCommandPolicy.isAllowed(wire, scope: .session))
        #expect(!ELMCommandPolicy.isAllowed(wire, scope: .manual))
    }

    // Regression: the console could change settings the session depends on.
    @Test("The console may only query the adapter", arguments: [
        "ATZ", "ATE0", "ATE1", "ATL0", "ATL1", "ATS0", "ATS1", "ATH0", "ATH1",
        "ATSP0", "ATAT0", "ATAT1", "ATAT2",
    ])
    func manualScopeRejectsConfiguration(_ wire: String) {
        #expect(ELMCommandPolicy.isAllowed(wire, scope: .session))
        #expect(!ELMCommandPolicy.isAllowed(wire, scope: .manual))
    }

    @Test("The console may run read-only queries and mode 01", arguments: [
        "ATI", "AT@1", "ATDP", "ATDPN", "ATRV", "atrv", "0100", "010D", "010D0C1",
    ])
    func manualScopeAllowsQueries(_ wire: String) throws {
        let validated = try ELMCommandPolicy.validate(wire, scope: .manual)
        #expect(validated.wire == wire.uppercased())
    }

    @Test("Every dangerous command is rejected from the console too", arguments: [
        "ATCAF0", "ATSH7E0", "ATPPS", "ATMA", "ATBRD23", "ATD", "ATWS", "04", "2EF190",
    ])
    func manualScopeRejectsDangerous(_ wire: String) {
        #expect(!ELMCommandPolicy.isAllowed(wire, scope: .manual))
    }
}

/// `ATSH` with an OBD request header: session scope only (bench test
/// 2026-10-07, physical addressing to the engine ECU).
@Suite("ELMCommandPolicy ATSH")
struct ELMCommandPolicyHeaderTests {
    static let requestHeaders = ["7DF", "7E0", "7E1", "7E2", "7E3", "7E4", "7E5", "7E6", "7E7"]

    @Test("ATSH with a CAN request header (7DF, 7E0-7E7) is allowed in session scope", arguments: requestHeaders)
    func allowsRequestHeaders(_ header: String) throws {
        let validated = try ELMCommandPolicy.validate("ATSH" + header, scope: .session)
        #expect(validated.wire == "ATSH" + header)
        #expect(validated.wireData == Data("ATSH\(header)\r".utf8))
    }

    @Test("Lower case is accepted and sent upper case", arguments: ["atsh7e0", "AtSh7dF", "atsh7E7"])
    func lowercase(_ wire: String) throws {
        #expect(try ELMCommandPolicy.validate(wire, scope: .session).wire == wire.uppercased())
    }

    @Test("Every other ATSH form is rejected in both scopes", arguments: [
        // Response headers and other 11-bit addresses.
        "ATSH7E8", "ATSH7E9", "ATSH7EF", "ATSH6F1", "ATSH7DE", "ATSH7E", "ATSH7F0", "ATSH700", "ATSH000", "ATSH7D0",
        // 29-bit, 2-, 4- and 6-digit headers.
        "ATSH18DB33F1", "ATSH18DAF110", "ATSHE0", "ATSH07E0", "ATSH7E00", "ATSH0007E0", "ATSH18DAF1",
        // Spaces, trailing junk, a smuggled second command.
        "ATSH 7E0", "ATSH7E0 ", " ATSH7E0", "ATSH 7 E 0", "ATSH7E0X", "ATSH7E01", "ATSH7DF0", "ATSH7E0\r04",
        "ATSH7E0\r", "ATSH7E0;04", "ATSH",
        // Fullwidth and other lookalike digits.
        "ATSH7E\u{FF10}", "ATSH\u{FF17}E0", "ATSH7\u{FF25}0", "ATSH7E\u{0660}",
    ])
    func rejectsOtherHeaders(_ wire: String) {
        #expect(throws: ELMSessionError.forbiddenCommand(wire)) { try ELMCommandPolicy.validate(wire, scope: .session) }
        #expect(!ELMCommandPolicy.isAllowed(wire, scope: .manual))
    }

    // ATSH changes addressing state the session relies on, like ATH0.
    @Test("ATSH stays out of the console", arguments: requestHeaders)
    func consoleCannotSetHeader(_ header: String) {
        #expect(ELMCommandPolicy.isAllowed("ATSH" + header, scope: .session))
        #expect(throws: ELMSessionError.forbiddenCommand("ATSH" + header)) {
            try ELMCommandPolicy.validate("ATSH" + header, scope: .manual)
        }
    }

    // A physically addressed mode 01 request is still read-only only while
    // CAN formatting and addressing stay at their defaults.
    @Test("The commands that would make a physical request unsafe stay blocked", arguments: [
        "ATCAF0", "ATCAF1", "ATCRA7E8", "ATCRA", "ATCEA", "ATCEA01", "ATFCSH7E0", "ATFCSD300000", "ATFCSM1",
    ])
    func companionsStillBlocked(_ wire: String) {
        #expect(!ELMCommandPolicy.isAllowed(wire, scope: .session))
        #expect(!ELMCommandPolicy.isAllowed(wire, scope: .manual))
    }

    @Test("Mode 22 from the bench transcript (22F40D) is rejected in both scopes")
    func rejectsBenchMode22() {
        #expect(throws: ELMSessionError.forbiddenCommand("22F40D")) { try ELMCommandPolicy.validate("22F40D", scope: .session) }
        #expect(throws: ELMSessionError.forbiddenCommand("22F40D")) { try ELMCommandPolicy.validate("22F40D", scope: .manual) }
    }
}

@Suite("CANRequestHeader and ELM327Command.setHeader")
struct CANRequestHeaderTests {
    @Test("Only 7DF and 7E0-7E7 construct", arguments: ELMCommandPolicyHeaderTests.requestHeaders)
    func constructs(_ text: String) throws {
        let header = try #require(CANRequestHeader(rawValue: text))
        #expect(header.rawValue == text)
        #expect(header.isPhysical == (text != "7DF"))
        #expect(ELM327Command.setHeader(header).wireFormat == "ATSH" + text)
        #expect(try ELM327Command.setHeader(header).validated().wire == "ATSH" + text)
    }

    @Test("Lower case constructs the upper-case header")
    func lowercase() {
        #expect(CANRequestHeader(rawValue: "7e0") == .engine)
        #expect(CANRequestHeader(rawValue: "7df") == .functional)
    }

    @Test("Anything else doesn't construct", arguments: [
        "", "7E8", "7EF", "6F1", "7DE", "7E", "7E00", "07E0", "18DB33F1", " 7E0", "7E0 ", "7\u{FF25}0", "7E\u{FF10}",
    ])
    func rejects(_ text: String) {
        #expect(CANRequestHeader(rawValue: text) == nil)
    }

    @Test("Named headers and the full list")
    func named() {
        #expect(CANRequestHeader.functional.rawValue == "7DF")
        #expect(CANRequestHeader.engine.rawValue == "7E0")
        #expect(CANRequestHeader.all.map(\.rawValue) == ELMCommandPolicyHeaderTests.requestHeaders)
        #expect(CANRequestHeader.engine.isPhysical)
        #expect(!CANRequestHeader.functional.isPhysical)
    }
}
