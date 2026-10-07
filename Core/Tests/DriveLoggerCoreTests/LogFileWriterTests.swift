import Foundation
import Testing

@testable import DriveLoggerCore

@Suite("LogFileWriter")
struct LogFileWriterTests {
    @Test("Header, events and flushes round-trip through the reader in order")
    func roundTrip() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = try WriterFixtures.writer(in: scratch)
        let events = WriterFixtures.events(0..<300)

        for event in events[0..<100] { writer.sink.record(event) }
        try await writer.flush()
        for event in events[100..<300] { writer.sink.record(event) }
        try await writer.flush()
        let summary = await writer.finish()

        #expect(summary.failure == nil)
        #expect(summary.unwrittenEvents == 0)
        #expect(summary.eventCount == 300)
        #expect(summary.members == 3)  // header + two flushes
        #expect(summary.bytesWritten == WriterFixtures.fileSize(summary.url))

        let read = try WriterFixtures.read(summary.url)
        #expect(read.header == WriterFixtures.header)
        #expect(read.events == events)
        #expect(read.report.members == 3)
        #expect(!read.report.truncatedTail)
        #expect(read.report.skippedLineIndices.isEmpty)
    }

    @Test("The header is on disk as soon as init returns")
    func headerFirst() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = try WriterFixtures.writer(in: scratch)
        let url = scratch.file("drive.jsonl.gz")

        let read = try WriterFixtures.read(url)
        #expect(read.header == WriterFixtures.header)
        #expect(read.events.isEmpty)
        #expect(read.report.members == 1)
        _ = await writer.finish()
    }

    #if os(macOS)
    @Test("The file passes gzip -t and gunzips to header + event lines")
    func systemGzipReadsRecording() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = try WriterFixtures.writer(in: scratch)
        let events = WriterFixtures.events(0..<50)
        for event in events { writer.sink.record(event) }
        try await writer.flush()
        let summary = await writer.finish()

        #expect(try SystemGzip.test(summary.url).status == 0)
        let output = try SystemGzip.decompress(summary.url)
        let codec = LogCodec()
        var expected = try codec.line(for: WriterFixtures.header)
        for event in events { expected.append(try codec.line(for: event)) }
        #expect(output.stdout == expected)
    }
    #endif

    @Test("The flush timer writes without an explicit flush")
    func timerFlushes() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = try WriterFixtures.writer(in: scratch, flushInterval: .milliseconds(50))
        let url = scratch.file("drive.jsonl.gz")
        let afterHeader = WriterFixtures.fileSize(url)

        for event in WriterFixtures.events(0..<20) { writer.sink.record(event) }
        var grew = false
        for _ in 0..<100 where !grew {
            try await Task.sleep(for: .milliseconds(20))
            grew = WriterFixtures.fileSize(url) > afterHeader
        }
        #expect(grew)
        let read = try WriterFixtures.read(url)
        #expect(read.events == WriterFixtures.events(0..<20))
        _ = await writer.finish()
    }

    @Test("An existing file is never overwritten")
    func refusesExistingFile() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("drive.jsonl.gz")
        try Data("precious".utf8).write(to: url)

        #expect(throws: LogWriteError.fileExists(path: url.path)) {
            _ = try LogFileWriter(url: url, header: WriterFixtures.header, diskSpace: FakeDiskSpace(WriterFixtures.roomy))
        }
        #expect(try Data(contentsOf: url) == Data("precious".utf8))
    }

    @Test("The public init creates the file and writes through POSIX")
    func publicInit() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("drive.jsonl.gz")
        let writer = try LogFileWriter(url: url, header: WriterFixtures.header, diskSpace: FakeDiskSpace(WriterFixtures.roomy))
        writer.sink.record(.marker("hello", at: .zero))
        let summary = await writer.finish()
        #expect(summary.failure == nil)
        #expect(try WriterFixtures.read(url).events == [.marker("hello", at: .zero)])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
        // Recording must survive screen lock: never `.complete`.
        #expect(attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
    }

    @Test("Init fails cleanly when the directory does not exist")
    func missingDirectory() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-dir-\(UUID().uuidString)/drive.jsonl.gz")
        #expect(throws: LogWriteError.self) {
            _ = try LogFileWriter(url: url, header: WriterFixtures.header, diskSpace: FakeDiskSpace(WriterFixtures.roomy))
        }
    }

    /// R2-7: a failed header write must not leave an unreadable recording.
    @Test("A header write failure removes the file init created")
    func headerFailureUnlinks() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let plan = FaultPlan()
        plan.failNextWrite(afterBytes: 5, errno: ENOSPC)
        #expect(throws: LogWriteError.diskFull) {
            _ = try WriterFixtures.writer(in: scratch, plan: plan)
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.file("drive.jsonl.gz").path))
    }

    @Test("A large backlog is split into several members at line boundaries")
    func splitsLargeMembers() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = try WriterFixtures.writer(in: scratch, maxMemberInputBytes: 1_000)
        let events = WriterFixtures.events(0..<200)
        for event in events { writer.sink.record(event) }
        try await writer.flush()
        let summary = await writer.finish()

        #expect(summary.members > 5)
        let read = try WriterFixtures.read(summary.url)
        #expect(read.events == events)
        #expect(read.report.members == summary.members)
    }

    /// Encoding can only fail on a non-finite Double (JSON has no NaN). One
    /// bad sample must not end a drive, and must not vanish silently.
    @Test("An unencodable event is replaced by a lifecycle error row, not a failure")
    func encodingFailureBecomesRow() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = try WriterFixtures.writer(in: scratch)
        let t = MonotonicTimestamp(nanoseconds: 42)
        writer.sink.record(LogEvent(timestamp: t, payload: .accelerometer(Vector3(x: .nan, y: 0, z: 0))))
        writer.sink.record(.marker("after", at: t))
        try await writer.flush()
        let summary = await writer.finish()
        let failures = await WriterFixtures.collect(writer.failures)

        #expect(failures.isEmpty)
        #expect(summary.failure == nil)
        let read = try WriterFixtures.read(summary.url)
        #expect(read.events.count == 2)
        guard case .lifecycle(let row) = read.events.first?.payload else {
            Issue.record("expected a lifecycle row, got \(String(describing: read.events.first))")
            return
        }
        #expect(read.events.first?.timestamp == t)
        #expect(row.event == "error")
        #expect(row.detail?.hasPrefix("encodingFailed accel:") == true)
        #expect(read.events.last == .marker("after", at: t))
    }
}

