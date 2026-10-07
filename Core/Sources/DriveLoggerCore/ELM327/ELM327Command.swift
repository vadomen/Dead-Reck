import Foundation

/// A command sent to an ELM327-compatible OBD-II adapter.
///
/// The wire protocol is plain ASCII: write the command followed by a carriage
/// return, then read until the adapter emits its `>` prompt. `AT`-prefixed
/// commands configure the adapter itself; everything else is forwarded to the
/// vehicle bus as hex.
///
/// Deliberately closed: there is no raw-string or arbitrary-mode case, so
/// every command this type can express is read-only. It still goes through
/// `ELMCommandPolicy` on its way out (`validated()`), because the transport
/// only accepts a `ValidatedELMCommand`.
public enum ELM327Command: Hashable, Sendable {
    /// `ATZ` — full reset. Takes about a second and discards all AT settings,
    /// so the rest of the handshake has to be re-sent afterwards.
    case reset

    /// `ATE0` / `ATE1` — command echo. Logging always runs with echo off so
    /// replies don't have to be disambiguated from the request.
    case echo(Bool)

    /// `ATL0` / `ATL1` — append linefeeds to carriage returns.
    case lineFeeds(Bool)

    /// `ATS0` / `ATS1` — spaces between returned hex bytes. Off is cheaper to
    /// read; the parser copes with either.
    case spaces(Bool)

    /// `ATH0` / `ATH1` — include CAN headers in replies.
    case headers(Bool)

    /// `ATSP0` — let the adapter auto-detect the vehicle's OBD protocol.
    case autoProtocol

    /// `ATDPN` — report the detected protocol number.
    case describeProtocolNumber

    /// `ATRV` — the adapter's own reading of battery voltage. Useful as a
    /// cheap liveness probe between PID polls.
    case readVoltage

    /// `ATSH7E0` etc. — the CAN header requests go out with. `.functional`
    /// (`7DF`, the default after `ATZ`) asks every emissions ECU; a physical
    /// header (`7E0`–`7E7`) asks one. On the test car functional requests
    /// are answered by the engine (`7E8`) and the gearbox (`7E9`), and with
    /// the response-count suffix the first reply wins — which was the
    /// gearbox's. `ATSH7E0` makes the engine the only responder.
    case setHeader(CANRequestHeader)

    /// `ATAT0` / `ATAT1` / `ATAT2` — adaptive timing. 2 is the most aggressive
    /// and often the biggest rate win on clones; fall back to 1 if replies
    /// start getting cut off.
    case adaptiveTiming(Int)

    /// `0100` — supported PIDs 01–20 as a bitmask. After `ATSP0` this is also
    /// what forces the adapter to search for the vehicle's protocol, so it can
    /// take several seconds the first time.
    case supportedPIDs

    /// Mode `01` (current data) for one PID, e.g. `010C` for engine speed.
    case currentData(OBDPID)

    /// A mode `01` request for up to six PIDs in one frame, optionally with the
    /// response-count suffix: `.currentDataMany([.vehicleSpeed, .engineSpeed],
    /// responseCount: 1)` → `010D0C1`. The suffix tells the adapter to stop
    /// after that many replies instead of waiting out its timeout.
    ///
    /// The suffix is a single digit, 1–9. `validated()` rejects anything else:
    /// `responseCount: 10` would render `010D10`, which the adapter reads as a
    /// request for PIDs 0x0D **and 0x10**, and the policy alone can't tell.
    case currentDataMany([OBDPID], responseCount: Int?)

    /// The command text, without the carriage-return terminator.
    public var wireFormat: String {
        switch self {
        case .reset:
            "ATZ"
        case .echo(let on):
            "ATE\(on ? 1 : 0)"
        case .lineFeeds(let on):
            "ATL\(on ? 1 : 0)"
        case .spaces(let on):
            "ATS\(on ? 1 : 0)"
        case .headers(let on):
            "ATH\(on ? 1 : 0)"
        case .autoProtocol:
            "ATSP0"
        case .describeProtocolNumber:
            "ATDPN"
        case .readVoltage:
            "ATRV"
        case .setHeader(let header):
            "ATSH" + header.rawValue
        case .adaptiveTiming(let level):
            "ATAT\(level)"
        case .supportedPIDs:
            "0100"
        case .currentData(let pid):
            "01" + Hex.string(pid.rawValue)
        case .currentDataMany(let pids, let responseCount):
            "01" + Hex.string(pids.map(\.rawValue)) + (responseCount.map(String.init) ?? "")
        }
    }

