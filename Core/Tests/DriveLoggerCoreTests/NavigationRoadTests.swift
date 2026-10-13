import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// N3.2 tests 1–13 (docs/N3_PLAN.md, "N3.2"): the road update in
/// `NavigationEngine(config:roads:)` on hand-written synthetic packs near
/// (0, 0). No real place, extract or recording is involved.
@Suite("Navigation roads (N3.2)")
struct NavigationRoadTests {
    typealias S = SyntheticDrive
    typealias N = RoadFixture.Node

    // MARK: Fixtures

    static func network(_ lines: [String], coverage: [[RoadPoint]]? = nil) throws -> RoadNetwork {
        try RoadNetwork(packs: [RoadFixture.build(lines, coverage: coverage)])
    }

    /// A straight two-way residential street from `from` to `to` (metres).
    static func street(_ id: Int64, from a: (Double, Double), to b: (Double, Double),
                       tags: [String: String] = ["highway": "residential"]) -> String {
        RoadFixture.way(id, tags, [N(id: id * 10, east: a.0, north: a.1), N(id: id * 10 + 1, east: b.0, north: b.1)])
    }

    static func pin(at t: Double, east: Double, north: Double, span: Double = 360, kmh: Double?) -> LogEvent {
        let p = S.plane.geodetic(east: east, north: north)
        return LogEvent(timestamp: S.ms(t), payload: .manualFix(ManualFixSample(
            latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(t), mapSpanM: span,
            speedSource: kmh == nil ? "unknown" : "obd", gateSpeedKmh: kmh)))
    }

    /// A test config: `particles`, seed, and the road keys as given.
    static func config(particles: Int = 400, seed: UInt64 = 1, _ edit: (inout NavigationConfig) -> Void = { _ in })
        -> NavigationConfig {
        var c = S.config(particles: particles, seed: seed)
        edit(&c)
        return c
    }

    /// Runs `inputs`; returns the engine and its estimate after every input
    /// whose arrival is at or before each sample time.
    static func run(_ inputs: [NavigationInput], config: NavigationConfig, roads: RoadNetwork?,
                    cache: Int = RoadMatcher.defaultCacheCapacity, every: Double? = nil)
        -> (engine: NavigationEngine, estimates: [NavigationEstimate]) {
        var engine = NavigationEngine(config: config, roads: roads, roadCacheCapacity: cache)
        var out: [NavigationEstimate] = []
        var next = every
        for input in inputs {
            if let step = every, let t = next, input.arrival > S.ms(t) {
                if let e = engine.estimate(at: S.ms(t)) { out.append(e) }
                next = t + step
            }
            engine.ingest(input)
        }
        return (engine, out)
    }

    /// The engine's whole particle state, for bit-identity.
    static func state(_ e: NavigationEngine) -> [[Double]] {
        [e.east, e.north, e.covEE, e.covEN, e.covNN, e.heading, e.scale, e.speedOffset, e.weight, e.logWeight]
    }

    static func meanOffset(_ e: NavigationEngine, plane: LocalTangentPlane = S.plane)
        -> (east: Double, north: Double) {
        let est = e.estimate(at: MonotonicTimestamp(nanoseconds: 0))!
        let p = plane.enu(latitude: est.latitude, longitude: est.longitude)
        return (p.east, p.north)
    }

    /// A drive north along x = 0 at `speed` from (0, −1000), initialised
    /// by a pin `offset` metres east of the truth, heading known from
    /// clean fixes before it (so the cloud is a tight blob, not a ring).
    static func northDrive(seconds: Double = 100, speed: Double = 12) -> SyntheticDrive {
        S(initialHeadingDeg: 0, initialSpeed: speed, [.straight(seconds: seconds, speed: speed)])
    }

    /// Input events shifted so the drive starts at (x0, y0) in the plane.
    static func shifted(_ drive: SyntheticDrive, by d: (east: Double, north: Double),
                        fix: @escaping (Double, SyntheticDrive.State, inout NavigationRandom) -> SyntheticDrive.Fix?,
                        extra: [LogEvent] = [], gyroNoise: Double = 0, seed: UInt64 = 7) -> [NavigationInput] {
        let events = drive.events(seed: seed, gyroNoise: gyroNoise, fix: { t, state, rng in
            guard var f = fix(t, state, &rng) else { return nil }
            f.east += d.east
            f.north += d.north
            return f
        }, extra: extra)
        return S.inputs(events)
    }

    // MARK: 1. Straight road, cross-track convergence; coupling 0 leaves along-track alone

    /// Truth on a road through the origin at bearing `bearingDeg`; the
    /// cloud starts 20 m across it from a pin (σ 30 m), then a 30 s drive
    /// on the road. Returns the truth's cross-track distance from the
    /// estimate at the end, and the largest along-track change any road
    /// update made to any particle (road frame), with its covariance.
    static func straightRoad(bearingDeg: Double, coupling: Double, seed: UInt64 = 1) throws
        -> (finalCross: Double, alongChange: Double, alongCovChange: Double, updates: Int) {
        let b = bearingDeg * .pi / 180
        let net = try network([street(1, from: (-2000 * sin(b), -2000 * cos(b)), to: (2000 * sin(b), 2000 * cos(b)))])
        // The road frame is the stored segment's direction in the plane
        // (E7 rounding moves it off `bearingDeg` by ~1e-6 rad).
        let seg = net.packs[0].segment(startingAt: 0)
        let pa = S.plane.enu(latitude: seg.a.latitude, longitude: seg.a.longitude)
        let pb = S.plane.enu(latitude: seg.b.latitude, longitude: seg.b.longitude)
        let len = ((pb.east - pa.east) * (pb.east - pa.east) + (pb.north - pa.north) * (pb.north - pa.north)).squareRoot()
        let ux = (pb.east - pa.east) / len, uy = (pb.north - pa.north) / len
        let v = 12.0
        let drive = S(initialHeadingDeg: bearingDeg, initialSpeed: v, [.straight(seconds: 30, speed: v)])
        // Start on the road at −150 m along it.
        let start = (east: -150 * ux, north: -150 * uy)
        // The pin: 20 m to the right of the road (normal = (uy, −ux)).
        let pinAt = (east: start.east + 20 * uy, north: start.north - 20 * ux)
        let events = drive.events(extra: [pin(at: 0.2, east: pinAt.east - start.east, north: pinAt.north - start.north,
                                              kmh: nil)])
        let inputs = S.inputs(events).map { input -> NavigationInput in
            guard case .manualFix(var m, let t) = input else { return input }
            let p = S.plane.geodetic(east: pinAt.east, north: pinAt.north)
            m.latitude = p.latitude
            m.longitude = p.longitude
            return .manualFix(m, at: t)
        }
        // No split: Step 1 re-draws means along the road by design; the
        // claim is about Step 4.
        var config = config(particles: 300, seed: seed) { c in
            c.roadAlongTrackCoupling = coupling
            c.roadPinAnchorMinKmh = 0
            c.roadSplitSigmaM = 1000
        }
        config.scalePriorStd = 0
        // Heading known: the pin cloud starts with uniform headings, so
        // every particle is set on the road's bearing after initialisation.
        // Each road update's effect on along-track is measured by running
        // it on a copy just before the input that would trigger it.
        var engine = NavigationEngine(config: config, roads: net)
        var maxAlong = 0.0, maxAlongCov = 0.0
        for input in inputs {
            if engine.isInitialized {
                var after = engine
                after.roadUpdate(evidenceDistanceM: config.roadCorrelationM)
                for i in 0..<engine.east.count {
                    let a0 = engine.east[i] * ux + engine.north[i] * uy
                    let a1 = after.east[i] * ux + after.north[i] * uy
                    maxAlong = max(maxAlong, abs(a1 - a0))
                    let paa0 = ux * ux * engine.covEE[i] + 2 * ux * uy * engine.covEN[i] + uy * uy * engine.covNN[i]
                    let paa1 = ux * ux * after.covEE[i] + 2 * ux * uy * after.covEN[i] + uy * uy * after.covNN[i]
                    maxAlongCov = max(maxAlongCov, abs(paa1 - paa0) / max(paa0, 1))
                }
            }
            let wasInitialized = engine.isInitialized
            engine.ingest(input)
            if !wasInitialized, engine.isInitialized {
                for i in engine.heading.indices { engine.heading[i] = b }
            }
        }
        let end = drive.truth(at: drive.duration)
        let truth = (east: start.east + end.east, north: start.north + end.north)
        let est = meanOffset(engine)
        let cross = (truth.east - est.east) * uy - (truth.north - est.north) * ux
        precondition(engine.counters.roadSplits == 0)
        return (abs(cross), maxAlong, maxAlongCov, engine.counters.roadUpdates)
    }

    @Test("1. Straight road, 20 m off: converges across the road; coupling 0 leaves along-track unchanged (30° road, 1e-9)")
    func straightRoadSchmidt() throws {
        let r = try Self.straightRoad(bearingDeg: 30, coupling: 0)
        #expect(r.updates > 20)
        #expect(r.finalCross < 6, "cross-track error \(r.finalCross) m, from 20 m")
        #expect(r.alongChange < 1e-9, "along-track moved by \(r.alongChange) m")
        #expect(r.alongCovChange < 1e-9, "P_aa moved by a relative \(r.alongCovChange)")
    }

    /// A cloud on a 30° road with correlated along/cross covariance
    /// (P_ac ≠ 0, as after a turn): coupling 0 leaves along-track and P_aa
    /// at 1e-9 in the road frame, coupling 1 moves along-track by
    /// P_ac/P_cc × the cross-track step. A swapped sin/cos in the frame
    /// would move along-track at coupling 0 and fail the first.
    @Test("1. Correlated covariance on a 30° road: coupling 0 keeps along-track, coupling 1 moves it by P_ac / S_w")
    func straightRoadCorrelated() throws {
        let b = 30 * Double.pi / 180
        let net = try Self.network([Self.street(1, from: (-2000 * sin(b), -2000 * cos(b)), to: (2000 * sin(b), 2000 * cos(b)))])
        let seg = net.packs[0].segment(startingAt: 0)
        let pa = S.plane.enu(latitude: seg.a.latitude, longitude: seg.a.longitude)
        let pb = S.plane.enu(latitude: seg.b.latitude, longitude: seg.b.longitude)
        let len = ((pb.east - pa.east) * (pb.east - pa.east) + (pb.north - pa.north) * (pb.north - pa.north)).squareRoot()
        let tx = (pb.east - pa.east) / len, ty = (pb.north - pa.north) / len
        let hx = ty, hy = -tx  // right of the road
        func cloud(coupling: Double) -> (before: NavigationEngine, after: NavigationEngine) {
            let config = Self.config(particles: 200) { $0.roadSplitSigmaM = 1000; $0.resampleESSFraction = 0; $0.roadAlongTrackCoupling = coupling }
            var engine = NavigationEngine(config: config, roads: net)
            let p = S.plane.geodetic(east: 0, north: 0)
            engine.ingest(.manualFix(ManualFixSample(latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(0.05),
                                                     mapSpanM: 360, speedSource: "unknown"), at: S.ms(0.05)))
            var rng = NavigationRandom(seed: 4)
            for i in engine.east.indices {
                let a = 100 * rng.nextGaussian(), c = 15 * rng.nextGaussian()
                engine.east[i] = a * tx + c * hx
                engine.north[i] = a * ty + c * hy
                // Road frame P: aa 400, cc 100, ac 120.
                let (paa, pcc, pac) = (400.0, 100.0, 120.0)
                engine.covEE[i] = paa * tx * tx + 2 * pac * tx * hx + pcc * hx * hx
                engine.covEN[i] = paa * tx * ty + pac * (tx * hy + ty * hx) + pcc * hx * hy
                engine.covNN[i] = paa * ty * ty + 2 * pac * ty * hy + pcc * hy * hy
                engine.heading[i] = b + 0.02 * rng.nextGaussian()
            }
            var after = engine
            after.roadUpdate(evidenceDistanceM: 30)
            return (engine, after)
        }
        let s = cloud(coupling: 0), k = cloud(coupling: 1)
        #expect(s.after.counters.roadUpdates == 1 && s.after.counters.roadSplits == 0)
        var schmidtAlong = 0.0, schmidtPaa = 0.0, kalmanAlong = 0.0, cross = 0.0
        for i in s.before.east.indices {
            func along(_ e: NavigationEngine) -> Double { e.east[i] * tx + e.north[i] * ty }
            func paa(_ e: NavigationEngine) -> Double { tx * tx * e.covEE[i] + 2 * tx * ty * e.covEN[i] + ty * ty * e.covNN[i] }
            schmidtAlong = max(schmidtAlong, abs(along(s.after) - along(s.before)))
            schmidtPaa = max(schmidtPaa, abs(paa(s.after) - paa(s.before)) / paa(s.before))
            kalmanAlong = max(kalmanAlong, abs(along(k.after) - along(k.before)))
            let c0 = s.before.east[i] * hx + s.before.north[i] * hy, c1 = s.after.east[i] * hx + s.after.north[i] * hy
            cross = max(cross, abs(c1 - c0))
        }
        #expect(cross > 1, "no cross-track update (\(cross) m)")
        #expect(schmidtAlong < 1e-9, "coupling 0 moved along-track by \(schmidtAlong) m")
        #expect(schmidtPaa < 1e-9, "coupling 0 moved P_aa by a relative \(schmidtPaa)")
        #expect(kalmanAlong > 1, "coupling 1 moved along-track by only \(kalmanAlong) m")
    }

