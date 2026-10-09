import DriveLoggerCore
import Foundation

// replay_nav — replay recordings through the navigation engine on the Mac.
//
//   swift run -c release replay_nav <log.jsonl.gz>... [--gps use|mask-after <s>|mask-after-motion <s>|none]
//       [--hold-out-acc <m>] [--truth logs/truth.json] [--seed N|header] [--particles N]
//       [--set <configKey>=<number>]... [--out logs/out]
//       [--as-live] [--compare <log.nav.jsonl> [--tolerance <m>] [--heading-tolerance <deg>]]
//       [--write-sidecar <out.nav.jsonl>]
//
// --seed header: each log's seed is derived from its header's sessionID
// (`NavigationSeed`), as the live app does. --as-live: replay as the app ran
// live — inputs in file order (the tap's order), the header's seed and the
// default config (no --seed, --particles or --set). --compare: run the
// app's per-recording loop (`LiveNavigationRun`) over the same inputs and
// compare its 1 Hz estimates and pins with the sidecar the app wrote (one
// log only); see docs/NAV_SIDECAR.md. --write-sidecar: write the sidecar
// the app would have written for this recording with no drops (the same
// loop: file order, header seed, default config; one log only), e.g. to
// check --compare end to end on a Mac.
//
// Inputs are fed in arrival order; the engine never sees a fix the GPS mode
// or --hold-out-acc withholds, and is scored only against information it did
// not receive (withheld clean fixes, manual fixes before ingest, truth file
// points and end). Writes <out>/metrics.md, <out>/metrics.json (merged with
// earlier runs in the same directory) and <out>/<log>-<mode>.geojson. Output
// holds real positions: keep --out inside the git-ignored logs/.
//
// The analysis lives in DriveLoggerCore (`NavigationReplay`, `ReplayReport`)
// so it is covered by `swift test`; this file only parses arguments, reads
// and writes files, and prints. Exit status: 0 ok, 1 unreadable input, 2 usage,
// 4 --compare failed.

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("replay_nav: \(message)\n".utf8))
    exit(status)
}

let usage = """
    usage: replay_nav <log.jsonl.gz>... [--gps use|mask-after <s>|mask-after-motion <s>|none] [--hold-out-acc <m>]
           [--truth <truth.json>] [--seed N|header] [--particles N] [--set <configKey>=<number>]... [--out <dir>]
           [--as-live] [--compare <sidecar.nav.jsonl> [--tolerance <m>] [--heading-tolerance <deg>]]
           [--write-sidecar <out.nav.jsonl>]
    """

var arguments = Array(CommandLine.arguments.dropFirst())
var paths: [String] = []
var gps = GPSMode.use
var holdOut: Double?
var truthPath: String?
var outPath = "logs/out"
var config = NavigationConfig()
var overrides: [(String, Double)] = []
var seedFromHeader = false
var explicitSeed = false
var explicitParticles = false
var asLive = false
var comparePath: String?
var writeSidecarPath: String?
var tolerance = SidecarComparison.Tolerance.default

