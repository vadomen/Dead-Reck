import Foundation
import Testing

@testable import DriveLoggerCore

/// N4B1-1: an OBD 0 must not freeze the cloud while recent good fixes show
/// the car moving (`NavigationConfig.zuptFixGate`). Synthetic drives in
/// local metres around (0, 0).
@Suite("Navigation OBD-zero fix gate")
struct NavigationZeroFixGateTests {
    typealias S = SyntheticDrive

    static func config(gate: Int, particles: Int = 400) -> NavigationConfig {
        var config = S.config(particles: particles)
        config.zuptFixGate = gate
        return config
    }

    /// The simulator case: OBD answers 0 on every poll while the car drives
    /// at 50 km/h and clean GNSS fixes (speed and course) track it.
    static let stuckDrive = S(initialHeadingDeg: 60, initialSpeed: 13.9, [
        .straight(seconds: 20, speed: 13.9), .turn(degrees: 90, seconds: 20, speed: 13.9),
        .straight(seconds: 20, speed: 13.9),
    ])

    static func stuckEvents(fixesUntil: Double = .infinity, fix: S.Fix? = nil) -> [LogEvent] {
        let clean = S.cleanFix()
        return stuckDrive.events(obdSpeed: { _, _ in 0 }, fix: { t, state, rng in
            guard t <= fixesUntil + 1e-9 else { return nil }
            if var f = fix { f.east = state.east; f.north = state.north; return f }
            return clean(t, state, &rng)
        })
    }

    @Test("OBD stuck at 0 while clean fixes show 50 km/h: gate on, the steps move and the estimate follows the drive")
    func stuckZeroDoesNotFreeze() throws {
        let times = [10.0, 30.0, 59.0]
        let events = Self.stuckEvents()
        let (on, onSamples) = S.run(events, config: Self.config(gate: 1), sampleTimes: times)
        // Evidence needs two moving fixes after the first 0 (t = 1 and 2 s):
        // every step from the third second on is vetoed.
        #expect(on.counters.zuptVetoedSteps >= 570, "vetoed \(on.counters.zuptVetoedSteps)")
        #expect(on.counters.zuptSteps <= 30, "ZUPT \(on.counters.zuptSteps)")
        #expect(on.counters.courseUpdates > 50)
        for (t, sample) in zip(times, onSamples) {
            let estimate = try #require(sample)
            #expect(!estimate.stationary, "t \(t)")
            #expect(Self.stuckDrive.error(estimate, at: t) < 30, "t \(t): error \(Self.stuckDrive.error(estimate, at: t)) m")
        }
        let last = try #require(onSamples.last ?? nil)
        #expect(abs(angleDifference(last.headingDeg, 150)) < 5, "heading \(last.headingDeg)")

        // Gate off: the engine trusts the 0 (the bug the gate fixes).
        let (off, offSamples) = S.run(events, config: Self.config(gate: 0), sampleTimes: times)
        #expect(off.counters.zuptVetoedSteps == 0)
        #expect(off.counters.zuptSteps >= 590)
        let frozen = try #require(offSamples.last ?? nil)
        #expect(frozen.stationary)
        #expect(Self.stuckDrive.error(frozen, at: 59) > 300)
    }

    @Test("A vetoed step moves at the newest moving fix's Doppler speed, unscaled, and records it as held, not as a fresh OBD speed")
    func vetoedStepSpeed() throws {
        // A scale prior far from 1, with no spread: a scaled step would run
        // at 1.5 × 13.9 m/s.
        var config = Self.config(gate: 1)
        config.scalePriorMean = 1.5
        config.scalePriorStd = 0
        config.scaleNoisePerSqrtS = 0
        // Sampled before the third fix (t 3.0 s) arrives: steps 2.1–2.9 s
        // are vetoed, their speed offsets 0.8 s old.
        let (engine, samples) = S.run(Self.stuckEvents(), config: config, sampleTimes: [2.95])
        let estimate = try #require(samples[0])
        #expect(!estimate.stationary)
        #expect(abs(estimate.speedMps - 13.9) < 1, "speed \(estimate.speedMps)")
        let entry = try #require(engine.motionHistoryEntry(atOrBefore: S.ms(30).nanoseconds))
        #expect(entry.speed == nil, "not a fresh OBD speed: no GNSS speed update against the scale")
        #expect(entry.held == 13.9)
    }

