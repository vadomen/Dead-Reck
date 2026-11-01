import Foundation
import Testing

@testable import DriveLoggerCore

/// Prompt 47 (UX-7), Core part: the no-OBD Navigate run's config
/// (`NavigationConfig.noOBDLive(seed:)`), the "position uncertain" signal
/// (`LiveNavigationRun.lastFixOrPinT`, `positionUncertain(at:)`, 120 s) and
/// the seeded restart prior when an adapter connects
/// (`NavigationPrior.noOBDRestart`). Synthetic drives from (0, 0) and
/// synthetic clocks only; no real place, date or recording.
@Suite("Navigation prompt 47: no-OBD Navigate run (config, uncertain signal, restart prior)")
struct NavigationNoOBDLiveTests {
    typealias S = SyntheticDrive

    // MARK: Fixtures

    /// A location fix at `t` (east/north metres from (0, 0)), arriving
    /// `latency` later. No speed or course: a network fix, unless `speed`.
    static func fix(at t: Double, east: Double = 0, north: Double = 0, accuracy: Double = 100,
                    latency: Double = 0.05, speed: Double = -1, course: Double = -1) -> LogEvent {
        let p = S.plane.geodetic(east: east, north: north)
        return .location(LocationSample(
            latitude: p.latitude, longitude: p.longitude, altitude: 0, horizontalAccuracy: accuracy,
            verticalAccuracy: -1, speed: speed, speedAccuracy: speed >= 0 ? 0.3 : -1, course: course,
            courseAccuracy: course >= 0 ? 2 : -1, receivedT: S.ms(t + latency), ageS: latency
        ), at: S.ms(t))
    }

    static func pin(at t: Double, east: Double = 0, north: Double = 0) -> LogEvent {
        let p = S.plane.geodetic(east: east, north: north)
        return LogEvent(timestamp: S.ms(t), payload: .manualFix(ManualFixSample(
            latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(t), speedSource: "none")))
    }

    static func gpsSwitch(on: Bool, at t: Double) -> LogEvent {
        LogEvent(timestamp: S.ms(t), payload: .gpsSwitch(GPSSwitchSample(on: on, source: .driver)))
    }

    /// The no-OBD live config with fewer particles (debug test speed).
    static func noOBDConfig(seed: UInt64 = 3) -> NavigationConfig {
        var config = NavigationConfig.noOBDLive(seed: seed)
        config.particleCount = 300
        return config
    }

    /// A parked car with no OBD reply at all for `seconds`, 100 Hz motion,
    /// plus `extra` events.
    static func parkedNoOBD(seconds: Double, extra: [LogEvent]) -> [NavigationInput] {
        S.inputs(S([.stop(seconds: seconds)]).events(obdSpeed: { _, _ in nil }, extra: extra))
    }

    struct Probe: Equatable {
        var uncertain: Bool
        var snapshotUncertain: Bool
        var last: MonotonicTimestamp?
    }

    /// Feeds `inputs` to `run`; at each of `times` (session seconds, sorted)
    /// records the signal from the state after every input arriving at or
    /// before it.
    static func probe(_ run: inout LiveNavigationRun, _ inputs: [NavigationInput], at times: [Double]) -> [Probe] {
        var out: [Probe] = []
        var pending = times[...]
        func record(_ t: Double) {
            out.append(Probe(uncertain: run.positionUncertain(at: S.ms(t)),
                             snapshotUncertain: run.snapshot(at: S.ms(t), droppedInputs: 0).positionUncertain,
                             last: run.lastFixOrPinT))
        }
        for input in inputs {
            while let t = pending.first, S.ms(t) < input.arrival {
                record(t)
                pending = pending.dropFirst()
            }
            run.ingest(input) { _ in }
        }
        for t in pending { record(t) }
        return out
    }

    // MARK: Config

