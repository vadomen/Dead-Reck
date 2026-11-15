import Foundation
import Testing

@testable import DriveLoggerCore

/// Prompt 50, observe-only: the M² of every fix the engine considers
/// (`FixJumpObservation`). Synthetic drives in a local plane at (0, 0) and
/// synthetic clocks only: no real place, date or recording.
@Suite("Navigation prompt 50: fix-jump observation")
struct NavigationFixJumpObserveTests {
    typealias S = SyntheticDrive

    static let drive = S(initialHeadingDeg: 30, [
        .stop(seconds: 3), .ramp(seconds: 5, from: 0, to: 12), .straight(seconds: 40, speed: 12),
        .turn(degrees: 90, seconds: 10, speed: 10), .straight(seconds: 20, speed: 12),
    ])

    /// The one far fix: at `jumpT` (no latency), `offEast` m east of the
    /// truth, a network fix (no Doppler speed) of accuracy `accuracy`.
    static let jumpT = 40.0
    static let offEast = 400.0

    /// Clean GNSS fixes each second, except the far network fix at `jumpT`.
    static func events(jumpAccuracy accuracy: Double, extra: [LogEvent] = []) -> [LogEvent] {
        let clean = S.cleanFix(accuracy: 5, positionNoise: 1)
        return drive.events(gyroNoise: 0.001, fix: { t, state, rng in
            if S.at(t, jumpT) {
                return S.Fix(east: state.east + offEast, north: state.north, accuracy: accuracy, latency: 0)
            }
            return clean(t, state, &rng)
        }, extra: extra)
    }

    static func observation(threshold: Double = NavigationReplay.fixJumpObserveChi2,
                            cap: Int = NavigationReplay.fixJumpObserveListCap) -> FixJumpObservation {
        FixJumpObservation(chi2Threshold: threshold, listCap: cap)
    }

    /// Runs `events`; `observe` nil leaves the observation off.
    static func run(_ events: [LogEvent], observe: FixJumpObservation?, prior: NavigationPrior? = nil,
                    until end: Double? = nil) -> (engine: NavigationEngine, estimates: [NavigationEstimate?]) {
        var engine = NavigationEngine(config: S.config(particles: 300, seed: 3), prior: prior)
        engine.fixJumps = observe
        var estimates: [NavigationEstimate?] = []
        var next = 0.5
        for input in S.inputs(events) {
            if let end, input.arrival > S.ms(end) { break }
            while S.ms(next) < input.arrival {
                estimates.append(engine.estimate(at: S.ms(next)))
                next += 0.5
            }
            engine.ingest(input)
        }
        return (engine, estimates)
    }

    /// The engine just before the input arriving at `t` with a location.
    static func engineBeforeFix(_ events: [LogEvent], at t: Double) throws -> NavigationEngine {
        var engine = NavigationEngine(config: S.config(particles: 300, seed: 3))
        for input in S.inputs(events) {
            if case .location = input, input.arrival == S.ms(t) { return engine }
            engine.ingest(input)
        }
        throw CancellationError()
    }

    /// Weighted mean and mixture covariance of a cloud (the test's own sums).
    static func moments(_ e: NavigationEngine) -> (east: Double, north: Double, ee: Double, en: Double, nn: Double) {
        var me = 0.0, mn = 0.0
        for i in e.east.indices {
            me += e.weight[i] * e.east[i]
            mn += e.weight[i] * e.north[i]
        }
        var ee = 0.0, en = 0.0, nn = 0.0
        for i in e.east.indices {
            let de = e.east[i] - me, dn = e.north[i] - mn
            ee += e.weight[i] * (e.covEE[i] + de * de)
            en += e.weight[i] * (e.covEN[i] + de * dn)
            nn += e.weight[i] * (e.covNN[i] + dn * dn)
        }
        return (me, mn, ee, en, nn)
    }

    // MARK: Hits