@Suite("LogFileWriter failures")
struct LogFileWriterFailureTests {
    /// Contract test 1 (LogFile.swift): a short write / ENOSPC on member N,
    /// then a successful retry.
    @Test("ENOSPC mid-member, then a retry: whole members, contiguous, every event once in order",
          arguments: [0, 1, 17])
    func shortWriteThenRetry(bytesBeforeError: Int) async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let plan = FaultPlan()
        let writer = try WriterFixtures.writer(in: scratch, plan: plan)
        let events = WriterFixtures.events(0..<90)

        for event in events[0..<30] { writer.sink.record(event) }
        try await writer.flush()                                  // member 1

        plan.failNextWrite(afterBytes: bytesBeforeError, errno: ENOSPC)
        for event in events[30..<60] { writer.sink.record(event) }
        await #expect(throws: LogWriteError.diskFull) {
            try await writer.flush()                              // member 2 fails
        }
        let sizeAfterFailure = WriterFixtures.fileSize(scratch.file("drive.jsonl.gz"))
        #expect(sizeAfterFailure == (await writer.bytesWritten))   // truncated back

        for event in events[60..<90] { writer.sink.record(event) }
        try await writer.flush()                                  // retry: 30..<90 in one member
        let summary = await writer.finish()
        let failures = await WriterFixtures.collect(writer.failures)

        #expect(summary.failure == nil)
        #expect(summary.unwrittenEvents == 0)
        #expect(summary.eventCount == 90)
        #expect(failures == [.diskFull])
        #expect(plan.log.contains { $0.hasPrefix("truncate") })

        let bytes = try Data(contentsOf: summary.url)
        let walk = WriterFixtures.memberOffsets(bytes)
        #expect(walk.end == bytes.count, "members must tile the file, no gap or partial member")
        #expect(walk.starts.count == summary.members)
        for start in walk.starts {
            #expect(bytes[start] == 0x1F && bytes[start + 1] == 0x8B)
        }

        let read = try WriterFixtures.read(summary.url)
        #expect(read.events == events)
        #expect(!read.report.truncatedTail)
        #expect(read.report.damagedMemberIndices.isEmpty)
        #if os(macOS)
        #expect(try SystemGzip.test(summary.url).status == 0)
        #endif
    }

    /// Contract test 2: partial write of member N, then ftruncate fails.
    @Test("Partial write + failing ftruncate: stop for good, reported once, reader sees members 0..<N")
    func truncateFailureStopsForGood() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let plan = FaultPlan()
        let writer = try WriterFixtures.writer(in: scratch, plan: plan)
        let url = scratch.file("drive.jsonl.gz")
        let events = WriterFixtures.events(0..<100)

        for event in events[0..<40] { writer.sink.record(event) }
        try await writer.flush()                                  // members 0 (header), 1
        let completeBytes = await writer.bytesWritten

        plan.failNextWrite(afterBytes: 25, errno: EIO)
        plan.failNextTruncate(errno: EROFS)
        for event in events[40..<70] { writer.sink.record(event) }
        var firstError: LogWriteError?
        do {
            try await writer.flush()
        } catch {
            firstError = error
        }
        guard case .writeFailed(let description) = firstError else {
            Issue.record("expected .writeFailed, got \(String(describing: firstError))")
            return
        }
        #expect(description.contains("ftruncate"))
        let sizeAfterFailure = WriterFixtures.fileSize(url)
        #expect(sizeAfterFailure == completeBytes + 25)           // the partial member stays

        for event in events[70..<100] { writer.sink.record(event) }
        await #expect(throws: firstError!) {
            try await writer.flush()                              // never touches the file
        }
        let summary = await writer.finish()
        let failures = await WriterFixtures.collect(writer.failures)

        #expect(WriterFixtures.fileSize(url) == sizeAfterFailure)  // never grew again
        #expect(failures == [firstError!])                         // reported once
        #expect(summary.failure == firstError)
        #expect(summary.unwrittenEvents == 60)
        #expect(summary.eventCount == 40)
        #expect(summary.members == 2)
        #expect(summary.bytesWritten == completeBytes)
        #expect(await writer.bytesWritten == completeBytes)
        // After the truncate failure: one write attempt, the failed truncate,
        // the close — and nothing else.
        let afterFailure = plan.log.drop { !$0.contains("fail after 25") }
        #expect(Array(afterFailure.dropFirst()) == ["truncate \(completeBytes) fail errno \(EROFS)", "close"])

        let read = try WriterFixtures.read(url)
        #expect(read.events == Array(events[0..<40]))
        #expect(read.report.members == 2)
        #expect(read.report.truncatedTail)
    }

    /// R1-9: each failure is reported once on `failures`; `flush()` throwing
    /// it again is a return value, not a second report.
    @Test("A repeated identical failure is reported once; it is reported again after clearing")
    func reportsEachFailureOnce() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let plan = FaultPlan()
        let writer = try WriterFixtures.writer(in: scratch, plan: plan)

        writer.sink.record(.marker("a", at: .zero))
        plan.failNextWrite(afterBytes: 0, errno: ENOSPC)
        plan.failNextWrite(afterBytes: 3, errno: ENOSPC)
        await #expect(throws: LogWriteError.diskFull) { try await writer.flush() }
        await #expect(throws: LogWriteError.diskFull) { try await writer.flush() }
        try await writer.flush()                                  // clears
        writer.sink.record(.marker("b", at: .zero))
        plan.failNextWrite(afterBytes: 0, errno: EIO)
        await #expect(throws: LogWriteError.self) { try await writer.flush() }
        let summary = await writer.finish()
        let failures = await WriterFixtures.collect(writer.failures)

        #expect(failures.count == 2)
        #expect(failures.first == .diskFull)
        if case .writeFailed(let description) = failures.last {
            #expect(description.contains("write"))
        } else {
            Issue.record("expected .writeFailed second, got \(failures)")
        }
        #expect(summary.failure == nil)                           // finish's retry succeeded
        #expect(try WriterFixtures.read(summary.url).events.map(\.payload) == [.marker("a"), .marker("b")])
    }

    /// Review finding 1: a success earlier in the same attempt must not clear
    /// the failure that attempt then reports.
    @Test("A write followed by a failing fsync, then another failing fsync, is reported once")
    func repeatedSyncFailureReportedOnce() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let plan = FaultPlan()
        let writer = try WriterFixtures.writer(in: scratch, plan: plan)
        writer.sink.record(.marker("a", at: .zero))
        plan.failNextSync(errno: EIO)
        plan.failNextSync(errno: EIO)
        await #expect(throws: LogWriteError.self) { try await writer.flush() }  // writes, fsync fails
        await #expect(throws: LogWriteError.self) { try await writer.flush() }  // nothing to write, fsync fails
        _ = await writer.finish()
        let failures = await WriterFixtures.collect(writer.failures)
        #expect(failures.count == 1, "\(failures)")
    }

    @Test("A split backlog failing on its second chunk is reported once across retries")
    func splitBacklogFailureReportedOnce() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let plan = FaultPlan()
        let writer = try WriterFixtures.writer(in: scratch, plan: plan, maxMemberInputBytes: 1_000)
        let events = WriterFixtures.events(0..<200)
        for event in events { writer.sink.record(event) }
        // The disk fills mid-backlog: the first attempt writes one chunk and
        // fails on the second; the disk stays full, so each retry fails on
        // its first chunk. One failure, one report.
        plan.failWrite(afterSuccessfulWrites: 1, afterBytes: 0, errno: ENOSPC)
        await #expect(throws: LogWriteError.diskFull) { try await writer.flush() }
        for _ in 0..<2 {
            plan.failNextWrite(afterBytes: 7, errno: ENOSPC)
            await #expect(throws: LogWriteError.diskFull) { try await writer.flush() }
        }
        let summary = await writer.finish()
        let failures = await WriterFixtures.collect(writer.failures)
        #expect(failures == [.diskFull], "\(failures)")
        #expect(summary.failure == nil)
        #expect(try WriterFixtures.read(summary.url).events == events)
    }

    @Test("A real success between two identical failures allows a second report")
    func successBetweenFailuresReportsAgain() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let plan = FaultPlan()
        let writer = try WriterFixtures.writer(in: scratch, plan: plan)
        writer.sink.record(.marker("a", at: .zero))
        plan.failNextSync(errno: EIO)
        await #expect(throws: LogWriteError.self) { try await writer.flush() }
        try await writer.flush()                                  // write nothing, fsync succeeds
        plan.failNextSync(errno: EIO)
        await #expect(throws: LogWriteError.self) { try await writer.flush() }
        _ = await writer.finish()
        let failures = await WriterFixtures.collect(writer.failures)
        #expect(failures.count == 2, "\(failures)")
    }

    /// R2-3: a truncate failure is `.writeFailed` whatever its errno — even
    /// ENOSPC, which only maps to `.diskFull` for `write`.
    @Test("ftruncate failing with ENOSPC is still .writeFailed")
    func truncateENOSPCIsWriteFailed() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let plan = FaultPlan()
        let writer = try WriterFixtures.writer(in: scratch, plan: plan)
        writer.sink.record(.marker("a", at: .zero))
        plan.failNextWrite(afterBytes: 4, errno: ENOSPC)
        plan.failNextTruncate(errno: ENOSPC)
        do {
            try await writer.flush()
            Issue.record("flush should have thrown")
        } catch {
            guard case .writeFailed(let description) = error else {
                Issue.record("expected .writeFailed, got \(error)")
                return
            }
            #expect(description.contains("ftruncate"))
        }
        _ = await writer.finish()
    }

    /// R2-4: `flush()` (background, memory warning) and `finish()` fsync; a
    /// failing fsync is a reported write failure, the member stays.
    @Test("flush() and finish() fsync; a failing fsync is reported but the member is kept")
    func syncFailure() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let plan = FaultPlan()
        let writer = try WriterFixtures.writer(in: scratch, plan: plan)
        writer.sink.record(.marker("a", at: .zero))
        plan.failNextSync(errno: EIO)
        do {
            try await writer.flush()
            Issue.record("flush should have thrown")
        } catch {
            guard case .writeFailed(let description) = error else {
                Issue.record("expected .writeFailed, got \(error)")
                return
            }
            #expect(description.contains("fsync"))
        }
        writer.sink.record(.marker("b", at: .zero))
        let summary = await writer.finish()
        let failures = await WriterFixtures.collect(writer.failures)

        #expect(failures.count == 1)
        #expect(summary.failure == nil)
        #expect(summary.eventCount == 2)
        #expect(plan.log.filter { $0 == "sync" }.count == 1)    // finish's fsync
        #expect(try WriterFixtures.read(summary.url).events.count == 2)
    }

    /// R1-9 / R3-2: `finish()` is idempotent and ends both streams.
    @Test("finish() is idempotent, closes both streams, and later events are dropped")
    func finishIsIdempotent() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = try WriterFixtures.writer(in: scratch)
        writer.sink.record(.marker("a", at: .zero))

        async let first = writer.finish()
        async let second = writer.finish()
        let (a, b) = await (first, second)
        let third = await writer.finish()
        #expect(a == b)
        #expect(a == third)
        #expect(a.eventCount == 1)

        // Both streams have finished: these loops end.
        #expect(await WriterFixtures.collect(writer.failures).isEmpty)
        #expect(await WriterFixtures.collect(writer.diskSpaceNotices).isEmpty)

        writer.sink.record(.marker("late", at: .zero))
        #expect(writer.sink.dropped == 1)
        #expect(writer.sink.queueDepth == 0)
        await #expect(throws: LogWriteError.alreadyFinished) { try await writer.flush() }
        #expect(await writer.finish() == a)
    }

    @Test("finish() writes everything recorded before it was called")
    func finishDrainsQueue() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = try WriterFixtures.writer(in: scratch)
        let events = WriterFixtures.events(0..<2_000)
        for event in events { writer.sink.record(event) }
        let summary = await writer.finish()
        #expect(summary.eventCount == 2_000)
        #expect(try WriterFixtures.read(summary.url).events == events)
    }

    @Test("Events recorded concurrently from many threads all arrive exactly once")
    func concurrentProducers() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = try WriterFixtures.writer(in: scratch, flushInterval: .milliseconds(10))
        let sink = writer.sink
        DispatchQueue.concurrentPerform(iterations: 8) { producer in
            for index in 0..<500 {
                sink.record(.marker("p\(producer)-\(index)", at: MonotonicTimestamp(nanoseconds: Int64(index))))
            }
        }
        let summary = await writer.finish()
        #expect(summary.eventCount == 4_000)
        let markers = try WriterFixtures.read(summary.url).events.compactMap { event -> String? in
            if case .marker(let text) = event.payload { return text }
            return nil
        }
        #expect(Set(markers).count == 4_000)
        // Per-producer order is preserved.
        for producer in 0..<8 {
            let mine = markers.filter { $0.hasPrefix("p\(producer)-") }
            #expect(mine == (0..<500).map { "p\(producer)-\($0)" })
        }
    }
}