    @Test("A real stop: OBD reaches 0 as the car stops, GNSS Doppler lags 1 s: the gate never vetoes, output equals gate off")
    func realStopStillZupts() throws {
        let drive = S(initialHeadingDeg: 45, initialSpeed: 10, [
            .straight(seconds: 20, speed: 10), .ramp(seconds: 4, from: 10, to: 0), .stop(seconds: 15),
            .ramp(seconds: 4, from: 0, to: 10), .straight(seconds: 10, speed: 10),
        ])
        let clean = S.cleanFix()
        let events = drive.events(gyroNoise: 0.05, fix: { t, state, rng in
            // Doppler speed from 1 s earlier: the GNSS tail of the braking.
            guard var f = clean(t, state, &rng) else { return nil }
            f.speed = drive.truth(at: max(0, t - 1)).speed
            return f
        })
        let times = stride(from: 1.0, through: 52, by: 0.5).map { $0 }
        let (on, onSamples) = S.run(events, config: Self.config(gate: 1), sampleTimes: times)
        let (off, offSamples) = S.run(events, config: Self.config(gate: 0), sampleTimes: times)
        #expect(on.counters.zuptVetoedSteps == 0)
        #expect(on.counters.zuptSteps >= 140)
        #expect(on.counters.zuptSteps == off.counters.zuptSteps)
        #expect(onSamples == offSamples)
        let atStop = try #require(onSamples[times.firstIndex(of: 30)!])
        #expect(atStop.stationary)
    }

    @Test("Evidence: one moving fix is not enough; network and coarse fixes never count; fixes before the zeros began never count")
    func evidenceRules() throws {
        // One moving fix after the zeros began, then nothing: below
        // zuptFixGateMinFixes (2), no veto.
        let one = Self.stuckEvents(fixesUntil: 1)
        #expect(S.run(one, config: Self.config(gate: 1)).engine.counters.zuptVetoedSteps == 0)
        var minOne = Self.config(gate: 1)
        minOne.zuptFixGateMinFixes = 1
        #expect(S.run(one, config: minOne).engine.counters.zuptVetoedSteps > 0)

        // Tower fixes (no Doppler speed) and coarse ones (accuracy over
        // cleanFixAccM, with speed): never evidence.
        let tower = Self.stuckEvents(fix: S.Fix(east: 0, north: 0, accuracy: 1414))
        #expect(S.run(tower, config: Self.config(gate: 1)).engine.counters.zuptVetoedSteps == 0)
        let coarse = Self.stuckEvents(fix: S.Fix(east: 0, north: 0, accuracy: 16, speed: 13.9, speedAccuracy: 0.5))
        #expect(S.run(coarse, config: Self.config(gate: 1)).engine.counters.zuptVetoedSteps == 0)
        let atLimit = Self.stuckEvents(fix: S.Fix(east: 0, north: 0, accuracy: 15, speed: 13.9, speedAccuracy: 0.5))
        #expect(S.run(atLimit, config: Self.config(gate: 1)).engine.counters.zuptVetoedSteps > 0)

        // Slow fixes: under zuptFixGateMinSpeedMps, no veto; at it, veto.
        let slow = Self.stuckEvents(fix: S.Fix(east: 0, north: 0, accuracy: 5, speed: 4.9, speedAccuracy: 0.5))
        #expect(S.run(slow, config: Self.config(gate: 1)).engine.counters.zuptVetoedSteps == 0)
        let atSpeed = Self.stuckEvents(fix: S.Fix(east: 0, north: 0, accuracy: 5, speed: 5, speedAccuracy: 0.5))
        #expect(S.run(atSpeed, config: Self.config(gate: 1)).engine.counters.zuptVetoedSteps > 0)

        // Fixes measured before the run of zeros began are the GNSS tail of
        // a stop, not evidence, even when they arrive after its first 0: OBD
        // answers only from 30 s, and each fix arrives 0.5 s after its t.
        let clean = S.cleanFix()
        let late = Self.stuckDrive.events(obdSpeed: { t, _ in t >= 30 ? 0 : nil }, fix: { t, state, rng in
            clean(t, state, &rng).map { var f = $0; f.latency = 0.5; return f }
        })
        var engine = NavigationEngine(config: Self.config(gate: 1))
        let inputs = S.inputs(late)
        for input in inputs where input.arrival <= S.ms(30.6) { engine.ingest(input) }
        let since = try #require(engine.zeroFix.zeroSinceNs)
        #expect(abs(Double(since) / 1e9 - 30.05) < 1e-6)
        #expect(engine.zeroFix.movingFixes == 0, "the fix at 30.0 s arrived at 30.5 s, after the first 0")
        for input in inputs where input.arrival > S.ms(30.6) && input.arrival <= S.ms(31.6) { engine.ingest(input) }
        #expect(engine.zeroFix.movingFixes == 1)
    }

