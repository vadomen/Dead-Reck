import Foundation
import Testing

@testable import DriveLoggerCore

/// NAV-NOOBD (prompt 44, replay only): `replay_nav --obd none` withholds
/// every OBD reply from the engine, causally; the fix accounting, the naive
/// last-fix baselines and the per-run aggregates. Synthetic drives from
/// (0, 0) only; no real place, date or recording.
@Suite("Navigation NAV-NOOBD: replay without OBD, last-fix baselines, fix accounting")
struct NavigationNoOBDTests {
    typealias S = SyntheticDrive

    // MARK: Fixture

    /// Parked 10 s, then driving with two turns; clean fixes every second.
    static let drive = S(initialHeadingDeg: 30, [
        .stop(seconds: 10), .ramp(seconds: 5, from: 0, to: 14), .straight(seconds: 30, speed: 14),
        .turn(degrees: 90, seconds: 10, speed: 10), .straight(seconds: 30, speed: 14),
        .turn(degrees: -60, seconds: 8, speed: 10), .straight(seconds: 20, speed: 12),
    ])

    /// Every second: an `elm` NO DATA row (never an engine input), and
    /// OBD replies the engine would otherwise get from another PID and
    /// another ECU, so "all ECUs, all PIDs" is exercised.
    static let extraEvents: [LogEvent] = (0..<110).flatMap { k -> [LogEvent] in
        // Off the 10 ms motion grid, so no time ties with the drive's rows.
        let t = Double(k) + 0.375
        let elm = LogEvent(timestamp: S.ms(t), payload: .elm(ELMTrafficSample(
            seq: k, phase: "poll", tx: "010D", requestT: S.ms(t - 0.05), rx: "NO DATA", outcome: "noData")))
        let rpm = LogEvent.obd(OBDSample(pid: .engineSpeed, value: 900, unit: .revolutionsPerMinute, ecu: "7E8"),
                               at: S.ms(t + 0.01))
        let otherECU = LogEvent.obd(OBDSample(pid: .vehicleSpeed, value: 50, unit: .kilometersPerHour, ecu: "7E9"),
                                    at: S.ms(t + 0.02))
        return [elm, rpm, otherECU]
    }

    /// The drive's rows, then the extra rows (the replay orders inputs by
    /// arrival; `elm` rows are not inputs, so they cannot go through
    /// `events(extra:)`, which sorts by input arrival).
    static let events: [LogEvent] = drive.events(gyroNoise: 0.002, fix: S.cleanFix(accuracy: 5, positionNoise: 1))
        + extraEvents

    /// The same recording with every `obd` and `elm` row removed.
    static let strippedEvents: [LogEvent] = events.filter {
        switch $0.payload {
        case .obd, .elm: false
        default: true
        }
    }

    static func options(_ obd: OBDMode, gps: GPSMode = .maskAfter(seconds: 50)) -> ReplayOptions {
        var options = ReplayOptions(gps: gps, config: S.config(particles: 300, seed: 3))
        options.obd = obd
        return options
    }

    static func run(_ events: [LogEvent], _ options: ReplayOptions) -> ReplayResult {
        NavigationReplay.run(logName: "synthetic.jsonl.gz", inputs: NavigationReplay.inputs(from: events),
                             options: options)
    }

    /// The engine side of a track point (its `distanceM` is scoring).
    static func engineSide(_ p: ReplayResult.TrackPoint) -> [Double] {
        [p.t, p.latitude, p.longitude, p.headingDeg, p.headingStdDeg, p.converged ? 1 : 0, p.speedScale]
    }

    /// The engine side of a checkpoint (its distance and % are scoring).
    static func engineSide(_ c: ReplayResult.Checkpoint) -> [Double?] {
        [c.t, c.errorM, c.estimateLatitude, c.estimateLongitude, c.headingStdDeg, c.ellipseSemiMajorM,
         c.ellipseSemiMinorM, c.ellipseOrientationDeg, c.inside95.map { $0 ? 1 : 0 }]
    }

    // MARK: Withholding

