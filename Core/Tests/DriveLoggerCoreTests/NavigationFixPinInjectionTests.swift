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

    @Test func caseFromSnapshotEqualsStraightRun() throws {
        let inputs = F.inputs(Self.drive, offsetUntil: -.infinity)
        let roads = try F.roads(Self.drive)
        let config = F.config(roads: 1, twoPin: 1)
        let options = FixPinInjection.Options()
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
}