    @Test("A slow good fix ends the veto; a moving OBD reply clears the evidence; a new run of zeros starts from nothing")
    func evidenceResets() throws {
        var engine = NavigationEngine(config: Self.config(gate: 1))
        let inputs = S.inputs(Self.stuckEvents())
        var index = 0
        while index < inputs.count, inputs[index].arrival < S.ms(10) {
            engine.ingest(inputs[index])
            index += 1
        }
        let since = try #require(engine.zeroFix.zeroSinceNs)
        #expect(engine.zeroFix.movingFixes >= 8)
        let held = engine.zeroFix
        // Another 0: the same run, evidence kept.
        engine.ingest(.obd(OBDSample(pid: .vehicleSpeed, value: 0, unit: .kilometersPerHour, ecu: "7E8"), at: S.ms(10)))
        #expect(engine.zeroFix == held)
        #expect(engine.zeroFix.speedMps == 13.9)
        // A slow good fix: the run of moving fixes ends.
        let p = S.plane.geodetic(east: 0, north: 0)
        let slow = LocationSample(latitude: p.latitude, longitude: p.longitude, altitude: 0, horizontalAccuracy: 5,
                                  verticalAccuracy: -1, speed: 1, speedAccuracy: 0.5, course: -1, courseAccuracy: -1,
                                  receivedT: S.ms(10.02), ageS: 0.01)
        engine.ingest(.location(slow, at: S.ms(10.01)))
        #expect(engine.zeroFix.movingFixes == 0 && engine.zeroFix.newestFixNs == nil)
        #expect(engine.zeroFix.zeroSinceNs == since)
        // A moving reply clears it all; the next 0 starts a new run.
        engine.ingest(.obd(OBDSample(pid: .vehicleSpeed, value: 30, unit: .kilometersPerHour, ecu: "7E8"), at: S.ms(10.1)))
        #expect(engine.zeroFix == NavigationEngine.ZeroFixEvidence())
        engine.ingest(.obd(OBDSample(pid: .vehicleSpeed, value: 0, unit: .kilometersPerHour, ecu: "7E8"), at: S.ms(10.2)))
        #expect(engine.zeroFix == NavigationEngine.ZeroFixEvidence(zeroSinceNs: S.ms(10.2).nanoseconds))
        // Another ECU's 0 is not the vehicle speed this engine uses.
        engine.ingest(.obd(OBDSample(pid: .vehicleSpeed, value: 40, unit: .kilometersPerHour, ecu: "7E9"), at: S.ms(10.3)))
        #expect(engine.zeroFix.zeroSinceNs == S.ms(10.2).nanoseconds)
    }

