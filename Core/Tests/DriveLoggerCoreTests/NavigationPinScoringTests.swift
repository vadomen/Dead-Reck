import Foundation
import Testing

@testable import DriveLoggerCore

/// N3.0 step 1: refinement pairs and truth-file pin exclusion are scoring
/// only. The engine ingests every pin; only which checkpoints count changes.
@Suite("Navigation pin scoring")
struct NavigationPinScoringTests {
    typealias S = SyntheticDrive

    static func times(_ seconds: [Double]) -> [MonotonicTimestamp] { seconds.map(S.ms) }

    // MARK: The rule

    @Test("Two pins 1.5 s apart: the second is a refinement of the first, which is scored")
    func pairFolding() {
        let (notScored, unmatched) = NavigationReplay.pinScoring(manualFixTimes: Self.times([100, 101.5]), pairWindowS: 3)
        #expect(notScored[0] == nil)
        #expect(notScored[1] == .init(reason: .refinement, firstPinT: 100))
        #expect(unmatched.isEmpty)
        // Pins farther apart than the window are both scored; the boundary is inclusive.
        #expect(NavigationReplay.pinScoring(manualFixTimes: Self.times([100, 103.001]), pairWindowS: 3).notScored == [nil, nil])
        #expect(NavigationReplay.pinScoring(manualFixTimes: Self.times([100, 103]), pairWindowS: 3).notScored[1]?.reason == .refinement)
    }

