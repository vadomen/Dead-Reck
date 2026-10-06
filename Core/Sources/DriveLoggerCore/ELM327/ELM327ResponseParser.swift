import Foundation

/// Turns the raw ASCII an ELM327 adapter writes back into data bytes.
///
/// A reply looks like `41 0C 1A F8\r\r>` with echo and headers off. Longer
/// replies arrive as an ISO-TP multi-frame block: a byte-count line followed by
/// index-prefixed lines, which may not arrive in order.
///
/// ```
/// 014
/// 0: 41 00 BE 1F
/// 1: A8 13 00 00
/// ```
public enum ELM327ResponseParser {
    /// Splits a raw reply into meaningful lines.
    ///
    /// Drops the `>` prompt, blank lines, and the transient chatter the adapter
    /// emits while negotiating (`SEARCHING...`, `BUS INIT: ...`) — those are
    /// progress reports, not results. A `BUS INIT` line that reports an error is
    /// kept so `error(for:)` can classify it.
    public static func lines(in raw: String) -> [String] {
        // Split the scalar view, not the character view: Swift treats CRLF as a
        // single Character, so a Character-level separator never matches it and
        // an adapter still set to ATL1 would yield lines with \r\n glued on.
        raw.unicodeScalars
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .map { scalars in
                String(String.UnicodeScalarView(scalars))
                    .replacingOccurrences(of: ">", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { line in
                guard !line.isEmpty else { return false }
                let upper = line.uppercased()
                if upper.hasPrefix("SEARCHING") { return false }
                if upper.hasPrefix("BUS INIT") { return upper.contains("ERROR") }
                return true
            }
    }

    /// Classifies a line as an adapter error, or returns nil if it looks like
    /// payload.
    ///
    /// Matching ignores spaces because the same adapter reports `BUFFER FULL`
    /// and `BUFFERFULL` depending on firmware.
    public static func error(for line: String) -> ELM327Error? {
        let normalised = String(line.uppercased().filter { !$0.isWhitespace })
        switch normalised {
        case "":
            return nil
        case "NODATA":
            return .noData
        case "UNABLETOCONNECT":
            return .unableToConnect
        case "STOPPED":
            return .stopped
        case "BUSERROR":
            return .busError
        case "CANERROR":
            return .canError
        case "BUFFERFULL":
            return .bufferFull
        case "DATAERROR":
            return .dataError
        case "?":
            return .notRecognised
        default:
            break
        }

        if normalised.hasPrefix("BUSINIT"), normalised.contains("ERROR") {
            return .busInitFailed
        }
        // Firmware-specific codes are all spelled `ERR<xx>`.
        if normalised.hasPrefix("ERR") {
            return .adapter(line)
        }
        return nil
    }

    /// Concatenated data bytes of a reply, with multi-frame reassembly applied
    /// and the service/PID echo stripped.
    ///
    /// Validates that the adapter answered the request actually sent: a positive
    /// reply repeats the requested service plus `0x40`, then the PID. Mismatches
    /// mean a reply was matched to the wrong in-flight request, which would
    /// otherwise silently mislabel a sample.
    public static func dataBytes(in raw: String, mode: UInt8, pid: UInt8) throws -> [UInt8] {
        let bytes = try frameBytes(in: raw)

        guard bytes.count >= 2 else {
            throw ELM327Error.truncatedFrame(expected: 2, actual: bytes.count)
        }
        let expectedMode = mode | 0x40
        guard bytes[0] == expectedMode else {
            throw ELM327Error.unexpectedMode(expected: expectedMode, actual: bytes[0])
        }
        guard bytes[1] == pid else {
            throw ELM327Error.unexpectedPID(expected: pid, actual: bytes[1])
        }
        return Array(bytes.dropFirst(2))
    }

    /// Reassembled bytes of a reply, including the service/PID echo.
    static func frameBytes(in raw: String) throws -> [UInt8] {
        let lines = lines(in: raw)
        guard !lines.isEmpty else { throw ELM327Error.emptyResponse }
        for line in lines {
            if let error = error(for: line) { throw error }
        }

        // Index-prefixed lines mark an ISO-TP multi-frame block.
        guard lines.contains(where: { $0.contains(":") }) else {
            return try lines.flatMap { try Hex.bytes(in: $0) }
        }

        var declaredByteCount: Int?
        var frames: [(index: Int, bytes: [UInt8])] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else {
                // The one line without an index is the total byte count, which
                // may be an odd number of hex digits (e.g. `014`).
                declaredByteCount = Int(String(line.filter { !$0.isWhitespace }), radix: 16)
                continue
            }
            guard let index = Int(line[line.startIndex..<colon], radix: 16) else {
                throw ELM327Error.malformedHex(line)
            }
            frames.append((index, try Hex.bytes(in: line[line.index(after: colon)...])))
        }

        let payload = frames.sorted { $0.index < $1.index }.flatMap { $0.bytes }
        guard let declaredByteCount else { return payload }
        guard payload.count >= declaredByteCount else {
            throw ELM327Error.truncatedFrame(expected: declaredByteCount, actual: payload.count)
        }
        // Trailing bytes are ISO-TP padding.
        return Array(payload.prefix(declaredByteCount))
    }
}