    @Test("noOBDLive: the default config with the seed, noOBDFixSpeedMean 1 with prompt 46's sub-key defaults, noOBDRobustNetworkFix 0; valid as is; the defaults and the OBD run's header config are untouched")
    func noOBDLiveConfig() throws {
        let config = NavigationConfig.noOBDLive(seed: 42)
        let base = NavigationConfig(seed: 42)
        #expect(config.differingKeys(base) == ["noOBDFixSpeedMean"])
        #expect(config.seed == 42 && config.noOBDFixSpeedMean == 1 && config.noOBDRobustNetworkFix == 0)
        // Prompt 46's rule (iv) defaults.
        #expect(config.noOBDFixSpeedDecayS == 500 && config.noOBDFixSpeedFloorKmh == 0 && config.noOBDFixSpeedGate == 2)
        #expect(config.noOBDFixSpeedWindowS == 120 && config.noOBDFixSpeedHoldS == 30 && config.noOBDFixSpeedGateK == 2.15)
        #expect(config.validated() == config)
        // The defaults: both switches off.
        #expect(NavigationConfig().noOBDFixSpeedMean == 0 && NavigationConfig().noOBDRobustNetworkFix == 0)

        let header = WriterFixtures.header
        let seed = NavigationSeed.derive(header: header)
        let obd = LiveNavigationRun(header: header, appBuild: "t")
        #expect(obd.engine.config == NavigationConfig(seed: seed) && obd.header.configHash == NavigationConfig(seed: seed).hashHex)
        #expect(!obd.engine.noOBDFixSpeedMeanActive && !obd.engine.noOBDRobustNetworkFixActive)
        let noOBD = LiveNavigationRun(header: header, appBuild: "t", noOBD: true)
        #expect(noOBD.engine.config == NavigationConfig.noOBDLive(seed: seed))
        #expect(noOBD.header.configJSON == String(decoding: NavigationConfig.noOBDLive(seed: seed).canonicalJSON(), as: UTF8.self))
        #expect(noOBD.engine.noOBDFixSpeedMeanActive && !noOBD.engine.noOBDRobustNetworkFixActive)
    }

    // MARK: Uncertain signal

    @Test("Uncertain: false before any input; the clock starts at the run's first input; flips at exactly 120 s without an accepted fix; cleared by the next accepted network fix and by a pin; the snapshot agrees")
    func uncertainFlipsAndClears() throws {
        var run = LiveNavigationRun(sessionID: UUID(), config: Self.noOBDConfig(), appBuild: "t")
        #expect(run.lastFixOrPinT == nil && !run.positionUncertain(at: S.ms(500)))
        #expect(!run.snapshot(at: S.ms(500), droppedInputs: 0).positionUncertain)
        let extra = [Self.fix(at: 2), Self.fix(at: 4, east: 20), Self.fix(at: 6, north: 15),
                     Self.fix(at: 200, east: 10), Self.pin(at: 380, east: 5)]
        let inputs = Self.parkedNoOBD(seconds: 510, extra: extra)
        let times = [1, 3, 6, 7, 126.04, 126.05, 199, 200.04, 200.1, 320.04, 320.05, 379.99, 380, 499.99, 500]
        let p = Self.probe(&run, inputs, at: times)
        func at(_ t: Double) -> Probe { p[times.firstIndex(of: t)!] }

        #expect(at(1).last == S.ms(0) && !at(1).uncertain, "the run's first input (motion at 0) starts the clock")
        #expect(at(3).last == S.ms(2.05), "a network fix's arrival")
        #expect(at(6).last == S.ms(4.05), "the fix at 6 s has not arrived yet")
        #expect(at(7).last == S.ms(6.05))
        #expect(!at(126.04).uncertain)
        #expect(at(126.05).uncertain, "120 s after the last accepted fix")
        #expect(at(199).uncertain && at(200.04).uncertain)
        #expect(!at(200.1).uncertain && at(200.1).last == S.ms(200.05), "cleared by the next accepted fix")
        #expect(!at(320.04).uncertain && at(320.05).uncertain)
        #expect(at(379.99).uncertain)
        #expect(!at(380).uncertain && at(380).last == S.ms(380), "cleared by a pin")
        #expect(!at(499.99).uncertain && at(500).uncertain)
        #expect(p.allSatisfy { $0.snapshotUncertain == $0.uncertain })
        #expect(run.engine.counters.fixesUsed == 4 && run.engine.counters.manualFixes == 1)
        #expect(!run.engine.obdEverIngested)
        #expect(run.secondsSinceFixOrPin(at: S.ms(390)) == 10)
        #expect(!run.positionUncertain(at: S.ms(390), afterS: 11) && run.positionUncertain(at: S.ms(390), afterS: 10))
    }

