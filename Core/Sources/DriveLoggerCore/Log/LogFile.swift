import Foundation

// Writing recording files (docs/PLAN.md §3.5 and §4.3). Reading is in
// LogFileReader.swift; the gzip member layout is in Gzip.swift.
//
// File layout: gzip-compressed JSON Lines, written as a sequence of
// independent gzip members, one per flush. Each member is raw DEFLATE from
// `NSData.compressed(using: .zlib)` wrapped in a gzip header carrying the
// member's compressed length in an `FEXTRA` subfield (`DL`, BGZF-style),
// followed by CRC-32 and ISIZE. Concatenated members are a valid gzip stream
// for any standard tool; the length field lets our reader slice members
// without a streaming inflater, and a truncated final member is detected and
// dropped.

/// Builds recording file names: `Drive_<yyyyMMdd-HHmmss>.jsonl.gz`.
public enum LogFileName {
    public static let fileExtension = "jsonl.gz"

    /// File name for a session starting at `start`, rendered in `timeZone`.
    /// Uses the header's wall clock, the only one in a recording.
    ///
    /// Always Gregorian, 24-hour, ASCII digits, whatever the user's locale and
    /// calendar. Seconds are truncated, never rounded up.
    ///
    /// Names have one-second resolution, so two recordings can collide. Pass
    /// `collisionIndex` 2, 3, … to get `Drive_<stamp>_2.jsonl.gz` and so on;
    /// `LogStore` picks the first name that doesn't exist, and
    /// `LogFileWriter` refuses to overwrite in any case. An index of 1 or
    /// less means no suffix.
    public static func make(for start: Date, timeZone: TimeZone, collisionIndex: Int = 1) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        func pad(_ value: Int?, _ width: Int) -> String {
            let digits = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        let stamp = pad(c.year, 4) + pad(c.month, 2) + pad(c.day, 2) + "-"
            + pad(c.hour, 2) + pad(c.minute, 2) + pad(c.second, 2)
        let suffix = collisionIndex > 1 ? "_\(collisionIndex)" : ""
        return "Drive_\(stamp)\(suffix).\(fileExtension)"
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
///
/// `record(_:)` yields to the continuation while holding `lock`, so the
/// counters and the stream can never disagree (an event is counted in
/// `queueDepth` before the writer can take it). The critical section is a
/// counter update and an enqueue — no I/O, no waiting on the writer.
///
/// **Tap (N4 A).** An optional `tap`, fixed when the writer is created, sees
/// every `motion`, `location`, `obd` and `manualFix` event that was accepted
/// into the writer's queue (`isTapped`), right after the enqueue and still
/// under `lock`. So the tap sees exactly the events the writer will take, in
/// exactly the order it takes them: live order is file order. An event the
/// sink refuses (after `finish()`) is never tapped. The tap runs inside the
/// critical section, and sensor callbacks call `record` while holding
/// `SampleGate`'s lock, so it must never block, never wait on anything and
/// never call back into this sink (`NavigationTap.record` is a bounded,
/// non-blocking enqueue). A nil tap changes nothing: same rows, same order,
/// same counters.
public final class LogSink: Sendable {
    /// The single consumer is the owning `LogFileWriter`.
    let events: AsyncStream<LogEvent>
    private let continuation: AsyncStream<LogEvent>.Continuation
    /// Called after each successful enqueue of a tapped kind; see the type's
    /// doc. Immutable after `init`.
    private let tap: (@Sendable (LogEvent) -> Void)?
    private let lock = NSLock()
    /// Guarded by `lock`. Events accepted into the stream.
    private nonisolated(unsafe) var enqueued = 0
    /// Guarded by `lock`. Events the writer has taken and encoded.
    private nonisolated(unsafe) var consumed = 0
    /// Guarded by `lock`. Events refused because the sink had finished.
    private nonisolated(unsafe) var droppedCount = 0
    /// Guarded by `lock`. Set once by `finish()`.
    private nonisolated(unsafe) var isFinished = false
    /// Guarded by `lock`. Highest `enqueued - consumed` since the last
    /// `takePeakQueueDepth()`.
    private nonisolated(unsafe) var peakDepth = 0

    init(tap: (@Sendable (LogEvent) -> Void)? = nil) {
        (events, continuation) = AsyncStream.makeStream(of: LogEvent.self, bufferingPolicy: .unbounded)
        self.tap = tap
    }

    /// Whether `tap` sees events of this kind: the navigation inputs
    /// `motion`, `location`, `obd` and `manualFix`, and nothing else.
    public static func isTapped(_ payload: LogEvent.Payload) -> Bool {
        switch payload {
        case .motion, .location, .obd, .manualFix: true
        default: false
        }
    }

    /// Enqueues an event. Never blocks on I/O or the writer; safe from any
    /// thread. After the writer's `finish()` the event is dropped and
    /// counted in `dropped`. A tapped kind that was enqueued is then handed
    /// to `tap` (see the type's doc).
    public func record(_ event: LogEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else {
            droppedCount += 1
            return
        }
        switch continuation.yield(event) {
        case .enqueued:
            enqueued += 1
            peakDepth = max(peakDepth, enqueued - consumed)
            if let tap, Self.isTapped(event.payload) {
                tap(event)
            }
        case .dropped, .terminated:
            droppedCount += 1
        @unknown default:
            droppedCount += 1
        }
    }

    /// Events enqueued but not yet encoded by the writer.
    public var queueDepth: Int {
        lock.withLock { enqueued - consumed }
    }

    /// Events refused since the sink was created (only after `finish()`).
    public var dropped: Int {
        lock.withLock { droppedCount }
    }

    /// Total events ever accepted. The writer waits until it has taken this
    /// many before a `flush()`, so a flush covers everything recorded before
    /// it was called.
    var totalEnqueued: Int {
        lock.withLock { enqueued }
    }

    /// The highest queue depth since the previous call (or since the sink
    /// was created), measured at every `record`, so a burst that the writer
    /// drained between two samples is still seen. Resets the peak to the
    /// current depth. Used by `LogFileWriter.closeStatsWindow(at:)`.
    func takePeakQueueDepth() -> Int {
        lock.withLock {
            let peak = peakDepth
            peakDepth = enqueued - consumed
            return peak
        }
    }

    /// Called by the writer after encoding each event it took.
    func noteConsumed(_ count: Int = 1) {
        lock.withLock { consumed += count }
    }

    /// Stops accepting events and ends the stream after what is buffered.
    func finish() {
        lock.withLock {
            guard !isFinished else { return }
            isFinished = true
            continuation.finish()
        }
    }
}

/// A failure to persist events. Surfaced, never swallowed.
///
/// Only real failures live here. Low free space is not a failure — the write
/// still succeeds — so it is a separate, advisory `DiskSpaceNotice` on
/// `LogFileWriter.diskSpaceNotices`.
public enum LogWriteError: Error, Hashable, Sendable {
    /// The target already exists. The writer never overwrites a recording.
    case fileExists(path: String)
    case couldNotCreate(path: String, description: String)
    /// A write, `fsync` or close failed for a reason other than `ENOSPC`, or
    /// an `ftruncate` failed for any reason (including `ENOSPC`).
    /// `description` names the operation and the `errno`.
    case writeFailed(description: String)
    /// A `write(2)` failed with `ENOSPC`.
    case diskFull
    /// A member could not be built (compression failed). Individual events
    /// that fail to encode are not failures: see `LogFileWriter`.
    case encodingFailed(kind: String, description: String)
    case alreadyFinished
}

/// What a finished recording looks like on disk.
public struct LogFileSummary: Hashable, Sendable {
    public var url: URL
    /// Events written to complete members.
    public var eventCount: Int
    /// Bytes in complete members, header member included — the file size,
    /// unless writing stopped for good with a partial member at the end.
    public var bytesWritten: Int
    /// Complete members, header member included.
    public var members: Int
    /// Events that were queued but never reached a complete member because
    /// writing failed. Zero on a clean finish. Events recorded after
    /// `finish()` are not here; they are `LogSink.dropped`.
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
/// make every write fail at screen lock and end the recording. If anything
/// fails after the file was created — data protection, the header write — the
/// file is closed and removed before `init` throws, so no headerless file is
/// left for `LogStore` to list (R2-7).
///
/// **File position: one rule, `O_APPEND`.** Every `write(2)` lands at the
/// current end of file, whatever the descriptor's offset; the writer never
/// calls `lseek`. The writer reads the end of file once (`fstat`, in `init`)
/// and from then on tracks it itself: it only ever grows by complete members.
/// Before writing a member that tracked offset is the member's start offset.
///
/// **Members stay whole.** If a member's write fails or is short (e.g.
/// `ENOSPC` after some bytes), the writer `ftruncate`s the file to the
/// recorded start offset and keeps the member's events for the next flush.
/// The retry re-encodes them (plus anything queued since) as one new member,
/// and `O_APPEND` puts it at exactly that offset: no zero-filled gap, no
/// partial member in the middle of the file. Readers slice members by their
/// `FEXTRA` length and would treat everything after a gap or a partial member
/// as damaged. A backlog larger than `maxMemberInputBytes` (8 MiB of JSON) is
/// split into several members at line boundaries, each committed on its own.
///
/// **If `ftruncate` itself fails**, the file may end in a partial member, and
/// the writer must never append after it. It stops writing for good: closes
/// the file (a close error is ignored, the file is already failed), reports
/// `.writeFailed` naming the truncate `errno` on `failures` — always
/// `.writeFailed`, even for `ENOSPC` (R2-3) — and from then on `flush()`
/// throws that same error without touching the file. `finish()` returns a
/// summary with that `failure`, `unwrittenEvents` counting every event not in
/// a complete member (including events still arriving afterwards, which are
/// counted and discarded), and `members`/`eventCount`/`bytesWritten`
/// counting only the complete members before the partial one. A reader sees
/// those members and `truncatedTail == true`.
///
/// **Durability (R2-4).** `flush()` — called on entering background and on
/// memory warnings — and `finish()` `fsync` after writing. Timer flushes do
/// not (the page cache survives an app crash; only a kernel panic or power
/// loss can lose them). An `fsync` failure is a write failure like any other:
/// reported on `failures`, thrown by `flush()`, returned by `finish()`. The
/// members it covered stay in the file and are counted as written — the OS
/// accepted them; whether they reached flash is exactly what is unknown.
///
/// **Low disk space is advisory, and separate from failures.** Free space is
/// read through `diskSpace` once in `init`, after the header is written, and
/// before every flush attempt (timer, `flush()`). Each reading goes through
/// one `DiskSpacePolicy(warningFreeBytes:stopFreeBytes:)` (default hysteresis
/// `LowDiskSpaceMonitor.defaultHysteresisBytes`), and every notice it returns
/// is delivered, in order, on `diskSpaceNotices` — never on `failures`:
/// - `.low` once when free space goes strictly below `warningFreeBytes`;
/// - `.critical` once when it goes strictly below `stopFreeBytes`;
/// - both, `.low` first, when one reading drops below both;
/// - each again only after free space has risen strictly above that
///   threshold plus the hysteresis and dropped below it again.
///
/// The writer only reports; it never acts on a notice. A notice never blocks,
/// delays or fails a write: `flush()` writes and never throws because of free
/// space, and `finish()` always attempts its final write regardless of free
/// space and does not read it. An `init` below either threshold still creates
/// the file and writes the header normally, then delivers its notices; the
/// writer does not refuse to start. A provider that throws is not a write
/// failure: that check is skipped, nothing is reported and the policy's state
/// is unchanged.
///
/// What happens next is `RecordingSession`'s policy, stated once on that
/// type: `.low` writes a `lifecycle` `lowDiskSpace` row and warns in the UI
/// while recording continues; `.critical` writes another `lowDiskSpace` row
/// and stops the recording through the normal stop path (not `failed`), so
/// the final rows are written and the file is closed normally. Start is
/// refused below `warningFreeBytes` before any writer exists.
///
/// **Failures — each reported once (R1-9).** Only real write failures
/// (`ENOSPC`, I/O errors, a failed truncate or `fsync`) appear on
/// `failures`. Nothing queued is discarded while a retry can still succeed.
/// A failure is delivered on `failures` once; an identical failure on a
/// later retry is not delivered again until a write or `fsync` has succeeded
/// in between (then it is a new failure). `flush()` throws on every failed
/// attempt — that is its return value to its caller, **not** a second
/// report: react to `failures`, not to the throw. Failures during `finish()`
/// are never delivered on `failures`; `finish()`'s summary is their report.
/// `RecordingSession` reacts to every delivered failure by writing a
/// `lifecycle` `error` row, calling `finish()` and entering
/// `failed(reason:unwrittenEvents:)`, because the row may not reach a failing
/// disk. Every member written before the failure stays readable.
///
/// **An event that cannot be encoded** (JSON has no NaN or infinity, so a
/// non-finite `Double` from a sensor is the only realistic cause) is not a
/// write failure and does not stop the recording: it is replaced, at the same
/// `t`, by a `lifecycle` row with event `error` and detail
/// `encodingFailed <kind>: <description>`, so the loss is visible in the file.
///
/// **Streams end at `finish()` (R3-2).** Both `failures` and
/// `diskSpaceNotices` are finished before `finish()` returns; a consumer's
/// `for await` loop then ends. `finish()` is idempotent: every call, including
/// concurrent ones, returns the same summary. Always call it: until then the
/// writer's drain task keeps the writer, and its file descriptor, alive.
///
/// **Tests M1 adds** (`LogFileWriterTests.swift`, through the internal
/// `LogFileHandle` seam, with a fault-injecting handle wrapping
/// `POSIXLogFileHandle` and a lock-guarded `Sendable` fault plan the test keeps
/// after handing the handle over — R2-6):
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
/// - With a fake `DiskSpaceProvider`: `init` below `warningFreeBytes` writes
///   the header and delivers `.low` once; a later reading below
///   `stopFreeBytes` delivers `.critical` once; an `init` below both delivers
///   `[.low, .critical]` in that order; later flushes below either threshold
///   still write and don't re-report; `finish()` below the floor writes its
///   final member; `failures` receives nothing throughout.
public actor LogFileWriter {
    /// Largest JSON payload compressed into one member: 8 MiB, about 25 s of
    /// every stream at full rate. Bounds the memory one compression needs
    /// after a long stall.
    static let defaultMaxMemberInputBytes = 8 * 1024 * 1024

    /// Where producers enqueue events.
    public nonisolated let sink: LogSink

    /// Write failures as they happen — `ENOSPC`, I/O errors, a failed
    /// truncate or `fsync`. Never a free-space notice. Each failure once (see
    /// the type's doc). Finishes when `finish()` returns. Single consumer.
    public nonisolated let failures: AsyncStream<LogWriteError>

    /// Advisory free-space notices from `DiskSpacePolicy`, in the order
    /// readings produced them. Never a failure, never a reason the writer
    /// stops writing. Finishes when `finish()` returns. Single consumer.
    public nonisolated let diskSpaceNotices: AsyncStream<DiskSpaceNotice>

    private let failuresContinuation: AsyncStream<LogWriteError>.Continuation
    private let noticesContinuation: AsyncStream<DiskSpaceNotice>.Continuation
    private let url: URL
    private let codec: LogCodec
    private let diskSpace: any DiskSpaceProvider
    private let flushInterval: Duration
    private let maxMemberInputBytes: Int
    private var policy: DiskSpacePolicy

    /// nil once closed (finished, or stopped for good).
    private var handle: (any LogFileHandle)?
    /// Encoded lines not yet in a complete member.
    private var pending = PendingLines()
    /// End of the last complete member: where the next member starts.
    private var fileEnd: Int64
    private var members: Int
    private var eventCount = 0
    /// Events taken from the sink.
    private var consumed = 0
    /// Events counted but discarded because writing stopped for good.
    private var discardedAfterStop = 0
    /// Set when `ftruncate` failed: the writer never touches the file again.
    private var stoppedFailure: LogWriteError?
    /// The failure last delivered on `failures`; cleared by a successful
    /// write or `fsync`.
    private var lastReported: LogWriteError?
    private var finishTask: Task<LogFileSummary, Never>?
    private var timerTask: Task<Void, Never>?
    /// The sink's stream has ended and every event in it was taken.
    private var drained = false
    /// Every event taken for writing, in write order, for `stats` rows.
    private var stats = StatsAccumulator()
    /// `sink.dropped` at the previous `closeStatsWindow`.
    private var droppedAtLastClose = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Creates the file exclusively — throws `LogWriteError.fileExists` rather
    /// than truncate an existing recording — and writes the header as the
    /// first member.
    ///
    /// Free space below either threshold does not stop `init`: the file is
    /// created and the header written, then the notices are delivered on
    /// `diskSpaceNotices`.
    ///
    /// - Parameter warningFreeBytes: free space strictly below this delivers
    ///   `.low`. The default leaves several minutes of recording.
    /// - Parameter stopFreeBytes: free space strictly below this delivers
    ///   `.critical`, leaving room for a clean stop.
    /// - Parameter diskSpace: free-space source; injectable for tests.
    /// - Parameter tap: handed to `sink` (`LogSink`'s doc, "Tap"): sees every
    ///   `motion`, `location`, `obd` and `manualFix` event the sink accepts,
    ///   in write order. Must never block. nil (the default) changes nothing.
    /// - Precondition: `stopFreeBytes < warningFreeBytes` (checked by
    ///   `DiskSpacePolicy.init`).
    public init(
        url: URL,
        header: LogHeader,
        flushInterval: Duration = .seconds(2),
        warningFreeBytes: Int64 = DiskSpacePolicy.defaultWarningFreeBytes,
        stopFreeBytes: Int64 = DiskSpacePolicy.defaultStopFreeBytes,
        diskSpace: any DiskSpaceProvider = VolumeDiskSpaceProvider(),
        tap: (@Sendable (LogEvent) -> Void)? = nil
    ) throws(LogWriteError) {
        let handle = try POSIXLogFileHandle(creatingExclusively: url)
        try self.init(
            handle: handle,
            url: url,
            header: header,
            flushInterval: flushInterval,
            warningFreeBytes: warningFreeBytes,
            stopFreeBytes: stopFreeBytes,
            diskSpace: diskSpace,
            tap: tap
        )
    }

    /// Test seam: writes through `handle`, an already exclusively-created,
    /// empty, append-only file at `url`. The public init opens a
    /// `POSIXLogFileHandle` and behaves exactly like this one from there on,
    /// including removing the file at `url` if the header can't be written.
    ///
    /// The handle is `sending`: after this call only the writer touches it.
    /// Tests that inject faults keep a `Sendable` fault plan instead.
    init(
        handle: sending any LogFileHandle,
        url: URL,
        header: LogHeader,
        flushInterval: Duration = .seconds(2),
        warningFreeBytes: Int64 = DiskSpacePolicy.defaultWarningFreeBytes,
        stopFreeBytes: Int64 = DiskSpacePolicy.defaultStopFreeBytes,
        diskSpace: any DiskSpaceProvider = VolumeDiskSpaceProvider(),
        maxMemberInputBytes: Int = LogFileWriter.defaultMaxMemberInputBytes,
        tap: (@Sendable (LogEvent) -> Void)? = nil
    ) throws(LogWriteError) {
        var policy = DiskSpacePolicy(warningFreeBytes: warningFreeBytes, stopFreeBytes: stopFreeBytes)
        let codec = LogCodec()

        let headerEnd: Int64
        do {
            headerEnd = try Self.writeHeader(header, codec: codec, to: handle, path: url.path)
        } catch {
            try? handle.close()
            _ = unlink(url.path)
            throw error
        }

        let (failures, failuresContinuation) = AsyncStream.makeStream(of: LogWriteError.self)
        let (notices, noticesContinuation) = AsyncStream.makeStream(of: DiskSpaceNotice.self)
        if let available = try? diskSpace.availableBytes(for: url) {
            for notice in policy.observe(availableBytes: available) {
                noticesContinuation.yield(notice)
            }
        }

        self.sink = LogSink(tap: tap)
        self.failures = failures
        self.failuresContinuation = failuresContinuation
        self.diskSpaceNotices = notices
        self.noticesContinuation = noticesContinuation
        self.url = url
        self.codec = codec
        self.diskSpace = diskSpace
        self.flushInterval = flushInterval
        self.maxMemberInputBytes = max(1, maxMemberInputBytes)
        self.policy = policy
        self.handle = handle
        self.fileEnd = headerEnd
        self.members = 1

        Task { await self.run() }
    }

    /// Encodes everything recorded before the call and writes it as one
    /// gzip member (or several, for a large backlog), then `fsync`s. Call on
    /// entering background and on memory warnings. On failure the member is
    /// truncated away and kept for the next attempt. Free space never makes
    /// it throw; notices go to `diskSpaceNotices` only.
    ///
    /// Throws the failure of this attempt; the same failure is delivered on
    /// `failures` at most once (see the type's doc). After writing stopped
    /// for good, throws that failure without touching the file; after
    /// `finish()`, `.alreadyFinished`.
    public func flush() async throws(LogWriteError) {
        try checkWritable()
        await catchUp(to: sink.totalEnqueued)
        try checkWritable()
        checkDiskSpace()
        try writePending(sync: true)
    }

    /// Takes everything recorded before the call, makes a final write attempt
    /// — regardless of free space, without reading it — then `fsync`s and
    /// **always** closes the file, even after a failure, and reports what
    /// didn't make it. Never throws. Idempotent: later and concurrent calls
    /// return the same summary. Ends `failures` and `diskSpaceNotices`.
    /// Events recorded afterwards are dropped and counted in
    /// `LogSink.dropped`.
    public func finish() async -> LogFileSummary {
        if let finishTask {
            return await finishTask.value
        }
        let task = Task { await self.performFinish() }
        finishTask = task
        return await task.value
    }

    /// Compressed bytes in complete members so far, header member included.
    public var bytesWritten: Int {
        Int(fileEnd)
    }

    /// Closes the current `stats` window at `end` and returns the row for it
    /// (`StatsAccumulator`'s definitions). The recorder writes the row into
    /// `sink` itself, every 10 s and once more just before `finish()`.
    ///
    /// The writer is the one place every event passes, in write order, so it
    /// owns the accumulator: everything recorded into `sink` before this call
    /// is taken first (as `flush()` does), then counted in this window.
    /// What only the writer knows is filled in here:
    /// - `queueDepthMax`: the sink's peak queue depth since the previous
    ///   close, measured at every `record` (not sampled), so the backlog that
    ///   builds while a member is compressed and written is seen;
    /// - `dropped`: events the sink refused since the previous close (only
    ///   possible after `finish()`, so 0 in every row of a healthy file);
    /// - `bytesWritten`: compressed bytes in complete members, as
    ///   `bytesWritten`.
    ///
    /// An event that could not be encoded is counted as the `lifecycle` row
    /// that replaced it; events discarded after writing stopped for good are
    /// not counted. Safe after `finish()` (the counts are then final).
    public func closeStatsWindow(at end: MonotonicTimestamp) async -> StatsSample {
        await catchUp(to: sink.totalEnqueued)
        let dropped = sink.dropped
        defer { droppedAtLastClose = dropped }
        return stats.closeWindow(
            at: end,
            queueDepthMax: sink.takePeakQueueDepth(),
            dropped: dropped - droppedAtLastClose,
            bytesWritten: Int(fileEnd)
        )
    }

    // MARK: - Internals

    /// Drains the sink for the writer's lifetime and runs the flush timer.
    private func run() async {
        let interval = flushInterval
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, await self.timerFired() else { return }
            }
        }
        for await event in sink.events {
            accept(event)
        }
        drained = true
        resumeWaiters()
    }

    private func accept(_ event: LogEvent) {
        consumed += 1
        defer {
            sink.noteConsumed()
            resumeWaiters()
        }
        guard stoppedFailure == nil else {
            discardedAfterStop += 1
            return
        }
        do {
            pending.append(try codec.line(for: event))
            stats.observe(event)
        } catch {
            let replacement = LogEvent(
                timestamp: event.timestamp,
                payload: .lifecycle(LifecycleSample(
                    .error,
                    detail: "encodingFailed \(event.payload.kind): \(error)"
                ))
            )
            if let line = try? codec.line(for: replacement) {
                pending.append(line)
                stats.observe(replacement)
            } else {
                // Unreachable in practice: the replacement holds only strings
                // and an integer. Keep the count honest anyway.
                discardedAfterStop += 1
            }
        }
    }

    private func resumeWaiters() {
        guard !waiters.isEmpty else { return }
        var remaining: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if drained || consumed >= waiter.target {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    /// Suspends until `target` events have been taken from the sink, or the
    /// sink's stream has ended.
    private func catchUp(to target: Int) async {
        if drained || consumed >= target { return }
        await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
        }
    }

    private func checkWritable() throws(LogWriteError) {
        if let stoppedFailure { throw stoppedFailure }
        if finishTask != nil || handle == nil { throw .alreadyFinished }
    }

    /// Returns whether the timer should keep running.
    private func timerFired() -> Bool {
        guard finishTask == nil, handle != nil, stoppedFailure == nil else { return false }
        checkDiskSpace()
        // A failure is reported inside writePending; the timer has no caller
        // to throw to.
        try? writePending(sync: false)
        return handle != nil
    }

    private func checkDiskSpace() {
        guard let available = try? diskSpace.availableBytes(for: url) else { return }
        for notice in policy.observe(availableBytes: available) {
            noticesContinuation.yield(notice)
        }
    }

    /// Writes `pending` as complete members. Synchronous: nothing else on the
    /// actor runs in the middle of a member.
    private func writePending(sync: Bool) throws(LogWriteError) {
        guard let handle else { throw stoppedFailure ?? .alreadyFinished }
        // A failure is delivered again only after a write or fsync has
        // succeeded since it was reported: clear `lastReported` right after
        // each success, never at the end of the attempt (which would also
        // erase a failure reported later in the same attempt).

        while let chunk = pending.nextChunk(maxBytes: maxMemberInputBytes) {
            let member: Data
            do {
                member = try GzipMember.make(chunk.data)
            } catch {
                let failure = LogWriteError.encodingFailed(kind: "gzip", description: String(describing: error))
                report(failure)
                throw failure
            }
            do {
                try handle.write(member)
            } catch let writeError {
                // A prefix of the member may be on disk. Cut back to where it
                // started; O_APPEND puts the retry exactly there.
                do {
                    try handle.truncate(to: fileEnd)
                } catch let truncateError {
                    let failure = LogWriteError.writeFailed(
                        description: "\(truncateError.description) truncating to \(fileEnd) after \(writeError.description)"
                    )
                    stopForGood(failure)
                    throw failure
                }
                let failure = writeError.writeError
                report(failure)
                throw failure
            }
            fileEnd += Int64(member.count)
            members += 1
            eventCount += chunk.count
            pending.commit(chunk)
            lastReported = nil
        }

        if sync {
            do {
                try handle.sync()
                lastReported = nil
            } catch {
                let failure = error.writeError
                report(failure)
                throw failure
            }
        }
    }

    private func stopForGood(_ failure: LogWriteError) {
        try? handle?.close()
        handle = nil
        stoppedFailure = failure
        discardedAfterStop += pending.count
        pending = PendingLines()
        report(failure)
    }

    private func report(_ failure: LogWriteError) {
        defer { lastReported = failure }
        // During finish() the summary is the report.
        guard finishTask == nil, failure != lastReported else { return }
        failuresContinuation.yield(failure)
    }

    private func performFinish() async -> LogFileSummary {
        sink.finish()
        await catchUp(to: .max)
        timerTask?.cancel()

        var failure = stoppedFailure
        if handle != nil {
            do {
                try writePending(sync: true)
            } catch {
                failure = error
            }
            if let handle {
                do {
                    try handle.close()
                } catch {
                    if failure == nil { failure = error.writeError }
                }
                self.handle = nil
            }
        }

        let summary = LogFileSummary(
            url: url,
            eventCount: eventCount,
            bytesWritten: Int(fileEnd),
            members: members,
            unwrittenEvents: pending.count + discardedAfterStop,
            failure: failure
        )
        failuresContinuation.finish()
        noticesContinuation.finish()
        return summary
    }

    /// Writes the header member. Returns the end of file after it.
    private static func writeHeader(
        _ header: LogHeader,
        codec: LogCodec,
        to handle: any LogFileHandle,
        path: String
    ) throws(LogWriteError) -> Int64 {
        let start: Int64
        do {
            start = try handle.endOffset()
        } catch {
            throw .couldNotCreate(path: path, description: error.description)
        }
        let line: Data
        do {
            line = try codec.line(for: header)
        } catch {
            throw .encodingFailed(kind: "header", description: String(describing: error))
        }
        let member: Data
        do {
            member = try GzipMember.make(line)
        } catch {
            throw .encodingFailed(kind: "gzip", description: String(describing: error))
        }
        do {
            try handle.write(member)
        } catch {
            throw error.writeError
        }
        return start + Int64(member.count)
    }
}

/// Encoded lines waiting for a member, with their boundaries so a large
/// backlog can be split at line ends.
private struct PendingLines {
    private(set) var data = Data()
    /// End offset in `data` of each line.
    private var lineEnds: [Int] = []

    var count: Int { lineEnds.count }

    mutating func append(_ line: Data) {
        data.append(line)
        lineEnds.append(data.count)
    }

    struct Chunk {
        var data: Data
        var count: Int
    }

    /// The longest prefix of whole lines within `maxBytes` (at least one
    /// line), or nil when empty.
    func nextChunk(maxBytes: Int) -> Chunk? {
        guard let first = lineEnds.first else { return nil }
        if data.count <= maxBytes {
            return Chunk(data: data, count: lineEnds.count)
        }
        var lines = 1
        var end = first
        while lines < lineEnds.count, lineEnds[lines] <= maxBytes {
            end = lineEnds[lines]
            lines += 1
        }
        return Chunk(data: data.prefix(end), count: lines)
    }

    mutating func commit(_ chunk: Chunk) {
        if chunk.count == lineEnds.count {
            self = PendingLines()
            return
        }
        let cut = lineEnds[chunk.count - 1]
        data = Data(data.dropFirst(cut))
        lineEnds = lineEnds.dropFirst(chunk.count).map { $0 - cut }
    }
}

/// A failed operation on the recording file, with the `errno` it returned.
///
/// Mapping to `LogWriteError` (`writeError`): `ENOSPC` from `write` is
/// `.diskFull`; everything else — including any `truncate` failure, whatever
/// its errno (R2-3) — is `.writeFailed` with `description`.
struct LogFileHandleError: Error, Hashable, Sendable, CustomStringConvertible {
    enum Operation: String, Hashable, Sendable {
        case open, write, truncate, sync, close, stat

        /// The system call, as named in error descriptions.
        var call: String {
            switch self {
            case .open: "open"
            case .write: "write"
            case .truncate: "ftruncate"
            case .sync: "fsync"
            case .close: "close"
            case .stat: "fstat"
            }
        }
    }

    var operation: Operation
    var errno: Int32

    var description: String {
        "\(operation.call) failed: errno \(errno) (\(String(cString: strerror(errno))))"
    }

    var writeError: LogWriteError {
        if operation == .write, errno == ENOSPC {
            return .diskFull
        }
        return .writeFailed(description: description)
    }
}

/// Internal seam over the open recording file, so tests can inject short
/// writes, `ENOSPC` and truncate failures. Owned by exactly one
/// `LogFileWriter` and used only on its actor, hence not `Sendable`.
///
/// The file is append-only (`O_APPEND`): `write` always lands at
/// `endOffset()`, and there is deliberately no seek.
protocol LogFileHandle: AnyObject {
    /// Current end of file — where the next `write` lands. The writer calls
    /// it once, before the header.
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
    /// `write(2)`-shaped: returns bytes written, or -1 with the errno.
    typealias WriteSyscall = (_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> (result: Int, errno: Int32)

    /// -1 once closed.
    private var fd: Int32
    private let writeSyscall: WriteSyscall

    /// Opens `url` with `O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC`,
    /// mode `0644`, and applies data protection
    /// `.completeUntilFirstUserAuthentication`. Throws `.fileExists` if
    /// anything is already at `url` (and leaves it alone), `.couldNotCreate`
    /// otherwise (removing the file if it was created).
    ///
    /// - Parameter writeSyscall: test seam for the short-write / `EINTR` loop
    ///   (R2-5); production uses `write(2)`.
    init(
        creatingExclusively url: URL,
        writeSyscall: @escaping WriteSyscall = POSIXLogFileHandle.systemWrite
    ) throws(LogWriteError) {
        let path = url.path
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            let error = errno
            if error == EEXIST {
                throw .fileExists(path: path)
            }
            throw .couldNotCreate(
                path: path,
                description: LogFileHandleError(operation: .open, errno: error).description
            )
        }
        // Exactly 0644 whatever the process umask, as documented.
        _ = fchmod(fd, 0o644)
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: path
            )
        } catch {
            _ = Darwin.close(fd)
            _ = unlink(path)
            throw .couldNotCreate(path: path, description: "data protection: \(error)")
        }
        self.fd = fd
        self.writeSyscall = writeSyscall
    }

