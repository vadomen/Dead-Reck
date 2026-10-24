import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// Prompt 40, the Navigate → Record hand-over (log v5 `navPrior`): Record's
/// run starts from the Navigate estimate written into the recording, so the
/// recording replays bit-exactly (`replay_nav` reads the row). Synthetic
/// drive at 80 km/h due north from (0, 0), synthetic clocks; no real place,
/// date or recording.
@Suite("Navigation prompt 40: Navigate → Record hand-over")
struct NavigationHandOverTests {
    typealias S = SyntheticDrive

    // MARK: Fixture

    /// 80 km/h (22.2 m/s) due north along x = 0 for 150 s, already moving.
    static let speed = 22.2
    static let drive = S(initialHeadingDeg: 0, initialSpeed: speed, [.straight(seconds: 150, speed: speed)])
    /// Record's Start, on the drive's (Navigate's) clock.
    static let switchT = 60.0
    /// Clean fixes until the switch, none after (jammed).
    static let events = drive.events(gyroNoise: 0.001, fix: { t, state, rng in
        t < switchT ? S.cleanFix()(t, state, &rng) : nil
    })
    static let navigateConfig = S.config(particles: 500, seed: 1)
    static let recordConfig = S.config(particles: 500, seed: 2)
    /// Navigate's clock: the recording's reference uptime minus `switchT`.
    static let recordingUptime = WriterFixtures.header.referenceUptimeSeconds
    static let navigateClock = SessionClock(referenceUptimeSeconds: recordingUptime - switchT,
                                            wallClockStart: Date(timeIntervalSince1970: 2_000_000_000))
    static let recordClock = SessionClock(header: WriterFixtures.header)

    /// The init replay's speed reading, stamped when the link connected
    /// (40 s before Record's Start): the recording's first engine input.
    static let initReplayOBD = LogEvent.obd(OBDSample(pid: .vehicleSpeed, value: 30, unit: .kilometersPerHour,
                                                      ecu: "7E8"), at: MonotonicTimestamp(seconds: -40))

    /// Navigate's run over the drive's inputs arriving before `until`.
    static func navigate(until: Double) -> LiveNavigationRun {
        var run = LiveNavigationRun(sessionID: UUID(), config: navigateConfig, appBuild: "test")
        for input in S.inputs(events) where input.arrival < S.ms(until) { run.ingest(input) { _ in } }
        return run
    }

    /// The `navPrior` row the app writes at Record's Start from Navigate's
    /// estimate at its last step, the estimate `ageS` old at the Start.
    static func handOverRow(ageS: Double) throws -> NavPriorSample {
        let run = navigate(until: switchT - ageS)
        let state = try #require(run.restoreState(clock: navigateClock, bootSessionID: nil, engineOff: false))
        return try #require(NavPriorSample(handOver: state, clock: recordClock))
    }

    /// The drive's events from the Start on, on Record's clock, in file
    /// order; `initReplay`: the stale init-replay reading first.
    static func recordEvents(initReplay: Bool = true) -> [LogEvent] {
        let shift = S.ms(switchT).nanoseconds
        let after = events.compactMap { event -> LogEvent? in
            guard let input = NavigationInput(event), input.arrival >= S.ms(switchT) else { return nil }
            return event.shifted(by: -shift)
        }
        return (initReplay ? [initReplayOBD] : []) + after
    }

    /// Estimates of `run` fed `inputs` at each of `times` (session seconds),
    /// from the state before the first input arriving after the time.
    static func sample(_ run: inout LiveNavigationRun, _ inputs: [NavigationInput], at times: [Double])
        -> [NavigationEstimate?] {
        var out: [NavigationEstimate?] = []
        var pending = times[...]
        for input in inputs {
            while let t = pending.first, S.ms(t) < input.arrival {
                out.append(run.engine.estimate(at: S.ms(t)))
                pending = pending.dropFirst()
            }
            run.ingest(input) { _ in }
        }
        for t in pending { out.append(run.engine.estimate(at: S.ms(t))) }
        return out
    }

