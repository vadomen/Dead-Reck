import Foundation
import Testing

@testable import DriveLoggerCore

// M2 part 2 backlog items in Core: M1-L1 (read errors), R2.1-4 (adapter CSV
// `requestHeader`), R3-4 (stop reasons and low-disk details pinned in Core),
// and the writer-owned `stats` window the recorder needs every 10 s.

/// Thrown by a `ChunkedFile.ReadFault` in place of an I/O error.
struct InjectedReadError: Error, CustomStringConvertible {
    var description: String { "injected EIO" }
}

@Suite("LogFileReader read errors (M1-L1)")
struct LogFileReaderReadErrorTests {
    static let chunk = ChunkedFile.chunkSize

    /// Markers of random hex, so the members stay large after compression
    /// and the file spans several 1 MiB read chunks.
    static func bulkyGroups(count: Int, eventsPerGroup: Int) -> [[LogEvent]] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { group in
            (0..<eventsPerGroup).map { index in
                let text = (0..<40).map { _ in String(format: "%08x", UInt32.random(in: .min ... .max, using: &generator)) }.joined()
                return .marker(text, at: MonotonicTimestamp(nanoseconds: Int64(group * eventsPerGroup + index)))
            }
        }
    }

    /// Fails every read that starts at or beyond `offset`.
    static func failing(from offset: Int) -> ChunkedFile.ReadFault {
        { start in
            if start >= offset { throw InjectedReadError() }
        }
    }

    @Test("A read error mid-way through a gzip file is a read error, not a damaged member, in both recovery modes")
    func gzipReadError() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("a.jsonl.gz")
        let groups = Self.bulkyGroups(count: 4, eventsPerGroup: 3_000)
        let (bytes, starts) = try RecordingBytes.gzip(groups)
        try bytes.write(to: url)
        #expect(bytes.count > 2 * Self.chunk, "the file must span several read chunks")

        // Members wholly inside the first chunk are read; the member that
        // straddles the 1 MiB boundary needs the failing read.
        let ends = Array(starts.dropFirst()) + [bytes.count]
        let readable = (1..<starts.count).filter { ends[$0] <= Self.chunk }.map { groups[$0 - 1] }.flatMap { $0 }
        #expect(!readable.isEmpty && readable.count < groups.joined().count)

        for recovery in [LogRecovery.skipMalformedLines, .strict] {
            let reader = try LogFileReader(url: url, recovery: recovery, readFault: Self.failing(from: Self.chunk))
            let events = Array(reader)
            #expect(events == readable, "\(recovery)")
            #expect(reader.report.readError == "injected EIO", "\(recovery)")
            #expect(reader.report.damagedMemberIndices.isEmpty, "\(recovery)")
            #expect(reader.report.truncatedTail == false, "\(recovery)")
            #expect(reader.report.failure == nil, "\(recovery)")
        }
    }

    @Test("A read error in a plain .jsonl file is a read error, never a failure under skip mode")
    func plainReadError() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("a.jsonl")
        let events = Self.bulkyGroups(count: 1, eventsPerGroup: 5_000)[0]
        try (RecordingBytes.headerLine() + RecordingBytes.lines(events)).write(to: url)

        for recovery in [LogRecovery.skipMalformedLines, .strict] {
            let reader = try LogFileReader(url: url, recovery: recovery, readFault: Self.failing(from: Self.chunk))
            let read = Array(reader)
            #expect(!read.isEmpty && read.count < events.count, "\(recovery)")
            #expect(read == Array(events.prefix(read.count)), "\(recovery)")
            #expect(reader.report.readError == "injected EIO", "\(recovery)")
            #expect(reader.report.failure == nil, "\(recovery)")
            #expect(reader.report.damagedMemberIndices.isEmpty, "\(recovery)")
        }
    }

    @Test("inspect_log's health warnings say reading stopped at a read error")
    func healthWarning() {
        var report = LogReadReport(members: 3, truncatedTail: false, skippedLineIndices: [])
        report.readError = "injected EIO"
        let summary = RecordingAnalyzer(header: WriterFixtures.header).summary(report: report)
        #expect(summary.healthWarnings.contains { $0.hasPrefix("reading stopped at a read error") && $0.hasSuffix("injected EIO") })
        #expect(summary.render().contains("read error: yes"))
    }
}

@Suite("Writer stats window")
struct WriterStatsWindowTests {
    @Test("closeStatsWindow counts every event recorded before it, in write order, and fills in what only the writer knows")
    func countsEverything() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = try WriterFixtures.writer(in: scratch)
        for ms in stride(from: 0.0, to: 1_000, by: 10) {
            writer.sink.record(StatsFixtures.motion(at: ms))
            writer.sink.record(StatsFixtures.accel(at: ms))
        }
        // One 120 ms hole in the gyro stream.
        for ms in [0.0, 10, 130, 140] {
            writer.sink.record(StatsFixtures.gyro(at: ms))
        }
        writer.sink.record(StatsFixtures.elm(.ok, at: 500))
        writer.sink.record(StatsFixtures.elm(.timeout, at: 600))

