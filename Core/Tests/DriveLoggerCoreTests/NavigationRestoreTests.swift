import Foundation
import Testing

@testable import DriveLoggerCore

/// UX-20: a Navigate run seeded from a restored estimate. Synthetic drives
/// and priors in a local plane at (0, 0) only, synthetic clocks: no real
/// place, date or recording.
@Suite("Navigation UX-20: restored prior")
struct NavigationRestoreTests {
    typealias S = SyntheticDrive
    typealias M = NavigationRestoreModel

    // MARK: Fixtures

    /// Where the restored car stands, local metres.
    static let parkedEast = 500.0
    static let parkedNorth = 800.0
    static let headingDeg = 30.0

    static func prior(_ restoreClass: NavigationRestoreClass, gapS: Double, east: Double = parkedEast,
                      north: Double = parkedNorth, sigmaM: Double = 5, headingStdDeg: Double = 3,
                      speedMps: Double = 0) -> NavigationPrior {
        let p = S.plane.geodetic(east: east, north: north)
        return NavigationPrior(latitude: p.latitude, longitude: p.longitude, covEE: sigmaM * sigmaM, covEN: 0,
                               covNN: sigmaM * sigmaM, headingDeg: headingDeg, headingStdDeg: headingStdDeg,
                               savedT: S.ms(-gapS), lastSpeedMps: speedMps, restoreClass: restoreClass)
    }

    /// After the restart: standing 5 s, then away along the saved heading.
    static let afterParking = S(initialHeadingDeg: headingDeg, [
        .stop(seconds: 5), .ramp(seconds: 5, from: 0, to: 12), .straight(seconds: 30, speed: 12),
    ])

    /// The car is `moved` metres (east, north) from where it was saved.
    enum Fixes { case gnss, wifi, tower, none }

    static func events(_ drive: S = afterParking, fixes: Fixes, movedEast: Double = 0, movedNorth: Double = 0,
                       extra: [LogEvent] = []) -> [LogEvent] {
        let clean = S.cleanFix(accuracy: 5, positionNoise: 1)
        let ox = parkedEast + movedEast, oy = parkedNorth + movedNorth
        return drive.events(gyroNoise: 0.001, fix: { t, state, rng in
            switch fixes {
            case .none:
                return nil
            case .gnss:
                var f = clean(t, state, &rng)
                f?.east += ox
                f?.north += oy
                return f
            case .wifi:
                return S.Fix(east: state.east + ox + 10, north: state.north + oy - 10, accuracy: 65, latency: 0.3)
            case .tower:
                return S.Fix(east: state.east + ox + 200, north: state.north + oy - 150, accuracy: 1414, latency: 0.5)
            }
        }, extra: extra)
    }

    static func run(_ events: [LogEvent], prior: NavigationPrior?, particles: Int = 300, seed: UInt64 = 1,
                    until end: Double? = nil) -> NavigationEngine {
        var engine = NavigationEngine(config: S.config(particles: particles, seed: seed), prior: prior)
        for input in S.inputs(events) {
            if let end, input.arrival > S.ms(end) { break }
            engine.ingest(input)
        }
        return engine
    }

    /// Distance of the estimate from a local point, metres.
    static func distance(_ estimate: NavigationEstimate, east: Double, north: Double) -> Double {
        let p = S.plane.enu(latitude: estimate.latitude, longitude: estimate.longitude)
        return ((p.east - east) * (p.east - east) + (p.north - north) * (p.north - north)).squareRoot()
    }

    static func pin(east: Double, north: Double, at t: Double) -> LogEvent {
        let p = S.plane.geodetic(east: east, north: north)
        return LogEvent(timestamp: S.ms(t), payload: .manualFix(ManualFixSample(
            latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(t), mapSpanM: 360, speedSource: "obd")))
    }

    // MARK: Growth

    @Test func parkedAndStandingStopGrowthIsGapIndependent() throws {
        for gap in [30.0, 3600, 80_000] {
            let parked = try #require(Self.prior(.parked, gapS: gap).seed(gapS: gap))
            #expect(abs(parked.covEE - (25 + 100)) < 1e-9)
            #expect(abs(parked.covNN - (25 + 100)) < 1e-9)
            let headingSigma: Double = try #require(parked.headingSigmaRadians)
            let expected: Double = (9.0 + 9).squareRoot()
            #expect(abs(headingSigma * 180 / Double.pi - expected) < 1e-9)
            let stop = try #require(Self.prior(.standingStop, gapS: gap).seed(gapS: gap))
            #expect(abs(stop.covEE - (25 + 2500)) < 1e-9)
        }
    }

    @Test func movingGrowthCapAndHeading() throws {
        // max(v, 11.1 m/s) × gap per axis; mean not shifted.
        let slow = try #require(Self.prior(.moving, gapS: 60, speedMps: 3).seed(gapS: 60))
        #expect(abs(slow.covEE - (25 + (11.1 * 60) * (11.1 * 60))) < 1e-6)
        #expect(slow.headingRadians == nil, "a gap over 5 s: uniform heading")
        let fast = try #require(Self.prior(.moving, gapS: 60, speedMps: 20).seed(gapS: 60))
        #expect(abs(fast.covNN - (25 + 1200 * 1200)) < 1e-6)
        // Over 1.5 km per axis: no prior.
        #expect(Self.prior(.moving, gapS: 80, speedMps: 20).seed(gapS: 80) == nil)
        #expect(Self.prior(.moving, gapS: 136, speedMps: 0).seed(gapS: 136) == nil)
        #expect(Self.prior(.moving, gapS: 135, speedMps: 0).seed(gapS: 135) != nil)
        // A short gap keeps a Gaussian heading, σ² + (5.5°/s · gap)², and
        // carries the mean forward by speed × gap along the heading (30°).
        let short = try #require(Self.prior(.moving, gapS: 2, speedMps: 10).seed(gapS: 2))
        let shortSigma: Double = try #require(short.headingSigmaRadians)
        let shortExpected: Double = (9.0 + 121).squareRoot()
        #expect(abs(shortSigma * 180 / Double.pi - shortExpected) < 1e-9)
        #expect(abs(short.shiftEastM - 20 * sin(Double.pi / 6)) < 1e-9)
        #expect(abs(short.shiftNorthM - 20 * cos(Double.pi / 6)) < 1e-9)
        #expect(abs(short.covEE - (25 + 22.2 * 22.2)) < 1e-6)
        // Past 5 s: uniform heading, no shift.
        let long = try #require(Self.prior(.moving, gapS: 6, speedMps: 10).seed(gapS: 6))
        #expect(long.headingRadians == nil && long.shiftEastM == 0 && long.shiftNorthM == 0)
        // A stopped class never grows more than a moving car over the gap.
        let stopOneSecond = try #require(Self.prior(.standingStop, gapS: 1).seed(gapS: 1))
        #expect(abs(stopOneSecond.covEE - (25 + 11.1 * 11.1)) < 1e-6)
        #expect(stopOneSecond.shiftEastM == 0)
        let parkedTenthSecond = try #require(Self.prior(.parked, gapS: 0.1).seed(gapS: 0.1))
        #expect(abs(parkedTenthSecond.covEE - (25 + 1.11 * 1.11)) < 1e-6)
        let parkedSigma: Double = try #require(parkedTenthSecond.headingSigmaRadians)
        #expect(abs(parkedSigma * 180 / Double.pi - (9 + 0.55 * 0.55).squareRoot()) < 1e-9)
        // Grown over 30°: uniform.
        #expect(Self.prior(.parked, gapS: 10, headingStdDeg: 31).seed(gapS: 10)?.headingRadians == nil)
        #expect(Self.prior(.parked, gapS: 10, headingStdDeg: 29).seed(gapS: 10)?.headingRadians != nil)
        // A stopped class whose first OBD reply is moving grows as moving.
        #expect(Self.prior(.parked, gapS: 600).seed(gapS: 600, movingAtStart: true) == nil)
        #expect(Self.prior(.parked, gapS: 20).seed(gapS: 20, movingAtStart: true)?.headingRadians == nil)
    }

