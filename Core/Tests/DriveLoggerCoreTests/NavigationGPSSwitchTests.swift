import Foundation
import Testing

@testable import DriveLoggerCore

/// UX-9 a: the driver's "GPS off" switch (log v4 `gpsSwitch`). While it is
/// off, fixes with a valid speed never reach the filter; network fixes,
/// pins, OBD, motion and roads are used as before. Synthetic drives near
/// (0, 0) only: no real place, date or recording.
@Suite("Navigation UX-9 a: GPS off switch")
struct NavigationGPSSwitchTests {
    typealias S = SyntheticDrive

    // MARK: Fixtures

    /// 80 s: away from a stop, a right turn, a stop (46–54 s), a left turn.
    static let drive = S(initialHeadingDeg: 30, [
        .ramp(seconds: 5, from: 0, to: 12), .straight(seconds: 15, speed: 12), .turn(degrees: 90, seconds: 6, speed: 10),
        .straight(seconds: 20, speed: 12), .stop(seconds: 8), .ramp(seconds: 4, from: 0, to: 10),
        .turn(degrees: -60, seconds: 5, speed: 10), .straight(seconds: 17, speed: 12),
    ])

    static let offT = 20.5
    static let onT = 50.5

    static func gpsSwitch(_ on: Bool, at t: Double) -> LogEvent {
        LogEvent(timestamp: S.ms(t), payload: .gpsSwitch(GPSSwitchSample(on: on, source: .driver)))
    }

    /// A clean GNSS fix every second, except a network fix (no speed,
    /// 300 m, 0.4 s late, biased) every 5 s from 2 s; a pin at 35 s (GPS
    /// off then); `extra` events (the switch).
    static func events(_ extra: [LogEvent] = []) -> [LogEvent] {
        let clean = S.cleanFix(accuracy: 6, positionNoise: 2)
        let pinT = 35.0
        let truth = drive.truth(at: pinT)
        let p = S.plane.geodetic(east: truth.east + 15, north: truth.north - 10)
        let pin = LogEvent(timestamp: S.ms(pinT), payload: .manualFix(ManualFixSample(
            latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(pinT), mapSpanM: 360, speedSource: "obd")))
        return drive.events(gyroNoise: 0.002, fix: { t, state, rng in
            if Int(t.rounded()) % 5 == 2 {
                return S.Fix(east: state.east + 80, north: state.north - 50, accuracy: 300, latency: 0.4)
            }
            return clean(t, state, &rng)
        }, extra: [pin] + extra)
    }

    /// Off at `offT`, on at `onT`.
    static let switched = events([gpsSwitch(false, at: offT), gpsSwitch(true, at: onT)])

    /// The same recording with no switch, and without the fixes the
    /// switch withholds (a valid speed, arriving while off).
    static let deleted = events().filter { !withheld($0) }

    static func withheld(_ event: LogEvent) -> Bool {
        guard let input = NavigationInput(event), case .location(let sample, _) = input, sample.hasValidSpeed else {
            return false
        }
        return input.arrival > S.ms(offT) && input.arrival < S.ms(onT)
    }

    /// Feeds `inputs` in the order given; the estimate at every whole
    /// second up to `end`, from the state before the first measurement
    /// arriving after it (after the last one: the final state).
    static func run(_ inputs: [NavigationInput], config: NavigationConfig = S.config(particles: 300),
                    roads: RoadNetwork? = nil, end: Double = 80) -> (engine: NavigationEngine, estimates: [NavigationEstimate?]) {
        var engine = NavigationEngine(config: config, roads: roads)
        var estimates: [NavigationEstimate?] = []
        var next = 1.0
        for input in inputs {
            while next <= end, S.ms(next) < input.arrival, !input.isGPSSwitch {
                estimates.append(engine.estimate(at: S.ms(next)))
                next += 1
            }
            engine.ingest(input)
        }
        while next <= end {
            estimates.append(engine.estimate(at: S.ms(next)))
            next += 1
        }
        return (engine, estimates)
    }

    static func state(_ e: NavigationEngine) -> [[Double]] { NavigationRoadTests.state(e) }

    // MARK: The gate

