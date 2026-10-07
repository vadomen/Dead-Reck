import Foundation

/// What a read found besides events.
public struct LogReadReport: Hashable, Sendable {
    /// Complete, intact gzip members decoded, header member included. Zero
    /// for a plain `.jsonl` file.
    public var members: Int
    /// The file ended inside a gzip member, or its remaining bytes are not a
    /// gzip member at all (e.g. zero-filled blocks after a power loss). That
    /// remainder was dropped. Expected after a crash or flat battery; every
    /// complete member before it was read.
    public var truncatedTail: Bool
    /// Zero-based indices of lines skipped under
    /// `LogRecovery.skipMalformedLines`. Counted over non-empty lines in the
    /// whole file, header = 0, as `LogCodec.document(from:)` counts them.
    /// Lines inside a damaged member are not counted.
    public var skippedLineIndices: [Int]
    /// Zero-based indices (header member = 0) of complete members that failed
    /// to decompress or failed their CRC-32 / ISIZE check and were skipped
    /// under `LogRecovery.skipMalformedLines`. Not expected from
    /// `LogFileWriter`, which never leaves a partial member mid-file; this is
    /// media corruption. Index 0 (the header member) is special: its content
    /// is still used if it inflates despite the failed checksum, because
    /// without a header no event in the file could be read. A header member
    /// that doesn't even inflate makes `init` throw
    /// `LogDecodingError.damagedMember(index: 0, …)`.
    public var damagedMemberIndices: [Int]
    /// Under `LogRecovery.strict`: the problem that ended iteration early
    /// (`.malformedLine` or `.damagedMember`). nil otherwise.
    public var failure: LogDecodingError?

    public init(
        members: Int,
        truncatedTail: Bool,
        skippedLineIndices: [Int],
        damagedMemberIndices: [Int] = [],
        failure: LogDecodingError? = nil
    ) {
        self.members = members
        self.truncatedTail = truncatedTail
        self.skippedLineIndices = skippedLineIndices
        self.damagedMemberIndices = damagedMemberIndices
        self.failure = failure
    }
}

/// A file `LogFileReader` cannot read at all.
public enum LogFileReadError: Error, Hashable, Sendable {
    /// A gzip file whose members lack DriveLogger's `DL` length subfield —
    /// e.g. a recording that was decompressed and recompressed with `gzip`.
    /// Decompress it (`gunzip`) and read the plain `.jsonl`.
    case foreignGzip(path: String)
}

/// Streams a recording member by member without loading it whole.
///
/// Accepts both `.jsonl.gz` files written by `LogFileWriter` (detected by the
/// gzip magic, not the file name) and plain `.jsonl`. Holds at most one gzip
/// member — or one 1 MiB chunk of a plain file — in memory at a time.
///
/// - Every member's CRC-32 and ISIZE are verified.
/// - A truncated final member (crash, flat battery) is dropped and reported
///   as `truncatedTail`; everything before it is returned.
/// - A half-written or otherwise undecodable line is skipped and its index
///   reported under `LogRecovery.skipMalformedLines`; under `.strict`,
///   iteration stops there and `report.failure` says why. A damaged complete
///   member is handled the same way, member-wide.
/// - A header from a newer format version is refused in `init`
///   (`LogDecodingError.unsupportedFormatVersion`), as `LogCodec` does.
/// - The header is always the first line of member 0 (or of a plain file);
///   an event line is never taken for it. A header member with a bad
///   checksum is salvaged under `.skipMalformedLines` (listed in
///   `damagedMemberIndices`) and refused under `.strict`; one that cannot be
///   inflated is refused with `.damagedMember(index: 0, …)`.
///
/// Single pass: the reader is its own cursor, so a second iterator continues
/// where the first stopped. Not `Sendable`: owns a `LogCodec`.
public final class LogFileReader: Sequence {
    public let header: LogHeader
    private let cursor: Cursor

