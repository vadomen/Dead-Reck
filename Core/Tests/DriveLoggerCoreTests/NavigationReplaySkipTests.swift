import Foundation
import Testing

@testable import DriveLoggerCore

/// R14.2-3: the replay does not schedule, sample or score up to an input the
/// engine rejects as an implausible forward time jump, so one corrupt huge
/// `t` cannot make `replay_nav` run `estimate()` once a second up to it.
@Suite("Navigation replay skips rejected inputs")
struct NavigationReplaySkipTests {
    typealias S = SyntheticDrive

    static let drive = S(initialHeadingDeg: 30, initialSpeed: 10, [.straight(seconds: 40, speed: 10), .stop(seconds: 5)])

    static func motion(_ t: Double) -> LogEvent {
        .motion(MotionSample(userAcceleration: Vector3(x: 0, y: 0, z: 0), gravity: Vector3(x: 0, y: 0, z: -1),
                             rotationRate: Vector3(x: 0, y: 0, z: 0), attitude: .identity), at: S.ms(t))
    }

    static func cleanFix(_ t: Double) -> LogEvent {
        let p = S.plane.geodetic(east: 0, north: 0)
        return .location(LocationSample(latitude: p.latitude, longitude: p.longitude, altitude: 0,
                                        horizontalAccuracy: 5, verticalAccuracy: -1, speed: 10, speedAccuracy: 0.3,
                                        course: 30, courseAccuracy: 2, receivedT: S.ms(t + 0.05), ageS: 0.05),
                         at: S.ms(t))
    }

    static func pin(_ t: Double) -> LogEvent {
        LogEvent(timestamp: S.ms(t), payload: .manualFix(ManualFixSample(
            latitude: 0, longitude: 0, pressedT: S.ms(t), mapSpanM: 200, speedSource: "obd")))
    }

    static func replay(_ events: [LogEvent], gps: GPSMode = .use, maxJumpS: Double = 3_600,
                       truth: TruthFile.Entry? = nil) -> ReplayResult {
        var config = S.config(particles: 100)
        config.maxForwardJumpS = maxJumpS
        return NavigationReplay.run(logName: "a", inputs: NavigationReplay.inputs(from: events),
                                    options: ReplayOptions(gps: gps, config: config), truth: truth)
    }

    static var truth: TruthFile.Entry {
        let end = drive.truth(at: drive.duration)
        let e = S.plane.geodetic(east: end.east, north: end.north)
        return TruthFile.Entry(end: TruthFile.Position(latitude: e.latitude, longitude: e.longitude, sigmaM: 10))
    }

    /// Everything the run produced except timing.
    static func output(_ r: ReplayResult) -> String {
        var r = r
        r.msPerStep = 0
        r.maxIngestMs = 0
        return "\(r)"
    }

    @Test("A motion row 2 h ahead (limit 1 h): no track, ellipse or checkpoint beyond the drive, the end stays the drive's end")
    func jumpedMotionRowIsOffTheTimeline() throws {
        let events = Self.drive.events(fix: { t, state, rng in t <= 20 ? S.cleanFix()(t, state, &rng) : nil })
        let clean = Self.replay(events, truth: Self.truth)
        let jumped = Self.replay(events + [Self.motion(Self.drive.duration + 7_200)], truth: Self.truth)
        #expect(jumped.counters.inputsRejectedTimeJump == 1)
        // Before R14.2-3 the track ran on, one point a second, for 2 h.
        #expect(jumped.track.count == clean.track.count)
        #expect(jumped.track.last?.t == clean.track.last?.t)
        #expect(jumped.endT == clean.endT)
        // Everything else is the clean run's, bit for bit.
        var withoutCounter = jumped
        withoutCounter.counters.inputsRejectedTimeJump = 0
        #expect(Self.output(withoutCounter) == Self.output(clean))
    }

    @Test("A motion row at t = 1e9 s returns quickly and adds nothing to the result")
    func hugeTimestamp() throws {
        let events = Self.drive.events(fix: { t, state, rng in t <= 20 ? S.cleanFix()(t, state, &rng) : nil })
        let clock = ContinuousClock()
        var result: ReplayResult?
        let elapsed = clock.measure { result = Self.replay(events + [Self.motion(1e9)]) }
        // Before R14.2-3: ~1e9 estimates, effectively a hang.
        #expect(elapsed < .seconds(30))
        let r = try #require(result)
        #expect(r.counters.inputsRejectedTimeJump == 1)
        #expect(r.track.last.map { $0.t <= Self.drive.duration + 1 } == true)
        #expect(r.endT <= Self.drive.duration + 1)
    }

    @Test("A withheld clean fix and a pin with a jumped t are not scored; a later real resume is")
    func jumpedCheckpointsAreNotScored() throws {
        let events = Self.drive.events(fix: { t, state, rng in t <= 20 ? S.cleanFix()(t, state, &rng) : nil })
        let late = Self.drive.duration + 7_200
        let jumped = Self.replay(events + [Self.cleanFix(late), Self.pin(late + 20)], gps: .maskAfter(seconds: 20))
        // The fix is withheld (masked), so the engine never sees it; the pin
        // is rejected by the engine. Neither is a checkpoint with an error.
        #expect(jumped.checkpoints.allSatisfy { $0.t < late })
        #expect(jumped.pins.allSatisfy { $0.pin.t.seconds < late })
        #expect(jumped.fixes.allSatisfy { $0.t < late })
        #expect(jumped.counters.inputsRejectedTimeJump == 1)
        #expect(jumped.endT <= Self.drive.duration + 1)

        // Two inputs within `forwardJumpConfirmS` of each other are a real
        // resume: the second is accepted and the timeline continues there.
        let resumed = Self.replay(events + [Self.motion(late), Self.motion(late + 1)])
        #expect(resumed.counters.inputsRejectedTimeJump == 1)
        #expect(resumed.endT == late + 1)
    }
}
