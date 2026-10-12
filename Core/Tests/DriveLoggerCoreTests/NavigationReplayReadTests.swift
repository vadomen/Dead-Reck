import Foundation
import Testing

@testable import DriveLoggerCore

/// R11.1-8: `replay_nav` reports how the recording was read, so a damaged
/// recording does not replay a shortened drive silently; `--strict` refuses
/// it (`ReplayReport.readProblems` non-empty).
@Suite("Navigation replay read report")
struct NavigationReplayReadTests {
    typealias S = SyntheticDrive

    /// A synthetic drive written as a writer-shaped gzip file: header member,
    /// then members of 500 events.
    static func recording(malformedAfter: Int? = nil) throws -> (bytes: Data, starts: [Int], events: [LogEvent]) {
        let drive = S(initialHeadingDeg: 30, initialSpeed: 10, [.straight(seconds: 20, speed: 10), .stop(seconds: 5)])
        let events = drive.events(fix: { t, state, rng in S.cleanFix()(t, state, &rng) })
        let codec = LogCodec()
        var bytes = try GzipMember.make(RecordingBytes.headerLine())
        var starts = [0]
        for chunk in stride(from: 0, to: events.count, by: 500) {
            var payload = Data()
            for (index, event) in events[chunk..<min(chunk + 500, events.count)].enumerated() {
                payload.append(try codec.line(for: event))
                if chunk + index == malformedAfter { payload.append(Data("{\"t\":1,\"kind\":\n".utf8)) }
            }
            starts.append(bytes.count)
            bytes.append(try GzipMember.make(payload))
        }
        return (bytes, starts, events)
    }

    static func read(_ bytes: Data, recovery: LogRecovery = .skipMalformedLines) throws
        -> (events: [LogEvent], report: LogReadReport) {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = scratch.file("drive.jsonl.gz")
        try bytes.write(to: url)
        let reader = try LogFileReader(url: url, recovery: recovery)
        let events = Array(reader)
        return (events, reader.report)
    }

    @Test("A clean recording: no read problems, and the summary line says so")
    func clean() throws {
        let (bytes, starts, events) = try Self.recording()
        let read = try Self.read(bytes)
        #expect(read.events == events)
        #expect(ReplayReport.readProblems(read.report).isEmpty)
        #expect(ReplayReport.readText(read.report)
            == "\(starts.count) gzip members; truncated tail: no; damaged members: none; skipped lines: none")
    }

    @Test("A truncated tail is a read problem, and the replay is shorter than the drive")
    func truncatedTail() throws {
        let (bytes, starts, events) = try Self.recording()
        let cut = try Self.read(bytes.prefix(starts.last! + 40))
        #expect(cut.report.truncatedTail)
        let problems = ReplayReport.readProblems(cut.report)
        #expect(problems.count == 1 && problems[0].contains("truncated"))
        #expect(ReplayReport.readText(cut.report).contains("truncated tail: yes"))
        // Why it matters: the drive replayed from the cut file ends early, so
        // a truth `end` would be scored at the wrong instant.
        let options = ReplayOptions(gps: .use, config: S.config(particles: 100))
        let full = NavigationReplay.run(logName: "a", inputs: NavigationReplay.inputs(from: events), options: options)
        let short = NavigationReplay.run(logName: "a", inputs: NavigationReplay.inputs(from: cut.events), options: options)
        #expect(short.endT < full.endT)
    }

    @Test("A malformed line is skipped and reported; under strict reading stops and the failure is a read problem")
    func malformedLine() throws {
        let (bytes, _, events) = try Self.recording(malformedAfter: 700)
        let lenient = try Self.read(bytes)
        #expect(lenient.events == events)
        #expect(lenient.report.skippedLineIndices.count == 1)
        #expect(ReplayReport.readProblems(lenient.report) == ["1 malformed line(s) skipped"])
        #expect(ReplayReport.readText(lenient.report).hasSuffix("skipped lines: 1"))

        let strict = try Self.read(bytes, recovery: .strict)
        #expect(strict.events.count == 701)
        #expect(strict.report.failure != nil)
        let problems = ReplayReport.readProblems(strict.report)
        #expect(problems.count == 1 && problems[0].hasPrefix("reading stopped early"))
        #expect(ReplayReport.readText(strict.report).contains("stopped early"))
    }

    @Test("A damaged member and a read error are read problems")
    func damagedAndReadError() {
        let report = LogReadReport(members: 5, truncatedTail: false, skippedLineIndices: [], damagedMemberIndices: [2],
                                   readError: "EIO")
        let problems = ReplayReport.readProblems(report)
        #expect(problems.count == 2)
        #expect(problems[0].contains("1 damaged gzip member(s) skipped: [2]"))
        #expect(problems[1].contains("read error") && problems[1].contains("EIO"))
        #expect(ReplayReport.readText(report).contains("damaged members: [2]"))
        #expect(ReplayReport.readText(report).contains("read error: EIO"))
    }
}