    @Test func farFixWithSmallSigmaIsAHitWithItsM2TimeAndPath() throws {
        let events = Self.events(jumpAccuracy: 15)
        let engine = Self.run(events, observe: Self.observation()).engine
        let jumps = try #require(engine.fixJumps)
        // The far fix, then (it pulled the cloud) the next clean fix: the
        // jump is listed first and is the largest.
        #expect(jumps.hits >= 1 && jumps.list.allSatisfy { $0.t >= Self.jumpT })
        let hit = try #require(jumps.list.first)
        #expect(jumps.list.count == jumps.hits && jumps.max == hit)
        #expect(hit.t == Self.jumpT && hit.fixT == Self.jumpT)
        #expect(hit.network && hit.accuracyM == 15 && hit.temper == 1, "the first network fix: untempered")
        #expect(hit.path == .update && hit.restore == nil && !hit.zeroGateEvidence)
        // M² from the cloud just before the fix: no step between it and the
        // fix (no latency, the fix on the 10 Hz grid), so no shift.
        let before = try Self.engineBeforeFix(events, at: Self.jumpT)
        let m = Self.moments(before)
        let config = NavigationConfig()
        let sigma = max(15 * config.fixSigmaPerAccuracy, config.fixSigmaFloorM) * config.networkFixInflation
        #expect(hit.sigmaM == sigma)
        let truth = Self.drive.truth(at: Self.jumpT)
        let fix = S.plane.geodetic(east: truth.east + Self.offEast, north: truth.north)
        let p = try #require(before.tangentPlane).enu(latitude: fix.latitude, longitude: fix.longitude)
        let de = p.east - m.east, dn = p.north - m.north
        let s2 = sigma * sigma
        let expected = NavigationEngine.chi2(de, dn, ee: m.ee + s2, en: m.en, nn: m.nn + s2)
        #expect(expected > 1000, "400 m against a few metres")
        #expect(abs(hit.mahalanobis2 - expected) <= 1e-9 * expected, "\(hit.mahalanobis2) vs \(expected)")
        #expect(hit.mahalanobis2Untempered == hit.mahalanobis2)
        #expect(abs(hit.innovationM - (de * de + dn * dn).squareRoot()) < 1e-6)
        // Every fix after the first one is measured (the first initialises).
        #expect(jumps.fixesMeasured == engine.counters.fixesUsed + engine.counters.fixesRejectedOffRoad - 1)
        let summary = ReplayReport.fixJumpLines(jumps)
        #expect(summary.first?.hasPrefix("Fix jumps     M² > 25: \(jumps.hits) of \(jumps.fixesMeasured) measured fixes; max M² ") == true)
        #expect(summary.count == 1 + jumps.hits && summary[1].contains("network, acc 15 m") && summary[1].hasSuffix(", update"))
    }

    @Test func farFixWithLargeSigmaIsNotAHit() throws {
        // Accuracy 1414 m (σ ≈ 936 m): 400 m off is M² ≈ 0.2.
        let engine = Self.run(Self.events(jumpAccuracy: 1414), observe: Self.observation()).engine
        let jumps = try #require(engine.fixJumps)
        #expect(jumps.hits == 0 && jumps.list.isEmpty)
        #expect(jumps.fixesMeasured > 60)
        let max = try #require(jumps.max)
        #expect(max.mahalanobis2 <= 25)
    }

