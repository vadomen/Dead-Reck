import Foundation
import Testing

@testable import DriveLoggerCore

/// The N3-FIXPIN injection study's driver (`FixPinInjection`,
/// `replay_nav --fixpin-inject`): a case continued from an engine snapshot
/// is the same as a straight run of the edited inputs, the edit touches
/// only what it says, and pin times keep clear of recorded pins and of
/// excluded fix ranges. Synthetic drives near (0, 0) only.
@Suite("Navigation fix-pin injection (N3-FIXPIN)")
struct NavigationFixPinInjectionTests {
    typealias F = NavigationFixPinTests
    typealias S = SyntheticDrive

    static let drive = F.lDrive(northS: 150, eastS: 150)

    /// The edited inputs of a case, run from the start without snapshots:
    /// the decisions after each injected pin and the estimate at `tEnd`.
    static func straightRun(_ inputs: [NavigationInput], config: NavigationConfig, roads: RoadNetwork, pin: FixPinInjection.PinTime,
                            case c: FixPinInjection.Case, options: FixPinInjection.Options)
        -> (decisions: [FixPinDecision?], estimate: NavigationEstimate?) {
        let truth = FixPinInjection.gnssFixes(inputs).filter { $0.source == .accessory }
        let pinTs = FixPinInjection.pinTs(pin, c)
        let t0 = pin.t - options.preS, tEnd = pinTs.last! + options.windowS - options.preS
        var pins = FixPinInjection.pinInputs(pinTs, case: c, truthFixes: truth, obdKmh: FixPinInjection.obdSpeeds(inputs),
                                             yaw: FixPinInjection.cumulativeYaw(inputs), options: options)
        var engine = NavigationEngine(config: config, roads: roads)
        var decisions: [FixPinDecision?] = []
        let endNs = MonotonicTimestamp(seconds: tEnd).nanoseconds
        for input in inputs where input.arrival.nanoseconds <= endNs {
            while let p = pins.first, p.ns < input.arrival.nanoseconds {
                engine.ingest(p.input)
                decisions.append(engine.lastFixPinDecision)
                pins.removeFirst()
            }
            engine.ingest(FixPinInjection.edited(input, case: c, t0: t0, tEnd: tEnd))
        }
        for p in pins {
            engine.ingest(p.input)
            decisions.append(engine.lastFixPinDecision)
        }
        return (decisions, engine.estimate(at: MonotonicTimestamp(seconds: tEnd)))
    }

    /// `inputs` with the fixes stamped at `ts` arriving at their own `t`
    /// (no latency), kept in arrival order (stable).
    static func zeroLatency(_ inputs: [NavigationInput], at ts: Set<Double>) -> [NavigationInput] {
        inputs.map { input -> NavigationInput in
            guard case .location(var sample, let t) = input, ts.contains(t.seconds) else { return input }
            sample.receivedT = nil
            return .location(sample, at: t)
        }.enumerated().sorted {
            $0.element.arrival != $1.element.arrival ? $0.element.arrival < $1.element.arrival : $0.offset < $1.offset
        }.map(\.element)
    }

