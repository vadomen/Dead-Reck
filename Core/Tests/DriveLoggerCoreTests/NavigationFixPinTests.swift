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
        let x0 = truth(drive, 1).east
        let y1 = truth(drive, drive.duration - 1).north
        var lines: [String] = []
        var id: Int64 = 1
        for k in -15...15 {
            let x = x0 + Double(k) * 100, y = y1 + Double(k) * 100
            lines.append(R.street(id, from: (x, -1800), to: (x, 1800))); id += 1
            lines.append(R.street(id, from: (-1800, y), to: (1800, y))); id += 1
        }
        return try R.network(lines)
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
            case .manualFix: run.decisions.append(run.engine.lastFixPinDecision)
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