    @Test("--obd none is the run of the recording with every obd and elm row removed (estimates, counters, fixes, baselines, ESS), while distance and motion start are the --obd use run's (scoring stays ∫ OBD from the log)")
    func noneEqualsTheRunWithoutOBDRows() throws {
        let obdRows = Self.events.filter { if case .obd = $0.payload { true } else { false } }.count
        let elmRows = Self.events.filter { if case .elm = $0.payload { true } else { false } }.count
        #expect(obdRows > 3 * 110 && elmRows == 110)
        // elm rows are never engine inputs, in any mode.
        let withoutElm = Self.events.filter { if case .elm = $0.payload { false } else { true } }
        #expect(NavigationReplay.inputs(from: Self.events) == NavigationReplay.inputs(from: withoutElm))

        let none = Self.run(Self.events, Self.options(.none))
        let stripped = Self.run(Self.strippedEvents, Self.options(.use))
        let use = Self.run(Self.events, Self.options(.use))

        // The engine saw exactly what it sees with no OBD rows at all.
        #expect(none.counters == stripped.counters)
        #expect(none.steps == stripped.steps && none.steps > 0)
        #expect(none.track.map(Self.engineSide) == stripped.track.map(Self.engineSide))
        #expect(none.ellipses == stripped.ellipses)
        #expect(none.checkpoints.map(Self.engineSide) == stripped.checkpoints.map(Self.engineSide))
        #expect(none.fixes == stripped.fixes)
        #expect(none.fixAccounting == stripped.fixAccounting)
        #expect(none.lastFixBaseline == stripped.lastFixBaseline)
        #expect(none.essMin == stripped.essMin && none.essMin != nil)
        // No OBD at all: every initialised step is a stale-speed step, never
        // a ZUPT or a parked step.
        #expect(none.counters.staleSpeedSteps == none.counters.steps)
        #expect(none.counters.zuptSteps == 0 && none.counters.staleParkedSteps == 0)

        // Scoring is the log's, as with --obd use.
        #expect(none.distanceM == use.distanceM && none.distanceM > 1_000)
        #expect(none.motionStartT == use.motionStartT && none.motionStartT != nil)
        #expect(none.checkpoints.map(\.distanceM) == use.checkpoints.map(\.distanceM))
        #expect(stripped.distanceM == 0 && stripped.motionStartT == nil)

        // Every obd row counted as withheld; none with --obd use.
        #expect(none.obdWithheld == obdRows)
        #expect(use.obdWithheld == nil && stripped.obdWithheld == nil)
        // OBD changed the --obd use run (it was given).
        #expect(use.counters.staleSpeedSteps < use.counters.steps / 2)
        #expect(use.counters.zuptSteps > 0)
        #expect(none.mode == "mask-after-50-obd-none" && use.mode == "mask-after-50")
    }

    @Test("--obd use is the run as before the flag: the default options' metrics and label")
    func useIsTheDefault() {
        let defaults = ReplayOptions(gps: .maskAfter(seconds: 50), config: S.config(particles: 300, seed: 3))
        #expect(defaults.obd == .use)
        #expect(defaults == Self.options(.use))
        #expect(defaults.label == "mask-after-50")
        let a = Self.run(Self.events, defaults)
        let b = Self.run(Self.events, Self.options(.use))
        #expect(NavigationReplayTests.untimed(a) == NavigationReplayTests.untimed(b))
        #expect(a.obdWithheld == nil && ReplayMetrics(a).obdWithheld == nil)
        // The summary says nothing about OBD with --obd use.
        #expect(!ReplayReport.summary(a).contains("OBD           "))
    }

