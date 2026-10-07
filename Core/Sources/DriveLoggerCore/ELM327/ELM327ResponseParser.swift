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

/// One ECU's answer within a reply.
public struct ECUReply: Hashable, Sendable {
    /// CAN header, e.g. `7E8` (11-bit) or `18DAF110` (29-bit). Nil when the
    /// adapter runs with headers off.
    public var header: String?
    /// Reassembled data bytes including the service/PID echo, with the CAN PCI
    /// byte(s) removed.
    public var bytes: [UInt8]

    public init(header: String?, bytes: [UInt8]) {
        self.header = header
        self.bytes = bytes
    }
}

/// A non-hex reply to an `AT` command, classified.
public enum ELMTextReply: Hashable, Sendable {
    case ok
    /// `ATZ` / `ATI` banner, e.g. `ELM327 v2.1`.
    case banner(String)
    /// `ATDPN`, e.g. `A6`.
    case protocolNumber(String)
    /// `ATRV`, parsed volts.
    case voltage(Double)
    /// Anything else, verbatim.
    case other(String)
}

extension ELM327ResponseParser {
    /// Splits a reply into per-ECU answers.
    ///
    /// With `headers: true` (`ATH1`, the logger's mode) every line starts with
    /// a CAN header and a PCI byte: `7E803410D3C`. With `headers: false` lines
    /// are bare payload: `410D3C`. Multi-frame answers are reassembled per ECU.
    /// Status lines (`NO DATA`, …) throw, as in `dataBytes(in:mode:pid:)`.
    ///
    /// Header-on lines: an odd number of hex digits is an 11-bit header (3
    /// digits), an even number a 29-bit header (8 digits, e.g. `18DAF110`).
    /// The PCI byte decides the rest: `0L` single frame of `L` bytes (padding
    /// after them dropped), `1L LL` ISO-TP first frame with a 12-bit length,
    /// `2N` consecutive frame `N`. Frames are reassembled per header, so two
    /// ECUs may interleave. Replies come back in order of each ECU's first
    /// line.
    ///
    /// Header-off lines: a 3-digit line is an ISO-TP byte count that opens a
    /// block, `N:` lines belong to the open block (sorted by index, padding
    /// trimmed to the count), and any other line is one ECU's single frame.
    ///
    /// Echo lines — anything shaped like a command the session could send
    /// (`010D`, `ATRV`) — are dropped: no reply line has that shape.
    /// `SEARCHING...` and informational `BUS INIT` lines are dropped too.
    public static func replies(in raw: String, headers: Bool) throws -> [ECUReply] {
        let lines = lines(in: raw).filter { !ELMCommandPolicy.looksLikeSessionCommand($0) }
        for line in lines {
            if let error = error(for: line) { throw error }
        }
        guard !lines.isEmpty else { throw ELM327Error.emptyResponse }
        return headers ? try headerOnReplies(lines) : try headerOffReplies(lines)
    }

    /// Classifies the reply to an `AT` command. `command` is the wire text that
    /// was sent, used to pick the interpretation (`ATRV` → voltage).
    ///
    /// The echo (a line equal to `command`) is dropped and the last remaining
    /// line is interpreted, so leftovers before the answer don't matter.
    /// `ATZ`/`ATI` → `.banner` (whatever the clone calls itself), `ATDPN` →
    /// `.protocolNumber`, `ATRV` → `.voltage` if it parses, `OK` → `.ok`,
    /// anything else → `.other`. Status lines throw.
    public static func textReply(to command: String, raw: String) throws -> ELMTextReply {
        let upperCommand = command.uppercased()
        let lines = lines(in: raw).filter { $0.uppercased() != upperCommand }
        for line in lines {
            if let error = error(for: line) { throw error }
        }
        guard let line = lines.last else { throw ELM327Error.emptyResponse }

        switch upperCommand {
        case "ATZ", "ATI":
            return .banner(line)
        case "ATDPN":
            return .protocolNumber(line)
        case "ATRV":
            var digits = String(line.filter { !$0.isWhitespace })
            if digits.last == "V" || digits.last == "v" { digits.removeLast() }
            if let volts = Double(digits), volts.isFinite { return .voltage(volts) }
            return .other(line)
        default:
            return line.uppercased() == "OK" ? .ok : .other(line)
        }
    }

    private static func isASCIIHex(_ character: Character) -> Bool {
        character.isASCII && character.isHexDigit
    }

