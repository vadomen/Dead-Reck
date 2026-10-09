import Foundation
import Testing

@testable import DriveLoggerCore

@Suite("Navigation replay")
struct NavigationReplayTests {
    typealias S = SyntheticDrive

    // MARK: Truth file

    @Test("Truth file: `end` and `points` in one entry, unknown keys ignored, lookup by file name or stem")
    func truthFileParses() throws {
        let json = """
            {
              "Drive_A.jsonl.gz": {
                "end": {"latitude": 0.01, "longitude": -0.02, "sigmaM": 30, "source": "pin", "extra": 1},
                "points": [
                  {"t": 120.5, "latitude": 0.001, "longitude": 0.002, "sigmaM": 32, "source": "gnss"},
                  {"t": 300.25, "latitude": 0.003, "longitude": 0.004}
                ],
                "note": "free text",
                "futureField": {"anything": [1, 2]}
              },
              "Drive_B": {"points": [{"t": 1, "latitude": 0, "longitude": 0, "sigmaM": 5, "source": "x"}]}
            }
            """
        let truth = try TruthFile(data: Data(json.utf8))
        let a = try #require(truth.entry(forLog: "Drive_A.jsonl.gz"))
        #expect(a.end == TruthFile.Position(latitude: 0.01, longitude: -0.02, sigmaM: 30, source: "pin"))
        #expect(a.points?.count == 2)
        #expect(a.points?[0] == TruthFile.Point(t: 120.5, latitude: 0.001, longitude: 0.002, sigmaM: 32, source: "gnss"))
        #expect(a.points?[1].sigmaM == nil)
        let b = try #require(truth.entry(forLog: "Drive_B.jsonl.gz"))
        #expect(b.end == nil && b.points?.count == 1)
        #expect(truth.entry(forLog: "Drive_C.jsonl.gz") == nil)
        #expect(throws: (any Error).self) { try TruthFile(data: Data(#"{"x": {"points": [{"latitude": 0}]}}"#.utf8)) }
    }

    // MARK: Input preparation

    static func fix(t: Double, received: Double?, accuracy: Double) -> LogEvent {
        .location(LocationSample(latitude: 0, longitude: 0, altitude: 0, horizontalAccuracy: accuracy,
                                 verticalAccuracy: -1, speed: -1, speedAccuracy: -1, course: -1, courseAccuracy: -1,
                                 receivedT: received.map(S.ms)), at: S.ms(t))
    }

    @Test("Inputs are ordered by arrival: location by receivedT, everything else by t; ties keep file order; other kinds dropped")
    func arrivalOrdering() {
        let motion = { (t: Double) in LogEvent.motion(MotionSample(userAcceleration: .zero, gravity: .zero,
                                                                   rotationRate: .zero, attitude: .identity), at: S.ms(t)) }
        let events: [LogEvent] = [
            motion(1.0),
            Self.fix(t: 0.5, received: 1.2, accuracy: 5),  // fix time 0.5, arrives 1.2
            .marker("ignored", at: S.ms(1.1)),
            motion(1.1),
            .obd(OBDSample(pid: .vehicleSpeed, value: 10, unit: .kilometersPerHour), at: S.ms(1.2)),
            Self.fix(t: 1.15, received: nil, accuracy: 5),  // v1: arrives at t
            motion(1.3),
        ]
        let arrivals = NavigationReplay.inputs(from: events).map { $0.arrival.seconds }
        #expect(arrivals == [1.0, 1.1, 1.15, 1.2, 1.2, 1.3])
        let kinds = NavigationReplay.inputs(from: events).map { input -> String in
            switch input {
            case .motion: "motion"
            case .obd: "obd"
            case .location: "location"
            case .manualFix: "manualFix"
            }
        }
        #expect(kinds == ["motion", "motion", "location", "location", "obd", "motion"])
    }

