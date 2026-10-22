import DriveLoggerCore
import Foundation

// replay_nav — replay recordings through the navigation engine on the Mac.
//
//   swift run -c release replay_nav <log.jsonl.gz>... [--gps use|mask-after <s>|mask-after-motion <s>|none]
//       [--hold-out-acc <m>] [--truth logs/truth.json] [--seed N|header] [--particles N]
//       [--set <configKey>=<number>]... [--out logs/out]
//       [--as-live | --file-order] [--compare <log.nav.jsonl> [--tolerance <m>] [--heading-tolerance <deg>]]
//       [--write-sidecar <out.nav.jsonl>] [--pin-pair-window <s>] [--strict]
//       [--roads <pack.roadpack>]... [--inject-roads <s>|after-<n>:<pack.roadpack>]... [--wrong-road-tolerance <m>]
//       [--fix-offset <from>:<to>|auto[:<len>:<step>]]... [--fix-source any|accessory|phone]
//       [--fix-offset-max <m>] [--fix-offset-step <m>] [--fix-max-acc <m>] [--fix-offset-stat mean|median]
//       [--fix-offset-course <deg>|off] [--fix-offset-test <m>@<deg>]... [--fix-offset-trace]
//       [--fixpin-inject <out.jsonl> [--fixpin-two-pins] [--fixpin-survey] [--fixpin-pins <n>] [--fixpin-separation <s>] [--fixpin-engine-no-roads]]
//       [--save-prior <state.json> [--save-prior-at <s>|end] [--save-prior-engine-off]]
//       [--prior <state.json> [--prior-offset <dE>,<dN>]] [--start-at <s>] [--no-prior]
//
// Prompt 40, the Navigate → Record hand-over (log v5): a recording that
// carries a `navPrior` row started its live run from that prior, so every
// replay of it does too (`ReplayRecordedPrior`): the metrics replay,
// --as-live, --compare and --write-sidecar alike; the label gets -prior.
// An explicit --prior replaces the row (a printed note; label -restored);
// --no-prior ignores it (a printed note: the run starts fresh, not as the
// live run did). A recording without the row (every recording before v5)
// replays exactly as before; --no-prior then changes nothing.
//
// UX-20 restore, replay only (one log): --save-prior writes the restore
// state (`NavigationRestoreState`, the app's persisted form) captured at
// --save-prior-at (session seconds, default end: the last input) from this
// run; --save-prior-engine-off classifies it as the app does after an
// ignition-off auto-stop. --prior seeds the engine from a saved state, its
// age on this recording's clock (`SessionClock(header:)`, no boot session:
// wall clock only) at --start-at, or at the first input; a state older than
// 24 h (or from the future) is not restored, as in the app. --prior-offset
// moves the saved position dE, dN metres first (a car moved while the app
// was not running). --start-at drops every input arriving before it (the
// app was not running). Labels: -from-<s>, -restored.
// --fixpin-inject (one log, needs --roads): the N3-FIXPIN injection study
// (`FixPinInjection`), no metrics files. Picks pin times (genuine GNSS
// rings, road context straight/junction/parallel, clear of recorded pins and
// of the truth file's excludeFixes), then per pin time runs every
// sensitivity case (fixes shifted 100/200/335/500 m × 8 bearings from 90 s
// before the pin to 30 s after it, pin at the genuine position) and
// specificity case (genuine fixes, pin displaced 30/75/150/300 m × 8) with
// the run's config (--seed, --set), --gps use, roads from the first input,
// and writes one JSON line per case: the engine's decision at the pin,
// the prior error and the error at the end of the window. --fixpin-two-pins:
// a second pin after ≥ 330 m and ≥ 55° of turn (pin times without one are
// skipped). --fixpin-survey: print the pin times only. --fixpin-pins
// (default 6) pin times at least --fixpin-separation s (default 60) apart.
// --fixpin-engine-no-roads: the engine runs without roads (the packs still
// pick and classify the pin times). With --fixpin-two-pins, sensitivity adds
// a genuine third pin 60 s after the second (the prior after the verdict),
// and specificity runs pin 2 displaced like pin 1 on the map, in the car's
// frame, and genuine. Relative metres,
// bearings and session seconds only.
// --fix-offset (repeatable, needs --roads): analysis only, no engine, no
// metrics files; the engine run's flags (--gps, --truth, --out, --compare,
// --write-sidecar, --set, …: `FixOffsetScan.engineOnlyFlags`) are refused
// with it (status 2). For each window of clean fixes (≤ 15 m, session seconds;
// `auto` = sliding windows, default 60 s every 30 s) from --fix-source
// (default any; accessory = `isProducedByAccessory` fixes, phone = the
// rest), prints the capped distance-to-road distribution of the recorded
// track, the best constant shift within ±--fix-offset-max (default 400 m,
// coarse step --fix-offset-step, default 10 m, then 1 m) and where both
// stand among every grid shift's score (`FixOffsetScan`); for each explicit
// window also the fixes' dynamics (path vs OBD distance, speed vs OBD,
// course change vs gyro yaw), and each pin against the time-nearest clean
// fix. --fix-max-acc widens the accuracy limit (the run is then not the
// clean-fix rule, and says so). Shifts are ranked by the mean capped
// distance (--fix-offset-stat); a moving fix with a course counts only roads
// within --fix-offset-course degrees of it (default 30, off: any road).
// --fix-offset-test (repeatable) scores a hypothesis shift — e.g. a pin's
// vector — in every window and ranks it among the grid shifts.
// --fix-offset-trace: for each explicit window, every fix's time, accuracy,
// speed and capped distance to the nearest road as recorded.
// Only relative metres and bearings are printed, never a position.
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
//   The given packs are also watched by the coverage trigger: once the
//   estimate's circle enters a given pack not attached yet, the attached
//   set is extended to it at that input (prompt 38);
// - with --compare: at each of the sidecar's `roads` lines (`afterInputs`),
//   that line's packs taken from the given ones (the first attached, later
//   ones extending it; the mode label gets -attach-sidecar), so --roads
//   must list every pack of every line (more are fine); with a sidecar that
//   used no roads, the live rule above (-attach-live unless --as-live). A
//   sidecar pack not given, packs on one side only, or roads lines that
//   differ is a warning naming the hashes, and the verdict is never PASS
//   (exact).
// --inject-roads <when>:<pack> (repeatable, replay only, prompt 38): a pack
// the live rule cannot select until <when> — session seconds (before the
// first input arriving then or later) or after-<n> (after n inputs given
// to the engine) — when it arrives as the app's library change does: the
// run watches it and raises a `libraryChanged` selection request at once,
// which attaches it or extends the attached set. The pack is part of the
// given set (road truth, label) and the run uses the live rule (label
// -attach-live unless --as-live, plus -inject-<hash>-<when>); also for
// --write-sidecar. Not with --compare (which follows the sidecar).
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
// A window other than 3 adds -pair-window-<s> to the mode label.
// A truth-file `scoreUntilT` (session seconds) leaves every checkpoint after
// it listed but unscored (the truth `end` included); also scoring only.
// Truth-file `excludeFixes` ranges ({fromT, toT}, inclusive) make the fixes
// in them never truth (no clean-fix checkpoint, no road truth) in any --gps
// mode; the engine still gets what --gps gives it.
// --seed header: each log's seed is derived from its header's sessionID
// (`NavigationSeed`), as the live app does. --as-live: replay as the app ran
// live — inputs in file order (the tap's order), the header's seed and the
// default config (no --seed, --particles or --set). --file-order: inputs
// in file order, as live, with any seed and config (a seed sweep of the live
// order); the label gets -file-order. --compare: run the
// app's per-recording loop (`LiveNavigationRun`) over the same inputs and
// compare its 1 Hz estimates and pins with the sidecar the app wrote (one
// log only; sidecar v1, v2 or v3); see docs/NAV_SIDECAR.md. Without roads on
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
           [--roads <pack.roadpack>]... [--inject-roads <s>|after-<n>:<pack.roadpack>]... [--wrong-road-tolerance <m>]
           [--fix-offset <from>:<to>|auto[:<len>:<step>]]... [--fix-source any|accessory|phone]
           [--fix-offset-max <m>] [--fix-offset-step <m>] [--fix-max-acc <m>] [--fix-offset-stat mean|median]
           [--fix-offset-course <deg>|off] [--fix-offset-test <m>@<deg>]... [--fix-offset-trace]
           [--fixpin-inject <out.jsonl> [--fixpin-two-pins] [--fixpin-survey] [--fixpin-pins <n>] [--fixpin-separation <s>] [--fixpin-engine-no-roads]]
           [--save-prior <state.json> [--save-prior-at <s>|end] [--save-prior-engine-off]]
           [--prior <state.json> [--prior-offset <dE>,<dN>]] [--start-at <s>] [--no-prior]
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
var injectRoads: [(when: ReplayRoadInjection.When, path: String)] = []
var wrongRoadTolerance: Double?
enum FixOffsetWindow { case explicit(Double, Double), auto(lengthS: Double, stepS: Double) }
var fixOffsetWindows: [FixOffsetWindow] = []
var fixSource = FixOffsetScan.Source.any
var fixOffsetOptions = FixOffsetScan.Options()
var fixMaxAccuracy = NavigationReplay.cleanFixTruthAccM
var fixOffsetTrace = false
var fixPinInjectPath: String?
var fixPinTwoPins = false
var fixPinSurvey = false
var fixPinEngineRoads = true
var fixPinOptions = FixPinInjection.Options()
var givenFlags: [String] = []
var savePriorPath: String?
var savePriorAt = Double.infinity
var savePriorEngineOff = false
var priorPath: String?
var priorOffset: (east: Double, north: Double)?
var startAt: Double?
var noPrior = false