        let first = await writer.closeStatsWindow(at: StatsFixtures.ms(1_000))
        #expect(first.counts == ["motion": 100, "accel": 100, "gyro": 4, "elm": 2])
        #expect(first.windowS == 1)
        #expect(first.motionHz == 100)
        #expect(first.obdHz == 1)
        #expect(first.timeouts == 1)
        #expect(first.gaps == ["motion": 0, "accel": 0, "gyro": 1])
        #expect(first.queueDepthMax >= 1)
        #expect(first.dropped == 0)
        #expect(first.bytesWritten == WriterFixtures.fileSize(scratch.file("drive.jsonl.gz")))

        // The stats row itself is an event of the next window.
        writer.sink.record(LogEvent(timestamp: StatsFixtures.ms(1_000), payload: .stats(first)))
        try await writer.flush()
        let second = await writer.closeStatsWindow(at: StatsFixtures.ms(2_000))
        #expect(second.counts == ["stats": 1])
        #expect(second.windowS == 1)
        #expect(second.queueDepthMax == 1)
        #expect(second.bytesWritten == WriterFixtures.fileSize(scratch.file("drive.jsonl.gz")))
        _ = await writer.finish()
    }

    @Test("Peak queue depth is measured at every record, not sampled; a window starts at the depth carried over")
    func peakDepth() {
        // A bare sink with no writer draining it: depth only moves when the
        // test says so.
        let sink = LogSink()
        for event in WriterFixtures.events(0..<500) { sink.record(event) }
        sink.noteConsumed(450)
        #expect(sink.queueDepth == 50)
        #expect(sink.takePeakQueueDepth() == 500)   // the burst, though it was drained
        #expect(sink.takePeakQueueDepth() == 50)    // carried over into the next window
        sink.noteConsumed(50)
        #expect(sink.takePeakQueueDepth() == 50)
        #expect(sink.takePeakQueueDepth() == 0)
    }

    @Test("Events refused after finish() are the next window's dropped count")
    func droppedAfterFinish() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let writer = try WriterFixtures.writer(in: scratch)
        writer.sink.record(StatsFixtures.motion(at: 0))
        _ = await writer.closeStatsWindow(at: StatsFixtures.ms(10))
        _ = await writer.finish()
        writer.sink.record(StatsFixtures.motion(at: 20))
        writer.sink.record(StatsFixtures.motion(at: 30))
        let after = await writer.closeStatsWindow(at: StatsFixtures.ms(40))
        #expect(after.dropped == 2)
        #expect(after.counts.isEmpty)
    }
}

@Suite("Lifecycle details (R3-4)")
struct LifecycleDetailTests {
    @Test("Stop reasons are on-disk strings")
    func stopReasons() {
        #expect(LifecycleSample.StopReason.user.rawValue == "user")
        #expect(LifecycleSample.StopReason.lowDiskSpace.rawValue == "lowDiskSpace")
        #expect(LifecycleSample.StopReason.allCases.count == 2)
        #expect(LifecycleSample.stop(.user) == LifecycleSample(event: "stop", detail: "user"))
        #expect(LifecycleSample.stop(.lowDiskSpace) == LifecycleSample(event: "stop", detail: "lowDiskSpace"))
    }

    @Test("Low-disk-space details keep their prefixes and byte counts")
    func lowDiskSpaceDetails() throws {
        #expect(LifecycleSample.lowDiskSpaceWarningPrefix == "warning: ")
        #expect(LifecycleSample.lowDiskSpaceFloorPrefix == "floor: ")
        #expect(LifecycleSample.lowDiskSpaceWarning(availableBytes: 199_999_999)
            == LifecycleSample(event: "lowDiskSpace", detail: "warning: 199999999 free"))
        #expect(LifecycleSample.lowDiskSpaceFloor(availableBytes: 49_000_000)
            == LifecycleSample(event: "lowDiskSpace", detail: "floor: 49000000 free"))
        let line = try LogCodec().line(for: LogEvent(timestamp: .zero, payload: .lifecycle(.lowDiskSpaceFloor(availableBytes: 7))))
        #expect(String(decoding: line, as: UTF8.self) == #"{"data":{"detail":"floor: 7 free","event":"lowDiskSpace"},"kind":"lifecycle","t":0}"# + "\n")
    }
}

@Suite("Adapter CSV request header (R2.1-4)")
struct AdapterCSVRequestHeaderTests {
    @Test("The adapter CSV has a requestHeader column: 7E0 for physical addressing, empty for functional")
    func requestHeaderColumn() {
        let columns = RecordingCSV.columns(for: "adapter")
        #expect(columns.last == "requestHeader")

        var physical = PollingRecord(.baseline)
        physical.requestHeader = "7E0"
        let functional = PollingRecord(.baseline)
        for (polling, expected) in [(physical, "7E0"), (functional, "")] {
            let event = LogEvent(timestamp: .zero, payload: .adapter(AdapterEventSample(adapter: MappingFixtures.bleAdapter, polling: polling)))
            let values = RecordingCSV.values(for: event)
            #expect(values.count == columns.count)
            #expect(values.last == expected)
        }
    }
}
