import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

@Suite("LogStore")
struct LogStoreTests {
    static func header(startedAt: Date) -> LogHeader {
        LogHeader(
            sessionID: UUID(),
            startedAt: startedAt,
            referenceUptimeSeconds: 100,
            app: RecordingFixtures.app,
            device: RecordingFixtures.device,
            timeZone: "UTC"
        )
    }

    /// A finished recording whose last event is at `lastSeconds`.
    static func write(_ store: LogStore, startedAt: Date, lastSeconds: Double, flushes: Int = 3) async throws -> URL {
        let url = store.newFileURL(startingAt: startedAt, timeZone: TimeZone(identifier: "UTC")!)
        let writer = try LogFileWriter(url: url, header: header(startedAt: startedAt), flushInterval: .seconds(3_600), diskSpace: FakeDisk(RecordingFixtures.roomy))
        for flush in 0..<flushes {
            let t = lastSeconds * Double(flush + 1) / Double(flushes)
            writer.sink.record(LogEvent(timestamp: MonotonicTimestamp(seconds: t - 0.5), payload: .accelerometer(.zero)))
            writer.sink.record(.marker("m\(flush)", at: MonotonicTimestamp(seconds: t)))
            try await writer.flush()
        }
        _ = await writer.finish()
        return url
    }

    @Test("New file names never collide with an existing file")
    func newFileURL() throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let utc = TimeZone(identifier: "UTC")!
        let first = scratch.store.newFileURL(startingAt: start, timeZone: utc)
        #expect(first.lastPathComponent == LogFileName.make(for: start, timeZone: utc))
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = scratch.store.newFileURL(startingAt: start, timeZone: utc)
        #expect(second.lastPathComponent == LogFileName.make(for: start, timeZone: utc, collisionIndex: 2))
        // A dangling symlink is a taken name too (O_EXCL would refuse it).
        try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: "/nonexistent/x")
        let third = scratch.store.newFileURL(startingAt: start, timeZone: utc)
        #expect(third.lastPathComponent == LogFileName.make(for: start, timeZone: utc, collisionIndex: 3))
    }

    @Test("Lists recordings newest first with size, start and duration from the last complete member")
    func list() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let older = try await Self.write(scratch.store, startedAt: Date(timeIntervalSince1970: 1_790_000_000), lastSeconds: 12.5)
        let newer = try await Self.write(scratch.store, startedAt: Date(timeIntervalSince1970: 1_790_003_600), lastSeconds: 3_600)
        FileManager.default.createFile(atPath: scratch.store.directory.appendingPathComponent("notes.txt").path, contents: Data("x".utf8))
        try FileManager.default.createDirectory(at: scratch.store.directory.appendingPathComponent("sub.jsonl.gz"), withIntermediateDirectories: false)

        let files = try scratch.store.list()
        #expect(files.map(\.url.lastPathComponent) == [newer.lastPathComponent, older.lastPathComponent])
        #expect(files[0].startedAt == Date(timeIntervalSince1970: 1_790_003_600))
        #expect(files[0].duration == 3_600)
        #expect(files[1].duration == 12.5)
        let size = try FileManager.default.attributesOfItem(atPath: older.path)[.size] as? Int
        #expect(files[1].sizeBytes == size)
    }

    @Test("A truncated tail: the duration is the last complete member's; a header-only or unreadable file has none")
    func damagedFiles() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let url = try await Self.write(scratch.store, startedAt: Date(timeIntervalSince1970: 1_790_000_000), lastSeconds: 30)
        // Append the start of a member whose data never made it (as a flat
        // battery leaves it): a valid member header promising more bytes
        // than follow. The last complete member ends with "m2" at 30 s.
        let bytes = try Data(contentsOf: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes.prefix(30))
        try handle.close()
        #expect(try LogFileReader(url: url).reduce(into: 0) { count, _ in count += 1 } == 6)

        let headerOnly = scratch.store.directory.appendingPathComponent("Drive_20260101-000000.jsonl.gz")
        let writer = try LogFileWriter(url: headerOnly, header: Self.header(startedAt: Date(timeIntervalSince1970: 1_000)), diskSpace: FakeDisk(RecordingFixtures.roomy))
        _ = await writer.finish()
        let garbage = scratch.store.directory.appendingPathComponent("Drive_20250101-000000.jsonl.gz")
        try Data("not a recording".utf8).write(to: garbage)

        let files = try scratch.store.list()
        #expect(files.map(\.name) == [url.lastPathComponent, headerOnly.lastPathComponent, garbage.lastPathComponent])
        #expect(files[0].duration == 30)
        #expect(files[1].startedAt == Date(timeIntervalSince1970: 1_000))
        #expect(files[1].duration == nil)
        #expect(files[2].startedAt == nil)
        #expect(files[2].duration == nil)
    }

    @Test("The tail walk matches what LogFileReader returns as the last event")
    func tailMatchesReader() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let url = try await Self.write(scratch.store, startedAt: Date(), lastSeconds: 99.25, flushes: 7)
        let last = Array(try LogFileReader(url: url)).last?.timestamp
        #expect(RecordingTail.lastEventTimestamp(of: url) == last)
    }

    @Test("Deletes recordings in the store only")
    func delete() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let url = try await Self.write(scratch.store, startedAt: Date(), lastSeconds: 1)
        let file = try #require(try scratch.store.list().first)
        let elsewhere = RecordingFile(url: FileManager.default.temporaryDirectory.appendingPathComponent(file.name), name: file.name, sizeBytes: 0, startedAt: nil, duration: nil)
        #expect(throws: LogStoreError.notInStore(path: elsewhere.url.path)) { try scratch.store.delete(elsewhere) }
        try scratch.store.delete(file)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