    @Test("A chain folds onto its first pin: each gap is to the previous pin, scored or not; a new chain starts after a longer gap")
    func chains() {
        // 0, 2, 4 s: 4 is 4 s from the first pin but 2 s from the previous one.
        let t = [10.0, 12, 14, 30, 31, 40]
        let notScored = NavigationReplay.pinScoring(manualFixTimes: Self.times(t), pairWindowS: 3).notScored
        #expect(notScored.map { $0?.reason } == [nil, .refinement, .refinement, nil, .refinement, nil])
        #expect(notScored.map { $0?.firstPinT } == [nil, 10, 10, nil, 30, nil])
        // Input order does not matter: the result follows the input's order.
        let shuffled = [31.0, 10, 40, 14, 30, 12]
        let s = NavigationReplay.pinScoring(manualFixTimes: Self.times(shuffled), pairWindowS: 3).notScored
        #expect(s.map { $0?.reason } == [.refinement, nil, nil, .refinement, nil, .refinement])
        // Two pins at the same t: the first in input order is scored.
        #expect(NavigationReplay.pinScoring(manualFixTimes: Self.times([5, 5]), pairWindowS: 3).notScored.map { $0?.reason }
            == [nil, .refinement])
    }

    @Test("Window 0 scores every pin (the old rule); a negative window too")
    func windowZero() {
        let t = Self.times([10, 10.5, 11, 12])
        #expect(NavigationReplay.pinScoring(manualFixTimes: t, pairWindowS: 0).notScored == [nil, nil, nil, nil])
        #expect(NavigationReplay.pinScoring(manualFixTimes: t, pairWindowS: -1).notScored == [nil, nil, nil, nil])
        #expect(ReplayOptions(gps: .use).pinPairWindowS == 3)
    }

    @Test("excludePins: nearest pin within 0.1 s; unmatched entries reported; an excluded pin still opens a pair window")
    func exclusionMatching() {
        let t = Self.times([100.0, 101.2, 200.0, 200.15])
        let exclusions = [
            TruthFile.ExcludedPin(t: 100.04, reason: "off"),  // matches 100.0
            TruthFile.ExcludedPin(t: 200.08, reason: nil),    // 200.0 is 0.08 away, 200.15 is 0.07: the nearer
            TruthFile.ExcludedPin(t: 300, reason: "none"),     // no pin
        ]
        let (notScored, unmatched) = NavigationReplay.pinScoring(manualFixTimes: t, pairWindowS: 3, exclusions: exclusions)
        #expect(notScored[0] == .init(reason: .excluded, note: "off"))
        #expect(notScored[1] == .init(reason: .refinement, firstPinT: 100), "the excluded pin was ingested: 101.2 still refines it")
        #expect(notScored[2] == nil)
        #expect(notScored[3] == .init(reason: .excluded))
        #expect(unmatched == [TruthFile.ExcludedPin(t: 300, reason: "none")])
        // 0.1 s is the limit.
        #expect(NavigationReplay.pinScoring(manualFixTimes: Self.times([50]), pairWindowS: 0,
                                            exclusions: [.init(t: 50.11)]).unmatchedExclusions.count == 1)
        #expect(NavigationReplay.pinScoring(manualFixTimes: Self.times([50]), pairWindowS: 0,
                                            exclusions: [.init(t: 50.1)]).notScored[0]?.reason == .excluded)
    }

    @Test("Truth file: excludePins decodes; files without it still decode")
    func truthFileExcludePins() throws {
        let json = """
            {"A.jsonl.gz": {"points": [{"t": 1, "latitude": 0, "longitude": 0}],
                            "excludePins": [{"t": 100.25, "reason": "doubtful tap"}, {"t": 200.5}]},
             "B.jsonl.gz": {"end": {"latitude": 0, "longitude": 0}}}
            """
        let truth = try TruthFile(data: Data(json.utf8))
        #expect(truth.entry(forLog: "A.jsonl.gz")?.excludePins == [.init(t: 100.25, reason: "doubtful tap"), .init(t: 200.5)])
        #expect(truth.entry(forLog: "B.jsonl.gz")?.excludePins == nil)
    }

    // MARK: In a replay

    /// A drive with clean GNSS for 15 s, then pins at `pinTimes` (each placed
    /// on the truth, or `offsetM` east of it for the indices in `offset`).
    static func scenario(pinTimes: [Double], offset: Set<Int> = [], offsetM: Double = 150)
        -> (events: [LogEvent], truth: TruthFile.Entry) {
        let drive = S(initialHeadingDeg: 45, initialSpeed: 10, [
            .straight(seconds: 30, speed: 10), .turn(degrees: 60, seconds: 6, speed: 8),
            .straight(seconds: 30, speed: 10), .ramp(seconds: 4, from: 10, to: 0), .stop(seconds: 5),
        ])
        let pins = pinTimes.enumerated().map { index, t in
            let state = drive.truth(at: t)
            let p = S.plane.geodetic(east: state.east + (offset.contains(index) ? offsetM : 0), north: state.north)
            return LogEvent(timestamp: S.ms(t), payload: .manualFix(ManualFixSample(
                latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(t), mapSpanM: 200, speedSource: "obd")))
        }
        let events = drive.events(fix: { t, state, rng in t <= 15 ? S.cleanFix()(t, state, &rng) : nil }, extra: pins)
        let end = drive.truth(at: drive.duration)
        let e = S.plane.geodetic(east: end.east, north: end.north)
        return (events, TruthFile.Entry(end: TruthFile.Position(latitude: e.latitude, longitude: e.longitude, sigmaM: 10)))
    }

    static func run(_ events: [LogEvent], truth: TruthFile.Entry?, window: Double) -> ReplayResult {
        var options = ReplayOptions(gps: .use, config: S.config(particles: 200))
        options.pinPairWindowS = window
        return NavigationReplay.run(logName: "synthetic.jsonl.gz", inputs: NavigationReplay.inputs(from: events),
                                    options: options, truth: truth)
    }

    /// Everything the engine produced, i.e. everything but the scoring.
    static func estimates(_ r: ReplayResult) -> [String] {
        let checkpoints = r.checkpoints.map { cp -> ReplayResult.Checkpoint in
            var cp = cp
            cp.notScored = nil
            return cp
        }
        return ["\(r.track)", "\(r.ellipses)", "\(r.pins)", "\(r.counters)", "\(r.fixes)", "\(checkpoints)"]
    }

    @Test("In a replay: a refinement is listed but not scored; window 0 is the old behaviour; estimates are bit-identical")
    func replayPairs() throws {
        let (events, truth) = Self.scenario(pinTimes: [40, 41.5, 55])
        let new = Self.run(events, truth: truth, window: 3)
        var old = Self.run(events, truth: truth, window: 0)
        // R18.1-3: the window has its own mode (row and file name); apart
        // from it the GeoJSON is byte-identical.
        #expect(new.mode == "use" && old.mode == "use-pair-window-0")
        old.mode = new.mode
        #expect(try ReplayReport.geoJSON(new) == ReplayReport.geoJSON(old))
        #expect(Self.estimates(new) == Self.estimates(old))
        #expect(new.counters.manualFixes == 3 && old.counters.manualFixes == 3, "every pin is ingested")

        let manual = new.checkpoints.filter { $0.kind == .manualFix }
        #expect(manual.map { $0.notScored?.reason } == [nil, .refinement, nil])
        #expect(manual[1].errorM != nil, "a refinement's error is still measured and listed")
        #expect(old.checkpoints.allSatisfy { $0.notScored == nil })
        #expect(new.pinScoring == .init(pairWindowS: 3, manualFixes: 3, scored: 2, refinements: 1))
        #expect(old.pinScoring == .init(pairWindowS: 0, manualFixes: 3, scored: 3))
        // Consistency: one checkpoint fewer, and exactly the scored ones.
        #expect(new.consistency == EllipseConsistency(new.checkpoints.filter { $0.notScored == nil }))
        #expect(new.consistency.byKind["manualFix"]?.scored == 2 && old.consistency.byKind["manualFix"]?.scored == 3)
        #expect(new.consistency.all.scored == old.consistency.all.scored - 1)

        let summary = ReplayReport.summary(new)
        #expect(summary.contains("Pins scored   3 manual fixes: 2 scored, 1 refinement folded into pairs (pair window 3 s), 0 excluded by truth"))
        #expect(summary.contains("[refinement of t 40.0 s, not scored]"))
        #expect(ReplayReport.summary(old).contains("(pair window off)"))
        let markdown = ReplayReport.markdown([ReplayMetrics(new)])
        #expect(markdown.contains("| manualFix (refinement of t 40.0 s, not scored) | 41.5 |"))
        #expect(markdown.contains("Pins: 3 manual fixes: 2 scored"))
    }

    @Test("A pin excluded by truth is not scored but still ingested: estimates bit-identical with or without the exclusion")
    func excludedPin() throws {
        // Pin 1 is 150 m off and pulls the estimate: it must stay in the engine.
        let (events, truth) = Self.scenario(pinTimes: [40, 55], offset: [0])
        var excluded = truth
        excluded.excludePins = [.init(t: 40.02, reason: "doubtful")]
        let with = Self.run(events, truth: excluded, window: 3)
        let without = Self.run(events, truth: truth, window: 3)
        #expect(try ReplayReport.geoJSON(with) == ReplayReport.geoJSON(without))
        #expect(Self.estimates(with) == Self.estimates(without))
        #expect(with.counters.manualFixes == 2)

        let manual = with.checkpoints.filter { $0.kind == .manualFix }
        #expect(manual[0].notScored == .init(reason: .excluded, note: "doubtful") && manual[1].notScored == nil)
        #expect(with.pinScoring.excluded == 1 && with.pinScoring.scored == 1)
        #expect(with.consistency.byKind["manualFix"]?.scored == 1)
        // Max error over scored checkpoints only.
        let scoredMax = with.checkpoints.filter { $0.notScored == nil }.compactMap(\.errorM).max()
        #expect(with.maxErrorM == scoredMax)
        #expect(ReplayReport.summary(with).contains("[excluded by truth (doubtful), not scored]"))

        // An exclusion that matches nothing is reported, not silently dropped.
        var stray = truth
        stray.excludePins = [.init(t: 47)]
        let s = Self.run(events, truth: stray, window: 3)
        #expect(s.pinScoring.unmatchedExclusionsT == [47] && s.pinScoring.excluded == 0)
        #expect(ReplayReport.summary(s).contains("excludePins matching no manual fix: t 47.000 s"))
    }

    @Test("Max and end error skip pins that are not scored")
    func maxAndEndSkipNotScored() {
        // Without a truth end, end error is the last scored checkpoint.
        let (events, _) = Self.scenario(pinTimes: [40, 41], offset: [])
        let new = Self.run(events, truth: nil, window: 3)
        let old = Self.run(events, truth: nil, window: 0)
        let manual = new.checkpoints.filter { $0.kind == .manualFix }
        #expect(old.endErrorM == manual[1].errorM)
        #expect(new.endErrorM == manual[0].errorM)
        #expect(!new.endIsTruth)
    }

    // MARK: metrics.json

    @Test("metrics.json: pinScoring and notScored round-trip; a file written before them still decodes and merges")
    func metricsDecodeOldFile() throws {
        let (events, truth) = Self.scenario(pinTimes: [40, 41.5])
        let result = Self.run(events, truth: truth, window: 3)
        let metrics = ReplayMetrics(result)
        let data = try ReplayReport.metricsJSON([metrics])
        let decoded = try JSONDecoder().decode([ReplayMetrics].self, from: data)
        #expect(decoded == [metrics])
        #expect(decoded[0].pinScoring?.refinements == 1)
        #expect(decoded[0].checkpoints.filter { $0.notScored != nil }.count == 1)

        // Strip every N3.0 key, as a file from the previous build would be.
        var old = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        old[0].removeValue(forKey: "pinScoring")
        var checkpoints = try #require(old[0]["checkpoints"] as? [[String: Any]])
        for i in checkpoints.indices { checkpoints[i].removeValue(forKey: "notScored") }
        old[0]["checkpoints"] = checkpoints
        old[0]["mode"] = "old-mode"
        let oldData = try JSONSerialization.data(withJSONObject: old)
        #expect(!String(decoding: oldData, as: UTF8.self).contains("notScored"))
        #expect(ReplayReport.existingMetricsDecodeError(oldData) == nil)
        let legacy = try JSONDecoder().decode([ReplayMetrics].self, from: oldData)
        #expect(legacy[0].pinScoring == nil)
        #expect(legacy[0].checkpoints.allSatisfy { $0.notScored == nil })
        // Its row survives a merge with a new run.
        let merged = try ReplayReport.mergedMetrics(existing: oldData, adding: [metrics])
        #expect(merged.map(\.mode).sorted() == ["old-mode", metrics.mode].sorted())
        #expect(ReplayReport.markdown(merged).contains("| old-mode |"))

        // A document that does not decode is reported (replay_nav warns and
        // keeps a copy instead of dropping its rows silently).
        #expect(ReplayReport.existingMetricsDecodeError(Data(#"[{"logName": "x"}]"#.utf8)) != nil)
        #expect(ReplayReport.existingMetricsDecodeError(nil) == nil)
    }
}