/// Contract test 3: free space is advisory and separate from failures.
@Suite("LogFileWriter disk space")
struct LogFileWriterDiskSpaceTests {
    static let warning: Int64 = 200_000
    static let floor: Int64 = 50_000

    func writer(_ scratch: ScratchDirectory, _ disk: FakeDiskSpace) throws -> LogFileWriter {
        try WriterFixtures.writer(
            in: scratch, diskSpace: disk, warningFreeBytes: Self.warning, stopFreeBytes: Self.floor
        )
    }

    @Test("init below the warning writes the header and delivers .low once; .critical later, once")
    func lowThenCritical() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let disk = FakeDiskSpace(150_000)
        let writer = try writer(scratch, disk)
        #expect(try WriterFixtures.read(scratch.file("drive.jsonl.gz")).header == WriterFixtures.header)

        writer.sink.record(.marker("a", at: .zero))
        disk.set(140_000)
        try await writer.flush()                                  // still low: nothing new
        disk.set(40_000)
        writer.sink.record(.marker("b", at: .zero))
        try await writer.flush()                                  // .critical, and it writes
        disk.set(30_000)
        writer.sink.record(.marker("c", at: .zero))
        try await writer.flush()                                  // no re-report
        writer.sink.record(.marker("d", at: .zero))
        let queriesBeforeFinish = disk.queryCount
        let summary = await writer.finish()                       // writes below the floor

