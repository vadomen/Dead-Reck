import Foundation
import Testing

@testable import DriveLoggerCore

/// Builds recording files byte by byte, so the reader is tested against
/// exactly the damage a crash or flat battery leaves.
enum RecordingBytes {
    static func headerLine(_ header: LogHeader = WriterFixtures.header) throws -> Data {
        try LogCodec().line(for: header)
    }

    static func lines(_ events: [LogEvent]) throws -> Data {
        let codec = LogCodec()
        var data = Data()
        for event in events { data.append(try codec.line(for: event)) }
        return data
    }

    /// Header member followed by one member per group, like the writer.
    static func gzip(_ groups: [[LogEvent]]) throws -> (bytes: Data, memberStarts: [Int]) {
        var bytes = try GzipMember.make(headerLine())
        var starts = [0]
        for group in groups {
            starts.append(bytes.count)
            bytes.append(try GzipMember.make(lines(group)))
        }
        return (bytes, starts)
    }
}

@Suite("LogFileReader")
struct LogFileReaderTests {
    static let groups = [
        WriterFixtures.events(0..<10),
        WriterFixtures.events(10..<25),
        WriterFixtures.events(25..<40),
    ]

    @Test("Reads a writer-shaped gzip file member by member")
    func readsGzip() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("a.jsonl.gz")
        try RecordingBytes.gzip(Self.groups).bytes.write(to: url)

