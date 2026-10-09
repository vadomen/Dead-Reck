import DriveLoggerCore
import Foundation

// replay_nav — replay recordings through the navigation engine on the Mac.
//
//   swift run -c release replay_nav <log.jsonl.gz>... [--gps use|mask-after <s>|mask-after-motion <s>|none]
//       [--hold-out-acc <m>] [--truth logs/truth.json] [--seed N] [--particles N]
//       [--set <configKey>=<number>]... [--out logs/out]
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
// and writes files, and prints. Exit status: 0 ok, 1 unreadable input, 2 usage.

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("replay_nav: \(message)\n".utf8))
    exit(status)
}

let usage = """
    usage: replay_nav <log.jsonl.gz>... [--gps use|mask-after <s>|mask-after-motion <s>|none] [--hold-out-acc <m>]
           [--truth <truth.json>] [--seed N] [--particles N] [--set <configKey>=<number>]... [--out <dir>]
    """

var arguments = Array(CommandLine.arguments.dropFirst())
var paths: [String] = []
var gps = GPSMode.use
var holdOut: Double?
var truthPath: String?
var outPath = "logs/out"
var config = NavigationConfig()
var overrides: [(String, Double)] = []

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
        guard let seed = UInt64(value()) else { fail("--seed needs an unsigned integer\n\(usage)", status: 2) }
        config.seed = seed
    case "--particles":
        guard let count = Int(value()), count > 0 else { fail("--particles needs a positive integer\n\(usage)", status: 2) }
        config.particleCount = count
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

let options = ReplayOptions(gps: gps, holdOutAccuracyM: holdOut, config: config)
let outDirectory = URL(fileURLWithPath: outPath)
do {
    try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
} catch {
    fail("cannot create \(outPath): \(error)", status: 1)
}

print("Config (seed \(config.seed), \(config.particleCount) particles):")
print(ReplayReport.configJSON(config))
print("")

var metrics: [ReplayMetrics] = []
for path in paths {
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    let inputs: [NavigationInput]
    do {
        let reader = try LogFileReader(url: url)
        inputs = NavigationReplay.inputs(from: reader)
    } catch {
        fail("cannot read \(path): \(error)", status: 1)
    }
    let entry = truth?.entry(forLog: name)
    if truth != nil && entry == nil {
        print("note: no truth entry for \(name)")
    }
    let result = NavigationReplay.run(logName: name, inputs: inputs, options: options, truth: entry)
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