        let notices = await WriterFixtures.collect(writer.diskSpaceNotices)
        let failures = await WriterFixtures.collect(writer.failures)
        #expect(notices == [.low(availableBytes: 150_000), .critical(availableBytes: 40_000)])
        #expect(failures.isEmpty)
        #expect(disk.queryCount == queriesBeforeFinish)           // finish doesn't read free space
        #expect(summary.failure == nil)
        #expect(try WriterFixtures.read(summary.url).events.map(\.payload)
            == [.marker("a"), .marker("b"), .marker("c"), .marker("d")])
    }

    @Test("init below both thresholds delivers [.low, .critical] in order")
    func belowBothAtInit() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let disk = FakeDiskSpace(10_000)
        let writer = try writer(scratch, disk)
        writer.sink.record(.marker("a", at: .zero))
        try await writer.flush()
        let summary = await writer.finish()
        let notices = await WriterFixtures.collect(writer.diskSpaceNotices)
        #expect(notices == [.low(availableBytes: 10_000), .critical(availableBytes: 10_000)])
        #expect(await WriterFixtures.collect(writer.failures).isEmpty)
        #expect(summary.eventCount == 1)
    }

    // The `for await` below waits for a notice; a regression must fail the
    // test, not hang the run.
    @Test("The timer checks free space too", .timeLimit(.minutes(1)))
    func timerChecks() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let disk = FakeDiskSpace(WriterFixtures.roomy)
        let writer = try WriterFixtures.writer(
            in: scratch, diskSpace: disk, flushInterval: .milliseconds(20),
            warningFreeBytes: Self.warning, stopFreeBytes: Self.floor
        )
        disk.set(100_000)
        var notices: [DiskSpaceNotice] = []
        for await notice in writer.diskSpaceNotices {
            notices.append(notice)
            break
        }
        #expect(notices == [.low(availableBytes: 100_000)])
        _ = await writer.finish()
    }

    @Test("A provider that throws is skipped silently")
    func unreadableProvider() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let disk = FakeDiskSpace(nil)
        let writer = try writer(scratch, disk)
        writer.sink.record(.marker("a", at: .zero))
        try await writer.flush()
        let summary = await writer.finish()
        #expect(await WriterFixtures.collect(writer.diskSpaceNotices).isEmpty)
        #expect(await WriterFixtures.collect(writer.failures).isEmpty)
        #expect(summary.eventCount == 1)
        #expect(disk.queryCount == 2)                             // init + flush
    }
}