    @Test("Fixes stop while OBD stays at 0: the veto lasts zuptFixGateMaxAgeS past the newest moving fix, then ZUPT")
    func evidenceExpires() throws {
        // Clean fixes until 30 s (arriving 30.05 s), none after.
        let (engine, samples) = S.run(Self.stuckEvents(fixesUntil: 30), config: Self.config(gate: 1),
                                      sampleTimes: [32.95, 33.2, 50])
        #expect(try !#require(samples[0]).stationary)
        #expect(try #require(samples[1]).stationary)
        #expect(try #require(samples[2]).stationary)
        // Steps 2.1 s…33.0 s are vetoed (310: the evidence holds from the
        // second moving fix's arrival at 2.05 s until 3 s after the last
        // fix's t, 30 s); 33.1 s on are ZUPT.
        #expect(engine.counters.zuptVetoedSteps == 310, "vetoed \(engine.counters.zuptVetoedSteps)")
        var short = Self.config(gate: 1)
        short.zuptFixGateMaxAgeS = 1
        let shortRun = S.run(Self.stuckEvents(fixesUntil: 30), config: short).engine
        #expect(shortRun.counters.zuptVetoedSteps == 290, "\(shortRun.counters.zuptVetoedSteps)")
    }

    @Test("A vetoed step moves like a stale one: each particle's speed takes the OU unknown-speed noise, so the cloud spreads along track")
    func vetoedStepTakesStaleSpeedNoise() throws {
        // Fixes until 2 s (arriving 2.05 s), then none; OBD stays at 0.
        // Steps 0–2.0 s are ZUPT (offsets reset to 0), 2.1 s on are vetoed
        // (until 5.0 s); stop at 4.95 s, 2.9 s of vetoed steps.
        let end = S.ms(4.95)
        let events = Self.stuckEvents(fixesUntil: 2).filter { NavigationInput($0)!.arrival <= end }
        let noisy = Self.config(gate: 1)
        var quiet = noisy
        quiet.staleSpeedNoiseMpsPerSqrtS = 0
        let (on, onSamples) = S.run(events, config: noisy, sampleTimes: [4.95])
        let ref = S.run(events, config: quiet).engine
        #expect(on.counters.zuptVetoedSteps == 29, "vetoed \(on.counters.zuptVetoedSteps)")
        #expect(ref.counters.zuptVetoedSteps == on.counters.zuptVetoedSteps)
        #expect(on.counters.staleSpeedSteps == 0, "vetoed steps are not counted as stale")

        // OU from 0 over 2.9 s (σ 2.5 m/s/√s, τ 20 s): std ≈ 4.0 m/s per
        // particle. 400 particles put the sample std within a few percent.
        func spread(_ e: NavigationEngine) -> Double {
            let w = e.weight.reduce(0, +)
            let mean = zip(e.weight, e.speedOffset).reduce(0) { $0 + $1.0 * $1.1 } / w
            let variance = zip(e.weight, e.speedOffset).reduce(0) { $0 + $1.0 * ($1.1 - mean) * ($1.1 - mean) } / w
            return variance.squareRoot()
        }
        #expect(spread(on) > 3 && spread(on) < 5, "speed offset std \(spread(on)) m/s")
        #expect(ref.speedOffset.allSatisfy { $0 == 0 })

        // The offsets reach the positions: the reference run draws the same
        // random numbers with the offsets × 0, so particle by particle the
        // two clouds differ by the integrated offsets alone (OU integral
        // over 2.9 s: ≈ 7 m rms).
        let shifts = zip(zip(on.east, on.north), zip(ref.east, ref.north)).map { a, b in
            ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1)).squareRoot()
        }
        let rms = (shifts.map { $0 * $0 }.reduce(0, +) / Double(shifts.count)).squareRoot()
        #expect(rms > 5 && rms < 10, "particle shift rms \(rms) m")
        #expect(try #require(onSamples[0]).stationary == false)
    }

    @Test("A stale OBD 0 (parked, no IMU motion) is vetoed by moving fixes as a fresh one is")
    func parkedIsVetoed() throws {
        // OBD answers 0 until 5 s, then nothing; constant speed, so the
        // IMU never clears the parked latch.
        let clean = S.cleanFix()
        let events = Self.stuckDrive.events(obdSpeed: { t, _ in t < 5 ? 0 : nil }, fix: { t, state, rng in
            clean(t, state, &rng)
        })
        let (on, onSamples) = S.run(events, config: Self.config(gate: 1), sampleTimes: [59])
        #expect(on.counters.zuptVetoedSteps >= 570)
        #expect(on.counters.staleParkedSteps == 0)
        #expect(Self.stuckDrive.error(try #require(onSamples[0]), at: 59) < 30)
        let off = S.run(events, config: Self.config(gate: 0)).engine
        #expect(off.counters.staleParkedSteps >= 520, "\(off.counters)")
        #expect(off.counters.zuptVetoedSteps == 0)
    }

    @Test("A silence of every input while the veto holds: catch-up equals stepping one by one")
    func catchUpWhileVetoed() throws {
        // OBD stuck at 0 and fixes until 39.9 s; every input silent from
        // 40 s to 55 s (the app suspended), then the drive resumes.
        let events = Self.stuckEvents().filter {
            let t = NavigationInput($0)!.arrival
            return t < S.ms(40) || t > S.ms(55)
        }
        let times = [41.0, 43.5, 56.0, 59.0]
        let bulk = S.run(events, config: Self.config(gate: 1), sampleTimes: times)
        var stepped = Self.config(gate: 1)
        stepped.maxCatchUpSteps = 1_000_000
        let single = S.run(events, config: stepped, sampleTimes: times)
        #expect(bulk.engine.counters.coalescedSteps > 0)
        #expect(single.engine.counters.coalescedSteps == 0)
        #expect(bulk.engine.counters.zuptVetoedSteps == single.engine.counters.zuptVetoedSteps)
        #expect(bulk.engine.counters.staleParkedSteps == single.engine.counters.staleParkedSteps)
        #expect(bulk.samples == single.samples)
    }

    @Test("Gate keys: defaults, decoding without them, refused values")
    func configKeys() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: NavigationConfig().canonicalJSON()) as? [String: Any])
        let keys = ["zuptFixGate", "zuptFixGateMinSpeedMps", "zuptFixGateMinFixes", "zuptFixGateMaxAgeS"]
        let defaults: [String: Double] = ["zuptFixGate": Double(NavigationConfig().zuptFixGate),
                                          "zuptFixGateMinSpeedMps": 5, "zuptFixGateMinFixes": 2, "zuptFixGateMaxAgeS": 3]
        for key in keys { #expect((json[key] as? NSNumber)?.doubleValue == defaults[key], "\(key)") }
        var old = json
        for key in keys { old.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(NavigationConfig.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded == NavigationConfig())
        #expect(!NavigationConfig.roadOnlyKeys.contains("zuptFixGate"))

        func refused(_ edit: (inout NavigationConfig) -> Void) -> String? {
            var c = NavigationConfig()
            edit(&c)
            return c.invalidReason
        }
        #expect(refused { $0.zuptFixGate = 1 } == nil)
        #expect(refused { $0.zuptFixGate = 0 } == nil)
        #expect(refused { $0.zuptFixGate = 2 }?.contains("zuptFixGate") == true)
        #expect(refused { $0.zuptFixGate = -1 } != nil)
        for bad in [0.0, -1, .infinity, .nan] {
            #expect(refused { $0.zuptFixGateMinSpeedMps = bad }?.contains("zuptFixGateMinSpeedMps") == true, "\(bad)")
        }
        #expect(refused { $0.zuptFixGateMinFixes = 0 }?.contains("zuptFixGateMinFixes") == true)
        #expect(refused { $0.zuptFixGateMinFixes = 1 } == nil)
        for bad in [-1.0, .infinity, .nan] {
            #expect(refused { $0.zuptFixGateMaxAgeS = bad }?.contains("zuptFixGateMaxAgeS") == true, "\(bad)")
        }
        #expect(refused { $0.zuptFixGateMaxAgeS = 0 } == nil)
    }
}
