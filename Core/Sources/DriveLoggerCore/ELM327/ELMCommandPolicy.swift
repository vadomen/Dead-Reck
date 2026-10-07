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
///   `ATAT0`–`ATAT2`, and `ATSH` with an OBD request header: `ATSH7DF`,
///   `ATSH7E0`–`ATSH7E7` (`CANRequestHeader`).
/// - Mode `01`.
///
/// `.manual` — the debug console, typed by a person mid-session:
/// - Query-only AT commands: `ATI`, `AT@1`, `ATDP`, `ATDPN`, `ATRV`.
/// - Mode `01`.
///
/// The console can't change echo, headers, spaces, timing, protocol or
/// addressing, or reset the adapter. The session depends on those settings to
/// frame and attribute replies; a change it didn't make would silently
/// corrupt the rows that follow (e.g. `ATH0` drops ECU attribution, and an
/// `ATSH` the session didn't send would make the plan's recorded addressing
/// wrong and could put the response-count suffix on functional requests).
///
/// `ATSH` is allowed for **request** headers only, because the bench test
/// (2026-10-07) showed that with functional addressing (`7DF`) the
/// response-count suffix returns whichever ECU answers first, which on the
/// test car was the gearbox (`7E9`), not the engine. `ATSH7E0` addresses the
/// engine alone. It is still read-only:
/// - only `7DF` and `7E0`–`7E7` are accepted, the ISO 15765-4 OBD request
///   IDs; response IDs (`7E8`), other 11-bit IDs (`6F1`, `7DE`), 29-bit and
///   any other length are rejected;
/// - those are OBD request IDs **only on 11-bit CAN**. A 3-digit `ATSH xyz`
///   sets the header to `00 0x yz`: on 29-bit CAN (protocols 7, 9) `ATSH7E0`
///   means `180007E0`, not a diagnostic ID, and on ISO 9141/KWP/J1850 the
///   header bytes `00 07 E0`. The policy can't see the protocol, so
///   `ELMSession` sends a physical header only when `ATDPN` reported 11-bit
///   ISO 15765-4 (`6`, `A6`, `8`, `A8`) and `0100` was answered from `7E8`
///   (see `ELM327Command.physicalAddressing`);
/// - the payload is still mode `01` only;
/// - `ATCAF0`, `ATCRA` and `ATCEA` stay blocked, so the adapter still adds the
///   ISO-TP length byte itself and a physically addressed `0104` is a mode
///   01 request for PID 04 to the engine, never service 04.
///
/// `ATSThh` (the adapter's own reply timeout) is deliberately **not** listed,
/// in either scope. No code path needs it: adaptive timing (`ATAT`) is the
/// knob the session probes. A value too short for this car's slowest
/// responder lets the adapter give up before a supported PID answers (J1979
/// gives a CAN ECU up to 50 ms, and clones and multi-ECU replies add their
/// own latency); the reply is then `NO DATA`, and by the `NO DATA` convention
/// that PID stops being polled for the rest of the drive. Adding it back is a
/// reviewed change, best made with bench data (M4).
///
/// Mode `01` means `01` followed by 1–6 PID bytes and an optional single
/// response-count digit `1`–`9` (`010D`, `010D0C`, `010D1`, `010D0C1`).
///
/// "Any `AT…`" would not be safe. `ATCAF0` turns off CAN auto-formatting, after
/// which an innocent-looking `0104` goes out verbatim as a frame for service
/// 04 (clear DTCs). `ATSH` to anything but an OBD request ID and `ATCRA`
/// retarget requests or replies, `ATPP` writes the adapter's EEPROM,
/// `ATMA`/`ATBRD` break the one-command-in-flight protocol. Modes 04, 08, 2E,
/// 22, 31, 3B and anything UDS are never valid.
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

    /// Checks `wire` against the allowlist for `scope`. There is deliberately
    /// no default scope: the caller has to say whether this is the session's
    /// own command (`.session`) or something a person typed (`.manual`).
    public static func validate(
        _ wire: String,
        scope: Scope
    ) throws(ELMSessionError) -> ValidatedELMCommand {
        guard !wire.isEmpty, wire.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else {
            throw .forbiddenCommand(wire)
        }
        // ASCII-only from here, so uppercasing can't turn one character into
        // another that would pass.
        let upper = wire.uppercased()
        let allowedAT = switch scope {
        case .session: sessionATCommands.contains(upper)
        case .manual: manualATCommands.contains(upper)
        }
        guard allowedAT || isAllowedMode01(upper) else {
            throw .forbiddenCommand(wire)
        }
        return ValidatedELMCommand(checkedWire: upper)
    }

    public static func isAllowed(_ wire: String, scope: Scope) -> Bool {
        (try? validate(wire, scope: scope)) != nil
    }

    static let sessionATCommands: Set<String> = Set([
        "ATZ", "ATI", "AT@1",
        "ATE0", "ATE1", "ATL0", "ATL1", "ATS0", "ATS1", "ATH0", "ATH1",
        "ATSP0", "ATDP", "ATDPN", "ATRV",
        "ATAT0", "ATAT1", "ATAT2",
    ]).union(CANRequestHeader.all.map { ELM327Command.setHeader($0).wireFormat })

    static let manualATCommands: Set<String> = ["ATI", "AT@1", "ATDP", "ATDPN", "ATRV"]

    /// True if `line` is a command this policy would let the session send.
    /// The reply parser uses it to recognise echo lines: no adapter reply
    /// line has that shape (replies start with `41`, `7F`, a CAN header or a
    /// 3-digit ISO-TP byte count, never `AT` or a mode `01` request).
    static func looksLikeSessionCommand(_ line: String) -> Bool {
        isAllowed(line, scope: .session)
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