    @Test("GPS modes and --hold-out-acc decide what the engine receives")
    func withholding() {
        let sample = { (acc: Double) in
            LocationSample(latitude: 0, longitude: 0, altitude: 0, horizontalAccuracy: acc, verticalAccuracy: -1,
                           speed: -1, speedAccuracy: -1, course: -1, courseAccuracy: -1)
        }
        let use = ReplayOptions(gps: .use)
        #expect(NavigationReplay.withholdReason(sample(5), at: S.ms(100), options: use) == nil)
        let mask = ReplayOptions(gps: .maskAfter(seconds: 30))
        #expect(NavigationReplay.withholdReason(sample(5), at: S.ms(30), options: mask) == nil)
        #expect(NavigationReplay.withholdReason(sample(5), at: S.ms(30.001), options: mask) == .masked)
        #expect(NavigationReplay.withholdReason(sample(1414), at: S.ms(0), options: ReplayOptions(gps: .none)) == .gpsNone)
        let holdOut = ReplayOptions(gps: .use, holdOutAccuracyM: 100)
        #expect(NavigationReplay.withholdReason(sample(32), at: S.ms(120), options: holdOut) == .heldOut)
        #expect(NavigationReplay.withholdReason(sample(99.9), at: S.ms(-50), options: holdOut) == .heldOut)
        #expect(NavigationReplay.withholdReason(sample(100), at: S.ms(0), options: holdOut) == nil)
        #expect(NavigationReplay.withholdReason(sample(-1), at: S.ms(0), options: holdOut) == nil)
        #expect(GPSMode("mask-after", seconds: 30) == .maskAfter(seconds: 30))
        #expect(GPSMode("use") == .use && GPSMode("none") == GPSMode.none && GPSMode("bogus") == nil)
        #expect(holdOut.label == "use-holdout-100" && mask.label == "mask-after-30")
    }

    @Test("Motion start: first OBD reply of a run ≥ 3 km/h held 3 s without a gap over 2 s; creep, dips, gaps and other ECUs don't count")
    func motionStartDetection() {
        func obd(_ t: Double, _ kmh: Double, ecu: String? = "7E8") -> NavigationInput {
            .obd(OBDSample(pid: .vehicleSpeed, value: kmh, unit: .kilometersPerHour, ecu: ecu), at: S.ms(t))
        }
        var inputs: [NavigationInput] = []
        for k in 0..<20 { inputs.append(obd(Double(k) * 0.5, 2)) }                  // 0–9.5 s: creep at 2 km/h
        for k in 0..<5 { inputs.append(obd(10 + Double(k) * 0.5, 5)) }              // 10–12 s: moving…
        inputs.append(obd(12.5, 0))                                                  // …a dip to 0 resets the run
        for k in 0..<4 { inputs.append(obd(13 + Double(k) * 0.5, 6)) }              // 13–14.5 s
        inputs.append(obd(17, 6))                                                    // 2.5 s gap resets the run
        for k in 0..<10 { inputs.append(obd(20 + Double(k) * 0.5, 40, ecu: "7E9")) } // another ECU: ignored
        inputs.append(.obd(OBDSample(pid: .engineSpeed, value: 900, unit: .revolutionsPerMinute, ecu: "7E8"), at: S.ms(18)))
        #expect(NavigationReplay.motionStart(inputs) == nil, "no qualifying run yet")
        for k in 0..<7 { inputs.append(obd(30 + Double(k) * 0.5, 3)) }              // 30–33 s at exactly 3 km/h
        #expect(NavigationReplay.motionStart(inputs) == S.ms(30))
        // v1 replies without an ECU count too.
        let v1 = (0..<8).map { obd(5 + Double($0) * 0.5, 10, ecu: nil) }
        #expect(NavigationReplay.motionStart(v1) == S.ms(5))
        // Held for just under 3 s: not yet.
        #expect(NavigationReplay.motionStart(Array(v1.prefix(6))) == nil)

        let options = ReplayOptions(gps: .maskAfterMotion(seconds: 30))
        let fix = LocationSample(latitude: 0, longitude: 0, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1,
                                 speed: -1, speedAccuracy: -1, course: -1, courseAccuracy: -1)
        #expect(NavigationReplay.withholdReason(fix, at: S.ms(60), options: options, motionStart: S.ms(30)) == nil)
        #expect(NavigationReplay.withholdReason(fix, at: S.ms(60.01), options: options, motionStart: S.ms(30)) == .masked)
        #expect(NavigationReplay.withholdReason(fix, at: S.ms(500), options: options, motionStart: nil) == nil)
        #expect(GPSMode("mask-after-motion", seconds: 30) == .maskAfterMotion(seconds: 30))
        #expect(GPSMode("mask-after-motion") == nil)
        #expect(options.label == "mask-after-motion-30")
    }

