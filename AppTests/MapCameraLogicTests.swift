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