    deinit {
        if fd >= 0 {
            _ = Darwin.close(fd)
        }
    }

    static func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> (result: Int, errno: Int32) {
        let result = Darwin.write(fd, buffer, count)
        return (result, result < 0 ? errno : 0)
    }

    private func openDescriptor(for operation: LogFileHandleError.Operation) throws(LogFileHandleError) -> Int32 {
        guard fd >= 0 else { throw LogFileHandleError(operation: operation, errno: EBADF) }
        return fd
    }

    func endOffset() throws(LogFileHandleError) -> Int64 {
        let fd = try openDescriptor(for: .stat)
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw LogFileHandleError(operation: .stat, errno: errno)
        }
        return Int64(info.st_size)
    }

    func write(_ data: Data) throws(LogFileHandleError) {
        let fd = try openDescriptor(for: .write)
        let writeSyscall = self.writeSyscall
        let failure: LogFileHandleError? = data.withUnsafeBytes { raw in
            guard var cursor = raw.baseAddress else { return nil }
            var remaining = raw.count
            while remaining > 0 {
                let (written, error) = writeSyscall(fd, cursor, remaining)
                if written < 0 {
                    if error == EINTR { continue }
                    return LogFileHandleError(operation: .write, errno: error)
                }
                if written == 0 {
                    // Not expected for a regular file; never spin on it.
                    return LogFileHandleError(operation: .write, errno: EIO)
                }
                cursor += written
                remaining -= written
            }
            return nil
        }
        if let failure { throw failure }
    }

    func truncate(to offset: Int64) throws(LogFileHandleError) {
        let fd = try openDescriptor(for: .truncate)
        while ftruncate(fd, off_t(offset)) != 0 {
            let error = errno
            if error != EINTR {
                throw LogFileHandleError(operation: .truncate, errno: error)
            }
        }
    }

    func sync() throws(LogFileHandleError) {
        let fd = try openDescriptor(for: .sync)
        while fsync(fd) != 0 {
            let error = errno
            if error != EINTR {
                throw LogFileHandleError(operation: .sync, errno: error)
            }
        }
    }

    func close() throws(LogFileHandleError) {
        let fd = try openDescriptor(for: .close)
        self.fd = -1
        // Never retried: after EINTR the descriptor's state is unspecified.
        if Darwin.close(fd) != 0 {
            throw LogFileHandleError(operation: .close, errno: errno)
        }
    }
}
