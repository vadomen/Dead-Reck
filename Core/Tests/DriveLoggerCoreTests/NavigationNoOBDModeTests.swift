import Foundation
import Testing

@testable import DriveLoggerCore

/// NAV-NOOBD-B (prompt 45): no-OBD mode — the robust network-fix
/// likelihood (`noOBDRobustNetworkFix`) and the fix-speed OU mean
/// (`noOBDFixSpeedMean`), both off by default and acting only until the
/// first OBD vehicle-speed reply. Synthetic drives from (0, 0) only; no
/// real place, date or recording.
@Suite("Navigation NAV-NOOBD-B: no-OBD mode, robust network fixes, fix-speed mean")
struct NavigationNoOBDModeTests {
    typealias S = SyntheticDrive

    // MARK: Fixtures

    /// Drive-off, 50 km/h straight, a right turn, 50 km/h again.
    static let drive = S(initialHeadingDeg: 60, [
        .ramp(seconds: 10, from: 0, to: 50 / 3.6), .straight(seconds: 120, speed: 50 / 3.6),
        .turn(degrees: 90, seconds: 10, speed: 10), .straight(seconds: 100, speed: 50 / 3.6),
    ])

    static let kmh50 = 50 / 3.6

    /// A network fix of the truth (no valid speed or course), with seeded
    /// per-axis position noise, from `from` s on.
    static func networkFix(accuracy: Double, noise: Double, from: Double = 0)
        -> (Double, S.State, inout NavigationRandom) -> S.Fix? {
        { t, state, rng in
            guard t >= from else { return nil }
            return S.Fix(east: state.east + noise * rng.nextGaussian(), north: state.north + noise * rng.nextGaussian(),
                         accuracy: accuracy)
        }
    }

    /// A clean GNSS fix (valid speed and course) before `until` s, nothing after.
    static func cleanFixUntil(_ until: Double) -> (Double, S.State, inout NavigationRandom) -> S.Fix? {
        let clean = S.cleanFix(accuracy: 5, positionNoise: 1)
        return { t, state, rng in t < until ? clean(t, state, &rng) : nil }
    }

    static func config(robust: Int = 0, fixSpeed: Int = 0, particles: Int = 300, seed: UInt64 = 5) -> NavigationConfig {
        var config = S.config(particles: particles, seed: seed)
        config.noOBDRobustNetworkFix = robust
        config.noOBDFixSpeedMean = fixSpeed
        return config
    }

    /// Prompt 45's (a): the floor 30 km/h, decay 30 s and no displacement gate.
    static func config45(robust: Int = 0, fixSpeed: Int = 1, particles: Int = 300, seed: UInt64 = 5) -> NavigationConfig {
        var config = Self.config(robust: robust, fixSpeed: fixSpeed, particles: particles, seed: seed)
        config.noOBDFixSpeedFloorKmh = 30
        config.noOBDFixSpeedGate = 0
        config.noOBDFixSpeedDecayS = 30
        return config
    }

    /// The four switch combinations: off, (e) only, (a) only, both.
    static let switches: [(robust: Int, fixSpeed: Int)] = [(0, 0), (1, 0), (0, 1), (1, 1)]

    static let sampleTimes = Array(stride(from: 2.0, through: 240, by: 2))

    /// No OBD reply at all.
    static func noOBD(_ t: Double, _ state: S.State) -> Double? { nil }

    /// A network fix input at (`east`, `north`) m, fix time `t`, arriving
    /// 0.05 s later.
    static func networkInput(east: Double, north: Double, accuracy: Double, at t: Double) -> NavigationInput {
        let p = S.plane.geodetic(east: east, north: north)
        let sample = LocationSample(
            latitude: p.latitude, longitude: p.longitude, altitude: 0, horizontalAccuracy: accuracy,
            verticalAccuracy: -1, speed: -1, speedAccuracy: -1, course: -1, courseAccuracy: -1,
            receivedT: S.ms(t + 0.05), ageS: 0.05)
        return .location(sample, at: S.ms(t))
    }

