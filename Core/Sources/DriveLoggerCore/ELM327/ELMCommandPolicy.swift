import Foundation

/// A command that has passed `ELMCommandPolicy`. The only thing an
/// `ELMTransport` accepts.
///
/// The initialiser is internal to DriveLoggerCore and only the policy calls
/// it, so outside Core there is no way to put bytes on the wire without the
/// check — not from the debug console, a keepalive or a future feature.
public struct ValidatedELMCommand: Hashable, Sendable {
    /// Command text without the carriage return, exactly as checked.
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
/// rejected:
///
/// - AT commands: `ATZ`, `ATI`, `AT@1`, `ATE0`/`ATE1`, `ATL0`/`ATL1`,
///   `ATS0`/`ATS1`, `ATH0`/`ATH1`, `ATSP0`, `ATDP`, `ATDPN`, `ATRV`,
///   `ATAT0`–`ATAT2`, `ATSThh` (two hex digits).
/// - Mode `01` requests: `01` followed by 1–6 PID bytes and an optional single
///   response-count digit `1`–`9` (`010D`, `010D0C`, `010D1`, `010D0C1`).
///
/// "Any `AT…`" would not be safe. `ATCAF0` turns off CAN auto-formatting, after
/// which an innocent-looking `0104` goes out verbatim as a frame for service
/// 04 (clear DTCs). `ATSH`/`ATCRA` retarget requests, `ATPP` writes the
/// adapter's EEPROM, `ATMA`/`ATBRD` break the one-command-in-flight protocol.
/// Modes 04, 08, 2E, 31, 3B and anything UDS are never valid.
///
/// Matching is case-insensitive. Whitespace and any other character are
/// rejected rather than stripped, so what is checked is exactly what is sent.
public enum ELMCommandPolicy {
    public static func validate(_ wire: String) throws(ELMSessionError) -> ValidatedELMCommand {
        let upper = wire.uppercased()
        guard isAllowedAT(upper) || isAllowedMode01(upper) else {
            throw .forbiddenCommand(wire)
        }
        return ValidatedELMCommand(checkedWire: upper)
    }

    public static func isAllowed(_ wire: String) -> Bool {
        (try? validate(wire)) != nil
    }

    static let allowedATCommands: Set<String> = [
        "ATZ", "ATI", "AT@1",
        "ATE0", "ATE1", "ATL0", "ATL1", "ATS0", "ATS1", "ATH0", "ATH1",
        "ATSP0", "ATDP", "ATDPN", "ATRV",
        "ATAT0", "ATAT1", "ATAT2",
    ]

    private static func isAllowedAT(_ upper: String) -> Bool {
        if allowedATCommands.contains(upper) { return true }
        // ATST hh — adapter's own response timeout, in 4 ms units.
        if upper.hasPrefix("ATST"), upper.count == 6 {
            return upper.dropFirst(4).allSatisfy(\.isHexDigit)
        }
        return false
    }

    private static func isAllowedMode01(_ upper: String) -> Bool {
        guard upper.hasPrefix("01") else { return false }
        var body = Substring(upper.dropFirst(2))
        // An odd length means a trailing response-count digit.
        if body.count.isMultiple(of: 2) == false {
            guard let last = body.last, ("1"..."9").contains(last) else { return false }
            body = body.dropLast()
        }
        let pidBytes = body.count / 2
        return (1...6).contains(pidBytes) && body.allSatisfy(\.isHexDigit)
    }
}