    @Test("mask-after-motion in a replay: fixes up to motion start + s are used, later ones masked and scored")
    func maskAfterMotionReplay() throws {
        // Parked 20 s, then driving: motion starts at about 20 s.
        let drive = S(initialHeadingDeg: 90, [
            .stop(seconds: 20), .ramp(seconds: 4, from: 0, to: 12), .straight(seconds: 60, speed: 12),
        ])
        let events = drive.events(fix: S.cleanFix(accuracy: 5, positionNoise: 1))
        let options = ReplayOptions(gps: .maskAfterMotion(seconds: 15), config: S.config(particles: 200))
        let result = NavigationReplay.run(logName: "synthetic.jsonl.gz", inputs: NavigationReplay.inputs(from: events), options: options)
        let start = try #require(result.motionStartT)
        #expect(start > 20 && start < 21.5)
        #expect(result.fixes.filter { $0.withheld == nil }.allSatisfy { $0.t <= start + 15 })
        #expect(result.fixes.filter { $0.withheld == .masked }.allSatisfy { $0.t > start + 15 })
        #expect(result.checkpoints.filter { $0.kind == .cleanFix }.count == result.fixes.filter { $0.withheld == .masked }.count)
        #expect(ReplayMetrics(result).motionStartT == start)
    }

    // MARK: Geometry

    @Test("Local tangent plane: round trip, distances and the anchor")
    func tangentPlane() {
        let plane = LocalTangentPlane(latitude: 0.5, longitude: -0.25)
        let origin = plane.enu(latitude: 0.5, longitude: -0.25)
        #expect(origin.east == 0 && origin.north == 0)
        for (e, n) in [(1_000.0, 0.0), (0, -2_500), (-7_000, 12_000), (30_000, 30_000)] {
            let p = plane.geodetic(east: e, north: n)
            let back = plane.enu(latitude: p.latitude, longitude: p.longitude)
            #expect(abs(back.east - e) < 1e-6 && abs(back.north - n) < 1e-6)
        }
        // One arc-minute of latitude near the equator is about 1843 m.
        let minute = plane.enu(latitude: 0.5 + 1.0 / 60, longitude: -0.25)
        #expect(abs(minute.north - 1843) < 2)
    }

    @Test("Error ellipse from a covariance: axes, orientation, containment")
    func ellipse() {
        let northSouth = ErrorEllipse(covarianceEE: 1, en: 0, nn: 100)
        #expect(abs(northSouth.semiMajorM - (5.991 * 100).squareRoot()) < 1e-9)
        #expect(abs(northSouth.orientationDeg) < 1e-9)
        #expect(northSouth.contains(dEast: 0, dNorth: 24) && !northSouth.contains(dEast: 3, dNorth: 0))
        let diagonal = ErrorEllipse(covarianceEE: 50, en: 49, nn: 50)
        #expect(abs(diagonal.orientationDeg - 45) < 1e-9)
    }

    // MARK: Whole replay