    @Test("--obd: parsing, labels and the flags refused with none")
    func parsingLabelsAndRefusals() {
        #expect(OBDMode("use") == OBDMode.use && OBDMode("none") == OBDMode.none)
        for bad in ["", "off", "ignore", "NONE", "Use", "mask-after"] { #expect(OBDMode(bad) == nil, "\(bad)") }

        var options = ReplayOptions(gps: .use)
        options.obd = .none
        #expect(options.label == "use-obd-none")
        options.holdOutAccuracyM = 100
        #expect(options.label == "use-holdout-100-obd-none")
        options = ReplayOptions(gps: .maskAfter(seconds: 1800))
        options.obd = .none
        options.asLive = true
        #expect(options.label == "mask-after-1800-as-live-obd-none")
        options.asLive = false
        options.startAtS = 30
        #expect(options.label == "mask-after-1800-from-30-obd-none")
        options.obd = .use
        #expect(options.label == "mask-after-1800-from-30")

        #expect(OBDMode.refusedWithNone == ["--prior", "--fix-offset", "--compare", "--write-sidecar", "--fixpin-inject"])
        #expect(OBDMode.refusedFlags(["--obd", "--write-sidecar", "--roads", "--prior", "--write-sidecar", "--compare"])
            == ["--write-sidecar", "--prior", "--compare"])
        for flag in OBDMode.refusedWithNone { #expect(OBDMode.refusedFlags(["--obd", flag]) == [flag]) }
        let allowed = ["--obd", "--gps", "--hold-out-acc", "--truth", "--seed", "--particles", "--set", "--out",
                       "--as-live", "--file-order", "--roads", "--inject-roads", "--start-at", "--no-prior",
                       "--save-prior", "--save-prior-at", "--pin-pair-window", "--strict", "--wrong-road-tolerance"]
        #expect(OBDMode.refusedFlags(allowed).isEmpty)
    }

    @Test("--obd none on a recording with a navPrior row: the row is ignored as with --no-prior, with its own note; --start-at carries the OBD mode into the run before the cut")
    func navPriorRowIgnoredWithoutOBD() throws {
        typealias H = NavigationHandOverTests
        let row = try H.handOverRow(ageS: 1)
        let prior = try #require(row.navigationPrior)
        let choice = ReplayRecordedPrior.choose(row: row, explicitPrior: false, noPrior: false, obd: .none)
        #expect(choice == .ignoredWithoutOBD && choice.prior == nil)
        #expect(ReplayRecordedPrior.choose(row: row, explicitPrior: false, noPrior: true, obd: .none) == .ignoredWithoutOBD)
        #expect(ReplayRecordedPrior.choose(row: nil, explicitPrior: false, noPrior: false, obd: .none) == .absent)
        // --obd use (and the default) is the choice as before.
        #expect(ReplayRecordedPrior.choose(row: row, explicitPrior: false, noPrior: false, obd: .use) == .used(prior))
        #expect(ReplayRecordedPrior.choose(row: row, explicitPrior: false, noPrior: false) == .used(prior))
        let note = try #require(choice.note(firstInput: nil))
        #expect(note.contains("navPrior row ignored with --obd none: its class and speed come from OBD"))
        // A cut changes nothing about an ignored row.
        let inputs = S.inputs(H.recordEvents())
        var options = ReplayOptions(gps: .use, config: H.recordConfig)
        options.obd = .none
        #expect(choice.atCut(startAtS: 30, inputs: inputs, options: options, clock: H.recordClock) == choice)
        // The run itself starts fresh: no prior, label -obd-none only.
        let run = NavigationReplay.run(logName: "synthetic.jsonl.gz", inputs: inputs, options: options)
        #expect(run.restore == nil && run.mode == "use-obd-none")
        // The cut's inner replay gets the run's options, OBD mode included:
        // from the same row, the hand-over at the cut differs with and
        // without OBD.
        var useOptions = options
        useOptions.obd = .use
        let cutNone = ReplayRecordedPrior.used(prior).atCut(startAtS: 30, inputs: inputs, options: options,
                                                            clock: H.recordClock)
        let cutUse = ReplayRecordedPrior.used(prior).atCut(startAtS: 30, inputs: inputs, options: useOptions,
                                                           clock: H.recordClock)
        guard case .cut(let withoutOBD, _) = cutNone, case .cut(let withOBD, _) = cutUse else {
            Issue.record("expected two cuts, got \(cutNone) and \(cutUse)")
            return
        }
        #expect(withoutOBD != withOBD)
    }

    // MARK: Fix accounting and the baselines in a run

    /// Driving at 10 m/s due east from (0, 0) for 70 s. Fixes: clean ones
    /// (5 m, exact) every second, withheld by `--hold-out-acc 10` and so
    /// checkpoints; at t 10 a 50 m fix arriving 15 s late (stale: older than
    /// `maxFixAgeS` 10 s at arrival); at t 40 and 55 fresh 50 m fixes.
    static let staleDrive = S(initialHeadingDeg: 90, initialSpeed: 10, [.straight(seconds: 70, speed: 10)])
    static let staleEvents: [LogEvent] = staleDrive.events(fix: { t, state, rng in
        if S.at(t, 10) {
            return S.Fix(east: state.east, north: state.north, accuracy: 50, latency: 15)
        }
        if S.at(t, 40) || S.at(t, 55) {
            return S.Fix(east: state.east, north: state.north, accuracy: 50)
        }
        return S.cleanFix(accuracy: 5, positionNoise: 0)(t, state, &rng)
    })

    static func staleRun(_ obd: OBDMode) -> ReplayResult {
        var options = ReplayOptions(gps: .use, holdOutAccuracyM: 10, config: S.config(particles: 300, seed: 5))
        options.obd = obd
        return run(staleEvents, options)
    }

    @Test("Fix accounting: without OBD a stale fix is held and dropped at the timeout (delivered ≠ accepted); with OBD it is ignored on arrival; the books balance")
    func fixAccountingStaleFix() throws {
        let none = Self.staleRun(.none)
        let a = none.fixAccounting
        #expect(a.delivered == 3)
        #expect(a.accepted == 2 && a.accepted == none.counters.fixesUsed)
        #expect(a.droppedHeldTimeout == 1 && none.counters.fixesHeld == 1)
        #expect(a.ignoredStale == 0 && a.stillHeld == 0 && a.unaccounted == 0)
        #expect(a.delivered != a.accepted)
        #expect(ReplayMetrics(none).fixAccounting == a)

        let use = Self.staleRun(.use)
        let b = use.fixAccounting
        #expect(b.delivered == 3 && b.accepted == 2)
        #expect(b.ignoredStale == 1 && b.droppedHeldTimeout == 0 && b.unaccounted == 0)
        #expect(ReplayReport.summary(none).contains("Fix account   delivered 3: accepted 2, held dropped timeout 1"))
    }

    @Test("Last-fix baselines in a run: the held stale fix is delivered but never accepted; known from its arrival, not its t; none yet is counted, not scored")
    func baselinesInARun() throws {
        let run = Self.staleRun(.none)
        let b = run.lastFixBaseline
        #expect(b.delivered.perCheckpointM.count == run.checkpoints.count)
        #expect(b.accepted.perCheckpointM.count == run.checkpoints.count)
        func at(_ t: Double) throws -> Int {
            try #require(run.checkpoints.firstIndex { $0.kind == .cleanFix && abs($0.t - t) < 0.005 })
        }
        // t 20: the stale fix (t 10) has not arrived yet (it arrives at 25).
        #expect(b.delivered.perCheckpointM[try at(20)] == nil)
        // t 30: delivered = the t 10 fix, 200 m behind; the engine never
        // used it (held, then dropped), so nothing accepted yet.
        let d30 = try #require(b.delivered.perCheckpointM[try at(30)])
        #expect(abs(d30 - 200) < 1)
        #expect(b.accepted.perCheckpointM[try at(30)] == nil)
        // t 50: both are the t 40 fix, 100 m behind.
        let d50 = try #require(b.delivered.perCheckpointM[try at(50)])
        let a50 = try #require(b.accepted.perCheckpointM[try at(50)])
        #expect(abs(d50 - 100) < 1 && d50 == a50)
        // t 65: the t 55 fix, 100 m behind.
        let a65 = try #require(b.accepted.perCheckpointM[try at(65)])
        #expect(abs(a65 - 100) < 1)
        // Counts: every checkpoint is scored here; before t 25 nothing was
        // delivered, before t 40 nothing accepted.
        let scored = run.checkpoints.filter(\.isScored).count
        #expect(b.delivered.count + b.delivered.countNone == scored)
        #expect(b.accepted.count + b.accepted.countNone == scored)
        #expect((24...26).contains(b.delivered.countNone))
        #expect((39...41).contains(b.accepted.countNone))
        // Max: accepted 150 m (t 70 against the t 55 fix); delivered 290 m
        // (t 39 against the t 10 fix: t 40 has no clean fix).
        #expect(b.accepted.maxM.map { abs($0 - 150) < 1 } == true)
        #expect(b.delivered.maxM.map { abs($0 - 290) < 1 } == true)
        // The summary and metrics.md carry them.
        #expect(ReplayReport.summary(run).contains("Last fix      (naive, same checkpoints) delivered: median"))
        let markdown = ReplayReport.markdown([ReplayMetrics(run)])
        #expect(markdown.contains("## Error distribution, last-fix baselines, fix accounting"))
        #expect(markdown.contains("| 3 | 2 | 1 / 0 / 0 | stale 0, invalid 0, older than save 0, time jump 0, still held 0 | "))
        // No roads, no switch: neither outcome is listed (as their keys).
        #expect(run.fixAccounting.rejectedOffRoad == nil && run.fixAccounting.withheldByGPSSwitch == nil)
    }

    // MARK: The helpers

    @Test("LastFixBaseline.Tracker: newest by fix time, not by delivery; delivered and accepted kept apart; distances on the plane")
    func trackerByHand() {
        let plane = LocalTangentPlane(latitude: 0, longitude: 0)
        func fix(_ t: Double, east: Double) -> LastFixBaseline.Fix {
            let p = plane.geodetic(east: east, north: 0)
            return LastFixBaseline.Fix(tNs: S.ms(t).nanoseconds, latitude: p.latitude, longitude: p.longitude)
        }
        let truth = plane.geodetic(east: 1_000, north: 0)
        var tracker = LastFixBaseline.Tracker()
        var m = tracker.measure(latitude: truth.latitude, longitude: truth.longitude, plane: plane)
        #expect(m.delivered == nil && m.accepted == nil)
        tracker.deliver(fix(10, east: 100))
        m = tracker.measure(latitude: truth.latitude, longitude: truth.longitude, plane: plane)
        #expect(abs(m.delivered! - 900) < 1e-6 && m.accepted == nil)
        tracker.accept(fix(10, east: 100))
        // A fix delivered later but taken earlier (cached) does not replace it.
        tracker.deliver(fix(5, east: 50))
        // A newer fix delivered, held, never accepted.
        tracker.deliver(fix(20, east: 600))
        m = tracker.measure(latitude: truth.latitude, longitude: truth.longitude, plane: plane)
        #expect(abs(m.delivered! - 400) < 1e-6 && abs(m.accepted! - 900) < 1e-6)
        // Ties: the later one.
        tracker.accept(fix(10, east: 700))
        m = tracker.measure(latitude: truth.latitude, longitude: truth.longitude, plane: plane)
        #expect(abs(m.accepted! - 300) < 1e-6)
        // No usable position: never a baseline fix.
        let invalid = LocationSample(latitude: 0, longitude: 0, altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1,
                                     speed: -1, speedAccuracy: -1, course: -1, courseAccuracy: -1)
        #expect(LastFixBaseline.Fix(invalid, at: S.ms(1)) == nil)
        var nan = invalid
        nan.horizontalAccuracy = 5
        nan.latitude = .nan
        #expect(LastFixBaseline.Fix(nan, at: S.ms(1)) == nil)
        var ok = invalid
        ok.horizontalAccuracy = 1414
        #expect(LastFixBaseline.Fix(ok, at: S.ms(1)) == LastFixBaseline.Fix(tNs: S.ms(1).nanoseconds, latitude: 0, longitude: 0))
    }

    @Test("LastFixBaseline aggregates on a hand-built checkpoint set: scored only, none yet counted not scored, nearest-rank median / p90, max")
    func baselineAggregatesByHand() {
        let perCheckpoint: [(delivered: Double?, accepted: Double?)] = [
            (nil, nil), (10, nil), (20, 20), (30, nil), (40, 10), (5_000, 5_000), (nil, nil),
        ]
        let scored = [true, true, true, true, true, false, false]
        let b = LastFixBaseline(perCheckpoint: perCheckpoint, scored: scored)
        #expect(b.delivered.perCheckpointM == [nil, 10, 20, 30, 40, 5_000, nil])
        #expect(b.delivered.count == 4 && b.delivered.countNone == 1)
        #expect(b.delivered.medianM == 20 && b.delivered.p90M == 40 && b.delivered.maxM == 40)
        #expect(b.accepted.count == 2 && b.accepted.countNone == 3)
        #expect(b.accepted.medianM == 10 && b.accepted.p90M == 20 && b.accepted.maxM == 20)
        let empty = LastFixBaseline(perCheckpoint: [(nil, nil)], scored: [true])
        #expect(empty.delivered.count == 0 && empty.delivered.countNone == 1 && empty.delivered.medianM == nil
            && empty.delivered.maxM == nil)
        #expect(b.delivered.text == "median 20 m, p90 40 m, max 40 m over 4 (1 none yet)")
        #expect(empty.accepted.text == "no scored checkpoint with a fix (1 none yet)")
    }