    @Test func invalidPriorGivesNoSeed() {
        var p = Self.prior(.parked, gapS: 10)
        p.covEN = 100 // |en| > √(ee·nn): not a covariance
        #expect(p.seed(gapS: 10) == nil)
        p = Self.prior(.parked, gapS: 10)
        p.latitude = .nan
        #expect(p.seed(gapS: 10) == nil)
    }

    // MARK: Parked car, then the first fix

    @Test func parkedCarNotMovedConfirmsAndShowsTheArrowAtOnce() throws {
        let events = Self.events(fixes: .gnss)
        let first = Self.run(events, prior: Self.prior(.parked, gapS: 3600), until: 0.01)
        #expect(first.restore.status == .unconfirmed)
        let atOnce = try #require(first.estimate(at: S.ms(0.01)))
        #expect(atOnce.converged, "heading σ √(3² + 3²) is under the arrow threshold")
        #expect(Self.distance(atOnce, east: Self.parkedEast, north: Self.parkedNorth) < 1)
        #expect(abs(angleDifference(atOnce.headingDeg, Self.headingDeg)) < 1)

        let engine = Self.run(events, prior: Self.prior(.parked, gapS: 3600))
        #expect(engine.restore.status == .confirmed)
        #expect(engine.restore.reason == .fix)
        #expect(try #require(engine.restore.decidedT) < S.ms(0.2), "the first fix confirms")
        let end = try #require(engine.estimate(at: S.ms(Self.afterParking.duration)))
        let truth = Self.afterParking.truth(at: Self.afterParking.duration)
        #expect(Self.distance(end, east: truth.east + Self.parkedEast, north: truth.north + Self.parkedNorth) < 15)
    }

    @Test func carMovedTwoKilometresWhileParkedRejectsOnTheFirstFix() throws {
        for fixes in [Fixes.gnss, .wifi] {
            let events = Self.events(fixes: fixes, movedEast: 1600, movedNorth: -1200)
            let engine = Self.run(events, prior: Self.prior(.parked, gapS: 3600), until: 1.5)
            #expect(engine.restore.status == .rejected, "\(fixes)")
            #expect(engine.restore.reason == .fix)
            #expect(try #require(engine.restore.decidedT) < S.ms(0.5), "the first fix rejects")
            // Reinitialised at the fix, as a fresh engine's first fix.
            let estimate = try #require(engine.estimate(at: S.ms(1.5)))
            #expect(Self.distance(estimate, east: Self.parkedEast + 1600, north: Self.parkedNorth - 1200) < 60)
            #expect(!estimate.converged, "no heading at a parked first fix: uniform")
            let full = Self.run(events, prior: Self.prior(.parked, gapS: 3600))
            let fresh = Self.run(events, prior: nil)
            let t = Self.afterParking.duration
            let truth = Self.afterParking.truth(at: t)
            let te = truth.east + Self.parkedEast + 1600, tn = truth.north + Self.parkedNorth - 1200
            let restoredError = Self.distance(try #require(full.estimate(at: S.ms(t))), east: te, north: tn)
            let freshError = Self.distance(try #require(fresh.estimate(at: S.ms(t))), east: te, north: tn)
            #expect(restoredError < freshError + 30, "\(fixes): \(restoredError) vs fresh \(freshError)")
        }
    }

    @Test func wifiFixConfirmsATowerFixNeverDoes() throws {
        // A moving prior 60 s old at 20 m/s: per-axis σ ≈ 1.2 km, so a tower
        // fix (σ ≈ 940 m) would pass the σ rule; it must not confirm.
        let prior = Self.prior(.moving, gapS: 60, speedMps: 20)
        let tower = Self.run(Self.events(fixes: .tower), prior: prior)
        #expect(tower.restore.status == .unconfirmed)
        #expect(tower.counters.networkFixesUsed > 0, "tower fixes are still used")
        let wifi = Self.run(Self.events(fixes: .wifi), prior: prior)
        #expect(wifi.restore.status == .confirmed)
        #expect(wifi.restore.reason == .fix)
    }

    @Test func towerFixFarAwayStillRejects() {
        // 30 km off: a tower fix's own σ cannot cover it.
        let engine = Self.run(Self.events(fixes: .tower, movedEast: 30_000), prior: Self.prior(.parked, gapS: 600),
                              until: 2)
        #expect(engine.restore.status == .rejected)
        #expect(engine.restore.reason == .fix)
    }

    @Test func gnssFixWiderThanThePriorDoesNotConfirm() {
        // A parked prior (σ ≈ 11 m): a 100 m GNSS fix (σ 66 m > 50 m) agrees
        // but is too coarse to confirm.
        let drive = S(initialHeadingDeg: Self.headingDeg, [.stop(seconds: 10)])
        let events = drive.events(fix: { _, state, _ in
            S.Fix(east: state.east + Self.parkedEast, north: state.north + Self.parkedNorth, accuracy: 100,
                  speed: 0, speedAccuracy: 1)
        })
        let engine = Self.run(events, prior: Self.prior(.parked, gapS: 600))
        #expect(engine.restore.status == .unconfirmed)
    }

    // MARK: Fix variance in the restore test (R77.1-1)

    /// A parked prior (σ ≈ 11 m per axis), the car not moved and standing,
    /// one fix at 2 s offset by (`dEast`, `dNorth`) from where it stands.
    /// `gnss`: a Doppler speed (0 m/s), so not a network fix.
    static func oneFix(dEast: Double, dNorth: Double, accuracy: Double, gnss: Bool) -> NavigationEngine {
        let drive = S(initialHeadingDeg: headingDeg, [.stop(seconds: 4)])
        let events = drive.events(fix: { t, state, _ in
            guard abs(t - 2) < 1e-6 else { return nil }
            return S.Fix(east: state.east + parkedEast + dEast, north: state.north + parkedNorth + dNorth,
                         accuracy: accuracy, speed: gnss ? 0 : -1, speedAccuracy: gnss ? 1 : -1)
        })
        return run(events, prior: prior(.parked, gapS: 600))
    }

    @Test func offsetNetworkFixesWithinTheirOwnSigmaKeepTheParkedPrior() throws {
        // Wi-Fi 60 m off, accuracy 65 m (σ ≈ 43 m): d² ≈ 60² / (125 + 43²)
        // ≈ 1.8. Without the fix's σ² the cloud's ~11 m alone gives ≈ 29.
        let wifi = Self.oneFix(dEast: 36, dNorth: -48, accuracy: 65, gnss: false)
        #expect(wifi.restore.status == .confirmed, "σ 43 m ≤ 50 m, not a tower fix")
        #expect(wifi.restore.reason == .fix)
        // A tower fix 1 km off, accuracy 1414 m (σ ≈ 936 m): d² ≈ 1.1, kept
        // and never confirming. Without σ² it would be ≈ 8000.
        let tower = Self.oneFix(dEast: 600, dNorth: 800, accuracy: 1414, gnss: false)
        #expect(tower.restore.status == .unconfirmed)
        #expect(tower.counters.networkFixesUsed == 1, "the tower fix is still used")
        for engine in [wifi, tower] {
            let end = try #require(engine.estimate(at: S.ms(4)))
            #expect(Self.distance(end, east: Self.parkedEast, north: Self.parkedNorth) < 60,
                    "the prior is kept, not reinitialised at the fix")
        }
    }

    @Test(arguments: [(0.97, false), (1.03, true)])
    func gnssFixAtTheChi2BoundaryOfTheCombinedCovariance(scale: Double, rejects: Bool) throws {
        // The bound is r² = 9.21 (λ + σ²) along the cloud's major axis
        // (λ from its estimate's ellipse, read before the fix), with the
        // fix's σ = accuracy / 1.51 ≈ 19.9 m: r ≈ 69 m. Without σ², 3 %
        // inside (≈ 67 m) would be d² ≈ 36 and reject.
        let accuracy = 30.0
        let drive = S(initialHeadingDeg: Self.headingDeg, [.stop(seconds: 4)])
        let standing = Self.run(drive.events(), prior: Self.prior(.parked, gapS: 600))
        let estimate = try #require(standing.estimate(at: S.ms(2)))
        let lambda = estimate.ellipse.semiMajorM * estimate.ellipse.semiMajorM / ErrorEllipse.chiSquare95
        let sigma = accuracy * NavigationConfig().fixSigmaPerAccuracy
        let r = scale * (M.rejectChi2 * (lambda + sigma * sigma)).squareRoot()
        let bearing = estimate.ellipse.orientationDeg * .pi / 180
        let engine = Self.oneFix(dEast: r * sin(bearing), dNorth: r * cos(bearing), accuracy: accuracy, gnss: true)
        #expect(engine.restore.status == (rejects ? .rejected : .confirmed),
                "\(r) m off, λ \(lambda) m², σ \(sigma) m")
        #expect(engine.restore.reason == .fix)
    }

