import Foundation
import Testing

@testable import DriveLoggerCore

/// N4 step B0: engine fixes deferred from review run 13 (R13.1-5, R13.1-6,
/// R13.2-2, R13.2-3), each with a regression test that fails on the code
/// before the fix.
@Suite("Navigation N4 B0")
struct NavigationB0Tests {
    typealias S = SyntheticDrive

    static func motion(_ t: Double, accelY: Double = 0) -> NavigationInput {
        .motion(MotionSample(userAcceleration: Vector3(x: 0, y: accelY, z: 0), gravity: Vector3(x: 0, y: 0, z: -1),
                             rotationRate: .zero, attitude: .identity), at: S.ms(t))
    }

    static func distance(_ a: NavigationEstimate, _ b: NavigationEstimate) -> Double {
        let de = b.east - a.east, dn = b.north - a.north
        return (de * de + dn * dn).squareRoot()
    }

    // MARK: R13.2-2

    /// 20 s at 10 m/s with clean fixes, then a 0.25 g ramp to a stop at
    /// 24 s; OBD falls silent from `silentFrom` (so the last reply, an OBD
    /// 0, comes while the braking deceleration is still in the 1 s EMA) and
    /// the car stays parked for 5 min.
    @Test("R13.2-2: OBD silent within ~1 s of a 0.25 g stop: still parked, the ellipse stays ~10 m after 5 min",
          arguments: [24.3, 24.6, 25.0])
    func hardStopSilenceStaysParked(silentFrom: Double) throws {
        let drive = S(initialHeadingDeg: 30, initialSpeed: 10, [
            .straight(seconds: 20, speed: 10), .ramp(seconds: 4, from: 10, to: 0), .stop(seconds: 302),
        ])
        let clean = S.cleanFix()
        let events = drive.events(gyroNoise: 0.02, accelNoise: 0.03,
                                  obdSpeed: { t, state in t >= silentFrom ? nil : (state.speed * 3.6).rounded(.down) },
                                  fix: { t, state, rng in t < 20 ? clean(t, state, &rng) : nil })
        let end = silentFrom + 300
        let (engine, samples) = S.run(events, config: S.config(particles: 400), sampleTimes: [silentFrom, end])
        let atStop = try #require(samples[0]), last = try #require(samples[1])
        #expect(last.ellipse.semiMajorM < 20,
                "semi-major \(atStop.ellipse.semiMajorM) → \(last.ellipse.semiMajorM) m after 5 min of silence")
        #expect(last.stationary)
        #expect(Self.distance(atStop, last) < 1)
        #expect(engine.counters.staleSpeedSteps == 0, "\(engine.counters.staleSpeedSteps) unknown-speed steps")
    }

    // MARK: R13.2-3

    @Test("R13.2-3: parked, one out-of-order motion sample then a 0.4 g jolt: the parked latch holds")
    func lateMotionSampleThenJoltStaysParked() throws {
        let drive = S(initialHeadingDeg: 30, initialSpeed: 10, [
            .straight(seconds: 20, speed: 10), .ramp(seconds: 4, from: 10, to: 0), .stop(seconds: 330),
        ])
        let clean = S.cleanFix()
        let events = drive.events(obdSpeed: { t, state in t >= 30 ? nil : (state.speed * 3.6).rounded(.down) },
                                  fix: { t, state, rng in t < 20 ? clean(t, state, &rng) : nil })
        var inputs: [NavigationInput] = []
        for input in S.inputs(events) {
            guard case .motion(var sample, let t) = input else { inputs.append(input); continue }
            if abs(t.seconds - 60.01) < 0.002 {
                // A one-sample jolt (a door, a hand on the mount): 0.4 g.
                sample.userAcceleration = Vector3(x: 0, y: 0.4, z: 0)
                inputs.append(.motion(sample, at: t))
                continue
            }
            inputs.append(input)
            if abs(t.seconds - 60.0) < 0.002 {
                // Delivered after the 60.00 s sample but stamped 0.4 s earlier.
                inputs.append(Self.motion(59.6))
            }
        }
        var engine = NavigationEngine(config: S.config(particles: 400))
        var atStop: NavigationEstimate?
        for input in inputs {
            if atStop == nil && input.arrival > S.ms(40) { atStop = engine.estimate(at: S.ms(40)) }
            engine.ingest(input)
        }
        let before = try #require(atStop), end = try #require(engine.estimate(at: S.ms(350)))
        #expect(engine.counters.staleSpeedSteps == 0, "\(engine.counters.staleSpeedSteps) unknown-speed steps after the jolt")
        #expect(end.stationary)
        #expect(end.ellipse.semiMajorM - before.ellipse.semiMajorM < 1,
                "semi-major \(before.ellipse.semiMajorM) → \(end.ellipse.semiMajorM) m")
    }

    // MARK: R13.1-6

    /// Parked after a stop (OBD 0 until 30 s, silent after). With `gap`,
    /// every input stops between 30 s and 630 s; without, motion samples
    /// continue, so the parked steps run one by one. A network fix arrives
    /// at 631 s (it reads the motion history across the gap).
    static func parkedGap(_ gap: Bool) -> (engine: NavigationEngine, catchUp: NavigationCounters, beforeCatchUp: NavigationCounters,
                                          after: NavigationEstimate?) {
        let drive = S(initialHeadingDeg: 30, initialSpeed: 10, [
            .straight(seconds: 20, speed: 10), .ramp(seconds: 4, from: 10, to: 0), .stop(seconds: 610),
        ])
        let clean = S.cleanFix()
        let events = drive.events(obdSpeed: { t, state in t >= 30 ? nil : (state.speed * 3.6).rounded(.down) },
                                  fix: { t, state, rng in
                                      if t < 20 { return clean(t, state, &rng) }
                                      if S.at(t, 631) { return S.Fix(east: state.east + 40, north: state.north, accuracy: 100) }
                                      return nil
                                  })
            .filter { !gap || !($0.timestamp.seconds > 30.001 && $0.timestamp.seconds < 629.999) }
        var engine = NavigationEngine(config: S.config(particles: 400))
        var before = NavigationCounters(), during = NavigationCounters()
        for input in S.inputs(events) {
            let isCatchUp = input.arrival == S.ms(630)
            if isCatchUp { before = engine.counters }
            engine.ingest(input)
            if isCatchUp { during = engine.counters }
        }
        return (engine, during, before, engine.estimate(at: S.ms(634)))
    }

    @Test("R13.1-6a: a 600 s silence of every input while parked is folded in bounded work, bit-identical to stepping it")
    func parkedGapIsCheapAndIdentical() throws {
        let gap = Self.parkedGap(true), control = Self.parkedGap(false)
        let steps = gap.catchUp.steps - gap.beforeCatchUp.steps
        let oneByOne = steps - (gap.catchUp.coalescedSteps - gap.beforeCatchUp.coalescedSteps)
        #expect(steps > 5_900, "the catch-up covered \(steps) grid steps")
        // At most the steps while the last OBD 0 is still fresh (2 s).
        #expect(oneByOne <= 21, "\(oneByOne) of \(steps) grid steps run one by one")
        #expect(gap.catchUp.macroSteps == gap.beforeCatchUp.macroSteps)
        let a = try #require(gap.after), b = try #require(control.after)
        #expect(a == b, "with the gap \(a), stepped \(b)")
        #expect(a.stationary)
        #expect(gap.engine.counters.steps == control.engine.counters.steps)
        #expect(gap.engine.counters.staleParkedSteps == control.engine.counters.staleParkedSteps)
        #expect(gap.engine.counters.networkFixesUsed == 1 && control.engine.counters.networkFixesUsed == 1)
        #expect(control.engine.counters.coalescedSteps == 0)
    }

    /// Driving at 12 m/s with clean fixes until 15 s and fresh OBD until
    /// 20 s. With `gap`, every input stops between 20 s and 620 s;
    /// without, motion samples continue while OBD is silent, so the
    /// unknown-speed steps run one by one.
    static func movingGap(_ gap: Bool) -> (engine: NavigationEngine, catchUp: NavigationCounters, beforeCatchUp: NavigationCounters,
                                          start: NavigationEstimate?, end: NavigationEstimate?) {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 12, [.straight(seconds: 622, speed: 12)])
        let clean = S.cleanFix()
        let events = drive.events(obdSpeed: { t, state in t >= 20 ? nil : (state.speed * 3.6).rounded(.down) },
                                  fix: { t, state, rng in t < 15 ? clean(t, state, &rng) : nil })
            .filter { !gap || !($0.timestamp.seconds > 20.001 && $0.timestamp.seconds < 619.999) }
        var engine = NavigationEngine(config: S.config(particles: 400))
        var before = NavigationCounters(), during = NavigationCounters()
        var start: NavigationEstimate?
        for input in S.inputs(events) {
            let isCatchUp = input.arrival == S.ms(620)
            if isCatchUp { before = engine.counters }
            if start == nil && input.arrival > S.ms(20) { start = engine.estimate(at: S.ms(20)) }
            engine.ingest(input)
            if isCatchUp { during = engine.counters }
        }
        return (engine, during, before, start, engine.estimate(at: S.ms(620.005)))
    }

    @Test("R13.1-6b: a 600 s silence of every input at unknown speed costs a bounded number of passes and matches stepping it")
    func movingGapIsBoundedAndConsistent() throws {
        let gap = Self.movingGap(true), control = Self.movingGap(false)
        let config = S.config(particles: 400)
        let steps = gap.catchUp.steps - gap.beforeCatchUp.steps
        let oneByOne = steps - (gap.catchUp.coalescedSteps - gap.beforeCatchUp.coalescedSteps)
        let macro = gap.catchUp.macroSteps - gap.beforeCatchUp.macroSteps
        #expect(steps > 5_900, "the catch-up covered \(steps) grid steps")
        #expect(oneByOne <= 21, "\(oneByOne) grid steps run one by one")
        #expect(macro >= 1 && macro <= config.maxCatchUpSteps, "\(macro) macro steps")
        #expect(gap.engine.counters.staleSpeedSteps == control.engine.counters.staleSpeedSteps)
        // Same model, other discretisation and draws: statistically equal.
        let a = try #require(gap.end), b = try #require(control.end)
        let ratio = a.ellipse.semiMajorM / b.ellipse.semiMajorM
        #expect(ratio > 0.85 && ratio < 1.15,
                "semi-major \(a.ellipse.semiMajorM) m caught up, \(b.ellipse.semiMajorM) m stepped")
        #expect(b.ellipse.semiMajorM > 1_500, "stepped semi-major \(b.ellipse.semiMajorM) m")
        #expect(Self.distance(a, b) < 0.2 * b.ellipse.semiMajorM, "means \(Self.distance(a, b)) m apart")
        let start = try #require(gap.start)
        let travelled = Self.distance(start, a)
        #expect(abs(travelled - 600 * 12.08 * config.scalePriorMean) < 0.1 * b.ellipse.semiMajorM,
                "travelled \(travelled) m")
        #expect(!a.stationary && a.speedMps > 0)
    }

    @Test("R13.1-6c: a corrupt huge t returns quickly, parked, moving and before initialisation")
    func hugeTimestampReturnsQuickly() throws {
        let huge = 1e9  // about 32 years: 10¹⁰ grid steps
        let clock = ContinuousClock()

        var parked = Self.parkedGap(false).engine
        let parkedBefore = try #require(parked.estimate(at: S.ms(634)))
        let parkedTime = clock.measure { parked.ingest(Self.motion(huge)) }
        let parkedAfter = try #require(parked.estimate(at: S.ms(huge)))
        #expect(parkedTime < .seconds(1), "parked: \(parkedTime)")
        #expect(parked.counters.steps > 9_000_000_000)
        #expect(parkedAfter.stationary && parkedAfter.east == parkedBefore.east && parkedAfter.north == parkedBefore.north)

        var moving = Self.movingGap(false).engine
        let movingTime = clock.measure { moving.ingest(Self.motion(huge)) }
        let movingAfter = try #require(moving.estimate(at: S.ms(huge)))
        #expect(movingTime < .seconds(1), "moving: \(movingTime)")
        #expect(moving.counters.macroSteps <= moving.config.maxCatchUpSteps)
        #expect(movingAfter.latitude.isFinite && movingAfter.longitude.isFinite && movingAfter.ellipse.semiMajorM.isFinite)

        var fresh = NavigationEngine(config: S.config(particles: 400))
        fresh.ingest(Self.motion(0))
        let freshTime = clock.measure { fresh.ingest(Self.motion(huge)) }
        #expect(freshTime < .seconds(1), "uninitialised: \(freshTime)")
        #expect(!fresh.isInitialized && fresh.counters.steps == 0)
    }

    @Test("R13.1-6d: the exact OU transition matches its small- and large-dt limits")
    func ouTransitionLimits() {
        let sigma = 2.5, tau = 20.0
        // dt ≪ τ: the random walk, Var ∫ = σ² dt³ / 3.
        let small = NavigationEngine.ouIntegralVariance(dt: 0.2, sigma: sigma, tau: tau)
        #expect(abs(small / (sigma * sigma * 0.008 / 3) - 1) < 0.02, "\(small)")
        // dt ≫ τ: Var ∫ → σ² τ² (dt − 1.5 τ).
        let large = NavigationEngine.ouIntegralVariance(dt: 10_000, sigma: sigma, tau: tau)
        #expect(abs(large / (sigma * sigma * tau * tau * (10_000 - 1.5 * tau)) - 1) < 1e-6, "\(large)")
        // The end value's spread is the one `step` uses.
        let ou = NavigationEngine.ouTransition(dt: 0.1, sigma: sigma, tau: tau)
        let a = exp(-0.1 / tau)
        #expect(abs(ou.sigmaEnd - sigma * (tau / 2 * (1 - a * a)).squareRoot()) < 1e-12)
        #expect(abs(ou.decay - a) < 1e-15)
    }

    @Test("R13.1-6e: ordinary input is never caught up in bulk")
    func ordinaryInputIsNotCoalesced() {
        let engine = S.run(NavigationCausalityTests.events(), config: S.config(particles: 200)).engine
        #expect(engine.counters.steps > 400)
        #expect(engine.counters.coalescedSteps == 0 && engine.counters.macroSteps == 0)
    }

    // MARK: R13.1-5

    @Test("R13.1-5: 60 s past the last step the estimate holds at the horizon: no jump, no spin, a grown ellipse")
    func extrapolationIsCapped() throws {
        let horizon = NavigationConfig().extrapolationHorizonS
        func engine(_ drive: S, until t: Double) -> NavigationEngine {
            var engine = NavigationEngine(config: S.config(particles: 400))
            let events = drive.events(fix: { t, state, rng in t < 8 ? S.cleanFix()(t, state, &rng) : nil })
            for input in S.inputs(events) where input.arrival <= S.ms(t) { engine.ingest(input) }
            return engine
        }
        // Straight at 20 m/s: before the cap, 60 s later it was 1.2 km on.
        let straight = engine(S(initialHeadingDeg: 45, initialSpeed: 20, [.straight(seconds: 20, speed: 20)]), until: 10)
        let last = try #require(straight.estimate(at: S.ms(10)))
        let atHorizon = try #require(straight.estimate(at: S.ms(10 + horizon)))
        let later = try [10.5, 12.5, 20, 40, 70].map { try #require(straight.estimate(at: S.ms($0))) }
        let far = try #require(later.last)
        #expect(Self.distance(last, far) < last.speedMps * horizon + 1, "moved \(Self.distance(last, far)) m in 60 s")
        #expect(far.east == atHorizon.east && far.north == atHorizon.north)
        for (a, b) in zip([last] + later, later) {
            #expect(b.ellipse.semiMajorM >= a.ellipse.semiMajorM && b.ellipse.semiMinorM >= a.ellipse.semiMinorM,
                    "\(a.t.seconds) s: \(a.ellipse), \(b.t.seconds) s: \(b.ellipse)")
        }
        // The grown ellipse covers a car that kept its last speed.
        let h = far.headingDeg * .pi / 180, keptOn = last.speedMps * 60
        #expect(far.ellipse.contains(dEast: last.east + keptOn * sin(h) - far.east, dNorth: last.north + keptOn * cos(h) - far.north),
                "\(far.ellipse)")
        // estimate(at:) does not mutate: asking again gives the same answer.
        #expect(straight.estimate(at: S.ms(10)) == last)

        // Mid-turn at 3°/s: before the cap, 60 s later the heading had spun 180°.
        let turning = engine(S(initialHeadingDeg: 0, initialSpeed: 15, [.straight(seconds: 10, speed: 15),
                                                                         .turn(degrees: 90, seconds: 30, speed: 15)]), until: 20)
        let turnLast = try #require(turning.estimate(at: S.ms(20)))
        let turnFar = try #require(turning.estimate(at: S.ms(80)))
        let spun = abs(angleDifference(turnFar.headingDeg, turnLast.headingDeg))
        #expect(spun < 3 * horizon + 0.5, "heading turned \(spun)° in 60 s")
        #expect(Self.distance(turnLast, turnFar) < turnLast.speedMps * horizon + 1)
    }
}
