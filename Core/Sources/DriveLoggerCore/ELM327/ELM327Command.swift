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

    /// Passes the command through `ELMCommandPolicy`. Can still throw, e.g. for
    /// `.adaptiveTiming(7)` or a seven-PID `.currentDataMany`.
    public func validated() throws(ELMSessionError) -> ValidatedELMCommand {
        try ELMCommandPolicy.validate(wireFormat)
    }
}

extension ELM327Command {
    /// The init sequence from docs/SPEC_V1.md, in order.
    ///
    /// Echo, linefeeds and spaces off keep replies compact; headers **on** so
    /// replies from different ECUs (`7E8`, `7E9`, …) can be told apart;
    /// `ATSP0` leaves protocol detection to the adapter and `0100` forces the
    /// search; `ATDPN` and `ATRV` record what was found. `ELMSession` runs this
    /// with per-step timeouts (long for `ATZ` and `0100`) and records every
    /// exchange.
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
    ]
}