    public init(url: URL, recovery: LogRecovery = .skipMalformedLines) throws {
        let cursor = try Cursor(url: url, recovery: recovery)
        let line = try cursor.nextLine()
        if let failure = cursor.headerMemberFailure {
            throw failure
        }
        // In a gzip file the header is the first line of member 0. An event
        // line from a later member is never taken for it.
        guard let line, cursor.isPlain || cursor.lineSourceMember == 0 else {
            throw LogDecodingError.missingHeader
        }
        do {
            header = try cursor.codec.header(from: line)
        } catch LogDecodingError.missingHeader where cursor.report.damagedMemberIndices.contains(0) {
            throw LogDecodingError.damagedMember(
                index: 0,
                description: "header member failed its checksum and its first line is not a header"
            )
        }
        self.cursor = cursor
    }

    /// What the read found so far. Final once iteration has finished.
    public var report: LogReadReport {
        cursor.report
    }

    public func makeIterator() -> Iterator {
        Iterator(cursor: cursor)
    }

    public struct Iterator: IteratorProtocol {
        fileprivate let cursor: Cursor

        public mutating func next() -> LogEvent? {
            cursor.nextEvent()
        }
    }
}

/// The reader's state: file, current member's lines, report.
private final class Cursor {
    enum Format { case gzip, plain }

    let codec = LogCodec()
    let recovery: LogRecovery
    private(set) var report = LogReadReport(members: 0, truncatedTail: false, skippedLineIndices: [])
    /// Set when member 0 cannot be salvaged; `LogFileReader.init` throws it.
    private(set) var headerMemberFailure: LogDecodingError?
    /// Member index the current batch of lines came from (gzip only).
    private(set) var lineSourceMember = -1
    var isPlain: Bool { format == .plain }

    private let file: ChunkedFile
    private let format: Format
    private let path: String
    /// Lines of the current member (or plain chunk) with their file-wide index.
    private var lines: [(index: Int, data: Data)] = []
    private var lineCursor = 0
    private var nextLineIndex = 0
    private var nextMemberIndex = 0
    private var plainRemainder = Data()
    private var exhausted = false

    init(url: URL, recovery: LogRecovery) throws {
        self.recovery = recovery
        self.path = url.path
        file = try ChunkedFile(url: url)
        let magic = try file.peek(2)
        format = magic == Data([0x1F, 0x8B]) ? .gzip : .plain
        if format == .gzip, case .foreign = GzipMember.parseHeader(try file.peek(65_600)) {
            throw LogFileReadError.foreignGzip(path: path)
        }
    }

    /// The next non-empty line, loading members as needed. nil at the end.
    func nextLine() throws -> Data? {
        while true {
            if lineCursor < lines.count {
                let line = lines[lineCursor].data
                lineCursor += 1
                return line
            }
            if exhausted { return nil }
            load()
        }
    }

    func nextEvent() -> LogEvent? {
        while true {
            if lineCursor < lines.count {
                let (index, line) = lines[lineCursor]
                lineCursor += 1
                do {
                    return try codec.event(from: line)
                } catch {
                    switch recovery {
                    case .strict:
                        stop(.malformedLine(index: index, description: String(describing: error)))
                        return nil
                    case .skipMalformedLines:
                        report.skippedLineIndices.append(index)
                        continue
                    }
                }
            }
            if exhausted { return nil }
            load()
        }
    }

    private func stop(_ failure: LogDecodingError) {
        report.failure = failure
        exhausted = true
        lines = []
        lineCursor = 0
    }

    private func load() {
        lines.removeAll(keepingCapacity: true)
        lineCursor = 0
        switch format {
        case .gzip: loadMember()
        case .plain: loadPlainChunk()
        }
    }