func number(_ text: String, _ flag: String) -> Double {
    guard let value = Double(text), value.isFinite else { fail("\(flag) needs a number, got \(text)\n\(usage)", status: 2) }
    return value
}

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    if argument.hasPrefix("--") { givenFlags.append(argument) }
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
    case "--inject-roads":
        let text = value()
        guard let colon = text.firstIndex(of: ":") else { fail("--inject-roads needs <s>|after-<n>:<pack>\n\(usage)", status: 2) }
        let whenText = String(text[..<colon]), path = String(text[text.index(after: colon)...])
        let when: ReplayRoadInjection.When
        if whenText.hasPrefix("after-") {
            guard let n = Int(whenText.dropFirst("after-".count)), n >= 0 else {
                fail("--inject-roads after-<n> needs a whole number >= 0\n\(usage)", status: 2)
            }
            when = .afterInputs(n)
        } else {
            let seconds = number(whenText, argument)
            guard seconds >= 0 else { fail("--inject-roads seconds must be >= 0\n\(usage)", status: 2) }
            when = .time(seconds: seconds)
        }
        guard !path.isEmpty else { fail("--inject-roads needs a pack path\n\(usage)", status: 2) }
        injectRoads.append((when, path))
    case "--wrong-road-tolerance":
        let metres = number(value(), argument)
        guard metres >= 0 else { fail("--wrong-road-tolerance must be >= 0\n\(usage)", status: 2) }
        wrongRoadTolerance = metres
    case "--fix-offset":
        let text = value()
        let parts = text.split(separator: ":").map(String.init)
        if parts.first == "auto" {
            guard parts.count == 1 || parts.count == 3 else { fail("--fix-offset auto[:<len>:<step>]\n\(usage)", status: 2) }
            let length = parts.count == 3 ? number(parts[1], argument) : 60
            let step = parts.count == 3 ? number(parts[2], argument) : 30
            guard length > 0, step > 0 else { fail("--fix-offset auto needs a positive length and step\n\(usage)", status: 2) }
            fixOffsetWindows.append(.auto(lengthS: length, stepS: step))
        } else {
            guard parts.count == 2 else { fail("--fix-offset needs <from>:<to> or auto\n\(usage)", status: 2) }
            let from = number(parts[0], argument), to = number(parts[1], argument)
            guard to > from else { fail("--fix-offset \(text): <to> must be after <from>\n\(usage)", status: 2) }
            fixOffsetWindows.append(.explicit(from, to))
        }
    case "--fix-source":
        let name = value()
        guard let source = FixOffsetScan.Source(rawValue: name) else { fail("unknown --fix-source \(name)\n\(usage)", status: 2) }
        fixSource = source
    case "--fix-offset-max":
        let metres = number(value(), argument)
        guard metres > 0 else { fail("--fix-offset-max must be > 0\n\(usage)", status: 2) }
        fixOffsetOptions.maxShiftM = metres
    case "--fix-offset-step":
        let metres = number(value(), argument)
        guard metres >= 1 else { fail("--fix-offset-step must be >= 1\n\(usage)", status: 2) }
        fixOffsetOptions.coarseStepM = metres
    case "--fix-max-acc":
        let metres = number(value(), argument)
        guard metres > 0 else { fail("--fix-max-acc must be > 0\n\(usage)", status: 2) }
        fixMaxAccuracy = metres
    case "--fix-offset-stat":
        let name = value()
        guard let statistic = FixOffsetScan.Statistic(rawValue: name) else { fail("unknown --fix-offset-stat \(name)\n\(usage)", status: 2) }
        fixOffsetOptions.statistic = statistic
    case "--fix-offset-course":
        let text = value()
        if text == "off" {
            fixOffsetOptions.courseToleranceDeg = nil
        } else {
            let degrees = number(text, argument)
            guard degrees > 0, degrees <= 90 else { fail("--fix-offset-course must be in (0, 90] or off\n\(usage)", status: 2) }
            fixOffsetOptions.courseToleranceDeg = degrees
        }
    case "--fix-offset-trace":
        fixOffsetTrace = true
    case "--fixpin-inject":
        fixPinInjectPath = value()
    case "--fixpin-two-pins":
        fixPinTwoPins = true
    case "--fixpin-survey":
        fixPinSurvey = true
    case "--fixpin-engine-no-roads":
        fixPinEngineRoads = false
    case "--fixpin-pins":
        let n = number(value(), argument)
        guard n >= 1, n == n.rounded() else { fail("--fixpin-pins must be a positive integer\n\(usage)", status: 2) }
        fixPinOptions.pinsPerLog = Int(n)
    case "--fixpin-separation":
        let seconds = number(value(), argument)
        guard seconds >= 0 else { fail("--fixpin-separation must be >= 0\n\(usage)", status: 2) }
        fixPinOptions.minSeparationS = seconds
    case "--fix-offset-test":
        let parts = value().split(separator: "@").map(String.init)
        guard parts.count == 2 else { fail("--fix-offset-test needs <m>@<deg>\n\(usage)", status: 2) }
        let metres = number(parts[0], argument), degrees = number(parts[1], argument) * .pi / 180
        fixOffsetOptions.tested.append(FixOffsetScan.Shift(east: metres * sin(degrees), north: metres * cos(degrees)))
    case "--save-prior":
        savePriorPath = value()
    case "--save-prior-at":
        let text = value()
        savePriorAt = text == "end" ? .infinity : number(text, argument)
    case "--save-prior-engine-off":
        savePriorEngineOff = true
    case "--prior":
        priorPath = value()
    case "--prior-offset":
        let parts = value().split(separator: ",").map(String.init)
        guard parts.count == 2 else { fail("--prior-offset needs <dE>,<dN> metres\n\(usage)", status: 2) }
        priorOffset = (number(parts[0], argument), number(parts[1], argument))
    case "--start-at":
        startAt = number(value(), argument)
    case "--no-prior":
        noPrior = true
    case "-h", "--help":
        print(usage)
        exit(EXIT_SUCCESS)
    default:
        guard !argument.hasPrefix("--") else { fail("unexpected argument \(argument)\n\(usage)", status: 2) }
        paths.append(argument)
    }
}
guard !paths.isEmpty else { fail(usage, status: 2) }
// R35.2-3: --fix-offset runs no engine and writes no metrics, so an engine
// flag with it would be silently ignored.
if !fixOffsetWindows.isEmpty {
    let refused = FixOffsetScan.refusedFlags(givenFlags)
    guard refused.isEmpty else {
        fail("--fix-offset is the offset scan only (no engine, no metrics files): drop \(refused.joined(separator: ", "))\n\(usage)", status: 2)
    }
}
if asLive {
    guard !explicitSeed, !explicitParticles, overrides.isEmpty else {
        fail("--as-live replays the live app: the header's seed and the default config; drop --seed N, --particles and --set\n\(usage)", status: 2)
    }
    seedFromHeader = true
}
if (savePriorPath != nil || priorPath != nil || startAt != nil) && paths.count != 1 {
    fail("--save-prior, --prior and --start-at take exactly one log\n\(usage)", status: 2)
}
if (priorPath != nil || startAt != nil) && (comparePath != nil || writeSidecarPath != nil) {
    fail("--prior and --start-at are replay only: drop --compare / --write-sidecar\n\(usage)", status: 2)
}
if priorOffset != nil && priorPath == nil {
    fail("--prior-offset needs --prior\n\(usage)", status: 2)
}
var restoreState: NavigationRestoreState?
if let priorPath {
    do {
        restoreState = try NavigationRestoreState.decode(Data(contentsOf: URL(fileURLWithPath: priorPath)))
    } catch {
        fail("cannot use the saved state \(priorPath): \(error)", status: 1)
    }
    if let offset = priorOffset { restoreState = restoreState?.shifted(eastM: offset.east, northM: offset.north) }
}
if (comparePath != nil || writeSidecarPath != nil) && paths.count != 1 {
    fail("--compare and --write-sidecar take exactly one log\n\(usage)", status: 2)
}
if !injectRoads.isEmpty && comparePath != nil {
    fail("--inject-roads replays a library change; --compare follows the sidecar's roads lines: drop one\n\(usage)", status: 2)
}
if wrongRoadTolerance != nil && roadPaths.isEmpty && injectRoads.isEmpty {
    print("note: --wrong-road-tolerance has no effect without --roads")
}