    private static func headerOnReplies(_ lines: [String]) throws -> [ECUReply] {
        struct OpenTransfer {
            var replyIndex: Int
            var declaredLength: Int
            var nextSequence: UInt8
        }
        var replies: [ECUReply] = []
        var open: [String: OpenTransfer] = [:]

        for line in lines {
            let digits = String(line.filter { !$0.isWhitespace })
            guard digits.allSatisfy(isASCIIHex) else { throw ELM327Error.malformedHex(line) }
            let headerLength = digits.count.isMultiple(of: 2) ? 8 : 3
            guard digits.count >= headerLength + 2 else { throw ELM327Error.malformedFrame(line) }
            let header = String(digits.prefix(headerLength))
            let frame = try Hex.bytes(in: digits.dropFirst(headerLength))
            let pci = frame[0]

            switch pci >> 4 {
            case 0x0:
                let length = Int(pci & 0x0F)
                guard (1...7).contains(length), open[header] == nil else { throw ELM327Error.malformedFrame(line) }
                let data = frame.dropFirst()
                guard data.count >= length else {
                    throw ELM327Error.truncatedFrame(expected: length, actual: data.count)
                }
                replies.append(ECUReply(header: header, bytes: Array(data.prefix(length))))
            case 0x1:
                guard frame.count >= 2, open[header] == nil else { throw ELM327Error.malformedFrame(line) }
                let length = Int(pci & 0x0F) << 8 | Int(frame[1])
                guard length > 7 else { throw ELM327Error.malformedFrame(line) }
                open[header] = OpenTransfer(replyIndex: replies.count, declaredLength: length, nextSequence: 1)
                replies.append(ECUReply(header: header, bytes: Array(frame.dropFirst(2).prefix(length))))
            case 0x2:
                guard var transfer = open[header], pci & 0x0F == transfer.nextSequence else {
                    throw ELM327Error.malformedFrame(line)
                }
                let missing = transfer.declaredLength - replies[transfer.replyIndex].bytes.count
                replies[transfer.replyIndex].bytes += frame.dropFirst().prefix(missing)
                if replies[transfer.replyIndex].bytes.count >= transfer.declaredLength {
                    open[header] = nil
                } else {
                    transfer.nextSequence = (transfer.nextSequence + 1) & 0x0F
                    open[header] = transfer
                }
            default:
                throw ELM327Error.malformedFrame(line)
            }
        }

        if let unfinished = open.values.min(by: { $0.replyIndex < $1.replyIndex }) {
            throw ELM327Error.truncatedFrame(
                expected: unfinished.declaredLength,
                actual: replies[unfinished.replyIndex].bytes.count
            )
        }
        return replies
    }

    private static func headerOffReplies(_ lines: [String]) throws -> [ECUReply] {
        var replies: [ECUReply] = []
        var block: (declared: Int?, frames: [(index: Int, bytes: [UInt8])])?

        func closeBlock() throws {
            guard let open = block else { return }
            block = nil
            let payload = open.frames.sorted { $0.index < $1.index }.flatMap(\.bytes)
            guard let declared = open.declared else {
                replies.append(ECUReply(header: nil, bytes: payload))
                return
            }
            guard payload.count >= declared else {
                throw ELM327Error.truncatedFrame(expected: declared, actual: payload.count)
            }
            // Trailing bytes are ISO-TP padding.
            replies.append(ECUReply(header: nil, bytes: Array(payload.prefix(declared))))
        }

        for line in lines {
            if let colon = line.firstIndex(of: ":") {
                let indexText = line[line.startIndex..<colon].filter { !$0.isWhitespace }
                guard !indexText.isEmpty, indexText.allSatisfy(isASCIIHex), let index = Int(indexText, radix: 16) else {
                    throw ELM327Error.malformedHex(line)
                }
                if block == nil { block = (nil, []) }
                block?.frames.append((index, try Hex.bytes(in: line[line.index(after: colon)...])))
                continue
            }
            let digits = String(line.filter { !$0.isWhitespace })
            try closeBlock()
            if digits.count == 3, digits.allSatisfy(isASCIIHex) {
                block = (Int(digits, radix: 16), [])
            } else {
                guard digits.allSatisfy(isASCIIHex) else { throw ELM327Error.malformedHex(line) }
                replies.append(ECUReply(header: nil, bytes: try Hex.bytes(in: line)))
            }
        }
        try closeBlock()
        return replies
    }
}