    /// A drive with clean fixes throughout, a truth file with a point and an
    /// end, and a manual fix.
    static func scenario() -> (drive: SyntheticDrive, events: [LogEvent], truth: TruthFile.Entry) {
        let drive = S(initialHeadingDeg: 60, initialSpeed: 12, [
            .straight(seconds: 40, speed: 12), .turn(degrees: 90, seconds: 6, speed: 10),
            .straight(seconds: 40, speed: 12), .ramp(seconds: 4, from: 12, to: 0), .stop(seconds: 5),
        ])
        let pinState = drive.truth(at: 50)
        let pin = S.plane.geodetic(east: pinState.east, north: pinState.north)
        let manual = LogEvent(timestamp: S.ms(50), payload: .manualFix(ManualFixSample(
            latitude: pin.latitude, longitude: pin.longitude, pressedT: S.ms(48), speedSource: "obd")))
        let events = drive.events(fix: S.cleanFix(accuracy: 5, positionNoise: 1), extra: [manual])
        let point = drive.truth(at: 70)
        let p = S.plane.geodetic(east: point.east, north: point.north)
        let end = drive.truth(at: drive.duration)
        let e = S.plane.geodetic(east: end.east, north: end.north)
        let truth = TruthFile.Entry(
            end: TruthFile.Position(latitude: e.latitude, longitude: e.longitude, sigmaM: 10),
            points: [TruthFile.Point(t: 70, latitude: p.latitude, longitude: p.longitude, sigmaM: 10)]
        )
        return (drive, events, truth)
    }

    @Test("mask-after: masked clean fixes become checkpoints scored causally; manual fix scored on the prior; truth point and end")
    func replayCheckpoints() throws {
        let (drive, events, truth) = Self.scenario()
        let inputs = NavigationReplay.inputs(from: events)
        var options = ReplayOptions(gps: .maskAfter(seconds: 20), config: S.config(particles: 300))
        options.convergenceHoldS = 10
        let result = NavigationReplay.run(logName: "synthetic.jsonl.gz", inputs: inputs, options: options, truth: truth)

        let clean = result.checkpoints.filter { $0.kind == .cleanFix }
        #expect(clean.count == result.fixes.filter { $0.withheld == .masked }.count)
        #expect(clean.allSatisfy { $0.t > 20 })
        #expect(result.fixes.filter { $0.withheld == nil }.allSatisfy { $0.t <= 20 })
        #expect(result.checkpoints.filter { $0.kind == .manualFix }.count == 1)
        #expect(result.checkpoints.filter { $0.kind == .truthPoint }.map(\.t) == [70])
        let end = try #require(result.checkpoints.last { $0.kind == .truthEnd })
        #expect(end.t == result.endT && result.endIsTruth)
        #expect(result.endErrorM == end.errorM)
        // Every scored error is measured against the checkpoint's own truth.
        for checkpoint in result.checkpoints where checkpoint.kind == .truthPoint {
            let error = try #require(checkpoint.errorM)
            #expect(error < 30, "truth point error \(error)")
            #expect(abs(checkpoint.distanceM - 12 * 69.5) < 40)
        }
        #expect(try #require(result.maxErrorM) >= (result.checkpoints.compactMap(\.errorM).max() ?? 0))
        // Distance is ∫ OBD speed (v + 0.5 km/h): ~ the true path length.
        let truePath = zip(drive.states, drive.states.dropFirst()).reduce(0.0) {
            $0 + (($1.1.east - $1.0.east) * ($1.1.east - $1.0.east) + ($1.1.north - $1.0.north) * ($1.1.north - $1.0.north)).squareRoot()
        }
        #expect(abs(result.distanceM - truePath) / truePath < 0.02)
        #expect(result.convergedDistanceM != nil)
        #expect(result.steps > 900 && result.msPerStep > 0)
        #expect(result.track.count > 90 && !result.ellipses.isEmpty)
    }

