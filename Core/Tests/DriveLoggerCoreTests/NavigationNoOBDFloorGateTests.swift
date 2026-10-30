import Foundation
import Testing

@testable import DriveLoggerCore

/// Prompt 46 Part A: the no-OBD fix-speed mean μ (`noOBDFixSpeedMean`)
/// relaxes towards `noOBDFixSpeedFloorKmh` = 0 when fixes stop, and a
/// window of network fixes that moves less than the noise of two fixes is
/// damped by the displacement gate (`noOBDFixSpeedGate`). Synthetic drives
/// from (0, 0) only; no real place, date or recording.
@Suite("Navigation prompt 46: no-OBD fix-speed floor and displacement gate")
struct NavigationNoOBDFloorGateTests {
    typealias S = SyntheticDrive
    typealias M = NavigationNoOBDModeTests

    static let kmh50 = 50 / 3.6

    /// Drives 120 s north-east at 50 km/h (clean GNSS fixes: position and
    /// heading converge), stops at 130 s and stays parked to 970 s.
    static let parkedDrive = S(initialHeadingDeg: 30, [
        .ramp(seconds: 10, from: 0, to: kmh50), .straight(seconds: 110, speed: kmh50),
        .ramp(seconds: 10, from: kmh50, to: 0), .stop(seconds: 840),
    ])
    static let parkAt = 130.0

    /// Clean fixes every 2 s before `parkAt`; from it, every 8 s, `network`
    /// (nil: none).
    static func parkedFixes(_ network: @escaping (Double, S.State, inout NavigationRandom) -> S.Fix?)
        -> (Double, S.State, inout NavigationRandom) -> S.Fix? {
        let clean = S.cleanFix(accuracy: 5, positionNoise: 1)
        return { t, state, rng in
            if t < parkAt { return clean(t, state, &rng) }
            let k = ((t - parkAt) / 8).rounded()
            guard abs(t - parkAt - 8 * k) < S.motionDt / 2 else { return nil }
            return network(t, state, &rng)
        }
    }

    static func distance(_ a: NavigationEstimate, _ b: (east: Double, north: Double)) -> Double {
        let p = S.plane.enu(latitude: a.latitude, longitude: a.longitude)
        return ((p.east - b.east) * (p.east - b.east) + (p.north - b.north) * (p.north - b.north)).squareRoot()
    }

    static func enu(_ a: NavigationEstimate) -> (east: Double, north: Double) {
        let p = S.plane.enu(latitude: a.latitude, longitude: a.longitude)
        return (p.east, p.north)
    }

    // MARK: Gate factor

    @Test("Gate factor: D0 = k·√2·σ of the worse endpoint's band (σ 8 / 170 / 240 m by claimed < 100, < 1000, ≥ 1000 m); 1 at and above D0; below it 0 (hard), (d/D0)² (soft); 1 when off; NaN accuracy is the tower band")
    func gateFactor() {
        var c = NavigationConfig()
        func f(_ d: Double, _ a: Double, _ b: Double) -> Double {
            NavigationEngine.fixSpeedGateFactor(distance: d, oldestAccuracy: a, newestAccuracy: b, config: c)
        }
        let r2 = 2.0.squareRoot()
        let d0Low = 2.15 * r2 * 8, d0Mid = 2.15 * r2 * 170, d0Tower = 2.15 * r2 * 240
        #expect(c.noOBDFixSpeedGate == 2)
        // Soft: (d/D0)² below D0, 1 from it.
        #expect(abs(f(d0Low / 2, 30, 30) - 0.25) < 1e-12)
        #expect(abs(f(d0Mid / 2, 500, 500) - 0.25) < 1e-12)
        #expect(abs(f(d0Tower / 2, 1_414, 1_414) - 0.25) < 1e-12)
        #expect(f(0, 1_414, 1_414) == 0)
        #expect(f(d0Tower, 1_414, 1_414) == 1 && f(d0Tower * 3, 1_414, 1_414) == 1)
        #expect(f(d0Tower.nextDown, 1_414, 1_414) < 1)
        // Band edges: 100 and 1000 m belong to the upper band.
        #expect(abs(f(d0Low / 2, 99.99, 99.99) - 0.25) < 1e-12)
        #expect(abs(f(d0Mid / 2, 100, 100) - 0.25) < 1e-12)
        #expect(abs(f(d0Mid / 2, 999.99, 999.99) - 0.25) < 1e-12)
        #expect(abs(f(d0Tower / 2, 1_000, 1_000) - 0.25) < 1e-12)
        // The worse endpoint sets σ, whichever end it is.
        #expect(abs(f(d0Tower / 2, 30, 1_414) - 0.25) < 1e-12)
        #expect(abs(f(d0Tower / 2, 1_414, 30) - 0.25) < 1e-12)
        #expect(abs(f(d0Mid / 2, 500, 30) - 0.25) < 1e-12)
        #expect(abs(f(d0Tower / 2, .nan, 30) - 0.25) < 1e-12)
        // Hard: 0 below D0, 1 from it.
        c.noOBDFixSpeedGate = 1
        #expect(f(d0Tower.nextDown, 1_414, 1_414) == 0 && f(d0Tower, 1_414, 1_414) == 1)
        #expect(f(d0Low.nextDown, 30, 30) == 0 && f(d0Low, 30, 30) == 1)
        // Off.
        c.noOBDFixSpeedGate = 0
        #expect(f(0, 1_414, 1_414) == 1 && f(d0Tower / 2, 1_414, 1_414) == 1)
        // The keys: k and each σ scale D0.
        c.noOBDFixSpeedGate = 2
        c.noOBDFixSpeedGateK = 1.67
        #expect(abs(f(1.67 * r2 * 240 / 2, 1_414, 1_414) - 0.25) < 1e-12)
        c.noOBDFixSpeedGateSigmaLowM = 20
        c.noOBDFixSpeedGateSigmaMidM = 50
        c.noOBDFixSpeedGateSigmaTowerM = 100
        #expect(abs(f(1.67 * r2 * 20 / 2, 30, 30) - 0.25) < 1e-12)
        #expect(abs(f(1.67 * r2 * 50 / 2, 500, 500) - 0.25) < 1e-12)
        #expect(abs(f(1.67 * r2 * 100 / 2, 1_414, 1_414) - 0.25) < 1e-12)
    }

