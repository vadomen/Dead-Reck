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
        "ATAT0", "ATAT1", "ATAT2", "ATST32", "ATSTFF",
        "0100", "010D", "010C", "010D0C", "010D1", "010D0C1", "0104",
        "01000102030405", "010D0C9",
        "atz", "010d", "atst3c", "ATST19",
    ])
    func allows(_ wire: String) throws {
        let validated = try ELMCommandPolicy.validate(wire)
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
            try ELMCommandPolicy.validate(wire)
        }
    }

    @Test("AT commands that can make a mode 01 request unsafe are rejected", arguments: [
        "ATCAF0", "ATCAF1",  // raw CAN formatting: "0104" would go out as service 04
        "ATSH7E0", "ATSH7DF", "ATSH18DB33F1",  // set header / retarget
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
        #expect(!ELMCommandPolicy.isAllowed(wire))
    }

    @Test("Malformed or padded input is rejected, not cleaned up", arguments: [
        "", " ", "01", "010", "01 0D", " 010D", "010D ", "010D\r", "010D\n",
        "010DZZ", "010D0", "010D0C0", "010D0CA", "0101020304050607",
        "010D\r04", "ATZ\r04", "ATZ;04", "ATZ 04",
    ])
    func rejectsMalformed(_ wire: String) {
        #expect(!ELMCommandPolicy.isAllowed(wire))
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
        #expect(!ELMCommandPolicy.isAllowed(wire))
        #expect(!ELMCommandPolicy.isAllowed(wire, scope: .manual))
    }

    // Regression: ATST01 (4 ms) made every poll answer NO DATA, which by
    // convention stops polling that PID for the rest of the drive.
    @Test("ATST below about 100 ms is rejected", arguments: ["ATST00", "ATST01", "ATST0A", "ATST18"])
    func rejectsTooShortATST(_ wire: String) {
        #expect(!ELMCommandPolicy.isAllowed(wire))
    }

    // Regression: the console could change settings the session depends on.
    @Test("The console may only query the adapter", arguments: [
        "ATZ", "ATE0", "ATE1", "ATL0", "ATL1", "ATS0", "ATS1", "ATH0", "ATH1",
        "ATSP0", "ATAT0", "ATAT1", "ATAT2", "ATST32", "ATSTFF",
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
