import Foundation
import Testing

@testable import DriveLoggerCore

/// N3-FIXPIN: a manual pin against a GNSS source (docs/NAVIGATION.md, "Pin
/// against a GNSS source"). Synthetic drives near (0, 0) on hand-written
/// street grids: no real place, date or recording is involved.
@Suite("Navigation pin against a GNSS source (N3-FIXPIN)")
struct NavigationFixPinTests {
    typealias S = SyntheticDrive
    typealias R = NavigationRoadTests

    /// The drive starts here (plane metres); the fixes of a shifted source
    /// are the truth plus `offset`: 288 m @56°, 40 m from every
    /// heading-compatible street of the grid (inside the 50 m fix gate, as
    /// on drive-10), and onto the grid again when shifted back.
    static let base = (east: 0.0, north: -300.0)
    static let offset = (east: 240.0, north: 160.0)

    /// North `northS` s at 10 m/s, a 90° right turn over 3 s, east `eastS` s.
    static func lDrive(northS: Double = 40, eastS: Double = 60) -> S {
        S(initialHeadingDeg: 0, initialSpeed: 10, [
            .straight(seconds: northS, speed: 10), .turn(degrees: 90, seconds: 3, speed: 10),
            .straight(seconds: eastS, speed: 10),
        ])
    }

    static func truth(_ drive: S, _ t: Double) -> (east: Double, north: Double) {
        let s = drive.truth(at: t)
        return (s.east + base.east, s.north + base.north)
    }

    /// A 100 m street grid aligned with the drive's legs: north–south
    /// streets through the first leg, east–west ones through the last.
    static func roads(_ drive: S) throws -> RoadNetwork {
        try R.network(streets(drive).map { R.street($0.id, from: $0.a, to: $0.b) })
    }

    /// `roads(drive)`'s streets, plane metres.
    static func streets(_ drive: S) -> [(id: Int64, a: (Double, Double), b: (Double, Double))] {
        let x0 = truth(drive, 1).east
        let y1 = truth(drive, drive.duration - 1).north
        var out: [(id: Int64, a: (Double, Double), b: (Double, Double))] = []
        var id: Int64 = 1
        for k in -15...15 {
            let x = x0 + Double(k) * 100, y = y1 + Double(k) * 100
            out.append((id, (x, -1800), (x, 1800))); id += 1
            out.append((id, (-1800, y), (1800, y))); id += 1
        }
        return out
    }

    /// `roads(drive)` with the streets at the same metres of `plane`
    /// instead of `S.plane` (R37.2-1), on a pack grid centred there.
    static func roads(_ drive: S, in plane: LocalTangentPlane) throws -> RoadNetwork {
        func e7(_ east: Double, _ north: Double) -> RoadPoint {
            let g = plane.geodetic(east: east, north: north)
            return RoadPoint(latE7: Int32((g.latitude * 1e7).rounded()), lonE7: Int32((g.longitude * 1e7).rounded()))
        }
        let lines = streets(drive).map { street -> String in
            let nodes = [(street.id * 10, street.a), (street.id * 10 + 1, street.b)].map { id, m in
                let p = e7(m.0, m.1)
                return "n\(id)x\(RoadFixture.degrees(p.lonE7))y\(RoadFixture.degrees(p.latE7))"
            }.joined(separator: ",")
            return "w\(street.id) v1 dV c0 t2020-01-01T00:00:00Z i0 u Thighway=residential N\(nodes)"
        }
        let grid = RoadGrid(southWest: e7(-2500, -2500), northEast: e7(2500, 2500))
        return try RoadNetwork(packs: [RoadFixture.build(lines, grid: grid)])
    }

    /// `inputs` (positions in `S.plane`) with every fix and pin at the same
    /// metres of `plane` (R37.2-1).
    static func moved(_ inputs: [NavigationInput], to plane: LocalTangentPlane) -> [NavigationInput] {
        func move(_ latitude: inout Double, _ longitude: inout Double) {
            let m = S.plane.enu(latitude: latitude, longitude: longitude)
            (latitude, longitude) = plane.geodetic(east: m.east, north: m.north)
        }
        return inputs.map { input in
            switch input {
            case .location(var s, let t):
                move(&s.latitude, &s.longitude)
                return .location(s, at: t)
            case .manualFix(var s, let t):
                move(&s.latitude, &s.longitude)
                return .manualFix(s, at: t)
            default:
                return input
            }
        }
    }

    /// The drive's inputs: 1 Hz fixes (clean, `accuracy`, with course and
    /// speed) shifted by `offset` before `offsetUntil`, from `accessory`;
    /// `network`: speedless 50 m fixes instead. Pins at the truth plus
    /// their own displacement, at 36 km/h (σ 31.6 m).
    static func inputs(_ drive: S, offsetUntil: Double = .infinity, accuracy: Double = 10, accessory: Bool? = true,
                       network: Bool = false, pins: [(t: Double, dEast: Double, dNorth: Double)] = [])
        -> [NavigationInput] {
        let clean = S.cleanFix(accuracy: accuracy)
        let pinEvents = pins.map { p -> LogEvent in
            let at = truth(drive, p.t)
            return R.pin(at: p.t, east: at.east + p.dEast, north: at.north + p.dNorth, kmh: 36)
        }
        let events = drive.events(seed: 7, gyroNoise: 0.002, fix: { t, state, rng in
            guard var f = clean(t, state, &rng) else { return nil }
            f.east += base.east
            f.north += base.north
            if t < offsetUntil {
                f.east += offset.east
                f.north += offset.north
            }
            if network {
                f.accuracy = 50
                f.speed = -1; f.speedAccuracy = -1; f.course = -1; f.courseAccuracy = -1
            }
            return f
        }, extra: pinEvents)
        return S.inputs(events).map { input in
            guard case .location(var sample, let t) = input else { return input }
            sample.accessory = accessory
            return .location(sample, at: t)
        }
    }