    @Test("--hold-out-acc: held-out fixes are listed, never ingested (not even for initialisation), and scored when clean")
    func holdOutReplay() throws {
        let (_, events, _) = Self.scenario()
        let inputs = NavigationReplay.inputs(from: events)
        let options = ReplayOptions(gps: .use, holdOutAccuracyM: 100, config: S.config(particles: 200))
        let result = NavigationReplay.run(logName: "synthetic.jsonl.gz", inputs: inputs, options: options)
        // Every fix is 5 m: all held out; the manual fix at 50 s initialises.
        #expect(result.heldOutFixes.count == result.fixes.count && !result.fixes.isEmpty)
        #expect(result.counters.fixesUsed == 0)
        #expect(result.track.first.map { $0.t >= 50 } == true)
        let early = result.checkpoints.filter { $0.kind == .cleanFix && $0.t < 50 }
        #expect(!early.isEmpty && early.allSatisfy { $0.errorM == nil })
        #expect(result.checkpoints.contains { $0.kind == .cleanFix && $0.t > 50 && $0.errorM != nil })
    }

    @Test("Reports: metrics merge across runs by log and mode; GeoJSON is a valid FeatureCollection; same seed, same bytes")
    func reports() throws {
        let (_, events, truth) = Self.scenario()
        let inputs = NavigationReplay.inputs(from: events)
        let options = ReplayOptions(gps: .maskAfter(seconds: 30), config: S.config(particles: 200))
        let a = NavigationReplay.run(logName: "a.jsonl.gz", inputs: inputs, options: options, truth: truth)
        let again = NavigationReplay.run(logName: "a.jsonl.gz", inputs: inputs, options: options, truth: truth)
        #expect(ReplayMetrics(a).checkpoints == ReplayMetrics(again).checkpoints)
        #expect(try ReplayReport.geoJSON(a) == ReplayReport.geoJSON(again))

        let first = try ReplayReport.metricsJSON([ReplayMetrics(a)])
        var b = ReplayMetrics(a)
        b.mode = "use"
        let merged = try ReplayReport.mergedMetrics(existing: first, adding: [b, ReplayMetrics(a)])
        #expect(merged.map(\.key) == ["a.jsonl.gz mask-after-30", "a.jsonl.gz use"])
        let markdown = ReplayReport.markdown(merged)
        #expect(markdown.contains("| a.jsonl.gz | mask-after-30 |") && markdown.contains("\"seed\" : 1"))

        let geo = try #require(try JSONSerialization.jsonObject(with: ReplayReport.geoJSON(a)) as? [String: Any])
        #expect(geo["type"] as? String == "FeatureCollection")
        let features = try #require(geo["features"] as? [[String: Any]])
        let kinds = Set(features.compactMap { ($0["properties"] as? [String: Any])?["kind"] as? String })
        #expect(kinds.isSuperset(of: ["track", "ellipse95", "fixUsed", "fixWithheld", "truth"]))
        #expect(ReplayReport.summary(a).contains("End error"))
    }

    @Test("Manual-fix checkpoints carry the span-derived σ and the engine's 95 % ellipse at the pin")
    func manualFixCheckpointSigma() throws {
        let drive = S(initialHeadingDeg: 30, initialSpeed: 10, [.straight(seconds: 30, speed: 10), .stop(seconds: 10)])
        let pins = [(34.005, 1_248.0), (37.005, nil as Double?)].map { t, span in
            LogEvent(timestamp: S.ms(t), payload: .manualFix(ManualFixSample(
                latitude: 0, longitude: 0, pressedT: S.ms(t - 2), mapSpanM: span, speedSource: "obd")))
        }
        let events = drive.events(fix: { t, state, rng in S.at(t, 0) ? S.cleanFix()(t, state, &rng) : nil }, extra: pins)
        let result = NavigationReplay.run(logName: "synthetic.jsonl.gz", inputs: NavigationReplay.inputs(from: events),
                                          options: ReplayOptions(gps: .use, config: S.config(particles: 100)))
        let manual = result.checkpoints.filter { $0.kind == .manualFix }
        #expect(manual.map(\.truthSigmaM) == [104, 30])
        let first = try #require(manual.first)
        #expect(first.ellipseSemiMajorM != nil && first.ellipseSemiMinorM != nil && first.ellipseOrientationDeg != nil)
        #expect(ReplayReport.summary(result).contains("truth σ 104 m, 95 % ellipse"))
    }
}
