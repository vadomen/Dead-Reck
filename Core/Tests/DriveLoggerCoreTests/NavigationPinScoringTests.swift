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
        let old = Self.run(events, truth: truth, window: 0)
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