    @Test("Arrival order: GNSS fixes while off never reach the engine (bit-identical to deleting them); network fixes and the pin are used")
    func offFixesWithheldArrivalOrder() throws {
        let withheldCount = Self.events().filter(Self.withheld).count
        #expect(withheldCount == 24, "fixes at 21…50 s, network seconds excluded")
        let networkWhileOff = Self.deleted.filter { event in
            guard let input = NavigationInput(event), case .location(let s, _) = input else { return false }
            return !s.hasValidSpeed && input.arrival > S.ms(Self.offT) && input.arrival < S.ms(Self.onT)
        }.count
        #expect(networkWhileOff == 6)

        let a = Self.run(S.inputs(Self.switched))
        let b = Self.run(S.inputs(Self.deleted))
        #expect(a.engine.fixesWithheldByGPSSwitch == withheldCount && b.engine.fixesWithheldByGPSSwitch == 0)
        #expect(a.engine.gpsOn && b.engine.gpsOn)
        #expect(Self.state(a.engine) == Self.state(b.engine))
        #expect(a.estimates == b.estimates && a.estimates.count == 80)
        #expect(a.engine.counters == b.engine.counters)
        // Network fixes while off counted as used (16 of them in all), the pin too.
        #expect(a.engine.counters.networkFixesUsed == 16 && a.engine.counters.manualFixes == 1)

        // And the switch matters: with every fix the run differs.
        let all = Self.run(S.inputs(Self.events()))
        #expect(Self.state(all.engine) != Self.state(a.engine))
        #expect(all.engine.counters.fixesUsed == a.engine.counters.fixesUsed + withheldCount)
    }

    @Test("File order (motion written late in 100 ms batches): still bit-identical to deleting the withheld fixes")
    func offFixesWithheldFileOrder() {
        let order = NavigationLiveTests.recorderOrder
        let a = Self.run(order(Self.switched).compactMap(NavigationInput.init))
        let b = Self.run(order(Self.deleted).compactMap(NavigationInput.init))
        #expect(a.engine.fixesWithheldByGPSSwitch == 24)
        #expect(Self.state(a.engine) == Self.state(b.engine))
        #expect(a.estimates == b.estimates && a.engine.counters == b.engine.counters)
    }

    @Test("Network fixes while off are processed exactly as before; GNSS fixes before the switch are not touched")
    func networkFixesStillUsed() {
        // Off for the whole drive (from before the first input): only the
        // network fixes and the pin can position the cloud.
        let events = Self.events([Self.gpsSwitch(false, at: -1)])
        let off = Self.run(S.inputs(events))
        let gnssFree = Self.run(S.inputs(Self.events().filter { event in
            guard case .location(let s) = event.payload else { return true }
            return !s.hasValidSpeed
        }))
        let gnss = Self.events().filter { if case .location(let s) = $0.payload { s.hasValidSpeed } else { false } }.count
        #expect(gnss == 65)
        #expect(!off.engine.gpsOn && off.engine.fixesWithheldByGPSSwitch == gnss)
        #expect(off.engine.isInitialized && off.engine.counters.networkFixesUsed == 16)
        #expect(Self.state(off.engine) == Self.state(gnssFree.engine) && off.estimates == gnssFree.estimates)

        #expect(off.engine.counters == gnssFree.engine.counters)
    }

    @Test("A switch alone changes nothing: a repeat, an off/on pair with no fix between, a switch with a corrupt huge t")
    func switchAloneChangesNothing() {
        let extra = [Self.gpsSwitch(true, at: 3.3),                                   // repeat of on
                     Self.gpsSwitch(false, at: 30.2), Self.gpsSwitch(true, at: 30.6)]  // no fix arrives between
        let plain = S.inputs(Self.events())
        var inputs = S.inputs(Self.events(extra))
        // A corrupt t far in the future, mid-drive (a repeat of on): taken,
        // no time-jump rejection, no clock moved.
        let corrupt = NavigationInput.gpsSwitch(GPSSwitchSample(on: true, source: .driver),
                                                at: MonotonicTimestamp(seconds: 9e8))
        inputs.insert(corrupt, at: inputs.count / 2)
        let a = Self.run(inputs)
        let b = Self.run(plain)
        #expect(Self.state(a.engine) == Self.state(b.engine) && a.estimates == b.estimates)
        #expect(a.engine.counters == b.engine.counters && a.engine.counters.inputsRejectedTimeJump == 0)
        #expect(a.engine.fixesWithheldByGPSSwitch == 0 && a.engine.gpsOn)

        // The live loop: same lines, the switch emits none.
        var live = LiveNavigationRun(sessionID: UUID(), config: S.config(particles: 300), appBuild: "test")
        var reference = LiveNavigationRun(sessionID: live.sessionID, config: live.engine.config, appBuild: "test")
        var linesA: [NavSidecar.Line] = [], linesB: [NavSidecar.Line] = []
        for input in inputs { live.ingest(input) { linesA.append($0) } }
        for input in plain { reference.ingest(input) { linesB.append($0) } }
        #expect(Self.stripTiming(linesA) == Self.stripTiming(linesB) && linesA.count > 70)
        #expect(live.inputs == reference.inputs + 4, "every switch is an input handed to the run")
    }

