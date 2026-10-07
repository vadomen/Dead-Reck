import Foundation
import Testing

@testable import DriveLoggerCore

/// Faults for `FaultInjectingHandle`, shared between a test and the handle it
/// handed to a `LogFileWriter`.
///
/// `LogFileWriter.init(handle: sending …)` takes the handle into the writer's
/// region, so a test can't touch the handle afterwards (R2-6). The plan is the
/// part the test keeps: a `Sendable` class whose mutable state is guarded by
/// `lock` (the project's NSLock convention, PLAN §4.0), so faults can be armed
/// at any point, before or after hand-over.
final class FaultPlan: Sendable {
    private let lock = NSLock()
    /// Guarded by `lock`. Write faults, in order: successful writes to let
    /// pass first, bytes to let through before the error, and the errno.
    private nonisolated(unsafe) var writeFaults: [(skip: Int, bytes: Int, errno: Int32)] = []
    /// Guarded by `lock`. errnos for the next truncate calls, in order.
    private nonisolated(unsafe) var truncateFaults: [Int32] = []
    /// Guarded by `lock`. errnos for the next sync calls, in order.
    private nonisolated(unsafe) var syncFaults: [Int32] = []
    /// Guarded by `lock`. Every handle call, for asserting what the writer did.
    private nonisolated(unsafe) var calls: [String] = []

    func failNextWrite(afterBytes bytes: Int, errno: Int32) {
        failWrite(afterSuccessfulWrites: 0, afterBytes: bytes, errno: errno)
    }

    /// Lets `skip` writes succeed, then fails the next one.
    func failWrite(afterSuccessfulWrites skip: Int, afterBytes bytes: Int, errno: Int32) {
        lock.withLock { writeFaults.append((skip, bytes, errno)) }
    }

    func failNextTruncate(errno: Int32) {
        lock.withLock { truncateFaults.append(errno) }
    }

    func failNextSync(errno: Int32) {
        lock.withLock { syncFaults.append(errno) }
    }

    var log: [String] { lock.withLock { calls } }

    func takeWriteFault() -> (bytes: Int, errno: Int32)? {
        lock.withLock {
            guard !writeFaults.isEmpty else { return nil }
            if writeFaults[0].skip > 0 {
                writeFaults[0].skip -= 1
                return nil
            }
            let fault = writeFaults.removeFirst()
            return (fault.bytes, fault.errno)
        }
    }

    func takeTruncateFault() -> Int32? {
        lock.withLock { truncateFaults.isEmpty ? nil : truncateFaults.removeFirst() }
    }

    func takeSyncFault() -> Int32? {
        lock.withLock { syncFaults.isEmpty ? nil : syncFaults.removeFirst() }
    }

    func note(_ call: String) {
        lock.withLock { calls.append(call) }
    }
}

/// Wraps the real `POSIXLogFileHandle` and injects faults from a `FaultPlan`:
/// a failing write can let a prefix through first, exactly like `write(2)`
/// returning short and then `ENOSPC`.
final class FaultInjectingHandle: LogFileHandle {
    let inner: POSIXLogFileHandle
    let plan: FaultPlan

    init(url: URL, plan: FaultPlan) throws {
        inner = try POSIXLogFileHandle(creatingExclusively: url)
        self.plan = plan
    }

    func endOffset() throws(LogFileHandleError) -> Int64 {
        plan.note("endOffset")
        return try inner.endOffset()
    }

    func write(_ data: Data) throws(LogFileHandleError) {
        if let fault = plan.takeWriteFault() {
            plan.note("write \(data.count) fail after \(fault.bytes) errno \(fault.errno)")
            if fault.bytes > 0 {
                try inner.write(data.prefix(fault.bytes))
            }
            throw LogFileHandleError(operation: .write, errno: fault.errno)
        }
        plan.note("write \(data.count)")
        try inner.write(data)
    }

    func truncate(to offset: Int64) throws(LogFileHandleError) {
        if let errno = plan.takeTruncateFault() {
            plan.note("truncate \(offset) fail errno \(errno)")
            throw LogFileHandleError(operation: .truncate, errno: errno)
        }
        plan.note("truncate \(offset)")
        try inner.truncate(to: offset)
    }