func number(_ text: String, _ flag: String) -> Double {
    guard let value = Double(text), value.isFinite else { fail("\(flag) needs a number, got \(text)\n\(usage)", status: 2) }
    return value
}

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    func value() -> String {
        guard !arguments.isEmpty else { fail("\(argument) needs a value\n\(usage)", status: 2) }
        return arguments.removeFirst()
    }
    switch argument {
    case "--gps":
        let name = value()
        let seconds = name.hasPrefix("mask-after") ? number(value(), name) : nil
        guard let mode = GPSMode(name, seconds: seconds) else { fail("unknown --gps \(name)\n\(usage)", status: 2) }
        gps = mode
    case "--hold-out-acc":
        holdOut = number(value(), argument)
    case "--truth":
        truthPath = value()
    case "--seed":
        let text = value()
        if text == "header" {
            seedFromHeader = true
        } else {
            guard let seed = UInt64(text) else { fail("--seed needs an unsigned integer or header\n\(usage)", status: 2) }
            config.seed = seed
            explicitSeed = true
        }
    case "--particles":
        guard let count = Int(value()), count > 0 else { fail("--particles needs a positive integer\n\(usage)", status: 2) }
        config.particleCount = count
        explicitParticles = true
    case "--as-live":
        asLive = true
    case "--compare":
        comparePath = value()
    case "--write-sidecar":
        writeSidecarPath = value()
    case "--tolerance":
        let metres = number(value(), argument)
        guard metres >= 0 else { fail("--tolerance must be >= 0\n\(usage)", status: 2) }
        tolerance.metres = metres
    case "--heading-tolerance":
        let degrees = number(value(), argument)
        guard degrees >= 0 else { fail("--heading-tolerance must be >= 0\n\(usage)", status: 2) }
        tolerance.degrees = degrees
    case "--set":
        let pair = value().split(separator: "=", maxSplits: 1).map(String.init)
        guard pair.count == 2 else { fail("--set needs key=value\n\(usage)", status: 2) }
        overrides.append((pair[0], number(pair[1], "--set \(pair[0])")))
    case "--out":
        outPath = value()
    case "-h", "--help":
        print(usage)
        exit(EXIT_SUCCESS)
    default:
        guard !argument.hasPrefix("--") else { fail("unexpected argument \(argument)\n\(usage)", status: 2) }
        paths.append(argument)
    }
}
guard !paths.isEmpty else { fail(usage, status: 2) }
if asLive {
    guard !explicitSeed, !explicitParticles, overrides.isEmpty else {
        fail("--as-live replays the live app: the header's seed and the default config; drop --seed N, --particles and --set\n\(usage)", status: 2)
    }
    seedFromHeader = true
}
if (comparePath != nil || writeSidecarPath != nil) && paths.count != 1 {
    fail("--compare and --write-sidecar take exactly one log\n\(usage)", status: 2)
}

// --set: patch numeric config fields through the config's JSON form, so
// every tunable is reachable without a rebuild.
if !overrides.isEmpty {
    do {
        let encoded = try JSONEncoder().encode(config)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            fail("cannot encode config", status: 2)
        }
        for (key, value) in overrides {
            guard object[key] != nil else { fail("unknown config key \(key)", status: 2) }
            object[key] = value
        }
        config = try JSONDecoder().decode(NavigationConfig.self, from: JSONSerialization.data(withJSONObject: object))
    } catch {
        fail("bad --set: \(error)", status: 2)
    }
}

var truth: TruthFile?
if let truthPath {
    do {
        truth = try TruthFile(contentsOf: URL(fileURLWithPath: truthPath))
    } catch {
        fail("cannot read truth file \(truthPath): \(error)", status: 1)
    }
}

if config.validated() != config {
    print("note: config validation clamps extrapolationHorizonS / maxForwardJumpS; the engine runs with the clamped values")
}
var baseOptions = ReplayOptions(gps: gps, holdOutAccuracyM: holdOut, config: config)
baseOptions.asLive = asLive
if asLive && (gps != .use || holdOut != nil) {
    print("note: --as-live with \(baseOptions.label): the live app received every fix; this run withholds some")
}
let outDirectory = URL(fileURLWithPath: outPath)
do {
    try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
} catch {
    fail("cannot create \(outPath): \(error)", status: 1)
}

