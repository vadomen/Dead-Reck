import Foundation
import Testing

@testable import DriveLoggerCore

/// N3.0 engine fixes (docs/N3_PLAN.md, "N3.0", engine-fix table). Each test
/// was run against the code before its fix and failed there.
@Suite("Navigation N3.0 engine fixes")
struct NavigationN30EngineTests {
    typealias S = SyntheticDrive
    typealias H = NavigationHeldFixTests

    /// A GNSS fix at plane (east, north) with time `t`, arriving at
    /// `arrival`, reporting `speed` m/s and `course`°.
    static func gnss(_ t: Double, arrival: Double? = nil, east: Double = 0, north: Double = 0, accuracy: Double = 10,
                     speed: Double, course: Double) -> NavigationInput {
        let p = S.plane.geodetic(east: east, north: north)
        let arrival = arrival ?? t + 0.05
        return .location(LocationSample(latitude: p.latitude, longitude: p.longitude, altitude: 0,
                                        horizontalAccuracy: accuracy, verticalAccuracy: -1,
                                        speed: speed, speedAccuracy: 0.5, course: course, courseAccuracy: 5,
                                        receivedT: S.ms(arrival), ageS: arrival - t),
                         at: S.ms(t))
    }

    /// A tower fix (no speed: a network fix) at plane (east, north).
    static func tower(_ t: Double, east: Double = 0, north: Double = 0, accuracy: Double = 300) -> NavigationInput {
        let p = S.plane.geodetic(east: east, north: north)
        return .location(LocationSample(latitude: p.latitude, longitude: p.longitude, altitude: 0,
                                        horizontalAccuracy: accuracy, verticalAccuracy: -1,
                                        speed: -1, speedAccuracy: -1, course: -1, courseAccuracy: -1,
                                        receivedT: S.ms(t + 0.05), ageS: 0.05),
                         at: S.ms(t))
    }

    /// Motion samples at 100 Hz from `from` to `to` (still, no yaw).
    static func still(_ from: Double, _ to: Double) -> [NavigationInput] {
        stride(from: from, through: to, by: 0.01).map { H.motion($0) }
    }

    /// Inputs sorted by arrival, ties in the given order.
    static func ordered(_ inputs: [NavigationInput]) -> [NavigationInput] {
        inputs.enumerated()
            .sorted { $0.element.arrival != $1.element.arrival ? $0.element.arrival < $1.element.arrival : $0.offset < $1.offset }
            .map(\.element)
    }

    // MARK: R11.1-4 course gate needs a known OBD speed

    @Test("R11.1-4: parked before the adapter connects (no OBD), a 10 m fix with 3.5 m/s speed noise does not set the heading")
    func noOBDAtInitialisationVetoesCourse() throws {
        let inputs = Self.ordered(Self.still(0, 3) + [Self.gnss(1, speed: 3.5, course: 90)])
        let engine = H.engine(inputs, config: S.config(particles: 400))
        let estimate = try #require(engine.estimate(at: S.ms(3)))
        #expect(engine.counters.courseUpdates == 0)
        // Uniform over the circle: a large circular std, not N(90°, 5°).
        #expect(estimate.headingStdDeg > 60, "heading std \(estimate.headingStdDeg)° from a parked course")
    }

