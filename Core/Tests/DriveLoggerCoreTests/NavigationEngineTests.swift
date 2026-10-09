import Foundation
import Testing

@testable import DriveLoggerCore

/// Behaviour of the navigation engine on synthetic drives (local metres
/// around (0, 0); no recording involved).
@Suite("Navigation engine")
struct NavigationEngineTests {
    typealias S = SyntheticDrive

    @Test("A heading initialised 40° wrong converges to the clean-fix course; position stays bounded")
    func wrongInitialHeadingConverges() throws {
        // First fix's course is 40° off (and claims 2°); every later fix is right.
        let drive = S(initialHeadingDeg: 30, initialSpeed: 15, [.straight(seconds: 60, speed: 15)])
        let wrong = S.cleanFix(courseOffsetDeg: 40)
        let good = S.cleanFix()
        let events = drive.events(fix: { t, state, rng in
            S.at(t, 0) ? wrong(t, state, &rng) : good(t, state, &rng)
        })
        let times = stride(from: 5.0, through: 60, by: 5).map { $0 }
        let (engine, samples) = S.run(events, config: S.config(), sampleTimes: times)
        #expect(engine.counters.reseeds >= 1)
        for (t, sample) in zip(times, samples) where t >= 15 {
            let estimate = try #require(sample)
            #expect(abs(angleDifference(estimate.headingDeg, 30)) < 3, "t \(t): heading \(estimate.headingDeg)")
            #expect(drive.error(estimate, at: t) < 15, "t \(t): error \(drive.error(estimate, at: t))")
            #expect(estimate.converged)
        }
    }

    @Test("Square loop, dead reckoning only after initialisation: closes within 1 % of the perimeter, heading within 3°")
    func squareLoopCloses() throws {
        // 4 × 500 m with right turns; the clean start fix gives position and course.
        var segments: [S.Segment] = [.ramp(seconds: 5, from: 0, to: 12.6)]
        for side in 0..<4 {
            segments.append(.straight(seconds: side == 0 ? 500.0 / 12.6 - 2.5 : 500.0 / 12.6, speed: 12.6))
            segments.append(.turn(degrees: 90, seconds: 6, speed: 12.6))
        }
        segments.append(.ramp(seconds: 5, from: 12.6, to: 0))
        segments.append(.stop(seconds: 3))
        let drive = S(initialHeadingDeg: 0, segments)
        let end = drive.truth(at: drive.duration)
        let perimeter = 2000.0
        let start = S.cleanFix(positionNoise: 0)
        let events = drive.events(gyroNoise: 0.002, fix: { t, state, rng in
            S.at(t, 3) ? start(t, state, &rng) : nil
        })
        let (engine, samples) = S.run(events, config: S.config(), sampleTimes: [drive.duration])
        let estimate = try #require(samples.first ?? nil)
        // The loop does not quite return to its start (turns take distance);
        // compare with where the truth ends.
        let closure = drive.error(estimate, at: drive.duration)
        #expect(closure < 0.01 * perimeter, "closure \(closure) m")
        #expect(abs(angleDifference(estimate.headingDeg, end.heading * 180 / .pi)) < 3, "heading \(estimate.headingDeg)")
        #expect(engine.counters.fixesUsed == 1)
    }