        let read = try WriterFixtures.read(url)
        #expect(read.header == WriterFixtures.header)
        #expect(read.events == Self.groups.flatMap { $0 })
        #expect(read.report == LogReadReport(members: 4, truncatedTail: false, skippedLineIndices: []))
    }

    @Test("Reads plain .jsonl too")
    func readsPlain() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("a.jsonl")
        let events = WriterFixtures.events(0..<30)
        try (RecordingBytes.headerLine() + RecordingBytes.lines(events)).write(to: url)

        let read = try WriterFixtures.read(url)
        #expect(read.header == WriterFixtures.header)
        #expect(read.events == events)
        #expect(read.report.members == 0)
        #expect(!read.report.truncatedTail)
    }

    @Test("Plain .jsonl larger than one read chunk streams correctly")
    func readsLargePlain() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("big.jsonl")
        let events = WriterFixtures.events(0..<30_000)
        try (RecordingBytes.headerLine() + RecordingBytes.lines(events)).write(to: url)
        #expect(try WriterFixtures.read(url).events == events)
    }

    @Test("A half-written last line in plain .jsonl is skipped and reported")
    func plainHalfLine() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("half.jsonl")
        let events = WriterFixtures.events(0..<5)
        let whole = try RecordingBytes.headerLine() + RecordingBytes.lines(events)
        try whole.dropLast(12).write(to: url)

        let read = try WriterFixtures.read(url)
        #expect(read.events == Array(events.prefix(4)))
        #expect(read.report.skippedLineIndices == [5])
    }

    /// The flat-battery case: the file can end anywhere inside the last
    /// member. Every cut must yield the complete members and flag the tail.
    @Test("A gzip file cut at every byte of its last member yields the complete members")
    func truncatedTailAtEveryCut() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let (bytes, starts) = try RecordingBytes.gzip(Self.groups)
        let lastStart = starts.last!
        let complete = Self.groups.dropLast().flatMap { $0 }

        for cut in (lastStart + 1)..<bytes.count {
            let url = scratch.file("cut-\(cut).jsonl.gz")
            try bytes.prefix(cut).write(to: url)
            let read = try WriterFixtures.read(url)
            #expect(read.events == complete, "cut at \(cut)")
            #expect(read.report.members == 3, "cut at \(cut)")
            #expect(read.report.truncatedTail, "cut at \(cut)")
            try FileManager.default.removeItem(at: url)
        }
    }

    @Test("A cut exactly at a member boundary is a clean file")
    func cutAtBoundary() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let (bytes, starts) = try RecordingBytes.gzip(Self.groups)
        let url = scratch.file("b.jsonl.gz")
        try bytes.prefix(starts[2]).write(to: url)
        let read = try WriterFixtures.read(url)
        #expect(read.events == Self.groups[0])
        #expect(!read.report.truncatedTail)
    }

    /// After power loss a filesystem can leave the file's last blocks
    /// zero-filled: the size was committed, the data wasn't.
    @Test("A zero-filled tail is reported as a damaged tail, the members before it survive")
    func zeroFilledTail() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("z.jsonl.gz")
        var bytes = try RecordingBytes.gzip(Self.groups).bytes
        bytes.append(Data(count: 4_096))
        try bytes.write(to: url)
        let read = try WriterFixtures.read(url)
        #expect(read.events == Self.groups.flatMap { $0 })
        #expect(read.report.truncatedTail)
    }

    @Test("A corrupt member in the middle is skipped and reported; reading continues")
    func corruptMiddleMember() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("c.jsonl.gz")
        var (bytes, starts) = try RecordingBytes.gzip(Self.groups)
        // Flip a bit in member 2's stored CRC.
        let crcIndex = starts[3] - 8
        bytes[crcIndex] ^= 0x40
        try bytes.write(to: url)

        let read = try WriterFixtures.read(url)
        #expect(read.events == Self.groups[0] + Self.groups[2])
        #expect(read.report.damagedMemberIndices == [2])
        #expect(read.report.members == 3)
        #expect(!read.report.truncatedTail)
    }

    @Test("Strict reading stops at a corrupt member and says why")
    func strictStopsAtCorruptMember() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("s.jsonl.gz")
        var (bytes, starts) = try RecordingBytes.gzip(Self.groups)
        bytes[starts[3] - 8] ^= 0x40
        try bytes.write(to: url)

        let read = try WriterFixtures.read(url, recovery: .strict)
        #expect(read.events == Self.groups[0])
        guard case .damagedMember(let index, _) = read.report.failure else {
            Issue.record("expected .damagedMember, got \(String(describing: read.report.failure))")
            return
        }
        #expect(index == 2)
    }

    @Test("Malformed lines inside a member are skipped with their file-wide line index")
    func malformedLinesInMember() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("m.jsonl.gz")
        let good = WriterFixtures.events(0..<3)
        var payload = try RecordingBytes.lines([good[0]])
        payload.append(Data("{not json}\n".utf8))
        payload.append(try RecordingBytes.lines([good[1], good[2]]))
        let bytes = try GzipMember.make(RecordingBytes.headerLine()) + GzipMember.make(payload)
        try bytes.write(to: url)

        let lenient = try WriterFixtures.read(url)
        #expect(lenient.events == good)
        #expect(lenient.report.skippedLineIndices == [2])         // header is line 0

        let strict = try WriterFixtures.read(url, recovery: .strict)
        #expect(strict.events == [good[0]])
        guard case .malformedLine(let index, _) = strict.report.failure else {
            Issue.record("expected .malformedLine, got \(String(describing: strict.report.failure))")
            return
        }
        #expect(index == 2)
    }

    @Test("A header from a newer format version is refused")
    func refusesNewerVersion() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("future.jsonl.gz")
        let line = Data(#"{"formatVersion":99,"sessionID":"3F2504E0-4F89-41D3-9A0C-0305E82C3301"}"#.utf8) + Data("\n".utf8)
        try GzipMember.make(line).write(to: url)
        #expect(throws: LogDecodingError.unsupportedFormatVersion(99)) {
            _ = try LogFileReader(url: url)
        }
    }

    @Test("An empty file, or one whose header member is cut, has no header")
    func missingHeader() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let empty = scratch.file("empty.jsonl.gz")
        try Data().write(to: empty)
        #expect(throws: LogDecodingError.missingHeader) { _ = try LogFileReader(url: empty) }

        let cut = scratch.file("cut.jsonl.gz")
        try GzipMember.make(RecordingBytes.headerLine()).dropLast(3).write(to: cut)
        #expect(throws: LogDecodingError.missingHeader) { _ = try LogFileReader(url: cut) }
    }

    @Test("A gzip file from another tool is refused with a clear error")
    func refusesForeignGzip() throws {
        #if os(macOS)
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let plain = scratch.file("other.jsonl")
        try (RecordingBytes.headerLine() + RecordingBytes.lines(WriterFixtures.events(0..<3))).write(to: plain)
        _ = try SystemGzip.run("/usr/bin/gzip", ["-k", plain.path])
        let gz = scratch.file("other.jsonl.gz")
        #expect(throws: LogFileReadError.self) { _ = try LogFileReader(url: gz) }
        #endif
    }

    @Test("A missing file throws")
    func missingFile() {
        #expect(throws: (any Error).self) {
            _ = try LogFileReader(url: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jsonl.gz"))
        }
    }

    @Test("v1 and v2 frozen fixtures read through the file reader")
    func readsFrozenFixtures() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        for (name, text) in [
            ("v1.jsonl", LogFormatCompatibilityTests.version1Recording),
            ("v2.jsonl", LogFormatCompatibilityV2Tests.version2Recording),
        ] {
            let plain = scratch.file(name)
            try Data(text.utf8).write(to: plain)
            let gz = scratch.file(name + ".gz")
            try GzipMember.make(Data(text.utf8)).write(to: gz)
            let expected = try LogCodec().document(from: Data(text.utf8))
            for url in [plain, gz] {
                let read = try WriterFixtures.read(url, recovery: .strict)
                #expect(read.header == expected.header)
                #expect(read.events == expected.events)
                #expect(read.report.failure == nil)
            }
        }
    }
}