    /// `b` relative to `a`, metres: along `a`'s heading and the distance.
    static func offset(_ a: NavigationEstimate, _ b: NavigationEstimate) -> (along: Double, distance: Double) {
        let p = S.plane.enu(latitude: a.latitude, longitude: a.longitude)
        let q = S.plane.enu(latitude: b.latitude, longitude: b.longitude)
        let h = a.headingDeg * .pi / 180
        let dE = q.east - p.east, dN = q.north - p.north
        return (dE * sin(h) + dN * cos(h), (dE * dE + dN * dN).squareRoot())
    }

    /// Major-axis σ of an estimate's position covariance, metres.
    static func sigma(_ e: NavigationEstimate) -> Double {
        let c = e.ellipse.covariance
        return NavigationPrior.majorVariance(c.ee, c.en, c.nn).squareRoot()
    }

    // MARK: Engine

    @Test("Inputs older than a pending prior (the init replay's reading from the link's connect) are ignored, clock included: the run is exactly the one without them; a fresh run is unchanged")
    func inputsBeforeThePriorAreIgnored() throws {
        let prior = try #require(try Self.handOverRow(ageS: 1).navigationPrior)
        let times = [0.05, 0.5, 1, 5, 20, 60]
        var with = LiveNavigationRun(sessionID: UUID(), config: Self.recordConfig, appBuild: "test", prior: prior)
        var without = with
        let a = Self.sample(&with, S.inputs(Self.recordEvents(initReplay: true)), at: times)
        let b = Self.sample(&without, S.inputs(Self.recordEvents(initReplay: false)), at: times)
        #expect(a == b)
        #expect(with.engine.restore.inputsOlderThanSave == 1 && without.engine.restore.inputsOlderThanSave == nil)
        #expect(with.engine.restore.status == .confirmed && with.engine.restore.reason == .handOver)
        #expect(with.engine.restore.decidedT == S.ms(0), "applied at Record's first live input, not at the old reading")
        let first = try #require(a[0])
        #expect(Self.drive.error(first, at: Self.switchT + 0.05) < 5)

        // No prior: the old reading is an input as always.
        var fresh = LiveNavigationRun(sessionID: UUID(), config: Self.recordConfig, appBuild: "test")
        fresh.ingest(try #require(NavigationInput(Self.initReplayOBD))) { _ in }
        #expect(fresh.engine.lastOBDSpeed?.kmh == 30)
        #expect(fresh.engine.restore == NavigationRestore())
    }

    // MARK: 80 km/h, a 1 s old estimate (user case)

    @Test("Hand-over at 80 km/h from a 1 s old estimate, GPS jammed after it: Record within 2σ of the uncut run at the switch and for 60 s after; the mean carried forward v·gap (no lag); converged and heading kept")
    func handOverAt80KmhKeepsUpWithTheUncutRun() throws {
        let row = try Self.handOverRow(ageS: 1)
        let prior = try #require(row.navigationPrior)
        let gapS = -prior.savedT.seconds
        #expect(gapS > 1 && gapS < 1.2, "1 s plus Navigate's last step: \(gapS)")
        #expect(row.converged && row.restoreClass == "moving" && abs(row.speedMps - Self.speed) < 0.5)

        let times = [0.01, 0.1, 0.5, 1, 2, 5, 10, 20, 30, 60]
        var record = LiveNavigationRun(sessionID: UUID(), config: Self.recordConfig, appBuild: "test", prior: prior)
        let recorded = Self.sample(&record, S.inputs(Self.recordEvents()), at: times)
        // The uncut run: Navigate on the same inputs with no switch.
        var uncut = LiveNavigationRun(sessionID: UUID(), config: Self.navigateConfig, appBuild: "test")
        let continued = Self.sample(&uncut, S.inputs(Self.events), at: times.map { $0 + Self.switchT })

        var rows: [String] = []
        for (k, t) in times.enumerated() {
            let r = try #require(recorded[k]), u = try #require(continued[k])
            let (along, distance) = Self.offset(u, r)
            let sigma = Self.sigma(r)
            #expect(distance <= 2 * sigma, "t \(t): \(distance) m from the uncut run, 2σ \(2 * sigma) m")
            #expect(r.converged, "t \(t): converged kept")
            #expect(abs(angleDifference(r.headingDeg, u.headingDeg)) < 3, "t \(t): heading \(r.headingDeg) vs \(u.headingDeg)")
            // No lag: carried forward by the last speed over the gap. Without
            // the shift Record would trail by v·gap ≈ 24 m.
            #expect(abs(along) < 0.25 * Self.speed * gapS, "t \(t): along-track \(along) m")
            rows.append(String(format: "t %5.2f s: vs uncut %5.1f m (along %+5.1f m), 2σ %5.1f m; vs truth %5.1f m (uncut %5.1f m)",
                               t, distance, along, 2 * sigma, Self.drive.error(r, at: t + Self.switchT),
                               Self.drive.error(u, at: t + Self.switchT)))
        }
        #expect(record.engine.restore.status == .confirmed && record.engine.restore.reason == .handOver)
        #expect(record.engine.counters.reseeds == 0)
        print("Prompt 40 hand-over at 80 km/h, estimate \(String(format: "%.2f", gapS)) s old:\n" + rows.joined(separator: "\n"))
    }

    // MARK: Roads

    @Test("Roads: the hand-over run's normal selection request fires at its first live input and attaches the covering pack there; a fresh run (jammed) never selects")
    func handOverRunSelectsRoadsAtOnce() throws {
        let road = try RoadFixture.build([RoadFixture.way(1, ["highway": "primary"], [
            RoadFixture.Node(id: 10, east: 0, north: -1000), RoadFixture.Node(id: 11, east: 0, north: 6000),
        ])])
        let given = ReplayRoadSet(try RoadNetwork(packs: [road]))
        let prior = try #require(try Self.handOverRow(ageS: 1).navigationPrior)
        let inputs = S.inputs(Self.recordEvents())

        var handed = LiveNavigationRun(sessionID: UUID(), config: Self.recordConfig, appBuild: "test", prior: prior)
        var selector = given.selector
        var lines: [NavSidecar.Line] = []
        var requestAt: Int?
        for input in inputs {
            handed.ingest(input, selector: &selector) { lines.append($0) }
            if requestAt == nil, selector.requests > 0 { requestAt = handed.inputs }
        }
        // Input 1 is the init replay's reading (ignored by the engine); the
        // first live input applies the prior, raises the request and attaches.
        let attached = try #require(handed.attachments.first)
        #expect(requestAt == 2 && attached.afterInputs == 2)
        #expect(attached.t == inputs[1].arrival, "attached at \(String(describing: attached.t?.seconds)) s")
        #expect(handed.engine.estimate(at: S.ms(60))?.onRoadShare ?? 0 > 0.9)
        print("Prompt 40 roads: hand-over Record run attached after input \(attached.afterInputs) at t \(attached.t?.seconds ?? .nan) s")

        var fresh = LiveNavigationRun(sessionID: UUID(), config: Self.recordConfig, appBuild: "test")
        var freshSelector = given.selector
        for input in inputs { fresh.ingest(input, selector: &freshSelector) { _ in } }
        #expect(fresh.roads == nil && freshSelector.requests == 0)
    }

    // MARK: replay_nav

    @Test("replay_nav's choice for a navPrior row: used by default, replaced by --prior, dropped by --no-prior; no row: absent whatever the flags")
    func recordedPriorChoice() throws {
        let row = try Self.handOverRow(ageS: 1)
        let prior = try #require(row.navigationPrior)
        #expect(ReplayRecordedPrior.choose(row: row, explicitPrior: false, noPrior: false) == .used(prior))
        #expect(ReplayRecordedPrior.choose(row: row, explicitPrior: true, noPrior: false) == .overridden)
        #expect(ReplayRecordedPrior.choose(row: row, explicitPrior: true, noPrior: true) == .overridden)
        #expect(ReplayRecordedPrior.choose(row: row, explicitPrior: false, noPrior: true) == .ignored)
        for explicit in [false, true] {
            for noPrior in [false, true] {
                let choice = ReplayRecordedPrior.choose(row: nil, explicitPrior: explicit, noPrior: noPrior)
                #expect(choice == .absent && choice.prior == nil && choice.note(firstInput: nil) == nil)
            }
        }
        #expect(ReplayRecordedPrior.ignored.prior == nil && ReplayRecordedPrior.overridden.prior == nil)
        var invalid = row
        invalid.restoreClass = "towed"
        #expect(ReplayRecordedPrior.choose(row: invalid, explicitPrior: false, noPrior: false) == .invalid(field: "restoreClass"))
        let used = ReplayRecordedPrior.used(prior)
        let inputs = S.inputs(Self.recordEvents())
        #expect(inputs[0].arrival == S.ms(-40) && used.startInput(in: inputs) == inputs[1].arrival,
                "the init replay's reading is not where the prior starts")
        #expect(ReplayRecordedPrior.ignored.startInput(in: inputs) == nil)
        let note = try #require(used.note(firstInput: used.startInput(in: inputs)))
        #expect(note.contains("navPrior") && note.contains("converged true") && note.contains("1.10 s before"))
        #expect(!note.contains("seed "), "seed is the RNG seed's word")
        #expect(!note.contains(String(format: "%.4f", row.latitude)), "no position printed")

        // Label: -prior for the row, -restored for --prior; none without.
        var options = ReplayOptions(gps: .use)
        options.asLive = true
        #expect(options.label == "use-as-live")
        options.prior = prior
        #expect(options.label == "use-as-live-restored")
        options.priorSource = .recording
        #expect(options.label == "use-as-live-prior")
    }