// MARK: - excludeFixes (truth-file fix ranges, N3-FIXPIN step 0)

/// The truth file's `excludeFixes`: a location fix in a range is never truth
/// (no clean-fix checkpoint, no road truth), in any GPS mode. Scoring only:
/// the engine receives exactly the fixes the GPS mode gives it.
extension NavigationPinScoringTests {
    /// Clean fixes (5 m, course) every second over ~85 s, a pin at 5 s on
    /// the truth (it initialises the engine under `--gps none`), truth `end`.
    static func fixRangeScenario() -> (events: [LogEvent], truth: TruthFile.Entry) {
        let drive = S(initialHeadingDeg: 30, initialSpeed: 10, [
            .straight(seconds: 35, speed: 10), .turn(degrees: 70, seconds: 6, speed: 8),
            .straight(seconds: 35, speed: 10), .ramp(seconds: 4, from: 10, to: 0), .stop(seconds: 5),
        ])
        let state = drive.truth(at: 5)
        let p = S.plane.geodetic(east: state.east, north: state.north)
        let pin = LogEvent(timestamp: S.ms(5), payload: .manualFix(ManualFixSample(
            latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(5), mapSpanM: 200, speedSource: "obd")))
        let events = drive.events(fix: S.cleanFix(accuracy: 5, positionNoise: 1), extra: [pin])
        let end = drive.truth(at: drive.duration)
        let e = S.plane.geodetic(east: end.east, north: end.north)
        return (events, TruthFile.Entry(end: TruthFile.Position(latitude: e.latitude, longitude: e.longitude, sigmaM: 10)))
    }