    /// A motion sample at `t` that turns nothing: steps the engine to `t`.
    static func still(at t: Double) -> NavigationInput {
        .motion(MotionSample(userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -1), rotationRate: .zero,
                             attitude: .identity), at: S.ms(t))
    }

    // MARK: 1. Default: bit-identical

    @Test("Defaults: both switches 0 and the calibrated parameters; with the switches 0 every other no-OBD key is inert (estimates and counters bit-identical, with OBD and without)")
    func defaultsAreOffAndInert() {
        let d = NavigationConfig()
        #expect(d.noOBDRobustNetworkFix == 0 && d.noOBDFixSpeedMean == 0)
        #expect(d.noOBDNetworkFixNu == 2 && d.noOBDNetworkFixScalePerAccuracy == 0.21)
        #expect(d.noOBDNetworkFixScaleFloorM == 5 && d.noOBDNetworkFixTowerAccuracyM == 1_000)
        #expect(d.noOBDNetworkFixTowerScaleM == 120 && d.noOBDNetworkFixCorrelationS == 30)
        #expect(d.noOBDFixSpeedWindowS == 120 && d.noOBDFixSpeedMinSpanS == 10 && d.noOBDFixSpeedMaxKmh == 110)
        #expect(d.noOBDFixSpeedHoldS == 30 && d.noOBDFixSpeedDecayS == 500 && d.noOBDFixSpeedFloorKmh == 0)
        #expect(d.noOBDFixSpeedGate == 2 && d.noOBDFixSpeedGateK == 2.15 && d.noOBDFixSpeedGateSigmaLowM == 8)
        #expect(d.noOBDFixSpeedGateSigmaMidM == 170 && d.noOBDFixSpeedGateSigmaTowerM == 240)
        #expect(NavigationConfig.noOBDFixSpeedGateMidAccuracyM == 100 && NavigationConfig.noOBDFixSpeedGateTowerAccuracyM == 1_000)

        // Explicitly off, every parameter moved off its default.
        var off = Self.config()
        off.noOBDNetworkFixNu = 5
        off.noOBDNetworkFixScalePerAccuracy = 0.5
        off.noOBDNetworkFixScaleFloorM = 20
        off.noOBDNetworkFixTowerAccuracyM = 500
        off.noOBDNetworkFixTowerScaleM = 40
        off.noOBDNetworkFixCorrelationS = 5
        off.noOBDFixSpeedWindowS = 30
        off.noOBDFixSpeedMinSpanS = 2
        off.noOBDFixSpeedMaxKmh = 200
        off.noOBDFixSpeedHoldS = 0
        off.noOBDFixSpeedDecayS = 1
        off.noOBDFixSpeedFloorKmh = 80
        off.noOBDFixSpeedGate = 1
        off.noOBDFixSpeedGateK = 9
        off.noOBDFixSpeedGateSigmaLowM = 300
        off.noOBDFixSpeedGateSigmaMidM = 400
        off.noOBDFixSpeedGateSigmaTowerM = 500
        #expect(off.invalidReason == nil)
        let fixes = Self.networkFix(accuracy: 300, noise: 60)
        for obd in [true, false] {
            var obdSpeed: ((Double, S.State) -> Double?)?
            if !obd { obdSpeed = { _, _ in nil } }
            let events = Self.drive.events(gyroNoise: 0.002, obdSpeed: obdSpeed, fixEvery: 8, fix: fixes)
            let a = S.run(events, config: Self.config(), sampleTimes: Self.sampleTimes)
            let b = S.run(events, config: off, sampleTimes: Self.sampleTimes)
            #expect(a.samples.compactMap { $0 }.count == Self.sampleTimes.count, "obd \(obd)")
            #expect(a.samples == b.samples, "obd \(obd)")
            #expect(a.engine.counters == b.engine.counters, "obd \(obd)")
            #expect(a.engine.counters.networkFixesUsed > 20)
            #expect(a.engine.fixSpeedEstimate == nil && b.engine.fixSpeedEstimate == nil)
            #expect(a.engine.obdEverIngested == obd && !a.engine.noOBDFixSpeedMeanActive)
        }
    }

    // MARK: 2. No-OBD mode ends at the first OBD reply

    @Test("OBD from the start: every switch combination is bit-identical to off throughout (no-OBD mode never begins)")
    func obdFromTheStartIsUnchanged() {
        // Fixes from 1 s on: the first OBD reply (0.05 s) comes first.
        let events = Self.drive.events(gyroNoise: 0.002, fixEvery: 8, fix: Self.networkFix(accuracy: 300, noise: 60, from: 1))
        let reference = S.run(events, config: Self.config(), sampleTimes: Self.sampleTimes)
        #expect(reference.engine.counters.networkFixesUsed > 20 && reference.engine.counters.zuptSteps == 0)
        for (robust, fixSpeed) in Self.switches.dropFirst() {
            let run = S.run(events, config: Self.config(robust: robust, fixSpeed: fixSpeed), sampleTimes: Self.sampleTimes)
            #expect(run.samples == reference.samples, "\(robust) \(fixSpeed)")
            #expect(run.engine.counters == reference.engine.counters, "\(robust) \(fixSpeed)")
            #expect(run.engine.obdEverIngested && !run.engine.noOBDRobustNetworkFixActive
                    && !run.engine.noOBDFixSpeedMeanActive)
            #expect(run.engine.fixSpeedEstimate == nil)
        }
    }

    @Test("First OBD reply at t0 = 60 s: the mode flag flips exactly there (other PIDs and ECUs do not end it); with no network fix before t0 every switch combination equals off throughout; without that reply the switches do change the run")
    func modeEndsAtTheFirstOBDReply() throws {
        let t0 = 60.0
        // Clean GNSS fixes before t0 (not network fixes: the switches
        // cannot act on them), network fixes from t0 + 5 s on.
        let fix: (Double, S.State, inout NavigationRandom) -> S.Fix? = { t, state, rng in
            if t < t0 { return Self.cleanFixUntil(t0)(t, state, &rng) }
            return Self.networkFix(accuracy: 300, noise: 60, from: t0 + 5)(t, state, &rng)
        }
        // Before t0: an RPM reply and another ECU's vehicle speed every
        // second; neither ends no-OBD mode.
        let others: [LogEvent] = stride(from: 0.375, to: t0, by: 1).flatMap { t -> [LogEvent] in
            [.obd(OBDSample(pid: .engineSpeed, value: 900, unit: .revolutionsPerMinute, ecu: "7E8"), at: S.ms(t)),
             .obd(OBDSample(pid: .vehicleSpeed, value: 50, unit: .kilometersPerHour, ecu: "7E9"), at: S.ms(t + 0.01))]
        }
        let obdFromT0: (Double, S.State) -> Double? = { t, state in t >= t0 ? (state.speed * 3.6).rounded(.down) : nil }
        let events = Self.drive.events(gyroNoise: 0.002, obdSpeed: obdFromT0, fix: fix, extra: others)

        // The flag, input by input.
        var engine = NavigationEngine(config: Self.config(robust: 1, fixSpeed: 1))
        var firstReply: MonotonicTimestamp?
        for input in S.inputs(events) {
            engine.ingest(input)
            if firstReply == nil, case .obd(let sample, let t) = input, sample.pid == .vehicleSpeed, sample.ecu == "7E8" {
                firstReply = t
            }
            #expect(engine.obdEverIngested == (firstReply != nil))
            #expect(engine.noOBDRobustNetworkFixActive == (firstReply == nil))
            #expect(engine.noOBDFixSpeedMeanActive == (firstReply == nil))
        }
        let first = try #require(firstReply)
        #expect(abs(first.seconds - t0) < 0.2)

        let reference = S.run(events, config: Self.config(), sampleTimes: Self.sampleTimes)
        #expect(reference.engine.counters.networkFixesUsed > 100)
        for (robust, fixSpeed) in Self.switches.dropFirst() {
            let run = S.run(events, config: Self.config(robust: robust, fixSpeed: fixSpeed), sampleTimes: Self.sampleTimes)
            #expect(run.samples == reference.samples, "\(robust) \(fixSpeed)")
            #expect(run.engine.counters == reference.engine.counters, "\(robust) \(fixSpeed)")
        }

        // The same recording without that reply: the network fixes after
        // t0 are taken in no-OBD mode, so each switch changes the run.
        let withoutOBD = Self.drive.events(gyroNoise: 0.002, obdSpeed: Self.noOBD, fix: fix, extra: others)
        let offRun = S.run(withoutOBD, config: Self.config(), sampleTimes: Self.sampleTimes)
        for (robust, fixSpeed) in Self.switches.dropFirst() {
            let run = S.run(withoutOBD, config: Self.config(robust: robust, fixSpeed: fixSpeed), sampleTimes: Self.sampleTimes)
            #expect(!run.engine.obdEverIngested)
            #expect(run.samples != offRun.samples, "\(robust) \(fixSpeed)")
        }
    }

    // MARK: 3. Robust likelihood

    /// A converged cloud set by hand: 1000 particles around the origin
    /// with a 50 m spread, each with a 20 m per-axis σ, equal weights,
    /// 60 s after the first network fix (so the next one is tempered by 1
    /// in both paths). Then one tower fix (1414 m claimed) at `offsetM`
    /// east, with no step between. Returns the estimate's shift (m) and
    /// its east part.
    static func shift(_ config: NavigationConfig, offsetM: Double) -> (shift: Double, east: Double) {
        var engine = NavigationEngine(config: config)
        engine.ingest(Self.networkInput(east: 0, north: 0, accuracy: 30, at: 0))
        engine.ingest(Self.still(at: 60.05))
        var rng = NavigationRandom(seed: 21)
        let n = engine.east.count
        for i in 0..<n {
            engine.east[i] = 50 * rng.nextGaussian()
            engine.north[i] = 50 * rng.nextGaussian()
            engine.covEE[i] = 400
            engine.covEN[i] = 0
            engine.covNN[i] = 400
            engine.logWeight[i] = -log(Double(n))
        }
        engine.normalizeWeights()
        let at = S.ms(60.05)
        let before = engine.estimate(at: at)!
        engine.ingest(Self.networkInput(east: offsetM, north: 0, accuracy: 1414, at: 60))
        #expect(engine.lastStepTime == S.ms(60))
        let after = engine.estimate(at: at)!
        let a = S.plane.enu(latitude: before.latitude, longitude: before.longitude)
        let b = S.plane.enu(latitude: after.latitude, longitude: after.longitude)
        let shift = ((b.east - a.east) * (b.east - a.east) + (b.north - a.north) * (b.north - a.north)).squareRoot()
        #expect([after.latitude, after.longitude, after.ellipse.semiMajorM, after.effectiveSampleSize]
            .allSatisfy { $0.isFinite })
        Self.expectFinite(engine, "shift \(offsetM)")
        return (shift, b.east - a.east)
    }

    @Test("Robust likelihood: a tower fix 5 km off a converged cloud (50 m spread) moves the estimate < 3 m (measured 2.2); the Gaussian path (claimed σ) moves it more than 5 times as far (15.9), a Gaussian of the same 120 m scale > 200 m (274); a tower fix 300 m off still pulls the robust estimate (29 m)")
    func robustIgnoresAFarOutlier() {
        let particles = 1000
        let robust = Self.shift(Self.config(robust: 1, particles: particles), offsetM: 5_000)
        let gaussian = Self.shift(Self.config(particles: particles), offsetM: 5_000)
        var sameScale = Self.config(particles: particles)
        sameScale.fixSigmaPerAccuracy = 120 / 1414
        let gaussianAtScale = Self.shift(sameScale, offsetM: 5_000)
        #expect(robust.shift < 3, "robust moved \(robust.shift) m")
        #expect(gaussian.shift > 5 * robust.shift && gaussian.east > 0,
                "gaussian moved \(gaussian.shift) m, robust \(robust.shift) m")
        #expect(gaussianAtScale.shift > 200, "gaussian at 120 m moved \(gaussianAtScale.shift) m")
        // An inlier at the tower scale is still evidence.
        let near = Self.shift(Self.config(robust: 1, particles: particles), offsetM: 300)
        #expect(near.east > 5 * robust.shift, "300 m fix moved \(near.east) m, 5 km fix \(robust.shift) m")
    }

    @Test("Robust scale bands: 0.21 × claimed (floor 5 m) below 1000 m, 120 m at and above")
    func robustScaleBands() {
        let c = NavigationConfig()
        #expect(NavigationEngine.noOBDNetworkFixScale(accuracy: 65, config: c) == 0.21 * 65)
        #expect(NavigationEngine.noOBDNetworkFixScale(accuracy: 10, config: c) == 5)
        #expect(NavigationEngine.noOBDNetworkFixScale(accuracy: 999, config: c) == 0.21 * 999)
        #expect(NavigationEngine.noOBDNetworkFixScale(accuracy: 1_000, config: c) == 120)
        #expect(NavigationEngine.noOBDNetworkFixScale(accuracy: 1_414, config: c) == 120)
    }

    // MARK: 4. μ follows the fixes

    @Test("Fix-speed mean: 0 until two fixes ≥ 10 s apart, then within 5 km/h of a 50 km/h track (network fixes every 8 s, 30 m noise) once the window fills; the engine with it ends far closer to the truth than without")
    func fixSpeedFollowsTheTrack() {
        let straight = S(initialHeadingDeg: 30, initialSpeed: Self.kmh50, [.straight(seconds: 300, speed: Self.kmh50)])
        let events = straight.events(gyroNoise: 0.002, obdSpeed: Self.noOBD, fixEvery: 8,
                                     fix: Self.networkFix(accuracy: 100, noise: 30))
        var engine = NavigationEngine(config: Self.config(fixSpeed: 1))
        var checked = 0
        for input in S.inputs(events) {
            engine.ingest(input)
            guard case .location(_, let t) = input else { continue }
            let mu = engine.fixSpeedMean(at: t.nanoseconds)
            if t.seconds < 16 {
                // Fixes at 0 and 8 s: not 10 s apart yet.
                #expect(mu == 0 && engine.fixSpeedEstimate == nil, "\(t.seconds)")
            } else {
                #expect(engine.fixSpeedEstimate?.newestNs == t.nanoseconds)
            }
            if t.seconds >= 130 {
                #expect(abs(mu - Self.kmh50) * 3.6 < 5, "μ \(mu * 3.6) km/h at \(t.seconds) s")
                checked += 1
            }
        }
        #expect(checked >= 20)
        let end = 300.0
        let on = S.run(events, config: Self.config(fixSpeed: 1), sampleTimes: [end]).samples[0]!
        let off = S.run(events, config: Self.config(), sampleTimes: [end]).samples[0]!
        let errorOn = straight.error(on, at: end), errorOff = straight.error(off, at: end)
        #expect(errorOn < errorOff / 2, "error with μ \(errorOn) m, without \(errorOff) m")
        #expect(abs(on.speedMps - Self.kmh50) < 3, "speed \(on.speedMps * 3.6) km/h")
    }

    @Test("Fix-speed estimate: endpoint distance over time, clamped to 0…110 km/h; the window drops fixes over 120 s behind the newest; a late fix slots in by its time; of two fixes with the same time the later arrival is the newest")
    func fixSpeedEstimateRules() {
        func run(_ fixes: [(t: Double, east: Double)], config: NavigationConfig = Self.config(fixSpeed: 1)) -> NavigationEngine {
            var engine = NavigationEngine(config: config)
            for f in fixes { engine.ingest(Self.networkInput(east: f.east, north: 0, accuracy: 30, at: f.t)) }
            return engine
        }
        // 100 m in 10 s, through a detour: 10 m/s from the endpoints.
        let e = run([(0, 0), (5, 400), (10, 100)])
        #expect(abs((e.fixSpeedEstimate?.mps ?? .nan) - 10) < 1e-3)
        // 9.99 s apart: no estimate.
        #expect(run([(0, 0), (9.99, 100)]).fixSpeedEstimate == nil)
        // 2 km in 10 s = 720 km/h: clamped to 110.
        #expect(abs((run([(0, 0), (10, 2_000)]).fixSpeedEstimate?.mps ?? .nan) - 110 / 3.6) < 1e-12)
        // The window: from 200 s, the fix at 0 s is out (> 120 s behind),
        // the one at 100 s in: (3000 − 1000) m / 100 s = 20 m/s (with the
        // fix at 0 s kept it would be 3000 m / 200 s = 15).
        let w = run([(0, 0), (100, 1_000), (200, 3_000)])
        #expect(abs((w.fixSpeedEstimate?.mps ?? .nan) - 20) < 1e-3)
        // Two fixes with the same `t`: the later arrival is the newest
        // (ties go to the later one): 300 m / 10 s, not 100 m / 10 s.
        let tie = run([(0, 0), (10, 100), (10, 300)])
        #expect(abs((tie.fixSpeedEstimate?.mps ?? .nan) - 30) < 1e-3)
        // Exactly 120 s behind is still in the window.
        let edge = run([(0, 0), (120, 1_200)])
        #expect(abs((edge.fixSpeedEstimate?.mps ?? .nan) - 10) < 1e-3)
        // A late fix (older `t`, arriving after a newer one, within
        // `maxFixAgeS`) slots in by its time: the newest endpoint stays the
        // fix at 100 s, (1000 − 500) m / 50 s; appended last it would be
        // the endpoint, 500 m / 45 s.
        var late = NavigationEngine(config: Self.config(fixSpeed: 1))
        late.ingest(Self.networkInput(east: 500, north: 0, accuracy: 30, at: 50))
        late.ingest(Self.networkInput(east: 1_000, north: 0, accuracy: 30, at: 100))
        var lateFix = Self.networkInput(east: 0, north: 0, accuracy: 30, at: 95)
        if case .location(var s, let t) = lateFix {
            s.receivedT = S.ms(100.5)
            s.ageS = 5.5
            lateFix = .location(s, at: t)
        }
        late.ingest(lateFix)
        #expect(late.counters.networkFixesUsed == 3)
        #expect(late.fixSpeedEstimate?.newestNs == S.ms(100).nanoseconds)
        #expect(abs((late.fixSpeedEstimate?.mps ?? .nan) - 10) < 1e-3)
    }

    // MARK: 5. Fixes stop for 10 min

    @Test("Fixes stop for 10 min in no-OBD mode: estimate, ellipse, μ and weights stay finite; μ holds 30 s then relaxes from the gated estimate to the floor (default: 0, τ 500 s; prompt 45's config: 30 km/h, τ 30 s); the same with no motion samples (catch-up macro steps)")
    func fixesStopForTenMinutes() throws {
        let long = S(initialHeadingDeg: 0, initialSpeed: Self.kmh50, [.straight(seconds: 760, speed: Self.kmh50)])
        let lastFix = 152.0
        let fix = Self.networkFix(accuracy: 1_414, noise: 200)
        let events = long.events(gyroNoise: 0.002, obdSpeed: Self.noOBD, fixEvery: 8,
                                 fix: { t, s, rng in t <= lastFix ? fix(t, s, &rng) : nil })
        let runs = Self.switches.map { (robust: $0.robust, fixSpeed: $0.fixSpeed, is45: false) }
            + [(robust: 0, fixSpeed: 1, is45: true)]
        for (robust, fixSpeed, is45) in runs {
            let times = Array(stride(from: 10.0, through: 760, by: 10))
            let config = is45 ? Self.config45() : Self.config(robust: robust, fixSpeed: fixSpeed)
            let floorKmh = config.noOBDFixSpeedFloorKmh, tau = config.noOBDFixSpeedDecayS
            let run = S.run(events, config: config, sampleTimes: times)
            let tag = "\(robust) \(fixSpeed) 45 \(is45)"
            for estimate in run.samples {
                let e = try #require(estimate, "\(tag)")
                #expect([e.latitude, e.longitude, e.headingDeg, e.speedMps, e.ellipse.semiMajorM, e.ellipse.semiMinorM,
                         e.ellipse.orientationDeg, e.effectiveSampleSize].allSatisfy { $0.isFinite }, "\(tag) at \(e.t.seconds)")
            }
            Self.expectFinite(run.engine, tag)
            guard fixSpeed == 1 else { continue }
            let estimate = try #require(run.engine.fixSpeedEstimate)
            #expect(estimate.newestNs == S.ms(lastFix).nanoseconds)
            let floor = floorKmh / 3.6
            // The 50 km/h track moves far beyond the gate's D0: μ̂ is the
            // track speed whatever the floor.
            #expect(abs(estimate.mps - Self.kmh50) * 3.6 < 15, "\(tag): μ̂ \(estimate.mps * 3.6) km/h")
            #expect(estimate.gatedMps == estimate.mps)
            var previous = estimate.mps
            for t in stride(from: lastFix, through: 760, by: 5) {
                let mu = run.engine.fixSpeedMean(at: S.ms(t).nanoseconds)
                #expect(mu.isFinite)
                if t - lastFix <= 30 {
                    #expect(mu == estimate.mps)
                } else {
                    // Monotone towards the floor, never past it.
                    #expect(abs(mu - floor) <= abs(previous - floor) && (mu - floor) * (estimate.mps - floor) >= 0)
                }
                previous = mu
            }
            let end = floor + (estimate.gatedMps - floor) * exp(-(760 - lastFix - 30) / tau)
            #expect(abs(run.engine.fixSpeedMean(at: S.ms(760).nanoseconds) - end) < 1e-9)
            if is45 { #expect(abs(end - floor) * 3.6 < 0.01) }
            let mid = lastFix + 30 + tau
            let expected = floor + (estimate.gatedMps - floor) * exp(-1)
            #expect(abs(run.engine.fixSpeedMean(at: S.ms(mid).nanoseconds) - expected) < 1e-9)
        }

        // No motion samples: only fixes, then one after the 10 min gap; the
        // silence is caught up in macro steps.
        let fixesOnly = events.filter { if case .location = $0.payload { true } else { false } }
        var lastOne = try #require(fixesOnly.last)
        if case .location(var s) = lastOne.payload {
            let p = S.plane.geodetic(east: 0, north: Self.kmh50 * 752)
            s.latitude = p.latitude
            s.longitude = p.longitude
            s.receivedT = S.ms(752.05)
            lastOne = .location(s, at: S.ms(752))
        }
        for (robust, fixSpeed) in Self.switches {
            let run = S.run(fixesOnly + [lastOne], config: Self.config(robust: robust, fixSpeed: fixSpeed),
                            sampleTimes: [600, 752.1])
            #expect(run.engine.counters.macroSteps > 0)
            for estimate in run.samples {
                let e = try #require(estimate)
                #expect([e.latitude, e.longitude, e.speedMps, e.ellipse.semiMajorM, e.effectiveSampleSize]
                    .allSatisfy { $0.isFinite }, "\(robust) \(fixSpeed)")
            }
            Self.expectFinite(run.engine, "fixes only \(robust) \(fixSpeed)")
        }
    }

    static func expectFinite(_ engine: NavigationEngine, _ tag: String) {
        #expect(engine.weight.allSatisfy { $0.isFinite } && engine.logWeight.allSatisfy { $0.isFinite }, "\(tag)")
        #expect(abs(engine.weight.reduce(0, +) - 1) < 1e-9, "\(tag)")
        for array in [engine.east, engine.north, engine.covEE, engine.covEN, engine.covNN, engine.speedOffset] {
            #expect(array.allSatisfy { $0.isFinite }, "\(tag)")
        }
        #expect(engine.effectiveSampleSize.isFinite && engine.effectiveSampleSize >= 1, "\(tag)")
    }

    @Test("∫μ dt in closed form matches the held-then-relaxing μ integrated numerically, across the hold's end; τ = 0 jumps to the floor")
    func fixSpeedIntegral() throws {
        var engine = NavigationEngine(config: Self.config45())
        engine.ingest(Self.networkInput(east: 0, north: 0, accuracy: 30, at: 0))
        engine.ingest(Self.networkInput(east: 200, north: 0, accuracy: 30, at: 10))
        let estimate = try #require(engine.fixSpeedEstimate)
        #expect(abs(estimate.mps - 20) < 1e-3)
        func numeric(_ a: Double, _ b: Double) -> Double {
            let n = 20_000
            let h = (b - a) / Double(n)
            var sum = 0.0
            for k in 0..<n {
                sum += engine.fixSpeedMean(at: S.ms(a + (Double(k) + 0.5) * h).nanoseconds) * h
            }
            return sum
        }
        for (a, b) in [(10.0, 30.0), (20.0, 60.0), (45.0, 47.0), (50.0, 400.0), (0.0, 10.0)] {
            let closed = engine.fixSpeedMeanIntegral(from: S.ms(a).nanoseconds, to: S.ms(b).nanoseconds)
            #expect(abs(closed - numeric(a, b)) < 1e-4 * max(1, closed), "\(a)…\(b): \(closed) vs \(numeric(a, b))")
        }
        #expect(engine.fixSpeedMeanIntegral(from: S.ms(50).nanoseconds, to: S.ms(50).nanoseconds) == 0)
        // An empty step's mean is μ at that instant.
        #expect(engine.fixSpeedMeanAverage(from: S.ms(50).nanoseconds, to: S.ms(50).nanoseconds)
                == engine.fixSpeedMean(at: S.ms(50).nanoseconds))
        // A 0.1 s step: its mean is the midpoint value to second order.
        #expect(abs(engine.fixSpeedMeanAverage(from: S.ms(60).nanoseconds, to: S.ms(60.1).nanoseconds)
                    - engine.fixSpeedMean(at: S.ms(60.05).nanoseconds)) < 1e-5)

        var instant = Self.config45()
        instant.noOBDFixSpeedDecayS = 0
        var e0 = NavigationEngine(config: instant)
        e0.ingest(Self.networkInput(east: 0, north: 0, accuracy: 30, at: 0))
        e0.ingest(Self.networkInput(east: 200, north: 0, accuracy: 30, at: 10))
        #expect(e0.fixSpeedMean(at: S.ms(40).nanoseconds) == (e0.fixSpeedEstimate?.mps ?? .nan))
        #expect(e0.fixSpeedMean(at: S.ms(40.001).nanoseconds) == 30 / 3.6)
        // 30 s held at 20 m/s, then 10 s at the floor.
        #expect(abs(e0.fixSpeedMeanIntegral(from: S.ms(10).nanoseconds, to: S.ms(50).nanoseconds)
                    - (30 * (e0.fixSpeedEstimate?.mps ?? .nan) + 10 * 30 / 3.6)) < 1e-6)
    }

    // MARK: Review run 83

    /// Every particle at the origin heading east, no speed offset, the
    /// given per-axis variance, equal weights: identical particles, so an
    /// update moves each the same way and leaves the weights uniform.
    static func setIdenticalCloud(_ engine: inout NavigationEngine, variance: Double) {
        let n = engine.east.count
        for i in 0..<n {
            engine.east[i] = 0
            engine.north[i] = 0
            engine.heading[i] = .pi / 2
            engine.speedOffset[i] = 0
            engine.covEE[i] = variance
            engine.covEN[i] = 0
            engine.covNN[i] = variance
            engine.logWeight[i] = -log(Double(n))
        }
        engine.normalizeWeights()
    }

    static func weightedMean(_ engine: NavigationEngine) -> (east: Double, north: Double) {
        var e = 0.0, n = 0.0
        for i in engine.east.indices {
            e += engine.weight[i] * engine.east[i]
            n += engine.weight[i] * engine.north[i]
        }
        return (e, n)
    }

    @Test("R83.1-1: fix-speed μ moves the cloud through catch-up macro steps: an 80 s input gap (μ = 20 m/s held to 40 s, then relaxing to 30 km/h) moves the mean east by ∫μ dt within 0.5 %, as stepping one by one does; with μ off it stays within 5 m")
    func fixSpeedMeanThroughMacroSteps() throws {
        func run(fixSpeed: Int, maxCatchUpSteps: Int = 100) throws -> (displacement: (east: Double, north: Double),
                                                                         expected: Double, macroSteps: Int) {
            var config = Self.config45(fixSpeed: fixSpeed)
            config.maxCatchUpSteps = maxCatchUpSteps
            var engine = NavigationEngine(config: config)
            // μ̂ = 200 m / 10 s from the fixes at 0 and 10 s (newest at 10 s).
            engine.ingest(Self.networkInput(east: 0, north: 0, accuracy: 30, at: 0))
            engine.ingest(Self.networkInput(east: 200, north: 0, accuracy: 30, at: 10))
            engine.ingest(Self.still(at: 20.05))
            let from = try #require(engine.lastStepTime)
            #expect(from == S.ms(20))
            Self.setIdenticalCloud(&engine, variance: 400)
            let macroBefore = engine.counters.macroSteps
            // No input for 80 s: 800 grid steps, caught up in macro steps.
            engine.ingest(Self.still(at: 100.05))
            let to = try #require(engine.lastStepTime)
            #expect(to == S.ms(100))
            let expected = engine.fixSpeedMeanIntegral(from: from.nanoseconds, to: to.nanoseconds)
            Self.expectFinite(engine, "macro \(fixSpeed) \(maxCatchUpSteps)")
            return (Self.weightedMean(engine), expected, engine.counters.macroSteps - macroBefore)
        }
        // 20 s held at 20 m/s, then 60 s relaxing from 20 m/s to 30 km/h.
        let floor = 30 / 3.6
        let closedForm = 20 * 20 + floor * 60 + (20 - floor) * 30 * -expm1(-2)
        let macro = try run(fixSpeed: 1)
        #expect(macro.macroSteps > 0)
        #expect(abs(macro.expected - closedForm) < 1e-6 * closedForm, "\(macro.expected) vs \(closedForm)")
        #expect(abs(macro.displacement.east - closedForm) < 0.005 * closedForm,
                "macro steps moved \(macro.displacement.east) m east, ∫μ = \(closedForm) m")
        #expect(abs(macro.displacement.north) < 0.01 * closedForm)
        let stepped = try run(fixSpeed: 1, maxCatchUpSteps: 1_000_000)
        #expect(stepped.macroSteps == 0)
        #expect(abs(stepped.displacement.east - closedForm) < 0.005 * closedForm,
                "stepping moved \(stepped.displacement.east) m east, ∫μ = \(closedForm) m")
        let off = try run(fixSpeed: 0)
        #expect(off.macroSteps > 0)
        #expect(abs(off.displacement.east) < 5, "μ off moved \(off.displacement.east) m east")
    }

    @Test("R83.1-2: a robust network fix 15 s after the previous one is tempered by 15 s / noOBDNetworkFixCorrelationS (scale² divided by it), not by networkFixCorrelationS: the identical-particle Kalman shift matches the closed form for 30 s and for 60 s to 1e-9 m, and changing networkFixCorrelationS leaves it unchanged")
    func robustTemperingUsesItsOwnTimeConstant() {
        let p = 400.0, offset = 300.0, scale = 120.0, nu = 2.0, dt = 15.0
        /// The shift every particle (so the mean) takes: Kalman gain of the
        /// scale² / w inflated by max(1, (ν + m²)/(ν + 2)).
        func predicted(correlationS: Double) -> Double {
            let r = scale * scale / min(1, dt / correlationS)
            let m2 = offset * offset / (p + r)
            let inflation = max(1, (nu + m2) / (nu + 2))
            return p / (p + r * inflation) * offset
        }
        func shift(_ edit: (inout NavigationConfig) -> Void) -> (east: Double, north: Double) {
            var config = Self.config(robust: 1)
            edit(&config)
            var engine = NavigationEngine(config: config)
            engine.ingest(Self.networkInput(east: 0, north: 0, accuracy: 30, at: 0))
            engine.ingest(Self.still(at: dt + 0.05))
            Self.setIdenticalCloud(&engine, variance: p)
            // A tower fix (scale 120 m) 300 m east, 15 s after the first; no step between.
            engine.ingest(Self.networkInput(east: offset, north: 0, accuracy: 1414, at: dt))
            #expect(engine.lastStepTime == S.ms(dt))
            let after = Self.weightedMean(engine)
            // The same fix again (same `t`, same arrival): Δt = 0, weight 0,
            // no update at all.
            let weights = engine.weight, east = engine.east, cov = engine.covEE
            engine.ingest(Self.networkInput(east: offset, north: 0, accuracy: 1414, at: dt))
            #expect(engine.weight == weights && engine.east == east && engine.covEE == cov)
            return after
        }
        let at30 = shift { _ in }
        let at60 = shift { $0.noOBDNetworkFixCorrelationS = 60 }
        let otherKey = shift { $0.networkFixCorrelationS = 5 }
        #expect(abs(at30.east - predicted(correlationS: 30)) < 1e-9, "\(at30.east) vs \(predicted(correlationS: 30))")
        #expect(abs(at60.east - predicted(correlationS: 60)) < 1e-9, "\(at60.east) vs \(predicted(correlationS: 60))")
        #expect(abs(at30.north) < 1e-9 && abs(at60.north) < 1e-9)
        // The two weights give clearly different shifts (≈ 3.25 and 2.07 m).
        #expect(at30.east > 1.3 * at60.east && at60.east > 1)
        // networkFixCorrelationS is the Gaussian path's key only.
        #expect(otherKey.east == at30.east && otherKey.north == at30.north)
    }

    @Test("R83.2-1: a robust network fix older than staleFixAgeS at arrival grows its scale by max(staleFixSigmaGrowthMps, 0) × age: a 65 m Wi-Fi fix 7.05 s old has scale 0.21 × 65 + 7.05 = 20.7 m; the identical-particle Kalman shift matches that closed form to 1e-9 m, and the same fix 0.05 s old (scale 13.65 m) matches its own")
    func robustScaleGrowsWithFixAge() {
        let p = 400.0, offset = 30.0, accuracy = 65.0, fixT = 8.0, nu = 2.0
        // Tempering 8 s after the first network fix, over 30 s: the same for both ages.
        let temper = fixT / 30
        func predicted(scale: Double) -> Double {
            let r = scale * scale / temper
            let m2 = offset * offset / (p + r)
            let inflation = max(1, (nu + m2) / (nu + 2))
            return p / (p + r * inflation) * offset
        }
        /// The fix (t = 8 s, 30 m east) arriving at `arrival`; no speed
        /// noise, so the cloud does not move and the fix's latency shift is 0.
        func shift(arrival: Double) -> (east: Double, north: Double) {
            var config = Self.config(robust: 1)
            config.staleSpeedNoiseMpsPerSqrtS = 0
            var engine = NavigationEngine(config: config)
            engine.ingest(Self.networkInput(east: 0, north: 0, accuracy: 30, at: 0))
            engine.ingest(Self.still(at: arrival))
            Self.setIdenticalCloud(&engine, variance: p)
            var fix = Self.networkInput(east: offset, north: 0, accuracy: accuracy, at: fixT)
            if case .location(var sample, let t) = fix {
                sample.receivedT = S.ms(arrival)
                sample.ageS = arrival - fixT
                fix = .location(sample, at: t)
            }
            let used = engine.counters.networkFixesUsed
            engine.ingest(fix)
            #expect(engine.counters.networkFixesUsed == used + 1)
            return Self.weightedMean(engine)
        }
        let config = NavigationConfig()
        #expect(config.staleFixAgeS == 5 && config.maxFixAgeS == 10 && config.staleFixSigmaGrowthMps == 1)
        let band = 0.21 * accuracy
        let stale = shift(arrival: fixT + 7.05)
        let fresh = shift(arrival: fixT + 0.05)
        let staleScale = band + max(config.staleFixSigmaGrowthMps, 0) * 7.05
        #expect(abs(stale.east - predicted(scale: staleScale)) < 1e-9, "\(stale.east) vs \(predicted(scale: staleScale))")
        #expect(abs(fresh.east - predicted(scale: band)) < 1e-9, "\(fresh.east) vs \(predicted(scale: band))")
        #expect(abs(stale.north) < 1e-9 && abs(fresh.north) < 1e-9)
        // ≈ 6.0 m against ≈ 10.9 m: the older fix pulls less.
        #expect(fresh.east > 1.5 * stale.east && stale.east > 3)
    }

    @Test("R83.3-1: the robust particle log-weight (ν = 2 and 5) is the bivariate Student-t −(ν + 2)/2 · log(1 + m²/ν) − ½ log|S|, S = P + (s²/w)·I: two particles at different offsets, with equal and then unequal (correlated) covariances, take log-weights whose difference matches the closed form to 1e-9")
    func robustWeightIsTheStudentT() {
        for nu in [2.0, 5.0] { Self.robustWeight(nu: nu) }
    }

    static func robustWeight(nu: Double) {
        let scale = 120.0, dt = 15.0
        let r = scale * scale / min(1, dt / 30)  // tempered 15 s / 30 s
        let fix = (east: 300.0, north: 200.0)
        let positions = [(east: 0.0, north: 0.0), (east: 80.0, north: -40.0)]
        /// Log-likelihood of particle `k` with covariance (ee, en, nn), constants dropped.
        func expected(_ k: Int, _ c: (ee: Double, en: Double, nn: Double)) -> Double {
            let see = c.ee + r, snn = c.nn + r, sen = c.en
            let det = see * snn - sen * sen
            let de = fix.east - positions[k].east, dn = fix.north - positions[k].north
            let m2 = (snn * de * de - 2 * sen * de * dn + see * dn * dn) / det
            return -(nu + 2) / 2 * log(1 + m2 / nu) - 0.5 * log(det)
        }
        func logWeightDifference(_ covs: [(ee: Double, en: Double, nn: Double)]) -> Double {
            var config = Self.config(robust: 1, particles: 2)
            config.staleSpeedNoiseMpsPerSqrtS = 0
            config.noOBDNetworkFixNu = nu
            var engine = NavigationEngine(config: config)
            engine.ingest(Self.networkInput(east: 0, north: 0, accuracy: 30, at: 0))
            engine.ingest(Self.still(at: dt + 0.05))
            #expect(engine.east.count == 2)
            for k in 0..<2 {
                engine.east[k] = positions[k].east
                engine.north[k] = positions[k].north
                engine.covEE[k] = covs[k].ee
                engine.covEN[k] = covs[k].en
                engine.covNN[k] = covs[k].nn
                engine.logWeight[k] = -log(2)
            }
            engine.normalizeWeights()
            engine.ingest(Self.networkInput(east: fix.east, north: fix.north, accuracy: 1414, at: dt))
            #expect(engine.lastStepTime == S.ms(dt))
            #expect(engine.weight.allSatisfy { $0.isFinite && $0 > 0 })
            return engine.logWeight[0] - engine.logWeight[1]
        }
        let equal = [(ee: 400.0, en: 0.0, nn: 400.0), (ee: 400.0, en: 0.0, nn: 400.0)]
        let unequal = [(ee: 400.0, en: 100.0, nn: 900.0), (ee: 2_500.0, en: -300.0, nn: 1_600.0)]
        for covs in [equal, unequal] {
            let got = logWeightDifference(covs)
            let want = expected(0, covs[0]) - expected(1, covs[1])
            #expect(abs(got - want) < 1e-9, "ν \(nu): log-weight difference \(got) vs \(want)")
            #expect(abs(want) > 1e-3)
        }
    }

    /// A no-OBD engine with μ on, without speed, heading or scale noise:
    /// every particle moves exactly at μ (or at the OBD speed), so a mean
    /// displacement is a closed form. `setIdenticalCloud` sets the headings
    /// east and the scales to 1.
    static func noiselessConfig(fixSpeed: Int = 1, maxCatchUpSteps: Int = 100) -> NavigationConfig {
        var config = Self.config(fixSpeed: fixSpeed)
        config.staleSpeedNoiseMpsPerSqrtS = 0
        config.headingNoiseDegPerSqrtS = 0
        config.scaleNoisePerSqrtS = 0
        config.maxCatchUpSteps = maxCatchUpSteps
        return config
    }

    @Test("Sweep: without speed, heading or scale noise the cloud moves exactly ∫μ dt (to 1e-6 relative) over an 80 s gap, through macro steps and stepping one by one alike (μ averaged over each step, not its end value)")
    func fixSpeedMeanExactWithoutNoise() throws {
        for maxCatchUpSteps in [100, 1_000_000] {
            var engine = NavigationEngine(config: Self.noiselessConfig(maxCatchUpSteps: maxCatchUpSteps))
            engine.ingest(Self.networkInput(east: 0, north: 0, accuracy: 30, at: 0))
            engine.ingest(Self.networkInput(east: 200, north: 0, accuracy: 30, at: 10))
            engine.ingest(Self.still(at: 20.05))
            Self.setIdenticalCloud(&engine, variance: 400)
            for i in engine.scale.indices { engine.scale[i] = 1 }
            let macroBefore = engine.counters.macroSteps
            engine.ingest(Self.still(at: 100.05))
            let expected = engine.fixSpeedMeanIntegral(from: S.ms(20).nanoseconds, to: S.ms(100).nanoseconds)
            let moved = Self.weightedMean(engine)
            #expect((engine.counters.macroSteps > macroBefore) == (maxCatchUpSteps == 100))
            #expect(abs(moved.east - expected) < 1e-6 * expected, "\(maxCatchUpSteps): \(moved.east) vs ∫μ \(expected)")
            #expect(abs(moved.north) < 1e-6 * expected)
        }
    }

    @Test("Sweep: after the first OBD reply μ is never added again: with a speed estimate from the fixes before it, a later OBD dropout (stale steps, then a catch-up gap) moves the cloud at the held OBD speed exactly")
    func noFixSpeedAfterTheFirstReply() throws {
        var engine = NavigationEngine(config: Self.noiselessConfig())
        // No OBD yet: μ̂ = 20 m/s from the network fixes.
        for (k, t) in [0.0, 10, 20].enumerated() {
            engine.ingest(Self.networkInput(east: 200 * Double(k), north: 0, accuracy: 30, at: t))
        }
        #expect(abs((engine.fixSpeedEstimate?.mps ?? .nan) - 20) < 1e-3)
        // OBD 36 km/h from 20.5 s to 30 s, then nothing.
        for t in stride(from: 20.5, through: 30, by: 0.5) {
            engine.ingest(.obd(OBDSample(pid: .vehicleSpeed, value: 36, unit: .kilometersPerHour, ecu: "7E8"), at: S.ms(t)))
        }
        #expect(engine.obdEverIngested && !engine.noOBDFixSpeedMeanActive)
        #expect(engine.lastStepTime == S.ms(30))
        Self.setIdenticalCloud(&engine, variance: 400)
        for i in engine.scale.indices { engine.scale[i] = 1 }
        let v = (36 + NavigationConfig().obdSpeedOffsetKmh) / 3.6
        // 30 → 40 s: fresh to 32 s, then stale, stepped one by one.
        let staleBefore = engine.counters.staleSpeedSteps
        engine.ingest(Self.still(at: 40.05))
        #expect(engine.counters.staleSpeedSteps > staleBefore)
        #expect(abs(Self.weightedMean(engine).east - v * 10) < 1e-6 * v * 10, "\(Self.weightedMean(engine).east) vs \(v * 10)")
        // 40 → 200 s: no input at all, caught up in macro steps.
        let macroBefore = engine.counters.macroSteps
        engine.ingest(Self.still(at: 200.05))
        #expect(engine.counters.macroSteps > macroBefore)
        #expect(abs(Self.weightedMean(engine).east - v * 170) < 1e-6 * v * 170, "\(Self.weightedMean(engine).east) vs \(v * 170)")
    }

    // MARK: Keys

    @Test("No-OBD keys: decoding without them gives the defaults (off); refused values")
    func configKeys() throws {
        let keys = ["noOBDRobustNetworkFix", "noOBDNetworkFixNu", "noOBDNetworkFixScalePerAccuracy",
                    "noOBDNetworkFixScaleFloorM", "noOBDNetworkFixTowerAccuracyM", "noOBDNetworkFixTowerScaleM",
                    "noOBDNetworkFixCorrelationS", "noOBDFixSpeedMean", "noOBDFixSpeedWindowS", "noOBDFixSpeedMinSpanS",
                    "noOBDFixSpeedMaxKmh", "noOBDFixSpeedHoldS", "noOBDFixSpeedDecayS", "noOBDFixSpeedFloorKmh",
                    "noOBDFixSpeedGate", "noOBDFixSpeedGateK", "noOBDFixSpeedGateSigmaLowM", "noOBDFixSpeedGateSigmaMidM",
                    "noOBDFixSpeedGateSigmaTowerM"]
        var json = try #require(try JSONSerialization.jsonObject(with: NavigationConfig().canonicalJSON()) as? [String: Any])
        for key in keys { #expect(json[key] != nil, "\(key)") }
        for key in keys { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(NavigationConfig.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == NavigationConfig())
        #expect(!keys.contains { NavigationConfig.roadOnlyKeys.contains($0) })

        func refused(_ edit: (inout NavigationConfig) -> Void) -> String? {
            var c = NavigationConfig()
            edit(&c)
            return c.invalidReason
        }
        for good in [0, 1] {
            #expect(refused { $0.noOBDRobustNetworkFix = good } == nil)
            #expect(refused { $0.noOBDFixSpeedMean = good } == nil)
        }
        for bad in [2, -1] {
            #expect(refused { $0.noOBDRobustNetworkFix = bad }?.contains("noOBDRobustNetworkFix") == true)
            #expect(refused { $0.noOBDFixSpeedMean = bad }?.contains("noOBDFixSpeedMean") == true)
        }
        for good in [0, 1, 2] { #expect(refused { $0.noOBDFixSpeedGate = good } == nil) }
        for bad in [3, -1] { #expect(refused { $0.noOBDFixSpeedGate = bad }?.contains("noOBDFixSpeedGate") == true) }
        let positive: [(String, WritableKeyPath<NavigationConfig, Double>)] = [
            ("noOBDNetworkFixNu", \.noOBDNetworkFixNu), ("noOBDNetworkFixScalePerAccuracy", \.noOBDNetworkFixScalePerAccuracy),
            ("noOBDNetworkFixScaleFloorM", \.noOBDNetworkFixScaleFloorM),
            ("noOBDNetworkFixTowerAccuracyM", \.noOBDNetworkFixTowerAccuracyM),
            ("noOBDNetworkFixTowerScaleM", \.noOBDNetworkFixTowerScaleM),
            ("noOBDNetworkFixCorrelationS", \.noOBDNetworkFixCorrelationS),
            ("noOBDFixSpeedMinSpanS", \.noOBDFixSpeedMinSpanS), ("noOBDFixSpeedWindowS", \.noOBDFixSpeedWindowS),
            ("noOBDFixSpeedGateK", \.noOBDFixSpeedGateK), ("noOBDFixSpeedGateSigmaLowM", \.noOBDFixSpeedGateSigmaLowM),
            ("noOBDFixSpeedGateSigmaMidM", \.noOBDFixSpeedGateSigmaMidM),
            ("noOBDFixSpeedGateSigmaTowerM", \.noOBDFixSpeedGateSigmaTowerM),
        ]
        for (name, key) in positive {
            for bad in [0.0, -1, .infinity, .nan] {
                #expect(refused { $0[keyPath: key] = bad }?.contains(name) == true, "\(name) \(bad)")
            }
        }
        #expect(NavigationConfig.maxNoOBDFixSpeedWindowS == 3_600)
        #expect(refused { $0.noOBDFixSpeedWindowS = NavigationConfig.maxNoOBDFixSpeedWindowS } == nil)
        #expect(refused { $0.noOBDFixSpeedWindowS = NavigationConfig.maxNoOBDFixSpeedWindowS + 1 } != nil)
        let nonNegative: [(String, WritableKeyPath<NavigationConfig, Double>)] = [
            ("noOBDFixSpeedMaxKmh", \.noOBDFixSpeedMaxKmh), ("noOBDFixSpeedHoldS", \.noOBDFixSpeedHoldS),
            ("noOBDFixSpeedDecayS", \.noOBDFixSpeedDecayS), ("noOBDFixSpeedFloorKmh", \.noOBDFixSpeedFloorKmh),
        ]
        for (name, key) in nonNegative {
            #expect(refused { $0[keyPath: key] = 0 } == nil, "\(name)")
            for bad in [-1.0, .infinity, .nan] {
                #expect(refused { $0[keyPath: key] = bad }?.contains(name) == true, "\(name) \(bad)")
            }
        }
    }
}
