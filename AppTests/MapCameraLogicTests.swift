import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

private let base = ContinuousClock.now
private func t(_ seconds: Double) -> ContinuousClock.Instant { base + .seconds(seconds) }

@Suite("Map camera logic")
struct MapCameraLogicTests {
    @Test("Camera heading choice")
    func cameraHeading() {
        #expect(CameraHeading.choose(headingUp: true, bearing: 120, smoothed: nil) == 120)
        #expect(CameraHeading.choose(headingUp: true, bearing: 120, smoothed: 115) == 115)
        #expect(CameraHeading.choose(headingUp: false, bearing: 120, smoothed: 115) == 0)
        #expect(CameraHeading.choose(headingUp: true, bearing: nil, smoothed: nil) == 0)
        // A stale smoothed heading with no bearing must not rotate the map.
        #expect(CameraHeading.choose(headingUp: true, bearing: nil, smoothed: 200) == 0)
    }

    @Test("Activation reseeds a stale smoother to the bearing, frozen or not")
    func activation() {
        var smoother = HeadingSmoother()
        smoother.step(target: 0, frozen: false, dt: 0.1)   // stale: car was heading north
        var gate = HeadingWriteGate()
        _ = gate.admit(0, at: t(0))
        let h = CameraHeading.activate(smoother: &smoother, gate: &gate, bearing: 90)
        #expect(h == 90)
        // Frozen at a stop: holds 90, not the stale 0.
        let held = smoother.step(target: 90, frozen: true, dt: 0.1)
        #expect(held == 90)
        // The gate was reset: the first write is admitted.
        let first = gate.admit(90, at: t(0.01))
        #expect(first)
    }

    @Test("Activation with no bearing gives 0")
    func activationNoBearing() {
        var smoother = HeadingSmoother()
        smoother.step(target: 200, frozen: false, dt: 0.1)
        var gate = HeadingWriteGate()
        #expect(CameraHeading.activate(smoother: &smoother, gate: &gate, bearing: nil) == 0)
        #expect(smoother.heading == nil)
    }

    @Test("Write gate: more than 2 degrees and at least 0.25 s")
    func gate() {
        var g = HeadingWriteGate()
        let r619330 = g.admit(100, at: t(0))
        #expect(r619330)
        let r45242 = g.admit(110, at: t(0.2))
        #expect(!r45242)   // too soon
        let r675349 = g.admit(102, at: t(1))
        #expect(!r675349)     // exactly 2 degrees: not more
        let r970017 = g.admit(102.5, at: t(1))
        #expect(r970017)
        let r605918 = g.admit(102.6, at: t(2))
        #expect(!r605918)   // too small
        let r588851 = g.admit(110, at: t(1.25))
        #expect(r588851)   // exactly 0.25 s after the last write
    }

    @Test("Write gate: 359 to 1 is 2 degrees, not 358")
    func gateWrap() {
        var g = HeadingWriteGate()
        let r359945 = g.admit(359, at: t(0))
        #expect(r359945)
        let r850637 = g.admit(1, at: t(1))
        #expect(!r850637)
        let r6887 = g.admit(1.5, at: t(2))
        #expect(r6887)
        g.reset()
        let r922918 = g.admit(1.5, at: t(2.1))
        #expect(r922918)
    }

    @Test("Marginal distance changes are skipped")
    func significance() {
        #expect(MapChange.isSignificant(old: nil, new: 1000))
        #expect(!MapChange.isSignificant(old: 1000, new: 1005))
        #expect(MapChange.isSignificant(old: 1000, new: 1020))
    }

    @Test("Stopped only for a fresh 0")
    func stationaryRule() {
        #expect(StationaryRule.isStopped(kmh: 0, replyUptime: 100, now: 100))
        #expect(StationaryRule.isStopped(kmh: 0, replyUptime: 100, now: 102))
        #expect(!StationaryRule.isStopped(kmh: 0, replyUptime: 100, now: 102.5))
        #expect(!StationaryRule.isStopped(kmh: 5, replyUptime: 100, now: 100))
        #expect(!StationaryRule.isStopped(kmh: nil, replyUptime: nil, now: 100))
        #expect(!StationaryRule.isStopped(kmh: 0, replyUptime: nil, now: 100))
    }
}

