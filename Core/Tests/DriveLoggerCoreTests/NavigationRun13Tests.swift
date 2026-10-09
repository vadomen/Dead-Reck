import Foundation
import Testing

@testable import DriveLoggerCore

/// Review run 13, round 1: regression and discriminating tests (R13.1-1..4).
@Suite("Navigation review run 13")
struct NavigationRun13Tests {
    typealias S = SyntheticDrive

    static func pin(at t: Double, east: Double, north: Double, span: Double? = nil) -> LogEvent {
        let p = S.plane.geodetic(east: east, north: north)
        return LogEvent(timestamp: S.ms(t), payload: .manualFix(ManualFixSample(
            latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(t - 2), mapSpanM: span, speedSource: "obd")))
    }

    // MARK: R13.1-1

    @Test("R13.1-1: heading unknown, 3 km straight, a pin at the truth fixes the heading (no reset discarding it)")
    func pinAfterRingKeepsHeadingInformation() throws {
        // Initialised by a pin (heading uniform), 200 s at 15 m/s on a 70°
        // bearing, then parked; a second pin at the true position.
        let drive = S(initialHeadingDeg: 70, initialSpeed: 15, [.straight(seconds: 200, speed: 15), .stop(seconds: 10)])
        let end = drive.truth(at: 205)
        let events = drive.events(extra: [Self.pin(at: 0.005, east: 0, north: 0), Self.pin(at: 205.005, east: end.east, north: end.north)])
        let (engine, samples) = S.run(events, config: S.config(particles: 2000, seed: 3), sampleTimes: [204, 206])
        let before = try #require(samples[0]), after = try #require(samples[1])
        #expect(before.headingStdDeg > 60, "the cloud should be a ring before the pin (σ \(before.headingStdDeg)°)")
        #expect(after.headingStdDeg < 5, "heading σ after the pin \(after.headingStdDeg)°")
        #expect(abs(angleDifference(after.headingDeg, 70)) < 5, "heading \(after.headingDeg)°")
        #expect(drive.error(after, at: 206) < 30)
        #expect(engine.counters.manualResets == 0)
    }

    // MARK: R13.1-2

    /// Drives 20 s, stops with a fresh OBD 0 at about 24 s, then OBD falls
    /// silent at 30 s while the car stays parked for `silentS` seconds. IMU
    /// noise stands in for an idling engine or a hand near the phone.
    static func parkedSilence(silentS: Double, accelNoise: Double) throws -> (atStop: NavigationEstimate, end: NavigationEstimate) {
        let drive = S(initialHeadingDeg: 30, initialSpeed: 10, [
            .straight(seconds: 20, speed: 10), .ramp(seconds: 4, from: 10, to: 0), .stop(seconds: 6 + silentS),
        ])
        let clean = S.cleanFix()
        let events = drive.events(gyroNoise: 0.02, accelNoise: accelNoise,
                                  obdSpeed: { t, state in t >= 30 ? nil : (state.speed * 3.6).rounded(.down) },
                                  fix: { t, state, rng in t < 20 ? clean(t, state, &rng) : nil })
        let samples = S.run(events, config: S.config(particles: 400), sampleTimes: [29.9, 30 + silentS]).samples
        return (try #require(samples[0]), try #require(samples[1]))
    }

    @Test("R13.1-2: 5 min of OBD silence after a fresh stop, no motion: the ellipse stays put (parked until motion shows)")
    func parkedSilenceStaysBounded() throws {
        let (atStop, end) = try Self.parkedSilence(silentS: 300, accelNoise: 0.03)
        let growth = end.ellipse.semiMajorM - atStop.ellipse.semiMajorM
        #expect(growth < 100, "semi-major grew \(growth) m in 5 min parked (\(atStop.ellipse.semiMajorM) → \(end.ellipse.semiMajorM) m)")
        #expect(end.stationary)
        #expect(abs(end.east - atStop.east) < 1 && abs(end.north - atStop.north) < 1)
    }

    @Test("R13.1-2: OBD lost while driving: the speed error is mean-reverting, so the ellipse grows diffusively, not as t^1.5")
    func staleWhileMovingGrowsDiffusively() throws {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 12, [.straight(seconds: 640, speed: 12)])
        let clean = S.cleanFix()
        let events = drive.events(obdSpeed: { t, state in t >= 20 ? nil : (state.speed * 3.6).rounded(.down) },
                                  fix: { t, state, rng in t < 15 ? clean(t, state, &rng) : nil })
        let samples = S.run(events, config: S.config(particles: 400), sampleTimes: [20, 320, 620]).samples
        let start = try #require(samples[0]).ellipse.semiMajorM
        let five = try #require(samples[1]).ellipse.semiMajorM - start
        let ten = try #require(samples[2]).ellipse.semiMajorM - start
        // Unbounded random walk: σ ∝ t^1.5, so doubling the time grows it
        // 2.8×; bounded speed error: about √2 = 1.4×.
        #expect(ten / five < 2, "5 min: \(five) m, 10 min: \(ten) m (ratio \(ten / five))")
        #expect(five < 3_000, "5 min of silence while driving: \(five) m")
    }

