import Foundation
import Testing

@testable import DriveLoggerCore

/// Review run 20, round 1: regression and discriminating tests (R20.1-1,
/// R20.1-2). Each was run against the code it guards with the fault
/// reintroduced and failed there.
@Suite("Navigation review run 20")
struct NavigationRun20Tests {
    typealias S = SyntheticDrive

    // MARK: R20.1-1 resampling keeps the speed errors the fixes favoured

    /// 15 m/s north with fresh OBD until 30 s; then OBD silent (not parked)
    /// while the car accelerates to 25 m/s over 60 s and holds it. Clean 5 m
    /// fixes every second until 89 s, none after. The fixes during the
    /// stale stretch are what tells the cloud its speed is 15 + offset: a
    /// resample must keep the offsets they favoured. Returns (error m,
    /// mean speed m/s) at 89.9, 95 and 100 s, N = 1000.
    static func learnedStaleSpeed(seed: UInt64) throws -> [(error: Double, speed: Double)] {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 15, [
            .straight(seconds: 30, speed: 15), .ramp(seconds: 60, from: 15, to: 25), .straight(seconds: 15, speed: 25),
        ])
        let clean = S.cleanFix(accuracy: 5, positionNoise: 0)
        let events = drive.events(obdSpeed: { t, state in t < 30 ? (state.speed * 3.6).rounded(.down) : nil },
                                  fix: { t, state, rng in t < 90 ? clean(t, state, &rng) : nil })
        let times = [89.9, 95, 100]
        let (engine, samples) = S.run(events, config: S.config(particles: 1000, seed: seed), sampleTimes: times)
        #expect(engine.counters.staleSpeedSteps > 700 && engine.counters.macroSteps == 0)
        return try zip(times, samples).map { t, sample in
            let estimate = try #require(sample)
            return (drive.error(estimate, at: t), estimate.speedMps)
        }
    }

    @Test("R20.1-1: fixes during a stale-speed stretch teach the cloud its speed; resampling keeps it (no re-pairing)")
    func resampleKeepsLearnedSpeedOffsets() throws {
        var error = [0.0, 0.0, 0.0], speed = [0.0, 0.0, 0.0]
        for seed in UInt64(1)...3 {
            for (k, r) in try Self.learnedStaleSpeed(seed: seed).enumerated() {
                error[k] += r.error / 3
                speed[k] += r.speed / 3
            }
        }
        // Before R11.1-7 (independent offsets, 4dd5a10), seeds 1–40: error
        // 2.14 / 15.66 / 36.71 m (max 2.62 / 18.06 / 41.78), speed 23.31 /
        // 21.52 / 20.13 m/s at 89.9 / 95 / 100 s. With re-pairing after
        // every resample (R11.1-7 as first written), seeds 1–3: 10.0 / 59.9
        // / 108.7 m at 15.2 m/s, the stale OBD speed: nothing learned.
        // Tolerance: 4dd5a10's mean + ~25 % in position, −1 m/s in speed.
        #expect(error[0] < 3, "error \(error[0]) m at 89.9 s")
        #expect(error[1] < 20, "error \(error[1]) m at 95 s")
        #expect(error[2] < 45, "error \(error[2]) m at 100 s")
        #expect(speed[0] > 22.3, "speed \(speed[0]) m/s at 89.9 s")
        #expect(speed[1] > 20.5, "speed \(speed[1]) m/s at 95 s")
        #expect(speed[2] > 19.1, "speed \(speed[2]) m/s at 100 s")
    }

    // MARK: R20.2-1 a macro step keeps each particle's learned offset

    /// `learnedStaleSpeed`'s drive held at 25 m/s until 200 s; every input
    /// is lost after 90 s (fixes end at 89 s) and the 110 s gap is caught
    /// up in macro steps by one motion sample at 200 s. Returns the error
    /// (m) at 200 s, N = 1000.
    static func learnedStaleSpeedThroughMacro(seed: UInt64) throws -> Double {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 15, [
            .straight(seconds: 30, speed: 15), .ramp(seconds: 60, from: 15, to: 25), .straight(seconds: 110, speed: 25),
        ])
        let clean = S.cleanFix(accuracy: 5, positionNoise: 0)
        let events = drive.events(obdSpeed: { t, state in t < 30 ? (state.speed * 3.6).rounded(.down) : nil },
                                  fix: { t, state, rng in t < 90 ? clean(t, state, &rng) : nil })
            .filter { $0.timestamp.seconds <= 90.001 }
        var engine = NavigationEngine(config: S.config(particles: 1000, seed: seed))
        for input in S.inputs(events) { engine.ingest(input) }
        let macroBefore = engine.counters.macroSteps
        engine.ingest(NavigationB0Tests.motion(200))
        #expect(macroBefore == 0 && engine.counters.macroSteps > 0, "macro steps \(engine.counters.macroSteps)")
        return drive.error(try #require(engine.estimate(at: S.ms(200))), at: 200)
    }

    @Test("R20.2-1: a gap caught up in macro steps keeps the stale speed offsets the fixes taught (no re-pairing in macroStep)")
    func macroStepKeepsLearnedSpeedOffsets() throws {
        var error = 0.0
        for seed in UInt64(1)...3 {
            error += try Self.learnedStaleSpeedThroughMacro(seed: seed) / 3
        }
        // Review run 20, round 2: 923–937 m at HEAD; with the offsets
        // re-paired (odd = −even) at the start of `macroStep`,
        // 1064–1084 m (the cloud falls back towards the stale 15 m/s).
        #expect(error < 1000, "error \(error) m at 200 s")
    }

    // MARK: R20.1-2 M2: macro steps count as moving for R11.1-5

    /// 12 m/s north with clean fixes until 15 s and fresh OBD until 20 s;
    /// then every input is lost until 120 s while the car drives on, brakes
    /// over 4 s from 110 s and stops. Inputs resume at 120 s (OBD 0): the
    /// 100 s gap is caught up in macro steps, the last ending at 120 s. A
    /// fix stamped at 112 s (truth, moving) arrives at 125 s, stopped.
    static func macroMotionThenStaleFix() throws -> (engine: NavigationEngine, before: NavigationEstimate,
                                                      after: NavigationEstimate, macroBefore: Int) {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 12, [
            .straight(seconds: 110, speed: 12), .ramp(seconds: 4, from: 12, to: 0), .stop(seconds: 16),
        ])
        let clean = S.cleanFix(accuracy: 5, positionNoise: 0)
        var events = drive.events(obdSpeed: { t, state in t < 20 ? (state.speed * 3.6).rounded(.down) : 0 },
                                  fix: { t, state, rng in t < 15 ? clean(t, state, &rng) : nil })
            .filter { !($0.timestamp.seconds > 20.001 && $0.timestamp.seconds < 119.999) }
        let truth = drive.truth(at: 112)
        let p = S.plane.geodetic(east: truth.east, north: truth.north)
        events.append(.location(LocationSample(latitude: p.latitude, longitude: p.longitude, altitude: 0,
                                               horizontalAccuracy: 5, verticalAccuracy: -1, speed: truth.speed,
                                               speedAccuracy: 0.5, course: -1, courseAccuracy: -1,
                                               receivedT: S.ms(125), ageS: 13), at: S.ms(112)))
        var config = S.config(particles: 400)
        // As in the R11.1-5 tests: σ 5 m, so an accepted fix pulls hard.
        config.staleFixSigmaGrowthMps = 0
        let (engine, samples) = S.run(events, config: config, sampleTimes: [124.9, 125.1])
        return (engine, try #require(samples[0]), try #require(samples[1]), engine.counters.macroSteps)
    }

    @Test("R20.1-2 M2: a stale fix from inside a caught-up moving gap, arriving stopped, is ignored (macro steps are moving)")
    func staleFixFromMacroStretchIgnored() throws {
        let (engine, before, after, macro) = try Self.macroMotionThenStaleFix()
        // ~981 grid steps in ⌈981 / 100⌉ = 10-step macro steps: 99.
        #expect(macro > 90 && macro <= engine.config.maxCatchUpSteps, "macro steps \(macro)")
        #expect(engine.counters.staleFixesIgnoredMoved == 1, "ignored as moved \(engine.counters.staleFixesIgnoredMoved)")
        #expect(after.east == before.east && after.north == before.north)
    }

    // MARK: R20.1-2 M3: the macro step's antithetic increments

    /// 15 m/s north, clean fixes until 15 s and fresh OBD until 20 s, then
    /// every input silent until 620 s: 600 s of unknown speed caught up in
    /// macro steps. Returns the along-track offset (m) of the cloud's mean
    /// at 620 s from the same run with no stale speed noise.
    static func macroMeanDrift(seed: UInt64) throws -> Double {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 15, [.straight(seconds: 30, speed: 15)])
        let clean = S.cleanFix(accuracy: 5, positionNoise: 0)
        let events = drive.events(obdSpeed: { t, state in t < 20 ? (state.speed * 3.6).rounded(.down) : nil },
                                  fix: { t, state, rng in t < 15 ? clean(t, state, &rng) : nil })
            .filter { $0.timestamp.seconds <= 20.001 }
        func end(_ config: NavigationConfig) throws -> NavigationEstimate {
            var engine = NavigationEngine(config: config)
            for input in S.inputs(events) { engine.ingest(input) }
            engine.ingest(NavigationB0Tests.motion(620))
            #expect(engine.counters.macroSteps == config.maxCatchUpSteps)
            return try #require(engine.estimate(at: S.ms(620)))
        }
        var config = S.config(particles: 1000, seed: seed)
        let a = try end(config)
        config.staleSpeedNoiseMpsPerSqrtS = 0
        let b = try end(config)
        return a.north - b.north
    }

    @Test("R20.1-2 M3: 10 min of unknown speed caught up in macro steps: the realised mean does not drift")
    func macroStaleMeanDoesNotDrift() throws {
        var squares = 0.0
        for seed in UInt64(1)...3 {
            let drift = try Self.macroMeanDrift(seed: seed)
            squares += drift * drift
        }
        let rms = (squares / 3).squareRoot()
        // Independent (n3, n4) per particle: ~√(Var I(600 s) / N) ≈ 38 m
        // (σ_I ≈ 1.2 km, N = 1000). Antithetic: the pair's integrals cancel
        // along each one's heading; the rest is heading spread.
        #expect(rms < 12, "realised mean drift \(rms) m RMS after 600 s of macro steps")
    }
}

