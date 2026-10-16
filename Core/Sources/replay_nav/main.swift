import DriveLoggerCore
import Foundation

// replay_nav — replay recordings through the navigation engine on the Mac.
//
//   swift run -c release replay_nav <log.jsonl.gz>... [--gps use|mask-after <s>|mask-after-motion <s>|none]
//       [--hold-out-acc <m>] [--truth logs/truth.json] [--seed N|header] [--particles N]
//       [--set <configKey>=<number>]... [--out logs/out]
//       [--as-live | --file-order] [--compare <log.nav.jsonl> [--tolerance <m>] [--heading-tolerance <deg>]]
//       [--write-sidecar <out.nav.jsonl>] [--pin-pair-window <s>] [--strict]
//       [--roads <pack.roadpack>]... [--wrong-road-tolerance <m>]
//
// --roads (repeatable, N3.2): road packs, in any order (the network sorts
// them by content hash, so the order given changes nothing; the same pack
// twice is refused); the engine runs its road update against them, the run is scored with the road metrics and its
// mode label gets -roads-<first 8 hex of roadSetHash>. Each pack is fully
// verified on load. When the engine gets them (N3.3, `ReplayRoadAttach`):
// - by default from the first input (the N3.2 replays);
// - with --as-live, and always for --write-sidecar: as the app with its
//   packs ready. The engine starts without roads; at each selection request
//   (the engine's first initialisation, then each position it uses until a
//   network is attached) the given packs covering the estimate's 95 % circle
//   are selected and attached at once. The metrics replay and the written
//   sidecar attach at the same input;
// - with --compare: at the sidecar's `roads` line (`afterInputs`), the whole
//   given set; with a sidecar that used no roads, the live rule above. A
//   roadSetHash that differs from the sidecar's, or packs on one side only,
//   is a warning naming the hashes, and the verdict is never PASS (exact).
// --wrong-road-tolerance m (default 20): a
// matched edge that is not the truth's road still counts as right within m
// metres of the truth fix. Data: © OpenStreetMap contributors, ODbL 1.0.
//
// Each log's read report (members, truncated tail, damaged members, skipped
// lines) is printed; a damaged read is a warning, and with --strict the
// recording is read with `LogRecovery.strict` and any damage (a truncated
// tail included) stops replay_nav with status 3: metrics.json and metrics.md
// are not updated (GeoJSON of logs before it in the same call is already written).
// --pin-pair-window s (default 3, 0 disables): a manual fix at most s seconds
// after the previous one is a refinement of it and is not scored (it is still
// ingested); see `NavigationReplay.pinScoring`. Truth-file `excludePins` mark
// manual fixes that are not scored either. Scoring only: estimates are the same.
// A truth-file `scoreUntilT` (session seconds) leaves every checkpoint after
// it listed but unscored (the truth `end` included); also scoring only.
// --seed header: each log's seed is derived from its header's sessionID
// (`NavigationSeed`), as the live app does. --as-live: replay as the app ran
// live — inputs in file order (the tap's order), the header's seed and the
// default config (no --seed, --particles or --set). --file-order: inputs
// in file order, as live, with any seed and config (a seed sweep of the live
// order); the label gets -file-order. --compare: run the
// app's per-recording loop (`LiveNavigationRun`) over the same inputs and
// compare its 1 Hz estimates and pins with the sidecar the app wrote (one
// log only; sidecar v1 or v2); see docs/NAV_SIDECAR.md. Without roads on
// either side, config keys that differ only in road-only keys are named as
// inert, not blamed (N3-CMPHASH). --write-sidecar: write the sidecar
// the app would have written for this recording with no drops (the same
// loop: file order, header seed, default config, --roads attached by the
// live rule; one log only), e.g. to check --compare end to end on a Mac.
// With --roads the selection attempts are `roadsSelection` lines (packs
// named by file name; identical repeats folded into one line with a count,
// as the app writes them); --compare prints both sides' attempts and never
// compares them.
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
// 3 damaged input under --strict, 4 --compare failed.

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("replay_nav: \(message)\n".utf8))
    exit(status)
}