    /// The lines without their timing diagnostics (never compared).
    static func stripTiming(_ lines: [NavSidecar.Line]) -> [NavSidecar.Line] {
        func strip(_ e: NavSidecar.Estimate) -> NavSidecar.Estimate {
            var e = e
            e.msPerStep = nil
            e.maxStepMs = nil
            return e
        }
        return lines.map {
            switch $0 {
            case .estimate(let e): return .estimate(strip(e))
            case .pin(var p):
                p.prior = p.prior.map(strip)
                return .pin(p)
            default: return $0
            }
        }
    }

    // MARK: Held stale fix

    typealias H = NavigationHeldFixTests

    static func switchInput(_ on: Bool, _ t: Double) -> NavigationInput {
        NavigationInput(gpsSwitch(on, at: t))!
    }

    @Test("A held stale GNSS fix is dropped at switch-off and never applied after the switch is back on")
    func heldFixDroppedAtSwitchOff() {
        // As NavigationHeldFixTests.liveOrder, with an off/on pair between
        // the held fix and the deciding OBD 0.
        let inputs: [NavigationInput] = [H.motion(0.01), H.fix(-60, arrival: 0.06), Self.switchInput(false, 0.062),
                                         Self.switchInput(true, 0.064), H.motion(0.07), H.motion(0.08),
                                         H.obd(0, 0.015), H.motion(0.09)]
        let engine = H.engine(inputs)
        #expect(!engine.isInitialized, "a fix from before the tap must never be applied after it")
        #expect(!engine.hasHeldFix && engine.fixesWithheldByGPSSwitch == 1)
        #expect(engine.counters.fixesHeld == 1 && engine.counters.heldFixesUsed == 0 && engine.counters.fixesUsed == 0)
        // Without the switch the same fix is used (the held-fix rule).
        #expect(H.engine(H.liveOrder).isInitialized)

        // Arriving while off: withheld on arrival, never held.
        let whileOff = H.engine([H.motion(0.01), Self.switchInput(false, 0.02), H.fix(-60, arrival: 0.06),
                                 H.motion(0.07), H.obd(0, 0.015), H.motion(0.09)])
        #expect(!whileOff.isInitialized && whileOff.counters.fixesHeld == 0 && whileOff.fixesWithheldByGPSSwitch == 1)
    }

    @Test("A held stale network fix is kept at switch-off and applied by the OBD 0, as without the switch")
    func heldNetworkFixKept() throws {
        func networkFix(_ t: Double, arrival: Double) -> NavigationInput {
            .location(LocationSample(latitude: 0, longitude: 0, altitude: 0, horizontalAccuracy: 300,
                                     verticalAccuracy: -1, speed: -1, speedAccuracy: -1, course: -1,
                                     courseAccuracy: -1, receivedT: S.ms(arrival), ageS: arrival - t), at: S.ms(t))
        }
        let base: [NavigationInput] = [H.motion(0.01), networkFix(-60, arrival: 0.06), H.motion(0.07),
                                       H.obd(0, 0.015), H.motion(0.09)]
        var switched = base
        switched.insert(Self.switchInput(false, 0.062), at: 2)
        let a = H.engine(switched)
        let b = H.engine(base)
        #expect(a.isInitialized && a.counters.heldFixesUsed == 1 && a.fixesWithheldByGPSSwitch == 0)
        #expect(!a.gpsOn)
        let ea = try #require(a.estimate(at: S.ms(0.09)))
        let eb = try #require(b.estimate(at: S.ms(0.09)))
        #expect(ea == eb && a.counters == b.counters)
    }