@Suite("LogFileName")
struct LogFileNameTests {
    // 2023-11-14T22:13:20Z
    static let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Rendered in the given time zone")
    func timeZones() {
        #expect(LogFileName.make(for: Self.start, timeZone: TimeZone(identifier: "UTC")!) == "Drive_20231114-221320.jsonl.gz")
        #expect(LogFileName.make(for: Self.start, timeZone: TimeZone(identifier: "Europe/Kyiv")!) == "Drive_20231115-001320.jsonl.gz")
        #expect(LogFileName.make(for: Self.start, timeZone: TimeZone(identifier: "America/Los_Angeles")!) == "Drive_20231114-141320.jsonl.gz")
    }

    @Test("Collision index 2, 3, … gets a suffix; 1 does not")
    func collisions() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(LogFileName.make(for: Self.start, timeZone: utc, collisionIndex: 1) == "Drive_20231114-221320.jsonl.gz")
        #expect(LogFileName.make(for: Self.start, timeZone: utc, collisionIndex: 2) == "Drive_20231114-221320_2.jsonl.gz")
        #expect(LogFileName.make(for: Self.start, timeZone: utc, collisionIndex: 13) == "Drive_20231114-221320_13.jsonl.gz")
    }

    @Test("Uses 24-hour Gregorian digits whatever the process locale")
    func posix() {
        // 2026-01-02T13:04:05Z: an afternoon hour that a 12-hour locale would
        // render as 01, and a date that some calendars number differently.
        let date = Date(timeIntervalSince1970: 1_767_359_045)
        #expect(LogFileName.make(for: date, timeZone: TimeZone(identifier: "UTC")!) == "Drive_20260102-130405.jsonl.gz")
    }

    @Test("Fractional seconds are truncated, not rounded up")
    func truncatesSeconds() {
        let date = Self.start.addingTimeInterval(0.999)
        #expect(LogFileName.make(for: date, timeZone: TimeZone(identifier: "UTC")!) == "Drive_20231114-221320.jsonl.gz")
    }
}