    @Test("1. North–south road on the plane's meridian, coupling 0: a road update leaves north and P_nn bit-identical")
    func straightRoadAxisBitExact() throws {
        // The road is the meridian of the plane's anchor (longitude 0):
        // exactly east = 0 in the plane, so the road frame is the axes.
        let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 3000))])
        let config = Self.config(particles: 300) { $0.roadSplitSigmaM = 1000; $0.resampleESSFraction = 0 }
        var engine = NavigationEngine(config: config, roads: net)
        let p = S.plane.geodetic(east: 0, north: -500)
        engine.ingest(.manualFix(ManualFixSample(latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(0.05),
                                                 mapSpanM: 360, speedSource: "unknown"), at: S.ms(0.05)))
        var rng = NavigationRandom(seed: 9)
        for i in engine.east.indices {
            engine.east[i] = 20 * rng.nextGaussian()
            engine.north[i] = 300 * rng.nextGaussian()
            engine.covEE[i] = 100 + 50 * abs(rng.nextGaussian())
            engine.covNN[i] = 200 + 50 * abs(rng.nextGaussian())
            engine.covEN[i] = 30 * rng.nextGaussian()
            engine.heading[i] = rng.nextUniform() < 0.5 ? 0.01 * rng.nextGaussian() : .pi + 0.01 * rng.nextGaussian()
        }
        for _ in 0..<5 {
            var after = engine
            after.roadUpdate(evidenceDistanceM: 30)
            #expect(after.counters.roadUpdates == engine.counters.roadUpdates + 1)
            #expect(after.counters.resamples == engine.counters.resamples && after.counters.roadSplits == 0)
            #expect(after.north == engine.north)
            #expect(after.covNN == engine.covNN)
            #expect(after.east != engine.east && after.covEE != engine.covEE)
            engine = after
        }
    }

    @Test("Step 4 algebra: coupling 0 is Schmidt (P_aa, Δa unchanged); 1 is exact Kalman; between, Joseph form is PSD")
    func crossTrackAlgebra() {
        let (paa, pac, pcc, d, rw) = (400.0, 60.0, 225.0, 12.0, 49.0)
        let s = RoadMatcher.crossTrackUpdate(paa: paa, pac: pac, pcc: pcc, distance: d, rw: rw, coupling: 0)
        #expect(s.da == 0 && s.paa == paa)
        #expect(abs(s.dc - (-d * pcc / (pcc + rw))) < 1e-12)
        #expect(abs(s.pcc - pcc * rw / (pcc + rw)) < 1e-12)
        let k = RoadMatcher.crossTrackUpdate(paa: paa, pac: pac, pcc: pcc, distance: d, rw: rw, coupling: 1)
        let sw = pcc + rw
        #expect(abs(k.da - (-d * pac / sw)) < 1e-12)
        #expect(abs(k.paa - (paa - pac * pac / sw)) < 1e-9)
        #expect(abs(k.pac - (pac - pac * pcc / sw)) < 1e-9)
        // The Joseph form at coupling 1 equals the Kalman update.
        let j = RoadMatcher.crossTrackUpdate(paa: paa, pac: pac, pcc: pcc, distance: d, rw: rw, coupling: 1 - 1e-15)
        #expect(abs(j.paa - k.paa) < 1e-9 && abs(j.pac - k.pac) < 1e-9 && abs(j.pcc - k.pcc) < 1e-9)
        for c in [0.25, 0.5, 0.75] {
            let u = RoadMatcher.crossTrackUpdate(paa: paa, pac: pac, pcc: pcc, distance: d, rw: rw, coupling: c)
            #expect(u.paa >= 0 && u.pcc >= 0 && u.paa * u.pcc - u.pac * u.pac >= 0)
            #expect(u.paa <= paa && u.paa >= k.paa)
        }
    }

    /// Step 4's mixture with the off-road branch, against the closed form
    /// computed here: r = (1 − ε) L_road / ((1 − ε) L_road + ε / (2R · 2π)),
    /// the exact Kalman update (coupling 1) across a north–south road on
    /// the plane's meridian (road frame: along = north, across = east), then
    /// μ ← μ + r Δμ and P ← r P_upd + (1 − r) P + r (1 − r) Δμ Δμᵀ. ε 0.5
    /// and d 34 m put r near 0.5, so the spread term is ~130 m² on P_cc.
    @Test("Step 4: the road/off-road mixture is moment-matched, P = r·P_upd + (1 − r)·P + r(1 − r)·ΔμΔμᵀ")
    func momentMatching() throws {
        let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 3000))])
        let config = Self.config(particles: 10) {
            $0.roadSplitSigmaM = 1000; $0.resampleESSFraction = 0; $0.roadOffRoadProbability = 0.5; $0.roadAlongTrackCoupling = 1
        }
        var engine = NavigationEngine(config: config, roads: net)
        let p = S.plane.geodetic(east: 0, north: 0)
        engine.ingest(.manualFix(ManualFixSample(latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(0.05),
                                                 mapSpanM: 360, speedSource: "unknown"), at: S.ms(0.05)))
        let (d, pee, pen, pnn, psi) = (34.0, 100.0, 60.0, 400.0, 0.1)
        for i in engine.east.indices {
            engine.east[i] = d
            engine.north[i] = 0
            engine.covEE[i] = pee; engine.covEN[i] = pen; engine.covNN[i] = pnn
            engine.heading[i] = psi
            engine.roadEdge[i] = RoadMatcher.noEdge
            engine.roadLevel[i] = RoadGeometry.unknownLevel
        }
        var after = engine
        after.roadUpdate(evidenceDistanceM: 30)
        #expect(after.counters.roadUpdates == 1 && after.counters.roadSplits == 0)

        let c = engine.config
        let sr2 = c.roadSigmaM * c.roadSigmaM, sigmaPsi = c.roadHeadingSigmaDeg * .pi / 180
        let (paa, pac, pcc) = (pnn, pen, pee)
        let s0 = pcc + sr2
        let logL = -0.5 * d * d / s0 - 0.5 * log(s0) - 0.5 * (psi / sigmaPsi) * (psi / sigmaPsi) - log(2 * .pi * sigmaPsi)
        let eps = c.roadOffRoadProbability
        let on = (1 - eps) * exp(logL), off = eps / (2 * c.roadSearchRadiusM * 2 * .pi)
        let r = on / (on + off)
        #expect(r > 0.3 && r < 0.7, "r \(r)")
        // Kalman, w = 1: innovation −d across the road.
        let sw = pcc + sr2
        let da = -d * pac / sw, dc = -d * pcc / sw
        let uAA = paa - pac * pac / sw, uAC = pac - pac * pcc / sw, uCC = pcc - pcc * pcc / sw
        let mix = r * (1 - r)
        let expected = (east: d + r * dc, north: r * da,
                        ee: r * uCC + (1 - r) * pcc + mix * dc * dc,
                        en: r * uAC + (1 - r) * pac + mix * da * dc,
                        nn: r * uAA + (1 - r) * paa + mix * da * da)
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-6 * max(1, abs(b)) }
        for i in after.east.indices {
            #expect(close(after.east[i], expected.east) && close(after.north[i], expected.north),
                    "μ (\(after.east[i]), \(after.north[i])), expected (\(expected.east), \(expected.north))")
            #expect(close(after.covEE[i], expected.ee) && close(after.covEN[i], expected.en) && close(after.covNN[i], expected.nn),
                    "P (\(after.covEE[i]), \(after.covEN[i]), \(after.covNN[i])), expected \(expected)")
        }
    }

    /// The engine's random stream, read through reflection (it is private)
    /// so a test can replay the exact draws a road update will make.
    static func random(of engine: NavigationEngine) throws -> NavigationRandom {
        try #require(Mirror(reflecting: engine).children.first { $0.label == "rng" }?.value as? NavigationRandom,
                     "NavigationEngine has no stored `rng: NavigationRandom`")
    }

    /// R21.4-1: Step 1 on rotated, anisotropic Gaussians (σs 15 m).
    /// P = λ₁ v₁v₁ᵀ + λ₂ v₂v₂ᵀ with v₁ at θ from east (θ in (−90°, 90°],
    /// the engine's eigenvector convention; v₂ = v₁ turned +90°), so
    /// P_en ≠ 0. Per particle, cycling through: (A) only λ₁ > σs²;
    /// (B) both above; (C) neither, no split and no draw. Expected after
    /// the update: P = σs² v₁v₁ᵀ + (λ₂ or σs²) v₂v₂ᵀ and
    /// μ += v₁ √(λ₁ − σs²) z₁ (+ v₂ √(λ₂ − σs²) z₂ in B), with (z₁, z₂)
    /// from a copy of the engine's stream, one pair per split particle.
    /// Heading east across a north–south road: no candidate, so Steps 2–4
    /// leave μ and P as Step 1 left them.
    @Test("Step 1 split: rotated anisotropic P splits along its eigenvectors to σs (major only, or both axes); mean shift v·√(λ − σs²)·z")
    func splitGeometry() throws {
        let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 3000))])
        var engine = Self.directEngine(net, particles: 120) { $0.roadSplitSigmaM = 15 }
        Self.place(&engine, at: (20, 0), heading: .pi / 2)
        let s2 = 15.0 * 15.0
        // (θ°, λ₁, λ₂): A, B, C at +30°, then the same at −60° (a < c, P_en < 0).
        let cases: [(deg: Double, l1: Double, l2: Double, splits: Int)] = [
            (30, 1600, 100, 1), (30, 1600, 625, 2), (30, 200, 50, 0),
            (-60, 900, 64, 1), (-60, 2500, 400, 2), (-60, 220, 220, 0),
        ]
        func axes(_ deg: Double) -> (v1: (e: Double, n: Double), v2: (e: Double, n: Double)) {
            let t = deg * .pi / 180
            return ((cos(t), sin(t)), (-sin(t), cos(t)))
        }
        for i in engine.east.indices {
            let k = cases[i % cases.count], (v1, v2) = axes(k.deg)
            engine.covEE[i] = k.l1 * v1.e * v1.e + k.l2 * v2.e * v2.e
            engine.covEN[i] = k.l1 * v1.e * v1.n + k.l2 * v2.e * v2.n
            engine.covNN[i] = k.l1 * v1.n * v1.n + k.l2 * v2.n * v2.n
        }
        #expect(engine.covEN[0] > 100 && engine.covEN[3] < -100, "P_en \(engine.covEN[0]), \(engine.covEN[3])")

        var reference = try Self.random(of: engine)
        var after = engine
        after.roadUpdate(evidenceDistanceM: 30)
        let splitting = engine.east.indices.filter { cases[$0 % cases.count].splits > 0 }.count
        #expect(after.counters.roadUpdates == 1 && after.counters.roadSplits == splitting)
        // No candidate (r = 0 everywhere): Steps 2–4 moved nothing.
        #expect(after.roadEdge.allSatisfy { $0 == RoadMatcher.noEdge } && after.offRoadM.allSatisfy { $0 == 30 })

        func close(_ x: Double, _ y: Double) -> Bool { abs(x - y) <= 1e-9 * 2500 }
        for i in engine.east.indices {
            let k = cases[i % cases.count], (v1, v2) = axes(k.deg)
            guard k.splits > 0 else {
                #expect(after.east[i] == engine.east[i] && after.north[i] == engine.north[i], "particle \(i): no split")
                #expect(after.covEE[i] == engine.covEE[i] && after.covEN[i] == engine.covEN[i]
                        && after.covNN[i] == engine.covNN[i], "particle \(i): no split")
                continue
            }
            let (z1, z2) = reference.nextGaussianPair()
            let a1 = (k.l1 - s2).squareRoot() * z1
            let a2 = k.splits == 2 ? (k.l2 - s2).squareRoot() * z2 : 0
            let k2 = k.splits == 2 ? s2 : k.l2
            let mean = (e: engine.east[i] + v1.e * a1 + v2.e * a2, n: engine.north[i] + v1.n * a1 + v2.n * a2)
            #expect(close(after.east[i], mean.e) && close(after.north[i], mean.n),
                    "particle \(i) (\(k)): μ (\(after.east[i]), \(after.north[i])), expected \(mean)")
            let p = (ee: after.covEE[i], en: after.covEN[i], nn: after.covNN[i])
            func quad(_ x: (e: Double, n: Double), _ y: (e: Double, n: Double)) -> Double {
                x.e * y.e * p.ee + (x.e * y.n + x.n * y.e) * p.en + x.n * y.n * p.nn
            }
            #expect(close(quad(v1, v1), s2) && close(quad(v2, v2), k2) && close(quad(v1, v2), 0),
                    "particle \(i) (\(k)): v₁ᵀPv₁ \(quad(v1, v1)), v₂ᵀPv₂ \(quad(v2, v2)) (want \(k2)), v₁ᵀPv₂ \(quad(v1, v2))")
        }
        // Exactly one pair per split particle, and nothing else drawn.
        #expect(try Self.random(of: after) == reference)
    }

    /// `RoadMatcher.nearest` on a 10 m segment from a = (2, 3) along
    /// u = (0.6, 0.8); n = (−0.8, 0.6) is its left normal. h points from
    /// the nearest point towards p: ±n inside, (p − Q)/d at an end vertex
    /// — along the axis for a point on it, not the normal — and a normal
    /// when p is on the segment or exactly on a vertex.
    @Test("Step 2 geometry: nearest point and h, inside on both sides, before the start, past the end, on a vertex")
    func nearestPointAndDirection() {
        let (ax, ay, ux, uy, length) = (2.0, 3.0, 0.6, 0.8, 10.0)
        let (nx, ny) = (-uy, ux)
        func at(_ s: Double, _ c: Double) -> (Double, Double) { (ax + s * ux + c * nx, ay + s * uy + c * ny) }
        func check(_ p: (Double, Double), d2: Double, h: (Double, Double), _ label: String) {
            let r = RoadMatcher.nearest(px: p.0, py: p.1, ax: ax, ay: ay, ux: ux, uy: uy, length: length)
            #expect(abs(r.distanceSquared - d2) < 1e-9, "\(label): d² \(r.distanceSquared), expected \(d2)")
            #expect(abs(r.hx - h.0) < 1e-9 && abs(r.hy - h.1) < 1e-9, "\(label): h (\(r.hx), \(r.hy)), expected \(h)")
        }
        check(at(4, 3), d2: 9, h: (nx, ny), "inside, left")
        check(at(4, -3), d2: 9, h: (-nx, -ny), "inside, right")
        // On the segment (to rounding): either normal (d = 0, no innovation).
        let on = RoadMatcher.nearest(px: at(4, 0).0, py: at(4, 0).1, ax: ax, ay: ay, ux: ux, uy: uy, length: length)
        #expect(on.distanceSquared < 1e-18 && abs(abs(on.hx * nx + on.hy * ny) - 1) < 1e-12)
        check(at(-5, 0), d2: 25, h: (-ux, -uy), "before the start, on the axis")
        check(at(-3, 4), d2: 25, h: ((-3 * ux + 4 * nx) / 5, (-3 * uy + 4 * ny) / 5), "before the start, off the axis")
        check(at(15, 0), d2: 25, h: (ux, uy), "past the end, on the axis")
        check(at(13, -4), d2: 25, h: ((3 * ux - 4 * nx) / 5, (3 * uy - 4 * ny) / 5), "past the end, off the axis")
        check(at(0, 0), d2: 0, h: (nx, ny), "on the start vertex")
        check((ax + length * ux, ay + length * uy), d2: 0, h: (nx, ny), "on the end vertex")
    }

    /// The end-vertex h in a road update: particles 10 m past a dead end,
    /// on the road's axis, are pulled back along the axis (north) to the
    /// end; east is untouched. With h the segment normal they would move
    /// sideways.
    @Test("Step 4 past a dead end: the cross-track update pulls along the road's axis, not sideways")
    func deadEndPullsAlongAxis() throws {
        // Ends at (0, 0), on the plane's meridian: the axis is exactly east = 0.
        let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 0))])
        let config = Self.config(particles: 50) { $0.roadSplitSigmaM = 1000; $0.resampleESSFraction = 0 }
        var engine = NavigationEngine(config: config, roads: net)
        let p = S.plane.geodetic(east: 0, north: 0)
        engine.ingest(.manualFix(ManualFixSample(latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(0.05),
                                                 mapSpanM: 360, speedSource: "unknown"), at: S.ms(0.05)))
        for i in engine.east.indices {
            engine.east[i] = 0
            engine.north[i] = 10
            engine.covEE[i] = 25; engine.covEN[i] = 0; engine.covNN[i] = 25
            engine.heading[i] = 0
        }
        var after = engine
        after.roadUpdate(evidenceDistanceM: 30)
        #expect(after.counters.roadUpdates == 1)
        for i in after.east.indices {
            #expect(after.east[i] == 0, "particle \(i) moved sideways by \(after.east[i]) m")
            #expect(after.north[i] < 10 - 1, "particle \(i) not pulled back: north \(after.north[i])")
            #expect(after.covEE[i] == 25 && after.covNN[i] < 25)
        }
    }

    @Test("roadAlongTrackCoupling outside 0…1 is invalid, not clamped; the other road keys are clamped")
    func couplingValidation() {
        for bad in [-0.1, 1.5, Double.nan, .infinity] {
            var c = NavigationConfig()
            c.roadAlongTrackCoupling = bad
            #expect(c.invalidReason != nil, "\(bad)")
            #expect(c.validated().roadAlongTrackCoupling.bitPattern == bad.bitPattern)
        }
        for good in [0.0, 0.5, 1.0] {
            var c = NavigationConfig()
            c.roadAlongTrackCoupling = good
            #expect(c.invalidReason == nil)
        }
        #expect(NavigationConfig().invalidReason == nil)
        #expect(NavigationConfig().validated() == NavigationConfig())
        var c = NavigationConfig()
        c.roadUpdateIntervalS = 0.01
        c.roadOffRoadProbability = 1.5
        c.roadSigmaM = -1
        c.roadSearchRadiusM = 80
        let v = c.validated()
        #expect(v.roadUpdateIntervalS == 0.1)
        #expect(v.roadOffRoadProbability < 1 && v.roadOffRoadProbability > 0.99)
        #expect(v.roadSigmaM == 7)
        #expect(v.roadSearchRadiusM == 80)
        c.roadUpdateIntervalS = -3
        #expect(c.validated().roadUpdateIntervalS == 0)
    }

    /// R21.1-7: `--set roadUpdateIntervalS=1e10` used to trap in the
    /// engine's `Int64` nanosecond interval. Clamped to an hour now, and an
    /// engine with roads accepts it.
    @Test("roadUpdateIntervalS is clamped above to maxRoadUpdateIntervalS; an engine with 1e10 s starts")
    func intervalUpperClamp() throws {
        var c = NavigationConfig()
        c.roadUpdateIntervalS = NavigationConfig.maxRoadUpdateIntervalS
        #expect(c.validated().roadUpdateIntervalS == NavigationConfig.maxRoadUpdateIntervalS)
        for huge in [1e10, 1e300, Double.greatestFiniteMagnitude] {
            c.roadUpdateIntervalS = huge
            #expect(c.validated().roadUpdateIntervalS == NavigationConfig.maxRoadUpdateIntervalS, "\(huge)")
        }
        let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 3000))])
        let engine = NavigationEngine(config: Self.config(particles: 10) { $0.roadUpdateIntervalS = 1e10 }, roads: net)
        #expect(engine.config.roadUpdateIntervalS == NavigationConfig.maxRoadUpdateIntervalS)
    }

    @Test("roadSearchRadiusM is clamped to the pack's guaranteed radius")
    func radiusClampedToPack() throws {
        let net = try Self.network([Self.street(1, from: (0, 0), to: (0, 100))])
        var c = NavigationConfig()
        c.roadSearchRadiusM = 80
        #expect(NavigationEngine(config: c, roads: net).config.roadSearchRadiusM == 50)
        #expect(NavigationEngine(config: c).config.roadSearchRadiusM == 80)
    }

    // MARK: 2. Car park / outside the pack: exact no-op

    /// A 60 s loop around a car park 300 m from the only road, with clean
    /// fixes at first; then a stretch outside the pack.
    @Test("2. A car park 300 m from any road, and a drive outside the pack: bit-identical to no roads")
    func carParkIsNoOp() throws {
        let net = try Self.network([Self.street(1, from: (-300, 300), to: (300, 300))])
        let drive = S(initialHeadingDeg: 90, initialSpeed: 4, [
            .straight(seconds: 10, speed: 4), .turn(degrees: 180, seconds: 10, speed: 4),
            .straight(seconds: 10, speed: 4), .turn(degrees: 180, seconds: 10, speed: 4),
            .straight(seconds: 20, speed: 8),
        ])
        let clean = S.cleanFix()
        for offset in [(east: -20.0, north: 0.0), (east: 0, north: -100_000)] {
            let inputs = Self.shifted(drive, by: offset, fix: { t, s, r in t < 15 ? clean(t, s, &r) : nil }, gyroNoise: 0.002)
            let config = Self.config(particles: 300)
            let a = Self.run(inputs, config: config, roads: nil, every: 1)
            let b = Self.run(inputs, config: config, roads: net, every: 1)
            #expect(Self.state(a.engine) == Self.state(b.engine))
            #expect(a.estimates.map(\.latitude) == b.estimates.map(\.latitude))
            #expect(b.engine.counters.roadUpdates == 0)
            #expect(b.engine.counters.roadUpdatesNoRoad > 30, "\(offset)")
            #expect(b.estimates.last?.onRoadShare == 0 && b.estimates.last?.matchedEdge == nil)
            #expect(a.estimates.last?.onRoadShare == nil)
            // R21.2-1: a no-road attempt keeps Δs counting. Reference: one
            // attempt only (interval 10⁶ s) sums the same steps in the same
            // order, so Δs is bit-identical; and close to the OBD distance
            // (40 s at 14 km/h, 20 s at 28 km/h, each + 0.5).
            let once = Self.run(inputs, config: Self.config(particles: 300) { $0.roadUpdateIntervalS = 1e6 }, roads: net)
            #expect(b.engine.roadDistanceM == once.engine.roadDistanceM, "\(offset)")
            let obd = 40 * 14.5 / 3.6 + 20 * 28.5 / 3.6
            #expect(abs(b.engine.roadDistanceM - obd) < 0.03 * obd, "\(offset): Δs \(b.engine.roadDistanceM) m, OBD \(obd) m")
        }
    }

    @Test("2. roadUpdateIntervalS 0 with a pack loaded runs no road code: bit-identical, every road counter 0")
    func intervalZeroIsNoOp() throws {
        let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 3000))])
        let inputs = Self.shifted(Self.northDrive(seconds: 30), by: (5, -500), fix: S.cleanFix())
        let config = Self.config(particles: 200) { $0.roadUpdateIntervalS = 0 }
        let a = Self.run(inputs, config: config, roads: nil)
        let b = Self.run(inputs, config: config, roads: net)
        #expect(Self.state(a.engine) == Self.state(b.engine))
        #expect(b.engine.counters == a.engine.counters)
        #expect(b.engine.estimate(at: S.ms(30))?.onRoadShare == nil)
    }

    // MARK: 3. A road missing from OSM: NavigationRoadOffRoadTests (known issue)

    // MARK: 4. A 15° fork

    /// A road north to a fork at (0, 0), then two branches 15° apart; the
    /// car takes the right one by gyro yaw. Heading known, position from a
    /// pin σ 30 m at the start; no fixes.
    @Test("4. A 15° Y-fork: both branches populated before the split, the right one wins after 300 m, never forced")
    func yFork() throws {
        let half = 7.5 * Double.pi / 180
        let length = 1500.0
        let net = try Self.network([
            RoadFixture.way(1, ["highway": "residential"], [N(id: 10, east: 0, north: -1000), N(id: 11, east: 0, north: 0)]),
            RoadFixture.way(2, ["highway": "residential"], [N(id: 11, east: 0, north: 0), N(id: 12, east: -sin(half) * length, north: cos(half) * length)]),
            RoadFixture.way(3, ["highway": "residential"], [N(id: 11, east: 0, north: 0), N(id: 13, east: sin(half) * length, north: cos(half) * length)]),
        ])
        let v = 12.0
        // 250 m to the fork, a 7.5° right turn over 2 s, then 500 m.
        let drive = S(initialHeadingDeg: 0, initialSpeed: v, [
            .straight(seconds: 250 / v, speed: v), .turn(degrees: 7.5, seconds: 2, speed: v), .straight(seconds: 500 / v, speed: v),
        ])
        let inputs = Self.shifted(drive, by: (0, -250), fix: { _, _, _ in nil },
                                  extra: [Self.pin(at: 0.2, east: 0, north: -250 + 0.2 * v, span: 360, kmh: nil)], gyroNoise: 0.0005)
        var engine = NavigationEngine(config: Self.config(particles: 2000) { $0.roadPinAnchorMinKmh = 0 }, roads: net)
        var initialized = false
        let leftEdge = UInt32(try #require(RoadFixture.edgeIndices(of: net.packs[0], way: 2).first))
        let rightEdge = UInt32(try #require(RoadFixture.edgeIndices(of: net.packs[0], way: 3).first))
        var sharesAt100: (Double, Double)?, maxMatched: Set<Int64> = []
        for input in inputs {
            engine.ingest(input)
            if !initialized, engine.isInitialized {
                initialized = true
                for i in engine.heading.indices { engine.heading[i] = 0 }
            }
            guard initialized else { continue }
            let t = input.arrival.seconds
            let along = drive.truth(at: t).north - 250 // past the fork, roughly
            let share = { (edge: UInt32) in
                zip(engine.roadEdge, engine.weight).reduce(0.0) { $0 + ($1.0 == edge ? $1.1 : 0) }
            }
            if sharesAt100 == nil, along > -8 { sharesAt100 = (share(leftEdge), share(rightEdge)) }
            if let m = engine.estimate(at: input.arrival)?.matchedEdge { maxMatched.insert(m.osmWayID) }
        }
        let early = try #require(sharesAt100)
        // Just before the turn both branches hold particles: only the gyro
        // yaw at the fork can tell them apart.
        #expect(early.0 > 0.1 && early.1 > 0.1, "at the fork: left \(early.0), right \(early.1)")
        let left = zip(engine.roadEdge, engine.weight).reduce(0.0) { $0 + ($1.0 == leftEdge ? $1.1 : 0) }
        let right = zip(engine.roadEdge, engine.weight).reduce(0.0) { $0 + ($1.0 == rightEdge ? $1.1 : 0) }
        #expect(right > 0.9, "500 m past the fork: right \(right), left \(left)")
        #expect(engine.estimate(at: S.ms(drive.duration))?.matchedEdge?.osmWayID == 3)
        #expect(engine.counters.manualResets == 0)
    }

    // MARK: 5. A stacked bridge

    @Test("5. Stacked bridge: the car on the street below is never matched to the bridge; a car via the ramp is")
    func stackedBridge() throws {
        let net = try RoadNetwork(packs: [RoadFixture.build(RoadGraphTests.bridgeLines())])
        let pack = net.packs[0]
        let bridge = UInt32(try #require(RoadFixture.edgeIndices(of: pack, way: 101).first))
        let ramp = try #require(RoadFixture.edgeIndices(of: pack, way: 102).first)
        let v = 10.0
        // Below: east along the street y = 0, from x = −250 to 150, under
        // the north–south bridge at x = 0. Bridge-aligned heading never
        // matters here; the level rule must block the bridge once the car is
        // on the street (level 0), since they share no node.
        do {
            let drive = S(initialHeadingDeg: 90, initialSpeed: v, [.straight(seconds: 40, speed: v)])
            let clean = S.cleanFix()
            let inputs = Self.shifted(drive, by: (-250, 0), fix: { t, s, r in t < 8 ? clean(t, s, &r) : nil })
            // A wide heading gate: the bridge crosses at 90°, so without
            // the level rule it is a candidate right at the crossing.
            let config = Self.config(particles: 500) { $0.roadHeadingGateDeg = 180; $0.roadHeadingSigmaDeg = 1000 }
            var engine = NavigationEngine(config: config, roads: net)
            var everOnBridge = 0.0
            for input in inputs {
                engine.ingest(input)
                let s = zip(engine.roadEdge, engine.weight).reduce(0.0) { $0 + ($1.0 == bridge ? $1.1 : 0) }
                everOnBridge = max(everOnBridge, s)
            }
            #expect(engine.counters.roadLevelBlocked > 0)
            #expect(everOnBridge < 0.01, "share on the bridge \(everOnBridge)")
        }
        // Via the ramp: a car on the ramp (level 0, one hop from the
        // bridge) drives onto the bridge southward and is matched to it.
        do {
            let rampPoints = RoadFixture.points(of: pack, edge: ramp).map(RoadFixture.metres)
            // Ramp runs (0, 300) → (150, 150) → (200, 0); drive it backwards
            // from (150, 150) to (0, 300), then south on the bridge.
            let a = rampPoints[1], b = rampPoints[0]
            let leg = ((b.east - a.east) * (b.east - a.east) + (b.north - a.north) * (b.north - a.north)).squareRoot()
            let bearing = RoadGeometry.bearing(east: b.east - a.east, north: b.north - a.north) * 180 / .pi
            let turn = angleDifference(180, bearing)
            let drive = S(initialHeadingDeg: bearing, initialSpeed: v, [
                .straight(seconds: leg / v, speed: v), .turn(degrees: turn, seconds: 1, speed: v), .straight(seconds: 20, speed: v),
            ])
            let clean = S.cleanFix()
            let inputs = Self.shifted(drive, by: (a.east, a.north), fix: { t, s, r in t < 8 ? clean(t, s, &r) : nil })
            var engine = NavigationEngine(config: Self.config(particles: 500), roads: net)
            for input in inputs { engine.ingest(input) }
            let s = zip(engine.roadEdge, engine.weight).reduce(0.0) { $0 + ($1.0 == bridge ? $1.1 : 0) }
            #expect(s > 0.8, "share on the bridge after the ramp: \(s)")
            #expect(engine.estimate(at: S.ms(drive.duration))?.matchedEdge?.osmWayID == 101)
        }
    }

    /// The level rule's hops, directly: particles on the ramp (level 0,
    /// one hop from the bridge) and on the street under it (level 0, three
    /// hops), all at the crossing point with the bridge's heading. The
    /// bridge (level 1) is a candidate for the ramp particles only.
    @Test("5. Level rule: the bridge is eligible from its ramp (1 hop), blocked from the street below (3 hops > 2)")
    func levelRuleHops() throws {
        let net = try RoadNetwork(packs: [RoadFixture.build(RoadGraphTests.bridgeLines())])
        let pack = net.packs[0]
        let bridge = UInt32(try #require(RoadFixture.edgeIndices(of: pack, way: 101).first))
        let ramp = UInt32(try #require(RoadFixture.edgeIndices(of: pack, way: 102).first))
        let crossing = UInt32(RoadFixture.edgeIndices(of: pack, way: 100)[0])
        let config = Self.config(particles: 100) { $0.roadSplitSigmaM = 1000; $0.resampleESSFraction = 0 }
        var engine = NavigationEngine(config: config, roads: net)
        let p = S.plane.geodetic(east: 0, north: 100)
        engine.ingest(.manualFix(ManualFixSample(latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(0.05),
                                                 mapSpanM: 360, speedSource: "unknown"), at: S.ms(0.05)))
        for i in engine.east.indices {
            // On the bridge's line, 100 m north of the street: no street
            // candidate within the gate there (the street is 100 m south).
            engine.east[i] = 2
            engine.north[i] = 100
            engine.covEE[i] = 25; engine.covEN[i] = 0; engine.covNN[i] = 25
            engine.heading[i] = 0
            engine.roadLevel[i] = 0
            engine.roadEdge[i] = i % 2 == 0 ? ramp : crossing
        }
        var after = engine
        after.roadUpdate(evidenceDistanceM: 30)
        #expect(after.counters.roadUpdates == 1)
        #expect(after.counters.roadLevelBlocked == 50)
        for i in after.east.indices {
            if i % 2 == 0 {
                #expect(after.roadEdge[i] == bridge && after.roadLevel[i] == 1, "ramp particle \(i)")
            } else {
                #expect(after.roadEdge[i] == crossing && after.roadLevel[i] == 0, "street particle \(i)")
            }
        }
    }

    /// R21.3-4: the level rule's boundary, `roadLevelHops` itself. The
    /// street's middle edge (x 60…200) meets the ramp at x = 200, and the
    /// ramp meets the bridge: the bridge is exactly 2 hops from it (and 3
    /// from the crossing edge under the bridge). Particles as in
    /// `levelRuleHops`, even on the middle edge, odd on the crossing one.
    /// Hops 2 (default): exactly 2 admits, 3 blocks. Hops 1: both blocked.
    /// Hops 3: both admitted.
    @Test("5. Level rule boundary: a bridge exactly roadLevelHops away is admitted, one hop further is blocked (hops 1, 2, 3)")
    func levelRuleHopBoundary() throws {
        let net = try RoadNetwork(packs: [RoadFixture.build(RoadGraphTests.bridgeLines())])
        let pack = net.packs[0]
        let bridge = try #require(RoadFixture.edgeIndices(of: pack, way: 101).first)
        let street = RoadFixture.edgeIndices(of: pack, way: 100)
        let crossing = street[0]
        let middle = try #require(street.first { e in
            let xs = RoadFixture.points(of: pack, edge: e).map { RoadFixture.metres($0).east }
            return abs(xs.min()! - 60) < 1 && abs(xs.max()! - 200) < 1
        })
        #expect(pack.isEdge(bridge, withinHops: 2, of: middle) && !pack.isEdge(bridge, withinHops: 1, of: middle))
        #expect(pack.isEdge(bridge, withinHops: 3, of: crossing) && !pack.isEdge(bridge, withinHops: 2, of: crossing))
        for (hops, middleAdmitted, crossingAdmitted) in [(2, true, false), (1, false, false), (3, true, true)] {
            var engine = Self.directEngine(net) { $0.roadLevelHops = hops }
            #expect(engine.config.roadLevelHops == hops)
            Self.place(&engine, at: (2, 100), heading: 0, level: 0)
            for i in engine.roadEdge.indices { engine.roadEdge[i] = UInt32(i % 2 == 0 ? middle : crossing) }
            engine.roadUpdate(evidenceDistanceM: 30)
            #expect(engine.counters.roadUpdates == 1, "hops \(hops)")
            let blocked = (middleAdmitted ? 0 : 50) + (crossingAdmitted ? 0 : 50)
            #expect(engine.counters.roadLevelBlocked == blocked, "hops \(hops)")
            for i in engine.east.indices {
                let (admitted, own) = i % 2 == 0 ? (middleAdmitted, middle) : (crossingAdmitted, crossing)
                if admitted {
                    #expect(engine.roadEdge[i] == UInt32(bridge) && engine.roadLevel[i] == 1, "hops \(hops), particle \(i)")
                } else {
                    #expect(engine.roadEdge[i] == UInt32(own) && engine.roadLevel[i] == 0, "hops \(hops), particle \(i)")
                }
            }
        }
    }

    /// The particles of `engine` (initialised at the plane origin) all at
    /// plane point `at` with P = 25·I and `heading`, on `edge` at `level`
    /// (any of them may be overridden per particle afterwards).
    static func place(_ engine: inout NavigationEngine, at p: (east: Double, north: Double), heading: Double,
                      edge: UInt32 = RoadMatcher.noEdge, level: Int8 = RoadGeometry.unknownLevel) {
        for i in engine.east.indices {
            engine.east[i] = p.east
            engine.north[i] = p.north
            engine.covEE[i] = 25; engine.covEN[i] = 0; engine.covNN[i] = 25
            engine.heading[i] = heading
            engine.roadEdge[i] = edge
            engine.roadLevel[i] = level
            engine.offRoadM[i] = 0
        }
    }

    /// An engine with roads, initialised by a pin at the plane origin
    /// (S.plane), no Step 1 split and no resampling.
    static func directEngine(_ net: RoadNetwork, particles: Int = 100,
                             _ edit: (inout NavigationConfig) -> Void = { _ in }) -> NavigationEngine {
        let config = Self.config(particles: particles) {
            $0.roadSplitSigmaM = 1000; $0.resampleESSFraction = 0
            edit(&$0)
        }
        var engine = NavigationEngine(config: config, roads: net)
        let p = S.plane.geodetic(east: 0, north: 0)
        engine.ingest(.manualFix(ManualFixSample(latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(0.05),
                                                 mapSpanM: 360, speedSource: "unknown"), at: S.ms(0.05)))
        return engine
    }

    /// R21.2-2: level forgetting. Particles on the street under the bridge
    /// (level 0, 3 hops from it), on the bridge's line 100 m north of the
    /// street. Heading east, the bridge (north–south) is outside the
    /// heading gate and nothing else is within R: a road update with no
    /// candidate, which adds Δs = 30 m off-road. 71 + 30 > 100 forgets the
    /// level; 70 + 30 = 100 does not (strictly past `roadLevelForgetM`).
    /// Then heading north: the forgotten particles take the bridge, the
    /// others are still blocked by the level rule.
    @Test("5. Level forgetting: past roadLevelForgetM off-road the level is unknown (at exactly it, still known), and the bridge it blocked becomes a candidate")
    func levelForgetting() throws {
        let net = try RoadNetwork(packs: [RoadFixture.build(RoadGraphTests.bridgeLines())])
        let pack = net.packs[0]
        let bridge = UInt32(try #require(RoadFixture.edgeIndices(of: pack, way: 101).first))
        let crossing = UInt32(RoadFixture.edgeIndices(of: pack, way: 100)[0])
        var engine = Self.directEngine(net)
        #expect(engine.config.roadLevelForgetM == 100 && engine.config.roadLevelHops == 2)
        #expect(!pack.isEdge(Int(bridge), withinHops: 2, of: Int(crossing)))
        Self.place(&engine, at: (2, 100), heading: .pi / 2, edge: crossing, level: 0)
        for i in engine.offRoadM.indices { engine.offRoadM[i] = i % 2 == 0 ? 71 : 70 }

        var off = engine
        off.roadUpdate(evidenceDistanceM: 30)
        #expect(off.counters.roadUpdates == 1 && off.counters.roadLevelBlocked == 0)
        for i in off.east.indices {
            #expect(off.roadEdge[i] == crossing && off.east[i] == 2, "particle \(i): no candidate")
            if i % 2 == 0 {
                #expect(off.offRoadM[i] == 101 && off.roadLevel[i] == RoadGeometry.unknownLevel, "particle \(i) forgets")
            } else {
                #expect(off.offRoadM[i] == 100 && off.roadLevel[i] == 0, "particle \(i) keeps its level")
            }
        }

        for i in off.heading.indices { off.heading[i] = 0 }
        var on = off
        on.roadUpdate(evidenceDistanceM: 30)
        #expect(on.counters.roadUpdates == 2)
        #expect(on.counters.roadLevelBlocked == 50)
        for i in on.east.indices {
            if i % 2 == 0 {
                #expect(on.roadEdge[i] == bridge && on.roadLevel[i] == 1 && on.offRoadM[i] == 0, "particle \(i)")
            } else {
                // Blocked, so off-road again: 130 m now forgets its level.
                #expect(on.roadEdge[i] == crossing && on.offRoadM[i] == 130, "particle \(i)")
                #expect(on.roadLevel[i] == RoadGeometry.unknownLevel, "particle \(i)")
            }
        }

        // Control: with the level still known, every particle is blocked.
        var known = engine
        for i in known.heading.indices { known.heading[i] = 0 }
        known.roadUpdate(evidenceDistanceM: 30)
        #expect(known.counters.roadLevelBlocked == 100)
        #expect(known.roadEdge.allSatisfy { $0 == crossing })
    }

    /// R21.2-4: two packs on one grid. Pack 0: seven separate streets far
    /// east (7 edges); pack 1: the stacked bridge (6 edges), so pack 1's
    /// global edges start at 7. Particles are matched in either pack; the
    /// estimate's edge names the pack, the local edge and the way. The
    /// level rule finds adjacency within a pack only: the pack-0 edge with
    /// the ramp's local index does not admit the bridge, the ramp does.
    @Test("Two packs: global edges offset by edgeBase; matchedEdge names pack, local edge and way; no level adjacency across packs")
    func twoPacks() throws {
        let streets = (1...7).map { k in
            Self.street(Int64(k), from: (900 + 100 * Double(k), -500), to: (900 + 100 * Double(k), 500))
        }
        let pack0 = try RoadFixture.build(streets)
        let pack1 = try RoadFixture.build(RoadGraphTests.bridgeLines(idOffset: 1000))
        let net = try RoadNetwork(packs: [pack0, pack1])
        #expect(pack0.edgeCount == 7 && pack1.edgeCount == 6)
        let matcher = RoadMatcher(network: net)
        #expect(matcher.edgeBase == [0, 7, 13])
        try #require(matcher.pack(ofEdge: 0) == 0)
        try #require(matcher.pack(ofEdge: 6) == 0)
        try #require(matcher.pack(ofEdge: 7) == 1)
        try #require(matcher.pack(ofEdge: 12) == 1)
        let bridgeLocal = try #require(RoadFixture.edgeIndices(of: pack1, way: 1101).first)
        let rampLocal = try #require(RoadFixture.edgeIndices(of: pack1, way: 1102).first)
        let sideLocal = try #require(RoadFixture.edgeIndices(of: pack1, way: 1103).first)
        let street1 = try #require(RoadFixture.edgeIndices(of: pack0, way: 1).first)
        let bridge = UInt32(7 + bridgeLocal), ramp = UInt32(7 + rampLocal)
        #expect(matcher.matchedEdge(bridge) == MatchedRoadEdge(pack: 1, edge: bridgeLocal, osmWayID: 1101))
        #expect(matcher.matchedEdge(UInt32(street1)) == MatchedRoadEdge(pack: 0, edge: street1, osmWayID: 1))
        // A pack-blind lookup would admit the bridge from local edge
        // `rampLocal` of pack 0: in pack 1 that index is the ramp, one hop.
        #expect(pack1.isEdge(bridgeLocal, withinHops: 2, of: rampLocal))
        #expect(pack0.edge(rampLocal).level == 0 && pack1.edge(bridgeLocal).level == 1)
        #expect(matcher.isEdge(bridge, withinHops: 2, of: ramp))
        #expect(!matcher.isEdge(bridge, withinHops: 2, of: UInt32(rampLocal)))

        // Level: on the bridge's line heading north, all on level 0; even
        // particles on the ramp (pack 1), odd on pack 0's edge `rampLocal`.
        var engine = Self.directEngine(net)
        Self.place(&engine, at: (2, 100), heading: 0, level: 0)
        for i in engine.roadEdge.indices { engine.roadEdge[i] = i % 2 == 0 ? ramp : UInt32(rampLocal) }
        var level = engine
        level.roadUpdate(evidenceDistanceM: 30)
        #expect(level.counters.roadUpdates == 1 && level.counters.roadLevelBlocked == 50)
        for i in level.east.indices {
            if i % 2 == 0 {
                #expect(level.roadEdge[i] == bridge && level.roadLevel[i] == 1, "ramp particle \(i)")
            } else {
                #expect(level.roadEdge[i] == UInt32(rampLocal) && level.roadLevel[i] == 0, "pack-0 particle \(i)")
            }
        }
        #expect(level.estimate(at: S.ms(0.05))?.matchedEdge == MatchedRoadEdge(pack: 1, edge: bridgeLocal, osmWayID: 1101))

        // Matched in pack 1 (the side street, x = 60) and in pack 0 (x = 1000).
        for (p, global, expected) in [
            ((62.0, -100.0), UInt32(7 + sideLocal), MatchedRoadEdge(pack: 1, edge: sideLocal, osmWayID: 1103)),
            ((1002.0, 0.0), UInt32(street1), MatchedRoadEdge(pack: 0, edge: street1, osmWayID: 1)),
        ] {
            var e = engine
            Self.place(&e, at: p, heading: 0)
            e.roadUpdate(evidenceDistanceM: 30)
            #expect(e.roadEdge.allSatisfy { $0 == global }, "\(p)")
            #expect(e.estimate(at: S.ms(0.05))?.matchedEdge == expected, "\(p)")
        }
    }

    /// R21.3-5: `RoadMatcher.storeIndices` on both paths. Cells [A, F, A, C]
    /// map to store indices [0, 1, 0, 2] (first-appearance order, a repeat
    /// reuses its index), and each store slice holds exactly that cell's
    /// segments in the plane. F is 150 cells east and north of A, so the
    /// bounding box (151 × 151 > 128 × 128) takes the dictionary fallback;
    /// with F 78 cells away it takes the dense window. A, F and C each hold
    /// a different street.
    @Test("RoadMatcher.storeIndices: first-appearance indices and per-cell slices, on the dense window and the dictionary fallback")
    func storeIndicesBothPaths() throws {
        let net = try Self.network([
            Self.street(1, from: (0, -100), to: (0, 100)),
            Self.street(2, from: (9600, 9500), to: (9600, 9700)),
            Self.street(3, from: (5000, 4900), to: (5000, 5100)),
            Self.street(4, from: (-300, 100), to: (-300, 300)),
        ])
        var matcher = RoadMatcher(network: net)
        let plane = S.plane
        let a = matcher.cell(east: 0, north: 0, plane: plane)
        let c = matcher.cell(east: -300, north: 200, plane: plane)
        for (far, fallback) in [((9600.0, 9600.0), true), ((5000.0, 5000.0), false)] {
            let f = matcher.cell(east: far.0, north: far.1, plane: plane)
            let cells = [a, f, a, c]
            let xs = cells.map { Int64($0.cx) }, ys = cells.map { Int64($0.cy) }
            let box = (xs.max()! - xs.min()! + 1) * (ys.max()! - ys.min()! + 1)
            #expect((box > Int64(RoadMatcher.maxWindowCells)) == fallback, "box \(box) cells")
            matcher.beginUpdate()
            #expect(matcher.storeIndices(of: cells, plane: plane) == [0, 1, 0, 2], "fallback \(fallback)")
            let store = matcher.store
            #expect(store.start.count == 4, "fallback \(fallback)")
            var ways: [Set<Int64>] = []
            for (k, cell) in [a, f, c].enumerated() {
                let expected = matcher.planeCell(cx: cell.cx, cy: cell.cy, plane: plane)
                let r = store.start[k]..<store.start[k + 1]
                #expect(expected.count > 0 && r.count == expected.count, "fallback \(fallback), cell \(k)")
                #expect(Array(store.cells.ax[r]) == expected.ax && Array(store.cells.ay[r]) == expected.ay)
                #expect(Array(store.cells.ux[r]) == expected.ux && Array(store.cells.uy[r]) == expected.uy)
                #expect(Array(store.cells.length[r]) == expected.length && Array(store.cells.edge[r]) == expected.edge)
                #expect(Array(store.cells.oneway[r]) == expected.oneway && Array(store.cells.level[r]) == expected.level)
                #expect(Array(store.cells.way[r]) == expected.way && Array(store.cells.index[r]) == expected.index)
                ways.append(Set(expected.way))
            }
            #expect(ways == [[1], [fallback ? 2 : 3], [4]], "fallback \(fallback)")
        }
    }

    /// Step 5's threshold on r itself, not on "a candidate exists": the odd
    /// particles have a candidate (20 m off, P_cc 4: d² = 400 ≤ χ² · S₀ =
    /// 9 · 53) but ε 0.9 makes L_off = ε / (2R · 2π) ≈ 1.4e-3 larger than
    /// (1 − ε) L_road ≈ 2.9e-4 there, so 0 < r ≈ 0.17 < 0.5; at 1 m,
    /// r ≈ 0.9. Each particle's r is read back from its cross-track move,
    /// r · g · d with g = P_cc / (P_cc + σr²) (no split, coupling 0).
    @Test("4. Step 5: a particle takes e* only with responsibility ≥ 0.5; with a candidate but r < 0.5 it keeps its edge and adds Δs off-road")
    func bookkeepingThreshold() throws {
        let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 3000))])
        let edge = UInt32(0)
        let config = Self.config(particles: 100) {
            $0.roadSplitSigmaM = 1000; $0.resampleESSFraction = 0; $0.roadOffRoadProbability = 0.9
        }
        var engine = NavigationEngine(config: config, roads: net)
        let p = S.plane.geodetic(east: 0, north: 0)
        engine.ingest(.manualFix(ManualFixSample(latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(0.05),
                                                 mapSpanM: 360, speedSource: "unknown"), at: S.ms(0.05)))
        let (near, far) = (1.0, 20.0)
        for i in engine.east.indices {
            engine.east[i] = i % 2 == 0 ? near : far
            engine.north[i] = 0
            engine.covEE[i] = 4; engine.covEN[i] = 0; engine.covNN[i] = 4
            engine.heading[i] = 0
            engine.roadEdge[i] = RoadMatcher.noEdge
            engine.offRoadM[i] = 10
        }
        var after = engine
        after.roadUpdate(evidenceDistanceM: 30)
        #expect(after.counters.roadUpdates == 1 && after.counters.roadSplits == 0)
        let gain = 4 / (4 + engine.config.roadSigmaM * engine.config.roadSigmaM)
        for i in after.east.indices {
            let d = i % 2 == 0 ? near : far
            let r = (engine.east[i] - after.east[i]) / (gain * d)
            if i % 2 == 0 {
                #expect(r >= 0.5 && r < 1, "particle \(i): r \(r)")
                #expect(after.roadEdge[i] == edge && after.offRoadM[i] == 0)
            } else {
                // A candidate existed (the mean moved towards the road), with r < 0.5.
                #expect(r > 0.05 && r < 0.5, "particle \(i): r \(r)")
                #expect(after.roadEdge[i] == RoadMatcher.noEdge && after.offRoadM[i] == 40)
            }
        }
        #expect((after.estimate(at: S.ms(0.05))?.onRoadShare ?? 0) > 0)
    }

    /// R21.2-3: Step 2's χ² innovation gate. P = 25·I, heading along the
    /// road (x = 0, north), Δs = 30 m (weight 1): S₀ = 25 + σr² = 74, gate
    /// d² ≤ 9 · 74 = 666, so 24 m (576) is inside and 28 m (784) outside,
    /// both within R. Closed form, dψ = 0: L_road = exp(−d²/2S₀) / √S₀ /
    /// (2π σψ), L_off = ε / (2R · 2π), r = (1 − ε) L_road / ((1 − ε) L_road
    /// + L_off). The 28 m particle would have r ≥ 0.5 without the gate;
    /// with it, it has no candidate at all.
    @Test("Step 2 χ² gate: P = 25·I, 24 m off is a candidate and moves r·g·d across; 28 m off is not (r ≥ 0.5 without the gate)")
    func innovationGate() throws {
        let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 3000))])
        var engine = Self.directEngine(net)
        let c = engine.config
        let (inside, outside) = (24.0, 28.0)
        Self.place(&engine, at: (0, 0), heading: 0)
        for i in engine.east.indices {
            engine.east[i] = i % 2 == 0 ? inside : outside
            engine.offRoadM[i] = 10
        }
        let s0 = 25 + c.roadSigmaM * c.roadSigmaM
        let gate = c.roadInnovationGateChi2 * s0
        #expect(inside * inside <= gate && outside * outside > gate && outside < c.roadSearchRadiusM)
        let epsilon = c.roadOffRoadProbability
        let offRoad = epsilon / (2 * c.roadSearchRadiusM * 2 * .pi)
        func onRoad(_ d: Double) -> Double {
            (1 - epsilon) * exp(-0.5 * d * d / s0) / s0.squareRoot() / (2 * .pi * c.roadHeadingSigmaDeg * .pi / 180)
        }
        func r(_ d: Double) -> Double { onRoad(d) / (onRoad(d) + offRoad) }
        #expect(r(outside) >= 0.5, "without the gate, r at \(outside) m = \(r(outside))")

        var after = engine
        after.roadUpdate(evidenceDistanceM: 30)
        #expect(after.counters.roadUpdates == 1 && after.counters.roadSplits == 0)
        let g = 25 / s0
        for i in after.east.indices {
            if i % 2 == 0 {
                let expected = inside - r(inside) * g * inside
                #expect(abs(after.east[i] - expected) < 1e-9, "particle \(i): \(after.east[i]), expected \(expected)")
                #expect(after.roadEdge[i] == 0 && after.offRoadM[i] == 0, "particle \(i)")
            } else {
                #expect(after.east[i] == outside && after.covEE[i] == 25 && after.covEN[i] == 0 && after.covNN[i] == 25,
                        "particle \(i)")
                #expect(after.roadEdge[i] == RoadMatcher.noEdge && after.offRoadM[i] == 40, "particle \(i)")
            }
        }
        // Weights: L = (1 − ε) L_road + L_off inside, L_off outside.
        let ratio = after.weight[0] / after.weight[1]
        let expectedRatio = (onRoad(inside) + offRoad) / offRoad
        #expect(abs(ratio / expectedRatio - 1) < 1e-9, "weight ratio \(ratio), expected \(expectedRatio)")
    }

    @Test("Never a road update inside a catch-up: its distance counts towards the next one")
    func noRoadUpdateInMacroStep() throws {
        let net = try Self.network([Self.street(1, from: (0, -30_000), to: (0, 30_000))])
        let config = Self.config(particles: 100) { $0.maxCatchUpSteps = 5 }
        let motion = { (t: Double) in
            NavigationInput.motion(MotionSample(userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -1),
                                                rotationRate: .zero, attitude: .identity), at: S.ms(t))
        }
        // Moving north on the road, then silence. The steps up to 2 s
        // after the last OBD reply are fresh and run one by one (road
        // updates included); the rest of a 60 s gap is stale, not parked:
        // macro steps only.
        var engine = NavigationEngine(config: config, roads: net)
        for input in Self.shifted(Self.northDrive(seconds: 5, speed: 8), by: (0, 0), fix: S.cleanFix()) { engine.ingest(input) }
        var fresh = engine
        fresh.ingest(motion(6.95))
        engine.ingest(motion(65))
        #expect(engine.counters.macroSteps == 5)
        #expect(engine.counters.roadUpdates == fresh.counters.roadUpdates)
        #expect(engine.counters.roadUpdatesNoRoad == fresh.counters.roadUpdatesNoRoad)

        // R21.2-1: the catch-up's distance is carried, not dropped: Δs after
        // the gap is what `fresh` had left plus the distance driven in the
        // macro steps (the mean's move north; no update moves it there).
        let gap = Self.meanOffset(engine).north - Self.meanOffset(fresh).north
        #expect(gap > 400, "driven in the catch-up: \(gap) m")
        #expect(abs(engine.roadDistanceM - (fresh.roadDistanceM + gap)) < 0.01 * gap,
                "Δs \(engine.roadDistanceM) m, expected \(fresh.roadDistanceM) + \(gap) m")
        // …and the next road update uses all of it.
        try Self.expectNextRoadUpdateUsesCarriedDistance(engine, at: S.ms(65))
    }

    /// A pin at the cloud's mean, arrival `t` (the engine has already
    /// stepped to it), speed source unknown so its σ does not depend on
    /// `kmh`; `kmh` ≥ `roadPinAnchorMinKmh` anchors a road update.
    static func meanPin(_ engine: NavigationEngine, at t: MonotonicTimestamp, kmh: Double) throws -> NavigationInput {
        let est = try #require(engine.estimate(at: t))
        return .manualFix(ManualFixSample(latitude: est.latitude, longitude: est.longitude, pressedT: t, mapSpanM: 360,
                                          speedSource: "unknown", gateSpeedKmh: kmh), at: t)
    }

    /// The next road update after `engine`'s current state consumes the
    /// carried Δs: a moving pin's anchor (a regular, tempered road update
    /// reading `roadDistanceM`) equals, bit for bit, the same pin without
    /// the anchor followed by `roadUpdate(evidenceDistanceM: Δs)`.
    static func expectNextRoadUpdateUsesCarriedDistance(_ engine: NavigationEngine, at t: MonotonicTimestamp) throws {
        let carried = engine.roadDistanceM
        var anchored = engine
        anchored.ingest(try meanPin(engine, at: t, kmh: 30))
        var reference = engine
        reference.ingest(try meanPin(engine, at: t, kmh: 1))
        #expect(reference.counters.roadPinAnchors == engine.counters.roadPinAnchors)
        #expect(reference.counters.manualResets == engine.counters.manualResets)
        reference.roadUpdate(evidenceDistanceM: carried)
        #expect(anchored.counters.roadPinAnchors == engine.counters.roadPinAnchors + 1)
        #expect(anchored.counters.roadUpdates == engine.counters.roadUpdates + 1)
        #expect(state(anchored) == state(reference))
        #expect(anchored.roadEdge == reference.roadEdge && anchored.roadLevel == reference.roadLevel
                && anchored.offRoadM == reference.offRoadM)
        #expect(anchored.roadDistanceM == 0 && reference.roadDistanceM == 0)
    }

    /// R21.2-1, the not-engaged branch: with the cloud wider than
    /// `roadEngageMaxEllipseM` every attempt is an exact no-op and Δs keeps
    /// counting. Reference: the same drive with one attempt only (the
    /// first step; interval 10⁶ s) sums the same steps in the same order,
    /// so Δs is bit-identical; and close to the OBD distance.
    @Test("Not engaged (cloud wider than roadEngageMaxEllipseM): Δs keeps counting, and the first engaged update uses all of it")
    func notEngagedKeepsDistance() throws {
        let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 3000))])
        let inputs = Self.shifted(Self.northDrive(seconds: 20), by: (0, 0), fix: S.cleanFix())
        let narrow = { (c: inout NavigationConfig) in c.roadEngageMaxEllipseM = 0.5 }
        let a = Self.run(inputs, config: Self.config(particles: 100, narrow), roads: net)
        let once = Self.run(inputs, config: Self.config(particles: 100) { narrow(&$0); $0.roadUpdateIntervalS = 1e6 },
                            roads: net)
        var engine = a.engine
        let t = try #require(inputs.last?.arrival)
        #expect(engine.counters.roadUpdates == 0 && engine.counters.roadUpdatesNoRoad == 0)
        #expect(engine.estimate(at: t)?.onRoadShare == nil)
        #expect(Self.state(engine) == Self.state(once.engine))
        #expect(engine.roadDistanceM == once.engine.roadDistanceM)
        // 20 s at OBD 43 km/h (+ 0.5), from the first fix.
        let obd = 43.5 / 3.6 * 20
        #expect(abs(engine.roadDistanceM - obd) < 0.02 * obd, "Δs \(engine.roadDistanceM) m, OBD \(obd) m")
        // Narrow the cloud to a point at its mean (no particle state other
        // than position and covariance changes), so the next update engages.
        let mean = Self.meanOffset(engine)
        for i in engine.east.indices {
            engine.east[i] = mean.east
            engine.north[i] = mean.north
            engine.covEE[i] = 0.01; engine.covEN[i] = 0; engine.covNN[i] = 0.01
        }
        try Self.expectNextRoadUpdateUsesCarriedDistance(engine, at: t)
    }

    /// R21.4-2: the engagement gate counts the spread of the particle
    /// means, not only each particle's own P. 100 particles with P = 1 m²
    /// on a ring of radius 750 m: the mixture's 95 % semi-major axis is
    /// √(5.991 · (750² / 2 + 1)) ≈ 1298 m > 1000 m, so no update engages,
    /// although every particle's own ellipse is 2.4 m. A first update on a
    /// tight cloud makes `onRoadShare` non-nil, so nil afterwards is the
    /// gate's doing. Control: the same ring at radius 500 m (≈ 865 m) engages.
    @Test("R21.4-2: means on a 1.5 km ring with P = 1 m² do not engage roads (spread of means counts); a 1 km ring does")
    func engagementCountsSpreadOfMeans() throws {
        let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 3000)),
                                    Self.street(2, from: (-3000, 0), to: (3000, 0))])
        let t = S.ms(0.05)
        for (radius, engages) in [(750.0, false), (500.0, true)] {
            var engine = Self.directEngine(net)
            Self.place(&engine, at: (0, 0), heading: 0)
            engine.roadUpdate(evidenceDistanceM: 30)
            #expect(engine.counters.roadUpdates == 1 && engine.estimate(at: t)?.onRoadShare != nil)
            let n = engine.east.count
            for i in 0..<n {
                let a = 2 * Double.pi * Double(i) / Double(n)
                engine.east[i] = radius * sin(a)
                engine.north[i] = radius * cos(a)
                engine.covEE[i] = 1; engine.covEN[i] = 0; engine.covNN[i] = 1
                engine.weight[i] = 1 / Double(n)
                engine.logWeight[i] = 0
            }
            engine.roadUpdate(evidenceDistanceM: 30)
            if engages {
                #expect(engine.counters.roadUpdates == 2, "radius \(radius)")
                #expect(engine.estimate(at: t)?.onRoadShare != nil, "radius \(radius)")
            } else {
                #expect(engine.counters.roadUpdates == 1, "radius \(radius): engaged")
                #expect(engine.estimate(at: t)?.onRoadShare == nil, "radius \(radius)")
                #expect(engine.estimate(at: t)?.matchedEdge == nil, "radius \(radius)")
            }
        }
    }

    /// R21.4-3: Step 2's radius guard. With `roadSplitSigmaM` 25 a particle
    /// with P = 625·I is not split, and its χ² gate admits d up to
    /// √(9 · (625 + 49)) ≈ 77.9 m: past R = 50 m. A north–south street
    /// 60–74 m east of it, listed in the particle's cell (the cell lists
    /// every segment within R of any point in it), must still not be a
    /// candidate, since L_off assumes a ±R strip. An east–west street 40 m
    /// north (outside the heading gate) passes Step 0. Control: the same
    /// street 45 m off is a candidate.
    @Test("R21.4-3: a segment beyond roadSearchRadiusM but inside the χ² gate and listed in the cell is not a candidate")
    func radiusGuardBeyondSearchRadius() throws {
        let streetX = 10.0
        let net = try Self.network([Self.street(1, from: (streetX, -3000), to: (streetX, 3000)),
                                    Self.street(2, from: (-3000, 40), to: (3000, 40))])
        // A particle position whose cell lists the north–south street, 60–74 m from it.
        let listed = stride(from: streetX - 74, through: streetX - 60, by: 1.0).first { x in
            let p = S.plane.geodetic(east: x, north: 0)
            return net.segments(nearLatitude: p.latitude, longitude: p.longitude).contains {
                net.segment($0).key.osmWayID == 1
            }
        }
        let x = try #require(listed, "no position 60–74 m off whose cell lists the street")
        let t = S.ms(0.05)
        for (px, candidate) in [(x, false), (streetX - 45, true)] {
            var engine = Self.directEngine(net) { $0.roadSplitSigmaM = 25 }
            Self.place(&engine, at: (px, 0), heading: 0)
            for i in engine.east.indices { engine.covEE[i] = 625; engine.covNN[i] = 625 }
            let d = streetX - px
            let s0 = 625 + engine.config.roadSigmaM * engine.config.roadSigmaM
            #expect(d * d <= engine.config.roadInnovationGateChi2 * s0, "inside the χ² gate at \(d) m")
            engine.roadUpdate(evidenceDistanceM: 30)
            #expect(engine.counters.roadUpdates == 1 && engine.counters.roadSplits == 0, "\(d) m")
            let share = try #require(engine.estimate(at: t)?.onRoadShare)
            if candidate {
                #expect(share > 0.5, "\(d) m: share \(share)")
                #expect(engine.roadEdge.allSatisfy { $0 != RoadMatcher.noEdge }, "\(d) m")
            } else {
                #expect(d > engine.config.roadSearchRadiusM)
                #expect(share == 0, "\(d) m: share \(share)")
                #expect(engine.roadEdge.allSatisfy { $0 == RoadMatcher.noEdge }, "\(d) m")
                #expect(engine.counters.roadCandidateTests > 0, "\(d) m: the cell's segments were tested")
            }
        }
    }

    // MARK: 6. Opposite oneways

    @Test("6. Opposite oneway carriageways 15 m apart: heading picks the northbound one")
    func oppositeOneways() throws {
        let net = try Self.network([
            RoadFixture.way(1, ["highway": "primary", "oneway": "yes"], [N(id: 10, east: 0, north: -3000), N(id: 11, east: 0, north: 3000)]),
            RoadFixture.way(2, ["highway": "primary", "oneway": "yes"], [N(id: 20, east: 15, north: 3000), N(id: 21, east: 15, north: -3000)]),
        ])
        // Pin 11 m east, nearer the southbound carriageway (x = 15) than
        // the northbound one the car is on (x = 0); heading north known.
        // Distance alone would pick the wrong one.
        let drive = Self.northDrive(seconds: 40)
        let inputs = Self.shifted(drive, by: (0, -500), fix: { _, _, _ in nil },
                                  extra: [Self.pin(at: 0.2, east: 11, north: -500 + 2.4, kmh: nil)])
        var engine = NavigationEngine(config: Self.config(particles: 500) { $0.roadPinAnchorMinKmh = 0 }, roads: net)
        var initialized = false
        for input in inputs {
            engine.ingest(input)
            if !initialized, engine.isInitialized {
                initialized = true
                for i in engine.heading.indices { engine.heading[i] = 0 }
            }
        }
        let est = try #require(engine.estimate(at: S.ms(40)))
        #expect(est.matchedEdge?.osmWayID == 1)
        #expect((est.onRoadShare ?? 0) > 0.8)
        #expect(!engine.roadEdge.contains(UInt32(try #require(RoadFixture.edgeIndices(of: net.packs[0], way: 2).first))))
        #expect(abs(Self.meanOffset(engine).east) < 4, "east \(Self.meanOffset(engine).east) m")

        // Directly: on the southbound carriageway's centreline, a
        // southbound particle takes it, and a northbound one takes the
        // northbound carriageway 15 m away (P wide enough that it is the
        // likelier explanation: r ≥ 0.5). The oneway direction gate is not
        // what decides here: without it the southbound carriageway would be
        // a candidate at dψ = π, whose heading likelihood (z = 18 at σψ
        // 10°) loses to the other carriageway anyway. `onewayDirectionGate`
        // tests the gate on its own.
        var probe = engine
        let plane = try #require(probe.tangentPlane)
        let onSouthbound = S.plane.geodetic(east: 15, north: S.plane.enu(latitude: est.latitude, longitude: est.longitude).north)
        let target = plane.enu(latitude: onSouthbound.latitude, longitude: onSouthbound.longitude)
        for i in probe.east.indices {
            probe.east[i] = target.east
            probe.north[i] = target.north
            probe.covEE[i] = 100; probe.covEN[i] = 0; probe.covNN[i] = 100
            probe.heading[i] = i % 2 == 0 ? 0 : .pi
            probe.roadEdge[i] = RoadMatcher.noEdge
            probe.roadLevel[i] = RoadGeometry.unknownLevel
            probe.offRoadM[i] = 0
        }
        let north = UInt32(try #require(RoadFixture.edgeIndices(of: net.packs[0], way: 1).first))
        let south = UInt32(try #require(RoadFixture.edgeIndices(of: net.packs[0], way: 2).first))
        probe.roadUpdate(evidenceDistanceM: 30)
        #expect(probe.counters.roadSplits == engine.counters.roadSplits)
        for i in probe.east.indices {
            #expect(probe.roadEdge[i] == (i % 2 == 0 ? north : south), "particle \(i)")
        }
    }

    /// R21.3-3: Step 2's oneway direction gate on its own. A lone
    /// northbound oneway along x = 0; particles on its centreline (d = 0,
    /// P = 25·I) heading south, against it. The gate admits a oneway only
    /// within `roadHeadingGateDeg` of its forward bearing, so there is no
    /// candidate at all: no edge, share exactly 0, no matched edge. At
    /// σψ 60° the heading term alone would not save it: a candidate there
    /// (dψ = π, z = 3) would have r ≥ 0.5 and be taken. Heading north, the
    /// same particles take it.
    @Test("6. Oneway direction gate: on a oneway's centreline heading against it, no candidate (share 0, no edge), even at σψ 60° where r would be ≥ 0.5")
    func onewayDirectionGate() throws {
        let net = try Self.network([
            RoadFixture.way(1, ["highway": "primary", "oneway": "yes"], [N(id: 10, east: 0, north: -3000), N(id: 11, east: 0, north: 3000)]),
        ])
        let edge = UInt32(try #require(RoadFixture.edgeIndices(of: net.packs[0], way: 1).first))
        for sigmaDeg in [10.0, 60.0] {
            var engine = Self.directEngine(net) { $0.roadHeadingSigmaDeg = sigmaDeg }
            let c = engine.config
            if sigmaDeg == 60 {
                // Closed form at d = 0, dψ = π, S₀ = 25 + σr².
                let s0 = 25 + c.roadSigmaM * c.roadSigmaM
                let sigmaPsi = sigmaDeg * .pi / 180
                let z = Double.pi / sigmaPsi
                let onRoad = (1 - c.roadOffRoadProbability) * exp(-0.5 * z * z) / s0.squareRoot() / (2 * .pi * sigmaPsi)
                let offRoad = c.roadOffRoadProbability / (2 * c.roadSearchRadiusM * 2 * .pi)
                let r = onRoad / (onRoad + offRoad)
                #expect(r >= 0.5, "without the gate, r = \(r)")
            }
            Self.place(&engine, at: (0, 0), heading: .pi)
            var against = engine
            against.roadUpdate(evidenceDistanceM: 30)
            #expect(against.counters.roadUpdates == 1 && against.counters.roadUpdatesNoRoad == 0, "σψ \(sigmaDeg)")
            #expect(against.roadEdge.allSatisfy { $0 == RoadMatcher.noEdge }, "σψ \(sigmaDeg)")
            #expect(against.east.allSatisfy { $0 == 0 }, "σψ \(sigmaDeg): not moved")
            let estimate = try #require(against.estimate(at: S.ms(0.05)))
            #expect(estimate.onRoadShare == 0, "σψ \(sigmaDeg): share \(String(describing: estimate.onRoadShare))")
            #expect(estimate.matchedEdge == nil, "σψ \(sigmaDeg)")

            Self.place(&engine, at: (0, 0), heading: 0)
            var with = engine
            with.roadUpdate(evidenceDistanceM: 30)
            #expect(with.roadEdge.allSatisfy { $0 == edge }, "σψ \(sigmaDeg): heading north takes it")
            #expect(with.estimate(at: S.ms(0.05))?.matchedEdge?.osmWayID == 1, "σψ \(sigmaDeg)")
        }
    }

    // MARK: 7. Ring cloud after a pin; no false collapse on a symmetric grid

    /// A 100 m street grid, `size` × `size` blocks centred on the origin.
    static func grid(blocks: Int, spacing: Double = 100, extent: Double? = nil) -> [String] {
        var lines: [String] = []
        let half = Double(blocks) * spacing / 2
        let reach = extent ?? half
        var id: Int64 = 1
        for k in 0...blocks {
            let x = -half + Double(k) * spacing
            lines.append(street(id, from: (x, -reach), to: (x, reach))); id += 1
            lines.append(street(id, from: (-reach, x), to: (reach, x))); id += 1
        }
        return lines
    }

    /// Measured 280–300 m on seeds 1–5 (heading std without roads: 234°).
    @Test("7. Ring cloud after a pin on one exit road: heading converges within 400 m")
    func ringOneExit() throws {
        // One road going north-east from the pin; nothing else within 1 km.
        let bearing = 40.0
        let b = bearing * .pi / 180
        let net = try Self.network([Self.street(1, from: (-200 * sin(b), -200 * cos(b)), to: (3000 * sin(b), 3000 * cos(b)))])
        let v = 10.0
        let drive = S(initialHeadingDeg: bearing, initialSpeed: v, [.straight(seconds: 60, speed: v)])
        let inputs = Self.shifted(drive, by: (0, 0), fix: { _, _, _ in nil },
                                  extra: [Self.pin(at: 0.05, east: 0, north: 0, span: 360, kmh: 0)], gyroNoise: 0.0005)
        let r = Self.run(inputs, config: Self.config(particles: 2000), roads: net, every: 1)
        let converged = r.estimates.first { $0.headingStdDeg < 10 && abs(angleDifference($0.headingDeg, bearing)) < 5 }
        let at = try #require(converged, "never converged")
        #expect(at.t.seconds * v <= 400, "converged after \(at.t.seconds * v) m")
        let last = try #require(r.estimates.last)
        #expect(abs(angleDifference(last.headingDeg, bearing)) < 3 && last.headingStdDeg < 5)
    }

    @Test("7. Symmetric 4-way grid, driven straight with no turn: heading stays multi-modal (no false collapse)")
    func symmetricGridNoCollapse() throws {
        // Pin at a junction, drive straight north 500 m along a grid line:
        // N, S, E, W are all consistent with the roads (only the start and
        // the straight line are known), so heading must not collapse.
        let net = try Self.network(Self.grid(blocks: 20))
        let v = 10.0
        let drive = S(initialHeadingDeg: 0, initialSpeed: v, [.straight(seconds: 50, speed: v)])
        let inputs = Self.shifted(drive, by: (0, 0), fix: { _, _, _ in nil },
                                  extra: [Self.pin(at: 0.05, east: 0, north: 0, span: 120, kmh: 0)], gyroNoise: 0.0005)
        let r = Self.run(inputs, config: Self.config(particles: 2000), roads: net, every: 5)
        let engine = r.engine
        // Weight per quadrant of heading around N, E, S, W.
        var quadrant = [Double](repeating: 0, count: 4)
        for i in engine.heading.indices {
            let k = Int(((engine.heading[i] * 180 / .pi + 45).truncatingRemainder(dividingBy: 360)) / 90)
            quadrant[min(3, k)] += engine.weight[i]
        }
        #expect(quadrant.filter { $0 > 0.1 }.count >= 3, "heading collapsed: N/E/S/W weights \(quadrant)")
        #expect((r.estimates.last?.headingStdDeg ?? 0) > 60)
        #expect(engine.counters.roadUpdates > 30)
    }

    // MARK: 8. GPS fix gate

    @Test("8. Fix gate: a fix 200 m from any road while on-road at speed is rejected; one on another road 300 m away is accepted")
    func fixGate() throws {
        // Road x = 0 (the car) and a parallel road x = 300 (the fix).
        let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 3000)), Self.street(2, from: (300, -3000), to: (300, 3000))])
        let v = 15.0
        let drive = Self.northDrive(seconds: 60, speed: v)
        let clean = S.cleanFix()
        func run(offEast: Double) -> NavigationEngine {
            let inputs = Self.shifted(drive, by: (0, -500), fix: { t, s, r in
                if t < 10 { return clean(t, s, &r) }
                if S.at(t, 40) {
                    var f = clean(t, s, &r)!
                    f.east += offEast
                    return f
                }
                return nil
            })
            var engine = NavigationEngine(config: Self.config(particles: 400), roads: net)
            for input in inputs { engine.ingest(input) }
            return engine
        }
        let off = run(offEast: 200)  // 200 m east: 100 m from either road
        #expect(off.counters.fixesRejectedOffRoad == 1)
        let other = run(offEast: 300)  // on the other road
        #expect(other.counters.fixesRejectedOffRoad == 0)
        #expect(other.counters.fixesUsed == off.counters.fixesUsed + 1)
        // Gate off: the same fix is used.
        var engine = NavigationEngine(config: Self.config(particles: 400) { $0.roadFixGateSigma = 0 }, roads: net)
        for input in Self.shifted(drive, by: (0, -500), fix: { t, s, r in
            if t < 10 { return clean(t, s, &r) }
            if S.at(t, 40) { var f = clean(t, s, &r)!; f.east += 200; return f }
            return nil
        }) { engine.ingest(input) }
        #expect(engine.counters.fixesRejectedOffRoad == 0)
    }

    @Test("8. Fix gate: slow, network fix, outside coverage, or a fix whose gate reaches the road: never gated")
    func fixGateConditions() throws {
        let ring = [RoadFixture.point(-500, -1000), RoadFixture.point(500, -1000), RoadFixture.point(500, 1000), RoadFixture.point(-500, 1000)]
        let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 3000))], coverage: [ring])
        let clean = S.cleanFix()
        func rejected(speed v: Double, fixEast: Double, accuracy: Double = 5, network: Bool = false) -> Int {
            let drive = Self.northDrive(seconds: 50, speed: v)
            let inputs = Self.shifted(drive, by: (0, -500), fix: { t, s, r in
                if t < 10 { return clean(t, s, &r) }
                if S.at(t, 40) {
                    var f = clean(t, s, &r)!
                    f.east += fixEast
                    f.accuracy = accuracy
                    if network { f.speed = -1; f.speedAccuracy = -1; f.course = -1 }
                    return f
                }
                return nil
            })
            var engine = NavigationEngine(config: Self.config(particles: 300), roads: net)
            for input in inputs { engine.ingest(input) }
            return engine.counters.fixesRejectedOffRoad
        }
        #expect(rejected(speed: 15, fixEast: 200) == 1)
        #expect(rejected(speed: 4, fixEast: 200) == 0)          // under 20 km/h
        #expect(rejected(speed: 15, fixEast: 200, network: true) == 0)
        #expect(rejected(speed: 15, fixEast: 800) == 0)         // outside coverage
        #expect(rejected(speed: 15, fixEast: 200, accuracy: 120) == 0)  // G = 3σ ≈ 238 m reaches the road
    }

    /// The car drives north on x = 0 at 15 m/s (fresh OBD, 54 km/h) from
    /// (0, −500); a clean fix every second for 10 s, then one at 40 s moved
    /// 200 m east. Coverage is a 4 km square, so the fix is inside it.
    /// Returns the rejected-fix count and the on-road share the gate read
    /// (the last road update's, just before the 40 s fix).
    static func gateRun(_ lines: [String], obdUntil: Double? = nil,
                        _ edit: (inout NavigationConfig) -> Void = { _ in }) throws
        -> (rejected: Int, share: Double?, engine: NavigationEngine) {
        let ring = [RoadFixture.point(-2000, -2000), RoadFixture.point(2000, -2000),
                    RoadFixture.point(2000, 2000), RoadFixture.point(-2000, 2000)]
        let net = try Self.network(lines, coverage: [ring])
        let drive = Self.northDrive(seconds: 50, speed: 15)
        let clean = S.cleanFix()
        let events = drive.events(obdSpeed: { t, s in
            obdUntil.map { t >= $0 } == true ? nil : (s.speed * 3.6).rounded(.down)
        }, fix: { t, s, r in
            guard t < 10 || S.at(t, 40), var f = clean(t, s, &r) else { return nil }
            f.north -= 500
            if S.at(t, 40) { f.east += 200 }
            return f
        })
        var engine = NavigationEngine(config: Self.config(particles: 300, edit), roads: net)
        var share: Double?? = .none
        for input in S.inputs(events) {
            if case .location(_, let t) = input, t > S.ms(30) {
                share = .some(engine.estimate(at: input.arrival)?.onRoadShare)
            }
            engine.ingest(input)
        }
        let read = try #require(share, "the 40 s fix was ingested")
        return (engine.counters.fixesRejectedOffRoad, read, engine)
    }

    /// R21.3-1: the gate needs the last road update's on-road share ≥
    /// `roadFixGateOnRoadShare`. An off-road cloud (share 0) or one with no
    /// road update engaged (share nil) never gates, even at speed with the
    /// fix 200 m from any road; the same drive on the road gates it.
    @Test("8. Fix gate on-road share: an off-road cloud (share 0: no road near, or no candidate) or an unengaged one (nil) never gates")
    func fixGateOnRoadShare() throws {
        // Control: on the road x = 0, share ≥ 0.8: the fix is rejected.
        let on = try Self.gateRun([Self.street(1, from: (0, -3000), to: (0, 3000))])
        #expect(on.rejected == 1)
        #expect((on.share ?? 0) >= 0.8, "share \(String(describing: on.share))")

        // No road within R of the cloud (the only road is x = 1000): every
        // update is a no-road update, share 0. The fix is 800 m from it.
        let far = try Self.gateRun([Self.street(1, from: (1000, -3000), to: (1000, 3000))])
        #expect(far.share == 0)
        #expect(far.engine.counters.roadUpdatesNoRoad > 0 && far.engine.counters.roadUpdates == 0)
        #expect(far.rejected == 0)

        // A road within R but no candidate: a southbound oneway 30 m east of
        // the northbound car. Engaged updates, every r = 0: share 0. The
        // fix (course north) is 170 m from it and against it.
        let oneway = RoadFixture.way(2, ["highway": "residential", "oneway": "yes"],
                                     [N(id: 20, east: 30, north: 3000), N(id: 21, east: 30, north: -3000)])
        let against = try Self.gateRun([oneway])
        #expect(against.share == 0)
        #expect(against.engine.counters.roadUpdates > 0)
        #expect(against.rejected == 0)

        // On the road but never engaged (roadEngageMaxEllipseM 0.5 m):
        // share nil.
        let unengaged = try Self.gateRun([Self.street(1, from: (0, -3000), to: (0, 3000))]) {
            $0.roadEngageMaxEllipseM = 0.5
        }
        #expect(unengaged.share == nil)
        #expect(unengaged.engine.counters.roadUpdates == 0 && unengaged.engine.counters.roadUpdatesNoRoad == 0)
        #expect(unengaged.rejected == 0)
    }

    /// R21.3-2: the gate needs fresh OBD speed. OBD stops at 36 s, so at
    /// the 40 s fix the held 54 km/h is 4 s old (> `obdMaxAgeS` 2 s) while
    /// the cloud is still on the road (share ≥ 0.8): not gated. With OBD
    /// fresh, the same fix is rejected.
    @Test("8. Fix gate: stale OBD speed (held, 4 s old) at speed on the road never gates; fresh OBD does")
    func fixGateStaleOBD() throws {
        let road = [Self.street(1, from: (0, -3000), to: (0, 3000))]
        let fresh = try Self.gateRun(road)
        #expect((fresh.share ?? 0) >= 0.8, "share \(String(describing: fresh.share))")
        #expect(fresh.rejected == 1)

        let stale = try Self.gateRun(road, obdUntil: 36)
        #expect(stale.engine.counters.staleSpeedSteps > 0)
        #expect((stale.share ?? 0) >= 0.8, "share \(String(describing: stale.share))")
        #expect(stale.rejected == 0)
    }

    /// The gate judges heading compatibility with the fix's own course. The
    /// car drives north on x = 0 and is at (0, 100) at 40 s; the fix there
    /// is moved 200 m east (150 m beyond the 50 m gate from x = 0), next to
    /// a road that is the only one within the gate radius.
    @Test("8. Fix gate heading: a fix 20 m from a cross street is rejected when its course runs across it, or against a oneway")
    func fixGateHeading() throws {
        let v = 15.0
        let drive = Self.northDrive(seconds: 50, speed: v)
        let clean = S.cleanFix()
        func rejected(_ road: String, course: Double?) throws -> Int {
            let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 3000)), road])
            let inputs = Self.shifted(drive, by: (0, -500), fix: { t, s, r in
                if t < 10 { return clean(t, s, &r) }
                if S.at(t, 40) {
                    var f = clean(t, s, &r)!
                    f.east += 200
                    if let course { f.course = course }
                    return f
                }
                return nil
            })
            var engine = NavigationEngine(config: Self.config(particles: 300), roads: net)
            for input in inputs { engine.ingest(input) }
            #expect(engine.counters.courseUpdates > 0)
            return engine.counters.fixesRejectedOffRoad
        }
        // An east–west street 20 m south of the fix (x 100…400, y 80).
        let cross = Self.street(2, from: (100, 80), to: (400, 80))
        #expect(try rejected(cross, course: nil) == 1, "course north (the car's) across the street")
        #expect(try rejected(cross, course: 90) == 0, "course east, along the street")
        #expect(try rejected(cross, course: 270) == 0, "course west: a two-way street")
        // A southbound oneway 20 m east of the fix (x = 220).
        let oneway = RoadFixture.way(3, ["highway": "residential", "oneway": "yes"],
                                     [N(id: 30, east: 220, north: 3000), N(id: 31, east: 220, north: -3000)])
        #expect(try rejected(oneway, course: nil) == 1, "course north, against the oneway")
        #expect(try rejected(oneway, course: 180) == 0, "course south, with the oneway")
        #expect(try rejected(Self.street(3, from: (220, 3000), to: (220, -3000)), course: nil) == 0,
                "course north on the same line, two-way")
    }

    // MARK: 9. Pin anchors

    @Test("9. A moving pin anchors a road update; a stationary pin does not")
    func pinAnchor() throws {
        let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 3000))])
        for (kmh, anchors) in [(30.0, 1), (0.0, 0), (2.0, 0)] {
            let drive = Self.northDrive(seconds: 20, speed: 8)
            let clean = S.cleanFix()
            let inputs = Self.shifted(drive, by: (0, -500), fix: { t, s, r in t < 5 ? clean(t, s, &r) : nil },
                                      extra: [Self.pin(at: 10.03, east: 0, north: drive.truth(at: 10.03).north - 500, kmh: kmh)])
            // A long interval, so only a pin could trigger the update at 10 s.
            let config = Self.config(particles: 300) { $0.roadUpdateIntervalS = 30 }
            var engine = NavigationEngine(config: config, roads: net)
            var updatesAtPin = -1
            for input in inputs {
                let before = engine.counters.roadUpdates
                engine.ingest(input)
                if case .manualFix = input { updatesAtPin = engine.counters.roadUpdates - before }
            }
            #expect(engine.counters.roadPinAnchors == anchors, "\(kmh) km/h")
            #expect(updatesAtPin == anchors, "\(kmh) km/h")
        }
    }

    @Test("9. A moving pin that initialises the engine anchors with full weight: the cloud snaps across the road")
    func initialisingPinAnchors() throws {
        let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 3000))])
        let drive = Self.northDrive(seconds: 1, speed: 8)
        let inputs = Self.shifted(drive, by: (0, -500), fix: { _, _, _ in nil },
                                  extra: [Self.pin(at: 0.05, east: 20, north: -500, span: 120, kmh: 30)])
        var engine = NavigationEngine(config: Self.config(particles: 300), roads: net)
        for input in inputs {
            engine.ingest(input)
            if case .manualFix = input { break }
        }
        #expect(engine.counters.roadPinAnchors == 1 && engine.counters.roadUpdates == 1)
        let share = try #require(engine.estimate(at: S.ms(0.05))?.onRoadShare)
        #expect(share > 0)
        // Only headings near north or south match a north–south road.
        var aligned = 0.0
        for i in engine.heading.indices where abs(sin(engine.heading[i])) < sin(45 * .pi / 180) { aligned += engine.weight[i] }
        #expect(aligned > 0.9, "weight on road-aligned headings \(aligned)")
    }

    /// R21.1-1: a moving pin compatible with the cloud (no initialisation,
    /// no manual reset) keeps the road information already used, so its
    /// anchor is an ordinary, early road update tempered by the distance
    /// driven since the last one: 0.03 s after a road update (Δs = 0) it
    /// does nothing; 0.53 s after it, it equals `roadUpdate(Δs)`. A full
    /// weight there would count the same road twice and add
    /// `roadCorrelationM` off-road for ~0 m driven. A pin 2 km ahead
    /// resets the cloud (earlier road information discarded): full weight.
    @Test("9. A compatible moving pin right after a road update anchors with the tempered weight, not a second full one")
    func compatiblePinAnchorIsTempered() throws {
        let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 3000))])
        let drive = Self.northDrive(seconds: 20, speed: 8)
        let clean = S.cleanFix()
        let inputs = Self.shifted(drive, by: (0, -500), fix: { t, s, r in t < 5 ? clean(t, s, &r) : nil })
        for (delay, ahead) in [(0.03, 0.0), (0.53, 0), (0.03, 2000)] {
            let reset = ahead > 0
            // Identical but for roadPinAnchorMinKmh, read only at a pin
            // (0 turns the anchor off).
            var anchored = NavigationEngine(config: Self.config(particles: 300), roads: net)
            var plain = NavigationEngine(config: Self.config(particles: 300) { $0.roadPinAnchorMinKmh = 0 }, roads: net)
            var pinT: Double?
            for input in inputs {
                if let t = pinT, input.arrival.seconds >= t { break }
                let before = anchored.counters.roadUpdates
                anchored.ingest(input)
                plain.ingest(input)
                if pinT == nil, input.arrival.seconds > 10, anchored.counters.roadUpdates > before {
                    pinT = input.arrival.seconds + delay
                }
            }
            let t = try #require(pinT)
            #expect(Self.state(anchored) == Self.state(plain))
            let updatesBefore = anchored.counters.roadUpdates
            let pin = try #require(NavigationInput(Self.pin(at: t, east: 0, north: drive.truth(at: t).north - 500 + ahead,
                                                            kmh: 30)))
            anchored.ingest(pin)
            plain.ingest(pin)
            #expect(anchored.counters.roadPinAnchors == 1 && plain.counters.roadPinAnchors == 0)
            #expect(anchored.counters.manualResets == (reset ? 1 : 0) && anchored.counters.manualFixes == 1)
            // Compatible: the anchor = a regular road update with Δs since
            // the last one. Reset: weight 1.
            var expected = plain
            expected.roadUpdate(evidenceDistanceM: reset ? max(plain.roadDistanceM, 30) : plain.roadDistanceM)
            #expect(Self.state(anchored) == Self.state(expected), "\(delay) s, \(ahead) m")
            #expect(anchored.offRoadM == expected.offRoadM && anchored.roadEdge == expected.roadEdge, "\(delay) s")
            if reset {
                #expect(anchored.counters.roadUpdates == updatesBefore + 1)
                #expect(Self.state(anchored) != Self.state(plain))
            } else if delay < 0.1 {
                #expect(plain.roadDistanceM == 0)
                #expect(anchored.counters.roadUpdates == updatesBefore, "a second road update at Δs = 0")
                #expect(Self.state(anchored) == Self.state(plain))
            } else {
                #expect(plain.roadDistanceM > 1 && plain.roadDistanceM < 10)
                #expect(anchored.counters.roadUpdates == updatesBefore + 1)
            }
        }
    }

    // MARK: 10. Late pin with roads

    @Test("10. Late pin with roads: the ring and motionEast/North are unaffected; matches arrival order as without roads")
    func latePinWithRoads() throws {
        let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 3000))])
        let drive = Self.northDrive(seconds: 40, speed: 12)
        let clean = S.cleanFix()
        let tPin = 25.0
        let inputs = Self.shifted(drive, by: (0, -500), fix: { t, s, r in t < 8 ? clean(t, s, &r) : nil },
                                  extra: [Self.pin(at: tPin, east: 0, north: drive.truth(at: tPin).north - 500, kmh: 43)])
        let late = NavigationLatePinTests.delayingPin(inputs, at: tPin, by: 3)
        let config = Self.config(particles: 400) { $0.roadPinAnchorMinKmh = 0 }
        // Road updates change positions, never the late-pin motion record.
        var withRoads = NavigationEngine(config: config, roads: net)
        var without = NavigationEngine(config: config)
        for input in late {
            withRoads.ingest(input)
            without.ingest(input)
            if case .manualFix = input { break }
        }
        #expect(withRoads.counters.lateManualFixes == 1)
        #expect(withRoads.counters.roadUpdates > 10)
        // A road update never writes motionEast/North or the ring: probe
        // every update on a copy with resampling off.
        var probeConfig = config
        probeConfig.resampleESSFraction = 0
        var probe = NavigationEngine(config: probeConfig, roads: net)
        var probed = 0
        for input in late {
            probe.ingest(input)
            guard probe.isInitialized else { continue }
            var after = probe
            after.roadUpdate(evidenceDistanceM: 30)
            guard after.counters.roadUpdates > probe.counters.roadUpdates else { continue }
            #expect(after.motionEast == probe.motionEast && after.motionNorth == probe.motionNorth)
            #expect(after.motionRing.chronological().map(\.east) == probe.motionRing.chronological().map(\.east))
            #expect(after.motionRing.chronological().map(\.north) == probe.motionRing.chronological().map(\.north))
            probed += 1
            if probed >= 20 { break }
        }
        #expect(probed == 20)
        // The late pin with roads lands where it lands in arrival order.
        var lateEngine = NavigationEngine(config: config, roads: net)
        var inOrderEngine = NavigationEngine(config: config, roads: net)
        for input in late where input.arrival <= S.ms(tPin + 4) { lateEngine.ingest(input) }
        for input in inputs where input.arrival <= S.ms(tPin + 4) { inOrderEngine.ingest(input) }
        let x = try #require(lateEngine.estimate(at: S.ms(tPin + 4))), y = try #require(inOrderEngine.estimate(at: S.ms(tPin + 4)))
        #expect(NavigationLatePinTests.distance(x, y) < 3)
    }

    // MARK: 11. Re-anchor

    @Test("11. Re-anchor during a road drive: continuous, and equal to running with no cell cache at all")
    func reanchor() throws {
        // A road at 60°, so the re-anchored plane moves the road in both
        // axes: a cache not cleared at the re-anchor would match the old
        // plane's coordinates.
        let b = 60 * Double.pi / 180
        let net = try Self.network([Self.street(1, from: (-3000 * sin(b), -3000 * cos(b)), to: (3000 * sin(b), 3000 * cos(b)))])
        let drive = S(initialHeadingDeg: 60, initialSpeed: 15, [.straight(seconds: 120, speed: 15)])
        let clean = S.cleanFix()
        let inputs = Self.shifted(drive, by: (-900 * sin(b), -900 * cos(b)), fix: { t, s, r in t < 8 ? clean(t, s, &r) : nil })
        let config = Self.config(particles: 300) { $0.reanchorDistanceM = 400 }
        let cached = Self.run(inputs, config: config, roads: net, every: 1)
        let uncached = Self.run(inputs, config: config, roads: net, cache: 0, every: 1)
        // The cell cache of the default run is cleared at a re-anchor; a
        // stale one is caught here, against a run with no cache at all.
        #expect(cached.engine.counters.reanchors >= 2)
        #expect(Self.state(cached.engine) == Self.state(uncached.engine))
        #expect(cached.estimates.map(\.latitude) == uncached.estimates.map(\.latitude))
        // Continuous: no jump between consecutive 1 s estimates beyond the
        // distance driven plus a little.
        let driving = cached.estimates.filter { $0.t.seconds > 10 }
        for (p, q) in zip(driving, driving.dropFirst()) {
            let a = S.plane.enu(latitude: p.latitude, longitude: p.longitude)
            let b = S.plane.enu(latitude: q.latitude, longitude: q.longitude)
            let step = ((b.east - a.east) * (b.east - a.east) + (b.north - a.north) * (b.north - a.north)).squareRoot()
            #expect(step < 15 * 1.0 + 5, "jump \(step) m at \(q.t.seconds) s")
            let across = b.east * cos(60 * Double.pi / 180) - b.north * sin(60 * Double.pi / 180)
            #expect(abs(across) < 6, "off the road by \(across) m at \(q.t.seconds) s")
        }
    }

    // MARK: 12. Determinism and causality

    static func gridDrive() throws -> (net: RoadNetwork, inputs: [NavigationInput], drive: SyntheticDrive) {
        let net = try Self.network(Self.grid(blocks: 10))
        let v = 10.0
        let drive = S(initialHeadingDeg: 0, initialSpeed: v, [
            .straight(seconds: 20, speed: v), .turn(degrees: 90, seconds: 3, speed: v), .straight(seconds: 25, speed: v),
            .turn(degrees: -90, seconds: 3, speed: v), .straight(seconds: 20, speed: v),
        ])
        let clean = S.cleanFix()
        // Initialised by a pin (σ 30 m > roadSplitSigmaM: splits), a clean
        // fix stretch, and a moving pin later.
        let inputs = Self.shifted(drive, by: (0, -300), fix: { t, s, r in t > 4 && t < 9 ? clean(t, s, &r) : nil },
                                  extra: [Self.pin(at: 0.05, east: 0, north: -300, kmh: 36),
                                          Self.pin(at: 40.03, east: drive.truth(at: 40.03).east, north: drive.truth(at: 40.03).north - 300, kmh: 36)],
                                  gyroNoise: 0.002)
        return (net, inputs, drive)
    }

    @Test("12. Determinism: same pack and seed bit-identical; cache size 1 equals the default; another seed differs")
    func determinism() throws {
        let (net, inputs, _) = try Self.gridDrive()
        let config = Self.config(particles: 400)
        let a = Self.run(inputs, config: config, roads: net, every: 1)
        let b = Self.run(inputs, config: config, roads: try Self.network(Self.grid(blocks: 10)), every: 1)
        let small = Self.run(inputs, config: config, roads: net, cache: 1, every: 1)
        #expect(a.engine.counters.roadUpdates > 50 && a.engine.counters.roadSplits > 0)
        #expect(Self.state(a.engine) == Self.state(b.engine) && a.estimates == b.estimates)
        #expect(Self.state(a.engine) == Self.state(small.engine) && a.estimates == small.estimates)
        #expect(a.engine.counters == small.engine.counters)
        let other = Self.run(inputs, config: Self.config(particles: 400, seed: 2), roads: net)
        #expect(Self.state(a.engine) != Self.state(other.engine))
    }

    @Test("12. Causality with roads: a prefix gives the same state; garbage after T leaves estimates up to T unchanged")
    func causality() throws {
        let (net, inputs, _) = try Self.gridDrive()
        let config = Self.config(particles: 300)
        let cut = S.ms(45)
        let full = Self.run(inputs, config: config, roads: net, every: 1)
        let prefix = Self.run(inputs.filter { $0.arrival <= cut }, config: config, roads: net, every: 1)
        let n = prefix.estimates.count
        #expect(n > 30)
        #expect(Array(full.estimates.prefix(n)) == prefix.estimates)
        // Garbage after T: a wild fix and a far pin.
        var garbage = inputs.filter { $0.arrival <= cut }
        let far = S.plane.geodetic(east: 5000, north: 5000)
        garbage.append(.location(LocationSample(latitude: far.latitude, longitude: far.longitude, altitude: 0,
                                                horizontalAccuracy: 5, verticalAccuracy: -1, speed: 40, speedAccuracy: 0.3,
                                                course: 270, courseAccuracy: 2, receivedT: S.ms(45.6), ageS: 0.05), at: S.ms(45.55)))
        garbage.append(.manualFix(ManualFixSample(latitude: far.latitude, longitude: far.longitude, pressedT: S.ms(46),
                                                  mapSpanM: 300, speedSource: "obd", gateSpeedKmh: 50), at: S.ms(46)))
        let g = Self.run(garbage, config: config, roads: net, every: 1)
        #expect(Array(g.estimates.prefix(n)) == prefix.estimates)
    }

    // MARK: 13. Resampling, reseed and reset

    @Test("13. Resampling copies road state with each particle; a reseed and a manual reset clear it")
    func roadStateFollowsParticles() throws {
        let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 3000))])
        let drive = Self.northDrive(seconds: 30)
        let clean = S.cleanFix()
        let inputs = Self.shifted(drive, by: (0, -500), fix: { t, s, r in t < 8 ? clean(t, s, &r) : nil })
        var engine = NavigationEngine(config: Self.config(particles: 200), roads: net)
        for input in inputs { engine.ingest(input) }
        #expect(engine.roadEdge.allSatisfy { $0 != RoadMatcher.noEdge })

        // Resample: give each particle a distinct road state, skew the
        // weights, resample; each new particle carries its ancestor's state
        // (identified through its unique offRoadM).
        var e = engine
        for i in e.roadEdge.indices {
            e.roadEdge[i] = UInt32(i)
            e.roadLevel[i] = Int8(i % 11 - 5)
            e.offRoadM[i] = Double(i)
            e.east[i] = 1000 + Double(i)  // ancestor tag
            e.logWeight[i] = i % 3 == 0 ? 0 : -50
        }
        e.normalizeWeights()
        e.resampleIfNeeded()
        #expect(e.counters.resamples > engine.counters.resamples)
        for i in e.east.indices {
            let k = Int(e.east[i] - 1000)
            #expect(k % 3 == 0)
            #expect(e.roadEdge[i] == UInt32(k) && e.roadLevel[i] == Int8(k % 11 - 5) && e.offRoadM[i] == Double(k))
        }

        // Reseed, directly: resampling off (it would also clear road state
        // by copying), every particle on a distinct, non-default road
        // state and heading east (≈ 90°–101°), so a clean fix with course
        // north has no support and reseeds half the cloud. A reseeded
        // particle is the one now heading north (σ 2°); it is on no road,
        // unknown level, 0 m; every other keeps exactly its state.
        var r = NavigationEngine(config: Self.config(particles: 200) { $0.resampleESSFraction = 0 }, roads: net)
        for input in inputs { r.ingest(input) }
        let n = r.heading.count
        for i in 0..<n {
            r.heading[i] = .pi / 2 + Double(i) / Double(n) * 0.2
            r.roadEdge[i] = 0
            r.roadLevel[i] = Int8(i % 7 - 3)
            r.offRoadM[i] = 1 + Double(i)
        }
        let tagged = r
        let p = S.plane.geodetic(east: 0, north: drive.truth(at: 30).north - 500)
        r.ingest(.location(LocationSample(latitude: p.latitude, longitude: p.longitude, altitude: 0, horizontalAccuracy: 5,
                                          verticalAccuracy: -1, speed: 12, speedAccuracy: 0.3, course: 0, courseAccuracy: 2,
                                          receivedT: S.ms(30.05), ageS: 0.05), at: S.ms(30)))
        #expect(r.counters.reseeds == tagged.counters.reseeds + 1)
        #expect(r.counters.resamples == tagged.counters.resamples && r.counters.roadUpdates == tagged.counters.roadUpdates)
        let reseeded = (0..<n).filter { abs(sin(r.heading[$0])) < sin(20 * Double.pi / 180) && cos(r.heading[$0]) > 0 }
        // 100 draws with replacement out of 200: ~79 distinct particles.
        #expect(reseeded.count > 50 && reseeded.count <= 100, "\(reseeded.count) reseeded")
        for i in 0..<n {
            if reseeded.contains(i) {
                #expect(r.roadEdge[i] == RoadMatcher.noEdge && r.roadLevel[i] == RoadGeometry.unknownLevel && r.offRoadM[i] == 0,
                        "reseeded particle \(i)")
            } else {
                #expect(r.heading[i] == tagged.heading[i])
                #expect(r.roadEdge[i] == 0 && r.roadLevel[i] == tagged.roadLevel[i] && r.offRoadM[i] == tagged.offRoadM[i],
                        "kept particle \(i)")
            }
        }

        // Manual reset: a pin 2 km away resets every particle's road state.
        var m = engine
        let far = S.plane.geodetic(east: 2000, north: 0)
        m.ingest(.manualFix(ManualFixSample(latitude: far.latitude, longitude: far.longitude, pressedT: S.ms(30.01),
                                            mapSpanM: 360, speedSource: "obd", gateSpeedKmh: 0), at: S.ms(30.01)))
        #expect(m.counters.manualResets == engine.counters.manualResets + 1)
        #expect(m.roadEdge.allSatisfy { $0 == RoadMatcher.noEdge })
        #expect(m.roadLevel.allSatisfy { $0 == RoadGeometry.unknownLevel })
        #expect(m.offRoadM.allSatisfy { $0 == 0 })
    }
}