    static func config(roads: Int = 0, twoPin: Int = 0, _ edit: (inout NavigationConfig) -> Void = { _ in })
        -> NavigationConfig {
        R.config(particles: 400) {
            $0.roadFixPinCheck = roads
            $0.fixPinTwoPinCheck = twoPin
            edit(&$0)
        }
    }

    struct Run {
        var engine: NavigationEngine
        /// The engine's decision after each manual fix, in order.
        var decisions: [FixPinDecision?] = []
        /// 1 Hz estimates, by whole second (state before any later input).
        var estimates: [(t: Double, estimate: NavigationEstimate)] = []
        /// The accessory source's agreement run length after every
        /// location input, with its fix time.
        var agree: [(t: Double, count: Int, downweighted: Bool)] = []
        /// After each manual fix: the counters, and each source's last pin `ns`.
        var pinStates: [(counters: NavigationCounters, lastPinNs: [Int64?])] = []
    }

    static func run(_ inputs: [NavigationInput], config: NavigationConfig, roads: RoadNetwork?,
                    cache: Int = RoadMatcher.defaultCacheCapacity) -> Run {
        var run = Run(engine: NavigationEngine(config: config, roads: roads, roadCacheCapacity: cache))
        var next = 1.0
        for input in inputs {
            while input.arrival > S.ms(next) {
                if let e = run.engine.estimate(at: S.ms(next)) { run.estimates.append((next, e)) }
                next += 1
            }
            run.engine.ingest(input)
            switch input {
            case .manualFix:
                run.decisions.append(run.engine.lastFixPinDecision)
                run.pinStates.append((run.engine.counters, run.engine.fixPin.map { $0.lastPin?.ns }))
            case .location(_, let t):
                if let source = run.engine.fixPin.first {
                    run.agree.append((t.seconds, source.agreeCount, source.isDownweighted))
                }
            default: break
            }
        }
        return run
    }

    /// Estimate error against the truth at each 1 Hz estimate in `from...to`.
    static func errors(_ run: Run, _ drive: S, from: Double, to: Double) -> [Double] {
        run.estimates.filter { $0.t >= from && $0.t <= to }.map { item in
            let p = S.plane.enu(latitude: item.estimate.latitude, longitude: item.estimate.longitude)
            let at = truth(drive, item.t)
            return ((p.east - at.east) * (p.east - at.east) + (p.north - at.north) * (p.north - at.north)).squareRoot()
        }
    }

    /// Everything the filter computed (not the counters).
    static func sameEstimates(_ a: Run, _ b: Run) -> Bool {
        R.state(a.engine) == R.state(b.engine) && a.estimates.map(\.estimate) == b.estimates.map(\.estimate)
    }

    static var offsetM: Double { (offset.east * offset.east + offset.north * offset.north).squareRoot() }

    // MARK: 1. drive-10-like

    @Test("1. Shifted accessory fixes, pin at the truth: roads verdict pin, source down-weighted, estimate stays at the truth")
    func driveTenLike() throws {
        let drive = Self.lDrive(eastS: 60)
        let net = try Self.roads(drive)
        let inputs = Self.inputs(drive, pins: [(30.03, 0, 0)])
        let on = Self.run(inputs, config: Self.config(roads: 1), roads: net)
        let off = Self.run(inputs, config: Self.config(), roads: net)

        let decision = try #require(on.decisions.first ?? nil)
        #expect(decision.significant && !decision.refinement)
        #expect(abs(decision.offsetM - Self.offsetM) < 15, "offset \(decision.offsetM) m")
        let source = try #require(decision.sources.first { $0.source == "accessory" })
        #expect(decision.sources.count == 1, "the phone has no fix")
        #expect(source.fixesInWindow >= 20)
        let road = try #require(source.road)
        #expect(road.verdict == .pin, "\(decision.text)")
        #expect((road.asGivenM ?? 0) > 30 && (road.shiftedM ?? 99) < 8, "\(decision.text)")
        #expect(source.downweighted && source.twoPin == nil)
        #expect(on.engine.fixPin[0].isDownweighted)

        let c = on.engine.counters
        #expect(c.fixPinSignificantPins == 1 && c.fixPinRoadVerdictPinAccessory == 1 && c.fixPinDownweightsAccessory == 1)
        #expect(c.manualResets == 1 && off.engine.counters.manualResets == 1, "the pin resets the cloud in both")
        // The next 60 s of fixes: down-weighted, the estimate stays at the truth.
        let after = Self.errors(on, drive, from: 31, to: 91)
        #expect(after.count >= 60)
        #expect(after.max()! < 40, "max error \(after.max()!) m against an offset of \(Self.offsetM) m")
        #expect(Self.errors(off, drive, from: 80, to: 91).min()! > 200, "key off follows the fixes")
        // Course and speed of the down-weighted source still used, and counted.
        #expect(c.fixPinDownweightedFixesAccessory >= 60)
        #expect(c.fixPinCourseUpdatesDownweightedAccessory >= 55 && c.fixPinSpeedUpdatesDownweightedAccessory >= 55)
        #expect(c.fixPinDownweightedFixesPhone == 0 && c.fixPinRestoresByAgreementAccessory == 0)
        // Deterministic: the same run twice is bit-identical; so is a run
        // with a one-cell matcher cache (only work counters may differ).
        let again = Self.run(inputs, config: Self.config(roads: 1), roads: net)
        #expect(Self.sameEstimates(on, again) && on.engine.counters == again.engine.counters)
        let small = Self.run(inputs, config: Self.config(roads: 1), roads: net, cache: 1)
        #expect(Self.sameEstimates(on, small) && on.engine.counters == small.engine.counters)
    }