    @Test("Uncertain: a fix the engine does not accept leaves it set (invalid accuracy, stale and held then dropped, withheld by the GPS switch, a time jump); the next accepted fix clears it")
    func rejectedFixesDoNotClear() throws {
        var run = LiveNavigationRun(sessionID: UUID(), config: Self.noOBDConfig(), appBuild: "t")
        let extra = [
            Self.fix(at: 2), Self.fix(at: 4, east: 20),
            Self.fix(at: 140, accuracy: -1),                          // invalid
            Self.fix(at: 150, latency: 15),                           // stale: held (no OBD to decide), dropped
            Self.gpsSwitch(on: false, at: 170),
            Self.fix(at: 175, accuracy: 5, speed: 0, course: -1),     // GNSS, withheld by the switch
            Self.gpsSwitch(on: true, at: 180),
            Self.fix(at: 186, latency: 3_700),                        // arrives > maxForwardJumpS ahead: rejected
            Self.fix(at: 200, east: 10),                              // accepted
        ]
        let inputs = Self.parkedNoOBD(seconds: 210, extra: extra)
        let times = [130.0, 199.0, 200.1]
        let p = Self.probe(&run, inputs, at: times)
        #expect(p[0].uncertain && p[0].last == S.ms(4.05))
        #expect(p[1].uncertain && p[1].last == S.ms(4.05), "none of the rejected fixes moved the clock")
        let c = run.engine.counters
        #expect(c.fixesIgnoredInvalid == 1)
        #expect(c.fixesHeld == 1 && c.heldFixesDroppedTimeout == 1)
        #expect(run.engine.fixesWithheldByGPSSwitch == 1)
        #expect(c.inputsRejectedTimeJump == 1)
        #expect(!p[2].uncertain && p[2].last == S.ms(200.05), "the accepted fix clears it")
        #expect(c.fixesUsed == 3)
    }