    @Test func caseFromSnapshotEqualsStraightRun() throws {
        let options = FixPinInjection.Options()
        // R37.1-11: a fix arriving exactly at each pin time's t0 (pin − preS)
        // is in the case's window (edited), never in the shared prefix.
        let t0s: Set<Double> = [120 - options.preS, 240 - options.preS]
        let inputs = Self.zeroLatency(F.inputs(Self.drive, offsetUntil: -.infinity), at: t0s)
        for t0 in t0s {
            #expect(inputs.contains {
                guard case .location(let s, let t) = $0 else { return false }
                return t.seconds == t0 && $0.arrival == t && s.hasValidSpeed
            }, "a fix arriving exactly at t0 \(t0)")
        }
        let roads = try F.roads(Self.drive)
        let config = F.config(roads: 1, twoPin: 1)
        func pin(_ t: Double, _ second: Double?) -> FixPinInjection.PinTime {
            .init(t: t, secondT: second, context: .straight, junction: false, parallel: false, source: "accessory",
                  ringFixes: 0, ringPathM: 0, speedMps: 10)
        }
        // Two pin times, so the second case set continues the prefix run.
        let pins = [pin(120, 200), pin(240, nil)]
        let cases = [
            FixPinInjection.Case(kind: .sensitivity, magnitudeM: 150, bearingDeg: 90, twoPins: false),
            FixPinInjection.Case(kind: .specificity, magnitudeM: 150, bearingDeg: 45, twoPins: false),
            FixPinInjection.Case(kind: .sensitivity, magnitudeM: 150, bearingDeg: 90, twoPins: true),
            FixPinInjection.Case(kind: .specificity, magnitudeM: 150, bearingDeg: 0, twoPins: true, secondPin: .sameInCarFrame),
            FixPinInjection.Case(kind: .specificity, magnitudeM: 150, bearingDeg: 0, twoPins: true, secondPin: .genuine),
        ]
        let outcomes = FixPinInjection.run(inputs: inputs, config: config, roads: roads, pinTimes: pins, cases: cases,
                                           options: options)
        // 5 cases at the first pin time, 2 at the second: its 3 two-pin
        // cases are skipped (no second pin).
        #expect(outcomes.count == 7)
        #expect(outcomes.filter { $0.pin.t == 240 }.allSatisfy { !$0.case.twoPins })
        for outcome in outcomes {
            let reference = Self.straightRun(inputs, config: config, roads: roads, pin: outcome.pin, case: outcome.case,
                                             options: options)
            #expect(outcome.decision == reference.decisions.first ?? nil)
            #expect(outcome.secondDecision == (reference.decisions.count > 1 ? reference.decisions[1] : nil))
            #expect(outcome.decisions == reference.decisions)
            #expect(reference.decisions.count == FixPinInjection.pinTs(outcome.pin, outcome.case).count)
            let truth = FixPinInjection.gnssFixes(inputs).filter { $0.source == .accessory }
            let tEnd = FixPinInjection.pinTs(outcome.pin, outcome.case).last! + options.windowS - options.preS
            let p = try #require(FixPinInjection.position(at: tEnd, in: truth, options: options))
            let e = try #require(reference.estimate)
            let d = LocalTangentPlane(latitude: p.latitude, longitude: p.longitude).enu(latitude: e.latitude, longitude: e.longitude)
            #expect(outcome.endErrorM == (d.east * d.east + d.north * d.north).squareRoot())
        }
        // The study measures something: the shifted case is judged by the roads
        // (150 m east of a north-south street is 50 m from every street).
        let shifted = try #require(outcomes.first { $0.case.kind == .sensitivity && !$0.case.twoPins })
        let decision = try #require(shifted.decision)
        #expect(decision.significant)
        #expect(decision.sources.first?.road?.verdict == .pin)
        // Car frame: across the 90° right turn pin 2's displacement turns from
        // north to east with the car.
        let turned = try #require(outcomes.first { $0.case.secondPin == .sameInCarFrame })
        let turnedPins = FixPinInjection.pinInputs([120, 200], case: turned.case,
                                             truthFixes: FixPinInjection.gnssFixes(inputs).filter { $0.source == .accessory },
                                             obdKmh: FixPinInjection.obdSpeeds(inputs), yaw: FixPinInjection.cumulativeYaw(inputs),
                                             options: options)
        let truth2 = try #require(FixPinInjection.position(at: 200, in: FixPinInjection.gnssFixes(inputs), options: options))
        guard case .manualFix(let s2, _) = turnedPins[1].input else { Issue.record("no pin 2"); return }
        let d2 = LocalTangentPlane(latitude: truth2.latitude, longitude: truth2.longitude).enu(latitude: s2.latitude, longitude: s2.longitude)
        #expect(abs(d2.east - 150) < 10 && abs(d2.north) < 10)
        // Genuine pin 2: at the genuine position.
        let genuine = try #require(outcomes.first { $0.case.secondPin == .genuine && $0.case.kind == .specificity && $0.case.twoPins })
        let g = FixPinInjection.pinInputs([120, 200], case: genuine.case,
                                          truthFixes: FixPinInjection.gnssFixes(inputs).filter { $0.source == .accessory },
                                          obdKmh: FixPinInjection.obdSpeeds(inputs), options: options)
        guard case .manualFix(let g2, _) = g[1].input else { Issue.record("no pin 2"); return }
        #expect(g2.latitude == truth2.latitude && g2.longitude == truth2.longitude)
    }

    @Test func editShiftsOnlyGNSSFixesInTheWindow() throws {
        let c = FixPinInjection.Case(kind: .sensitivity, magnitudeM: 100, bearingDeg: 0, twoPins: false)
        let gnss = F.inputs(Self.drive, offsetUntil: -.infinity)
        let network = F.inputs(Self.drive, offsetUntil: -.infinity, network: true)
        var shifted = 0
        for input in gnss + network {
            let out = FixPinInjection.edited(input, case: c, t0: 50, tEnd: 80)
            guard case .location(let a, let t) = input, case .location(let b, _) = out else {
                #expect(out == input)
                continue
            }
            if a.hasValidSpeed && t.seconds >= 50 && t.seconds <= 80 {
                let d = LocalTangentPlane(latitude: a.latitude, longitude: a.longitude).enu(latitude: b.latitude, longitude: b.longitude)
                #expect(abs(d.north - 100) < 1e-6 && abs(d.east) < 1e-6)
                shifted += 1
            } else {
                #expect(out == input)
            }
        }
        #expect(shifted >= 25)
        // Specificity never edits a fix.
        let spec = FixPinInjection.Case(kind: .specificity, magnitudeM: 100, bearingDeg: 0, twoPins: false)
        #expect(gnss.allSatisfy { FixPinInjection.edited($0, case: spec, t0: 0, tEnd: 1000) == $0 })
    }

    @Test func pinTimesKeepClearOfRecordedPinsAndExcludedFixes() throws {
        let inputs = F.inputs(Self.drive, offsetUntil: -.infinity, pins: [(t: 100, dEast: 0, dNorth: 0)])
        let roads = try F.roads(Self.drive)
        var options = FixPinInjection.Options()
        options.minSeparationS = 10
        let excluded = [TruthFile.ExcludedFixRange(fromT: 280, toT: 290)]
        let times = FixPinInjection.pinTimes(inputs, roads: roads, options: options, excluded: excluded)
        #expect(!times.isEmpty)
        #expect(times == FixPinInjection.pinTimes(inputs, roads: roads, options: options, excluded: excluded))
        for p in times {
            let t0 = p.t - options.preS, tEnd = t0 + options.windowS
            #expect(!(100 >= t0 - options.pinClearanceS && 100 <= tEnd + options.pinClearanceS))
            #expect(!(280 <= tEnd && 290 >= t0))
            #expect(p.ringFixes >= options.minRingFixes && p.ringPathM >= options.minRingPathM)
        }
        #expect(zip(times, times.dropFirst()).allSatisfy { $1.t - $0.t >= options.minSeparationS })
    }

    // MARK: Pin selection and road context (R37.1-3)

    /// The L-drive (north 150 s, a 3 s right turn, east) on a sparse map in
    /// the test plane: a north–south street along the first leg, an
    /// east–west one along the last (crossing it at the corner), and a short
    /// street 45 m east of the first leg, alongside it from 640 m to 960 m
    /// north (the leg passes there at about 94–126 s). The north–south
    /// street has a node every 100 m (at 30 m past each hundred), as real
    /// streets do: the 5 s candidate grid (50 m) is never within 20 m of
    /// one, so its next and previous segments are always 20–80 m away and
    /// collinear, and only the interior rule keeps them from counting as a
    /// parallel road (R37.2-2).
    static func lMap(_ drive: S) throws -> RoadNetwork {
        let x0 = F.truth(drive, 1).east, y1 = F.truth(drive, drive.duration - 1).north
        let nodes = [-1000.0] + (0..<30).map { -970 + 100 * Double($0) } + [2000]
        return try NavigationRoadTests.network([
            RoadFixture.way(1, ["highway": "residential"],
                            nodes.enumerated().map { RoadFixture.Node(id: 1000 + Int64($0.offset), east: x0, north: $0.element) }),
            NavigationRoadTests.street(2, from: (-500, y1), to: (2500, y1)),
            NavigationRoadTests.street(3, from: (x0 + 45, 640), to: (x0 + 45, 960)),
        ])
    }

    /// Every candidate pin time (no recorded pin, nothing excluded): one
    /// per `candidateStepS`, since all of them are at least that far apart.
    static func allPinTimes(_ inputs: [NavigationInput], roads: RoadNetwork, _ edit: (inout FixPinInjection.Options) -> Void = { _ in })
        -> (times: [FixPinInjection.PinTime], options: FixPinInjection.Options) {
        var options = FixPinInjection.Options()
        options.pinsPerLog = 1000
        options.minSeparationS = options.candidateStepS
        edit(&options)
        return (FixPinInjection.pinTimes(inputs, roads: roads, options: options), options)
    }

    /// The second pin by the rule, written out: the first whole second
    /// from `twoPinMinGapS` to `twoPinMaxGapS` after `t` (and not after the
    /// last fix) with at least the OBD path and net gyro turn since `t`.
    static func expectedSecond(_ t: Double, inputs: [NavigationInput], options: FixPinInjection.Options) -> Double? {
        let obd = FixPinInjection.cumulativeOBD(inputs), yaw = FixPinInjection.cumulativeYaw(inputs)
        let last = FixPinInjection.gnssFixes(inputs).last!.t
        guard let o0 = FixPinInjection.value(obd, at: t), let y0 = FixPinInjection.value(yaw, at: t) else { return nil }
        var s = t + options.twoPinMinGapS
        while s <= min(t + options.twoPinMaxGapS, last) {
            if let o = FixPinInjection.value(obd, at: s), let y = FixPinInjection.value(yaw, at: s),
               o - o0 >= options.twoPinMinPathM, abs(y - y0) * 180 / .pi >= options.twoPinMinTurnDeg {
                return s
            }
            s += 1
        }
        return nil
    }

    @Test func contextOnAnLDrive() throws {
        let drive = F.lDrive(northS: 150, eastS: 150)
        let inputs = F.inputs(drive, offsetUntil: -.infinity)
        let (times, options) = Self.allPinTimes(inputs, roads: try Self.lMap(drive))
        func at(_ t: Double) throws -> FixPinInjection.PinTime { try #require(times.first { $0.t == t }, "no candidate at \(t) s") }
        // Every candidate of the grid is there.
        #expect(times.count > 30 && zip(times, times.dropFirst()).allSatisfy { $1.t - $0.t == options.candidateStepS })
        // Mid-leg, on the street with nothing else near: straight.
        for t in [140.0, 200, 250] {
            let p = try at(t)
            #expect(p.context == .straight && !p.junction && !p.parallel, "\(t) s: \(p.context)")
        }
        // The whole first leg (candidates start at 90 s, once the ring has
        // its fixes) away from the street alongside (95–125 s) and the
        // corner (150 s): straight on its own many-node street.
        let firstLeg = times.filter { $0.t < 150 && !(95...125).contains($0.t) }
        #expect(firstLeg.map(\.t) == [90, 130, 135, 140, 145])
        for p in firstLeg {
            #expect(p.context == .straight && !p.junction && !p.parallel, "\(p.t) s: \(p.context)")
        }
        // The turn starts at 150 s, 19 m before the east–west street (the
        // turn's radius), heading north: across it, so a junction.
        let corner = try at(150)
        #expect(corner.context == .junction && corner.junction && !corner.parallel, "\(corner.context)")
        // 155 s: 39 m along the last leg, past the junction radius.
        #expect(try at(155).context == .straight)
        // 100–120 s: the street 45 m east runs alongside.
        for t in [100.0, 110, 120] {
            let p = try at(t)
            #expect(p.context == .parallel && p.parallel && !p.junction, "\(t) s: \(p.context)")
        }
        #expect(try at(135).context == .straight, "past the parallel street's end")
        // 130 s, 1000 m north: 70 m past a node and 30 m before the next, the
        // street's own neighbouring segments are not a road alongside.
        let p130 = try at(130)
        #expect(p130.context == .straight && !p130.parallel, "\(p130.context)")

        // The classifier directly: the corner's crossing road is within the
        // radius at 30°, the leg's own street never makes a junction.
        let map = try Self.lMap(drive)
        func context(_ east: Double, _ north: Double, course: Double?) -> (junction: Bool, parallel: Bool) {
            let g = S.plane.geodetic(east: east, north: north)
            return FixPinInjection.context(latitude: g.latitude, longitude: g.longitude, course: course, speed: 10,
                                           roads: map, options: options)
        }
        let y1 = F.truth(drive, drive.duration - 1).north
        #expect(context(0, y1 - 20, course: 0) == (true, false))
        #expect(context(0, y1 - 30, course: 0) == (false, false), "outside the 25 m radius")
        #expect(context(0, 300, course: 0) == (false, false))
        #expect(context(0, 300, course: 180) == (false, false), "a street is two-way")
        #expect(context(0, 800, course: 0) == (false, true))
        #expect(context(0, 800, course: 30) == (false, false), "the street alongside at 30° is not parallel")
        #expect(context(0, 800, course: nil) == (false, true), "no course: the nearest road's direction")
        // 30 m into a 100 m segment (nodes at 130 m and 230 m north): the
        // street's next segment starts 70 m ahead and its previous one ended
        // 30 m behind, both collinear and in the parallel band, but the pin
        // is not beside either of them, so they are not a parallel road.
        #expect(context(0, 160, course: 0) == (false, false))
        #expect(context(0, 160, course: nil) == (false, false))
        #expect(context(0, 1000, course: 0) == (false, false))
        // On the east–west street 20 m from the north–south one, heading east.
        #expect(context(20, y1, course: 90) == (true, false))
    }

    /// R37.2-3: the parallel band starts `parallelMinM` beyond the nearest
    /// road, not only `parallelMinM` from the pin. A pin 10 m west of its
    /// street (x = 0): a street alongside at x = 10 is 20 m away, inside
    /// 15–80 m but not 15 m past the nearest (25 m), so not parallel; at
    /// x = 20 (30 m) it is.
    @Test func parallelRoadMustBeClearOfTheNearestOne() throws {
        func context(secondStreetEast x: Double) throws -> (junction: Bool, parallel: Bool) {
            let map = try NavigationRoadTests.network([
                NavigationRoadTests.street(1, from: (0, -1000), to: (0, 1000)),
                NavigationRoadTests.street(2, from: (x, -1000), to: (x, 1000)),
            ])
            let g = S.plane.geodetic(east: -10, north: 0)
            return FixPinInjection.context(latitude: g.latitude, longitude: g.longitude, course: 0, speed: 10,
                                           roads: map, options: FixPinInjection.Options())
        }
        #expect(FixPinInjection.Options().parallelMinM == 15)
        #expect(try context(secondStreetEast: 10) == (false, false), "20 m: within 15 m of the nearest road's 10 m")
        #expect(try context(secondStreetEast: 20) == (false, true), "30 m: 20 m past the nearest road")
    }

    /// R37.2-3: the second pin needs its own ring, at least `minRingFixes / 2`
    /// genuine fixes of the source in [s − preS, s]. The L-drive's 130 s
    /// candidate (second pin at s ≈ 163 s, its ring from s − 90) with the
    /// fixes over 73–127 s removed, and over 133 s to s − `kept`: the ring
    /// keeps the 5 fixes around the first pin and `kept` before s.
    @Test func secondPinNeedsItsOwnRing() throws {
        let drive = F.lDrive(northS: 150, eastS: 150)
        let inputs = F.inputs(drive, offsetUntil: -.infinity)
        let map = try Self.lMap(drive)
        let options = Self.allPinTimes(inputs, roads: map).options
        let s = try #require(Self.expectedSecond(130, inputs: inputs, options: options))
        #expect(options.minRingFixes / 2 == 12)
        func withGap(kept: Int) -> [NavigationInput] {
            inputs.filter { input in
                guard case .location(_, let t) = input else { return true }
                let x = t.seconds
                return !((x > 72.5 && x < 127.5) || (x > 132.5 && x < s - Double(kept) + 0.5))
            }
        }
        for (kept, accepted) in [(7, true), (6, false)] {
            let gapped = withGap(kept: kept)
            let ring = FixPinInjection.gnssFixes(gapped).filter { $0.t >= s - options.preS && $0.t <= s }
            #expect(ring.count == 5 + kept, "ring before s: \(ring.count)")
            let (times, _) = Self.allPinTimes(gapped, roads: map)
            let p = try #require(times.first { $0.t == 130 }, "130 s is still a candidate (its own ring is 40–72 s plus 128–130 s)")
            #expect(p.secondT == (accepted ? s : nil), "\(5 + kept) fixes: \(String(describing: p.secondT))")
        }
    }

    @Test func secondAndThirdPinSelection() throws {
        let drive = F.lDrive(northS: 150, eastS: 150)
        let inputs = F.inputs(drive, offsetUntil: -.infinity)
        let map = try Self.lMap(drive)
        let (times, options) = Self.allPinTimes(inputs, roads: map)
        let last = try #require(FixPinInjection.gnssFixes(inputs).last?.t)
        func at(_ t: Double) throws -> FixPinInjection.PinTime { try #require(times.first { $0.t == t }, "no candidate at \(t) s") }

        // Every candidate: the second pin is the rule's, and a third one is
        // 60 s later whenever its window ends by the last fix.
        for p in times {
            #expect(p.secondT == Self.expectedSecond(p.t, inputs: inputs, options: options), "\(p.t) s")
            if let s2 = p.secondT {
                let fits = s2 + options.thirdPinAfterS + options.windowS - options.preS <= last
                #expect(p.thirdT == (fits ? s2 + options.thirdPinAfterS : nil), "\(p.t) s")
            } else {
                #expect(p.thirdT == nil)
            }
        }
        // 100 s: 330 m of path by 133 s, 55° of the 30°/s turn (from 150 s)
        // only at 151.8 s: the turn decides.
        let early = try at(100)
        #expect(early.secondT == 152, "\(String(describing: early.secondT))")
        #expect(early.thirdT == 212)
        // 130 s: the turn is done by 153 s, 330 m of path only at 163 s: the path decides.
        let late = try at(130)
        let s2 = try #require(late.secondT)
        #expect(s2 >= 163 && s2 <= 164, "\(s2)")
        // Mid-leg after the turn: no second turn ahead, no second pin.
        for t in [160.0, 200] {
            #expect(try at(t).secondT == nil && at(t).thirdT == nil, "\(t) s")
        }
        // The turn more than twoPinMaxGapS ahead: none either.
        let (near, _) = Self.allPinTimes(inputs, roads: map) { $0.twoPinMaxGapS = 30 }
        #expect(try #require(near.first { $0.t == 100 }).secondT == nil)
        #expect(try #require(near.first { $0.t == 130 }).secondT == nil, "163 s is 33 s after")
        #expect(try #require(near.first { $0.t == 125 }).secondT == nil, "the turn's 55° is 27 s after, the 330 m 33 s")

        // A drive ending 80 s after the turn: the third pin's window (212 s
        // + 30 s) runs past the last fix (233 s); the second pin stays.
        let short = F.lDrive(northS: 150, eastS: 80)
        let shortInputs = F.inputs(short, offsetUntil: -.infinity)
        let shortLast = try #require(FixPinInjection.gnssFixes(shortInputs).last?.t)
        #expect(shortLast < 242 && shortLast >= 212)
        let (shortTimes, _) = Self.allPinTimes(shortInputs, roads: try Self.lMap(short))
        let p = try #require(shortTimes.first { $0.t == 100 })
        #expect(p.secondT == 152 && p.thirdT == nil, "\(String(describing: p.secondT)) / \(String(describing: p.thirdT))")
    }
}