// --roads: every pack fully verified (content hash and structure). The order
// given does not matter: RoadNetwork keeps them in content-hash order.
var roads: ReplayRoadSet?
var injections: [ReplayRoadInjection] = []
if !roadPaths.isEmpty || !injectRoads.isEmpty {
    var packs: [RoadPack] = []
    var names: [UInt64: String] = [:]
    func load(_ path: String) -> RoadPack {
        do {
            let url = URL(fileURLWithPath: path)
            let pack = try RoadPack(contentsOf: url, verify: true)
            packs.append(pack)
            names[pack.contentHash] = url.lastPathComponent
            return pack
        } catch {
            fail("cannot read road pack \(path): \(error)", status: 1)
        }
    }
    for path in roadPaths { _ = load(path) }
    for (when, path) in injectRoads {
        let pack = load(path)
        injections.append(ReplayRoadInjection(when: when, contentHashes: [pack.contentHash]))
    }
    do {
        roads = ReplayRoadSet(try RoadNetwork(packs: packs), names: names)
    } catch {
        fail("cannot use these road packs together: \(error)", status: 2)
    }
}

// --fix-offset: the constant-offset scan only, then stop.
if !fixOffsetWindows.isEmpty {
    guard let network = roads?.network else { fail("--fix-offset needs --roads\n\(usage)", status: 2) }
    print(ReplayReport.roadsText(roads!.packs, roadSetHash: roads!.roadSetHashHex))
    print("Fix offset    fixes ≤ \(fixMaxAccuracy) m\(fixMaxAccuracy == NavigationReplay.cleanFixTruthAccM ? " (clean)" : " (not the clean-fix rule)"), source \(fixSource.rawValue); shifts ±\(fixOffsetOptions.maxShiftM) m step \(fixOffsetOptions.coarseStepM) m then \(fixOffsetOptions.fineStepM) m; distances capped at \(fixOffsetOptions.capM) m; ranked by \(fixOffsetOptions.statistic.rawValue); course gate \(fixOffsetOptions.courseToleranceDeg.map { "\($0)° at ≥ \(fixOffsetOptions.courseMinSpeedMps) m/s" } ?? "off")")
    print("              mean/p50/p90 = capped distance to the nearest road; rank = share of grid shifts scoring ≤ the recorded track")
    for path in paths {
        let url = URL(fileURLWithPath: path)
        let events: [LogEvent]
        do {
            let reader = try LogFileReader(url: url, recovery: strict ? .strict : .skipMalformedLines)
            events = Array(reader)
            print("\nRead          \(url.lastPathComponent): \(ReplayReport.readText(reader.report))")
        } catch {
            fail("cannot read \(path): \(error)", status: 1)
        }
        let all = FixOffsetScan.cleanFixes(from: events, maxAccuracyM: fixMaxAccuracy)
        let fixes = all.filter { fixSource.admits($0.accessory) }
        let accessory = all.filter { $0.accessory == true }.count
        print("Fixes         \(all.count) (accessory \(accessory), other \(all.count - accessory)); scanned \(fixes.count)")
        guard !fixes.isEmpty else { continue }
        let obd = FixOffsetScan.obdSpeed(from: events)
        let yaw = FixOffsetScan.yawRate(from: events)
        var explicitWindows: [(Double, Double)] = []
        print(FixOffsetScan.windowHeader)
        for request in fixOffsetWindows {
            let windows: [(from: Double, to: Double)]
            switch request {
            case .explicit(let from, let to):
                windows = [(from, to)]
                explicitWindows.append((from, to))
            case .auto(let length, let step):
                windows = FixOffsetScan.slidingWindows(over: fixes, lengthS: length, stepS: step)
            }
            for w in windows {
                let inside = fixes.filter { $0.t >= w.from && $0.t < w.to }
                if let result = FixOffsetScan.scan(inside, roads: network, options: fixOffsetOptions) {
                    print(FixOffsetScan.text(result))
                    FixOffsetScan.testedText(result).forEach { print($0) }
                } else {
                    print(String(format: "%.1f–%.1f", w.from, w.to) + "  \(inside.count) fixes: too few to scan")
                }
            }
        }
        for (from, to) in explicitWindows {
            let inside = fixes.filter { $0.t >= from && $0.t < to }
            guard inside.count >= 2 else { continue }
            if fixOffsetTrace, let w = FixOffsetScan.scan(inside, roads: network, options: fixOffsetOptions) {
                print(String(format: "Trace         %.1f–%.1f s: t s, accuracy m, speed m/s, distance to road m (recorded)", from, to))
                for (fix, d) in zip(inside, w.recordedDistancesM) {
                    print(String(format: "  %8.1f  %5.1f  %5.1f  %5.1f", fix.t, fix.accuracyM, fix.speed, d))
                }
            }
            print(String(format: "Dynamics      %.1f–%.1f s: ", from, to) + FixOffsetScan.text(FixOffsetScan.dynamics(inside, obdSpeed: obd, yawRate: yaw)))
        }
        let pins: [(t: Double, latitude: Double, longitude: Double)] = events.compactMap { event in
            guard case .manualFix(let pin) = event.payload else { return nil }
            return (event.timestamp.seconds, pin.latitude, pin.longitude)
        }
        for check in FixOffsetScan.pinChecks(pins: pins, fixes: fixes) {
            print("Pin           " + FixOffsetScan.text(check))
        }
        if pins.count > 0 { print("Pins          \(pins.count), of which \(FixOffsetScan.pinChecks(pins: pins, fixes: fixes).count) within 5 s of a scanned fix") }
    }
    exit(EXIT_SUCCESS)
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
// --fixpin-inject: the injection study only, then stop.
if let fixPinInjectPath {
    guard let network = roads?.network else { fail("--fixpin-inject needs --roads\n\(usage)", status: 2) }
    guard paths.count == 1 else { fail("--fixpin-inject takes one log\n\(usage)", status: 2) }
    let url = URL(fileURLWithPath: paths[0])
    let events: [LogEvent]
    do {
        let reader = try LogFileReader(url: url, recovery: strict ? .strict : .skipMalformedLines)
        events = Array(reader)
        print("Read          \(url.lastPathComponent): \(ReplayReport.readText(reader.report))")
    } catch {
        fail("cannot read \(paths[0]): \(error)", status: 1)
    }
    let inputs = NavigationReplay.inputs(from: events)
    let excluded = truth?.entry(forLog: url.lastPathComponent)?.excludeFixes ?? []
    let options = fixPinOptions
    let pinTimes = FixPinInjection.pinTimes(inputs, roads: network, options: options, excluded: excluded)
    print("Config        seed \(config.seed), roadFixPinCheck \(config.roadFixPinCheck), fixPinTwoPinCheck \(config.fixPinTwoPinCheck), "
          + "roadFixPinOffRoadM \(config.roadFixPinOffRoadM), roadFixPinMarginM \(config.roadFixPinMarginM)")
    print("Pin times     \(pinTimes.count)\(excluded.isEmpty ? "" : " (\(excluded.count) excluded fix range(s) avoided)")")
    for p in pinTimes {
        let flags = (p.junction ? "J" : "-") + (p.parallel ? "P" : "-")
        print(String(format: "  t %7.1f  ", p.t) + p.context.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
              + " \(flags) \(p.source) ring \(p.ringFixes) fixes " + String(format: "%.0f m  v %.1f m/s", p.ringPathM, p.speedMps)
              + "  second pin " + (p.secondT.map { String(format: "%.1f", $0) } ?? "none (minimums not met)")
              + (p.thirdT.map { String(format: "  third %.1f", $0) } ?? ""))
    }
    if fixPinSurvey { exit(EXIT_SUCCESS) }
    FileManager.default.createFile(atPath: fixPinInjectPath, contents: nil)
    guard let handle = FileHandle(forWritingAtPath: fixPinInjectPath) else { fail("cannot write \(fixPinInjectPath)", status: 1) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var count = 0
    let cases = FixPinInjection.cases(options, twoPins: fixPinTwoPins)
    _ = FixPinInjection.run(inputs: inputs, config: config, roads: fixPinEngineRoads ? network : nil, pinTimes: pinTimes, cases: cases,
                            options: options) { outcome in
        if let data = try? encoder.encode(outcome) { handle.write(data + Data("\n".utf8)) }
        count += 1
    }
    handle.closeFile()
    print("Cases         \(count) written to \(fixPinInjectPath)")
    exit(EXIT_SUCCESS)
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
    roadAttach = contents.roads.isEmpty ? .live : .schedule(contents.roads.compactMap(ReplayRoadAttachPoint.init))
} else if asLive || !injections.isEmpty {
    roadAttach = .live
}
var baseOptions = ReplayOptions(gps: gps, holdOutAccuracyM: holdOut, config: config)
baseOptions.roads = roads
baseOptions.roadAttach = roadAttach
baseOptions.roadInjections = injections
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
    // Prompt 40: the recording's navPrior row, the live run's start
    // condition (absent: everything below is exactly as before v5).
    let recordedPrior = ReplayRecordedPrior.choose(row: NavigationReplay.recordedPrior(in: events),
                                                   explicitPrior: priorPath != nil, noPrior: noPrior)
    if let note = recordedPrior.note(firstInput: recordedPrior.startInput(in: inputs)) { print(note) }
    if case .absent = recordedPrior, noPrior { print("note: --no-prior: \(name) has no navPrior row; nothing to ignore") }
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
                roads: roads, attach: .live, injections: injections, prior: recordedPrior.prior
            ) { line in
                if case .roadsSelection = line { selections += 1 }
                writer.append(line)
                count += 1
                if count >= 1_000 { writer.flush(); count = 0 }
            }
            writer.close()
            if let failure = writer.failure { fail("cannot write \(writeSidecarPath): \(failure)", status: 1) }
            print("Sidecar       wrote \(writeSidecarPath): \(run.estimates) estimates, \(writer.bytesWritten) bytes (as the app would, no drops)"
                  + (roads == nil ? "" : run.attachments.isEmpty ? "; no roads attached (no given pack covered a selection request)"
                     : run.attachments.enumerated().map { "; roads \($0.offset == 0 ? "attached" : "extended") after \($0.element.afterInputs) inputs, roadSetHash \($0.element.network.roadSetHashHex)" }.joined())
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
    options.startAtS = startAt
    if let prior = recordedPrior.prior {
        options.prior = prior
        options.priorSource = .recording
    }
    if let restoreState {
        // Its age on this recording's clock at the start (the first input
        // given, or --start-at).
        let start = startAt.map { MonotonicTimestamp(seconds: $0) }
            ?? inputs.first { !$0.isGPSSwitch }?.arrival ?? .zero
        let first = inputs.first { $0.arrival >= start && !$0.isGPSSwitch }?.arrival ?? start
        options.prior = restoreState.prior(at: first, clock: SessionClock(header: header), bootSessionID: nil)
        if let prior = options.prior {
            print(String(format: "Prior         %@, saved %.1f s before t %.1f s (class %@)", priorPath ?? "",
                         first.seconds - prior.savedT.seconds, first.seconds, prior.restoreClass.rawValue)
                  + (priorOffset.map { String(format: ", moved %.0f m E, %.0f m N", $0.east, $0.north) } ?? ""))
        } else {
            print("note: the saved state is not restorable here (older than 24 h, from the future, or invalid): no prior")
            options.prior = nil
        }
    }
    if savePriorPath != nil {
        options.savePrior = ReplaySavePrior(atS: savePriorAt, header: header, engineOff: savePriorEngineOff)
    }
    let result = NavigationReplay.run(logName: name, inputs: inputs, options: options, truth: entry)
    if let savePriorPath {
        if let state = result.savedRestoreState {
            do {
                try state.encoded().write(to: URL(fileURLWithPath: savePriorPath))
                print("Saved prior   \(savePriorPath): class \(state.restoreClass.rawValue), converged \(state.converged)"
                      + String(format: ", σhead %.1f°", state.headingStdDeg))
            } catch {
                fail("cannot write \(savePriorPath): \(error)", status: 1)
            }
        } else {
            print("note: no estimate at --save-prior-at: no state written")
        }
    }
    if result.counters.inputsRejectedTimeJump > 0 {
        print("note: \(result.counters.inputsRejectedTimeJump) input(s) rejected as implausible forward time jumps")
    }
    print(ReplayReport.summary(result), terminator: "")
    if roads != nil && options.roadAttach != .fromStart {
        print("Roads attach  " + (result.roadsAttachedAfterInputs.map {
            "after \($0) inputs given to the engine, roadSetHash \(result.attachedRoadSetHash ?? "n/a")"
        } ?? "none (no selection request met a covering pack set)")
              + (result.roadsExtendedAfterInputs.isEmpty ? ""
                 : "; extended after " + result.roadsExtendedAfterInputs.map(String.init).joined(separator: ", ") + " inputs"))
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
                                               roads: roads, attach: options.roadAttach, prior: options.prior)
        let comparison = SidecarComparison(
            sidecar: contents, replay: lines, replayConfig: NavigationEngine(config: options.config).config,
            encodingFailures: NavigationReplay.encodingFailures(in: events).count,
            givenRoadSetHash: roads?.roadSetHashHex,
            givenPackHashes: roads.map { Set($0.network.packs.map { NavigationSeed.hex($0.contentHash) }) }
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
