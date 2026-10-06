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
    ///
    /// Names have one-second resolution, so two recordings can collide. Pass
    /// `collisionIndex` 2, 3, … to get `Drive_<stamp>_2.jsonl.gz` and so on;
    /// `LogStore` picks the first name that doesn't exist, and
    /// `LogFileWriter` refuses to overwrite in any case.
    public static func make(for start: Date, timeZone: TimeZone, collisionIndex: Int = 1) -> String {
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
///
/// Concurrency pattern (the one every Sendable class in this project with
/// mutable state uses; `Mutex` and atomics need iOS 18, Core may only import
/// Foundation): the event queue is an `AsyncStream.Continuation`, which is
/// already thread-safe; counters are `private nonisolated(unsafe) var`
/// guarded by one `NSLock`, with a comment at the declaration naming the
/// lock. No `@unchecked Sendable` on the type.
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
    /// The target already exists. The writer never overwrites a recording.
    case fileExists(path: String)
    case couldNotCreate(path: String, description: String)
    /// A write, truncate or close failed for a reason other than `ENOSPC`.
    /// `description` names the operation and the `errno`.
    case writeFailed(description: String)
    /// A write failed with `ENOSPC`.
    case diskFull
    /// Free space fell below `minimumFreeBytes`. **Advisory only**: it never
    /// blocks, delays or fails a write, `init` and `flush()` never throw it,
    /// and it is delivered only on `LogFileWriter.failures`. Reported *before*
    /// the disk is full, so the recording can still be stopped cleanly with
    /// its final rows written. Reported once per crossing, under the rule
    /// implemented by `LowDiskSpaceMonitor`; `availableBytes` is the reading
    /// that crossed.
    case lowDiskSpace(availableBytes: Int64)
    case encodingFailed(kind: String, description: String)
    case alreadyFinished
}

/// What a finished recording looks like on disk.
public struct LogFileSummary: Hashable, Sendable {
    public var url: URL
    /// Events written to complete members.
    public var eventCount: Int
    public var bytesWritten: Int
    public var members: Int
    /// Events that were queued but never reached the file because writing
    /// failed. Zero on a clean finish.
    public var unwrittenEvents: Int
    /// The failure that stopped writing, if any. The file is closed either way.
    public var failure: LogWriteError?

    public init(
        url: URL,
        eventCount: Int,
        bytesWritten: Int,
        members: Int,
        unwrittenEvents: Int = 0,
        failure: LogWriteError? = nil
    ) {
        self.url = url
        self.eventCount = eventCount
        self.bytesWritten = bytesWritten
        self.members = members
        self.unwrittenEvents = unwrittenEvents
        self.failure = failure
    }
}