    private func loadMember() {
        let memberIndex = nextMemberIndex
        do {
            guard try file.fill(atLeast: 1) else {
                exhausted = true  // clean end, exactly at a member boundary
                return
            }
            // Our headers are 20 bytes; grow the window only for a header with
            // optional name/comment fields.
            var want = GzipMember.headerLength
            var parsed: GzipMember.Header?
            while parsed == nil {
                let enough = try file.fill(atLeast: want)
                switch GzipMember.parseHeader(try file.peek(min(file.available, 65_600))) {
                case .complete(let header):
                    parsed = header
                case .needMoreBytes:
                    guard enough, want < 65_600 else {
                        truncatedTail()  // the file ends inside the header
                        return
                    }
                    want = file.available + 256
                case .invalid, .foreign:
                    truncatedTail()  // not a member: zero fill, garbage
                    return
                }
            }
            guard let header = parsed, try file.fill(atLeast: header.totalLength) else {
                truncatedTail()
                return
            }
            let member = file.consume(header.totalLength)
            nextMemberIndex += 1
            let payload: Data
            do {
                payload = try GzipMember.decode(member)
                report.members += 1
            } catch {
                guard memberIndex == 0 else {
                    damaged(memberIndex, String(describing: error))
                    return
                }
                // The header member. Losing it would make every intact event
                // member unreadable, so under recovery its content is used
                // when it still inflates, checksum notwithstanding, and the
                // member is listed as damaged. Otherwise the whole read fails
                // with a specific error rather than guessing a header.
                if recovery == .skipMalformedLines,
                   let salvaged = try? GzipMember.decode(member, verifyingChecksums: false) {
                    report.damagedMemberIndices.append(0)
                    payload = salvaged
                } else {
                    headerMemberFailure = .damagedMember(index: 0, description: String(describing: error))
                    exhausted = true
                    return
                }
            }
            lineSourceMember = memberIndex
            appendLines(payload)
        } catch {
            damaged(memberIndex, "read error: \(error)")
            exhausted = true
        }
    }

    private func truncatedTail() {
        report.truncatedTail = true
        exhausted = true
    }

    private func damaged(_ index: Int, _ description: String) {
        switch recovery {
        case .strict:
            stop(.damagedMember(index: index, description: description))
        case .skipMalformedLines:
            report.damagedMemberIndices.append(index)
        }
    }

    private func loadPlainChunk() {
        do {
            guard let chunk = try file.readChunk() else {
                if !plainRemainder.isEmpty {
                    appendLines(plainRemainder)
                    plainRemainder = Data()
                }
                exhausted = true
                return
            }
            var data = plainRemainder
            data.append(chunk)
            if let newline = data.lastIndex(of: UInt8(ascii: "\n")) {
                appendLines(data[data.startIndex...newline])
                plainRemainder = Data(data[(newline + 1)...])
            } else {
                plainRemainder = data
            }
        } catch {
            stop(.damagedMember(index: 0, description: "read error: \(error)"))
        }
    }

    /// Splits on `\n`, trims trailing `\r` and spaces, drops blank lines —
    /// the same rule as `LogCodec.document(from:)`.
    private func appendLines(_ data: Data) {
        for piece in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            var line = piece
            while let last = line.last, last == UInt8(ascii: "\r") || last == UInt8(ascii: " ") {
                line = line.dropLast()
            }
            guard !line.isEmpty else { continue }
            lines.append((nextLineIndex, Data(line)))
            nextLineIndex += 1
        }
    }
}

/// Buffered sequential reads from a file.
private final class ChunkedFile {
    static let chunkSize = 1 << 20

    private let handle: FileHandle
    private var buffer = Data()
    private var position = 0
    private var atEnd = false

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle.close()
    }

    var available: Int { buffer.count - position }

    /// Reads until at least `count` bytes are buffered or the file ends.
    /// Returns whether `count` bytes are available.
    func fill(atLeast count: Int) throws -> Bool {
        while available < count, !atEnd {
            if position > 0 {
                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + position))
                position = 0
            }
            let want = max(Self.chunkSize, count - available)
            if let more = try handle.read(upToCount: want), !more.isEmpty {
                buffer.append(more)
            } else {
                atEnd = true
            }
        }
        return available >= count
    }

    /// Up to `count` buffered bytes, without consuming them.
    func peek(_ count: Int) throws -> Data {
        _ = try fill(atLeast: count)
        let start = buffer.startIndex + position
        return buffer.subdata(in: start..<(start + min(count, available)))
    }

    /// Removes and returns `count` buffered bytes. Call `fill` first.
    func consume(_ count: Int) -> Data {
        let start = buffer.startIndex + position
        let bytes = buffer.subdata(in: start..<(start + count))
        position += count
        return bytes
    }

    /// Everything buffered plus the next chunk; nil at end of file.
    func readChunk() throws -> Data? {
        if available == 0 {
            _ = try fill(atLeast: 1)
        }
        guard available > 0 else { return nil }
        let bytes = consume(available)
        return bytes
    }
}
