import Foundation
import Testing

@testable import DriveLoggerCore

/// Review run 11, round 1: discriminating tests for the fix-latency shift
/// (R11.1-1), tower tempering (R11.1-2) and replay scoring before ingest
/// (R11.1-3). Each was checked to fail under the reviewer's mutation.
@Suite("Navigation review run 11")
struct NavigationReviewTests {
    typealias S = SyntheticDrive

    /// A clean fix generator whose fixes arrive `latency` seconds late,
    /// except the first (t = 0), which initialises promptly.
    static func lateFixes(_ latency: Double) -> (Double, S.State, inout NavigationRandom) -> S.Fix? {
        let clean = S.cleanFix(accuracy: 5, positionNoise: 0)
        return { t, state, rng in
            guard var fix = clean(t, state, &rng) else { return nil }
            if !S.at(t, 0) { fix.latency = latency }
            return fix
        }
    }

    // MARK: R11.1-1 fix latency

    @Test("R11.1-1: fixes arriving 2 s late at 15 m/s are shifted to the present; the posterior at arrival matches the truth")
    func lateFixesShiftedStraight() throws {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 15, [.straight(seconds: 60, speed: 15)])
        let events = drive.events(fix: Self.lateFixes(2))
        // Sample exactly at arrival: the estimate includes the fix that just arrived.
        let arrivals = stride(from: 12.0, through: 58, by: 2).map { $0 + 2 }
        let (engine, samples) = S.run(events, config: S.config(), sampleTimes: arrivals)
        #expect(engine.counters.fixesUsed > 50 && engine.counters.fixesIgnoredStale == 0)
        for (t, sample) in zip(arrivals, samples) {
            let estimate = try #require(sample)
            // Unshifted, a fix 2 s old is 30 m behind the car.
            #expect(drive.error(estimate, at: t) < 3, "t \(t): error \(drive.error(estimate, at: t)) m")
        }
    }

    @Test("R11.1-1: turning during the 2 s latency window: course is shifted by the yaw since the fix; heading and position stay right")
    func lateFixesShiftedThroughTurn() throws {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 12, [
            .straight(seconds: 20, speed: 12), .turn(degrees: 90, seconds: 6, speed: 12),
            .straight(seconds: 10, speed: 12), .turn(degrees: -120, seconds: 8, speed: 12),
            .straight(seconds: 10, speed: 12),
        ])
        let events = drive.events(fix: Self.lateFixes(2))
        let arrivals = stride(from: 21.0, through: 53, by: 1).map { $0 }
        let (_, samples) = S.run(events, config: S.config(), sampleTimes: arrivals)
        for (t, sample) in zip(arrivals, samples) {
            let estimate = try #require(sample)
            let truthHeading = drive.truth(at: t).heading * 180 / .pi
            #expect(abs(angleDifference(estimate.headingDeg, truthHeading)) < 2,
                    "t \(t): heading \(estimate.headingDeg) vs \(truthHeading)")
            #expect(drive.error(estimate, at: t) < 6, "t \(t): error \(drive.error(estimate, at: t)) m")
        }
    }

    // MARK: R11.1-2 tower tempering

    @Test("R11.1-2: temper = min(1, Δt / correlation), 1 for the first tower fix, 0 for one not after the last")
    func towerTemperValues() {
        #expect(NavigationEngine.networkTemper(sinceLastS: 0, correlationS: 60) == 0)
        #expect(NavigationEngine.networkTemper(sinceLastS: 30, correlationS: 60) == 0.5)
        #expect(NavigationEngine.networkTemper(sinceLastS: 120, correlationS: 60) == 1)
        #expect(NavigationEngine.networkTemper(sinceLastS: -5, correlationS: 60) == 0)
        #expect(NavigationEngine.networkTemper(sinceLastS: nil, correlationS: 60) == 1)
    }

    @Test("R11.1-2: 1 Hz tower fixes with one correlated 600 m bias for 5 minutes pull a loose position by tempered evidence only")
    func towerBiasTempered() throws {
        // Parked 300 s (ZUPT: only the fixes move the estimate). Initialised
        // by an unbiased 300 m fix (σ ≈ 200 m); then 1 Hz tower fixes, all
        // 600 m east. Tempered (60 s): ~5 fixes' worth of evidence, ~110 m
        // pull. Untempered: 300 independent fixes, ~560 m.
        let drive = S(initialHeadingDeg: 0, [.stop(seconds: 300)])
        let events = drive.events(fix: { t, state, rng in
            S.at(t, 0)
                ? S.Fix(east: state.east, north: state.north, accuracy: 300)
                : S.Fix(east: state.east + 600 + 30 * rng.nextGaussian(), north: state.north + 30 * rng.nextGaussian(),
                        accuracy: 1414)
        })
        let (engine, samples) = S.run(events, config: S.config(particles: 200), sampleTimes: [299])
        let estimate = try #require(samples.first ?? nil)
        #expect(engine.counters.networkFixesUsed >= 290)
        let error = drive.error(estimate, at: 299)
        #expect(error > 50, "the bias should pull somewhat (\(error) m)")
        #expect(error < 200, "pulled \(error) m: tower fixes counted as independent")
        let offset = drive.offset(estimate, at: 299)
        #expect(estimate.ellipse.contains(dEast: offset.dEast, dNorth: offset.dNorth))
    }

    // MARK: R11.1-3 replay scores before ingest

    /// Rebuilds the engine from only the inputs the replay had given it
    /// before `t`: arrival < t (≤ t for the end checkpoint, scored after the
    /// last input), withheld exactly as the replay withholds.
    static func rebuiltEstimate(
        _ inputs: [NavigationInput], options: ReplayOptions, motionStart: MonotonicTimestamp?,
        at t: MonotonicTimestamp, inclusive: Bool
    ) -> NavigationEstimate? {
        var engine = NavigationEngine(config: options.config)
        for input in inputs where inclusive ? input.arrival <= t : input.arrival < t {
            if case .location(let sample, let fixT) = input,
               NavigationReplay.withholdReason(sample, at: fixT, options: options, motionStart: motionStart) != nil {
                continue
            }
            engine.ingest(input)
        }
        return engine.estimate(at: t)
    }

    @Test("R11.1-3: every checkpoint equals an engine rebuilt from only the inputs that arrived before it")
    func checkpointsScoredBeforeIngest() throws {
        let (_, events, truth) = NavigationReplayTests.scenario()
        let inputs = NavigationReplay.inputs(from: events)
        let options = ReplayOptions(gps: .maskAfter(seconds: 20), config: S.config(particles: 150))
        let result = NavigationReplay.run(logName: "synthetic.jsonl.gz", inputs: inputs, options: options, truth: truth)
        let motionStart = NavigationReplay.motionStart(inputs)
        let clean = result.checkpoints.filter { $0.kind == .cleanFix }
        let others = result.checkpoints.filter { $0.kind != .cleanFix }
        #expect(clean.count > 30 && Set(others.map(\.kind)) == [.manualFix, .truthPoint, .truthEnd])
        let checked = clean.enumerated().filter { $0.offset % 4 == 0 }.map(\.element) + others
        for checkpoint in checked {
            let t = MonotonicTimestamp(seconds: checkpoint.t)
            let rebuilt = try #require(Self.rebuiltEstimate(
                inputs, options: options, motionStart: motionStart, at: t, inclusive: checkpoint.kind == .truthEnd
            ))
            #expect(checkpoint.estimateLatitude == rebuilt.latitude && checkpoint.estimateLongitude == rebuilt.longitude,
                    "\(checkpoint.kind) at \(checkpoint.t)")
            #expect(checkpoint.headingStdDeg == rebuilt.headingStdDeg, "\(checkpoint.kind) at \(checkpoint.t)")
        }
    }

    @Test("R11.1-3: a manual fix pinned 300 m off the track is scored on the prior: its error is the prior's, not ~0")
    func manualFixScoredOnPrior() throws {
        let drive = S(initialHeadingDeg: 45, initialSpeed: 12, [
            .straight(seconds: 40, speed: 12), .ramp(seconds: 4, from: 12, to: 0), .stop(seconds: 10),
            .ramp(seconds: 4, from: 0, to: 12), .straight(seconds: 20, speed: 12),
        ])
        // Between two 10 ms motion samples, so the pin is the first input
        // arriving at or after its own time: scoring after ingest would
        // see it.
        let pinT = 48.005
        let atPin = drive.truth(at: pinT)
        let p = S.plane.geodetic(east: atPin.east + 300, north: atPin.north)
        let pin = LogEvent(timestamp: S.ms(pinT), payload: .manualFix(ManualFixSample(
            latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(pinT - 2), speedSource: "obd")))
        let events = drive.events(fix: { t, state, rng in t < 40 ? S.cleanFix()(t, state, &rng) : nil }, extra: [pin])
        let inputs = NavigationReplay.inputs(from: events)
        let options = ReplayOptions(gps: .use, config: S.config(particles: 200))
        let result = NavigationReplay.run(logName: "synthetic.jsonl.gz", inputs: inputs, options: options)
        let checkpoint = try #require(result.checkpoints.first { $0.kind == .manualFix })
        let prior = try #require(Self.rebuiltEstimate(inputs, options: options, motionStart: nil,
                                                      at: S.ms(pinT), inclusive: false))
        let pinENU = S.plane.enu(latitude: p.latitude, longitude: p.longitude)
        let priorENU = S.plane.enu(latitude: prior.latitude, longitude: prior.longitude)
        let priorError = ((pinENU.east - priorENU.east) * (pinENU.east - priorENU.east)
            + (pinENU.north - priorENU.north) * (pinENU.north - priorENU.north)).squareRoot()
        let error = try #require(checkpoint.errorM)
        #expect(abs(error - priorError) < 1e-3, "checkpoint \(error) m vs prior \(priorError) m")
        #expect(error > 250, "a pin 300 m off must show ~300 m on the prior, got \(error) m")
        // After ingesting it, the engine is at the pin (no-support reset).
        #expect(result.counters.manualResets == 1)
    }

    // MARK: R11.2-1 stale speed offsets reset on ZUPT

    @Test("R11.2-1: dropout, fresh OBD 0, dropout again: the second dropout's speed errors start from 0")
    func staleOffsetsResetOnZUPT() throws {
        // Parked for 40 s. Flaky link: OBD 0, dropout 5–20 s, fresh 0 again
        // 20–30 s, dropout from 30 s. Reference: OBD 0 until 30 s, then the
        // same dropout, without the first one.
        let drive = S(initialHeadingDeg: 0, [.stop(seconds: 40)])
        let firstFix: (Double, S.State, inout NavigationRandom) -> S.Fix? = { t, state, _ in
            S.at(t, 0) ? S.Fix(east: state.east, north: state.north, accuracy: 5, speed: 0, speedAccuracy: 0.3) : nil
        }
        let flaky = drive.events(obdSpeed: { t, _ in (5..<20).contains(t) || t >= 30 ? nil : 0 }, fix: firstFix)
        let steady = drive.events(obdSpeed: { t, _ in t >= 30 ? nil : 0 }, fix: firstFix)
        var config = S.config(particles: 2000, seed: 21)
        // Since R13.1-2 a stale period after an OBD 0 is parked until the IMU
        // shows motion; disable that latch so the dropouts random-walk, which
        // is what this regression is about.
        config.staleParkedMotionG = -1

        // During the second fresh zero the offsets of the first dropout are gone.
        var engine = NavigationEngine(config: config)
        for input in S.inputs(flaky) where input.arrival <= S.ms(29) { engine.ingest(input) }
        #expect(engine.counters.staleSpeedSteps > 100)
        #expect(try #require(engine.estimate(at: S.ms(29))).stationary)
        let rms = (engine.speedOffset.reduce(0) { $0 + $1 * $1 } / Double(engine.speedOffset.count)).squareRoot()
        #expect(rms == 0, "speed offsets carried through the ZUPT: RMS \(rms) m/s")

        // The second dropout grows the cloud as much as a first dropout would.
        func growth(_ events: [LogEvent]) throws -> Double {
            let samples = S.run(events, config: config, sampleTimes: [30, 40]).samples
            let before = try #require(samples[0]), after = try #require(samples[1])
            return after.ellipse.semiMajorM * after.ellipse.semiMajorM - before.ellipse.semiMajorM * before.ellipse.semiMajorM
        }
        let flakyGrowth = try growth(flaky), steadyGrowth = try growth(steady)
        #expect(steadyGrowth > 0)
        let ratio = flakyGrowth / steadyGrowth
        #expect(ratio > 0.7 && ratio < 1.4, "variance growth \(flakyGrowth) vs \(steadyGrowth) m² (ratio \(ratio))")
    }
}