/// Writes one recording file. Owns the file handle and the recording's only
/// `LogCodec`.
///
/// Writes the header immediately and flushes a gzip member at least every
/// `flushInterval`, on `flush()` and on `finish()`. A crash loses at most the
/// unflushed buffer.
///
/// **File creation.** Exclusive, append-only: `open(2)` with
/// `O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC` (not
/// `FileManager.createFile`, which overwrites), with data protection
/// `.completeUntilFirstUserAuthentication` applied before the header is
/// written. Recording continues with the screen locked; `.complete` would
/// make every write fail at screen lock and end the recording.
///
/// **File position: one rule, `O_APPEND`.** Every `write(2)` lands at the
/// current end of file, whatever the descriptor's offset; the writer never
/// calls `lseek`. Before writing a member the writer records its start
/// offset, the current end of file (`LogFileHandle.endOffset()`).
///
/// **Members stay whole.** If a member's write fails or is short (e.g.
/// `ENOSPC` after some bytes), the writer `ftruncate`s the file to the
/// recorded start offset and keeps the member's events for the next flush.
/// The retry re-encodes them (plus anything queued since) as one new member,
/// and `O_APPEND` puts it at exactly that offset: no zero-filled gap, no
/// partial member in the middle of the file. Readers slice members by their
/// `FEXTRA` length and would treat everything after a gap or a partial member
/// as damaged.
///
/// **If `ftruncate` itself fails**, the file may end in a partial member, and
/// the writer must never append after it. It stops writing for good: closes
/// the file (a close error is ignored, the file is already failed), reports
/// `.writeFailed` naming the truncate `errno` on `failures`, and from then on
/// `flush()` throws that same error without touching the file. `finish()`
/// returns a summary with that `failure`, `unwrittenEvents` counting every
/// event not in a complete member, and `members`/`eventCount` counting only
/// the complete members before the partial one. A reader sees those members
/// and `truncatedTail == true`.
///
/// **Low disk space is advisory.** Free space is read through `diskSpace` once
/// in `init`, after the header is written, and before every flush attempt
/// (timer, `flush()`); each reading goes through a `LowDiskSpaceMonitor`
/// (`minimumFreeBytes`, default hysteresis of
/// `LowDiskSpaceMonitor.defaultHysteresisBytes`). A reading strictly below
/// `minimumFreeBytes` reports `.lowDiskSpace` on `failures` once; it is
/// reported again only after free space has risen strictly above
/// `minimumFreeBytes` plus the hysteresis and then dropped below the
/// threshold again, so a payload that changes every flush is not re-reported
/// every flush. The report never blocks, delays or fails a write: `flush()`
/// writes and never throws `.lowDiskSpace`, and `finish()` always attempts
/// its final write regardless of free space and does not consult the
/// monitor. An `init` below the threshold still creates the file and writes
/// the header normally, then reports `.lowDiskSpace` on `failures`; it does
/// not refuse to start — `RecordingSession` decides. A provider that throws
/// is not a write failure: that check is skipped, nothing is reported and the
/// monitor's state is unchanged.
///
/// **Failures.** Nothing queued is discarded while a retry can still succeed.
/// Each distinct write failure is reported once on `failures` (again only if
/// it changes or clears); `.lowDiskSpace` follows the monitor's rule above
/// instead. `RecordingSession` reacts to any failure by writing a `lifecycle`
/// `error` row, calling `finish()`, and showing the failure in its own state,
/// because the row may not reach a failing disk. Every member written before
/// the failure stays readable.
///
/// **Tests M1 must add** (through the internal `LogFileHandle` seam, with a
/// fault-injecting handle wrapping `POSIXLogFileHandle`):
/// - Short write and `ENOSPC` on member N (both "some bytes then error" and
///   "zero bytes then error"), then a successful retry: the file passes
///   `gzip -t`, every member decodes with `truncatedTail == false`, every
///   event appears exactly once in order, and each member begins (gzip magic
///   `1f 8b`) at the byte where the previous one ended, with the last ending
///   at end of file — no zero bytes between members.
/// - Partial write of member N, then `ftruncate` fails: the file size never
///   grows after the failure (no member appended after the partial one),
///   later `flush()` calls throw `.writeFailed`, `failures` delivers it once,
///   `finish()` reports it with the right `unwrittenEvents`, and a reader
///   returns members 0..<N with `truncatedTail == true`.
/// - With a fake `DiskSpaceProvider`: `init` below the threshold writes the
///   header and reports `.lowDiskSpace` once; later flushes below the
///   threshold still write and don't re-report; `finish()` below the
///   threshold writes its final member.
public actor LogFileWriter {
    /// Where producers enqueue events.
    public nonisolated let sink: LogSink

    /// Write failures as they happen. Single consumer.
    public nonisolated let failures: AsyncStream<LogWriteError>

    /// Creates the file exclusively — throws `LogWriteError.fileExists` rather
    /// than truncate an existing recording — and writes the header as the
    /// first member.
    ///
    /// Free space below this does not stop `init`: the file is created and
    /// the header written, then `.lowDiskSpace` is reported on `failures`.
    ///
    /// - Parameter minimumFreeBytes: free-space floor that triggers
    ///   `.lowDiskSpace`. The default leaves several minutes of recording.
    /// - Parameter diskSpace: free-space source; injectable for tests.
    public init(
        url: URL,
        header: LogHeader,
        flushInterval: Duration = .seconds(2),
        minimumFreeBytes: Int64 = 200_000_000,
        diskSpace: any DiskSpaceProvider = VolumeDiskSpaceProvider()
    ) throws(LogWriteError) {
        fatalError("M1: LogFileWriter.init")
    }

    /// Test seam: writes through `handle`, an already exclusively-created,
    /// empty, append-only file at `url`. The public init opens a
    /// `POSIXLogFileHandle` and behaves exactly like this one from there on.
    init(
        handle: sending any LogFileHandle,
        url: URL,
        header: LogHeader,
        flushInterval: Duration = .seconds(2),
        minimumFreeBytes: Int64 = 200_000_000,
        diskSpace: any DiskSpaceProvider = VolumeDiskSpaceProvider()
    ) throws(LogWriteError) {
        fatalError("M1: LogFileWriter.init(handle:)")
    }

    /// Encodes and writes everything queued so far as one gzip member. Call on
    /// entering background and on memory warnings. On failure the member is
    /// truncated away and kept for the next attempt. Never throws
    /// `.lowDiskSpace`; that goes to `failures` only.
    public func flush() async throws(LogWriteError) {
        fatalError("M1: LogFileWriter.flush")
    }

    /// Final flush attempt — made regardless of free space — then **always**
    /// closes the file, even after a failure, and reports what didn't make it.
    /// Never throws. Events recorded afterwards are dropped and counted in
    /// `LogSink.dropped`.
    public func finish() async -> LogFileSummary {
        fatalError("M1: LogFileWriter.finish")
    }

    /// Compressed bytes on disk so far.
    public var bytesWritten: Int {
        fatalError("M1: LogFileWriter.bytesWritten")
    }
}

