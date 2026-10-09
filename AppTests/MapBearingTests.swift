import DriveLoggerCore
import Testing

@testable import DriveLogger

private func fix(
    speed: Double = 20, course: Double = 90, courseAccuracy: Double = 5
) -> LocationSample {
    LocationSample(
        latitude: 0, longitude: 0, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
        speed: speed, speedAccuracy: 1, course: course, courseAccuracy: courseAccuracy,
        receivedT: MonotonicTimestamp(seconds: 0), ageS: 0
    )
}

@Suite("GPSCourseBearingSource")
@MainActor
struct MapBearingSourceTests {
    @Test("Speed gate: exactly 10 km/h rejected, just above accepted")
    func speedGate() {
        let s = GPSCourseBearingSource()
        s.ingest(fix(speed: 10.0 / 3.6, course: 10))
        #expect(s.bearingDegrees == nil)
        s.ingest(fix(speed: 10.01 / 3.6, course: 20))
        #expect(s.bearingDegrees == 20)
        s.ingest(fix(speed: -1, course: 30))
        #expect(s.bearingDegrees == 20)
        s.ingest(fix(speed: .nan, course: 30))
        #expect(s.bearingDegrees == 20)
    }

    @Test("Course accuracy gate: 20 accepted, 20.1 rejected, negative and NaN rejected")
    func accuracyGate() {
        let s = GPSCourseBearingSource()
        s.ingest(fix(course: 1, courseAccuracy: 20.1))
        #expect(s.bearingDegrees == nil)
        s.ingest(fix(course: 2, courseAccuracy: 20))
        #expect(s.bearingDegrees == 2)
        s.ingest(fix(course: 3, courseAccuracy: -1))
        s.ingest(fix(course: 4, courseAccuracy: .nan))
        #expect(s.bearingDegrees == 2)
        s.ingest(fix(course: 5, courseAccuracy: 0))
        #expect(s.bearingDegrees == 5)
    }

    @Test("Course gate: negative, NaN and 360 rejected; 0 accepted; holds last good")
    func courseGate() {
        let s = GPSCourseBearingSource()
        s.ingest(fix(course: 0))
        #expect(s.bearingDegrees == 0)
        s.ingest(fix(course: 100))
        s.ingest(fix(course: -1))
        s.ingest(fix(course: .nan))
        s.ingest(fix(course: 360))
        #expect(s.bearingDegrees == 100)
        s.reset()
        #expect(s.bearingDegrees == nil)
    }
}

private func step(_ s: inout HeadingSmoother, target: Double?, frozen: Bool, dt: Double) -> Double? {
    s.step(target: target, frozen: frozen, dt: dt)
}

@Suite("HeadingSmoother")
struct HeadingSmootherTests {
    @Test("First target snaps")
    func snaps() {
        var s = HeadingSmoother()
        #expect(s.step(target: nil, frozen: false, dt: 0.1) == nil)
        #expect(s.step(target: 123, frozen: false, dt: 0.1) == 123)
    }

    @Test("350 to 10 goes the short way through 0")
    func wraps() throws {
        var s = HeadingSmoother()
        s.step(target: 350, frozen: false, dt: 0.1)
        let h = try #require(step(&s, target: 10, frozen: false, dt: 0.1))
        // Moved +20 * alpha through north, not -340.
        #expect(h < 10 || h > 350)
        #expect(h != 350)
        #expect(HeadingSmoother.shortestDelta(from: 350, to: h) > 0)
    }

    @Test("Never exceeds 90 deg/s per step")
    func rateClamp() throws {
        var s = HeadingSmoother()
        s.step(target: 0, frozen: false, dt: 0.1)
        for dt in [0.1, 0.5, 2.0] {
            let before = try #require(s.heading)
            let after = try #require(step(&s, target: 180, frozen: false, dt: dt))
            #expect(abs(HeadingSmoother.shortestDelta(from: before, to: after)) <= 90 * dt + 1e-9)
        }
    }

    @Test("Frozen and nil target hold")
    func holds() {
        var s = HeadingSmoother()
        s.step(target: 100, frozen: false, dt: 0.1)
        #expect(s.step(target: 200, frozen: true, dt: 1) == 100)
        #expect(s.step(target: nil, frozen: false, dt: 1) == 100)
        #expect(s.step(target: 200, frozen: false, dt: 0) == 100)
        #expect(s.step(target: 200, frozen: false, dt: .nan) == 100)
        #expect(s.step(target: 200, frozen: false, dt: -1) == 100)
    }

    @Test("Converges to the target and stays in [0, 360)")
    func converges() throws {
        var s = HeadingSmoother()
        s.step(target: 300, frozen: false, dt: 0.1)
        for target in [20.0, 200, 359.9, 0] {
            for _ in 0..<200 {
                let h = try #require(step(&s, target: target, frozen: false, dt: 0.1))
                #expect(h >= 0 && h < 360)
            }
            let h = try #require(s.heading)
            #expect(abs(HeadingSmoother.shortestDelta(from: h, to: target)) < 0.1)
        }
        #expect(HeadingSmoother.normalized(-1e-20) < 360)
        #expect(HeadingSmoother.normalized(-10) == 350)
        #expect(HeadingSmoother.normalized(720) == 0)
    }
}