    @Test func thresholdIsStrictlyGreater() throws {
        let measured = try #require(Self.run(Self.events(jumpAccuracy: 15), observe: Self.observation()).engine.fixJumps)
        let m2 = try #require(measured.max?.mahalanobis2)
        let at = try #require(Self.run(Self.events(jumpAccuracy: 15),
                                       observe: Self.observation(threshold: m2)).engine.fixJumps)
        #expect(at.hits == 0 && at.max?.mahalanobis2 == m2)
        let below = try #require(Self.run(Self.events(jumpAccuracy: 15),
                                          observe: Self.observation(threshold: m2.nextDown)).engine.fixJumps)
        #expect(below.hits == 1)
    }

    @Test func networkTemperRaisesR() throws {
        // Two far network fixes 10 s apart: the second is tempered by
        // 10 / `networkFixCorrelationS`, so R = σ² / temper.
        let second = 50.0
        let clean = S.cleanFix(accuracy: 5, positionNoise: 1)
        let events = Self.drive.events(gyroNoise: 0.001, fix: { t, state, rng in
            if S.at(t, Self.jumpT) || S.at(t, second) {
                return S.Fix(east: state.east + Self.offEast, north: state.north, accuracy: 15, latency: 0)
            }
            return clean(t, state, &rng)
        })
        let jumps = try #require(Self.run(events, observe: Self.observation()).engine.fixJumps)
        let hit = try #require(jumps.list.first { $0.t == second })
        #expect(abs(hit.temper - 10 / NavigationConfig().networkFixCorrelationS) < 1e-12)
        #expect(hit.mahalanobis2 < hit.mahalanobis2Untempered)
    }

    @Test func farNetworkFixAgainstAnUnconfirmedPriorRegistersAsRestoreRejected() throws {
        // The step A shape (prompt 50): a restored prior, still unconfirmed, and a
        // first network fix with a small claimed σ ~470 m from it. The
        // judge rejects the prior and the fix initialises the engine.
        let drive = S(initialHeadingDeg: 30, [.stop(seconds: 5), .ramp(seconds: 5, from: 0, to: 12),
                                              .straight(seconds: 20, speed: 12)])
        let parked = (east: 500.0, north: 800.0)
        let p = S.plane.geodetic(east: parked.east, north: parked.north)
        let prior = NavigationPrior(latitude: p.latitude, longitude: p.longitude, covEE: 25, covEN: 0, covNN: 25,
                                    headingDeg: 30, headingStdDeg: 3, savedT: S.ms(-600), lastSpeedMps: 0,
                                    restoreClass: .parked)
        let events = drive.events(gyroNoise: 0.001, fix: { t, state, _ in
            guard t >= 12 else { return nil }
            return S.Fix(east: state.east + parked.east + 280, north: state.north + parked.north - 380,
                         accuracy: 15, latency: 0.3)
        })
        let engine = Self.run(events, observe: Self.observation(), prior: prior).engine
        #expect(engine.restore.status == .rejected && engine.restore.reason == .fix)
        let jumps = try #require(engine.fixJumps)
        let first = try #require(jumps.list.first)
        #expect(first.path == .restoreRejected && first.restore == .rejected && first.network)
        #expect(abs(first.t - 12.3) < 1e-9 && abs(first.fixT - 12) < 1e-9)
        #expect(first.mahalanobis2 > 25 && first.mahalanobis2 == first.mahalanobis2Untempered)
        #expect(first.innovationM > 400)
        #expect(jumps.max == first, "the largest M²")
        // After the re-initialisation the fixes agree.
        #expect(jumps.hits == 1)
    }

    @Test func restoreRejectedLabelsOnlyTheJudgedFix() throws {
        // R89.2-1: the drive above with threshold below 0, so every measured
        // fix is listed. `restore.status` stays `.rejected` for the rest of
        // the run; only the fix the judge ran on is `restoreRejected`.
        let drive = S(initialHeadingDeg: 30, [.stop(seconds: 5), .ramp(seconds: 5, from: 0, to: 12),
                                              .straight(seconds: 20, speed: 12)])
        let parked = (east: 500.0, north: 800.0)
        let p = S.plane.geodetic(east: parked.east, north: parked.north)
        let prior = NavigationPrior(latitude: p.latitude, longitude: p.longitude, covEE: 25, covEN: 0, covNN: 25,
                                    headingDeg: 30, headingStdDeg: 3, savedT: S.ms(-600), lastSpeedMps: 0,
                                    restoreClass: .parked)
        let events = drive.events(gyroNoise: 0.001, fix: { t, state, _ in
            guard t >= 12 else { return nil }
            return S.Fix(east: state.east + parked.east + 280, north: state.north + parked.north - 380,
                         accuracy: 15, latency: 0.3)
        })
        let engine = Self.run(events, observe: Self.observation(threshold: -1), prior: prior).engine
        #expect(engine.restore.status == .rejected && engine.restore.reason == .fix)
        let jumps = try #require(engine.fixJumps)
        #expect(jumps.list.count == jumps.fixesMeasured && jumps.fixesMeasured > 5, "every measured fix listed")
        let first = try #require(jumps.list.first)
        #expect(abs(first.fixT - 12) < 1e-9)
        #expect(first.path == .restoreRejected && first.restore == .rejected)
        let later = jumps.list.dropFirst()
        #expect(later.allSatisfy { $0.path != .restoreRejected }, "the status stays rejected; the label does not")
        #expect(later.allSatisfy { $0.restore == nil }, "the judge ran once")
        #expect(jumps.list.filter { $0.path == .restoreRejected }.count == 1)
        // The max is the judged fix, labelled as such.
        let max = try #require(jumps.max)
        #expect(max == first && max.path == .restoreRejected && max.restore == .rejected)
    }

    @Test func agreeingFixAgainstAnUnconfirmedPriorRecordsTheJudgeOutcome() throws {
        // Threshold below 0: every measured fix is listed with its path.
        let drive = S(initialHeadingDeg: 30, [.stop(seconds: 6)])
        let parked = (east: 500.0, north: 800.0)
        let p = S.plane.geodetic(east: parked.east, north: parked.north)
        let prior = NavigationPrior(latitude: p.latitude, longitude: p.longitude, covEE: 25, covEN: 0, covNN: 25,
                                    headingDeg: 30, headingStdDeg: 3, savedT: S.ms(-600), lastSpeedMps: 0,
                                    restoreClass: .parked)
        let events = drive.events(fix: { t, state, _ in
            guard t >= 2 else { return nil }
            return S.Fix(east: state.east + parked.east, north: state.north + parked.north, accuracy: 5,
                         speed: 0, speedAccuracy: 1)
        })
        let engine = Self.run(events, observe: Self.observation(threshold: -1), prior: prior).engine
        #expect(engine.restore.status == .confirmed)
        let jumps = try #require(engine.fixJumps)
        #expect(jumps.list.first?.restore == .confirmed && jumps.list.first?.path == .update)
        #expect(jumps.list.dropFirst().allSatisfy { $0.restore == nil }, "the judge ran once")
    }

    @Test func reseedPathIsNamed() throws {
        // Threshold below 0: the second clean fix of a fresh engine (heading
        // still unknown) reseeds.
        let engine = Self.run(Self.events(jumpAccuracy: 15), observe: Self.observation(threshold: -1)).engine
        let jumps = try #require(engine.fixJumps)
        #expect(engine.counters.reseeds > 0)
        let reseeds = jumps.list.filter { $0.path == .reseed }.count
        #expect(reseeds == engine.counters.reseeds)
        #expect(jumps.list.contains { $0.path == .update })
    }

    // MARK: Every path, FIXPIN R, latency (R89.1-1, R89.1-2)

    @Test func roadGateRejectionIsNamedRejectedOffRoad() throws {
        typealias R = NavigationRoadTests
        // `NavigationRoadTests.fixGate`'s shape: the car on road x = 0, a
        // parallel road x = 300, a clean fix at 40 s 200 m east of the car
        // (100 m from either road) while on-road at 54 km/h.
        let net = try R.network([R.street(1, from: (0, -3000), to: (0, 3000)),
                                 R.street(2, from: (300, -3000), to: (300, 3000))])
        let clean = S.cleanFix()
        let inputs = R.shifted(R.northDrive(seconds: 60, speed: 15), by: (0, -500), fix: { t, s, r in
            if t < 10 { return clean(t, s, &r) }
            guard S.at(t, 40), var f = clean(t, s, &r) else { return nil }
            f.east += 200
            return f
        })
        var engine = NavigationEngine(config: R.config(particles: 400), roads: net)
        engine.fixJumps = Self.observation()
        for input in inputs { engine.ingest(input) }
        #expect(engine.counters.fixesRejectedOffRoad == 1)
        let jumps = try #require(engine.fixJumps)
        let hit = try #require(jumps.list.first { abs($0.fixT - 40) < 1e-6 })
        #expect(hit.path == .rejectedOffRoad && !hit.network && hit.temper == 1 && hit.restore == nil)
        #expect(hit.innovationM > 150 && hit.mahalanobis2 > 25 && jumps.max == hit)
        #expect(jumps.list.filter { $0.path == .rejectedOffRoad } == [hit])
    }

    @Test func downweightedSourceNamesReseedBlockedAndUpdateDownweightedWithItsR() throws {
        typealias P = NavigationFixPinTests
        // `NavigationFixPinTests.twoPinsWithTurn`: accessory fixes 288 m
        // off; the two-pin verdict at the second pin (80 s) down-weights the
        // source. The fix at 90 s claims a course 90° off the car's: no
        // particle supports it, so that clean fix would reseed, and
        // down-weighted the reseed is blocked.
        let drive = P.lDrive(eastS: 60)
        let pinT = 80.03, blockedT = 90.0
        let inputs = P.inputs(drive, pins: [(30.03, 0, 0), (pinT, 0, 0)]).map { input -> NavigationInput in
            guard case .location(var sample, let t) = input, abs(t.seconds - blockedT) < 1e-6 else { return input }
            sample.course = (sample.course + 90).truncatingRemainder(dividingBy: 360)
            return .location(sample, at: t)
        }
        let inflation = 1.5
        let config = P.config(twoPin: 1) { $0.fixPinInflation = inflation }
        var engine = NavigationEngine(config: config)
        engine.fixJumps = Self.observation(threshold: -1, cap: 1000)
        for input in inputs { engine.ingest(input) }
        let c = engine.counters
        let source = engine.fixPin[0]
        let offset = try #require(source.offset, "down-weighted at the second pin")
        let offsetM = (offset.east * offset.east + offset.north * offset.north).squareRoot()
        #expect(abs(offsetM - P.offsetM) < 15, "offset \(offsetM) m")

        let jumps = try #require(engine.fixJumps)
        #expect(jumps.list.count == jumps.fixesMeasured, "every measured fix listed")
        // By arrival: the fix taken at 80 s arrives after the pin.
        let after = jumps.list.filter { $0.t > pinT }
        let before = jumps.list.filter { $0.t < pinT }
        #expect(after.count >= 20 && before.count >= 70)
        #expect(before.allSatisfy { $0.path != .reseedBlocked && $0.path != .updateDownweighted && $0.temper == 1 })
        let blocked = try #require(after.first { abs($0.fixT - blockedT) < 1e-6 })
        #expect(blocked.path == .reseedBlocked)
        #expect(c.fixPinReseedsBlocked >= 1)
        #expect(after.filter { $0.path == .reseedBlocked }.count == c.fixPinReseedsBlocked)
        #expect(after.allSatisfy { $0.path == .reseedBlocked || $0.path == .updateDownweighted })
        #expect(after.count == c.fixPinDownweightedFixesAccessory && c.fixPinDownweightedFixesPhone == 0)
        #expect(after.filter { $0.path == .updateDownweighted }.count >= 20)

        // R of a down-weighted fix: σ = max(claimed σ, |offset|) × inflation,
        // tempered by the time since the source's previous fix.
        let d = NavigationConfig()
        let claimed = max(10 * d.fixSigmaPerAccuracy, d.fixSigmaFloorM)
        let sigma = max(claimed, offsetM) * inflation
        #expect(sigma > 10 * claimed)
        for (previous, hit) in zip(jumps.list.dropLast(), jumps.list.dropFirst()) where hit.t > pinT {
            #expect(!hit.network && hit.accuracyM == 10)
            #expect(abs(hit.sigmaM - sigma) <= 1e-9 * sigma, "\(hit.fixT): σ \(hit.sigmaM) vs \(sigma)")
            let temper = min(1, (hit.fixT - previous.fixT) / d.networkFixCorrelationS)
            #expect(abs(temper - 1 / 60) < 1e-6)
            #expect(abs(hit.temper - temper) < 1e-12, "\(hit.fixT): temper \(hit.temper) vs \(temper)")
            #expect(hit.mahalanobis2 < hit.mahalanobis2Untempered)
        }
    }

    @Test func movingFixDuringAnOBDZeroRunCarriesZeroGateEvidence() throws {
        // OBD answers 0 from 30 s while the car drives on at 12 m/s; clean
        // fixes (Doppler 12 m/s) keep coming, and the fix at 40 s is a
        // network fix (no speed: no evidence either way).
        let zeroFrom = 30.0
        let clean = S.cleanFix(accuracy: 5, positionNoise: 1)
        let events = Self.drive.events(gyroNoise: 0.001, obdSpeed: { t, state in
            t >= zeroFrom ? 0 : (state.speed * 3.6).rounded(.down)
        }, fix: { t, state, rng in
            if S.at(t, Self.jumpT) {
                return S.Fix(east: state.east, north: state.north, accuracy: 15, latency: 0)
            }
            return clean(t, state, &rng)
        })
        let jumps = try #require(Self.run(events, observe: Self.observation(threshold: -1, cap: 1000)).engine.fixJumps)
        #expect(jumps.list.count == jumps.fixesMeasured)
        // The run of zeros begins at the first 0 reply, 30.05 s; fixes taken
        // after it with a Doppler speed ≥ `zuptFixGateMinSpeedMps` extend it.
        let firstZero = zeroFrom + 0.05
        for hit in jumps.list {
            #expect(hit.zeroGateEvidence == (hit.fixT > firstZero && !hit.network), "fix \(hit.fixT)")
        }
        #expect(jumps.list.filter(\.zeroGateEvidence).count >= 30)
        #expect(jumps.list.contains { $0.network && $0.fixT == Self.jumpT && !$0.zeroGateEvidence })
    }

    @Test func latencyShiftsTheFixByTheCloudsMotionSinceItsTime() throws {
        // The far network fix of `farFixWithSmallSigma…`, arriving 0.75 s
        // after its own time: the engine compares it with the cloud moved on
        // by the motion since the fix (~12 m/s × 0.7 s, steps 40.1…40.7).
        let latency = 0.75
        let clean = S.cleanFix(accuracy: 5, positionNoise: 1)
        let events = Self.drive.events(gyroNoise: 0.001, fix: { t, state, rng in
            if S.at(t, Self.jumpT) {
                return S.Fix(east: state.east + Self.offEast, north: state.north, accuracy: 15, latency: latency)
            }
            return clean(t, state, &rng)
        })
        let jumps = try #require(Self.run(events, observe: Self.observation()).engine.fixJumps)
        let hit = try #require(jumps.list.first { abs($0.fixT - Self.jumpT) < 1e-9 })
        #expect(abs(hit.t - (Self.jumpT + latency)) < 1e-9 && hit.network && hit.temper == 1 && hit.path == .update)

        // The cloud at the fix's own time (its 10 Hz step the newest) and
        // just before the fix arrives (the 40.7 s step the newest). Only
        // motion and OBD in between: no fix moves the cloud or its weights.
        let fixNs = S.ms(Self.jumpT).nanoseconds, arrivalNs = S.ms(Self.jumpT + latency).nanoseconds
        var engine = NavigationEngine(config: S.config(particles: 300, seed: 3))
        var atFix: NavigationEngine?
        var beforeFix: NavigationEngine?
        for input in S.inputs(events) {
            if atFix == nil, input.arrival.nanoseconds > fixNs { atFix = engine }
            if case .location = input, input.arrival.nanoseconds == arrivalNs {
                beforeFix = engine
                break
            }
            engine.ingest(input)
        }
        let a = try #require(atFix), b = try #require(beforeFix)
        #expect(a.motionHistoryEntry(atOrBefore: .max)?.t == fixNs)
        #expect(b.motionHistoryEntry(atOrBefore: .max)?.t == S.ms(Self.jumpT + 0.7).nanoseconds)
        let ma = Self.moments(a), mb = Self.moments(b)
        let shift = (east: mb.east - ma.east, north: mb.north - ma.north)
        let shiftM = (shift.east * shift.east + shift.north * shift.north).squareRoot()
        #expect(abs(shiftM - 12 * 0.7) < 0.5, "shift \(shiftM) m")
        #expect(abs(atan2(shift.east, shift.north) * 180 / .pi - 30) < 3, "along the 30° heading")

        let config = NavigationConfig()
        let sigma = max(15 * config.fixSigmaPerAccuracy, config.fixSigmaFloorM) * config.networkFixInflation
        #expect(hit.sigmaM == sigma)
        let truth = Self.drive.truth(at: Self.jumpT)
        let fix = S.plane.geodetic(east: truth.east + Self.offEast, north: truth.north)
        let p = try #require(b.tangentPlane).enu(latitude: fix.latitude, longitude: fix.longitude)
        let de = p.east + shift.east - mb.east, dn = p.north + shift.north - mb.north
        let s2 = sigma * sigma
        let expected = NavigationEngine.chi2(de, dn, ee: mb.ee + s2, en: mb.en, nn: mb.nn + s2)
        #expect(abs(hit.mahalanobis2 - expected) <= 1e-9 * expected, "\(hit.mahalanobis2) vs \(expected)")
        #expect(hit.mahalanobis2Untempered == hit.mahalanobis2)
        let innovation = (de * de + dn * dn).squareRoot()
        #expect(abs(hit.innovationM - innovation) < 1e-6, "\(hit.innovationM) vs \(innovation)")
        // Without the shift both would be off by metres: the test sees it.
        let unshifted = ((de - shift.east) * (de - shift.east) + (dn - shift.north) * (dn - shift.north)).squareRoot()
        #expect(abs(unshifted - innovation) > 2)
    }

    // MARK: Observe-only

    @Test func estimatesAreBitIdenticalWithAndWithoutTheObservation() throws {
        let drives: [(events: [LogEvent], prior: NavigationPrior?)] = [
            (Self.events(jumpAccuracy: 15), nil),
            (Self.events(jumpAccuracy: 1414), nil),
        ]
        for (events, prior) in drives {
            let off = Self.run(events, observe: nil, prior: prior)
            let on = Self.run(events, observe: Self.observation(threshold: -1, cap: 5), prior: prior)
            #expect(off.engine.fixJumps == nil)
            #expect((on.engine.fixJumps?.fixesMeasured ?? 0) > 0)
            #expect(on.estimates == off.estimates)
            #expect(on.engine.counters == off.engine.counters)
            #expect(on.engine.east == off.engine.east && on.engine.north == off.engine.north)
            #expect(on.engine.covEE == off.engine.covEE && on.engine.covEN == off.engine.covEN
                    && on.engine.covNN == off.engine.covNN)
            #expect(on.engine.heading == off.engine.heading && on.engine.scale == off.engine.scale)
            #expect(on.engine.logWeight == off.engine.logWeight)
            #expect(on.engine.restore == off.engine.restore)
        }
    }

    @Test func listIsCappedAndKeepsCounting() throws {
        let engine = Self.run(Self.events(jumpAccuracy: 15), observe: Self.observation(threshold: -1, cap: 3)).engine
        let jumps = try #require(engine.fixJumps)
        #expect(jumps.hits == jumps.fixesMeasured && jumps.hits > 3)
        #expect(jumps.list.count == 3)
        #expect(jumps.list.map(\.t) == jumps.list.map(\.t).sorted() && jumps.list[0].t < 2, "the first three")
        #expect(jumps.max?.t == Self.jumpT, "the max is tracked past the cap")
        let lines = ReplayReport.fixJumpLines(jumps)
        #expect(lines.count == 5 && lines[4].contains("\(jumps.hits - 3) more hits (metrics.json lists 3)"))
        let none = try #require(Self.run(Self.events(jumpAccuracy: 15),
                                         observe: Self.observation(threshold: -1, cap: 0)).engine.fixJumps)
        #expect(none.list.isEmpty && none.hits == jumps.hits)
    }

    // MARK: Replay

    @Test func replayReportsTheObservationInMetricsOnly() throws {
        let result = NavigationReplay.run(logName: "synthetic", inputs: S.inputs(Self.events(jumpAccuracy: 15)),
                                          options: ReplayOptions(gps: .use))
        let jumps = try #require(result.fixJumps)
        #expect(jumps.chi2Threshold == 25 && jumps.listCap == 100 && jumps.hits >= 1 && jumps.list.first?.t == Self.jumpT)
        #expect(ReplayReport.summary(result).contains("Fix jumps     M² > 25: \(jumps.hits) of \(jumps.fixesMeasured) "))
        let decoded = try JSONDecoder().decode([ReplayMetrics].self, from: ReplayReport.metricsJSON([ReplayMetrics(result)]))
        #expect(decoded[0].fixJumps == jumps)
        // A row written before the key still decodes, without it.
        var old = try #require(try JSONSerialization.jsonObject(with: ReplayReport.metricsJSON([ReplayMetrics(result)]))
            as? [[String: Any]])
        old[0]["fixJumps"] = nil
        let back = try JSONDecoder().decode([ReplayMetrics].self, from: JSONSerialization.data(withJSONObject: old))
        #expect(back[0].fixJumps == nil)
        #expect(!ReplayReport.markdown([ReplayMetrics(result)]).contains("Fix jumps"), "metrics.md unchanged")
    }
}
