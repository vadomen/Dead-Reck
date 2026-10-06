import Foundation

/// A command that has passed `ELMCommandPolicy`. The only thing an
/// `ELMTransport` accepts.
///
/// The initialiser is internal to DriveLoggerCore and only the policy calls
/// it, so outside Core there is no way to build one without the check. App
/// code that holds the `CBPeripheral` could still call `writeValue` directly;
/// `RepositoryInvariantTests` asserts that only `BLETransport.send` does.
public struct ValidatedELMCommand: Hashable, Sendable {
    /// Command text without the carriage return, exactly as checked and sent:
    /// printable ASCII, uppercased.
    public let wire: String

    init(checkedWire wire: String) {
        self.wire = wire
    }

    /// Bytes to write, carriage-return terminated.
    public var wireData: Data {
        Data((wire + "\r").utf8)
    }
}

/// The read-only guard: the only gate between any caller and the adapter.
///
/// Car safety depends on this. It is an **allowlist**; anything not listed is
/// rejected. What is allowed depends on who is asking (`Scope`):
///
/// `.session` — the app's own init, probing and polling (`ELMSession`):
/// - AT commands: `ATZ`, `ATI`, `AT@1`, `ATE0`/`ATE1`, `ATL0`/`ATL1`,
///   `ATS0`/`ATS1`, `ATH0`/`ATH1`, `ATSP0`, `ATDP`, `ATDPN`, `ATRV`,
///   `ATAT0`–`ATAT2`, and `ATSThh` with `hh` from `19` to `FF` (≈100 ms to
///   1 s; shorter makes every poll answer `NO DATA`, which stops polling).
/// - Mode `01`.
///
/// `.manual` — the debug console, typed by a person mid-session:
/// - Query-only AT commands: `ATI`, `AT@1`, `ATDP`, `ATDPN`, `ATRV`.
/// - Mode `01`.
///
/// The console can't change echo, headers, spaces, timing or protocol, or
/// reset the adapter. The session depends on those settings to frame and
/// attribute replies; a change it didn't make would silently corrupt the rows
/// that follow (e.g. `ATH0` drops ECU attribution, `ATST01` makes every poll
/// time out and polling stop).
///
/// Mode `01` means `01` followed by 1–6 PID bytes and an optional single
/// response-count digit `1`–`9` (`010D`, `010D0C`, `010D1`, `010D0C1`).
///
/// "Any `AT…`" would not be safe. `ATCAF0` turns off CAN auto-formatting, after
/// which an innocent-looking `0104` goes out verbatim as a frame for service
/// 04 (clear DTCs). `ATSH`/`ATCRA` retarget requests, `ATPP` writes the
/// adapter's EEPROM, `ATMA`/`ATBRD` break the one-command-in-flight protocol.
/// Modes 04, 08, 2E, 31, 3B and anything UDS are never valid.
///
/// Input must be printable ASCII (0x21–0x7E) and is checked **before** any
/// case mapping, so lookalikes such as fullwidth digits (`０４`) or ligatures
/// are rejected rather than normalised. Letters may be lower case; the
/// uppercased form is what is checked and sent. Whitespace is rejected rather
/// than stripped.
public enum ELMCommandPolicy {
    public enum Scope: Hashable, Sendable {
        /// `ELMSession`'s own init, probe and poll commands.
        case session
        /// The debug console.
        case manual
    }

    public static func validate(
        _ wire: String,
        scope: Scope = .session
    ) throws(ELMSessionError) -> ValidatedELMCommand {
        guard !wire.isEmpty, wire.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else {
            throw .forbiddenCommand(wire)
        }
        // ASCII-only from here, so uppercasing can't turn one character into
        // another that would pass.
        let upper = wire.uppercased()
        let allowedAT = switch scope {
        case .session: isAllowedSessionAT(upper)
        case .manual: manualATCommands.contains(upper)
        }
        guard allowedAT || isAllowedMode01(upper) else {
            throw .forbiddenCommand(wire)
        }
        return ValidatedELMCommand(checkedWire: upper)
    }

    public static func isAllowed(_ wire: String, scope: Scope = .session) -> Bool {
        (try? validate(wire, scope: scope)) != nil
    }

    static let sessionATCommands: Set<String> = [
        "ATZ", "ATI", "AT@1",
        "ATE0", "ATE1", "ATL0", "ATL1", "ATS0", "ATS1", "ATH0", "ATH1",
        "ATSP0", "ATDP", "ATDPN", "ATRV",
        "ATAT0", "ATAT1", "ATAT2",
    ]

    static let manualATCommands: Set<String> = ["ATI", "AT@1", "ATDP", "ATDPN", "ATRV"]

    /// Lowest `ATST` value: 0x19 × 4.096 ms ≈ 102 ms.
    static let minimumATST: UInt8 = 0x19

    private static func isAllowedSessionAT(_ upper: String) -> Bool {
        if sessionATCommands.contains(upper) { return true }
        // ATSThh — adapter's own response timeout, in 4.096 ms units.
        if upper.hasPrefix("ATST"), upper.utf8.count == 6,
           upper.utf8.dropFirst(4).allSatisfy(isASCIIHexDigit),
           let value = UInt8(upper.dropFirst(4), radix: 16) {
            return value >= minimumATST
        }
        return false
    }

    private static func isAllowedMode01(_ upper: String) -> Bool {
        guard upper.hasPrefix("01") else { return false }
        var body = Array(upper.utf8.dropFirst(2))
        // An odd length means a trailing response-count digit.
        if !body.count.isMultiple(of: 2) {
            guard let last = body.last, (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(last) else {
                return false
            }
            body.removeLast()
        }
        return (1...6).contains(body.count / 2) && body.allSatisfy(isASCIIHexDigit)
    }

    private static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "F"):
            true
        default:
            false
        }
    }
}