    // MARK: Parked, no fixes

    @Test("Parked 10 min with no fixes (μ̂ ≈ 0 from 2 min of parked Wi-Fi fixes): the estimate (2000 particles) drifts < 50 m at floor 0 (measured: worst 10.2 m, 5.7 m at the end; μ̂ 0.84 km/h); prompt 45's floor 30 km/h drives it over 1 km (1722 m)")
    func parkedWithoutFixesStays() throws {
        let fixesStop = 250.0, end = 850.0
        let wifi = M.networkFix(accuracy: 50, noise: 8)
        let fixes = Self.parkedFixes { t, state, rng in t < fixesStop ? wifi(t, state, &rng) : nil }
        let events = Self.parkedDrive.events(gyroNoise: 0.002, obdSpeed: M.noOBD, fixEvery: 2, fix: fixes)
        let times = Array(stride(from: fixesStop, through: end, by: 10))
        func drift(_ config: NavigationConfig) throws -> (max: Double, end: Double, mu: Double?) {
            let run = S.run(events, config: config, sampleTimes: times)
            let start = Self.enu(try #require(run.samples[0]))
            var worst = 0.0
            for sample in run.samples { worst = max(worst, Self.distance(try #require(sample), start)) }
            #expect(!run.engine.obdEverIngested && run.engine.counters.networkFixesUsed >= 14)
            return (worst, Self.distance(try #require(run.samples.last!), start), run.engine.fixSpeedEstimate?.mps)
        }
        let now = try drift(M.config(fixSpeed: 1, particles: 2_000))
        #expect(now.max < 50, "max drift \(now.max) m, at the end \(now.end) m, μ̂ \(now.mu ?? .nan) m/s")
        // Parked Wi-Fi fixes: μ̂ well under 1 km/h.
        #expect((now.mu ?? .nan) * 3.6 < 1)
        let old = try drift(M.config45(particles: 2_000))
        #expect(old.end > 1_000, "prompt 45 drifts \(old.end) m")
    }

    // MARK: Parked, tower fixes

    @Test("Parked 10 min with tower fixes (1414 m claimed) jittering uniformly ±200 m per axis every 8 s: the estimate (2000 particles) stays within 150 m of the car on average (measured: mean 21.9 m, worst 63.9 m); prompt 45's (a) is farther off (mean 135.4 m, worst 180.6 m)")
    func parkedWithTowerFixesStays() throws {
        let end = Self.parkAt + 600
        let tower: (Double, S.State, inout NavigationRandom) -> S.Fix? = { _, state, rng in
            S.Fix(east: state.east + 400 * (rng.nextUniform() - 0.5), north: state.north + 400 * (rng.nextUniform() - 0.5),
                  accuracy: 1_414)
        }
        let events = Self.parkedDrive.events(gyroNoise: 0.002, obdSpeed: M.noOBD, fixEvery: 2,
                                             fix: Self.parkedFixes { t, state, rng in t <= end ? tower(t, state, &rng) : nil })
        let times = Array(stride(from: Self.parkAt + 10, through: end, by: 10))
        let car = Self.parkedDrive.truth(at: Self.parkAt)
        func drift(_ config: NavigationConfig) throws -> (mean: Double, max: Double) {
            let run = S.run(events, config: config, sampleTimes: times)
            #expect(!run.engine.obdEverIngested && run.engine.counters.networkFixesUsed >= 70)
            let d = try run.samples.map { Self.distance(try #require($0), (car.east, car.north)) }
            return (d.reduce(0, +) / Double(d.count), d.max()!)
        }
        let now = try drift(M.config(fixSpeed: 1, particles: 2_000))
        #expect(now.mean < 150, "mean drift \(now.mean) m, worst \(now.max) m")
        let old = try drift(M.config45(particles: 2_000))
        #expect(now.mean < old.mean, "now \(now.mean) m, prompt 45 \(old.mean) m")
    }

    // MARK: Moving: μ as in prompt 45

    @Test("Moving at 50 km/h with tower fixes (200 m noise) every 8 s: μ̂ is endpoint distance / span × min(1, (d/730 m)²), the same as prompt 45's (a) times the gate; once the window spans more than D0 (here from 130 s on) it equals prompt 45's bit for bit")
    func movingTrackKeepsTheFixSpeed() throws {
        let straight = S(initialHeadingDeg: 30, initialSpeed: Self.kmh50, [.straight(seconds: 300, speed: Self.kmh50)])
        let events = straight.events(gyroNoise: 0.002, obdSpeed: M.noOBD, fixEvery: 8,
                                     fix: M.networkFix(accuracy: 1_414, noise: 200))
        var gated = NavigationEngine(config: M.config(fixSpeed: 1))
        var old = NavigationEngine(config: M.config45())
        var window: [(t: Double, east: Double, north: Double)] = []
        let d0 = 2.15 * 2.0.squareRoot() * 240
        var damped = 0, equal = 0
        for input in S.inputs(events) {
            gated.ingest(input)
            old.ingest(input)
            guard case .location(let sample, let t) = input else { continue }
            let p = S.plane.enu(latitude: sample.latitude, longitude: sample.longitude)
            window.append((t.seconds, p.east, p.north))
            window.removeAll { t.seconds - $0.t > 120 }
            let span = t.seconds - window[0].t
            guard span >= 10 else {
                #expect(gated.fixSpeedEstimate == nil && old.fixSpeedEstimate == nil)
                continue
            }
            let d = ((p.east - window[0].east) * (p.east - window[0].east)
                + (p.north - window[0].north) * (p.north - window[0].north)).squareRoot()
            let oldMps = try #require(old.fixSpeedEstimate?.mps)
            let gatedMps = try #require(gated.fixSpeedEstimate?.mps)
            #expect(abs(oldMps - min(d / span, 110 / 3.6)) < 1e-6, "\(t.seconds)")
            let factor = min(1, (d / d0) * (d / d0))
            #expect(abs(gatedMps - min(d / span * factor, 110 / 3.6)) < 1e-6, "\(t.seconds): \(gatedMps) vs \(d / span * factor)")
            if d < d0 { damped += 1 }
            if t.seconds >= 130 {
                #expect(d > 1.5 * d0)
                #expect(gatedMps == oldMps, "\(t.seconds)")
                #expect(abs(gatedMps - Self.kmh50) * 3.6 < 15, "\(t.seconds): \(gatedMps * 3.6) km/h")
                equal += 1
            }
        }
        #expect(gated.counters.networkFixesUsed == old.counters.networkFixesUsed)
        #expect(gated.counters.networkFixesUsed == 38)
        #expect(damped >= 3 && equal >= 20, "damped \(damped), equal \(equal)")
    }

    // MARK: Prompt 45 reproduced

    @Test("Floor 30 and gate 0 reproduce prompt 45's (a) bit for bit: a 10 min no-fix gap after a 50 km/h tower-fix drive ends at the estimate prompt 45 produced (values recorded on its code)")
    func floor30ReproducesPrompt45() throws {
        let long = S(initialHeadingDeg: 0, initialSpeed: Self.kmh50, [.straight(seconds: 760, speed: Self.kmh50)])
        let fix = M.networkFix(accuracy: 1_414, noise: 200)
        let events = long.events(gyroNoise: 0.002, obdSpeed: M.noOBD, fixEvery: 8,
                                 fix: { t, s, rng in t <= 152 ? fix(t, s, &rng) : nil })
        let run = S.run(events, config: M.config45(), sampleTimes: [400, 760])
        let mid = try #require(run.samples[0]), end = try #require(run.samples[1])
        let mu = try #require(run.engine.fixSpeedEstimate?.mps)
        let got = [mid.latitude, mid.longitude, end.latitude, end.longitude, end.ellipse.semiMajorM, mu].map(\.bitPattern)
        #expect(got == Self.prompt45Bits, "\(got)")
    }

    /// Recorded with prompt 45's code (nav-noobd f063768, floor 30 its
    /// default, no gate) for `floor30ReproducesPrompt45`.
    static let prompt45Bits: [UInt64] = [
        4583402987100919984, 13792656893693868045, 4586179606612696957, 13796456654923128948, 4666973437252394694,
        4624878866698884153,
    ]
}