    // MARK: R13.1-3

    /// Anchored at (55°, 10°) by a parked fix; a manual pin 100 km east resets
    /// the cloud there; the car then drives due north along that meridian (a
    /// geodesic, true bearing 0°) at 20 m/s: 60 s with clean GNSS fixes and
    /// courses, then `dr` seconds of dead reckoning. Returns the true and
    /// estimated positions at the end and the engine.
    static func northAtFarMeridian(drS: Double, config: NavigationConfig)
        -> (truthLat: Double, truthLon: Double, estimate: NavigationEstimate?, engine: NavigationEngine) {
        let lat0 = 55.0, lon0 = 10.0
        let phi = lat0 * .pi / 180
        let a = 6_378_137.0, e2 = 6.694_379_990_14e-3
        let n = a / (1 - e2 * sin(phi) * sin(phi)).squareRoot()
        let lon1 = lon0 + 100_000 / (n * cos(phi)) * 180 / .pi
        var inputs: [NavigationInput] = []
        func obd(_ t: Double, _ kmh: Double) {
            inputs.append(.obd(OBDSample(pid: .vehicleSpeed, value: kmh, unit: .kilometersPerHour, ecu: "7E8"), at: S.ms(t)))
        }
        func motion(_ t: Double) {
            inputs.append(.motion(MotionSample(userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -1),
                                               rotationRate: .zero, attitude: .identity), at: S.ms(t)))
        }
        func fix(_ t: Double, lat: Double, lon: Double, speed: Double) {
            inputs.append(.location(LocationSample(latitude: lat, longitude: lon, altitude: 0, horizontalAccuracy: 5,
                                                   verticalAccuracy: -1, speed: speed, speedAccuracy: 0.3,
                                                   course: speed > 0 ? 0 : -1, courseAccuracy: speed > 0 ? 2 : -1,
                                                   receivedT: S.ms(t), ageS: 0), at: S.ms(t)))
        }
        // Parked: anchor fix, then the pin 100 km east.
        for k in 0..<20 { obd(Double(k) * 0.1, 0); motion(Double(k) * 0.1 + 0.05) }
        fix(0.06, lat: lat0, lon: lon0, speed: 0)
        inputs.append(.manualFix(ManualFixSample(latitude: lat0, longitude: lon1, pressedT: S.ms(0.5),
                                                 speedSource: "obd"), at: S.ms(1.005)))
        // Then due north at 20 m/s (72 km/h).
        let v = 20.0
        var lat = lat0
        let total = 60 + drS
        var t = 2.0
        var lastFix = 1.0
        while t <= 2 + total {
            let phiNow = lat * .pi / 180
            let m = a * (1 - e2) / pow(1 - e2 * sin(phiNow) * sin(phiNow), 1.5)
            lat += v * 0.01 / m * 180 / .pi
            t += 0.01
            motion(t)
            if Int((t * 100).rounded()) % 10 == 0 { obd(t, 72) }
            if t - lastFix >= 1 - 1e-9 {
                lastFix = t
                if t <= 62 { fix(t, lat: lat, lon: lon1, speed: v) }
            }
        }
        var engine = NavigationEngine(config: config)
        for input in inputs.enumerated().sorted(by: { ($0.element.arrival, $0.offset) < ($1.element.arrival, $1.offset) }).map(\.element) {
            engine.ingest(input)
        }
        return (lat, lon1, engine.estimate(at: S.ms(t)), engine)
    }

    @Test("R13.1-3: at latitude 55°, 100 km east of the anchor, GNSS course then 10 km of DR north: no convergence bias")
    func farFromAnchorNoConvergenceBias() throws {
        let run = Self.northAtFarMeridian(drS: 500, config: S.config(particles: 300))
        let estimate = try #require(run.estimate)
        let phi = run.truthLat * .pi / 180
        let a = 6_378_137.0, e2 = 6.694_379_990_14e-3
        let n = a / (1 - e2 * sin(phi) * sin(phi)).squareRoot()
        let crossTrack = (estimate.longitude - run.truthLon) * .pi / 180 * n * cos(phi)
        // Without a fix the heading is biased by Δλ·sin φ ≈ 1.28°: ~220 m
        // cross-track after 10 km. Noise-free DR otherwise.
        #expect(abs(crossTrack) < 40, "cross-track \(crossTrack) m after 10 km of DR")
        #expect(abs(angleDifference(estimate.headingDeg, 0)) < 0.5, "heading \(estimate.headingDeg)°")
        #expect(run.engine.counters.manualResets == 1)
    }

    // MARK: R13.1-4

    @Test("R13.1-4a: a glitch fix reporting 25 m/s at OBD 10 m/s with a wrong course leaves heading unchanged")
    func dopplerGateRejectsGlitch() throws {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 10, [.straight(seconds: 40, speed: 10)])
        let clean = S.cleanFix()
        let events = drive.events(fix: { t, state, rng in
            if t < 30 { return clean(t, state, &rng) }
            if S.at(t, 30) {  // the glitch: clean-looking, 25 m/s, course 90° ± 2°
                return S.Fix(east: state.east, north: state.north, accuracy: 5, speed: 25, speedAccuracy: 0.5,
                             course: 90, courseAccuracy: 2)
            }
            return nil
        })
        let (engine, samples) = S.run(events, config: S.config(particles: 400), sampleTimes: [29.9, 31])
        let before = try #require(samples[0]), after = try #require(samples[1])
        #expect(abs(angleDifference(after.headingDeg, before.headingDeg)) < 1,
                "heading \(before.headingDeg)° → \(after.headingDeg)°")
        #expect(after.headingStdDeg < 3, "heading σ \(after.headingStdDeg)°")
        #expect(engine.counters.reseeds <= 1)
    }

    @Test("R13.1-4b: estimate(at:) 0.5 s past the last step moves v·0.5 s along heading; it does not move when stationary")
    func estimateExtrapolates() throws {
        func engine(after events: [LogEvent], until t: Double) -> NavigationEngine {
            var engine = NavigationEngine(config: S.config(particles: 200))
            for input in S.inputs(events) where input.arrival <= S.ms(t) { engine.ingest(input) }
            return engine
        }
        let drive = S(initialHeadingDeg: 45, initialSpeed: 10, [.straight(seconds: 20, speed: 10)])
        let moving = engine(after: drive.events(fix: { t, state, rng in t < 5 ? S.cleanFix()(t, state, &rng) : nil }), until: 10)
        let a = try #require(moving.estimate(at: S.ms(10))), b = try #require(moving.estimate(at: S.ms(10.5)))
        let de = b.east - a.east, dn = b.north - a.north
        let distance = (de * de + dn * dn).squareRoot()
        #expect(a.speedMps > 9.5)
        #expect(abs(distance - a.speedMps * 0.5) < 0.05, "moved \(distance) m at \(a.speedMps) m/s")
        #expect(abs(angleDifference(atan2(de, dn) * 180 / .pi, a.headingDeg)) < 0.5)

        let parked = S(initialHeadingDeg: 45, [.stop(seconds: 20)])
        // Gyro noise while parked: extrapolating a stationary estimate would
        // turn it by the last yaw rate.
        let still = engine(after: parked.events(gyroNoise: 0.05, fix: { t, state, _ in
            S.at(t, 0) ? S.Fix(east: state.east, north: state.north, accuracy: 5, speed: 0, speedAccuracy: 0.3) : nil
        }), until: 10)
        let c = try #require(still.estimate(at: S.ms(10))), d = try #require(still.estimate(at: S.ms(10.5)))
        #expect(c.stationary && c.east == d.east && c.north == d.north && c.headingDeg == d.headingDeg)
    }

    @Test("R13.1-4c: after a 60 s gap in motion samples, a large rate on the next sample adds no yaw")
    func motionGapAddsNoYaw() throws {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 10, [.straight(seconds: 80, speed: 10)])
        let clean = S.cleanFix()
        let events = drive.events(fix: { t, state, rng in t < 5 ? clean(t, state, &rng) : nil }).compactMap { event -> LogEvent? in
            guard case .motion(var sample) = event.payload else { return event }
            let t = event.timestamp.seconds
            if t > 10 && t < 70 { return nil }  // the gap
            if abs(t - 70) < 0.005 {  // first sample after it: 1 rad/s clockwise
                sample.rotationRate = Vector3(x: 0, y: 0, z: -1)
            }
            return .motion(sample, at: event.timestamp)
        }
        let (_, samples) = S.run(events, config: S.config(particles: 200), sampleTimes: [9.9, 75])
        let before = try #require(samples[0]), after = try #require(samples[1])
        #expect(abs(angleDifference(after.headingDeg, before.headingDeg)) < 1, "heading \(before.headingDeg)° → \(after.headingDeg)°")
    }

    @Test("R13.1-4d: heading σ grows by about 0.1°·√(degrees turned) over a 90° turn, about √(time) on a straight")
    func turnNoiseGrowsHeadingStd() throws {
        var config = S.config(particles: 2000)
        config.courseSigmaFloorDeg = 0.05
        func growth(turn: Double) throws -> Double {
            let drive = S(initialHeadingDeg: 0, initialSpeed: 12, [.straight(seconds: 2, speed: 12),
                                                                   .turn(degrees: turn, seconds: 6, speed: 12),
                                                                   .straight(seconds: 2, speed: 12)])
            let events = drive.events(fix: { t, state, _ in
                // One near-perfect course at t = 0 initialises heading tightly.
                S.at(t, 0) ? S.Fix(east: 0, north: 0, accuracy: 5, speed: 12, speedAccuracy: 0.3,
                                   course: 0, courseAccuracy: 0.05) : nil
            })
            let samples = S.run(events, config: config, sampleTimes: [1, 9]).samples
            let a = try #require(samples[0]).headingStdDeg, b = try #require(samples[1]).headingStdDeg
            return (b * b - a * a).squareRoot()
        }
        let turning = try growth(turn: 90), straight = try growth(turn: 0)
        // Expected: √(0.1² × 90 + 0.05² × 8) ≈ 0.95° turning, √(0.05² × 8) ≈ 0.14° straight.
        #expect(turning > 0.8 && turning < 1.15, "σ growth over the 90° turn \(turning)°")
        #expect(straight < 0.25, "σ growth on the straight \(straight)°")
    }
}