    @Test("Nearest-rank percentiles: rank ⌈p·n/100⌉, the lower middle for an even median, observed values only")
    func nearestRank() {
        let ten = (1...10).map(Double.init).shuffled()
        #expect(NearestRank.percentile(ten, 50) == 5)
        #expect(NearestRank.percentile(ten, 90) == 9)
        #expect(NearestRank.percentile(ten, 91) == 10)
        #expect(NearestRank.percentile(ten, 100) == 10)
        #expect(NearestRank.percentile(ten, 0) == 1)
        let twenty = (1...20).map(Double.init)
        #expect(NearestRank.percentile(twenty, 90) == 18)
        #expect(NearestRank.percentile(twenty, 50) == 10)
        #expect(NearestRank.percentile([7], 90) == 7 && NearestRank.percentile([7], 50) == 7)
        #expect(NearestRank.percentile([3, 1, 2], 50) == 2 && NearestRank.percentile([3, 1, 2], 90) == 3)
        #expect(NearestRank.percentile([], 50) == nil)
        #expect(NearestRank.percentile([.nan, 4, .infinity, 2], 90) == 4)
    }

    @Test("Per-run aggregates over scored checkpoints with an error: unscored, after-cutoff and pre-initialisation ones are left out; % only where a distance exists")
    func errorAggregates() {
        func cp(_ error: Double?, percent: Double?, axis: Double?, notScored: Bool = false, after: Bool = false)
            -> ReplayResult.Checkpoint {
            var c = ReplayResult.Checkpoint(kind: .cleanFix, t: 1, latitude: 0, longitude: 0, distanceM: 100)
            c.errorM = error
            c.errorPercent = percent
            c.ellipseSemiMajorM = axis
            if notScored { c.notScored = NavigationReplay.NotScored(reason: .excluded) }
            if after { c.afterScoreUntilT = true }
            return c
        }
        let checkpoints = [
            cp(nil, percent: nil, axis: nil),
            cp(10, percent: nil, axis: 100),
            cp(20, percent: 2, axis: 300),
            cp(30, percent: 3, axis: 200),
            cp(40, percent: 4, axis: 400),
            cp(1_000, percent: 100, axis: 9_000, notScored: true),
            cp(2_000, percent: 200, axis: 9_000, after: true),
        ]
        let a = ReplayErrorAggregates(checkpoints)
        #expect(a.errorMedianM == 20 && a.errorP90M == 40)
        #expect(a.errorMedianPercent == 3 && a.errorP90Percent == 4)
        #expect(a.ellipseSemiMajorMedianM == 200)
        let none = ReplayErrorAggregates([cp(nil, percent: nil, axis: nil)])
        #expect(none.errorMedianM == nil && none.errorP90Percent == nil && none.ellipseSemiMajorMedianM == nil)
    }

    @Test("A run's aggregates are the helper's over its checkpoints, and metrics.json carries them; ESS min is positive and at most the particle count")
    func runAggregatesInMetrics() throws {
        let run = Self.run(Self.events, Self.options(.none))
        let metrics = ReplayMetrics(run)
        let a = ReplayErrorAggregates(run.checkpoints)
        #expect(a.errorMedianM != nil)
        #expect(metrics.errorMedianM == a.errorMedianM && metrics.errorP90M == a.errorP90M)
        #expect(metrics.errorMedianPercent == a.errorMedianPercent && metrics.errorP90Percent == a.errorP90Percent)
        #expect(metrics.ellipseSemiMajorMedianM == a.ellipseSemiMajorMedianM)
        let ess = try #require(metrics.essMin)
        #expect(ess > 0 && ess <= 300)
        #expect(metrics.lastFixBaseline == run.lastFixBaseline && metrics.obdWithheld == run.obdWithheld)
        let summary = ReplayReport.summary(run)
        #expect(summary.contains("OBD           none: "))
        #expect(summary.contains("distance for scoring is still ∫ OBD speed from the log"))
        #expect(summary.contains("Error dist.   scored "))
    }
}