let usage = """
    usage: replay_nav <log.jsonl.gz>... [--gps use|mask-after <s>|mask-after-motion <s>|none] [--hold-out-acc <m>]
           [--truth <truth.json>] [--seed N|header] [--particles N] [--set <configKey>=<number>]... [--out <dir>]
           [--as-live | --file-order] [--compare <sidecar.nav.jsonl> [--tolerance <m>] [--heading-tolerance <deg>]]
           [--write-sidecar <out.nav.jsonl>] [--pin-pair-window <s>] [--strict]
           [--roads <pack.roadpack>]... [--wrong-road-tolerance <m>]
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
var fileOrder = false
var comparePath: String?
var writeSidecarPath: String?
var tolerance = SidecarComparison.Tolerance.default
var pinPairWindow = NavigationReplay.defaultPinPairWindowS
var strict = false
var roadPaths: [String] = []
var wrongRoadTolerance: Double?

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
    case "--file-order":
        fileOrder = true
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
    case "--pin-pair-window":
        let seconds = number(value(), argument)
        guard seconds >= 0 else { fail("--pin-pair-window must be >= 0\n\(usage)", status: 2) }
        pinPairWindow = seconds
    case "--set":
        let pair = value().split(separator: "=", maxSplits: 1).map(String.init)
        guard pair.count == 2 else { fail("--set needs key=value\n\(usage)", status: 2) }
        overrides.append((pair[0], number(pair[1], "--set \(pair[0])")))
    case "--out":
        outPath = value()
    case "--strict":
        strict = true
    case "--roads":
        roadPaths.append(value())
    case "--wrong-road-tolerance":
        let metres = number(value(), argument)
        guard metres >= 0 else { fail("--wrong-road-tolerance must be >= 0\n\(usage)", status: 2) }
        wrongRoadTolerance = metres
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
if wrongRoadTolerance != nil && roadPaths.isEmpty {
    print("note: --wrong-road-tolerance has no effect without --roads")
}

// --roads: every pack fully verified (content hash and structure). The order
// given does not matter: RoadNetwork keeps them in content-hash order.
var roads: ReplayRoadSet?
if !roadPaths.isEmpty {
    var packs: [RoadPack] = []
    var names: [UInt64: String] = [:]
    for path in roadPaths {
        do {
            let url = URL(fileURLWithPath: path)
            let pack = try RoadPack(contentsOf: url, verify: true)
            packs.append(pack)
            names[pack.contentHash] = url.lastPathComponent
        } catch {
            fail("cannot read road pack \(path): \(error)", status: 1)
        }
    }
    do {
        roads = ReplayRoadSet(try RoadNetwork(packs: packs), names: names)
    } catch {
        fail("cannot use these road packs together: \(error)", status: 2)
    }
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

// R21.3-6: a value the engine refuses stops the replay before it starts;
// a value it clamps is listed, key by key.
let validated = config.validated(roads: roads?.network)
if let reason = validated.invalidReason {
    fail("invalid config: \(reason)", status: 2)
}
for change in ReplayReport.configChanges(from: config, to: validated) {
    print("note: config validation clamps \(change); the engine runs with the clamped value")
}
// --compare: the sidecar is read first; its roads line decides when the
// replay attaches the given packs.
var compareContents: NavSidecar.Contents?
if let comparePath {
    do {
        compareContents = try NavSidecar.read(contentsOf: URL(fileURLWithPath: comparePath))
    } catch {
        fail("cannot read sidecar \(comparePath): \(error)", status: 1)
    }
}
var roadAttach = ReplayRoadAttach.fromStart
if let contents = compareContents {
    roadAttach = contents.roads.map { .afterInputs($0.afterInputs) } ?? .live
} else if asLive {
    roadAttach = .live
}
var baseOptions = ReplayOptions(gps: gps, holdOutAccuracyM: holdOut, config: config)
baseOptions.roads = roads
baseOptions.roadAttach = roadAttach
if let wrongRoadTolerance { baseOptions.wrongRoadToleranceM = wrongRoadTolerance }
baseOptions.asLive = asLive
baseOptions.fileOrder = asLive || fileOrder
baseOptions.pinPairWindowS = pinPairWindow
if asLive && (gps != .use || holdOut != nil) {
    print("note: --as-live with \(baseOptions.label): the live app received every fix; this run withholds some")
}
let outDirectory = URL(fileURLWithPath: outPath)
do {
    try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
} catch {
    fail("cannot create \(outPath): \(error)", status: 1)
}

print("Config (\(seedFromHeader ? "seed from each log's header" : "seed \(config.seed)"), \(config.particleCount) particles\(asLive ? ", as live: file order" : fileOrder ? ", file order" : "")):")
print(ReplayReport.configJSON(config))
print("")
if let roads {
    print(ReplayReport.roadsText(roads.packs, roadSetHash: roads.roadSetHashHex))
    print("")
}
var compareFailed = false

var metrics: [ReplayMetrics] = []
for path in paths {
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    let inputs: [NavigationInput]
    let header: LogHeader
    let events: [LogEvent]
    let readReport: LogReadReport
    do {
        let reader = try LogFileReader(url: url, recovery: strict ? .strict : .skipMalformedLines)
        events = Array(reader)
        header = reader.header
        readReport = reader.report
    } catch {
        fail("cannot read \(path): \(error)", status: 1)
    }
    // R11.1-8: never replay a shortened or holed drive silently.
    print("Read          \(name): \(ReplayReport.readText(readReport))")
    let readProblems = ReplayReport.readProblems(readReport)
    if !readProblems.isEmpty {
        if strict {
            fail("\(path) is damaged (\(readProblems.joined(separator: "; "))); --strict refuses it; metrics.json and metrics.md are not updated", status: 3)
        }
        for problem in readProblems {
            print("Warning       \(name): \(problem); distance and the truth end are scored on what was read")
        }
    }
    inputs = baseOptions.fileOrder ? NavigationReplay.fileOrderInputs(from: events) : NavigationReplay.inputs(from: events)
    if let writeSidecarPath {
        // Exactly the app's loop: file order, header seed, default config,
        // the given packs attached by the live rule.
        do {
            let writer = try NavSidecarWriter(url: URL(fileURLWithPath: writeSidecarPath))
            var count = 0
            var selections = 0
            let run = NavigationReplay.runLive(
                inputs: NavigationReplay.fileOrderInputs(from: events), sessionID: header.sessionID,
                config: NavigationConfig(seed: NavigationSeed.derive(header: header)), appBuild: "replay_nav",
                roads: roads, attach: .live
            ) { line in
                if case .roadsSelection = line { selections += 1 }
                writer.append(line)
                count += 1
                if count >= 1_000 { writer.flush(); count = 0 }
            }
            writer.close()
            if let failure = writer.failure { fail("cannot write \(writeSidecarPath): \(failure)", status: 1) }
            print("Sidecar       wrote \(writeSidecarPath): \(run.estimates) estimates, \(writer.bytesWritten) bytes (as the app would, no drops)"
                  + (roads == nil ? "" : run.roads.map { "; roads attached after \($0.afterInputs) inputs, roadSetHash \($0.network.roadSetHashHex)" }
                     ?? "; no roads attached (no given pack covered a selection request)")
                  + (roads == nil ? "" : "; \(selections) roadsSelection line(s) for \(run.selectionLog.attempts) attempt(s)"))
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
    print(ReplayReport.summary(result), terminator: "")
    if roads != nil && options.roadAttach != .fromStart {
        print("Roads attach  " + (result.roadsAttachedAfterInputs.map {
            "after \($0) inputs given to the engine, roadSetHash \(result.attachedRoadSetHash ?? "n/a")"
        } ?? "none (no selection request met a covering pack set)"))
    }
    print("")
    metrics.append(ReplayMetrics(result))
    let stem = name.hasSuffix(".jsonl.gz") ? String(name.dropLast(9)) : name
    let geoURL = outDirectory.appendingPathComponent("\(stem)-\(options.label).geojson")
    do {
        try ReplayReport.geoJSON(result).write(to: geoURL)
        print("GeoJSON       \(geoURL.path)\n")
    } catch {
        fail("cannot write \(geoURL.path): \(error)", status: 1)
    }

    if let comparePath, let contents = compareContents {
        if contents.header.sessionID != header.sessionID {
            print("Warning       the sidecar's sessionID is not this recording's")
        }
        // The app's loop over exactly the inputs this replay gave its engine.
        let motionStart = NavigationReplay.motionStart(inputs)
        let given = inputs.filter { input in
            guard case .location(let sample, let t) = input else { return true }
            return NavigationReplay.withholdReason(sample, at: t, options: options, motionStart: motionStart) == nil
        }
        let lines = NavigationReplay.liveLines(inputs: given, sessionID: header.sessionID, config: options.config,
                                               roads: roads, attach: options.roadAttach)
        let comparison = SidecarComparison(
            sidecar: contents, replay: lines, replayConfig: NavigationEngine(config: options.config).config,
            encodingFailures: NavigationReplay.encodingFailures(in: events).count,
            givenRoadSetHash: roads?.roadSetHashHex
        )
        print("Sidecar       \(URL(fileURLWithPath: comparePath).lastPathComponent): v\(contents.header.sidecarVersion), \(contents.estimates.count) estimates, \(contents.pins.count) pins, app build \(contents.header.appBuild) (\(contents.header.buildConfiguration ?? "build configuration not recorded"))\(asLive ? "" : fileOrder ? " (--file-order, not --as-live)" : " (not --as-live: arrival order)")")
        print(comparison.report(tolerance: tolerance))
        if !comparison.passes(tolerance) { compareFailed = true }
    }
}

let jsonURL = outDirectory.appendingPathComponent("metrics.json")
let markdownURL = outDirectory.appendingPathComponent("metrics.md")
do {
    var existing: Data?
    if FileManager.default.fileExists(atPath: jsonURL.path) {
        do {
            existing = try Data(contentsOf: jsonURL)
        } catch {
            fail("cannot read the existing \(jsonURL.path) (\(error)); left unchanged, metrics not written", status: 1)
        }
    }
    if let existing, let reason = ReplayReport.existingMetricsDecodeError(existing) {
        // Keep the old rows instead of replacing them silently (R11.2-4).
        // Claim the copy only once it is written, and never overwrite an
        // older copy (R18.1-2); without a copy, metrics.json stays as it is.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = "\(formatter.string(from: Date()))-\(ProcessInfo.processInfo.processIdentifier)"
        let backup: URL
        do {
            backup = try ReplayReport.keepUndecodableMetrics(existing, in: outDirectory, stamp: stamp)
        } catch {
            fail("\(jsonURL.path) does not decode (\(reason)) and no copy could be written (\(error)); left unchanged, metrics not written", status: 1)
        }
        print("Warning       \(jsonURL.path) does not decode (\(reason)); its rows are dropped from the merge, copy kept at \(backup.path)")
    }
    let merged = try ReplayReport.mergedMetrics(existing: existing, adding: metrics)
    try ReplayReport.metricsJSON(merged).write(to: jsonURL)
    try Data(ReplayReport.markdown(merged).utf8).write(to: markdownURL)
    print("Metrics       \(markdownURL.path), \(jsonURL.path) (\(merged.count) runs)")
} catch {
    fail("cannot write metrics: \(error)", status: 1)
}
if compareFailed { exit(4) }