    @Test("Uncertain: reading the signal changes nothing: a run queried after every input gives the same lines and estimates as one never queried")
    func signalChangesNoOutput() throws {
        let extra = [Self.fix(at: 2), Self.fix(at: 30, east: 5), Self.pin(at: 40, east: 3)]
        let inputs = Self.parkedNoOBD(seconds: 60, extra: extra)
        var a = LiveNavigationRun(sessionID: UUID(uuid: (1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
                                  config: Self.noOBDConfig(), appBuild: "t")
        var b = a
        var linesA: [NavSidecar.Line] = [], linesB: [NavSidecar.Line] = []
        for input in inputs {
            a.ingest(input) { linesA.append($0) }
            _ = a.positionUncertain(at: input.arrival)
            b.ingest(input) { linesB.append($0) }
        }
        func strip(_ lines: [NavSidecar.Line]) -> [NavSidecar.Line] {
            lines.map {
                switch $0 {
                case .estimate(var e):
                    e.msPerStep = nil
                    e.maxStepMs = nil
                    return .estimate(e)
                case .pin(var p):
                    p.prior?.msPerStep = nil
                    p.prior?.maxStepMs = nil
                    return .pin(p)
                default: return $0
                }
            }
        }
        #expect(strip(linesA) == strip(linesB) && !linesA.isEmpty)
        #expect(a.engine.estimate(at: S.ms(60)) == b.engine.estimate(at: S.ms(60)))
    }

    // MARK: Restart prior

    /// 50 km/h due north from (0, 0), already moving.
    static let speed = 50 / 3.6
    static let drive = S(initialHeadingDeg: 0, initialSpeed: speed, [.straight(seconds: 200, speed: speed)])
    /// The adapter reaches `polling`, on the no-OBD run's clock.
    static let switchT = 90.0
    static let noOBDClock = SessionClock(referenceUptimeSeconds: 5_000, wallClockStart: Date(timeIntervalSince1970: 2_000_000_000))
    /// The OBD run's clock starts at the switch.
    static let obdClock = SessionClock(referenceUptimeSeconds: 5_000 + switchT,
                                       wallClockStart: Date(timeIntervalSince1970: 2_000_000_000 + switchT))

    /// The drive with network fixes (accuracy 100 m, 30 m noise) every 5 s
    /// and no OBD before the switch; OBD and no fix (jammed) from it on.
    static let events = drive.events(gyroNoise: 0.001, obdSpeed: { t, state in
        t >= switchT ? (state.speed * 3.6).rounded(.down) : nil
    }, fix: { t, state, rng in
        guard t < switchT, Int(t.rounded()) % 5 == 0 else { return nil }
        return S.Fix(east: state.east + 30 * rng.nextGaussian(), north: state.north + 30 * rng.nextGaussian(),
                     accuracy: 100)
    })

    @Test("Restart prior: from the running no-OBD engine's capture, class .moving (no OBD ever), not a hand-over, position and covariance kept; the OBD run seeded from it starts where the no-OBD run was (carried v·gap), its ellipse grown only by the gap, unconfirmed")
    func restartPriorKeepsTheEstimate() throws {
        var noOBD = LiveNavigationRun(sessionID: UUID(), config: Self.noOBDConfig(), appBuild: "t")
        for input in S.inputs(Self.events) where input.arrival < S.ms(Self.switchT) { noOBD.ingest(input) { _ in } }
        #expect(!noOBD.engine.obdEverIngested && noOBD.engine.counters.networkFixesUsed > 10)
        let lastStep = try #require(noOBD.engine.lastStepTime)
        #expect(noOBD.engine.restoreClass(at: lastStep, engineOff: false) == .moving)
        let capture = try #require(noOBD.restoreState(clock: Self.noOBDClock, bootSessionID: "boot", engineOff: false))
        #expect(capture.restoreClass == .moving && capture.lastOBDSpeedKmh == nil)
        let estimate = try #require(noOBD.engine.estimate(at: lastStep))

        let prior = try #require(NavigationPrior.noOBDRestart(from: capture, at: .zero, clock: Self.obdClock,
                                                               bootSessionID: "boot"))
        #expect(prior.restoreClass == .moving && !prior.handOver)
        #expect(prior.latitude == capture.latitude && prior.longitude == capture.longitude)
        #expect(prior.covEE == capture.covEE && prior.covEN == capture.covEN && prior.covNN == capture.covNN)
        let gapS = -prior.savedT.seconds
        #expect(abs(gapS - (Self.switchT - lastStep.seconds)) < 1e-6 && gapS >= 0 && gapS <= 0.2, "gap \(gapS), last step \(lastStep.seconds)")
        // Same as the general restore path with handOver false.
        #expect(prior == capture.prior(at: .zero, clock: Self.obdClock, bootSessionID: "boot", handOver: false))

        // The OBD run (default config) on its own clock, from the switch on.
        var config = S.config(particles: 300, seed: 4)
        config.seed = 4
        var obd = LiveNavigationRun(sessionID: UUID(), config: config, appBuild: "t", prior: prior)
        let shift = S.ms(Self.switchT).nanoseconds
        let after = Self.events.compactMap { event -> LogEvent? in
            guard let input = NavigationInput(event), input.arrival >= S.ms(Self.switchT) else { return nil }
            return event.shifted(by: -shift)
        }
        let inputs = S.inputs(after)
        obd.ingest(inputs[0]) { _ in }
        let first = try #require(obd.engine.estimate(at: inputs[0].arrival))
        #expect(obd.engine.restore.status == .unconfirmed)

        // Where the no-OBD estimate is carried to by v·gap along its heading.
        let plane = LocalTangentPlane(latitude: estimate.latitude, longitude: estimate.longitude)
        let h = estimate.headingDeg * .pi / 180
        let carried = capture.speedMps * gapS
        let p = plane.enu(latitude: first.latitude, longitude: first.longitude)
        let jump = ((p.east - carried * sin(h)) * (p.east - carried * sin(h))
                    + (p.north - carried * cos(h)) * (p.north - carried * cos(h))).squareRoot()
        #expect(jump < 1, "no jump: \(jump) m from the carried no-OBD estimate")
        // The ellipse: kept, grown only by the gap (moving: + max(v, 11.1 m/s)·gap per axis, in quadrature).
        let growth = max(capture.speedMps, NavigationRestoreModel.movingMinSpeedMps) * gapS
        let grownMajor = (estimate.ellipse.semiMajorM * estimate.ellipse.semiMajorM
                          + ErrorEllipse.chiSquare95 * growth * growth).squareRoot()
        #expect(first.ellipse.semiMajorM >= estimate.ellipse.semiMajorM * 0.98, "\(first.ellipse.semiMajorM) vs \(estimate.ellipse.semiMajorM)")
        #expect(first.ellipse.semiMajorM <= grownMajor * 1.02 + 0.5, "\(first.ellipse.semiMajorM) vs grown \(grownMajor)")

        // Then the OBD run continues from there: OBD seen, the no-OBD mode off.
        for input in inputs.dropFirst() where input.arrival < S.ms(10) { obd.ingest(input) { _ in } }
        #expect(obd.engine.obdEverIngested)
        let later = try #require(obd.engine.estimate(at: S.ms(10)))
        let q = plane.enu(latitude: later.latitude, longitude: later.longitude)
        let moved = (q.east * q.east + q.north * q.north).squareRoot()
        #expect(abs(moved - Self.speed * (10 + gapS)) < 15, "drives on at OBD speed from the restart point: \(moved) m; heading \(estimate.headingDeg) ± \(estimate.headingStdDeg), later \(later.headingDeg) ± \(later.headingStdDeg)")
    }
}