    @Test("Road arbiter: the per-fix distance cache returns exactly what fresh queries do")
    func roadCacheExact() throws {
        let drive = Self.lDrive(eastS: 60)
        let net = try Self.roads(drive)
        let inputs = Self.inputs(drive, pins: [(30.03, 0, 0)])
        var engine = Self.run(inputs, config: Self.config(roads: 1), roads: net).engine
        let shift = try #require(engine.fixPin[0].offset)
        // The engine's own plane (anchored at its first fix), as the cache assumes.
        let plane = try #require(engine.tangentPlane)
        #expect(engine.counters.fixPinRoadRechecks >= 5)
        let queriesBefore = engine.counters.fixPinRoadDistanceQueries
        let cached = engine.roadFixPinComparison(.accessory, shiftEast: shift.east, shiftNorth: shift.north, plane: plane)
        // Only the fixes since the last 10 s recheck are new.
        #expect(engine.counters.fixPinRoadDistanceQueries - queriesBefore <= 2 * 11, "the ring was cached")
        var fresh = engine
        fresh.clearFixPinRoadCache()
        let recomputed = fresh.roadFixPinComparison(.accessory, shiftEast: shift.east, shiftNorth: shift.north, plane: plane)
        #expect(fresh.counters.fixPinRoadDistanceQueries - engine.counters.fixPinRoadDistanceQueries == 2 * recomputed.fixes)
        #expect(cached.a == recomputed.a && cached.b == recomputed.b && cached.fixes == recomputed.fixes
                && cached.pathM == recomputed.pathM)
        #expect((cached.a ?? 0) > 30 && (cached.b ?? 99) < 8)
        // Another shift recomputes B only.
        let before = engine.counters.fixPinRoadDistanceQueries
        let other = engine.roadFixPinComparison(.accessory, shiftEast: 0, shiftNorth: 0, plane: plane)
        #expect(engine.counters.fixPinRoadDistanceQueries - before == other.fixes)
        #expect(other.a == other.b && other.a == cached.a)
    }

    // MARK: 2. drive-7-like

    @Test("2. Genuine on-road fixes, pin 150 m along-track off: verdict fixes, every estimate bit-identical to key off")
    func driveSevenLike() throws {
        let drive = Self.lDrive(eastS: 40)
        let net = try Self.roads(drive)
        // Phone fixes on the roads; the pin on the east leg, 150 m too far east.
        let inputs = Self.inputs(drive, offsetUntil: -1, accuracy: 5, accessory: false, pins: [(58.03, 150, 0)])
        let on = Self.run(inputs, config: Self.config(roads: 1, twoPin: 1), roads: net)
        let off = Self.run(inputs, config: Self.config(), roads: net)

        let decision = try #require(on.decisions.first ?? nil)
        #expect(decision.significant, "\(decision.text)")
        let source = try #require(decision.sources.first)
        #expect(source.source == "phone" && source.road?.verdict == .fixes, "\(decision.text)")
        #expect(!source.downweighted)
        #expect(on.engine.counters.fixPinRoadVerdictFixesPhone == 1 && on.engine.counters.fixPinDownweightsPhone == 0)
        // Verdict "fixes" only counts: the engine is exactly the key-off one.
        #expect(Self.sameEstimates(on, off))
        var counters = on.engine.counters
        for key in [\NavigationCounters.fixPinSignificantPins, \.fixPinRoadVerdictFixesPhone, \.fixPinRoadDistanceQueries] {
            counters[keyPath: key] = 0
        }
        #expect(counters == off.engine.counters)
    }

    // MARK: 3. No roads, one pin

    @Test("3. No roads, one pin, both keys on: bit-identical to key off")
    func noRoadsOnePin() throws {
        let drive = Self.lDrive(eastS: 40)
        let inputs = Self.inputs(drive, pins: [(30.03, 0, 0)])
        let on = Self.run(inputs, config: Self.config(roads: 1, twoPin: 1), roads: nil)
        let off = Self.run(inputs, config: Self.config(), roads: nil)
        #expect(Self.sameEstimates(on, off))
        let decision = try #require(on.decisions.first ?? nil)
        #expect(decision.significant && decision.sources.count == 1)
        #expect(decision.sources[0].road == nil && decision.sources[0].twoPin == nil && !decision.sources[0].downweighted)
        #expect(!on.engine.fixPin[0].isDownweighted && on.engine.counters.fixPinDownweightsAccessory == 0)
    }

    // MARK: 4–5. Two pins, no roads

    @Test("4. No roads, two agreeing pins 500 m apart across a 90° turn: two-pin verdict pin")
    func twoPinsWithTurn() throws {
        let drive = Self.lDrive(eastS: 60)
        let inputs = Self.inputs(drive, pins: [(30.03, 0, 0), (80.03, 0, 0)])
        let on = Self.run(inputs, config: Self.config(twoPin: 1), roads: nil)
        let off = Self.run(inputs, config: Self.config(), roads: nil)

        #expect(on.decisions.count == 2)
        let first = try #require(on.decisions[0])
        #expect(first.sources.first?.twoPin == nil, "one pin alone: no verdict")
        let second = try #require(on.decisions[1])
        let w = try #require(second.sources.first?.twoPin)
        #expect(w.verdict == .pin && w.chi2 <= 5.991, "\(second.text)")
        #expect(abs(w.pathM - 500) < 25 && abs(w.turnDeg - 90) < 5, "\(second.text)")
        #expect(second.sources.first?.downweighted == true && on.engine.fixPin[0].isDownweighted)
        #expect(on.engine.counters.fixPinTwoPinVerdictPinAccessory == 1)
        let after = Self.errors(on, drive, from: 81, to: 102)
        #expect(after.max()! < 45, "max error \(after.max()!) m")
        #expect(Self.errors(off, drive, from: 95, to: 102).min()! > 200)
        // Before the second pin the two runs are the same engine.
        #expect(on.estimates.prefix(80).map(\.estimate) == off.estimates.prefix(80).map(\.estimate))
    }

    @Test("5. The same two pins on a straight drive (no turn): no verdict, bit-identical to key off")
    func twoPinsStraight() throws {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 10, [.straight(seconds: 100, speed: 10)])
        let inputs = Self.inputs(drive, pins: [(30.03, 0, 0), (75.03, 0, 0)])
        let on = Self.run(inputs, config: Self.config(twoPin: 1), roads: nil)
        let off = Self.run(inputs, config: Self.config(), roads: nil)
        let w = try #require(on.decisions.last??.sources.first?.twoPin)
        #expect(w.verdict == nil && w.chi2 <= 5.991 && w.pathM >= 300 && abs(w.turnDeg) < 45, "\(w)")
        #expect(on.engine.counters.fixPinTwoPinVerdictNoneAccessory == 1 && on.engine.counters.fixPinDownweightsAccessory == 0)
        #expect(Self.sameEstimates(on, off))
    }

    // MARK: 6. Win-back

    @Test("6. The offset ends after the down-weighting: restored by agreement, the estimate follows the fixes")
    func winBackByAgreement() throws {
        let drive = Self.lDrive(eastS: 120)
        let inputs = Self.inputs(drive, offsetUntil: 100, pins: [(30.03, 0, 0), (80.03, 0, 0)])
        let on = Self.run(inputs, config: Self.config(twoPin: 1), roads: nil)
        let c = on.engine.counters
        #expect(c.fixPinDownweightsAccessory == 1 && c.fixPinRestoresByAgreementAccessory == 1)
        #expect(c.fixPinRestoresByRoadsAccessory == 0 && c.fixPinRestoresByPinAccessory == 0)
        #expect(!on.engine.fixPin[0].isDownweighted)
        // Restored at ≥ 30 s and ≥ 15 fixes after the first agreeing fix.
        let restoredAt = try #require(on.agree.first { $0.t > 81 && !$0.downweighted }?.t)
        #expect(restoredAt >= 129 && restoredAt <= 136, "restored at \(restoredAt) s")
        // Down-weighted fixes: 81 s … restore.
        #expect(abs(Double(c.fixPinDownweightedFixesAccessory) - (restoredAt - 81)) <= 2)
        // The fixes are the truth again, and the estimate is on them.
        #expect(Self.errors(on, drive, from: 150, to: 162).max()! < 10)
    }

    @Test("6. Win-back by roads: once the ring is on the roads as given and off them shifted")
    func winBackByRoads() throws {
        let drive = Self.lDrive(eastS: 100)
        let net = try Self.roads(drive)
        let inputs = Self.inputs(drive, offsetUntil: 50, pins: [(30.03, 0, 0)])
        // Agreement disabled (an hour), so only roads can restore.
        let on = Self.run(inputs, config: Self.config(roads: 1) { $0.fixPinRestoreS = 3600 }, roads: net)
        let c = on.engine.counters
        #expect(c.fixPinDownweightsAccessory == 1 && c.fixPinRestoresByRoadsAccessory == 1, "\(c)")
        #expect(c.fixPinRoadRechecks >= 5)
        let restoredAt = try #require(on.agree.first { $0.t > 31 && !$0.downweighted }?.t)
        // The 90 s ring is mostly genuine from ~106 s; rechecks every 10 s.
        #expect(restoredAt > 100 && restoredAt < 125, "restored at \(restoredAt) s")
        #expect(Self.errors(on, drive, from: 130, to: 142).max()! < 10)
    }

    @Test("6. Win-back by a pin: a new pin agreeing with the source's newest fix restores it")
    func winBackByPin() throws {
        let drive = Self.lDrive(eastS: 60)
        let inputs = Self.inputs(drive, offsetUntil: 90, pins: [(30.03, 0, 0), (80.03, 0, 0), (95.03, 0, 0)])
        let on = Self.run(inputs, config: Self.config(twoPin: 1), roads: nil)
        let c = on.engine.counters
        #expect(c.fixPinDownweightsAccessory == 1 && c.fixPinRestoresByPinAccessory == 1, "\(c)")
        let third = try #require(on.decisions[2]?.sources.first)
        #expect(third.wasDownweighted && third.restored && (third.sourceChi2 ?? 99) <= 9)
        #expect(!on.engine.fixPin[0].isDownweighted)
    }

    // MARK: 7. The offset persists

    @Test("7. The offset persists: never restored; a fix still offset by d never counts as agreeing")
    func offsetPersists() throws {
        let drive = Self.lDrive(eastS: 140)
        let net = try Self.roads(drive)
        for (label, config, roads) in [("roads", Self.config(roads: 1), Optional(net)),
                                       ("two-pin", Self.config(twoPin: 1), nil)] {
            let pins: [(t: Double, dEast: Double, dNorth: Double)] = roads != nil ? [(30.03, 0, 0)]
                : [(30.03, 0, 0), (80.03, 0, 0)]
            let on = Self.run(Self.inputs(drive, pins: pins), config: config, roads: roads)
            let from = pins.last!.t
            let after = on.agree.filter { $0.t > from }
            #expect(after.count > 90, "\(label): longer than the window and fixPinRestoreS")
            // Against the inflated σ (≥ |d|) an offset fix would agree
            // (χ² ≈ |d|² / (|d|² + P) < 1); against the claimed σ it must not.
            #expect(after.allSatisfy { $0.downweighted && $0.count == 0 }, "\(label): an offset fix agreed")
            let c = on.engine.counters
            #expect(c.fixPinRestoresByAgreementAccessory + c.fixPinRestoresByRoadsAccessory + c.fixPinRestoresByPinAccessory == 0,
                    "\(label)")
            #expect(on.engine.fixPin[0].isDownweighted, "\(label)")
            #expect(Self.errors(on, drive, from: from + 1, to: drive.duration - 1).max()! < 60, "\(label)")
        }
    }

    // MARK: 8. Network fixes

    @Test("8. Network-only fixes: never judged, bit-identical to key off")
    func networkOnly() throws {
        let drive = Self.lDrive(eastS: 60)
        let net = try Self.roads(drive)
        let inputs = Self.inputs(drive, network: true, pins: [(30.03, 0, 0), (80.03, 0, 0)])
        let on = Self.run(inputs, config: Self.config(roads: 1, twoPin: 1), roads: net)
        let off = Self.run(inputs, config: Self.config(), roads: net)
        #expect(on.decisions.count == 2 && on.decisions.allSatisfy { $0?.sources.isEmpty == true })
        #expect(!on.engine.counters.anyFixPin)
        #expect(on.engine.fixPin.allSatisfy { $0.ring.isEmpty })
        #expect(Self.sameEstimates(on, off) && on.engine.counters == off.engine.counters)
    }

    // MARK: 9. Config

    @Test("9. Config: the keys are encoded, decode tolerantly, default off; invalid values refused; road key is road-only")
    func configKeys() throws {
        let keys = ["fixPinWindowS", "fixPinTwoPinCheck", "fixPinTwoPinMinPathM", "fixPinTwoPinMinTurnDeg",
                    "fixPinInflation", "fixPinRestoreS", "roadFixPinCheck", "roadFixPinOffRoadM", "roadFixPinMarginM"]
        let json = try #require(try JSONSerialization.jsonObject(with: NavigationConfig().canonicalJSON()) as? [String: Any])
        let defaults: [String: Double] = ["fixPinWindowS": 90, "fixPinTwoPinCheck": 0, "fixPinTwoPinMinPathM": 300,
                                          "fixPinTwoPinMinTurnDeg": 45, "fixPinInflation": 1, "fixPinRestoreS": 30,
                                          "roadFixPinCheck": 0, "roadFixPinOffRoadM": 15, "roadFixPinMarginM": 10]
        for key in keys {
            #expect((json[key] as? NSNumber)?.doubleValue == defaults[key], "\(key)")
        }
        #expect(NavigationConfig().invalidReason == nil)
        // An old config without them decodes with the defaults.
        var old = json
        for key in keys { old.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(NavigationConfig.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded == NavigationConfig())
        // Road-only (inert without roads, N3-CMPHASH) only for the road key family.
        #expect(["roadFixPinCheck", "roadFixPinOffRoadM", "roadFixPinMarginM"].allSatisfy(NavigationConfig.roadOnlyKeys.contains))
        #expect(!NavigationConfig.roadOnlyKeys.contains("fixPinTwoPinCheck"))

        func refused(_ edit: (inout NavigationConfig) -> Void) -> String? {
            var c = NavigationConfig()
            edit(&c)
            return c.invalidReason
        }
        #expect(refused { $0.roadFixPinCheck = 2 }?.contains("roadFixPinCheck") == true)
        #expect(refused { $0.roadFixPinCheck = -1 } != nil)
        #expect(refused { $0.fixPinTwoPinCheck = 2 }?.contains("fixPinTwoPinCheck") == true)
        for bad in [0.0, -1, .infinity, .nan, NavigationConfig.maxFixPinWindowS + 1] {
            #expect(refused { $0.fixPinWindowS = bad } != nil, "fixPinWindowS \(bad)")
        }
        #expect(refused { $0.fixPinWindowS = NavigationConfig.maxFixPinWindowS } == nil)
        for bad in [0.0, -1, .infinity, .nan] { #expect(refused { $0.fixPinInflation = bad } != nil, "inflation \(bad)") }
        for bad in [-1.0, 361, .nan] { #expect(refused { $0.fixPinTwoPinMinTurnDeg = bad } != nil, "turn \(bad)") }
        for key in [\NavigationConfig.fixPinTwoPinMinPathM, \.fixPinRestoreS, \.roadFixPinOffRoadM, \.roadFixPinMarginM] {
            for bad in [-1.0, .infinity, .nan] { #expect(refused { $0[keyPath: key] = bad } != nil, "\(key) \(bad)") }
            #expect(refused { $0[keyPath: key] = 0 } == nil, "\(key) 0")
        }
        // Validation does not clamp them: refused is refused.
        var c = NavigationConfig()
        c.fixPinWindowS = -5
        #expect(c.validated().fixPinWindowS == -5)
    }

    // MARK: Each key alone, no pin

    @Test("Each key on alone, and both, on a drive without pins: bit-identical to key off, no counter moves")
    func keysWithoutPins() throws {
        let (net, events, _) = try R.gridDrive()
        // gridDrive's pins removed; its clean fixes stay.
        let inputs = events.filter { if case .manualFix = $0 { false } else { true } }
        for roads in [Optional(net), nil] {
            let off = Self.run(inputs, config: Self.config(), roads: roads)
            for (r, w) in [(1, 0), (0, 1), (1, 1)] {
                let on = Self.run(inputs, config: Self.config(roads: r, twoPin: w), roads: roads)
                #expect(Self.sameEstimates(on, off), "roads \(roads != nil), keys \(r)/\(w)")
                #expect(on.engine.counters == off.engine.counters && !on.engine.counters.anyFixPin)
            }
        }
    }

    // MARK: Re-anchor (R37.1-1)

    /// A plane point of `engine` as metres in the fixed test plane.
    static func inTestPlane(_ engine: NavigationEngine, _ east: Double, _ north: Double,
                            plane: LocalTangentPlane = S.plane) throws -> (east: Double, north: Double) {
        let g = try #require(engine.tangentPlane).geodetic(east: east, north: north)
        let p = plane.enu(latitude: g.latitude, longitude: g.longitude)
        return (p.east, p.north)
    }

    /// |∂e'/∂n| of the map from `off`'s plane to `on`'s at `fix` (in
    /// `off`'s plane): what a re-anchor's Jacobian must carry.
    static func planeShear(from off: NavigationEngine, to on: NavigationEngine, at fix: FixPinSource.Fix) throws -> Double {
        let old = try #require(off.tangentPlane), new = try #require(on.tangentPlane)
        func east(_ e: Double, _ n: Double) -> Double {
            let g = old.geodetic(east: e, north: n)
            return new.enu(latitude: g.latitude, longitude: g.longitude).east
        }
        return abs(east(fix.east, fix.north + 1) - east(fix.east, fix.north - 1)) / 2
    }

    static func distance(_ a: (east: Double, north: Double), _ b: (east: Double, north: Double)) -> Double {
        ((a.east - b.east) * (a.east - b.east) + (a.north - b.north) * (a.north - b.north)).squareRoot()
    }

    /// The decision-relevant fix-pin counters (the road distance queries
    /// are work: a re-anchor clears the per-fix cache).
    static var fixPinVerdictCounters: [KeyPath<NavigationCounters, Int>] { [
        \.fixPinSignificantPins, \.fixPinRoadVerdictPinAccessory, \.fixPinRoadVerdictFixesAccessory,
        \.fixPinRoadVerdictNoneAccessory, \.fixPinTwoPinVerdictPinAccessory, \.fixPinTwoPinVerdictNoneAccessory,
        \.fixPinDownweightsAccessory, \.fixPinDownweightedFixesAccessory, \.fixPinCourseUpdatesDownweightedAccessory,
        \.fixPinSpeedUpdatesDownweightedAccessory, \.fixPinRestoresByRoadsAccessory, \.fixPinRestoresByAgreementAccessory,
        \.fixPinRestoresByPinAccessory, \.fixPinReseedsBlocked, \.fixPinRejectedOffRoadDownweightedAccessory,
        \.fixPinRoadRechecks,
    ] }

    /// At latitude 0 the old→new plane map of a re-anchor is a translation
    /// (J = I); at 60° (R37.2-1) a re-anchor east of the old anchor shears
    /// it, ∂e'/∂n ≈ −Δe · tan φ / R, so a dropped or transposed Jacobian at
    /// the call site moves the carried offset, last pin and ring courses.
    @Test("Re-anchor while down-weighted (both keys): ring, offset and last pin carried into the new plane; verdicts and win-back unchanged",
          arguments: [0.0, 60.0])
    func reanchorWhileDownweighted(latitude: Double) throws {
        let plane = LocalTangentPlane(latitude: latitude, longitude: 0)
        let drive = Self.lDrive(eastS: 140)
        let net = latitude == 0 ? try Self.roads(drive) : try Self.roads(drive, in: plane)
        // The offset persists (never restored), or ends at 100 s (restored by
        // roads after both re-anchors, from a ring that straddles them).
        // Agreement disabled, so only roads can restore.
        for offsetUntil in [Double.infinity, 100] {
            let label = "latitude \(latitude), offset until \(offsetUntil)"
            let built = Self.inputs(drive, offsetUntil: offsetUntil, pins: [(30.03, 0, 0)])
            let inputs = latitude == 0 ? built : Self.moved(built, to: plane)
            let fixed = Self.config(roads: 1, twoPin: 1) { $0.fixPinRestoreS = 3600 }
            let moving = Self.config(roads: 1, twoPin: 1) { $0.fixPinRestoreS = 3600; $0.reanchorDistanceM = 500 }
            #expect(moving.invalidReason == nil && moving.validated().reanchorDistanceM == 500)
            let off = Self.run(inputs, config: fixed, roads: net)
            let on = Self.run(inputs, config: moving, roads: net)
            #expect(off.engine.counters.reanchors == 0, "\(label)")
            #expect(on.engine.counters.reanchors >= 1, "\(label)")
            let a = off.engine.fixPin[0], b = on.engine.fixPin[0]

            // Verdicts and win-back: the same decisions, counters and restore time.
            #expect(on.decisions == off.decisions, "\(label)")
            for key in Self.fixPinVerdictCounters {
                #expect(on.engine.counters[keyPath: key] == off.engine.counters[keyPath: key], "\(label): \(key)")
            }
            #expect(on.agree.map(\.downweighted) == off.agree.map(\.downweighted), "\(label)")
            #expect(on.agree.map(\.count) == off.agree.map(\.count), "\(label)")
            if offsetUntil.isFinite {
                #expect(on.engine.counters.fixPinRestoresByRoadsAccessory == 1 && !b.isDownweighted, "\(label)")
                let restoredAt = try #require(on.agree.first { $0.t > 31 && !$0.downweighted }?.t)
                #expect(restoredAt > 150, "\(label): restored at \(restoredAt) s, after the re-anchors")
            } else {
                #expect(b.isDownweighted && on.engine.counters.fixPinRestoresByRoadsAccessory == 0, "\(label)")
            }

            // The ring: the same fixes at the same places on the ground, and
            // some of them older than the first re-anchor (≈ 110 s), so moved.
            #expect(a.ring.map(\.ns) == b.ring.map(\.ns), "\(label)")
            #expect((b.ring.first?.ns ?? .max) < S.ms(105).nanoseconds, "\(label)")
            var worst = 0.0, worstCourse = 0.0
            for (p, q) in zip(a.ring, b.ring) {
                worst = max(worst, Self.distance(try Self.inTestPlane(off.engine, p.east, p.north, plane: plane),
                                                 try Self.inTestPlane(on.engine, q.east, q.north, plane: plane)))
                #expect((p.course == nil) == (q.course == nil))
                if let c = p.course, let d = q.course { worstCourse = max(worstCourse, abs(remainder(c - d, 2 * .pi))) }
                #expect(p.sigma == q.sigma)
            }
            #expect(worst < 1e-6, "\(label): ring moved by \(worst) m on the ground")
            #expect(worstCourse < 1e-6, "\(label): ring course moved by \(worstCourse) rad")

            // The offset and the last pin's vector, as tips at the newest
            // fix: the same on the ground (linearised at the cloud mean;
            // measured 3e-7 m at both latitudes). At 60° the two re-anchors
            // shear the plane by ∂e'/∂n ≈ 2.6e-4, so a dropped Jacobian
            // moves each tip by 0.042 m and a transposed one by 0.075 m
            // (and turns the ring's east courses by 2.6e-4 rad).
            let pa = try #require(a.ring.last), pb = try #require(b.ring.last)
            let shear = try Self.planeShear(from: off.engine, to: on.engine, at: pa)
            #expect(latitude == 0 ? shear < 1e-7 : shear > 2e-4, "\(label): ∂e'/∂n \(shear)")
            if let oa = a.offset {
                let ob = try #require(b.offset)
                let tipA = try Self.inTestPlane(off.engine, pa.east + oa.east, pa.north + oa.north, plane: plane)
                let tipB = try Self.inTestPlane(on.engine, pb.east + ob.east, pb.north + ob.north, plane: plane)
                #expect(Self.distance(tipA, tipB) < 1e-3, "\(label): offset tip \(Self.distance(tipA, tipB)) m")
                #expect(abs((oa.east * oa.east + oa.north * oa.north).squareRoot() - Self.offsetM) < 15)
            } else {
                #expect(b.offset == nil, "\(label)")
            }
            let la = try #require(a.lastPin, "\(label)"), lb = try #require(b.lastPin, "\(label)")
            #expect(la.ns == lb.ns && la.obdM == lb.obdM && la.yaw == lb.yaw, "\(label)")
            let tipA = try Self.inTestPlane(off.engine, pa.east + la.dEast, pa.north + la.dNorth, plane: plane)
            let tipB = try Self.inTestPlane(on.engine, pb.east + lb.dEast, pb.north + lb.dNorth, plane: plane)
            #expect(Self.distance(tipA, tipB) < 1e-3, "\(label): last-pin tip \(Self.distance(tipA, tipB)) m")
            // Covariance: invariant under the near-rotation (trace, determinant).
            #expect(abs((la.ee + la.nn) - (lb.ee + lb.nn)) < 1e-3 * (la.ee + la.nn), "\(label)")
            #expect(abs((la.ee * la.nn - la.en * la.en) - (lb.ee * lb.nn - lb.en * lb.en))
                    < 1e-3 * (la.ee * la.nn - la.en * la.en), "\(label)")
            // The estimates agree (the plane change is exact up to rounding).
            let worstEstimate = zip(on.estimates, off.estimates).map { x, y in
                Self.distance(plane.enu(latitude: x.estimate.latitude, longitude: x.estimate.longitude),
                              plane.enu(latitude: y.estimate.latitude, longitude: y.estimate.longitude))
            }.max() ?? .infinity
            #expect(on.estimates.count == off.estimates.count && worstEstimate < 0.5, "\(label): estimate \(worstEstimate) m")
        }
    }

    @Test("FixPinSource.transform: positions through the map; offset, last pin, course and covariance through the Jacobian")
    func sourceTransform() throws {
        // A synthetic plane change: rotate 30° counter-clockwise, then
        // translate. J = [[cos, −sin], [sin, cos]] in (east, north).
        let a = 30 * Double.pi / 180, co = cos(a), si = sin(a)
        func map(_ e: Double, _ n: Double) -> (Double, Double) { (co * e - si * n - 500, si * e + co * n + 200) }
        var source = FixPinSource()
        source.append(.init(ns: 1, east: 100, north: 0, course: 0, sigma: 10, covered: true, roadA: 3, roadB: 4), windowNs: 100)
        source.append(.init(ns: 2, east: 0, north: 50, course: nil, sigma: 12), windowNs: 100)
        source.setRoadShift((7, 8))
        source.offset = (240, 160)
        source.lastPin = .init(ns: 5, dEast: 30, dNorth: -40, ee: 900, en: 100, nn: 400, obdM: 123, yaw: 0.5)
        source.transform(map: map, jee: co, jen: -si, jne: si, jnn: co)

        #expect(source.ring.count == 2 && source.roadShift == nil)
        let f0 = source.ring[0], f1 = source.ring[1]
        #expect(abs(f0.east - (co * 100 - 500)) < 1e-9 && abs(f0.north - (si * 100 + 200)) < 1e-9)
        #expect(abs(f1.east - (-si * 50 - 500)) < 1e-9 && abs(f1.north - (co * 50 + 200)) < 1e-9)
        #expect(f0.roadA == nil && f0.roadB == nil && f0.covered == true && f0.sigma == 10 && f1.course == nil)
        // A heading (clockwise from north) turns the other way: north (0)
        // rotated 30° counter-clockwise is a bearing of 330°.
        let course = try #require(f0.course)
        #expect(abs(course - (2 * .pi - a)) < 1e-9, "course \(course * 180 / .pi)°")
        let o = try #require(source.offset)
        #expect(abs(o.east - (co * 240 - si * 160)) < 1e-9 && abs(o.north - (si * 240 + co * 160)) < 1e-9)
        let p = try #require(source.lastPin)
        #expect(abs(p.dEast - (co * 30 + si * 40)) < 1e-9 && abs(p.dNorth - (si * 30 - co * 40)) < 1e-9)
        #expect(p.ns == 5 && p.obdM == 123 && p.yaw == 0.5)
        // P' = J P Jᵀ, written out.
        let j = [[co, -si], [si, co]], m = [[900.0, 100], [100, 400]]
        var q = [[0.0, 0], [0, 0]]
        for r in 0..<2 { for c in 0..<2 { for x in 0..<2 { for y in 0..<2 { q[r][c] += j[r][x] * m[x][y] * j[c][y] } } } }
        #expect(abs(p.ee - q[0][0]) < 1e-9 && abs(p.en - q[0][1]) < 1e-9 && abs(p.nn - q[1][1]) < 1e-9)
        #expect(abs(q[0][1] - q[1][0]) < 1e-9)
        // Nothing to move: no offset, no pin, an empty ring.
        var empty = FixPinSource()
        empty.transform(map: map, jee: co, jen: -si, jne: si, jnn: co)
        #expect(empty.ring.isEmpty && empty.offset == nil && empty.lastPin == nil)
    }

    // MARK: Refinement (R37.1-2)

    /// Genuine phone fixes on the roads (test 2), pins 150 m along-track
    /// off on the east leg at `times`, both keys on: each first pin is
    /// significant and judged by both arbiters (verdict fixes, no
    /// down-weighting), so a judged pin leaves a road entry, and the
    /// two-pin arbiter has a previous pin from the second judged one on.
    static func refinementRun(_ times: [Double]) throws -> Run {
        let drive = Self.lDrive(eastS: 40)
        let net = try Self.roads(drive)
        let inputs = Self.inputs(drive, offsetUntil: -1, accuracy: 5, accessory: false,
                                 pins: times.map { ($0, 150, 0) })
        return Self.run(inputs, config: Self.config(roads: 1, twoPin: 1), roads: net)
    }

    @Test("Refinement: a pin 1.5 s after the previous one is not judged; its lastPin and counters are the previous pin's")
    func refinementWithinWindow() throws {
        let run = try Self.refinementRun([58.03, 59.53])
        #expect(run.decisions.count == 2 && run.pinStates.count == 2)
        let first = try #require(run.decisions[0]), second = try #require(run.decisions[1])
        #expect(!first.refinement && first.significant, "\(first.text)")
        #expect(first.sources.first?.road?.verdict == .fixes, "\(first.text)")
        #expect(second.refinement, "\(second.text)")
        #expect(second.text.contains("(refinement, not judged)"))
        let s = try #require(second.sources.first)
        #expect(second.sources.count == 1 && s.source == "phone" && s.fixesInWindow > 0)
        #expect(s.road == nil && s.twoPin == nil && s.sourceChi2 == nil && !s.downweighted && !s.restored, "\(second.text)")
        // lastPin is still the first pin, and no verdict counter moved.
        #expect(run.pinStates[0].lastPinNs[FixPinSource.Kind.phone.rawValue] == S.ms(58.03).nanoseconds)
        #expect(run.pinStates[1].lastPinNs[FixPinSource.Kind.phone.rawValue] == S.ms(58.03).nanoseconds)
        for key in Self.fixPinVerdictCounters + [\.fixPinRoadVerdictFixesPhone, \.fixPinTwoPinVerdictNonePhone,
                                                 \.fixPinTwoPinVerdictPinPhone, \.fixPinDownweightsPhone] {
            #expect(run.pinStates[1].counters[keyPath: key] == run.pinStates[0].counters[keyPath: key], "\(key)")
        }
        #expect(!run.engine.fixPin[1].isDownweighted)
    }

    @Test("Refinement: a pin 3.5 s after the previous one is judged and becomes the last pin")
    func refinementOutsideWindow() throws {
        let run = try Self.refinementRun([58.03, 61.53])
        let second = try #require(run.decisions[1])
        #expect(!second.refinement, "\(second.text)")
        #expect(second.significant, "\(second.text)")
        let s = try #require(second.sources.first)
        #expect(s.road != nil && s.twoPin != nil, "\(second.text)")
        #expect(abs((s.twoPin?.previousT ?? 0) - 58.03) < 1e-6)
        #expect(run.pinStates[1].lastPinNs[FixPinSource.Kind.phone.rawValue] == S.ms(61.53).nanoseconds)
        #expect(run.pinStates[1].counters.fixPinSignificantPins == run.pinStates[0].counters.fixPinSignificantPins + 1)
    }

    @Test("Refinement chain 0, 2, 4 s: rolling (each against the pin before), as the replay's pin scoring folds it")
    func refinementChain() throws {
        let times = [58.03, 60.03, 62.03]
        let run = try Self.refinementRun(times)
        let flags = run.decisions.map { $0?.refinement }
        // The third pin is 4 s after the first but 2 s after the second.
        #expect(flags == [false, true, true], "\(flags)")
        for state in run.pinStates {
            #expect(state.lastPinNs[FixPinSource.Kind.phone.rawValue] == S.ms(58.03).nanoseconds)
            #expect(state.counters.fixPinSignificantPins == run.pinStates[0].counters.fixPinSignificantPins)
        }
        for d in run.decisions.dropFirst() {
            #expect(d?.sources.allSatisfy { $0.road == nil && $0.twoPin == nil } == true)
        }
        // The replay's scoring rule on the same times: the same pins are
        // refinements, both of the chain's first pin.
        let scoring = NavigationReplay.pinScoring(manualFixTimes: times.map(S.ms), pairWindowS: NavigationReplay.defaultPinPairWindowS)
        #expect(scoring.notScored.map { $0?.reason == .refinement } == [false, true, true])
        #expect(scoring.notScored.dropFirst().allSatisfy { abs(($0?.firstPinT ?? 0) - 58.03) < 1e-6 })
        #expect(NavigationEngine.fixPinRefinementWindowS == NavigationReplay.defaultPinPairWindowS)
    }

    // MARK: Replay output

    @Test("Replay: the per-pin decision and the Fix-pin line appear only with a key on; no position in them")
    func replayOutput() throws {
        let drive = Self.lDrive(eastS: 30)
        let events = Self.inputs(drive, pins: [(30.03, 0, 0)])
        func result(_ config: NavigationConfig) -> ReplayResult {
            NavigationReplay.run(logName: "synthetic.jsonl.gz", inputs: events, options: ReplayOptions(gps: .use, config: config),
                                 truth: nil)
        }
        let off = result(Self.config()), on = result(Self.config(twoPin: 1))
        #expect(off.pins.allSatisfy { $0.fixPin == nil })
        #expect(on.pins.count == 1 && on.pins[0].fixPin != nil)
        let offSummary = ReplayReport.summary(off), onSummary = ReplayReport.summary(on)
        #expect(!offSummary.contains("fix-pin") && !offSummary.contains("Fix-pin"))
        #expect(onSummary.contains("Fix-pin       checks roads 0, two-pin 1") && onSummary.contains("fix-pin: offset"))
        let offMetrics = ReplayMetrics(off), onMetrics = ReplayMetrics(on)
        #expect(offMetrics.fixPinDecisions == nil && onMetrics.fixPinDecisions?.count == 1)
        let offJSON = String(decoding: try ReplayReport.metricsJSON([offMetrics]), as: UTF8.self)
        #expect(!offJSON.contains("fixPinDecisions"))
        let back = try JSONDecoder().decode([ReplayMetrics].self, from: ReplayReport.metricsJSON([onMetrics]))
        #expect(back == [onMetrics])
        #expect(!ReplayReport.markdown([offMetrics]).contains("N3-FIXPIN"))
        #expect(ReplayReport.markdown([onMetrics]).contains("Pin against GNSS sources (N3-FIXPIN)"))
        // The decision text is relative: no latitude or longitude digits.
        let text = try #require(on.pins[0].fixPin?.text)
        #expect(!text.contains("0.00"), "\(text)")
    }
}