/// A failed operation on the recording file, with the `errno` it returned.
/// `ENOSPC` maps to `LogWriteError.diskFull`, anything else to
/// `.writeFailed`.
struct LogFileHandleError: Error, Hashable, Sendable {
    enum Operation: String, Hashable, Sendable {
        case open, write, truncate, sync, close, stat
    }

    var operation: Operation
    var errno: Int32
}

/// Internal seam over the open recording file, so tests can inject short
/// writes, `ENOSPC` and truncate failures. Owned by exactly one
/// `LogFileWriter` and used only on its actor, hence not `Sendable`.
///
/// The file is append-only (`O_APPEND`): `write` always lands at
/// `endOffset()`, and there is deliberately no seek.
protocol LogFileHandle: AnyObject {
    /// Current end of file — where the next `write` lands.
    func endOffset() throws(LogFileHandleError) -> Int64

    /// Writes all of `data`, retrying short writes and `EINTR` internally.
    /// On error a prefix of `data` may already be on disk; the caller
    /// truncates it away.
    func write(_ data: Data) throws(LogFileHandleError)

    /// `ftruncate` to `offset`. Does not move anything else: with `O_APPEND`
    /// the next `write` lands at the new end of file.
    func truncate(to offset: Int64) throws(LogFileHandleError)

    /// `fsync`.
    func sync() throws(LogFileHandleError)

    /// Closes the descriptor. Further calls throw.
    func close() throws(LogFileHandleError)
}

/// The production `LogFileHandle`: a raw descriptor from `open(2)`.
final class POSIXLogFileHandle: LogFileHandle {
    /// Opens `url` with `O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC`,
    /// mode `0644`, and applies data protection
    /// `.completeUntilFirstUserAuthentication`. Throws `.fileExists` if
    /// anything is already at `url`, `.couldNotCreate` otherwise.
    init(creatingExclusively url: URL) throws(LogWriteError) {
        fatalError("M1: POSIXLogFileHandle.init")
    }

    func endOffset() throws(LogFileHandleError) -> Int64 {
        fatalError("M1: POSIXLogFileHandle.endOffset")
    }

    func write(_ data: Data) throws(LogFileHandleError) {
        fatalError("M1: POSIXLogFileHandle.write")
    }

    func truncate(to offset: Int64) throws(LogFileHandleError) {
        fatalError("M1: POSIXLogFileHandle.truncate")
    }

    func sync() throws(LogFileHandleError) {
        fatalError("M1: POSIXLogFileHandle.sync")
    }

    func close() throws(LogFileHandleError) {
        fatalError("M1: POSIXLogFileHandle.close")
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