    @Test("R11.1-4: parked with OBD gone stale at 0, a clean fix with speed noise neither reseeds nor updates the course")
    func staleZeroVetoesCourse() throws {
        // OBD 0 at 0.05–2.05 s, then the link drops: stale 0, parked latch
        // armed. Initialised by a tower fix (headings uniform), then a 10 m
        // fix at 8 s reporting 3.5 m/s and a course.
        let obd = stride(from: 0.05, through: 2.05, by: 0.1).map { H.obd(0, $0) }
        let inputs = Self.ordered(Self.still(0, 10) + obd + [Self.tower(0.5), Self.gnss(8, speed: 3.5, course: 90)])
        let engine = H.engine(inputs, config: S.config(particles: 400))
        let estimate = try #require(engine.estimate(at: S.ms(10)))
        #expect(engine.counters.staleParkedSteps > 50)
        #expect(engine.counters.reseeds == 0 && engine.counters.courseUpdates == 0,
                "reseeds \(engine.counters.reseeds), course updates \(engine.counters.courseUpdates)")
        #expect(estimate.headingStdDeg > 60, "heading std \(estimate.headingStdDeg)°")
    }

    @Test("R11.1-4: a dropout while driving (stale OBD holding 15 m/s) still lets a clean course through")
    func staleMovingStillUsesCourse() throws {
        // 15 m/s east; OBD stops after 5 s; clean fixes at 10–12 s.
        let drive = S(initialHeadingDeg: 90, initialSpeed: 15, [.straight(seconds: 14, speed: 15)])
        let events = drive.events(obdSpeed: { t, state in t < 5 ? (state.speed * 3.6).rounded(.down) : nil },
                                  fix: { t, state, rng in
                                      t == 0 || t >= 10 ? S.cleanFix(accuracy: 5, positionNoise: 0)(t, state, &rng) : nil
                                  })
        let (engine, samples) = S.run(events, config: S.config(particles: 400), sampleTimes: [13])
        let estimate = try #require(samples.first ?? nil)
        #expect(engine.counters.staleSpeedSteps > 0)
        #expect(engine.counters.courseUpdates >= 4, "course updates \(engine.counters.courseUpdates)")
        #expect(abs(angleDifference(estimate.headingDeg, 90)) < 3)
    }

    // MARK: R11.1-5 a stale fix accepted while stopped needs no motion since its time

    /// 10 m/s north for 30 s with clean fixes, braking to a stop over 4 s,
    /// then stopped (fresh OBD 0) to 70 s. Plus one extra fix at `fixT`
    /// (truth position there, 5 m), arriving at `arrival`.
    static func stopWithStaleFix(fixT: Double, arrival: Double) -> (drive: S, events: [LogEvent]) {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 10, [
            .straight(seconds: 30, speed: 10), .ramp(seconds: 4, from: 10, to: 0), .stop(seconds: 36),
        ])
        let clean = S.cleanFix(accuracy: 5, positionNoise: 0)
        var events = drive.events(fix: { t, state, rng in t <= 30 ? clean(t, state, &rng) : nil })
        let truth = drive.truth(at: fixT)
        let p = S.plane.geodetic(east: truth.east, north: truth.north)
        let stale = LocationSample(latitude: p.latitude, longitude: p.longitude, altitude: 0,
                                   horizontalAccuracy: 5, verticalAccuracy: -1, speed: truth.speed, speedAccuracy: 0.5,
                                   course: -1, courseAccuracy: -1, receivedT: S.ms(arrival), ageS: arrival - fixT)
        events.append(.location(stale, at: S.ms(fixT)))
        return (drive, events)
    }

    static func staleConfig() -> NavigationConfig {
        var config = S.config(particles: 400)
        // Without the stale σ growth the fix is taken at σ 5 m, so an
        // unshifted fix pulls hard enough to see.
        config.staleFixSigmaGrowthMps = 0
        return config
    }

    @Test("R11.1-5: a 16 s old fix from before the stop, arriving while stopped, is ignored: the history cannot shift it")
    func staleFixFromBeforeStopIgnored() throws {
        // Fix at 28 s (moving), arriving at 44 s (stopped since 34 s). The
        // ~10 s history starts at ~34 s, so the motion from 28 s to 34 s
        // (40 m) could not be compensated: unshifted it pulls the estimate
        // back along the track.
        let (drive, events) = Self.stopWithStaleFix(fixT: 28, arrival: 44)
        let (engine, samples) = S.run(events, config: Self.staleConfig(), sampleTimes: [43.9, 44.1])
        let before = try #require(samples[0]), after = try #require(samples[1])
        #expect(engine.counters.fixesIgnoredStale == 1 && engine.counters.staleFixesIgnoredMoved == 1,
                "ignored stale \(engine.counters.fixesIgnoredStale)")
        #expect(after.east == before.east && after.north == before.north)
        #expect(drive.error(after, at: 44.1) < 2, "error \(drive.error(after, at: 44.1)) m after the stale fix")
    }

    @Test("R11.1-5: a 14 s old fix from during the stop, arriving while still stopped, is still used")
    func staleFixDuringStopUsed() throws {
        let (_, events) = Self.stopWithStaleFix(fixT: 36, arrival: 50)
        let (engine, samples) = S.run(events, config: Self.staleConfig(), sampleTimes: [49.9, 50.1])
        let before = try #require(samples[0]), after = try #require(samples[1])
        #expect(engine.counters.fixesIgnoredStale == 0)
        #expect(after.ellipse.semiMajorM < before.ellipse.semiMajorM, "the fix was not applied")
    }

    @Test("R11.1-5: a pre-session fix that initialises the engine while stopped is still used")
    func staleFixInitialisesWhileStopped() throws {
        let inputs = Self.ordered(Self.still(0, 3) + [H.obd(0, 0.05), H.fix(-120, arrival: 0.2)])
        let engine = H.engine(inputs)
        #expect(engine.isInitialized && engine.counters.fixesUsed == 1 && engine.counters.fixesIgnoredStale == 0)
    }

    // MARK: R11.2-2 latency shift interpolated between history entries

    /// Mean signed along-track error (estimate − truth, m; positive =
    /// ahead) just after each fix arrives, driving north at 30 m/s. Clean
    /// fixes at whole seconds up to 5 s converge the heading; from 6 s
    /// fixes of the exact truth at `k + offset`, arriving 0.5 s later.
    static func alongTrackBias(offset: Double) throws -> Double {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 30, [.straight(seconds: 62, speed: 30)])
        var extra: [LogEvent] = []
        var arrivals: [Double] = []
        for k in 6...60 {
            let t = Double(k) + offset
            let truth = drive.truth(at: t)
            let p = S.plane.geodetic(east: truth.east, north: truth.north)
            extra.append(.location(LocationSample(latitude: p.latitude, longitude: p.longitude, altitude: 0,
                                                  horizontalAccuracy: 5, verticalAccuracy: -1,
                                                  speed: 30, speedAccuracy: 0.3, course: 0, courseAccuracy: 2,
                                                  receivedT: S.ms(t + 0.5), ageS: 0.5), at: S.ms(t)))
            arrivals.append(t + 0.5 + 0.001)
        }
        let clean = S.cleanFix(accuracy: 5, positionNoise: 0)
        let events = drive.events(fix: { t, state, rng in t <= 5 ? clean(t, state, &rng) : nil }, extra: extra)
        let samples = S.run(events, config: S.config(particles: 400), sampleTimes: arrivals).samples
        var sum = 0.0
        for (t, sample) in zip(arrivals, samples).dropFirst(10) {
            let estimate = try #require(sample)
            sum -= drive.offset(estimate, at: t).dNorth
        }
        return sum / Double(arrivals.count - 10)
    }

    @Test("R11.2-2: a fix 0.07 s after a grid step is not pushed forward by 0.07 s × v: off-grid and on-grid fixes agree")
    func latencyShiftInterpolated() throws {
        let onGrid = try Self.alongTrackBias(offset: 0)
        let offGrid = try Self.alongTrackBias(offset: 0.07)
        // Before: the shift counted 0.07 s × 30 m/s = 2.1 m of motion from
        // before the fix, and the posterior followed most of it.
        #expect(abs(offGrid - onGrid) < 0.3, "along-track bias off-grid \(offGrid) m, on-grid \(onGrid) m")
    }

    // MARK: R11.2-3 (remainder) an initialising fix's age × speed

    /// Driving north at 20 m/s with OBD; the engine's first fix is stamped
    /// 10 s and arrives `age` s later (a relaunch mid-drive: the first fix
    /// delivered is a few seconds old).
    static func initialisingFix(age: Double, gnssSpeed: Double = 20, obd: Bool = true)
        -> (drive: S, engine: NavigationEngine) {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 20, [.straight(seconds: 20, speed: 20)])
        let truth = drive.truth(at: 10)
        let p = S.plane.geodetic(east: truth.east, north: truth.north)
        let fix = LocationSample(latitude: p.latitude, longitude: p.longitude, altitude: 0,
                                 horizontalAccuracy: 5, verticalAccuracy: -1, speed: gnssSpeed, speedAccuracy: 0.5,
                                 course: 0, courseAccuracy: 2, receivedT: S.ms(10 + age), ageS: age)
        let events = drive.events(obdSpeed: obd ? nil : { _, _ in nil }, extra: [.location(fix, at: S.ms(10))])
        var engine = NavigationEngine(config: S.config(particles: 400))
        for input in S.inputs(events) where input.arrival <= S.ms(10 + age + 0.001) { engine.ingest(input) }
        return (drive, engine)
    }

    @Test("R11.2-3: a 4 s old fix initialising at 20 m/s: the ellipse covers the 80 m the car moved since")
    func initialisingFixAgeCovered() throws {
        let (drive, engine) = Self.initialisingFix(age: 4)
        let t = 14.001
        let estimate = try #require(engine.estimate(at: S.ms(t)))
        let offset = drive.offset(estimate, at: t)
        #expect(drive.error(estimate, at: t) > 70, "the start is at the fix, 80 m behind")
        #expect(estimate.ellipse.contains(dEast: offset.dEast, dNorth: offset.dNorth),
                "truth \(drive.error(estimate, at: t)) m away, semi-major \(estimate.ellipse.semiMajorM) m")
        // σ² = 5² + (20.5 × 1.0 × 4)² with OBD 72 km/h + 0.5: about 82 m, not hundreds.
        #expect(estimate.ellipse.semiMajorM < 3 * 82, "semi-major \(estimate.ellipse.semiMajorM) m")
    }

    @Test("R11.2-3: with no OBD yet, the fix's own Doppler speed sizes the allowance")
    func initialisingFixAgeNoOBD() throws {
        let (drive, engine) = Self.initialisingFix(age: 4, obd: false)
        let t = 14.001
        let estimate = try #require(engine.estimate(at: S.ms(t)))
        let offset = drive.offset(estimate, at: t)
        #expect(estimate.ellipse.contains(dEast: offset.dEast, dNorth: offset.dNorth),
                "truth \(drive.error(estimate, at: t)) m away, semi-major \(estimate.ellipse.semiMajorM) m")
    }

    @Test("R11.2-3: a prompt initialising fix (0.05 s) keeps about its own σ")
    func promptInitialisingFixUnchanged() throws {
        let (_, engine) = Self.initialisingFix(age: 0.05)
        let estimate = try #require(engine.estimate(at: S.ms(10.051)))
        // σ² = 5² + (20.5 × 0.05)²: 5.1 m, semi-major ≈ 12.5 m.
        #expect(estimate.ellipse.semiMajorM < 13.5, "semi-major \(estimate.ellipse.semiMajorM) m")
    }

    // MARK: R14.4-1 a late initialising pin backfills the motion record

    /// Two pins 1.5 s apart (20 s and 21.5 s), at the truth, no GPS. Live,
    /// each is written when its 3 s undo window closes, so the first
    /// initialises the engine late, and the second is late too, with a
    /// tap before that initialisation.
    @Test("R14.4-1: a second late pin tapped before the late initialisation lands where it lands in arrival order",
          arguments: [8.0, 15.0, 25.0])
    func secondLatePinAfterLateInitialisation(speed: Double) throws {
        typealias L = NavigationLatePinTests
        let drive = S(initialHeadingDeg: 70, initialSpeed: speed, [.straight(seconds: 40, speed: speed)])
        let a = drive.truth(at: 20), b = drive.truth(at: 21.5)
        let inputs = S.inputs(drive.events(gyroNoise: 0.002, extra: [
            L.pin(at: 20, east: a.east, north: a.north), L.pin(at: 21.5, east: b.east, north: b.north),
        ]))
        let late = L.delayingPin(L.delayingPin(inputs, at: 20, by: 3), at: 21.5, by: 3)
        let config = S.config(particles: 2000, seed: 1)
        let inOrder = L.estimate(inputs, config: config, at: 26), delayed = L.estimate(late, config: config, at: 26)
        let x = try #require(inOrder.estimate), y = try #require(delayed.estimate)
        #expect(delayed.engine.counters.lateManualFixes == 2)
        #expect(delayed.engine.counters.lateManualFixesMeanShift == 0,
                "counted as a mean shift (\(delayed.engine.counters.lateManualFixesMeanShift)) at \(speed) m/s")
        let gap = L.distance(x, y)
        #expect(gap < 1.5, "\(gap) m from arrival order at \(speed) m/s")
        #expect(abs(y.ellipse.semiMajorM / x.ellipse.semiMajorM - 1) < 0.05,
                "semi-major late \(y.ellipse.semiMajorM) m vs in order \(x.ellipse.semiMajorM) m")
    }

    // MARK: N4MF-1 pin σ grows with speed at the tap

    static func pinSample(span: Double?, source: String, gateKmh: Double?, pressedT: Double = 100) -> ManualFixSample {
        ManualFixSample(latitude: 0, longitude: 0, pressedT: S.ms(pressedT), mapSpanM: span,
                        speedSource: source, gateSpeedKmh: gateKmh)
    }

    @Test("N4MF-1: σ_pin² = max(min, span/divisor)² + (v·(τ + max(0, t − pressedT)))²; unknown speed is 10 m/s")
    func pinSigmaGrowsWithSpeed() {
        let config = NavigationConfig()
        func sigma(_ sample: ManualFixSample, t: Double = 100) -> Double {
            config.manualFixSigma(sample, at: S.ms(t))
        }
        // Stationary: unchanged.
        #expect(sigma(Self.pinSample(span: 1_248, source: "obd", gateKmh: 0)) == 104)
        // 50 km/h by OBD, double tap (t = pressedT), τ 1 s: √(30² + 13.89²) = 33.06 m.
        let v50: Double = 50 / 3.6
        #expect(abs(sigma(Self.pinSample(span: 360, source: "obd", gateKmh: 50)) - (900 + v50 * v50).squareRoot()) < 1e-9)
        // GPS speed counts the same.
        #expect(sigma(Self.pinSample(span: 360, source: "gps", gateKmh: 36)) == (900 + 100.0).squareRoot())
        // Unknown speed: 10 m/s × 1 s.
        #expect(sigma(Self.pinSample(span: nil, source: "unknown", gateKmh: nil)) == (900 + 100.0).squareRoot())
        // A source with a missing speed is unknown too.
        #expect(sigma(Self.pinSample(span: nil, source: "obd", gateKmh: nil)) == (900 + 100.0).squareRoot())
        // Old long-press row: confirmed 6.69 s after the press at 8 km/h, span 1248 m.
        let longPress = sigma(Self.pinSample(span: 1_248, source: "obd", gateKmh: 8, pressedT: 100 - 6.69))
        let allowance: Double = 8 / 3.6 * 7.69
        let expected: Double = (104 * 104 + allowance * allowance).squareRoot()
        #expect(abs(longPress - expected) < 1e-9)
        #expect(abs(longPress - 105.4) < 0.05, "manual-3 pin 1: \(longPress) m")
        // τ 0 and a double tap: today's σ.
        var off = NavigationConfig()
        off.manualFixReactionS = 0
        #expect(off.manualFixSigma(Self.pinSample(span: 360, source: "obd", gateKmh: 50), at: S.ms(100)) == 30)
    }

    @Test("N4MF-1: a pin tapped at 50 km/h initialises the engine with the speed-grown σ; the replay's truth σ stays frozen")
    func pinSigmaInEngineNotInTruth() throws {
        let p = S.plane.geodetic(east: 0, north: 0)
        let sample = ManualFixSample(latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(1), mapSpanM: 360,
                                     speedSource: "obd", gateSpeedKmh: 50)
        var engine = NavigationEngine(config: S.config(particles: 50))
        engine.ingest(.manualFix(sample, at: S.ms(1)))
        let estimate = try #require(engine.estimate(at: S.ms(1)))
        let sigma = (900 + (50 / 3.6) * (50 / 3.6)).squareRoot()
        #expect(abs(estimate.ellipse.semiMajorM - sigma * ErrorEllipse.chiSquare95.squareRoot()) < 1e-6,
                "semi-major \(estimate.ellipse.semiMajorM) m")
        #expect(NavigationReplay.manualFixTruthSigmaM(mapSpanM: 360) == 30)
    }

    @Test("N4MF-1: the new config keys decode from a row that lacks them, with their defaults")
    func pinSigmaKeysDecodeTolerantly() throws {
        let data = NavigationConfig().canonicalJSON()
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object.removeValue(forKey: "manualFixReactionS") != nil)
        #expect(object.removeValue(forKey: "manualFixUnknownSpeedMps") != nil)
        let decoded = try JSONDecoder().decode(NavigationConfig.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == NavigationConfig())
        #expect(decoded.manualFixReactionS == 1 && decoded.manualFixUnknownSpeedMps == 10)
    }
}