    /// Bytes this command would put on the wire, carriage-return terminated.
    /// Informational: transports only accept `validated()`.
    public var wireData: Data {
        Data((wireFormat + "\r").utf8)
    }

    /// Passes the command through `ELMCommandPolicy` (session scope). Throws
    /// for parameters the type can hold but the wire can't express, e.g.
    /// `.adaptiveTiming(7)`, a seven-PID `.currentDataMany`, or a response
    /// count outside 1–9.
    public func validated() throws(ELMSessionError) -> ValidatedELMCommand {
        switch self {
        case .currentDataMany(let pids, let responseCount?) where !(1...9).contains(responseCount):
            throw .forbiddenCommand("currentDataMany(\(pids.count) PIDs, responseCount: \(responseCount))")
        case .adaptiveTiming(let level) where !(0...2).contains(level):
            throw .forbiddenCommand("adaptiveTiming(\(level))")
        default:
            return try ELMCommandPolicy.validate(wireFormat, scope: .session)
        }
    }
}

extension ELM327Command {
    /// The init sequence from docs/SPEC_V1.md, in order.
    ///
    /// Echo, linefeeds and spaces off keep replies compact; headers **on** so
    /// replies from different ECUs (`7E8`, `7E9`, …) can be told apart;
    /// `ATSP0` leaves protocol detection to the adapter and `0100` forces the
    /// search; `ATDPN` and `ATRV` record what was found. `ATSH7E0` last:
    /// physical addressing to the engine ECU, so the response-count suffix
    /// returns the engine's reply (bench test 2026-10-07). It runs after
    /// `0100`, which stays functional so the log records every ECU's
    /// supported PIDs. `ELMSession` runs this with per-step timeouts (long
    /// for `ATZ` and `0100`) and records every exchange; a refused `ATSH7E0`
    /// is not an init failure.
    public static let handshake: [ELM327Command] = [
        .reset,
        .echo(false),
        .lineFeeds(false),
        .spaces(false),
        .headers(true),
        .autoProtocol,
        .supportedPIDs,
        .describeProtocolNumber,
        .readVoltage,
        .setHeader(.engine),
    ]
}

/// An 11-bit CAN header for OBD requests (ISO 15765-4): `7DF` functional,
/// or `7E0`–`7E7` physical, one ECU each (that ECU answers on header + 8,
/// e.g. `7E0` → `7E8`). Nothing else can be built, so `.setHeader` can't
/// address a response ID (`7E8`), a 29-bit header or a manufacturer module.
public struct CANRequestHeader: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    /// Three upper-case hex digits.
    public let rawValue: String

    /// Accepts `7DF` and `7E0`–`7E7`, in either case; nil for anything else,
    /// including non-ASCII lookalikes.
    public init?(rawValue: String) {
        guard rawValue.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        let upper = rawValue.uppercased()
        guard Self.all.contains(where: { $0.rawValue == upper }) else { return nil }
        self.rawValue = upper
    }

    private init(checked rawValue: String) {
        self.rawValue = rawValue
    }

    /// `7DF`: every emissions ECU answers. The adapter's default after `ATZ`.
    public static let functional = CANRequestHeader(checked: "7DF")
    /// `7E0`: ECU #1, the engine, which answers on `7E8`.
    public static let engine = CANRequestHeader(checked: "7E0")

    /// `7DF`, then `7E0`…`7E7`.
    public static let all: [CANRequestHeader] = [functional]
        + (0...7).map { CANRequestHeader(checked: "7E\($0)") }

    /// True for `7E0`–`7E7`.
    public var isPhysical: Bool { self != .functional }

    public var description: String { rawValue }
}