    func sync() throws(LogFileHandleError) {
        if let errno = plan.takeSyncFault() {
            plan.note("sync fail errno \(errno)")
            throw LogFileHandleError(operation: .sync, errno: errno)
        }
        plan.note("sync")
        try inner.sync()
    }

    func close() throws(LogFileHandleError) {
        plan.note("close")
        try inner.close()
    }
}

/// A `DiskSpaceProvider` whose reading the test sets, counting every query.
final class FakeDiskSpace: DiskSpaceProvider {
    struct Unreadable: Error {}

    private let lock = NSLock()
    /// Guarded by `lock`. nil = throw.
    private nonisolated(unsafe) var bytes: Int64?
    /// Guarded by `lock`.
    private nonisolated(unsafe) var queries = 0

    init(_ bytes: Int64?) {
        self.bytes = bytes
    }

    func set(_ value: Int64?) {
        lock.withLock { bytes = value }
    }

    var queryCount: Int { lock.withLock { queries } }

    func availableBytes(for url: URL) throws -> Int64 {
        let value = lock.withLock { () -> Int64? in
            queries += 1
            return bytes
        }
        guard let value else { throw Unreadable() }
        return value
    }
}

enum WriterFixtures {
    static let header = LogHeader(
        sessionID: LogFixtures.sessionID,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        referenceUptimeSeconds: 1_234.5,
        app: LogFixtures.app,
        device: LogFixtures.device,
        notes: "writer test",
        timeZone: "Europe/Kyiv"
    )

    /// Plenty of free space: no notices.
    static let roomy: Int64 = 10_000_000_000

    /// Distinct, ordered events of a few kinds.
    static func events(_ range: Range<Int>) -> [LogEvent] {
        range.map { index in
            let t = MonotonicTimestamp(nanoseconds: Int64(index) * 10_000_000)
            switch index % 3 {
            case 0:
                return LogEvent(timestamp: t, payload: .accelerometer(Vector3(x: Double(index), y: 0.5, z: -1)))
            case 1:
                return LogEvent(timestamp: t, payload: .gyroscope(Vector3(x: 0.01, y: Double(index), z: 0)))
            default:
                return .marker("event \(index)", at: t)
            }
        }
    }

    static func writer(
        in scratch: ScratchDirectory,
        name: String = "drive.jsonl.gz",
        plan: FaultPlan = FaultPlan(),
        diskSpace: any DiskSpaceProvider = FakeDiskSpace(roomy),
        flushInterval: Duration = .seconds(3_600),
        warningFreeBytes: Int64 = DiskSpacePolicy.defaultWarningFreeBytes,
        stopFreeBytes: Int64 = DiskSpacePolicy.defaultStopFreeBytes,
        maxMemberInputBytes: Int = LogFileWriter.defaultMaxMemberInputBytes
    ) throws -> LogFileWriter {
        let url = scratch.file(name)
        let handle = try FaultInjectingHandle(url: url, plan: plan)
        return try LogFileWriter(
            handle: handle,
            url: url,
            header: header,
            flushInterval: flushInterval,
            warningFreeBytes: warningFreeBytes,
            stopFreeBytes: stopFreeBytes,
            diskSpace: diskSpace,
            maxMemberInputBytes: maxMemberInputBytes
        )
    }

    /// Reads a whole file with `LogFileReader`.
    static func read(
        _ url: URL,
        recovery: LogRecovery = .skipMalformedLines
    ) throws -> (header: LogHeader, events: [LogEvent], report: LogReadReport) {
        let reader = try LogFileReader(url: url, recovery: recovery)
        let events = Array(reader)
        return (reader.header, events, reader.report)
    }

    /// Byte offsets where each gzip member starts, walking the `DL` lengths.
    /// Returns the offsets and where the walk stopped.
    static func memberOffsets(_ bytes: Data) -> (starts: [Int], end: Int) {
        var starts: [Int] = []
        var offset = 0
        while offset < bytes.count {
            guard case .complete(let header) = GzipMember.parseHeader(bytes[(bytes.startIndex + offset)...]),
                  offset + header.totalLength <= bytes.count
            else { break }
            starts.append(offset)
            offset += header.totalLength
        }
        return (starts, offset)
    }

    static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? -1
    }

    static func collect<T>(_ stream: AsyncStream<T>) async -> [T] {
        var values: [T] = []
        for await value in stream {
            values.append(value)
        }
        return values
    }
}