    @Test("A stale OBD zero is unknown speed, not a stop: no freeze, the ellipse grows and covers the truth")
    func staleZeroDoesNotFreeze() throws {
        // Stopped with OBD 0; at t = 10 the adapter stops replying and the
        // car drives off.
        let drive = S(initialHeadingDeg: 90, [
            .stop(seconds: 10), .ramp(seconds: 5, from: 0, to: 5), .straight(seconds: 3, speed: 5),
        ])
        let events = drive.events(
            obdSpeed: { t, _ in t < 10 ? 0 : nil },
            fix: { t, state, _ in S.at(t, 0) ? S.Fix(east: state.east, north: state.north, accuracy: 3,
                                                     speed: 0, speedAccuracy: 0.3) : nil }
        )
        let times = [9.0, 13.0, 15.0, 18.0]
        var config = S.config()
        config.particleCount = 1000
        let (engine, samples) = S.run(events, config: config, sampleTimes: times)
        let atStop = try #require(samples[0])
        let later = try #require(samples[1])
        let mid = try #require(samples[2])
        let last = try #require(samples[3])
        #expect(atStop.stationary)
        #expect(!later.stationary, "a stale zero must not freeze the cloud")
        #expect(engine.counters.staleSpeedSteps > 0)
        #expect(later.ellipse.semiMajorM > atStop.ellipse.semiMajorM)
        #expect(mid.ellipse.semiMajorM < last.ellipse.semiMajorM)
        let offset = drive.offset(last, at: 18)
        #expect(last.ellipse.contains(dEast: offset.dEast, dNorth: offset.dNorth),
                "truth \(offset) outside \(last.ellipse)")
    }

    @Test("Stop-and-go: during a fresh OBD 0 position and heading are bit-identical despite gyro noise")
    func zuptFreezes() throws {
        let drive = S(initialHeadingDeg: 45, initialSpeed: 10, [
            .straight(seconds: 20, speed: 10), .ramp(seconds: 4, from: 10, to: 0), .stop(seconds: 15),
            .ramp(seconds: 4, from: 0, to: 10), .straight(seconds: 10, speed: 10),
        ])
        let clean = S.cleanFix()
        let events = drive.events(gyroNoise: 0.05, fix: { t, state, rng in
            S.at(t, 0) ? clean(t, state, &rng) : nil
        })
        // OBD reads 0 from about 24 s to 39 s; sample inside that window.
        let times = stride(from: 26.0, through: 38, by: 0.5).map { $0 }
        let (engine, samples) = S.run(events, config: S.config(), sampleTimes: times + [50])
        let frozen = try samples.prefix(times.count).map { try #require($0) }
        let first = try #require(frozen.first)
        #expect(first.stationary)
        for estimate in frozen {
            #expect(estimate.east == first.east && estimate.north == first.north)
            #expect(estimate.headingDeg == first.headingDeg && estimate.headingStdDeg == first.headingStdDeg)
            #expect(estimate.ellipse == first.ellipse)
        }
        #expect(engine.counters.zuptSteps >= 140)
        let after = try #require(samples.last ?? nil)
        #expect(!after.stationary)
        #expect(after.east != first.east)
    }

    @Test("Tower-like fixes with a correlated 600 m offset: the estimate does not chase it; the ellipse covers the truth")
    func towerBiasNotChased() throws {
        let drive = S(initialHeadingDeg: 10, initialSpeed: 14, [
            .straight(seconds: 60, speed: 14), .turn(degrees: 90, seconds: 8, speed: 10),
            .straight(seconds: 60, speed: 14), .turn(degrees: -90, seconds: 8, speed: 10),
            .straight(seconds: 60, speed: 14),
        ])
        let clean = S.cleanFix()
        let events = drive.events(fixEvery: 4, fix: { t, state, rng in
            if S.at(t, 0) { return clean(t, state, &rng) }
            // Tower fixes: one correlated offset, small jitter, iOS-style fields.
            return S.Fix(east: state.east + 600 + 50 * rng.nextGaussian(),
                         north: state.north + 50 * rng.nextGaussian(), accuracy: 1414)
        })
        let times = [100.0, 150.0, drive.duration]
        let (engine, samples) = S.run(events, config: S.config(), sampleTimes: times)
        #expect(engine.counters.networkFixesUsed > 40)
        for (t, sample) in zip(times, samples) {
            let estimate = try #require(sample)
            let error = drive.error(estimate, at: t)
            #expect(error < 200, "t \(t): error \(error) m — chased the 600 m tower bias")
            let offset = drive.offset(estimate, at: t)
            #expect(estimate.ellipse.contains(dEast: offset.dEast, dNorth: offset.dNorth), "t \(t)")
        }
    }

    @Test("A manual fix after a deliberate 1 km drift resets position to the pin and keeps the heading")
    func manualFixResets() throws {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 11, [.straight(seconds: 90, speed: 11), .stop(seconds: 10)])
        let pinT = 95.0
        let pinTruth = drive.truth(at: pinT)
        let pinPosition = S.plane.geodetic(east: pinTruth.east, north: pinTruth.north)
        let pin = LogEvent(timestamp: S.ms(pinT), payload: .manualFix(ManualFixSample(
            latitude: pinPosition.latitude, longitude: pinPosition.longitude, pressedT: S.ms(pinT - 3),
            obdSpeedKmh: 0, obdSpeedT: S.ms(pinT - 0.1), speedSource: "obd", gateSpeedKmh: 0
        )))
        // OBD reports twice the true speed: about 1 km of drift by the stop.
        let events = drive.events(
            obdSpeed: { _, state in (state.speed * 2 * 3.6).rounded(.down) },
            fix: { t, state, rng in S.at(t, 0) ? S.cleanFix()(t, state, &rng) : nil },
            extra: [pin]
        )
        let (engine, samples) = S.run(events, config: S.config(), sampleTimes: [pinT - 0.5, pinT + 0.5])
        let before = try #require(samples[0])
        let after = try #require(samples[1])
        #expect(drive.error(before, at: pinT) > 900)
        #expect(drive.error(after, at: pinT) < 30, "error after pin \(drive.error(after, at: pinT))")
        #expect(engine.counters.manualResets == 1)
        #expect(abs(angleDifference(after.headingDeg, before.headingDeg)) < 0.5)
        #expect(abs(after.headingStdDeg - before.headingStdDeg) < 0.5)
    }

    @Test("Determinism: same seed gives identical output; a different seed gives different particles")
    func determinism() throws {
        let drive = S(initialHeadingDeg: 200, initialSpeed: 12, [.straight(seconds: 20, speed: 12), .turn(degrees: 60, seconds: 5, speed: 10),
                                                .straight(seconds: 20, speed: 12)])
        let events = drive.events(gyroNoise: 0.01, fix: S.cleanFix(accuracy: 30, positionNoise: 10))
        let times = stride(from: 1.0, through: 45, by: 1).map { $0 }
        let a = S.run(events, config: S.config(seed: 3), sampleTimes: times)
        let b = S.run(events, config: S.config(seed: 3), sampleTimes: times)
        let c = S.run(events, config: S.config(seed: 4), sampleTimes: times)
        #expect(a.samples == b.samples)
        #expect(a.engine.heading == b.engine.heading && a.engine.east == b.engine.east)
        #expect(a.engine.heading != c.engine.heading)
        #expect(a.samples != c.samples)
    }

    @Test("Circular mean and std of heading around 0/360")
    func circularStatistics() throws {
        var engine = NavigationEngine(config: S.config(particles: 4))
        engine.ingest(.location(LocationSample(latitude: 0, longitude: 0, altitude: 0, horizontalAccuracy: 5,
                                               verticalAccuracy: -1, speed: -1, speedAccuracy: -1,
                                               course: -1, courseAccuracy: -1), at: S.ms(0)))
        engine.heading = [359, 1, 358, 2].map { $0 * .pi / 180 }
        let estimate = try #require(engine.estimate(at: S.ms(0)))
        #expect(abs(angleDifference(estimate.headingDeg, 0)) < 1e-9)
        // Circular std of ±1°, ±2° with equal weights ≈ 1.58°.
        #expect(abs(estimate.headingStdDeg - (2.5).squareRoot()) < 0.01)
        engine.heading = [359, 179, 89, 269].map { $0 * .pi / 180 }
        let spread = try #require(engine.estimate(at: S.ms(0)))
        #expect(!spread.converged)
        #expect(spread.headingStdDeg > 100)
    }

    @Test("No estimate before the first position; a manual fix alone initialises")
    func initialisation() throws {
        var engine = NavigationEngine(config: S.config(particles: 50))
        engine.ingest(.obd(OBDSample(pid: .vehicleSpeed, value: 0, unit: .kilometersPerHour, ecu: "7E8"), at: S.ms(0.1)))
        #expect(engine.estimate(at: S.ms(0.2)) == nil)
        engine.ingest(.manualFix(ManualFixSample(latitude: 0.001, longitude: 0.002, pressedT: S.ms(0), speedSource: "unknown"),
                                 at: S.ms(0.3)))
        let estimate = try #require(engine.estimate(at: S.ms(0.3)))
        #expect(abs(estimate.latitude - 0.001) < 1e-9 && abs(estimate.longitude - 0.002) < 1e-9)
        #expect(!estimate.converged)
        #expect(estimate.ellipse.semiMajorM > 60 && estimate.ellipse.semiMajorM < 90)  // √5.991 × 30 m
    }

    @Test("A stale fix is ignored while moving and accepted while stopped; GNSS course is vetoed while OBD says stopped")
    func staleFixAndCourseGate() throws {
        var engine = NavigationEngine(config: S.config(particles: 50))
        func fix(_ t: Double, age: Double, speed: Double = -1, course: Double = -1) -> NavigationInput {
            .location(LocationSample(latitude: 0, longitude: 0, altitude: 0, horizontalAccuracy: 5,
                                     verticalAccuracy: -1, speed: speed, speedAccuracy: speed >= 0 ? 0.3 : -1,
                                     course: course, courseAccuracy: course >= 0 ? 2 : -1,
                                     receivedT: S.ms(t + age), ageS: age), at: S.ms(t))
        }
        engine.ingest(.obd(OBDSample(pid: .vehicleSpeed, value: 40, unit: .kilometersPerHour, ecu: "7E8"), at: S.ms(0)))
        engine.ingest(fix(-60, age: 60.1))
        #expect(!engine.isInitialized)
        #expect(engine.counters.fixesIgnoredStale == 1)
        engine.ingest(.obd(OBDSample(pid: .vehicleSpeed, value: 0, unit: .kilometersPerHour, ecu: "7E8"), at: S.ms(0.2)))
        engine.ingest(fix(-60, age: 60.3, speed: 4, course: 90))  // stopped: accepted, course vetoed
        #expect(engine.isInitialized)
        let estimate = try #require(engine.estimate(at: S.ms(0.3)))
        #expect(estimate.headingStdDeg > 90, "course must not be used while OBD says stopped")
        // OBD from another ECU is not vehicle speed for the engine.
        engine.ingest(.obd(OBDSample(pid: .vehicleSpeed, value: 50, unit: .kilometersPerHour, ecu: "7E9"), at: S.ms(0.4)))
        engine.ingest(.motion(MotionSample(userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -1),
                                           rotationRate: .zero, attitude: .identity), at: S.ms(1.0)))
        #expect(try #require(engine.estimate(at: S.ms(1.0))).stationary)
    }

    @Test("Manual-fix σ: max(30 m, mapSpanM / 12); 30 m without a usable span")
    func manualFixSigmaRule() {
        let config = NavigationConfig()
        #expect(config.manualFixSigma(mapSpanM: nil) == 30)
        #expect(config.manualFixSigma(mapSpanM: 1_248) == 104)
        #expect(config.manualFixSigma(mapSpanM: 360) == 30)
        #expect(config.manualFixSigma(mapSpanM: 372) == 31)
        #expect(config.manualFixSigma(mapSpanM: 120) == 30)
        for bad in [Double.nan, .infinity, -.infinity, 0, -500] {
            #expect(config.manualFixSigma(mapSpanM: bad) == 30, "span \(bad)")
        }
        var custom = NavigationConfig()
        custom.manualFixSigmaMinM = 10
        custom.manualFixSpanDivisor = 20
        #expect(custom.manualFixSigma(mapSpanM: 100) == 10 && custom.manualFixSigma(mapSpanM: 400) == 20)
    }

    @Test("The engine uses the pin's span: a manual fix on a 2400 m map initialises with σ = 200 m")
    func manualFixSigmaInEngine() throws {
        func initialised(span: Double?) throws -> NavigationEstimate {
            var engine = NavigationEngine(config: S.config(particles: 50))
            engine.ingest(.manualFix(ManualFixSample(latitude: 0, longitude: 0, pressedT: S.ms(0), mapSpanM: span,
                                                     speedSource: "unknown"), at: S.ms(1)))
            return try #require(engine.estimate(at: S.ms(1)))
        }
        let k = ErrorEllipse.chiSquare95.squareRoot()
        #expect(abs(try initialised(span: 2_400).ellipse.semiMajorM - k * 200) < 1e-6)
        #expect(abs(try initialised(span: nil).ellipse.semiMajorM - k * 30) < 1e-6)
        #expect(abs(try initialised(span: 100).ellipse.semiMajorM - k * 30) < 1e-6)
    }

    @Test("GNSS speed updates the scale only above speedUpdateMinKmh with a valid speedAccuracy")
    func speedUpdateGate() {
        func speedUpdates(kmh: Double, gate: Double, speedAccuracy: Double = 0.3) -> Int {
            let v = kmh / 3.6
            let drive = S(initialHeadingDeg: 0, initialSpeed: v, [.straight(seconds: 20, speed: v)])
            let clean = S.cleanFix()
            let events = drive.events(fix: { t, state, rng in
                var fix = clean(t, state, &rng)
                fix?.speedAccuracy = speedAccuracy
                return fix
            })
            var config = S.config(particles: 50)
            config.speedUpdateMinKmh = gate
            return S.run(events, config: config).engine.counters.speedUpdates
        }
        #expect(speedUpdates(kmh: 25, gate: 30) == 0)
        #expect(speedUpdates(kmh: 40, gate: 30) >= 15)
        #expect(speedUpdates(kmh: 25, gate: 10.8) >= 15)
        #expect(speedUpdates(kmh: 40, gate: 30, speedAccuracy: -1) == 0)
    }

    @Test("A 50 m fix without a valid speed is a network fix and is tempered; a 50 m fix with speed is not")
    func noSpeedFixIsTempered() throws {
        // Parked (fresh OBD 0). A 50 m fix at the origin initialises; a second
        // 50 m fix 1 s later, 100 m east, either with or without speed.
        func eastAfterSecondFix(speed: Double, speedAccuracy: Double) throws -> (east: Double, network: Int) {
            var engine = NavigationEngine(config: S.config(particles: 50))
            func fix(_ t: Double, east: Double) -> NavigationInput {
                let p = S.plane.geodetic(east: east, north: 0)
                return .location(LocationSample(latitude: p.latitude, longitude: p.longitude, altitude: 0,
                                                horizontalAccuracy: 50, verticalAccuracy: -1,
                                                speed: speed, speedAccuracy: speedAccuracy,
                                                course: -1, courseAccuracy: -1, receivedT: S.ms(t), ageS: 0), at: S.ms(t))
            }
            engine.ingest(.obd(OBDSample(pid: .vehicleSpeed, value: 0, unit: .kilometersPerHour, ecu: "7E8"), at: S.ms(0)))
            engine.ingest(fix(0.05, east: 0))
            engine.ingest(.obd(OBDSample(pid: .vehicleSpeed, value: 0, unit: .kilometersPerHour, ecu: "7E8"), at: S.ms(1)))
            engine.ingest(fix(1.05, east: 100))
            let estimate = try #require(engine.estimate(at: S.ms(1.05)))
            return (S.plane.enu(latitude: estimate.latitude, longitude: estimate.longitude).east, engine.counters.networkFixesUsed)
        }
        // With speed: two equal fixes, the second at full weight → halfway.
        let withSpeed = try eastAfterSecondFix(speed: 0, speedAccuracy: 0.5)
        #expect(abs(withSpeed.east - 50) < 1, "with speed: \(withSpeed.east) m")
        #expect(withSpeed.network == 0)
        // Without speed: tempered by 1 s / 60 s → about 100/61 m.
        let noSpeed = try eastAfterSecondFix(speed: -1, speedAccuracy: -1)
        #expect(abs(noSpeed.east - 100.0 / 61) < 0.5, "without speed: \(noSpeed.east) m")
        #expect(noSpeed.network == 2)
        // A speed without a valid accuracy is not a valid speed either.
        let noAccuracy = try eastAfterSecondFix(speed: 3, speedAccuracy: -1)
        #expect(noAccuracy.network == 2 && noAccuracy.east < 5)
    }

    @Test("Stale-fix σ grows by k × age for fixes older than N s at ingest; a fresh or 0.6 s pre-session fix is not inflated")
    func staleFixSigmaGrowth() throws {
        var config = S.config(particles: 50)
        config.staleFixSigmaGrowthMps = 1.0
        config.staleFixAgeS = 5
        let k = ErrorEllipse.chiSquare95.squareRoot()
        let base = 30 / 1.51  // σ of a 30 m fix at face value
        // Initialises from one fix while parked; returns the initial σ.
        func initialSigma(t: Double, age: Double, config: NavigationConfig) throws -> Double {
            var engine = NavigationEngine(config: config)
            engine.ingest(.obd(OBDSample(pid: .vehicleSpeed, value: 0, unit: .kilometersPerHour, ecu: "7E8"), at: S.ms(t + age - 0.01)))
            engine.ingest(.location(LocationSample(latitude: 0, longitude: 0, altitude: 0, horizontalAccuracy: 30,
                                                   verticalAccuracy: -1, speed: 0, speedAccuracy: 0.5, course: -1,
                                                   courseAccuracy: -1, receivedT: S.ms(t + age), ageS: age), at: S.ms(t)))
            return try #require(engine.estimate(at: S.ms(t + age))).ellipse.semiMajorM / k
        }
        // Pre-session and old: t = −60 s, arriving 0.1 s into the session (age 60.1 s).
        #expect(abs(try initialSigma(t: -60, age: 60.1, config: config) - (base + 60.1)) < 1e-6)
        // Pre-session but only 0.6 s old: not stale.
        #expect(abs(try initialSigma(t: -0.5, age: 0.6, config: config) - base) < 1e-6)
        // Fresh fix: not inflated.
        #expect(abs(try initialSigma(t: 100, age: 0.05, config: config) - base) < 1e-6)
        // In session but older than N = 5 s (a relaunch mid-drive): inflated.
        #expect(abs(try initialSigma(t: 100, age: 7, config: config) - (base + 7)) < 1e-6)
        #expect(abs(try initialSigma(t: 100, age: 4.9, config: config) - base) < 1e-6)
        // The default is 1.0 m/s; k = 0 leaves every fix at face value.
        #expect(NavigationConfig().staleFixSigmaGrowthMps == 1)
        var off = config
        off.staleFixSigmaGrowthMps = 0
        #expect(abs(try initialSigma(t: -60, age: 60.1, config: off) - base) < 1e-6)

        // Updates too: parked at the origin, a stale fix 100 m east pulls far
        // less than a fresh one.
        func eastAfter(age: Double) throws -> Double {
            var engine = NavigationEngine(config: config)
            func fix(_ t: Double, east: Double, age: Double) -> NavigationInput {
                let p = S.plane.geodetic(east: east, north: 0)
                return .location(LocationSample(latitude: p.latitude, longitude: p.longitude, altitude: 0,
                                                horizontalAccuracy: 30, verticalAccuracy: -1, speed: 0, speedAccuracy: 0.5,
                                                course: -1, courseAccuracy: -1, receivedT: S.ms(t + age), ageS: age), at: S.ms(t))
            }
            engine.ingest(.obd(OBDSample(pid: .vehicleSpeed, value: 0, unit: .kilometersPerHour, ecu: "7E8"), at: S.ms(1)))
            engine.ingest(fix(1.05, east: 0, age: 0))
            for t in stride(from: 2.0, through: 8.9, by: 1) {  // fresh OBD 0: parked, no drift
                engine.ingest(.obd(OBDSample(pid: .vehicleSpeed, value: 0, unit: .kilometersPerHour, ecu: "7E8"), at: S.ms(t)))
            }
            engine.ingest(fix(9 - age, east: 100, age: age))
            let estimate = try #require(engine.estimate(at: S.ms(9)))
            return S.plane.enu(latitude: estimate.latitude, longitude: estimate.longitude).east
        }
        #expect(abs(try eastAfter(age: 0.05) - 50) < 1)  // equal σ: halfway
        let stale = try eastAfter(age: 8)                 // σ = base + 8
        let expected = 100 * base * base / (base * base + (base + 8) * (base + 8))
        #expect(abs(stale - expected) < 1, "stale update pulled \(stale) m, expected \(expected) m")
    }
}