    // MARK: Pins and roads while off

    @Test("Pins and roads are used while off: a grid drive with GPS off after 10 s equals the drive without those fixes")
    func pinsAndRoadsWhileOff() throws {
        let net = try NavigationRoadTests.network(NavigationRoadTests.grid(blocks: 10))
        let base = try NavigationRoadTests.gridDrive()
        let clean = S.cleanFix()
        let drive = base.drive
        let pins = [NavigationRoadTests.pin(at: 0.05, east: 0, north: -300, kmh: 36),
                    NavigationRoadTests.pin(at: 40.03, east: drive.truth(at: 40.03).east,
                                            north: drive.truth(at: 40.03).north - 300, kmh: 36)]
        // Clean fixes all the way; GPS off from 10 s to the end.
        func inputs(_ extra: [LogEvent]) -> [NavigationInput] {
            NavigationRoadTests.shifted(drive, by: (0, -300), fix: { t, s, r in t > 4 ? clean(t, s, &r) : nil },
                                        extra: pins + extra, gyroNoise: 0.002)
        }
        let switched = inputs([Self.gpsSwitch(false, at: 10)])
        let deleted = inputs([]).filter { input in
            guard case .location(let s, _) = input else { return true }
            return !(s.hasValidSpeed && input.arrival > S.ms(10))
        }
        let config = NavigationRoadTests.config(particles: 300)
        let a = Self.run(switched, config: config, roads: net, end: 71)
        let b = Self.run(deleted, config: config, roads: net, end: 71)
        let before = Self.run(switched.filter { $0.arrival <= S.ms(10) }, config: config, roads: net, end: 10)
        #expect(a.engine.fixesWithheldByGPSSwitch == 62)
        #expect(Self.state(a.engine) == Self.state(b.engine) && a.estimates == b.estimates)
        #expect(a.engine.counters == b.engine.counters)
        #expect(a.engine.counters.manualFixes == 2, "the pin at 40 s, while off, is used")
        #expect(a.engine.counters.roadUpdates - before.engine.counters.roadUpdates > 50, "roads keep updating while off")
        #expect(a.engine.counters.fixesUsed == before.engine.counters.fixesUsed)
    }

    // MARK: HUD state

    @Test("Snapshot: gnssInUse within 5 s of a used GNSS fix while on; gpsSwitchedOff while off; never from network fixes")
    func snapshotGPSState() {
        #expect(!NavigationSnapshot.idle(at: .zero).gnssInUse && !NavigationSnapshot.idle(at: .zero).gpsSwitchedOff)
        let events = Self.events([Self.gpsSwitch(false, at: 10.2), Self.gpsSwitch(true, at: 15.2)])
        let inputs = S.inputs(events)
        var run = LiveNavigationRun(sessionID: UUID(), config: S.config(particles: 100), appBuild: "test")
        func snap(_ t: Double) -> NavigationSnapshot { run.snapshot(at: S.ms(t), droppedInputs: 0) }
        #expect(!snap(0).gnssInUse && !snap(0).gpsSwitchedOff)
        var next = 0
        /// Every input arriving at or before `end`.
        func advance(to end: Double) {
            while next < inputs.count, inputs[next].arrival <= S.ms(end) {
                run.ingest(inputs[next]) { _ in }
                next += 1
            }
        }
        advance(to: 10.1)  // the fix at 10 s arrived at 10.05
        #expect(snap(10.1).gnssInUse && !snap(10.1).gpsSwitchedOff)
        #expect(snap(15.05).gnssInUse && !snap(15.06).gnssInUse, "5 s after the last used fix's arrival")
        advance(to: 10.3)
        #expect(!snap(10.3).gnssInUse && snap(10.3).gpsSwitchedOff)
        advance(to: 15.1)  // fixes at 11, 13, 14, 15 withheld (12 is network)
        #expect(!snap(15.1).gnssInUse && snap(15.1).gpsSwitchedOff)
        #expect(run.engine.fixesWithheldByGPSSwitch == 4)
        advance(to: 15.3)
        #expect(!snap(15.3).gnssInUse && !snap(15.3).gpsSwitchedOff, "back on: the last used fix is 5.25 s old")
        advance(to: 16.1)
        #expect(snap(16.1).gnssInUse && !snap(16.1).gpsSwitchedOff)

        // Network fixes alone: initialised, never "in use".
        var network = LiveNavigationRun(sessionID: UUID(), config: S.config(particles: 100), appBuild: "test")
        for input in S.inputs(Self.events()) {
            if case .location(let s, _) = input, s.hasValidSpeed { continue }
            network.ingest(input) { _ in }
        }
        let last = network.snapshot(at: S.ms(80), droppedInputs: 0)
        #expect(last.initialized && !last.gnssInUse && !last.gpsSwitchedOff)
    }