print("Config (\(seedFromHeader ? "seed from each log's header" : "seed \(config.seed)"), \(config.particleCount) particles\(asLive ? ", as live: file order" : "")):")
print(ReplayReport.configJSON(config))
print("")
var compareFailed = false

var metrics: [ReplayMetrics] = []
for path in paths {
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    let inputs: [NavigationInput]
    let header: LogHeader
    let events: [LogEvent]
    do {
        let reader = try LogFileReader(url: url)
        events = Array(reader)
        header = reader.header
    } catch {
        fail("cannot read \(path): \(error)", status: 1)
    }
    inputs = asLive ? NavigationReplay.fileOrderInputs(from: events) : NavigationReplay.inputs(from: events)
    if let writeSidecarPath {
        // Exactly the app's loop: file order, header seed, default config.
        var run = LiveNavigationRun(header: header, appBuild: "replay_nav")
        do {
            let writer = try NavSidecarWriter(url: URL(fileURLWithPath: writeSidecarPath))
            writer.append(.header(run.header))
            var count = 0
            for input in NavigationReplay.fileOrderInputs(from: events) {
                run.ingest(input) { writer.append($0); count += 1 }
                if count >= 1_000 { writer.flush(); count = 0 }
            }
            writer.close()
            if let failure = writer.failure { fail("cannot write \(writeSidecarPath): \(failure)", status: 1) }
            print("Sidecar       wrote \(writeSidecarPath): \(run.estimates) estimates, \(writer.bytesWritten) bytes (as the app would, no drops)")
        } catch {
            fail("cannot write \(writeSidecarPath): \(error)", status: 1)
        }
    }
    var options = baseOptions
    if seedFromHeader {
        options.config.seed = NavigationSeed.derive(header: header)
        print("Seed          \(options.config.seed) (from the header's sessionID)")
    }
    let entry = truth?.entry(forLog: name)
    if truth != nil && entry == nil {
        print("note: no truth entry for \(name)")
    }
    let result = NavigationReplay.run(logName: name, inputs: inputs, options: options, truth: entry)
    if result.counters.inputsRejectedTimeJump > 0 {
        print("note: \(result.counters.inputsRejectedTimeJump) input(s) rejected as implausible forward time jumps")
    }
    print(ReplayReport.summary(result))
    metrics.append(ReplayMetrics(result))
    let stem = name.hasSuffix(".jsonl.gz") ? String(name.dropLast(9)) : name
    let geoURL = outDirectory.appendingPathComponent("\(stem)-\(options.label).geojson")
    do {
        try ReplayReport.geoJSON(result).write(to: geoURL)
        print("GeoJSON       \(geoURL.path)\n")
    } catch {
        fail("cannot write \(geoURL.path): \(error)", status: 1)
    }

    if let comparePath {
        let contents: NavSidecar.Contents
        do {
            contents = try NavSidecar.read(contentsOf: URL(fileURLWithPath: comparePath))
        } catch {
            fail("cannot read sidecar \(comparePath): \(error)", status: 1)
        }
        if contents.header.sessionID != header.sessionID {
            print("Warning       the sidecar's sessionID is not this recording's")
        }
        // The app's loop over exactly the inputs this replay gave its engine.
        let motionStart = NavigationReplay.motionStart(inputs)
        let given = inputs.filter { input in
            guard case .location(let sample, let t) = input else { return true }
            return NavigationReplay.withholdReason(sample, at: t, options: options, motionStart: motionStart) == nil
        }
        let lines = NavigationReplay.liveLines(inputs: given, sessionID: header.sessionID, config: options.config)
        let comparison = SidecarComparison(
            sidecar: contents, replay: lines, replayConfig: NavigationEngine(config: options.config).config,
            encodingFailures: NavigationReplay.encodingFailures(in: events).count
        )
        print("Sidecar       \(URL(fileURLWithPath: comparePath).lastPathComponent): \(contents.estimates.count) estimates, \(contents.pins.count) pins, app build \(contents.header.appBuild)\(asLive ? "" : " (not --as-live: arrival order)")")
        print(comparison.report(tolerance: tolerance))
        if !comparison.passes(tolerance) { compareFailed = true }
    }
}

let jsonURL = outDirectory.appendingPathComponent("metrics.json")
let markdownURL = outDirectory.appendingPathComponent("metrics.md")
do {
    let merged = try ReplayReport.mergedMetrics(existing: try? Data(contentsOf: jsonURL), adding: metrics)
    try ReplayReport.metricsJSON(merged).write(to: jsonURL)
    try Data(ReplayReport.markdown(merged).utf8).write(to: markdownURL)
    print("Metrics       \(markdownURL.path), \(jsonURL.path) (\(merged.count) runs)")
} catch {
    fail("cannot write metrics: \(error)", status: 1)
}
if compareFailed { exit(4) }
