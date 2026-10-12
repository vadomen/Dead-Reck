import Foundation
import Testing

@testable import DriveLoggerCore

/// Tests only (N3.0): the halves of the catch-up claims that
/// `NavigationB0Tests` 6a/6b and `ringAcrossParkedFold` leave open
/// (R14.1-2, R14.4-2 macroStep half). The engine is unchanged.
@Suite("Navigation catch-up bookkeeping")
struct NavigationCatchUpTests {
    typealias S = SyntheticDrive

    // MARK: R14.1-2 6a: the parked fold's motion history

    /// Parked from 24 s (OBD 0 until 30 s, silent after). With `gap`, every
    /// input arriving between 30 s and 630 s is dropped, so the parked
    /// stretch is folded in one catch-up. A clean-looking fix stamped at
    /// 625 s (inside the gap) arrives at 631 s, 6 s late, with a 4 m/s
    /// Doppler speed and a course. It reads the motion history at 625 s:
    /// stepped, that entry is a parked stale step (no fresh speed, OBD 0
    /// held); without the fold's history it would be the last fresh step at
    /// 30 s. Since R11.1-4 the held 0 vetoes the course in both, so the
    /// entry itself is compared.
    static func parkedGapWithLateFix(_ gap: Bool) -> (engine: NavigationEngine, before: NavigationCounters) {
        let drive = S(initialHeadingDeg: 30, initialSpeed: 10, [
            .straight(seconds: 20, speed: 10), .ramp(seconds: 4, from: 10, to: 0), .stop(seconds: 610),
        ])
        let clean = S.cleanFix()
        let events = drive.events(obdSpeed: { t, state in t >= 30 ? nil : (state.speed * 3.6).rounded(.down) },
                                  fix: { t, state, rng in
                                      if t < 20 { return clean(t, state, &rng) }
                                      if S.at(t, 625) {
                                          return S.Fix(east: state.east + 3, north: state.north, accuracy: 5, speed: 4,
                                                       speedAccuracy: 0.5, course: 80, courseAccuracy: 5, latency: 6)
                                      }
                                      return nil
                                  })
        var engine = NavigationEngine(config: S.config(particles: 400))
        var before = NavigationCounters()
        for input in S.inputs(events) {
            if gap && input.arrival > S.ms(30.001) && input.arrival < S.ms(629.999) { continue }
            if case .location(_, let t) = input, t == S.ms(625) { before = engine.counters }
            engine.ingest(input)
        }
        return (engine, before)
    }

    @Test("R14.1-2 6a: a fix stamped inside a folded parked gap reads the same history as when the gap is stepped")
    func fixInsideFoldedGap() throws {
        let (gap, gapBefore) = Self.parkedGapWithLateFix(true)
        let (control, controlBefore) = Self.parkedGapWithLateFix(false)
        #expect(gap.counters.coalescedSteps > 5_000 && control.counters.coalescedSteps == 0)
        #expect(gap.counters.fixesUsed - gapBefore.fixesUsed == 1)
        #expect(control.counters.fixesUsed - controlBefore.fixesUsed == 1)
        // The fix reads the same history entry at 625 s in both: a parked
        // stale step (no fresh speed, held OBD 0). A fold without history
        // would return the last fresh step at 30 s (fresh OBD 0).
        let folded = try #require(gap.motionHistoryEntry(atOrBefore: S.ms(625).nanoseconds))
        let stepped = try #require(control.motionHistoryEntry(atOrBefore: S.ms(625).nanoseconds))
        #expect(folded.t == stepped.t && folded.t == S.ms(625).nanoseconds)
        #expect(folded.speed == nil && stepped.speed == nil && folded.held == 0 && stepped.held == 0)
        #expect(folded.east == stepped.east && folded.north == stepped.north && folded.yaw == stepped.yaw)
        // Parked with a stale OBD 0, its course is vetoed in both (R11.1-4).
        #expect(gap.counters.courseUpdates == gapBefore.courseUpdates)
        #expect(control.counters.courseUpdates == controlBefore.courseUpdates)
        let a = try #require(gap.estimate(at: S.ms(632))), b = try #require(control.estimate(at: S.ms(632)))
        #expect(a == b, "folded \(a), stepped \(b)")
    }

    // MARK: R14.1-2 6b: the macro step's exact OU integral over hours

