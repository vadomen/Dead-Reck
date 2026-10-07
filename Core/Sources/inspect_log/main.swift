import DriveLoggerCore
import Foundation

// inspect_log — summarise a DriveLogger recording on the Mac.
//
//   swift run inspect_log <file.jsonl.gz | file.jsonl> [--csv <dir>] [--strict]
//
// Prints the header, events per kind, achieved rates, gaps over 50 ms in the
// 100 Hz streams, OBD latency percentiles (t - requestT), `elm` outcome
// counts, the recorder's own stats rows and the truncation report; `--csv`
// writes one CSV per kind for analysis in Python. `--strict` stops at the
// first malformed line or damaged member instead of skipping it.
//
// The analysis lives in DriveLoggerCore (`RecordingAnalyzer`,
// `RecordingCSVExporter`) so it is covered by `swift test`; this file only
// parses arguments and prints. Exit status: 0 read (warnings are printed,
// not fatal), 1 unreadable file, 2 usage.

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("inspect_log: \(message)\n".utf8))
    exit(status)
}

let usage = "usage: inspect_log <file.jsonl.gz|file.jsonl> [--csv <dir>] [--strict]"
var arguments = Array(CommandLine.arguments.dropFirst())
var csvDirectory: URL?
var recovery = LogRecovery.skipMalformedLines
var path: String?

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--csv":
        guard !arguments.isEmpty else { fail("--csv needs a directory\n\(usage)", status: 2) }
        csvDirectory = URL(fileURLWithPath: arguments.removeFirst())
    case "--strict":
        recovery = .strict
    case "-h", "--help":
        print(usage)
        exit(EXIT_SUCCESS)
    default:
        guard path == nil, !argument.hasPrefix("--") else { fail("unexpected argument \(argument)\n\(usage)", status: 2) }
        path = argument
    }
}
guard let path else { fail(usage, status: 2) }

let url = URL(fileURLWithPath: path)
let reader: LogFileReader
do {
    reader = try LogFileReader(url: url, recovery: recovery)
} catch {
    fail("cannot read \(path): \(error)", status: 1)
}

var analyzer = RecordingAnalyzer(header: reader.header)
let exporter: RecordingCSVExporter?
do {
    exporter = try csvDirectory.map { try RecordingCSVExporter(directory: $0) }
} catch {
    fail("cannot create \(csvDirectory?.path ?? ""): \(error)", status: 1)
}

do {
    for event in reader {
        analyzer.observe(event)
        try exporter?.write(event)
    }
} catch {
    fail("CSV export failed: \(error)", status: 1)
}

let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
print("File          \(url.path) (\(size) bytes)")
print("")
print(analyzer.summary(report: reader.report).render(), terminator: "")

if let exporter {
    do {
        let rows = try exporter.finish()
        print("")
        print("CSV           \(exporter.directory.path): " + rows.keys.sorted().map { "\($0).csv \(rows[$0]!) rows" }.joined(separator: ", "))
    } catch {
        fail("CSV export failed: \(error)", status: 1)
    }
}