@MainActor
private final class SpySource: MapBearingSource {
    var bearingDegrees: Double?
    var resets = 0
    func ingest(_ fix: LocationSample) { bearingDegrees = fix.course }
    func reset() { resets += 1; bearingDegrees = nil }
}

private func fix(course: Double = 90) -> LocationSample {
    LocationSample(
        latitude: 0, longitude: 0, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
        speed: 20, speedAccuracy: 1, course: course, courseAccuracy: 5,
        receivedT: MonotonicTimestamp(seconds: 0), ageS: 0
    )
}

/// Test-only counter; the observation callback runs synchronously on the main actor here.
final class Counter: @unchecked Sendable { var n = 0 }

@Suite("MapViewModel heading and stationary")
@MainActor
struct MapViewModelHeadingTests {
    @Test("Stationary: fresh 0 yes; stale 0, nil, moving no; flips only")
    func stationary() {
        let m = MapViewModel()
        m.setOBDSpeed(0, replyUptime: 10, now: 11)
        #expect(m.isStationary)
        m.setOBDSpeed(0, replyUptime: 10, now: 12.5)   // went stale, no new reading
        #expect(!m.isStationary)
        m.setOBDSpeed(0, replyUptime: 20, now: 20)
        #expect(m.isStationary)
        m.setOBDSpeed(nil, replyUptime: nil, now: 21)
        #expect(!m.isStationary)
        m.setOBDSpeed(7, replyUptime: 22, now: 22)
        #expect(!m.isStationary)
    }

    @Test("Stationary publishes only when it flips")
    func flipOnly() {
        let m = MapViewModel()
        let changes = Counter()
        func arm() {
            withObservationTracking { _ = m.isStationary } onChange: { changes.n += 1 }
        }
        arm()
        m.setOBDSpeed(5, replyUptime: 1, now: 1)
        m.setOBDSpeed(nil, replyUptime: nil, now: 1)
        #expect(changes.n == 0)
        m.setOBDSpeed(0, replyUptime: 1, now: 1)
        #expect(changes.n == 1)
    }

    @Test("Stationary is assigned only when it flips (the guard, not @Observable's dedup)")
    func flipOnlyGuard() {
        let m = MapViewModel()
        m.setOBDSpeed(5, replyUptime: 1, now: 1)
        m.setOBDSpeed(nil, replyUptime: nil, now: 1)
        #expect(m.stationaryWrites == 0)
        m.setOBDSpeed(0, replyUptime: 1, now: 1)
        m.setOBDSpeed(0, replyUptime: 2, now: 2)
        m.setOBDSpeed(0, replyUptime: 3, now: 3)
        #expect(m.stationaryWrites == 1)
        m.setOBDSpeed(4, replyUptime: 4, now: 4)
        #expect(m.stationaryWrites == 2)
    }

    @Test("Resume loop: sleeps to the deadline, resumes once, and stops")
    @MainActor
    func resumeLoop() async {
        var clock = base
        var follow = FollowController()
        follow.userGesture(at: clock)
        var sleeps: [ContinuousClock.Instant] = []
        await FollowResumeLoop.run(
            deadline: { follow.resumeDeadline },
            now: { clock },
            sleep: { target in sleeps.append(target); clock = target },
            resumeIfDue: { follow.tick(now: clock) }
        )
        #expect(follow.isFollowing)
        #expect(sleeps == [base + FollowController.resumeDelay])
    }

    @Test("Resume loop: a deadline pushed while asleep sleeps again before resuming")
    @MainActor
    func resumeLoopPushed() async {
        var clock = base
        var follow = FollowController()
        follow.userGesture(at: clock)
        var sleeps = 0
        await FollowResumeLoop.run(
            deadline: { follow.resumeDeadline },
            now: { clock },
            sleep: { target in
                sleeps += 1
                if sleeps == 1 {
                    // The driver touches the map just before the deadline.
                    clock = target - .seconds(1)
                    follow.cameraSettled(at: clock)
                    clock = target
                } else {
                    clock = target
                }
            },
            resumeIfDue: { follow.tick(now: clock) }
        )
        #expect(sleeps == 2)
        #expect(follow.isFollowing)
    }