@Suite("LogSink")
struct LogSinkTests {
    @Test("Depth counts events not yet taken by the writer; dropped counts events after finish")
    func counters() async {
        let sink = LogSink()
        #expect(sink.queueDepth == 0)
        sink.record(.marker("a", at: .zero))
        sink.record(.marker("b", at: .zero))
        #expect(sink.queueDepth == 2)
        #expect(sink.dropped == 0)
        sink.finish()
        sink.record(.marker("late", at: .zero))
        #expect(sink.dropped == 1)
        var received: [LogEvent] = []
        for await event in sink.events {
            received.append(event)
            sink.noteConsumed()
        }
        #expect(received.count == 2)
        #expect(sink.queueDepth == 0)
        #expect(sink.totalEnqueued == 2)
    }
}

@Suite("POSIXLogFileHandle")
struct POSIXLogFileHandleTests {
    /// R2-5: the handle's own short-write / EINTR loop, through the internal
    /// write-syscall seam.
    @Test("Short writes and EINTR are retried until every byte lands")
    func retriesShortWritesAndEINTR() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("loop.bin")
        var calls = 0
        let handle = try POSIXLogFileHandle(creatingExclusively: url) { fd, buffer, count in
            calls += 1
            if calls % 3 == 0 { return (-1, EINTR) }
            let n = Darwin.write(fd, buffer, min(count, 7))
            return (n, n < 0 ? errno : 0)
        }
        let data = Data((0..<1_000).map { UInt8(truncatingIfNeeded: $0) })
        try handle.write(data)
        #expect(try handle.endOffset() == 1_000)
        try handle.close()
        #expect(try Data(contentsOf: url) == data)
        #expect(calls > 1_000 / 7)
    }

    @Test("A hard error stops the loop and reports the operation and errno")
    func reportsHardError() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("err.bin")
        var calls = 0
        let handle = try POSIXLogFileHandle(creatingExclusively: url) { fd, buffer, count in
            calls += 1
            if calls == 1 { return (Darwin.write(fd, buffer, 3), 0) }
            return (-1, ENOSPC)
        }
        #expect(throws: LogFileHandleError(operation: .write, errno: ENOSPC)) {
            try handle.write(Data(count: 10))
        }
        #expect(try handle.endOffset() == 3)                      // the prefix landed
        try handle.truncate(to: 0)
        #expect(try handle.endOffset() == 0)
        try handle.close()
    }

    @Test("Writes append at end of file after a truncate, with no gap")
    func appendsAfterTruncate() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("append.bin")
        let handle = try POSIXLogFileHandle(creatingExclusively: url)
        try handle.write(Data("hello world".utf8))
        try handle.truncate(to: 5)
        try handle.write(Data("!".utf8))
        try handle.sync()
        try handle.close()
        #expect(try Data(contentsOf: url) == Data("hello!".utf8))
    }

    @Test("Operations after close throw")
    func closedThrows() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let handle = try POSIXLogFileHandle(creatingExclusively: scratch.file("c.bin"))
        try handle.close()
        #expect(throws: LogFileHandleError.self) { try handle.write(Data([1])) }
        #expect(throws: LogFileHandleError.self) { try handle.close() }
    }

    @Test("Creation is exclusive")
    func exclusive() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("x.bin")
        let first = try POSIXLogFileHandle(creatingExclusively: url)
        #expect(throws: LogWriteError.fileExists(path: url.path)) {
            _ = try POSIXLogFileHandle(creatingExclusively: url)
        }
        try first.close()
    }
}
