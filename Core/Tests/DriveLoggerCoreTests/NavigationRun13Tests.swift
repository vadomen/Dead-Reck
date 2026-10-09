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

    // MARK: R13.2-1

    /// One run of the re-anchor scenario, as engine snapshots.
    struct ReanchorRun {
        /// Just before and just after the input whose step re-anchored
        /// (nil when the plane never moved).
        var pre: NavigationEngine?
        var post: NavigationEngine?
        /// Right after the input that brought `counters.steps` to the
        /// requested capture step.
        var atStep: NavigationEngine?
        /// The late fix's prior: the engine stepped to the fix's arrival
        /// (by a copy fed an OBD reply then) but not updated by it.
        var beforeLateFix: NavigationEngine?
        /// Right after the late fix.
        var afterLateFix: NavigationEngine?
        var end: NavigationEngine
    }

    static let reanchorLateFixT = 195.0
    static let reanchorLateFixArrival = 250.5

    /// Anchored at (55°, 10°) by a parked fix; a pin 100 km east resets the
    /// cloud there, where the plane's north is tilted ~1.3° against true
    /// north. The car then drives a constant true bearing of 30° at 20 m/s:
    /// clean GNSS fixes and courses for t ≤ 30 s, then dead reckoning with
    /// no GNSS. Along-track 1.2 and cross-track 0.2 m/√m make each
    /// particle's covariance anisotropic and oblique. With `reanchor` the
    /// plane moves at the first 10 s check after the cloud passes the true
    /// track's distance from the anchor at t = 230 s; without, never. A
    /// network fix with t = 195 s, at the truth then, arrives at 250.5 s:
    /// its t is before the re-anchor, its arrival after.
    static func reanchorScenario(reanchor: Bool, captureStep: Int? = nil) -> ReanchorRun {
        let lat0 = 55.0, lon0 = 10.0
        let radians = Double.pi / 180
        let lon1 = lon0 + 100_000 / (LocalTangentPlane.primeVerticalRadius(latitudeRadians: lat0 * radians)
                                     * cos(lat0 * radians)) / radians
        let v = 20.0, bearing = 30.0 * radians
        var inputs: [NavigationInput] = []
        func obd(_ t: Double, _ kmh: Double) {
            inputs.append(.obd(OBDSample(pid: .vehicleSpeed, value: kmh, unit: .kilometersPerHour, ecu: "7E8"), at: S.ms(t)))
        }
        func motion(_ t: Double) {
            inputs.append(.motion(MotionSample(userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -1),
                                               rotationRate: .zero, attitude: .identity), at: S.ms(t)))
        }
        func fix(_ t: Double, lat: Double, lon: Double, accuracy: Double, speed: Double, course: Double,
                 arrival: Double? = nil) {
            let received = arrival ?? t
            inputs.append(.location(LocationSample(latitude: lat, longitude: lon, altitude: 0, horizontalAccuracy: accuracy,
                                                   verticalAccuracy: -1, speed: speed, speedAccuracy: speed >= 0 ? 0.3 : -1,
                                                   course: course, courseAccuracy: course >= 0 ? 2 : -1,
                                                   receivedT: S.ms(received), ageS: received - t), at: S.ms(t)))
        }
        // Parked: anchor fix, then the pin 100 km east.
        for k in 0..<20 { obd(Double(k) * 0.1, 0); motion(Double(k) * 0.1 + 0.05) }
        fix(0.06, lat: lat0, lon: lon0, accuracy: 5, speed: 0, course: -1)
        inputs.append(.manualFix(ManualFixSample(latitude: lat0, longitude: lon1, pressedT: S.ms(0.5),
                                                 speedSource: "obd"), at: S.ms(1.005)))
        // Then a constant true bearing, integrated on the ellipsoid at 100 Hz.
        let anchor = LocalTangentPlane(latitude: lat0, longitude: lon0)
        var lat = lat0, lon = lon1
        var thresholdM = 0.0
        let dt = 0.01
        for k in 1...25_300 {
            let phi = lat * radians
            lat += v * cos(bearing) * dt / LocalTangentPlane.meridianRadius(latitudeRadians: phi) / radians
            lon += v * sin(bearing) * dt / (LocalTangentPlane.primeVerticalRadius(latitudeRadians: phi) * cos(phi)) / radians
            let t = 2 + Double(k) * dt
            motion(t)
            if k % 10 == 0 { obd(t, 72) }
            if k % 100 == 0 && t <= 30 { fix(t, lat: lat, lon: lon, accuracy: 5, speed: v, course: 30) }
            if k == 19_300 {  // t = 195 s
                fix(t, lat: lat, lon: lon, accuracy: 0.5, speed: -1, course: -1, arrival: reanchorLateFixArrival)
            }
            if k == 22_800 {  // t = 230 s
                let p = anchor.enu(latitude: lat, longitude: lon)
                thresholdM = (p.east * p.east + p.north * p.north).squareRoot()
            }
        }
        var config = S.config(particles: 400)
        config.alongTrackNoisePerSqrtM = 1.2
        config.crossTrackNoisePerSqrtM = 0.2
        config.reanchorDistanceM = reanchor ? thresholdM : .infinity
        // The late fix: inside the history, not grown for its age, tight.
        config.maxFixAgeS = 60
        config.staleFixSigmaGrowthMps = 0
        config.fixSigmaFloorM = 0.5

        var engine = NavigationEngine(config: config)
        var run = ReanchorRun(end: engine)
        var candidate: NavigationEngine?
        let ordered = inputs.enumerated()
            .sorted { ($0.element.arrival, $0.offset) < ($1.element.arrival, $1.offset) }.map(\.element)
        for input in ordered {
            // The plane can move only on a step whose count is a multiple
            // of 100: keep a copy while the next step may be one.
            if engine.counters.steps % 100 == 99 { candidate = engine }
            let isLateFix: Bool
            if case .location(_, let t) = input, t == S.ms(reanchorLateFixT) { isLateFix = true } else { isLateFix = false }
            if isLateFix {
                var probe = engine
                probe.ingest(.obd(OBDSample(pid: .vehicleSpeed, value: 72, unit: .kilometersPerHour, ecu: "7E8"),
                                  at: S.ms(reanchorLateFixArrival)))
                run.beforeLateFix = probe
            }
            let reanchors = engine.counters.reanchors
            engine.ingest(input)
            if engine.counters.reanchors > reanchors && run.post == nil {
                run.pre = candidate
                run.post = engine
            }
            if let captureStep, run.atStep == nil, engine.counters.steps >= captureStep { run.atStep = engine }
            if isLateFix { run.afterLateFix = engine }
        }
        run.end = engine
        return run
    }

    typealias Belief = (estimate: NavigationEstimate, plane: LocalTangentPlane)

    /// The current belief (no extrapolation) of an engine snapshot, with the
    /// plane it is expressed in.
    static func belief(_ engine: NavigationEngine?) throws -> Belief {
        let engine = try #require(engine)
        return (try #require(engine.estimate(at: .zero)), try #require(engine.tangentPlane))
    }

    /// Jacobian of plane metres → true local east/north metres at a point,
    /// by central differences of the plane's own WGS-84 inverse.
    static func trueFrame(_ b: Belief) -> (ee: Double, en: Double, ne: Double, nn: Double) {
        let e = b.estimate.east, n = b.estimate.north
        let phi = b.plane.geodetic(east: e, north: n).latitude * .pi / 180
        let m = LocalTangentPlane.meridianRadius(latitudeRadians: phi)
        let r = LocalTangentPlane.primeVerticalRadius(latitudeRadians: phi) * cos(phi)
        func d(_ de: Double, _ dn: Double) -> (east: Double, north: Double) {
            let p = b.plane.geodetic(east: e + de, north: n + dn), q = b.plane.geodetic(east: e - de, north: n - dn)
            return ((p.longitude - q.longitude) * .pi / 180 * r / 2, (p.latitude - q.latitude) * .pi / 180 * m / 2)
        }
        let byEast = d(1, 0), byNorth = d(0, 1)
        return (byEast.east, byNorth.east, byEast.north, byNorth.north)
    }

    /// True bearing of the mean heading, degrees.
    static func trueBearing(_ b: Belief) -> Double {
        let g = trueFrame(b)
        let h = b.estimate.headingDeg * .pi / 180
        let deg = atan2(g.ee * sin(h) + g.en * cos(h), g.ne * sin(h) + g.nn * cos(h)) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    /// The 95 % ellipse in true local east/north metres (G C Gᵀ).
    static func trueEllipse(_ b: Belief) -> ErrorEllipse {
        let el = b.estimate.ellipse
        let o = el.orientationDeg * .pi / 180
        let l1 = el.semiMajorM * el.semiMajorM / ErrorEllipse.chiSquare95
        let l2 = el.semiMinorM * el.semiMinorM / ErrorEllipse.chiSquare95
        // C = λ₁ u uᵀ + λ₂ w wᵀ, u = (sin o, cos o) the major axis, w ⟂ u.
        let ue = sin(o), un = cos(o)
        let cee = l1 * ue * ue + l2 * un * un, cnn = l1 * un * un + l2 * ue * ue, cen = (l1 - l2) * ue * un
        let g = trueFrame(b)
        let aee = g.ee * cee + g.en * cen, aen = g.ee * cen + g.en * cnn
        let ane = g.ne * cee + g.nn * cen, ann = g.ne * cen + g.nn * cnn
        return ErrorEllipse(covarianceEE: aee * g.ee + aen * g.en, en: aee * g.ne + aen * g.nn, nn: ane * g.ne + ann * g.nn)
    }

    /// True east/north metres from `b`'s mean to `a`'s.
    static func trueOffset(_ a: Belief, from b: Belief) -> (east: Double, north: Double) {
        let phi = b.estimate.latitude * .pi / 180
        return ((a.estimate.longitude - b.estimate.longitude) * .pi / 180
                    * LocalTangentPlane.primeVerticalRadius(latitudeRadians: phi) * cos(phi),
                (a.estimate.latitude - b.estimate.latitude) * .pi / 180 * LocalTangentPlane.meridianRadius(latitudeRadians: phi))
    }

    @Test("R13.2-1a: re-anchor 100 km east at 55°, no GNSS since: the true bearing is continuous and matches a run that never re-anchors")
    func reanchorPreservesTrueBearing() throws {
        let run = Self.reanchorScenario(reanchor: true)
        let pre = try Self.belief(run.pre), post = try Self.belief(run.post)
        let control = try Self.belief(Self.reanchorScenario(reanchor: false, captureStep: try #require(run.post).counters.steps).atStep)
        // The plane really moved and its north turned against the old one
        // (shear Δλ·sin φ): plane headings jump by about cos²30° × 1.3°.
        let planeJump = angleDifference(post.estimate.headingDeg, pre.estimate.headingDeg)
        #expect(abs(planeJump) > 0.5, "plane heading jump \(planeJump)°")
        let before = Self.trueBearing(pre), after = Self.trueBearing(post), reference = Self.trueBearing(control)
        #expect(abs(angleDifference(after, before)) < 0.01, "true bearing \(before)° → \(after)° across the re-anchor")
        #expect(abs(angleDifference(after, reference)) < 0.01, "true bearing \(after)°, without re-anchor \(reference)°")
        #expect(run.end.counters.reanchors == 1)
    }

    @Test("R13.2-1b: re-anchor with an oblique, anisotropic covariance: the ellipse in true east/north is continuous and matches a run that never re-anchors")
    func reanchorPreservesEllipse() throws {
        let run = Self.reanchorScenario(reanchor: true)
        let pre = try Self.belief(run.pre), post = try Self.belief(run.post)
        let control = try Self.belief(Self.reanchorScenario(reanchor: false, captureStep: try #require(run.post).counters.steps).atStep)
        let before = Self.trueEllipse(pre), after = Self.trueEllipse(post), reference = Self.trueEllipse(control)
        // Oblique (major axis along the 30° track) and anisotropic, so a
        // shear of the plane changes it.
        #expect(after.semiMajorM > 1.5 * after.semiMinorM && after.orientationDeg > 20 && after.orientationDeg < 40, "\(after)")
        func check(_ x: ErrorEllipse, _ y: ErrorEllipse, _ what: String, axes: Double, degrees: Double) {
            let major = abs(x.semiMajorM / y.semiMajorM - 1), minor = abs(x.semiMinorM / y.semiMinorM - 1)
            let turn = abs(angleDifference(2 * x.orientationDeg, 2 * y.orientationDeg)) / 2
            #expect(major < axes && minor < axes && turn < degrees,
                    "\(what): \(y.semiMajorM) × \(y.semiMinorM) m at \(y.orientationDeg)° → \(x.semiMajorM) × \(x.semiMinorM) m at \(x.orientationDeg)°")
        }
        // Across the step: one 2 m step of growth, ~3e-4 of the axes.
        check(after, before, "across the re-anchor", axes: 2e-3, degrees: 0.01)
        // Same step, same draws, other plane: equal but for rounding.
        check(after, reference, "against no re-anchor", axes: 1e-5, degrees: 0.001)
    }

    @Test("R13.2-1c: a fix 55 s late whose t is before the re-anchor moves the estimate by the same true vector as without re-anchor")
    func reanchorPreservesLateFixShift() throws {
        let run = Self.reanchorScenario(reanchor: true), control = Self.reanchorScenario(reanchor: false)
        let reanchorS = Double(try #require(run.post).counters.steps) / NavigationConfig().stepHz
        #expect(reanchorS > Self.reanchorLateFixT + 20 && reanchorS < Self.reanchorLateFixArrival, "re-anchored at \(reanchorS) s")
        // The two runs' priors differ by a few metres here (the far, old
        // plane stretches distances by ~1 %: what the re-anchor fixes), so
        // compare what the fix does: target = fix + own displacement since
        // its t, prior P ≫ R, so the correction is target − prior mean.
        let shift = Self.trueOffset(try Self.belief(run.afterLateFix), from: try Self.belief(run.beforeLateFix))
        let reference = Self.trueOffset(try Self.belief(control.afterLateFix), from: try Self.belief(control.beforeLateFix))
        let gap = ((shift.east - reference.east) * (shift.east - reference.east)
                   + (shift.north - reference.north) * (shift.north - reference.north)).squareRoot()
        #expect((reference.east * reference.east + reference.north * reference.north).squareRoot() > 10,
                "the fix should correct the tilt-biased track: \(reference)")
        #expect(gap < 0.2, "fix moved the estimate \(shift), without re-anchor \(reference): \(gap) m apart")
        #expect(run.end.counters.reanchors == 1 && control.end.counters.reanchors == 0)
        #expect(run.end.counters.networkFixesUsed == 1 && run.end.counters.fixesIgnoredStale == 0)
    }
}