    // MARK: Pins

    @Test func pinThatDisagreesRejectsAndInitialisesAtThePin() throws {
        let e = Self.parkedEast + 600, n = Self.parkedNorth
        let events = Self.events(fixes: .none, extra: [Self.pin(east: e, north: n, at: 3)])
        let engine = Self.run(events, prior: Self.prior(.parked, gapS: 3600), until: 4)
        #expect(engine.restore.status == .rejected)
        #expect(engine.restore.reason == .pin)
        let estimate = try #require(engine.estimate(at: S.ms(4)))
        #expect(Self.distance(estimate, east: e, north: n) < 5)
        #expect(estimate.headingStdDeg > 60, "a first pin: uniform heading")
    }

    @Test func pinThatAgreesConfirms() throws {
        let events = Self.events(fixes: .none, extra: [Self.pin(east: Self.parkedEast + 20, north: Self.parkedNorth,
                                                                at: 3)])
        let engine = Self.run(events, prior: Self.prior(.parked, gapS: 3600), until: 4)
        #expect(engine.restore.status == .confirmed)
        #expect(engine.restore.reason == .pin)
        let estimate = try #require(engine.estimate(at: S.ms(4)))
        #expect(estimate.converged, "the restored heading is kept")
    }

    /// R77.1-2: a pin that rejects a restored prior while the car drives,
    /// written late (Navigate commits it when the 3 s undo window closes),
    /// initialises the engine as a fresh engine's first late pin does: the
    /// cloud carried forward from the tap over the steps run since, from
    /// the pre-initialisation record kept while the prior was unconfirmed.
    /// GPS masked (no fixes delivered); the car was moved 600 m while parked.
    @Test func lateRejectingPinWhileDrivingMatchesAFreshEngine() throws {
        let v = 15.0, tPin = 20.0, delay = 3.0, tSecond = 60.0
        let drive = S(initialHeadingDeg: Self.headingDeg, [
            .stop(seconds: 5), .ramp(seconds: 5, from: 0, to: v), .straight(seconds: 20, speed: v),
            .turn(degrees: 60, seconds: 10, speed: v), .straight(seconds: 40, speed: v),
        ])
        let oe = Self.parkedEast + 600, on = Self.parkedNorth
        let a = drive.truth(at: tPin), b = drive.truth(at: tSecond)
        let events = drive.events(gyroNoise: 0.002, extra: [
            Self.pin(east: a.east + oe, north: a.north + on, at: tPin),
            Self.pin(east: b.east + oe, north: b.north + on, at: tSecond),
        ])
        let inputs = NavigationLatePinTests.delayingPin(S.inputs(events), at: tPin, by: delay)
        let config = S.config(particles: 2000, seed: 1)
        func run(prior: NavigationPrior?, at times: [Double]) -> (NavigationEngine, [NavigationEstimate?]) {
            var engine = NavigationEngine(config: config, prior: prior)
            var out: [NavigationEstimate?] = []
            var pending = times[...]
            for input in inputs {
                while let t = pending.first, input.arrival > S.ms(t) {
                    out.append(engine.estimate(at: S.ms(t)))
                    pending = pending.dropFirst()
                }
                engine.ingest(input)
            }
            return (engine, out)
        }
        let times = [tPin + delay + 0.5, tSecond + 3.5]
        let (restored, r) = run(prior: Self.prior(.parked, gapS: 3600), at: times)
        let (fresh, f) = run(prior: nil, at: times)
        #expect(restored.restore.status == .rejected && restored.restore.reason == .pin)
        #expect(restored.counters.lateManualFixes == 1 && fresh.counters.lateManualFixes == 1)
        #expect(restored.counters.lateManualFixesMeanShift == 0 && fresh.counters.lateManualFixesMeanShift == 0,
                "the steps since the tap are on record: no mean-shift fallback")
        func gap(_ p: NavigationEstimate, _ q: NavigationEstimate) -> Double {
            Self.distance(p, east: S.plane.enu(latitude: q.latitude, longitude: q.longitude).east,
                          north: S.plane.enu(latitude: q.latitude, longitude: q.longitude).north)
        }
        // Just after the late pin: the same ring-shaped cloud, carried forward.
        let r0 = try #require(r[0]), f0 = try #require(f[0])
        #expect(gap(r0, f0) < 1, "\(gap(r0, f0)) m from the fresh engine")
        #expect(abs(r0.ellipse.semiMajorM - f0.ellipse.semiMajorM) < 0.02 * f0.ellipse.semiMajorM,
                "ellipse \(r0.ellipse.semiMajorM) m vs fresh \(f0.ellipse.semiMajorM) m")
        #expect(abs(r0.ellipse.semiMinorM - f0.ellipse.semiMinorM) < 0.02 * f0.ellipse.semiMinorM)
        // After the second pin, past the turn: the same converged estimate.
        let r1 = try #require(r[1]), f1 = try #require(f[1])
        #expect(gap(r1, f1) < 3, "\(gap(r1, f1)) m from the fresh engine")
        #expect(abs(angleDifference(r1.headingDeg, f1.headingDeg)) < 2)
        let truth = drive.truth(at: times[1])
        #expect(Self.distance(r1, east: truth.east + oe, north: truth.north + on) < 20)
    }

    // MARK: First OBD reply, cap, cached fix

    @Test func stoppedPriorMovingAtStartRegrowsOrRejects() throws {
        let rolling = S(initialHeadingDeg: Self.headingDeg, initialSpeed: 12, [.straight(seconds: 20, speed: 12)])
        let events = Self.events(rolling, fixes: .none)
        // 20 s gap: 11.1 m/s × 20 s = 222 m per axis, heading uniform.
        let short = Self.run(events, prior: Self.prior(.parked, gapS: 20), until: 1)
        #expect(short.restore.status == .unconfirmed)
        #expect(short.restore.regrownAsMoving)
        let estimate = try #require(short.estimate(at: S.ms(1)))
        #expect(!estimate.converged)
        #expect(estimate.ellipse.semiMajorM > 400)
        // 10 min gap: far beyond 1.5 km, the run waits for a fix.
        let long = Self.run(events, prior: Self.prior(.parked, gapS: 600), until: 1)
        #expect(long.restore.status == .rejected)
        #expect(long.restore.reason == .movingAtStart)
        #expect(!long.isInitialized)
        // OBD 0 at the start keeps the parked prior as it was.
        let parked = Self.run(Self.events(fixes: .none), prior: Self.prior(.parked, gapS: 600), until: 1)
        #expect(parked.restore.status == .unconfirmed)
        #expect(!parked.restore.regrownAsMoving)
        #expect(try #require(parked.estimate(at: S.ms(1))).converged)
    }

    /// A parked car pulling out at `kmh` from the first input on, its
    /// every OBD reply `kmh`; no fix.
    static func pullOut(kmh: Double, seconds: Double = 10) -> [LogEvent] {
        let drive = kmh == 0
            ? S(initialHeadingDeg: headingDeg, [.stop(seconds: seconds)])
            : S(initialHeadingDeg: headingDeg, initialSpeed: kmh / 3.6, [.straight(seconds: seconds, speed: kmh / 3.6)])
        return drive.events(gyroNoise: 0.001, obdSpeed: { _, _ in kmh })
    }

    @Test(arguments: [(0.0, NavigationRestoreClass.parked), (5, .parked), (9.9, .parked), (10, .parked), (15, .parked),
                      (5, .standingStop), (10, .standingStop)])
    func slowPullOutKeepsTheStoppedPrior(kmh: Double, restoreClass: NavigationRestoreClass) throws {
        // The first OBD reply arrives at 0.05 s; the cloud is the same
        // before it whatever it says (same draws, same IMU), so the
        // covariance right after it differs only by what the reply did.
        let replyT = 0.05
        let prior = Self.prior(restoreClass, gapS: 600)
        let engine = Self.run(Self.pullOut(kmh: kmh), prior: prior, until: replyT)
        let still = Self.run(Self.pullOut(kmh: 0), prior: prior, until: replyT)
        let before = Self.run(Self.pullOut(kmh: kmh), prior: prior, until: replyT - 0.001)
        #expect(before.restore.status == .unconfirmed && before.restore.slowPullOutKmh == nil)
        if kmh < M.slowPullOutMaxKmh {
            #expect(engine.restore.status == .unconfirmed, "\(kmh) km/h: kept")
            #expect(!engine.restore.regrownAsMoving)
            #expect(engine.restore.slowPullOutKmh == (kmh > 0 ? kmh : nil))
            let a = try #require(engine.estimate(at: S.ms(replyT)))
            let b = try #require(still.estimate(at: S.ms(replyT)))
            let roll = kmh / 3.6 * M.slowPullOutRollS
            let ca = a.ellipse.covariance, cb = b.ellipse.covariance
            #expect(abs(ca.ee - (cb.ee + roll * roll)) < 1e-6 * max(1, ca.ee), "\(kmh): \(ca.ee) vs \(cb.ee) + \(roll)²")
            #expect(abs(ca.nn - (cb.nn + roll * roll)) < 1e-6 * max(1, ca.nn))
            #expect(abs(ca.en - cb.en) < 1e-6 * max(1, ca.ee))
            #expect(a.latitude == b.latitude && a.longitude == b.longitude, "the mean stays where it was saved")
            #expect(a.converged, "the heading is kept")
        } else {
            // 10 min as a moving car: far beyond 1.5 km, rejected as before.
            #expect(engine.restore.regrownAsMoving, "\(kmh) km/h: regrown as moving")
            #expect(engine.restore.slowPullOutKmh == nil)
            #expect(engine.restore.status == .rejected && engine.restore.reason == .movingAtStart)
            #expect(!engine.isInitialized)
        }
    }

    @Test func slowPullOutThenAgreeingFixConfirms() throws {
        // Pulling out at 2 m/s (OBD 7 km/h) from where it was saved: kept,
        // and the first clean fix (from 3 s, after the first reply) confirms it.
        let drive = S(initialHeadingDeg: Self.headingDeg, initialSpeed: 2, [
            .straight(seconds: 5, speed: 2), .ramp(seconds: 5, from: 2, to: 12),
            .straight(seconds: 20, speed: 12),
        ])
        let events = Self.events(drive, fixes: .gnss).filter {
            if case .location = $0.payload { return $0.timestamp >= S.ms(3) }
            return true
        }
        let engine = Self.run(events, prior: Self.prior(.parked, gapS: 900))
        #expect(engine.restore.slowPullOutKmh == 7)
        #expect(engine.restore.status == .confirmed && engine.restore.reason == .fix)
        #expect(engine.counters.reseeds == 0)
        let end = try #require(engine.estimate(at: S.ms(drive.duration)))
        let truth = drive.truth(at: drive.duration)
        #expect(Self.distance(end, east: truth.east + Self.parkedEast, north: truth.north + Self.parkedNorth) < 15)
    }

    // MARK: Record-stop hand-over confirmation

    /// A moving prior `gapS` old with `converged` and `handOver` set.
    static func handOverPrior(gapS: Double, converged: Bool, handOver: Bool = true,
                              restoreClass: NavigationRestoreClass = .moving) -> NavigationPrior {
        var prior = Self.prior(restoreClass, gapS: gapS, headingStdDeg: converged ? 3 : 40,
                               speedMps: restoreClass == .moving ? 12 : 0)
        prior.converged = converged
        prior.handOver = handOver
        return prior
    }

    static let handOverDrive = S(initialHeadingDeg: headingDeg, initialSpeed: 12, [.straight(seconds: 20, speed: 12)])

    @Test(arguments: [(3.0, true, NavigationRestore.Status.confirmed), (3, false, .unconfirmed),
                      (10, true, .confirmed), (12, true, .unconfirmed)])
    func handOverConfirmsOnlyAConvergedShortGap(gapS: Double, converged: Bool,
                                                expected: NavigationRestore.Status) throws {
        let events = Self.events(Self.handOverDrive, fixes: .none)
        let engine = Self.run(events, prior: Self.handOverPrior(gapS: gapS, converged: converged), until: 0.01)
        #expect(engine.restore.status == expected, "gap \(gapS) s, converged \(converged)")
        if expected == .confirmed {
            #expect(engine.restore.reason == .handOver)
            #expect(engine.restore.decidedT == S.ms(0))
        } else {
            #expect(engine.restore.reason == nil && engine.restore.decidedT == nil)
        }
        // Only the status: the cloud is the one the same prior without the
        // flag gives, at every step.
        var plain = Self.handOverPrior(gapS: gapS, converged: converged)
        plain.handOver = false
        let full = Self.run(events, prior: Self.handOverPrior(gapS: gapS, converged: converged))
        let reference = Self.run(events, prior: plain)
        #expect(reference.restore.status == .unconfirmed)
        for t in stride(from: 0.5, through: 19.5, by: 3.0) {
            #expect(full.estimate(at: S.ms(t)) == reference.estimate(at: S.ms(t)), "t \(t)")
        }
        #expect(full.counters == reference.counters)
    }

    @Test func withoutTheHandOverFlagAShortConvergedGapStaysUnconfirmed() {
        // A relaunch a few seconds after a kill: the state is as fresh as a
        // hand-over's, but the app never sets the flag for it.
        let events = Self.events(Self.handOverDrive, fixes: .none)
        let engine = Self.run(events, prior: Self.handOverPrior(gapS: 3, converged: true, handOver: false), until: 1)
        #expect(engine.restore.status == .unconfirmed)
    }

    @Test func nextMorningRestoreIsNeverConfirmedByTheHandOverRule() throws {
        // Saved converged, read 8 h later even with the flag set: the gap
        // rule refuses; `prior(at:)` never sets the flag by itself.
        let state = Self.state()
        let morning = SessionClock(referenceUptimeSeconds: 5000 + 8 * 3600,
                                   wallClockStart: Date(timeIntervalSince1970: 1_000_000_000 + 8 * 3600))
        #expect(try #require(state.prior(at: .zero, clock: morning, bootSessionID: "boot-a")).handOver == false)
        let flagged = try #require(state.prior(at: .zero, clock: morning, bootSessionID: "boot-a", handOver: true))
        #expect(flagged.converged && flagged.handOver)
        let engine = Self.run(Self.events(fixes: .none), prior: flagged, until: 2)
        #expect(engine.restore.status == .unconfirmed)
    }

    @Test func handOverConfirmedStoppedPriorStillRegrowsAtAMovingFirstReply() throws {
        // Record stopped at a light (standing stop), Navigate resumes 3 s
        // later, the first reply says 15 km/h: confirmed by the hand-over,
        // and grown as moving exactly as without the flag.
        let events = Self.events(Self.handOverDrive, fixes: .none)
        let flagged = Self.run(events, prior: Self.handOverPrior(gapS: 3, converged: true, restoreClass: .standingStop),
                               until: 1)
        var plain = Self.handOverPrior(gapS: 3, converged: true, restoreClass: .standingStop)
        plain.handOver = false
        let reference = Self.run(events, prior: plain, until: 1)
        #expect(flagged.restore.status == .confirmed && flagged.restore.reason == .handOver)
        #expect(flagged.restore.regrownAsMoving && reference.restore.regrownAsMoving)
        #expect(flagged.estimate(at: S.ms(1)) == reference.estimate(at: S.ms(1)))
    }

    @Test func movingPriorTooWideStartsFresh() throws {
        let events = Self.events(fixes: .gnss)
        let first = Self.run(events, prior: Self.prior(.moving, gapS: 200, speedMps: 5), until: 0.01)
        #expect(first.restore.status == .none)
        #expect(first.restore.reason == .tooUncertain)
        #expect(!first.isInitialized)
        let engine = Self.run(events, prior: Self.prior(.moving, gapS: 200, speedMps: 5))
        #expect(engine.isInitialized, "the first fix initialises it as usual")
        #expect(engine.restore.status == .none)
    }

    @Test func cachedFixOlderThanTheSaveIsIgnored() {
        func cached(east: Double, fixT: Double) -> LogEvent {
            let p = S.plane.geodetic(east: east, north: Self.parkedNorth)
            return .location(LocationSample(latitude: p.latitude, longitude: p.longitude, altitude: 0,
                                            horizontalAccuracy: 10, verticalAccuracy: -1, speed: 3.6, speedAccuracy: 1,
                                            course: -1, courseAccuracy: -1, receivedT: S.ms(0.2), ageS: 0.2 - fixT),
                             at: S.ms(fixT))
        }
        // 3 km off and 60 s old, the state 30 s old: ignored, no rejection.
        let old = Self.run(Self.events(fixes: .none, extra: [cached(east: Self.parkedEast + 3000, fixT: -60)]),
                           prior: Self.prior(.parked, gapS: 30), until: 2)
        #expect(old.restore.status == .unconfirmed)
        #expect(old.restore.fixesOlderThanSave == 1)
        // Newer than the save: an ordinary observation through the test.
        let newer = Self.run(Self.events(fixes: .none, extra: [cached(east: Self.parkedEast + 3000, fixT: -10)]),
                             prior: Self.prior(.parked, gapS: 30), until: 2)
        #expect(newer.restore.status == .rejected)
        #expect(newer.restore.fixesOlderThanSave == 0)
    }

    @Test func cachedFixOlderThanTheSaveIsIgnoredAfterAHandOverConfirmation() throws {
        // Record stopped at a light 1 s ago, converged: confirmed by the
        // hand-over at the first input. A cached fix from before the save,
        // where the car stands, is still older information than the state:
        // ignored, and the cloud is the one the same run without it gives.
        let prior = Self.handOverPrior(gapS: 1, converged: true, restoreClass: .standingStop)
        let p = S.plane.geodetic(east: Self.parkedEast, north: Self.parkedNorth)
        let cached = LogEvent.location(
            LocationSample(latitude: p.latitude, longitude: p.longitude, altitude: 0, horizontalAccuracy: 5,
                           verticalAccuracy: -1, speed: 0, speedAccuracy: 0.3, course: -1, courseAccuracy: -1,
                           receivedT: S.ms(0.2), ageS: 2.2),
            at: S.ms(-2))
        let with = Self.run(Self.events(fixes: .none, extra: [cached]), prior: prior, until: 2)
        let without = Self.run(Self.events(fixes: .none), prior: prior, until: 2)
        #expect(with.restore.status == .confirmed && with.restore.reason == .handOver)
        #expect(with.restore.fixesOlderThanSave == 1)
        #expect(with.counters.fixesUsed == 0)
        let a = try #require(with.estimate(at: S.ms(2)))
        let b = try #require(without.estimate(at: S.ms(2)))
        #expect(a.ellipse.semiMajorM > 25, "the grown prior, not shrunk to a 5 m fix: \(a.ellipse.semiMajorM)")
        #expect(a == b)
    }

    @Test func rejectedParkedPriorWithoutOBDReleasesTheParkedHold() throws {
        // No OBD at all, cruising at a constant 12 m/s from the first input
        // (no acceleration to clear the hold through the IMU), the stopped
        // prior 2.6 km from the car: the first clean fix rejects it, and the
        // prior's parked hold goes with it. The run then matches a run
        // without a prior instead of freezing at speed 0.
        let cruise = S(initialHeadingDeg: Self.headingDeg, initialSpeed: 12, [.straight(seconds: 30, speed: 12)])
        let clean = S.cleanFix(accuracy: 5, positionNoise: 1)
        let moved = 2600.0
        let events = cruise.events(gyroNoise: 0.001, obdSpeed: { _, _ in nil }, fix: { t, state, rng in
            var f = clean(t, state, &rng)
            f?.east += Self.parkedEast + moved
            f?.north += Self.parkedNorth
            return f
        })
        let engine = Self.run(events, prior: Self.prior(.parked, gapS: 600))
        #expect(engine.restore.status == .rejected && engine.restore.reason == .fix)
        let decided = try #require(engine.restore.decidedT)
        #expect(decided <= S.ms(0.1), "the first fix rejects")
        let atRejection = Self.run(events, prior: Self.prior(.parked, gapS: 600), until: decided.seconds)
        #expect(atRejection.restore.status == .rejected)
        #expect(engine.counters.staleParkedSteps == atRejection.counters.staleParkedSteps,
                "no parked step after the rejection")
        let fresh = Self.run(events, prior: nil)
        let end = S.ms(cruise.duration)
        let a = try #require(engine.estimate(at: end))
        let b = try #require(fresh.estimate(at: end))
        let pb = S.plane.enu(latitude: b.latitude, longitude: b.longitude)
        #expect(Self.distance(a, east: pb.east, north: pb.north) < 5, "\(Self.distance(a, east: pb.east, north: pb.north)) m")
    }

    // MARK: Determinism, no prior

    @Test func seededRunIsDeterministic() {
        let events = Self.events(fixes: .wifi, movedEast: 1600, movedNorth: -1200)
        let times = stride(from: 0.5, through: Self.afterParking.duration, by: 2).map { $0 }
        func estimates() -> [NavigationEstimate?] {
            var engine = NavigationEngine(config: S.config(particles: 300), prior: Self.prior(.parked, gapS: 900))
            var out: [NavigationEstimate?] = []
            var pending = times[...]
            for input in S.inputs(events) {
                while let t = pending.first, S.ms(t) < input.arrival {
                    out.append(engine.estimate(at: S.ms(t)))
                    pending = pending.dropFirst()
                }
                engine.ingest(input)
            }
            return out
        }
        let a = estimates(), b = estimates()
        #expect(a == b)
        #expect(a.compactMap { $0 }.count == times.count)
    }

    @Test func withoutPriorTheRunIsUnchanged() {
        let events = Self.events(fixes: .gnss)
        let a = Self.run(events, prior: nil)
        var b = NavigationEngine(config: S.config(particles: 300))
        for input in S.inputs(events) { b.ingest(input) }
        let t = S.ms(Self.afterParking.duration)
        #expect(a.estimate(at: t) == b.estimate(at: t))
        #expect(a.counters == b.counters)
        #expect(a.restore == NavigationRestore())
    }

    // MARK: Classification at save

    @Test func classification() {
        // Away, 20 s at 12 m/s, then braking to a stop held 10 s.
        let drive = S(initialHeadingDeg: 0, [
            .ramp(seconds: 4, from: 0, to: 12), .straight(seconds: 20, speed: 12), .ramp(seconds: 4, from: 12, to: 0),
            .stop(seconds: 10),
        ])
        // OBD replies end at 34 s: the link went away while stopped.
        let events = drive.events(obdSpeed: { t, state in t > 34 ? nil : (state.speed * 3.6).rounded(.down) },
                                  fix: S.cleanFix())
        func engine(until t: Double) -> NavigationEngine { Self.run(events, prior: nil, until: t) }
        #expect(engine(until: 15).restoreClass(at: S.ms(15), engineOff: false) == .moving)
        #expect(engine(until: 15).restoreClass(at: S.ms(15), engineOff: true) == .moving,
                "a link lost mid-drive is not a parked car")
        // The zeros begin at ~27.9 s.
        #expect(engine(until: 29).restoreClass(at: S.ms(29), engineOff: false) == .moving)
        #expect(engine(until: 29).restoreClass(at: S.ms(29), engineOff: true) == .parked)
        #expect(engine(until: 32).restoreClass(at: S.ms(32), engineOff: false) == .standingStop)
        // Stale after the 0, no motion since: parked.
        #expect(engine(until: 38).restoreClass(at: S.ms(38), engineOff: false) == .parked)
        // No OBD at all: moving.
        let noOBD = drive.events(obdSpeed: { _, _ in nil }, fix: S.cleanFix())
        #expect(Self.run(noOBD, prior: nil, until: 30).restoreClass(at: S.ms(30), engineOff: true) == .moving)

        // R77.2-2 (a): standing 5 s at OBD 0, then the link drops and, at
        // 8 s, the car drives off: the IMU clears the parked latch. The run
        // of zeros is over 3 s old but stale: moving, not a standing stop.
        let away = S(initialHeadingDeg: 0, [
            .stop(seconds: 8), .ramp(seconds: 5, from: 0, to: 12), .straight(seconds: 10, speed: 12),
        ])
        let dropped = away.events(obdSpeed: { t, _ in t > 5 ? nil : 0 })
        #expect(Self.run(dropped, prior: nil, until: 4.5).restoreClass(at: S.ms(4.5), engineOff: false) == .standingStop)
        #expect(Self.run(dropped, prior: nil, until: 7.5).restoreClass(at: S.ms(7.5), engineOff: false) == .parked,
                "stale after the 0, no motion yet")
        #expect(Self.run(dropped, prior: nil, until: 11).restoreClass(at: S.ms(11), engineOff: false) == .moving)

        // R77.2-2 (b): OBD stuck at 0 while clean fixes read 12 m/s: the
        // zero is vetoed (`zuptFixGate`), so neither a standing stop nor,
        // with `engineOff`, parked.
        let stuck = S(initialHeadingDeg: 0, initialSpeed: 12, [.straight(seconds: 20, speed: 12)])
            .events(obdSpeed: { _, _ in 0 }, fix: S.cleanFix())
        let vetoed = Self.run(stuck, prior: nil, until: 10)
        #expect(vetoed.restoreClass(at: S.ms(10), engineOff: false) == .moving)
        #expect(vetoed.restoreClass(at: S.ms(10), engineOff: true) == .moving)
        let unvetoed = S(initialHeadingDeg: 0, initialSpeed: 12, [.straight(seconds: 20, speed: 12)])
            .events(obdSpeed: { _, _ in 0 })
        #expect(Self.run(unvetoed, prior: nil, until: 10).restoreClass(at: S.ms(10), engineOff: false) == .standingStop,
                "the same zeros without the fixes")
    }

    /// R77.2-1: a run seeded from a stopped-class prior saves that class
    /// while it still waits for its first OBD reply (Navigate opened before
    /// the ignition), and a run of zeros from that first reply continues
    /// the prior's stop.
    @Test(arguments: [NavigationRestoreClass.parked, .standingStop])
    func stoppedPriorKeepsItsClassUntilOBDSaysOtherwise(_ restoreClass: NavigationRestoreClass) throws {
        let prior = Self.prior(restoreClass, gapS: 600)
        // Motion only: the car stands 5 s, then drives off; no OBD, no fix.
        let noOBD = Self.afterParking.events(gyroNoise: 0.001, obdSpeed: { _, _ in nil })
        let waiting = Self.run(noOBD, prior: prior, until: 4)
        #expect(waiting.restore.status == .unconfirmed)
        #expect(waiting.restoreClass(at: S.ms(4), engineOff: false) == restoreClass)
        #expect(waiting.restoreClass(at: S.ms(4), engineOff: true) == .parked)
        let state = try #require(NavigationRestoreState.capture(waiting, at: S.ms(4), clock: Self.clock,
                                                                bootSessionID: nil, engineOff: false))
        #expect(state.restoreClass == restoreClass)
        // Driving off: the IMU clears the parked hold.
        #expect(Self.run(noOBD, prior: prior, until: 12).restoreClass(at: S.ms(12), engineOff: false) == .moving)
        // Without a prior the same motion is moving throughout.
        #expect(Self.run(noOBD, prior: nil, until: 4).restoreClass(at: S.ms(4), engineOff: false) == .moving)

        // The first replies are 0 (from 0.05 s): 1.5 s of zeros continue the
        // prior's stop. Without a prior they are not yet a standing stop.
        let zeros = Self.pullOut(kmh: 0)
        let stopped = Self.run(zeros, prior: prior, until: 1.5)
        #expect(stopped.restoreClass(at: S.ms(1.5), engineOff: false) == .standingStop)
        #expect(stopped.restoreClass(at: S.ms(1.5), engineOff: true) == .parked)
        #expect(Self.run(zeros, prior: nil, until: 1.5).restoreClass(at: S.ms(1.5), engineOff: false) == .moving)

        // A slow pull-out, then zeros from 2 s: a new run of zeros, under 3 s.
        let rolled = S(initialHeadingDeg: Self.headingDeg, [.stop(seconds: 10)])
            .events(gyroNoise: 0.001, obdSpeed: { t, _ in t < 2 ? 5 : 0 })
        let rerun = Self.run(rolled, prior: prior, until: 3.5)
        #expect(rerun.restore.slowPullOutKmh == 5)
        #expect(rerun.restoreClass(at: S.ms(3.5), engineOff: false) == .moving)

        // Rejected after its first 0 reply (a clean fix 2 km away at 1 s):
        // as without a prior, 1.95 s of zeros are not a standing stop.
        let far = S(initialHeadingDeg: Self.headingDeg, [.stop(seconds: 10)]).events(gyroNoise: 0.001, fix: { t, _, _ in
            t < 1 ? nil : S.Fix(east: Self.parkedEast + 2000, north: Self.parkedNorth, accuracy: 5,
                                speed: 0, speedAccuracy: 0.3)
        })
        let rejected = Self.run(far, prior: prior, until: 2)
        #expect(rejected.restore.status == .rejected)
        #expect(rejected.restoreClass(at: S.ms(2), engineOff: false) == .moving)
    }

    // MARK: Persisted state

    static let clock = SessionClock(referenceUptimeSeconds: 5000, wallClockStart: Date(timeIntervalSince1970: 1_000_000_000))

    static func state(savedAtOffset: Double = 0, boot: String? = "boot-a", uptime: Double = 5000) -> NavigationRestoreState {
        let p = S.plane.geodetic(east: parkedEast, north: parkedNorth)
        return NavigationRestoreState(
            savedAt: Date(timeIntervalSince1970: 1_000_000_000 + savedAtOffset), bootSessionID: boot,
            uptimeSeconds: uptime, latitude: p.latitude, longitude: p.longitude, covEE: 30, covEN: 4, covNN: 20,
            headingDeg: headingDeg, headingStdDeg: 3, converged: true, restoreClass: .parked, speedMps: 0,
            lastOBDSpeedKmh: 0, lastOBDAgeS: 12, roadPacks: ["0123abcd"])
    }

    @Test func stateRoundTripsAndRefusesBadInput() throws {
        let state = Self.state(savedAtOffset: 0.25)
        let data = try state.encoded()
        #expect(try NavigationRestoreState.decode(data) == state)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"class\":\"parked\""))

        func decode(_ edit: (inout [String: Any]) -> Void) -> NavigationRestoreState.DecodeError? {
            var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            edit(&object)
            let bytes = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            do {
                _ = try NavigationRestoreState.decode(bytes)
                return nil
            } catch {
                return error
            }
        }
        #expect(decode { $0["version"] = 2 } == .unsupportedVersion(2))
        #expect(decode { $0["version"] = 0 } == .unsupportedVersion(0))
        #expect(decode { $0["latitude"] = 91.0 } == .invalid(field: "latitude"))
        #expect(decode { $0["covEE"] = -1.0 } == .invalid(field: "covEE"))
        #expect(decode { $0["covEN"] = 100.0 } == .invalid(field: "covEN"))
        #expect(decode { $0["headingDeg"] = 360.0 } == .invalid(field: "headingDeg"))
        #expect(decode { $0["speedMps"] = -0.1 } == .invalid(field: "speedMps"))
        #expect(decode { $0["class"] = "towed" } != nil)
        #expect(decode { $0.removeValue(forKey: "latitude") } != nil)
        #expect(throws: NavigationRestoreState.DecodeError.self) { try NavigationRestoreState.decode(Data("{\"vers".utf8)) }
        #expect(throws: NavigationRestoreState.DecodeError.self) {
            try NavigationRestoreState.decode(Data("{\"version\":1,\"latitude\":1e999}".utf8))
        }
    }

    @Test func ageWindow() {
        let state = Self.state()
        let saved = Date(timeIntervalSince1970: 1_000_000_000)
        #expect(state.age(nowWall: saved.addingTimeInterval(600), nowUptimeSeconds: 5600, bootSessionID: "boot-a") == 600)
        // Saved 5 min in the future (clock set back, other boot): refused.
        #expect(state.age(nowWall: saved.addingTimeInterval(-300), nowUptimeSeconds: 100, bootSessionID: "boot-b") == nil)
        // The same boot: uptime bounds the age from below.
        #expect(state.age(nowWall: saved.addingTimeInterval(-300), nowUptimeSeconds: 5900, bootSessionID: "boot-a") == 900)
        #expect(state.age(nowWall: saved.addingTimeInterval(60), nowUptimeSeconds: 5900, bootSessionID: "boot-a") == 900)
        // Another boot: the wall clock only.
        #expect(state.age(nowWall: saved.addingTimeInterval(60), nowUptimeSeconds: 99_000, bootSessionID: "boot-b") == 60)
        #expect(state.age(nowWall: saved.addingTimeInterval(60), nowUptimeSeconds: 99_000, bootSessionID: nil) == 60)
        // Over 24 h: refused; just under: kept.
        #expect(state.age(nowWall: saved.addingTimeInterval(25 * 3600), nowUptimeSeconds: 0, bootSessionID: nil) == nil)
        #expect(state.age(nowWall: saved.addingTimeInterval(24 * 3600 + 1), nowUptimeSeconds: 0, bootSessionID: nil) == nil)
        #expect(state.age(nowWall: saved.addingTimeInterval(24 * 3600 - 1), nowUptimeSeconds: 0, bootSessionID: nil) != nil)
        // Up to 5 s in the future (clock skew): age 0; beyond: refused.
        #expect(state.age(nowWall: saved.addingTimeInterval(-3), nowUptimeSeconds: 0, bootSessionID: nil) == 0)
        #expect(state.age(nowWall: saved.addingTimeInterval(-5), nowUptimeSeconds: 0, bootSessionID: nil) == 0)
        #expect(state.age(nowWall: saved.addingTimeInterval(-5.001), nowUptimeSeconds: 0, bootSessionID: nil) == nil)
        #expect(state.age(nowWall: saved.addingTimeInterval(-6), nowUptimeSeconds: 0, bootSessionID: nil) == nil)
        #expect(state.age(nowWall: saved.addingTimeInterval(-0.001), nowUptimeSeconds: 0, bootSessionID: "boot-b") == 0)
        // The same boot: uptime 3 s behind and wall 3 s behind is skew too.
        #expect(state.age(nowWall: saved.addingTimeInterval(-3), nowUptimeSeconds: 4997, bootSessionID: "boot-a") == 0)
        #expect(state.age(nowWall: saved.addingTimeInterval(-6), nowUptimeSeconds: 4994, bootSessionID: "boot-a") == nil)
        // A prior from a state 3 s in the future is saved at the run's start.
        let skewed = SessionClock(referenceUptimeSeconds: 0, wallClockStart: saved.addingTimeInterval(-3))
        #expect(state.prior(at: S.ms(1), clock: skewed, bootSessionID: nil)?.savedT == S.ms(1))
        let tooSkewed = SessionClock(referenceUptimeSeconds: 0, wallClockStart: saved.addingTimeInterval(-7))
        #expect(state.prior(at: S.ms(1), clock: tooSkewed, bootSessionID: nil) == nil)
    }

    @Test func priorFromStateIsOnTheNewClock() throws {
        let state = Self.state()
        // The new session starts 10 min after the save.
        let clock = SessionClock(referenceUptimeSeconds: 5600, wallClockStart: Date(timeIntervalSince1970: 1_000_000_600))
        let prior = try #require(state.prior(at: S.ms(2), clock: clock, bootSessionID: "boot-a"))
        #expect(prior.savedT == S.ms(-600))
        #expect(prior.restoreClass == .parked)
        #expect(prior.covEN == 4)
        let late = SessionClock(referenceUptimeSeconds: 0, wallClockStart: Date(timeIntervalSince1970: 1_000_000_000 + 90_000))
        #expect(state.prior(at: .zero, clock: late, bootSessionID: nil) == nil)
    }

    @Test func captureFromALiveRun() throws {
        let drive = S(initialHeadingDeg: 60, [
            .ramp(seconds: 4, from: 0, to: 12), .straight(seconds: 40, speed: 12), .ramp(seconds: 4, from: 12, to: 0),
            .stop(seconds: 6),
        ])
        var run = LiveNavigationRun(sessionID: UUID(), config: S.config(particles: 300), appBuild: "test")
        for input in S.inputs(drive.events(gyroNoise: 0.001, fix: S.cleanFix())) { run.ingest(input) { _ in } }
        let t = S.ms(drive.duration)
        let state = try #require(run.restoreState(at: t, clock: Self.clock, bootSessionID: "boot-a", engineOff: false))
        let estimate = try #require(run.engine.estimate(at: t))
        #expect(state.restoreClass == .standingStop)
        #expect(state.latitude == estimate.latitude && state.longitude == estimate.longitude)
        #expect(state.savedAt == Self.clock.wallClock(for: t))
        #expect(state.uptimeSeconds == 5000 + t.seconds)
        #expect(state.converged)
        #expect(state.lastOBDSpeedKmh == 0)
        #expect(try #require(state.lastOBDAgeS) < 0.2)
        // The ellipse of the saved covariance is the estimate's.
        let ellipse = ErrorEllipse(covarianceEE: state.covEE, en: state.covEN, nn: state.covNN)
        #expect(abs(ellipse.semiMajorM - estimate.ellipse.semiMajorM) < 1e-6)
        #expect(abs(ellipse.semiMinorM - estimate.ellipse.semiMinorM) < 1e-6)

        // Restored 20 min later in a new run: unconfirmed, the age shown.
        let next = SessionClock(referenceUptimeSeconds: 5000 + t.seconds + 1200,
                                wallClockStart: Self.clock.wallClock(for: t).addingTimeInterval(1200))
        let prior = try #require(state.prior(at: .zero, clock: next, bootSessionID: "boot-a"))
        var restored = LiveNavigationRun(sessionID: UUID(), config: S.config(particles: 300), appBuild: "test",
                                         prior: prior)
        var lines: [NavSidecar.Line] = []
        let parked = S(initialHeadingDeg: 60, [.stop(seconds: 3)])
        for input in S.inputs(parked.events()) { restored.ingest(input) { lines.append($0) } }
        let snapshot = restored.snapshot(at: S.ms(3), droppedInputs: 0)
        #expect(snapshot.restore.status == .unconfirmed)
        #expect(abs(try #require(snapshot.restore.ageS(at: S.ms(3))) - 1203) < 1e-6)
        #expect(snapshot.converged)
        #expect(lines.contains { if case .estimate = $0 { true } else { false } }, "estimates from the first second")
    }

    // MARK: Record → Navigate hand-over

    /// `input` on a session clock that started `offset` seconds later.
    static func shifted(_ input: NavigationInput, by offset: Double) -> NavigationInput {
        let d = MonotonicTimestamp(seconds: offset).nanoseconds
        func m(_ t: MonotonicTimestamp) -> MonotonicTimestamp { MonotonicTimestamp(nanoseconds: t.nanoseconds - d) }
        switch input {
        case .motion(let s, let t): return .motion(s, at: m(t))
        case .obd(let s, let t): return .obd(s, at: m(t))
        case .location(var s, let t):
            s.receivedT = s.receivedT.map(m)
            return .location(s, at: m(t))
        case .manualFix(var s, let t):
            s.pressedT = m(s.pressedT)
            return .manualFix(s, at: m(t))
        case .gpsSwitch(let s, let t): return .gpsSwitch(s, at: m(t))
        }
    }

    @Test(arguments: [0.3, 1.0, 2.0])
    func recordStopHandOverIsContinuous(gapS: Double) throws {
        // Record's run converges on clean fixes; at Stop (60 s, moving) it
        // saves with the app's function; Navigate starts `gapS` later on
        // its own session clock and boot, seeded through the normal path.
        let drive = S(initialHeadingDeg: 70, [
            .ramp(seconds: 5, from: 0, to: 14), .straight(seconds: 20, speed: 14),
            .turn(degrees: 60, seconds: 8, speed: 12), .straight(seconds: 50, speed: 14),
        ])
        let all = S.inputs(drive.events(gyroNoise: 0.001, fix: S.cleanFix(accuracy: 5, positionNoise: 2)))
        let stopT = 60.0, startT = stopT + gapS
        let config = S.config(particles: 400)
        var record = LiveNavigationRun(sessionID: UUID(), config: config, appBuild: "test")
        var uncut = record
        for input in all where input.arrival <= S.ms(stopT) {
            record.ingest(input) { _ in }
        }
        let saved = try #require(record.engine.estimate(at: S.ms(stopT)))
        #expect(saved.converged)
        let state = try #require(record.restoreState(at: S.ms(stopT), clock: Self.clock, bootSessionID: "boot-a",
                                                     engineOff: false))
        #expect(state.restoreClass == .moving)

        let navigateClock = SessionClock(referenceUptimeSeconds: Self.clock.referenceUptimeSeconds + startT,
                                         wallClockStart: Self.clock.wallClock(for: S.ms(startT)))
        let prior = try #require(state.prior(at: .zero, clock: navigateClock, bootSessionID: "boot-a"))
        #expect(prior.converged)
        #expect(abs(prior.savedT.seconds + gapS) < 1e-6)
        var navigate = LiveNavigationRun(sessionID: UUID(), config: config, appBuild: "test", prior: prior)
        let later = all.filter { $0.arrival > S.ms(startT) }.map { Self.shifted($0, by: startT) }
        // The first input: motion, before the first fix after the gap.
        let firstFix = try #require(later.firstIndex { if case .location = $0 { true } else { false } })
        for input in later[..<firstFix] { navigate.ingest(input) { _ in } }
        let tFirst = later[firstFix].arrival
        let restored = try #require(navigate.engine.estimate(at: tFirst))
        #expect(navigate.engine.restore.status == .unconfirmed)
        let turn = NavigationRestoreModel.movingHeadingRateDegPerS * gapS
        let grown = (saved.headingStdDeg * saved.headingStdDeg + turn * turn).squareRoot()
        // Continuous: the grown σ exactly at the seed, plus the heading
        // noise of the step or two run before the first fix.
        #expect(restored.headingStdDeg >= grown - 1e-6 && restored.headingStdDeg < grown + 0.2,
                "\(restored.headingStdDeg) vs \(grown)")
        // `converged` follows the grown σ: kept while it stays under 10°
        // (about 1.5–1.8 s of gap from a converged 2–5°), not by chance.
        #expect(restored.converged == (restored.headingStdDeg < config.convergedHeadingStdDeg))
        if gapS <= 1 { #expect(restored.converged, "converged carries over") }
        // Against the run Record would have continued: same place, same heading.
        for input in all where input.arrival < MonotonicTimestamp(seconds: tFirst.seconds + startT) {
            uncut.ingest(input) { _ in }
        }
        let reference = try #require(uncut.engine.estimate(at: MonotonicTimestamp(seconds: tFirst.seconds + startT)))
        let a = S.plane.enu(latitude: restored.latitude, longitude: restored.longitude)
        let b = S.plane.enu(latitude: reference.latitude, longitude: reference.longitude)
        #expect(((a.east - b.east) * (a.east - b.east) + (a.north - b.north) * (a.north - b.north)).squareRoot() < 10)
        #expect(abs(angleDifference(restored.headingDeg, reference.headingDeg)) < 2)

        // The next fix agrees: confirmed, no reseed, still converged.
        navigate.ingest(later[firstFix]) { _ in }
        #expect(navigate.engine.restore.status == .confirmed)
        #expect(navigate.engine.counters.reseeds == 0)
        for input in later[(firstFix + 1)...] { navigate.ingest(input) { _ in } }
        #expect(navigate.engine.counters.reseeds == 0)
        let end = try #require(navigate.engine.estimate(at: later.last!.arrival))
        #expect(end.converged)
        #expect(drive.error(end, at: later.last!.arrival.seconds + startT) < 15)
    }

    @Test func ellipseCovarianceRoundTrips() {
        for (ee, en, nn) in [(100.0, 0.0, 25.0), (30, 12, 20), (400, -150, 90), (50, 0, 50)] {
            let c = ErrorEllipse(covarianceEE: ee, en: en, nn: nn).covariance
            #expect(abs(c.ee - ee) < 1e-9 * max(1, ee))
            #expect(abs(c.en - en) < 1e-9 * max(1, ee))
            #expect(abs(c.nn - nn) < 1e-9 * max(1, nn))
        }
    }
}
