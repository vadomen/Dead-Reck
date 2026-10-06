import Foundation

/// A command sent to an ELM327-compatible OBD-II adapter.
///
/// The wire protocol is plain ASCII: write the command followed by a carriage
/// return, then read until the adapter emits its `>` prompt. `AT`-prefixed
/// commands configure the adapter itself; everything else is forwarded to the
/// vehicle bus as hex.
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

    /// A service/PID request, e.g. mode `0x01` PID `0x0C` for engine speed.
    case request(mode: UInt8, pid: UInt8)

    /// Escape hatch for adapter-specific commands; sent verbatim.
    case raw(String)

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
        case .request(let mode, let pid):
            Hex.string(mode) + Hex.string(pid)
        case .raw(let text):
            text
        }
    }

    /// Bytes to write to the adapter's characteristic, carriage-return
    /// terminated.
    public var wireData: Data {
        Data((wireFormat + "\r").utf8)
    }

    /// Requests current-data (service 01) for a PID.
    public static func currentData(_ pid: OBDPID) -> ELM327Command {
        .request(mode: 0x01, pid: pid.rawValue)
    }
}

extension ELM327Command {
    /// The handshake to run after connecting, in order.
    ///
    /// Echo, linefeeds and spaces off keeps replies to a single compact line;
    /// headers off because this logger records decoded PID values rather than
    /// raw CAN frames; `ATSP0` leaves protocol detection to the adapter, which
    /// handles the long tail of vehicles better than a hardcoded guess.
    public static let handshake: [ELM327Command] = [
        .reset,
        .echo(false),
        .lineFeeds(false),
        .spaces(false),
        .headers(false),
        .autoProtocol,
    ]
}