    @Test("Resume loop: a deadline already past resumes without sleeping; no deadline ends it")
    @MainActor
    func resumeLoopDue() async {
        var follow = FollowController()
        follow.userGesture(at: base)
        var slept = false
        await FollowResumeLoop.run(
            deadline: { follow.resumeDeadline },
            now: { base + .seconds(60) },
            sleep: { _ in slept = true },
            resumeIfDue: { follow.tick(now: base + .seconds(60)) }
        )
        #expect(follow.isFollowing && !slept)
        var off = FollowController(following: false)
        off.followTapped(at: base)
        off.followTapped(at: base)   // manual off again: no deadline
        await FollowResumeLoop.run(
            deadline: { off.resumeDeadline }, now: { base },
            sleep: { _ in slept = true }, resumeIfDue: { Issue.record("must not run"); return false }
        )
    }

    @Test("A new recording clears smoother, gate and pending publish")
    func resetNewRecording() {
        var smoother = HeadingSmoother()
        smoother.step(target: 200, frozen: false, dt: 0.1)
        var gate = HeadingWriteGate()
        _ = gate.admit(200, at: t(0))
        var pending = true
        HeadingReset.newRecording(smoother: &smoother, gate: &gate, publishPending: &pending)
        #expect(smoother.heading == nil)
        #expect(!pending)
        let admitted = gate.admit(200, at: t(0.01))
        #expect(admitted, "the gate was reset: the first write is admitted")
    }

    @Test("Losing the bearing drops the smoothed heading only when nothing else supplies one")
    func resetNoBearing() {
        var smoother = HeadingSmoother()
        smoother.step(target: 200, frozen: false, dt: 0.1)
        HeadingReset.bearingChanged(to: 90, effectiveBearing: 90, smoother: &smoother)
        #expect(smoother.heading == 200)
        HeadingReset.bearingChanged(to: nil, effectiveBearing: 150, smoother: &smoother)
        #expect(smoother.heading == 200, "another source still gives a bearing")
        HeadingReset.bearingChanged(to: nil, effectiveBearing: nil, smoother: &smoother)
        #expect(smoother.heading == nil)
    }

    @Test("A new recording file resets the bearing source and heading falls back to 0")
    func newFile() {
        let spy = SpySource()
        let m = MapViewModel(bearingSource: spy)
        let a = URL(fileURLWithPath: "/tmp/a")
        let b = URL(fileURLWithPath: "/tmp/b")
        m.ingest(fix(course: 200), file: a, isActive: true)
        #expect(m.bearing == 200)
        let resetsBefore = spy.resets
        m.ingest(nil, file: b, isActive: true)
        #expect(spy.resets == resetsBefore + 1)
        #expect(m.bearing == nil)
        #expect(CameraHeading.choose(headingUp: true, bearing: m.bearing, smoothed: 200) == 0)
    }
}

/// Drives `FollowCameraTick` at the loop's real 100 ms tick with a synthetic
/// clock; `published` fires at the feed's 4 Hz and the DR heading keeps
/// turning, so every writer of the combined rate is active.
@Suite("Follow camera write rate")
struct FollowCameraRateTests {
    struct Result {
        var writes: [Double] = []   // seconds
        var lastDistance = 0.0
        var zoom = FollowZoom()
        var maxPerSecond: Int {
            writes.map { start in writes.filter { $0 >= start && $0 < start + 1 }.count }.max() ?? 0
        }
    }

    /// `speed(t)` in km/h, nil for no source.
    private func run(
        headingUp: Bool, estimate: Bool, seconds: Double, speed: (Double) -> Double?
    ) -> Result {
        var smoother = HeadingSmoother()
        var gate = HeadingWriteGate()
        var zoom = FollowZoom()
        var pending = false
        var result = Result()
        zoom.frame(distance: 250)   // the camera already sits at the cold-start zoom
        smoother.reseed(to: 0)
        let tick = 0.1
        var nextPublish = 0.0
        var now = 0.0
        while now < seconds {
            now += tick
            zoom.step(speedKmh: speed(now), dt: tick)
            var published = false
            if estimate, now >= nextPublish - 1e-9 {
                published = true
                nextPublish += 0.25
            }
            if let write = FollowCameraTick.decide(
                smoother: &smoother, gate: &gate, zoom: &zoom, publishPending: &pending,
                published: published, headingUp: headingUp, frozen: false,
                target: estimate ? 40 * now : nil,   // turning 40 deg/s: the smoother keeps moving
                hasEstimate: estimate, hasCenter: true, semiMajorM: estimate ? 5 : nil, dt: tick,
                now: t(now)
            ) {
                result.writes.append(now)
                result.lastDistance = write.distance
            }
        }
        result.zoom = zoom
        return result
    }