    // MARK: replay_nav --start-at on a v5 file (R78.2-2)

    /// The row's prior started from Record's first live input over the
    /// recording's inputs arriving before `cutS`, handed over as the app
    /// would at its last step: LiveNavigationRun's own path, not the replay's.
    static func appHandOver(from prior: NavigationPrior, before cutS: Double) throws -> NavigationPrior {
        var run = LiveNavigationRun(sessionID: UUID(), config: recordConfig, appBuild: "test", prior: prior)
        for input in S.inputs(recordEvents()) where input.arrival < S.ms(cutS) { run.ingest(input) { _ in } }
        var state = try #require(run.restoreState(clock: recordClock, bootSessionID: nil, engineOff: false))
        if run.engine.restore.status == .unconfirmed { state.converged = false }
        return try #require(NavPriorSample(handOver: state, clock: recordClock)?.navigationPrior)
    }

    @Test("--start-at past the row's start input: the cut starts from the estimate at the cut (the app's hand-over of the run before it, bit-exact), confirmed at once and on the truth; the drive-start prior grown over the cut would be unconverged and ~700 m wide; the note describes the cut")
    func startAtCutStartsFromTheEstimateAtTheCut() throws {
        let row = try Self.handOverRow(ageS: 1)
        let prior = try #require(row.navigationPrior)
        let inputs = S.inputs(Self.recordEvents())
        let cutS = 30.0
        let options = ReplayOptions(gps: .use, config: Self.recordConfig)
        let choice = ReplayRecordedPrior.used(prior).atCut(startAtS: cutS, inputs: inputs, options: options,
                                                           clock: Self.recordClock)
        guard case .cut(let cutPrior, let atS) = choice else {
            Issue.record("expected the estimate at the cut, got \(choice)")
            return
        }
        #expect(atS == cutS && choice.prior == cutPrior)
        #expect(cutPrior == (try Self.appHandOver(from: prior, before: cutS)), "the row the app would have written at the cut")
        #expect(cutPrior.savedT < S.ms(cutS) && cutPrior.savedT.seconds > cutS - 0.2, "the last step before the cut: \(cutPrior.savedT.seconds)")
        #expect(cutPrior.handOver && cutPrior.converged && cutPrior.restoreClass == .moving)
        #expect(abs(cutPrior.lastSpeedMps - Self.speed) < 0.5)
        #expect(choice == ReplayRecordedPrior.used(prior).atCut(startAtS: cutS, inputs: inputs, options: options,
                                                                 clock: Self.recordClock), "deterministic")

        // The cut from it: confirmed at once, near the truth from its first input.
        let cutInputs = inputs.filter { $0.arrival >= S.ms(cutS) }
        let times = [cutS + 0.05, cutS + 1, cutS + 10, 89.0]
        var fromCut = LiveNavigationRun(sessionID: UUID(), config: Self.recordConfig, appBuild: "test", prior: cutPrior)
        let cut = Self.sample(&fromCut, cutInputs, at: times)
        #expect(fromCut.engine.restore.status == .confirmed && fromCut.engine.restore.reason == .handOver)
        // The uncut Record run (the row's prior, every input) at the same times.
        var uncut = LiveNavigationRun(sessionID: UUID(), config: Self.recordConfig, appBuild: "test", prior: prior)
        let continued = Self.sample(&uncut, inputs, at: times)
        var rows: [String] = []
        for (k, t) in times.enumerated() {
            let e = try #require(cut[k]), u = try #require(continued[k])
            let error = Self.drive.error(e, at: t + Self.switchT)
            let distance = Self.offset(u, e).distance
            #expect(error < 30 && e.converged, "t \(t): \(error) m from the truth")
            #expect(distance < 5, "t \(t): \(distance) m from the uncut run (σ \(Self.sigma(e)) m)")
            rows.append(String(format: "t %5.2f s: vs truth %5.1f m, vs uncut %5.1f m, σ %5.1f m", t, error, distance, Self.sigma(e)))
        }
        print("R78.2-2 cut at \(cutS) s from the estimate at the cut:\n" + rows.joined(separator: "\n"))
        // Before R78.2-2: the drive-start prior grown over ~31 s.
        var stale = LiveNavigationRun(sessionID: UUID(), config: Self.recordConfig, appBuild: "test", prior: prior)
        let staleFirst = try #require(Self.sample(&stale, cutInputs, at: [cutS + 0.05])[0])
        #expect(Self.sigma(staleFirst) > 300 && !staleFirst.converged, "stale: σ \(Self.sigma(staleFirst)) m")
        print(String(format: "R78.2-2 stale drive-start prior at the cut: σ %.0f m, converged %@", Self.sigma(staleFirst),
                     staleFirst.converged ? "true" : "false"))
        #expect(stale.engine.restore.reason != .handOver)

        // The replay's cut run, labelled -from-30-prior.
        var cutOptions = options
        cutOptions.startAtS = cutS
        cutOptions.prior = choice.prior
        cutOptions.priorSource = .recording
        let result = NavigationReplay.run(logName: "handover", inputs: inputs, options: cutOptions)
        #expect(result.mode == "use-from-30-prior")
        #expect(result.restore?.status == .confirmed && result.restore?.reason == .handOver)

        // The note: the cut's inputs, not the uncut start (1.10 s).
        let note = try #require(choice.note(firstInput: choice.startInput(in: cutInputs)))
        #expect(note.contains("estimate at the cut") && note.contains("--start-at 30 s"))
        #expect(note.contains("before the input the cut starts at (t \(String(format: "%.2f", cutInputs[0].arrival.seconds)) s)"), "\(note)")
        #expect(!note.contains("1.10 s before") && note.contains("converged true"))
        #expect(!note.contains(String(format: "%.4f", cutPrior.latitude)), "no position printed")
    }

    @Test("--start-at: a cut at or before the row's start input keeps the row's prior; no row, --prior, --no-prior and an invalid row are unchanged by a cut")
    func startAtCutBeforeTheStartInputAndOtherChoices() throws {
        let row = try Self.handOverRow(ageS: 1)
        let prior = try #require(row.navigationPrior)
        let inputs = S.inputs(Self.recordEvents())
        let options = ReplayOptions(gps: .use, config: Self.recordConfig)
        let start = try #require(ReplayRecordedPrior.used(prior).startInput(in: inputs))
        // -10 drops only the init replay's reading (older than the estimate).
        for cutS in [-50, -10, start.seconds] {
            #expect(ReplayRecordedPrior.used(prior).atCut(startAtS: cutS, inputs: inputs, options: options,
                                                          clock: Self.recordClock) == .used(prior), "cut at \(cutS) s")
        }
        let cutS = start.seconds + 0.001
        #expect(ReplayRecordedPrior.used(prior).atCut(startAtS: cutS, inputs: inputs, options: options,
                                                      clock: Self.recordClock).prior != prior)
        for choice in [ReplayRecordedPrior.absent, .overridden, .ignored, .invalid(field: "restoreClass")] {
            #expect(choice.atCut(startAtS: 30, inputs: inputs, options: options, clock: Self.recordClock) == choice)
        }
    }

    @Test("--start-at: an unconverged row hands over unconverged at the cut (the run is an unconfirmed restore); a run with no position before the cut starts the cut fresh, with a note")
    func startAtCutUnconvergedAndNoEstimate() throws {
        let inputs = S.inputs(Self.recordEvents())
        let options = ReplayOptions(gps: .use, config: Self.recordConfig)
        // Navigate still "finding its position": converged false, no fix
        // after it, so the restore stays unconfirmed through the cut.
        var unconverged = try Self.handOverRow(ageS: 1)
        unconverged.converged = false
        let prior = try #require(unconverged.navigationPrior)
        let choice = ReplayRecordedPrior.used(prior).atCut(startAtS: 30, inputs: inputs, options: options,
                                                           clock: Self.recordClock)
        let cutPrior = try #require(choice.prior)
        #expect(cutPrior.savedT.seconds > 29.8 && !cutPrior.converged && cutPrior.handOver)
        #expect(cutPrior == (try Self.appHandOver(from: prior, before: 30)))
        #expect(cutPrior.headingStdDeg < 30, "the run itself has a heading; only `converged` is withheld")

        // A row 5 min old: the grown prior is over 1.5 km, the run starts
        // fresh and, jammed, has no position before the cut.
        var old = try Self.handOverRow(ageS: 1)
        old.estimateT = MonotonicTimestamp(seconds: -300)
        let oldPrior = try #require(old.navigationPrior)
        let none = ReplayRecordedPrior.used(oldPrior).atCut(startAtS: 30, inputs: inputs, options: options,
                                                            clock: Self.recordClock)
        #expect(none == .noEstimateAtCut(atS: 30) && none.prior == nil)
        #expect(none.startInput(in: inputs) == nil)
        let note = try #require(none.note(firstInput: nil))
        #expect(note.contains("--start-at 30 s") && note.contains("no estimate at the cut") && note.contains("fresh"))
        var cutOptions = options
        cutOptions.startAtS = 30
        cutOptions.prior = none.prior
        #expect(cutOptions.label == "use-from-30")
    }

    @Test("A synthetic v5 recording with a navPrior row: the app path's sidecar (the tap into LiveNavigationRun started from the feed's row) equals replay_nav --as-live --compare exactly; without the row's prior it does not")
    func liveSidecarWithNavPriorMatchesAsLive() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let row = try Self.handOverRow(ageS: 1)
        // File order as RecordingSession writes it: start, navPrior, the
        // init replay (with its old reading), then the sources.
        let events = [LogEvent(timestamp: .zero, payload: .lifecycle(LifecycleSample(.start))),
                      LogEvent(timestamp: MonotonicTimestamp(nanoseconds: 2_000_000), payload: .navPrior(row))]
            + NavigationLiveTests.recorderOrder(Self.recordEvents())
        let tap = NavigationTap(bufferLimit: 1_000_000)
        let writer = try TapFixtures.writer(scratch, "handover.jsonl.gz", tap: tap.tap)
        let sidecarURL = NavSidecarFile.url(forRecording: scratch.file("handover.jsonl.gz"))
        let header = WriterFixtures.header
        // NavigationService.begin for a recording: LiveNavigationRun(header:
        // appBuild:prior: feed.navPrior?.navigationPrior).
        let livePrior = row.navigationPrior
        let consumer = Task {
            var run = LiveNavigationRun(header: header, appBuild: "test", prior: livePrior)
            let out = try NavSidecarWriter(url: sidecarURL)
            for line in run.openingLines { out.append(line) }
            for await input in tap.inputs {
                run.ingest(input, droppedInputs: tap.droppedInputs) { out.append($0) }
            }
            out.close()
            return (run.estimates, run.engine.restore, out.failure)
        }
        let summary = try await TapFixtures.write(events, to: writer)
        tap.finish()
        let (estimateCount, restore, failure) = try await consumer.value
        #expect(failure == nil && tap.droppedInputs == 0)
        #expect(restore.status == .confirmed && restore.reason == .handOver && restore.inputsOlderThanSave == 1)

        let read = try WriterFixtures.read(summary.url, recovery: .strict)
        #expect(read.header.formatVersion == .v5)
        let recorded = try #require(NavigationReplay.recordedPrior(in: read.events))
        #expect(recorded == row)
        let choice = ReplayRecordedPrior.choose(row: recorded, explicitPrior: false, noPrior: false)
        let prior = try #require(choice.prior)
        let contents = try NavSidecar.read(contentsOf: sidecarURL)
        let config = NavigationConfig(seed: NavigationSeed.derive(header: read.header))
        let fileOrder = NavigationReplay.fileOrderInputs(from: read.events)
        let asLive = NavigationReplay.liveLines(inputs: fileOrder, sessionID: read.header.sessionID, config: config,
                                                prior: prior)
        let comparison = SidecarComparison(sidecar: contents, replay: asLive, replayConfig: config)
        #expect(comparison.exact, "\(comparison.report(tolerance: .default))")
        #expect(comparison.estimates.matched == estimateCount && estimateCount >= 80)
        #expect(comparison.passes(SidecarComparison.Tolerance(metres: 0, degrees: 0)))

        // --no-prior (the row ignored): not what ran live.
        let ignored = NavigationReplay.liveLines(inputs: fileOrder, sessionID: read.header.sessionID, config: config)
        #expect(!SidecarComparison(sidecar: contents, replay: ignored, replayConfig: config).exact)

        // The metrics replay starts from the row too, labelled -prior.
        var options = ReplayOptions(gps: .use, config: config)
        options.asLive = true
        options.fileOrder = true
        options.prior = prior
        options.priorSource = .recording
        let result = NavigationReplay.run(logName: "handover", inputs: fileOrder, options: options)
        #expect(result.mode == "use-as-live-prior")
        #expect(result.restore?.status == .confirmed && result.restore?.reason == .handOver)

        // For the CLI proof: keep the pair where the caller asks (scratch only).
        if let directory = ProcessInfo.processInfo.environment["NAV_HANDOVER_FIXTURE_DIR"] {
            let target = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for url in [summary.url, sidecarURL] {
                let destination = target.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: url, to: destination)
            }
        }
    }
}

extension LogEvent {
    /// The same event `ns` nanoseconds later (negative: earlier), on another
    /// session clock; a fix's arrival moves with it. Motion, OBD and fixes.
    func shifted(by ns: Int64) -> LogEvent {
        func m(_ t: MonotonicTimestamp) -> MonotonicTimestamp { MonotonicTimestamp(nanoseconds: t.nanoseconds + ns) }
        var payload = payload
        if case .location(var sample) = payload {
            sample.receivedT = sample.receivedT.map(m)
            payload = .location(sample)
        }
        return LogEvent(timestamp: m(timestamp), payload: payload)
    }
}