    static func fixRangeRun(_ events: [LogEvent], truth: TruthFile.Entry?, gps: GPSMode) -> ReplayResult {
        NavigationReplay.run(logName: "synthetic.jsonl.gz", inputs: NavigationReplay.inputs(from: events),
                             options: ReplayOptions(gps: gps, config: S.config(particles: 200)), truth: truth)
    }

    /// Everything the engine produced (track, ellipses, pin priors, counters,
    /// fix list): must not depend on `excludeFixes`.
    static func engineOutput(_ r: ReplayResult) -> [String] {
        ["\(r.track)", "\(r.ellipses)", "\(r.pins)", "\(r.counters)", "\(r.fixes)"]
    }

    static func location(_ input: NavigationInput) -> (sample: LocationSample, t: MonotonicTimestamp)? {
        if case .location(let sample, let t) = input { return (sample, t) }
        return nil
    }

    @Test("Truth file: excludeFixes decodes; an entry without it decodes unchanged (nil)")
    func truthFileExcludeFixes() throws {
        let json = """
            {"A.jsonl.gz": {"excludeFixes": [{"fromT": -1, "toT": 251, "reason": "offset"}, {"fromT": 300.5, "toT": 300.5}],
                            "excludePins": [{"t": 3}], "note": "x"},
             "B.jsonl.gz": {"end": {"latitude": 0, "longitude": 0}, "excludePins": [{"t": 3}], "scoreUntilT": 9}}
            """
        let truth = try TruthFile(data: Data(json.utf8))
        let a = try #require(truth.entry(forLog: "A.jsonl.gz"))
        #expect(a.excludeFixes == [.init(fromT: -1, toT: 251, reason: "offset"), .init(fromT: 300.5, toT: 300.5)])
        #expect(a.excludePins == [.init(t: 3)])
        let b = try #require(truth.entry(forLog: "B.jsonl.gz"))
        #expect(b == TruthFile.Entry(end: TruthFile.Position(latitude: 0, longitude: 0), excludePins: [.init(t: 3)],
                                     scoreUntilT: 9))
        #expect(b.excludeFixes == nil && !b.excludesFix(at: S.ms(0)))
    }

    @Test("Truth file: a range with fromT > toT or a missing bound fails the whole file; non-finite bounds are invalid and match nothing")
    func truthFileBadRange() throws {
        for bad in [#"{"fromT": 10, "toT": 9.999}"#, #"{"fromT": 10}"#, #"{"toT": 10}"#, #"{"fromT": "a", "toT": 10}"#] {
            let json = #"{"A.jsonl.gz": {"excludeFixes": ["# + bad + "]}}"
            #expect(throws: DecodingError.self, "\(bad)") { try TruthFile(data: Data(json.utf8)) }
        }
        // JSON has no NaN or infinity literal and Foundation refuses an
        // out-of-range number, so a non-finite bound only exists in code.
        #expect(throws: (any Error).self) {
            try TruthFile(data: Data(#"{"A.jsonl.gz": {"excludeFixes": [{"fromT": 0, "toT": 1e400}]}}"#.utf8))
        }
        let infinite = TruthFile.ExcludedFixRange(fromT: 0, toT: .infinity)
        let nan = TruthFile.ExcludedFixRange(fromT: .nan, toT: 10)
        let reversed = TruthFile.ExcludedFixRange(fromT: 10, toT: 5)
        #expect(infinite.problem != nil && nan.problem != nil && reversed.problem != nil)
        #expect(!infinite.contains(S.ms(1)) && !nan.contains(S.ms(5)) && !reversed.contains(S.ms(7)))
        // fromT == toT is a valid one-instant range.
        let instant = TruthFile.ExcludedFixRange(fromT: 7, toT: 7)
        #expect(instant.problem == nil && instant.contains(S.ms(7)) && !instant.contains(MonotonicTimestamp(nanoseconds: 7_000_000_001)))
    }

    @Test("--gps none: an excluded range removes exactly its clean-fix checkpoints (inclusive), consistency shrinks with it, the engine is unchanged")
    func excludedRangeGpsNone() throws {
        let (events, truth) = Self.fixRangeScenario()
        var excluded = truth
        excluded.excludeFixes = [.init(fromT: 20, toT: 30, reason: "shifted")]
        let base = Self.fixRangeRun(events, truth: truth, gps: .none)
        let with = Self.fixRangeRun(events, truth: excluded, gps: .none)

        #expect(Self.engineOutput(with) == Self.engineOutput(base))
        #expect(with.fixes.allSatisfy { $0.withheld == .gpsNone }, "the GPS mode alone decides what the engine gets")
        let baseClean = base.checkpoints.filter { $0.kind == .cleanFix }
        let inRange = baseClean.filter { $0.t >= 20 && $0.t <= 30 }
        #expect(inRange.count == 11 && inRange.first?.t == 20 && inRange.last?.t == 30, "fixes at 20, 21, …, 30 s, both ends")
        #expect(baseClean.filter { $0.t > 5 }.allSatisfy { $0.inside95 != nil }, "every clean fix after the pin has an estimate")
        #expect(inRange.allSatisfy { $0.inside95 != nil })
        // Exactly those checkpoints are gone; the rest are unchanged.
        let kept = base.checkpoints.filter { !($0.kind == .cleanFix && $0.t >= 20 && $0.t <= 30) }
        #expect(with.checkpoints == kept)
        #expect(with.checkpoints.contains { $0.kind == .cleanFix && $0.t == 19 }
            && with.checkpoints.contains { $0.kind == .cleanFix && $0.t == 31 })
        #expect(with.consistency == EllipseConsistency(kept))
        #expect(with.consistencyWithTruthSigma == EllipseConsistency(kept, withTruthSigma: true))
        #expect(with.consistency.byKind["cleanFix"]?.scored == (base.consistency.byKind["cleanFix"]?.scored ?? 0) - 11)
        #expect(with.consistency.all.scored == base.consistency.all.scored - 11)
        #expect(with.maxErrorM == kept.filter(\.isScored).compactMap(\.errorM).max())
        #expect(with.endErrorM == base.endErrorM && with.endIsTruth)
        #expect(with.fixesExcludedByTruth == .init(ranges: excluded.excludeFixes!, fixes: 11, cleanFixes: 11,
                                                   cleanFixCheckpoints: 11))
        #expect(base.fixesExcludedByTruth == nil)

        // One nanosecond inside each bound drops the two boundary fixes.
        var inner = truth
        inner.excludeFixes = [.init(fromT: 20.000_000_001, toT: 29.999_999_999)]
        let narrow = Self.fixRangeRun(events, truth: inner, gps: .none)
        #expect(narrow.fixesExcludedByTruth?.cleanFixCheckpoints == 9)
        #expect(narrow.checkpoints.contains { $0.kind == .cleanFix && $0.t == 20 }
            && narrow.checkpoints.contains { $0.kind == .cleanFix && $0.t == 30 })

        // Reports: the summary line and metrics.md name the range and counts;
        // metrics.json round-trips the new key.
        let summary = ReplayReport.summary(with)
        #expect(summary.contains("Fixes excl.   by truth excludeFixes t 20.0 … 30.0 s (shifted): 11 fixes, 11 clean (≤ 15 m), 11 withheld clean-fix checkpoints; never truth"))
        #expect(summary.contains("cleanFix      \(kept.filter { $0.kind == .cleanFix }.count) withheld clean fixes"))
        let markdown = ReplayReport.markdown([ReplayMetrics(with)])
        #expect(markdown.contains("Fixes excluded by truth (excludeFixes): t 20.0 … 30.0 s (shifted): 11 fixes"))
        let data = try ReplayReport.metricsJSON([ReplayMetrics(with)])
        #expect(try JSONDecoder().decode([ReplayMetrics].self, from: data) == [ReplayMetrics(with)])
        let row = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])[0]
        let saved = try #require(row["fixesExcludedByTruth"] as? [String: Any])
        #expect(saved["cleanFixCheckpoints"] as? Int == 11 && saved["fixes"] as? Int == 11)
    }

    @Test("Any GPS mode: fixes given to the engine stay given (use, mask-after); only withheld ones lose their checkpoint")
    func excludedRangeOtherModes() throws {
        let (events, truth) = Self.fixRangeScenario()
        var excluded = truth
        excluded.excludeFixes = [.init(fromT: 15, toT: 40)]
        // use: nothing is withheld, so there is no clean-fix checkpoint to drop.
        let useBase = Self.fixRangeRun(events, truth: truth, gps: .use)
        let use = Self.fixRangeRun(events, truth: excluded, gps: .use)
        #expect(Self.engineOutput(use) == Self.engineOutput(useBase))
        #expect(use.checkpoints == useBase.checkpoints)
        #expect(use.fixesExcludedByTruth == .init(ranges: excluded.excludeFixes!, fixes: 26, cleanFixes: 26,
                                                  cleanFixCheckpoints: 0))
        // mask-after 25: 15…25 s are used as before, 26…40 s lose their checkpoint.
        let maskBase = Self.fixRangeRun(events, truth: truth, gps: .maskAfter(seconds: 25))
        let mask = Self.fixRangeRun(events, truth: excluded, gps: .maskAfter(seconds: 25))
        #expect(Self.engineOutput(mask) == Self.engineOutput(maskBase))
        #expect(mask.counters.fixesUsed == maskBase.counters.fixesUsed)
        #expect(mask.checkpoints == maskBase.checkpoints.filter { !($0.kind == .cleanFix && $0.t <= 40) })
        #expect(maskBase.checkpoints.filter { $0.kind == .cleanFix && $0.t <= 40 }.count == 15)
        #expect(mask.fixesExcludedByTruth?.cleanFixCheckpoints == 15 && mask.fixesExcludedByTruth?.fixes == 26)
    }

    @Test("No excludeFixes (absent or empty): no new key in metrics.json or reports; outputs byte-identical")
    func noExcludeFixesUnchanged() throws {
        let (events, truth) = Self.fixRangeScenario()
        var empty = truth
        empty.excludeFixes = []
        let base = Self.fixRangeRun(events, truth: truth, gps: .maskAfter(seconds: 20))
        let none = Self.fixRangeRun(events, truth: empty, gps: .maskAfter(seconds: 20))
        #expect(base.fixesExcludedByTruth == nil && none.fixesExcludedByTruth == nil)
        #expect(try ReplayReport.geoJSON(none) == ReplayReport.geoJSON(base))
        #expect(none.checkpoints == base.checkpoints)
        func untimed(_ r: ReplayResult) -> ReplayMetrics {
            var m = ReplayMetrics(r)
            m.msPerStep = 0
            m.maxIngestMs = 0
            return m
        }
        let json = try ReplayReport.metricsJSON([untimed(none)])
        #expect(json == (try ReplayReport.metricsJSON([untimed(base)])))
        #expect(!String(decoding: json, as: UTF8.self).contains("fixesExcludedByTruth"))
        #expect(ReplayReport.markdown([untimed(none)]) == ReplayReport.markdown([untimed(base)]))
        #expect(!ReplayReport.summary(none).contains("excludeFixes"))
    }
}