    // MARK: replay_nav

    @Test("replay_nav: the live path's sidecar of a recording with the switch equals --as-live --compare exactly")
    func liveSidecarMatchesAsLiveWithSwitch() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let events = NavigationLiveTests.recorderOrder(Self.switched)
        let tap = NavigationTap(bufferLimit: 1_000_000)
        let writer = try TapFixtures.writer(scratch, "live.jsonl.gz", tap: tap.tap)
        let sidecarURL = NavSidecarFile.url(forRecording: scratch.file("live.jsonl.gz"))
        let header = WriterFixtures.header
        let consumer = Task {
            var run = LiveNavigationRun(header: header, appBuild: "test")
            let out = try NavSidecarWriter(url: sidecarURL)
            out.append(.header(run.header))
            for await input in tap.inputs {
                run.ingest(input, droppedInputs: tap.droppedInputs) { out.append($0) }
            }
            out.close()
            return (run.engine.fixesWithheldByGPSSwitch, run.engine.gpsOn, out.failure)
        }
        let summary = try await TapFixtures.write(events, to: writer)
        tap.finish()
        let (liveWithheld, liveOn, failure) = try await consumer.value
        #expect(failure == nil && tap.droppedInputs == 0)
        #expect(liveWithheld == 24 && liveOn)

        let read = try WriterFixtures.read(summary.url, recovery: .strict)
        #expect(read.events.filter { if case .gpsSwitch = $0.payload { true } else { false } }.count == 2)
        let contents = try NavSidecar.read(contentsOf: sidecarURL)
        let config = NavigationConfig(seed: NavigationSeed.derive(header: read.header))
        let fileOrder = NavigationReplay.fileOrderInputs(from: read.events)
        #expect(fileOrder.filter(\.isGPSSwitch).count == 2)
        let asLive = NavigationReplay.liveLines(inputs: fileOrder, sessionID: read.header.sessionID, config: config)
        let comparison = SidecarComparison(sidecar: contents, replay: asLive, replayConfig: config)
        #expect(comparison.exact, "\(comparison.report(tolerance: .default))")
        #expect(comparison.estimates.matched >= 75 && comparison.pins.matched == 1)

        // Without the switch rows the replay is not what ran live.
        let ignored = NavigationReplay.liveLines(inputs: fileOrder.filter { !$0.isGPSSwitch },
                                                 sessionID: read.header.sessionID, config: config)
        #expect(!SidecarComparison(sidecar: contents, replay: ignored, replayConfig: config).exact)

