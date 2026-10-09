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

    /// Writes a stand-in sidecar next to `recording` (A only fixes the path;
    /// the contents are N4 B's).
    @discardableResult
    static func writeSidecar(for recording: URL) throws -> URL {
        let sidecar = LogStore.navSidecarURL(for: recording)
        try Data("{\"kind\":\"header\"}\n".utf8).write(to: sidecar)
        return sidecar
    }

    @Test("The sidecar path is the recording's, with .jsonl.gz replaced by .nav.jsonl, in the same folder")
    func sidecarPath() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let url = try await Self.write(scratch.store, startedAt: Date(timeIntervalSince1970: 1_790_000_000), lastSeconds: 1)
        let sidecar = LogStore.navSidecarURL(for: url)
        #expect(sidecar == NavSidecarFile.url(forRecording: url))
        #expect(sidecar.deletingLastPathComponent().standardizedFileURL == scratch.store.directory.standardizedFileURL)
        #expect(sidecar.lastPathComponent == url.lastPathComponent.replacingOccurrences(of: ".jsonl.gz", with: ".nav.jsonl"))
    }

    @Test("The list ignores sidecars, orphans included, and attaches each recording's sidecar when it exists")
    func listIgnoresSidecars() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let withSidecar = try await Self.write(scratch.store, startedAt: Date(timeIntervalSince1970: 1_790_003_600), lastSeconds: 5)
        let without = try await Self.write(scratch.store, startedAt: Date(timeIntervalSince1970: 1_790_000_000), lastSeconds: 5)
        let sidecar = try Self.writeSidecar(for: withSidecar)
        // A sidecar whose recording is gone is not a recording either.
        try Data("x\n".utf8).write(to: scratch.store.directory.appendingPathComponent("Drive_20200101-000000.nav.jsonl"))

        let files = try scratch.store.list()
        #expect(files.map(\.name) == [withSidecar.lastPathComponent, without.lastPathComponent])
        #expect(files[0].navSidecar?.standardizedFileURL == sidecar.standardizedFileURL)
        #expect(files[1].navSidecar == nil)
    }

    @Test("Export shares the recording and its sidecar; only the recording when there is none")
    func shareIncludesSidecar() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let withSidecar = try await Self.write(scratch.store, startedAt: Date(timeIntervalSince1970: 1_790_003_600), lastSeconds: 5)
        let without = try await Self.write(scratch.store, startedAt: Date(timeIntervalSince1970: 1_790_000_000), lastSeconds: 5)
        let sidecar = try Self.writeSidecar(for: withSidecar)

        let files = try scratch.store.list()
        #expect(files[0].shareItems.map(\.standardizedFileURL) == [withSidecar.standardizedFileURL, sidecar.standardizedFileURL])
        #expect(files[1].shareItems.map(\.standardizedFileURL) == [without.standardizedFileURL])
        #expect(files[0].shareItems.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("Delete removes the recording and its sidecar, works without one, and never touches another recording's")
    func deleteIncludesSidecar() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let doomed = try await Self.write(scratch.store, startedAt: Date(timeIntervalSince1970: 1_790_003_600), lastSeconds: 5)
        let kept = try await Self.write(scratch.store, startedAt: Date(timeIntervalSince1970: 1_790_000_000), lastSeconds: 5)
        let plain = try await Self.write(scratch.store, startedAt: Date(timeIntervalSince1970: 1_789_990_000), lastSeconds: 5)
        let doomedSidecar = try Self.writeSidecar(for: doomed)
        let keptSidecar = try Self.writeSidecar(for: kept)

        let files = try scratch.store.list()
        #expect(files.map(\.name) == [doomed, kept, plain].map(\.lastPathComponent))
        try scratch.store.delete(files[0])
        #expect(!FileManager.default.fileExists(atPath: doomed.path))
        #expect(!FileManager.default.fileExists(atPath: doomedSidecar.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(FileManager.default.fileExists(atPath: keptSidecar.path))

        // No sidecar: the recording alone goes.
        try scratch.store.delete(files[2])
        #expect(!FileManager.default.fileExists(atPath: plain.path))

        // A sidecar written after the list was read still goes with its recording.
        let stale = RecordingFile(url: files[1].url, name: files[1].name, sizeBytes: files[1].sizeBytes, startedAt: files[1].startedAt, duration: files[1].duration)
        try scratch.store.delete(stale)
        #expect(Set(scratch.files.map(\.lastPathComponent)).isEmpty)

        // A sidecar is never deleted as if it were a recording.
        let orphan = scratch.store.directory.appendingPathComponent("Drive_20200101-000000.nav.jsonl")
        try Data("x\n".utf8).write(to: orphan)
        let asRecording = RecordingFile(url: orphan, name: orphan.lastPathComponent, sizeBytes: 2, startedAt: nil, duration: nil)
        #expect(throws: LogStoreError.notInStore(path: orphan.path)) { try scratch.store.delete(asRecording) }
        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test("Deleting through the session takes the sidecar too, and refuses the recording being written")
    @MainActor
    func sessionDeleteIncludesSidecar() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let session = RecordingFixtures.session(store: scratch.store)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let active = try #require(session.currentFile)
        let activeSidecar = try Self.writeSidecar(for: active)
        let activeFile = RecordingFile(url: active, name: active.lastPathComponent, sizeBytes: 0, startedAt: nil, duration: nil)
        await #expect(throws: LogStoreError.recordingInProgress(path: activeFile.url.path)) { try await session.deleteRecording(activeFile) }
        #expect(FileManager.default.fileExists(atPath: activeSidecar.path))
        await session.stop()

        let file = try #require(try scratch.store.list().first)
        #expect(file.navSidecar != nil)
        try await session.deleteRecording(file)
        #expect(scratch.files.isEmpty)
    }
}
