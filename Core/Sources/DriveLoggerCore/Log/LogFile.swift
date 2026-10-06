import Foundation

// Contracts for writing and reading recording files. Stubs: implemented in M1
// by the log layer (see docs/PLAN.md §3.5 and §4.3).
//
// File layout: gzip-compressed JSON Lines, written as a sequence of
// independent gzip members, one per flush. Each member is raw DEFLATE from
// `NSData.compressed(using: .zlib)` wrapped in a gzip header carrying the
// member's compressed length in an `FEXTRA` subfield (as BGZF does), followed
// by CRC-32 and ISIZE. Concatenated members are a valid gzip stream for any
// standard tool; the length field lets our reader slice members without a
// streaming inflater, and a truncated final member is detected and dropped.

/// Builds recording file names: `Drive_<yyyyMMdd-HHmmss>.jsonl.gz`.
public enum LogFileName {
    public static let fileExtension = "jsonl.gz"

    /// File name for a session starting at `start`, rendered in `timeZone`.
    /// Uses the header's wall clock, the only one in a recording.
    public static func make(for start: Date, timeZone: TimeZone) -> String {
        fatalError("M1: LogFileName.make")
    }
}

/// The non-blocking front door through which every sensor and the OBD link
/// hand events to the writer.
///
/// `record(_:)` is called from sensor callbacks at several hundred events per
/// second and must never block or hop to an actor. The queue behind it is
/// unbounded on purpose — dropping is data loss — and its depth is reported in
/// every `stats` row.
public final class LogSink: Sendable {
    init() {}

    /// Enqueues an event. Never blocks; safe from any thread.
    public func record(_ event: LogEvent) {
        fatalError("M1: LogSink.record")
    }

    /// Events enqueued but not yet encoded.
    public var queueDepth: Int {
        fatalError("M1: LogSink.queueDepth")
    }

    /// Events refused since the sink was created (only after `finish()`).
    public var dropped: Int {
        fatalError("M1: LogSink.dropped")
    }
}

/// A failure to persist events. Surfaced, never swallowed.
public enum LogWriteError: Error, Hashable, Sendable {
    case couldNotCreate(path: String, description: String)
    case writeFailed(description: String)
    case diskFull
    case encodingFailed(kind: String, description: String)
    case alreadyFinished
}

/// What a finished recording looks like on disk.
public struct LogFileSummary: Hashable, Sendable {
    public var url: URL
    public var eventCount: Int
    public var bytesWritten: Int
    public var members: Int

    public init(url: URL, eventCount: Int, bytesWritten: Int, members: Int) {
        self.url = url
        self.eventCount = eventCount
        self.bytesWritten = bytesWritten
        self.members = members
    }
}

/// Writes one recording file. Owns the file handle and the recording's only
/// `LogCodec`.
///
/// Writes the header immediately and flushes a gzip member at least every
/// `flushInterval`, on `flush()` and on `finish()`. A crash loses at most the
/// unflushed buffer.
public actor LogFileWriter {
    /// Where producers enqueue events.
    public nonisolated let sink: LogSink

    /// Write failures as they happen. Single consumer.
    public nonisolated let failures: AsyncStream<LogWriteError>

    /// Creates the file and writes the header as the first member.
    public init(url: URL, header: LogHeader, flushInterval: Duration = .seconds(2)) throws {
        fatalError("M1: LogFileWriter.init")
    }

    /// Encodes and writes everything queued so far as one gzip member. Call on
    /// entering background and on memory warnings.
    public func flush() async throws {
        fatalError("M1: LogFileWriter.flush")
    }

    /// Final flush, close the file. Events recorded afterwards are dropped and
    /// counted.
    public func finish() async throws -> LogFileSummary {
        fatalError("M1: LogFileWriter.finish")
    }

    /// Compressed bytes on disk so far.
    public var bytesWritten: Int {
        fatalError("M1: LogFileWriter.bytesWritten")
    }
}

/// What a read found besides events.
public struct LogReadReport: Hashable, Sendable {
    /// Complete gzip members decoded.
    public var members: Int
    /// The file ended inside a gzip member, which was dropped.
    public var truncatedTail: Bool
    /// Zero-based line indices skipped under `LogRecovery.skipMalformedLines`.
    public var skippedLineIndices: [Int]

    public init(members: Int, truncatedTail: Bool, skippedLineIndices: [Int]) {
        self.members = members
        self.truncatedTail = truncatedTail
        self.skippedLineIndices = skippedLineIndices
    }
}

/// Streams a recording member by member without loading it whole.
///
/// Accepts both `.jsonl.gz` files written by `LogFileWriter` and plain
/// `.jsonl`. Tolerates a truncated gzip tail and a half-written last line.
/// Not `Sendable`: owns a `LogCodec`.
public final class LogFileReader: Sequence {
    public let header: LogHeader

    public init(url: URL, recovery: LogRecovery = .skipMalformedLines) throws {
        fatalError("M1: LogFileReader.init")
    }

    /// Valid once iteration has finished.
    public var report: LogReadReport {
        fatalError("M1: LogFileReader.report")
    }

    public func makeIterator() -> Iterator {
        fatalError("M1: LogFileReader.makeIterator")
    }

    public struct Iterator: IteratorProtocol {
        public mutating func next() -> LogEvent? {
            fatalError("M1: LogFileReader.Iterator.next")
        }
    }
}