        // The scored as-live run: the switch reported, its fixes flagged,
        // none a checkpoint; the pin estimate is the sidecar's.
        var options = ReplayOptions(gps: .use, config: config)
        options.asLive = true
        let result = NavigationReplay.run(logName: "live", inputs: fileOrder, options: options)
        #expect(result.gpsSwitch == ReplayResult.GPSSwitchReport(
            offIntervals: [.init(offT: Self.offT, onT: Self.onT)], fixesWithheld: 24, switches: 2))
        #expect(result.fixes.filter { $0.withheldByGPSSwitch == true }.count == 24)
        #expect(result.fixes.allSatisfy { $0.withheld == nil })
        #expect(!result.checkpoints.contains { $0.kind == .cleanFix })
        let replayPin = try #require(result.pins.first?.pin.prior)
        let livePin = try #require(contents.pins.first?.prior)
        #expect(SidecarComparison.Differences.bitEqual(replayPin, livePin))
    }

    @Test("Replay report: intervals (an open one at the end), summary, metrics.md, metrics.json and GeoJSON; nothing without a switch")
    func replayReport() throws {
        let events = Self.events([Self.gpsSwitch(false, at: Self.offT), Self.gpsSwitch(false, at: 25),
                                  Self.gpsSwitch(true, at: Self.onT), Self.gpsSwitch(false, at: 70.5)])
        var options = ReplayOptions(gps: .maskAfter(seconds: 60), config: S.config(particles: 200))
        options.trackIntervalS = 1
        let result = NavigationReplay.run(logName: "synthetic", inputs: NavigationReplay.inputs(from: events), options: options)
        // Off 20.5–50.5 (a repeat at 25 is no change), off again from 70.5 to the end;
        // after 60 s the replay masks every fix, so the second interval withholds nothing more.
        let report = try #require(result.gpsSwitch)
        let intervals: [ReplayResult.GPSSwitchReport.Interval] = [.init(offT: Self.offT, onT: Self.onT), .init(offT: 70.5)]
        #expect(report.offIntervals == intervals)
        #expect(report.switches == 4 && report.fixesWithheld == 24)
        // Masked fixes are the replay's checkpoints; switch-withheld ones are not.
        let clean = result.checkpoints.filter { (cp: ReplayResult.Checkpoint) in cp.kind == .cleanFix }
        #expect(!clean.isEmpty && clean.allSatisfy { (cp: ReplayResult.Checkpoint) in cp.t > 60 })
        let flagged = result.fixes.filter { (fix: ReplayResult.Fix) in fix.withheldByGPSSwitch == true }
        #expect(flagged.count == 24 && flagged.allSatisfy { (fix: ReplayResult.Fix) in fix.withheld == nil && fix.t < Self.onT })
        // Same estimates as the run without those fixes and no switch.
        let plain = NavigationReplay.run(logName: "synthetic", inputs: NavigationReplay.inputs(from: Self.deleted),
                                         options: options)
        #expect(result.track == plain.track && result.checkpoints == plain.checkpoints && result.counters == plain.counters)
        #expect(plain.gpsSwitch == nil)
        // NAV-NOOBD fix accounting: the switch's fixes are delivered (the
        // replay gave them) and withheld by the engine; the books balance.
        #expect(result.fixAccounting.withheldByGPSSwitch == 24 && result.fixAccounting.unaccounted == 0)
        #expect(result.fixAccounting.delivered == plain.fixAccounting.delivered + 24)
        #expect(plain.fixAccounting.withheldByGPSSwitch == nil && plain.fixAccounting.unaccounted == 0)

        let text = "GPS off 2 intervals: t 20.5 … 50.5 s, t 70.5 s … end; 24 fixes withheld by the switch (not checkpoints); 4 switch inputs"
        #expect(report.text == text)
        #expect(ReplayReport.summary(result).contains("GPS switch    " + text))
        #expect(!ReplayReport.summary(plain).contains("GPS switch"))
        #expect(ReplayReport.markdown([ReplayMetrics(result)]).contains("GPS switch (the recording's, UX-9 a): " + text))
        #expect(!ReplayReport.markdown([ReplayMetrics(plain)]).contains("GPS switch"))
        let json = try ReplayReport.metricsJSON([ReplayMetrics(plain)])
        #expect(!String(decoding: json, as: UTF8.self).contains("gpsSwitch"), "absent without a switch")
        let decoded = try JSONDecoder().decode([ReplayMetrics].self, from: ReplayReport.metricsJSON([ReplayMetrics(result)]))
        #expect(decoded[0].gpsSwitch == report)
        let geo = try #require(try JSONSerialization.jsonObject(with: ReplayReport.geoJSON(result)) as? [String: Any])
        let kinds = (geo["features"] as? [[String: Any]] ?? []).compactMap { ($0["properties"] as? [String: Any])?["kind"] as? String }
        #expect(kinds.filter { $0 == "fixWithheldByGPSSwitch" }.count == 24)
        let plainGeo = try #require(String(data: ReplayReport.geoJSON(plain), encoding: .utf8))
        #expect(!plainGeo.contains("GPSSwitch"))
    }

    @Test("An encoding failure of a gpsSwitch row is a navigation input the replay missed")
    func encodingFailureKinds() {
        let row = LogEvent(timestamp: S.ms(3), payload: .lifecycle(LifecycleSample(.error, detail: "encodingFailed gpsSwitch: x")))
        #expect(NavigationReplay.encodingFailures(in: [row]).map(\.kind) == ["gpsSwitch"])
    }
}
