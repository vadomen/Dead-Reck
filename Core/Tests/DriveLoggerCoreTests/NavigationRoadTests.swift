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

    // MARK: 3. A road missing from OSM: NavigationRoadOffRoadTests (open)

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

    @Test("4. Step 5: a particle takes e* only with responsibility ≥ 0.5; otherwise it keeps its edge and adds Δs off-road")
    func bookkeepingThreshold() throws {
        let net = try Self.network([Self.street(1, from: (0, -3000), to: (0, 3000))])
        let edge = UInt32(0)
        let config = Self.config(particles: 100) { $0.roadSplitSigmaM = 1000; $0.resampleESSFraction = 0 }
        var engine = NavigationEngine(config: config, roads: net)
        let p = S.plane.geodetic(east: 0, north: 0)
        engine.ingest(.manualFix(ManualFixSample(latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(0.05),
                                                 mapSpanM: 360, speedSource: "unknown"), at: S.ms(0.05)))
        // Even particles on the road, odd ones 25 m off it (inside the
        // gate but r < 0.5: on-road density there is below ε · L_off).
        for i in engine.east.indices {
            engine.east[i] = i % 2 == 0 ? 1 : 25
            engine.north[i] = 0
            engine.covEE[i] = 4; engine.covEN[i] = 0; engine.covNN[i] = 4
            engine.heading[i] = 0
            engine.roadEdge[i] = RoadMatcher.noEdge
            engine.offRoadM[i] = 10
        }
        var after = engine
        after.roadUpdate(evidenceDistanceM: 30)
        for i in after.east.indices {
            if i % 2 == 0 {
                #expect(after.roadEdge[i] == edge && after.offRoadM[i] == 0)
            } else {
                #expect(after.roadEdge[i] == RoadMatcher.noEdge && after.offRoadM[i] == 40)
            }
        }
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
        // southbound particle takes it, and a northbound one has only the
        // northbound carriageway 15 m away (P wide enough that it is the
        // likelier explanation: r ≥ 0.5). Without the oneway rule the
        // northbound particle would take the road it sits on.
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

    @Test("8. Fix gate: slow, off-road cloud, network fix, or outside coverage: never gated")
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

        // Reseed: a clean fix while heading is unknown reseeds half the
        // cloud; those particles are on no road, unknown level, 0 m.
        var r = engine
        for i in r.heading.indices { r.heading[i] = Double(i) / Double(r.heading.count) * 2 * .pi }
        for i in r.offRoadM.indices { r.offRoadM[i] = 77 }
        let p = S.plane.geodetic(east: 0, north: drive.truth(at: 30).north - 500)
        r.ingest(.location(LocationSample(latitude: p.latitude, longitude: p.longitude, altitude: 0, horizontalAccuracy: 5,
                                          verticalAccuracy: -1, speed: 12, speedAccuracy: 0.3, course: 0, courseAccuracy: 2,
                                          receivedT: S.ms(30.05), ageS: 0.05), at: S.ms(30)))
        #expect(r.counters.reseeds == engine.counters.reseeds + 1)
        let cleared = r.offRoadM.indices.filter { r.offRoadM[$0] == 0 }
        #expect(cleared.count > 50 || r.counters.resamples > engine.counters.resamples)

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