    /// Driving north at 12 m/s with clean fixes until 15 s and fresh OBD
    /// until 20 s, then every input silent until `gapS`. Noise that would
    /// blur the along-track spread is off, so the north spread of the cloud
    /// is the unknown-speed error's integral.
    static func longMovingGap(gapS: Double) -> (engine: NavigationEngine, staleS: Double) {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 12, [.straight(seconds: 30, speed: 12)])
        let clean = S.cleanFix()
        let events = drive.events(obdSpeed: { t, state in t >= 20 ? nil : (state.speed * 3.6).rounded(.down) },
                                  fix: { t, state, rng in t < 15 ? clean(t, state, &rng) : nil })
            .filter { $0.timestamp.seconds <= 20.001 }
        var config = S.config(particles: 2_000)
        config.headingNoiseDegPerSqrtS = 0
        config.scaleNoisePerSqrtS = 0
        config.scalePriorStd = 0
        config.resampleScaleJitter = 0
        config.alongTrackNoisePerSqrtM = 0
        config.crossTrackNoisePerSqrtM = 0
        config.maxForwardJumpS = 1e6
        var engine = NavigationEngine(config: config)
        for input in S.inputs(events) { engine.ingest(input) }
        // The last OBD reply is at 19.95 s: fresh until 21.95 s, so the
        // first stale grid step is 22.0 s.
        engine.ingest(NavigationB0Tests.motion(gapS))
        return (engine, gapS - 21.9)
    }

    @Test("R14.1-2 6b: after a 2 h silence at unknown speed the along-track σ is the OU integral's, not end value × dt")
    func twoHourGapMatchesOUIntegral() throws {
        let (engine, staleS) = Self.longMovingGap(gapS: 7_200)
        let config = engine.config
        #expect(engine.counters.macroSteps == config.maxCatchUpSteps)
        #expect(engine.counters.coalescedSteps > 70_000)
        var mean = 0.0
        for i in engine.north.indices { mean += engine.weight[i] * engine.north[i] }
        var variance = 0.0
        for i in engine.north.indices {
            let d = engine.north[i] - mean
            variance += engine.weight[i] * (engine.covNN[i] + d * d)
        }
        let expected = NavigationEngine.ouIntegralVariance(dt: staleS, sigma: config.staleSpeedNoiseMpsPerSqrtS,
                                                           tau: config.staleSpeedDecayS)
        let ratio = (variance / expected).squareRoot()
        // 2000 particles: the σ estimate is good to about 1.6 %. End value ×
        // dt over 72 s macro steps would give about 1.34.
        #expect(abs(ratio - 1) < 0.08, "along-track σ \(variance.squareRoot()) m, OU integral \(expected.squareRoot()) m")
        #expect(expected.squareRoot() > 4_000)
    }

    // MARK: R14.4-2: the macro step records the per-particle ring

    @Test("R14.4-2: macro steps record the per-particle motion ring, as stepped steps do")
    func ringAcrossMacroSteps() throws {
        let gap = NavigationB0Tests.movingGap(true)
        let engine = gap.engine
        let macro = gap.catchUp.macroSteps - gap.beforeCatchUp.macroSteps
        #expect(macro == engine.config.maxCatchUpSteps)
        let ring = engine.motionRing.chronological()
        #expect(ring.count == engine.motionRing.capacity)
        // The ring's slots before the resume are macro-step ends, one macro
        // length (6 s here) apart, ending just before 620 s.
        let beforeResume = ring.filter { $0.t < S.ms(620).nanoseconds }
        #expect(beforeResume.count >= 20)
        let spacing = Set(zip(beforeResume, beforeResume.dropFirst()).map { $1.t - $0.t })
        #expect(spacing.count == 1)
        let macroNs = try #require(spacing.first)
        #expect(macroNs == 60 * 100_000_000, "macro step \(Double(macroNs) / 1e9) s")
        #expect(try #require(beforeResume.last).t > S.ms(614).nanoseconds)
        // Each particle moved north about 6 s × 12 m/s between two macro ends.
        let last = beforeResume[beforeResume.count - 1], previous = beforeResume[beforeResume.count - 2]
        var meanNorth = 0.0
        for i in last.north.indices { meanNorth += (last.north[i] - previous.north[i]) / Double(last.north.count) }
        #expect(abs(meanNorth - 6 * 12.08 * engine.config.scalePriorMean) < 15, "mean motion \(meanNorth) m")
    }
}