    private func expectBounded(_ r: Result, converged: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(r.maxPerSecond <= 4, "at most 4 camera writes in any 1 s window", sourceLocation: sourceLocation)
        guard converged else { return }
        // Deferred, not dropped: the last write is within the 2 % write
        // threshold of the auto distance, which sits near the 1500 m step
        // (the latch deadband can leave it a few percent short).
        let auto = r.zoom.auto.distance
        #expect(auto > 1400, sourceLocation: sourceLocation)
        #expect(abs(log(r.lastDistance / auto)) <= 0.021, "written \(r.lastDistance), auto \(auto)", sourceLocation: sourceLocation)
    }

    @Test(
        "A 0 to 110 km/h ramp over 15 s writes at most 4 times a second and reaches the zoom (R26.2-1)",
        arguments: [(false, true), (true, true), (false, false)]
    )
    func ramp(headingUp: Bool, estimate: Bool) {
        let r = run(headingUp: headingUp, estimate: estimate, seconds: 45) { min(110, 110 * $0 / 15) }
        #expect(!r.writes.isEmpty)
        expectBounded(r)
    }

    @Test(
        "Speed jumping from none to 110 km/h writes at most 4 times a second and reaches the zoom (R26.2-1)",
        arguments: [(false, true), (true, true), (false, false)]
    )
    func jump(headingUp: Bool, estimate: Bool) {
        let r = run(headingUp: headingUp, estimate: estimate, seconds: 40) { $0 < 5 ? nil : 110 }
        #expect(!r.writes.isEmpty)
        expectBounded(r)
    }

    @Test("Steady state writes nothing without a publish or heading change (R26.1-1, R26.2-1)")
    func steady() {
        let r = run(headingUp: false, estimate: false, seconds: 30) { _ in 110 }
        // The zoom settles at 110 km/h; after that no write follows.
        #expect(r.writes.allSatisfy { $0 < 25 })
        #expect(r.maxPerSecond <= 4)
    }

    @Test("A publish held back by the gate lands on the next open tick (R26.2-1)")
    func heldPublishLands() {
        var smoother = HeadingSmoother()
        var gate = HeadingWriteGate()
        var zoom = FollowZoom()
        var pending = false
        func tick(_ published: Bool, _ at: Double) -> FollowCameraWrite? {
            FollowCameraTick.decide(
                smoother: &smoother, gate: &gate, zoom: &zoom, publishPending: &pending,
                published: published, headingUp: false, frozen: false, target: nil,
                hasEstimate: true, hasCenter: true, semiMajorM: nil, dt: 0.1, now: t(at)
            )
        }
        #expect(tick(true, 1.0) != nil)
        #expect(tick(true, 1.1) == nil)      // 100 ms after a write: held
        #expect(tick(false, 1.2) == nil)
        #expect(tick(false, 1.3) != nil)     // gate open: the held publish lands
        #expect(tick(false, 1.6) == nil)     // and is not written twice
    }

    @Test("The first write after activation is immediate (R26.2-1)")
    func activationIsImmediate() {
        var smoother = HeadingSmoother()
        var gate = HeadingWriteGate()
        var zoom = FollowZoom()
        var pending = false
        gate.noteWrite(0, at: t(1.0))
        _ = CameraHeading.activate(smoother: &smoother, gate: &gate, bearing: 90)
        let write = FollowCameraTick.decide(
            smoother: &smoother, gate: &gate, zoom: &zoom, publishPending: &pending,
            published: true, headingUp: true, frozen: true, target: 90,
            hasEstimate: true, hasCenter: true, semiMajorM: nil, dt: 0.1, now: t(1.05)
        )
        #expect(write?.heading == 90)
    }
}
