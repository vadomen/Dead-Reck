import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

private let base = ContinuousClock.now
private func t(_ seconds: Double) -> ContinuousClock.Instant { base + .seconds(seconds) }

private func nav(
    lat: Double = 0.001, lon: Double = 0.002, major: Double = 20, minor: Double = 8, orientation: Double = 0,
    heading: Double? = 90, converged: Bool = true
) -> NavDisplay {
    NavDisplay(
        position: GeoPoint(latitude: lat, longitude: lon), semiMajorM: major, semiMinorM: minor,
        orientationDeg: orientation, headingDeg: heading, headingStdDeg: converged ? 3 : 30, converged: converged
    )
}

private func fix(t: Double, accuracy: Double, lat: Double = 0.001) -> LocationSample {
    LocationSample(
        latitude: lat, longitude: 0.001, altitude: 0, horizontalAccuracy: accuracy,
        verticalAccuracy: 5, speed: 10, speedAccuracy: 1, course: 0, courseAccuracy: 5,
        receivedT: MonotonicTimestamp(seconds: t), ageS: 0
    )
}

/// Reference wrapper: `#expect` cannot call a mutating member on a local value.
private final class GateBox {
    var gate = NavWriteGate()
    func admit(_ value: NavDisplay?, at now: ContinuousClock.Instant) -> Bool { gate.admit(value, at: now) }
}

@Suite("Map dead-reckoning logic")
struct MapNavigationTests {
    // MARK: bearing choice

    @Test("Heading-up bearing: DR heading once converged, GPS course before")
    func bearingChoice() {
        #expect(CameraHeading.targetBearing(drHeading: 80, converged: true, gpsBearing: 120) == 80)
        // Not converged: the DR heading is not trusted, the M4.3 rule decides.
        #expect(CameraHeading.targetBearing(drHeading: 80, converged: false, gpsBearing: 120) == 120)
        #expect(CameraHeading.targetBearing(drHeading: 80, converged: false, gpsBearing: nil) == nil)
        // Converged without a heading value (cannot happen live) falls back.
        #expect(CameraHeading.targetBearing(drHeading: nil, converged: true, gpsBearing: 120) == 120)
        #expect(CameraHeading.targetBearing(drHeading: nil, converged: true, gpsBearing: nil) == nil)
    }

    @Test("The chosen bearing drives the camera heading; none leaves it north")
    func bearingToCamera() {
        let dr = CameraHeading.targetBearing(drHeading: 80, converged: true, gpsBearing: 120)
        #expect(CameraHeading.choose(headingUp: true, bearing: dr, smoothed: nil) == 80)
        let none = CameraHeading.targetBearing(drHeading: 80, converged: false, gpsBearing: nil)
        #expect(CameraHeading.choose(headingUp: true, bearing: none, smoothed: 200) == 0)
    }

    // MARK: ellipse polygon

    private func enu(_ p: GeoPoint, from c: GeoPoint) -> (east: Double, north: Double) {
        (
            (p.longitude - c.longitude) * NavGeometry.metersPerDegree * cos(c.latitude * .pi / 180),
            (p.latitude - c.latitude) * NavGeometry.metersPerDegree
        )
    }

    @Test("Ellipse ring: major axis runs along the orientation bearing")
    func ellipseOrientation() {
        let c = GeoPoint(latitude: 0.001, longitude: 0.002)
        // Orientation 0: major axis north-south.
        let north = EllipsePolygon.ring(center: c, semiMajorM: 100, semiMinorM: 40, orientationDeg: 0, points: 48)
        #expect(north.count == 48)
        let tip = enu(north[0], from: c)
        #expect(abs(tip.north - 100) < 0.01 && abs(tip.east) < 0.01)
        let side = enu(north[12], from: c)
        #expect(abs(side.east - 40) < 0.01 && abs(side.north) < 0.01)
        // Orientation 90: major axis east-west.
        let east = EllipsePolygon.ring(center: c, semiMajorM: 100, semiMinorM: 40, orientationDeg: 90, points: 48)
        let e = enu(east[0], from: c)
        #expect(abs(e.east - 100) < 0.01 && abs(e.north) < 0.01)
        // Orientation 45: the major tip points north-east.
        let ne = EllipsePolygon.ring(center: c, semiMajorM: 100, semiMinorM: 40, orientationDeg: 45, points: 48)
        let n = enu(ne[0], from: c)
        #expect(abs(n.east - 70.71) < 0.05 && abs(n.north - 70.71) < 0.05)
    }

    @Test("Ellipse ring: every point is on the ellipse, and degenerate input is safe")
    func ellipseShape() {
        let c = GeoPoint(latitude: 48, longitude: 11)
        let theta = 30.0 * .pi / 180
        for p in EllipsePolygon.ring(center: c, semiMajorM: 60, semiMinorM: 20, orientationDeg: 30) {
            let (e, n) = enu(p, from: c)
            let along = e * sin(theta) + n * cos(theta)
            let across = e * cos(theta) - n * sin(theta)
            let r = (along / 60) * (along / 60) + (across / 20) * (across / 20)
            #expect(abs(r - 1) < 1e-3)
        }
        #expect(EllipsePolygon.ring(center: c, semiMajorM: .nan, semiMinorM: 1, orientationDeg: 0).isEmpty)
        // A collapsed ellipse is still drawn at the floor size.
        let tiny = EllipsePolygon.ring(center: c, semiMajorM: 0, semiMinorM: 0, orientationDeg: 0)
        #expect(tiny.count == EllipsePolygon.defaultPoints)
        #expect(Set(tiny).count > 3)
    }

    @Test("Not converged: the ellipse is always drawn, never the dot alone")
    func ellipseLayers() {
        let calibrating = nav(major: 1, converged: false)
        #expect(NavLayers.showDot(calibrating) && NavLayers.showEllipse(calibrating))
        #expect(NavLayers.calibrating(calibrating))
        #expect(NavLayers.showEllipse(nav(major: 30, converged: true)))
        #expect(!NavLayers.showEllipse(nav(major: 1, converged: true)))
        #expect(!NavLayers.calibrating(nav(converged: true)))
        // Before initialisation: nothing.
        #expect(!NavLayers.showDot(nil) && !NavLayers.showEllipse(nil) && !NavLayers.calibrating(nil))
    }

    @Test("An idle snapshot gives no display; stats copy the snapshot")
    func snapshotConversion() {
        #expect(NavDisplay(.idle(at: .zero)) == nil)
        let stats = NavStatsDisplay(NavigationSnapshot.Stats(
            msPerStep: 0.5, maxMsPerStep: 2, effectiveSampleSize: 900, headingStdDeg: 4,
            speedScale: 1.016, droppedInputs: 3
        ))
        #expect(stats.droppedInputs == 3 && stats.effectiveSampleSize == 900)
        #expect(stats.line.contains("ESS 900") && stats.line.contains("dropped 3") && stats.line.contains("1.016"))
    }

    // MARK: framing span

    @Test("Heading-up span fits the ellipse: min(1000, max(minimum, 2.2 x semi-major))")
    func framingSpan() {
        #expect(FollowSpan.span(minimum: 500, semiMajorM: 50) == 500)
        #expect(abs(FollowSpan.span(minimum: 500, semiMajorM: 300) - 660) < 1e-9)
        #expect(FollowSpan.span(minimum: 500, semiMajorM: 2000) == 1000)
        #expect(FollowSpan.span(minimum: 500, semiMajorM: .nan) == 500)
        // A driver who zoomed out beyond 1000 m is not zoomed in.
        #expect(FollowSpan.span(minimum: 1500, semiMajorM: 2000) == 1500)
    }

    // MARK: follow centre

    @Test("Follow centres on the estimate once initialised, otherwise the GPS fix")
    func followCentre() {
        let dr = GeoPoint(latitude: 1, longitude: 2)
        let gps = GeoPoint(latitude: 3, longitude: 4)
        #expect(FollowTarget.center(dr: dr, gps: gps) == dr)
        #expect(FollowTarget.center(dr: nil, gps: gps) == gps)
        #expect(FollowTarget.center(dr: nil, gps: nil) == nil)
    }

    // MARK: faded fixes

    @Test("Fixes over 1000 m are faded dots, outside the polyline")
    func fadedSplit() {
        var track = GPSTrack()
        track.append(fix(t: 0, accuracy: 5))
        track.append(fix(t: 2, accuracy: 1000))      // poor, still in the line
        track.append(fix(t: 4, accuracy: 1000.5))    // bad: faded
        track.append(fix(t: 6, accuracy: 5000))      // bad: faded
        track.append(fix(t: 8, accuracy: 5))
        #expect(track.points.map(\.t) == [0, 2, 8])
        #expect(track.faded.map(\.t) == [4, 6])
        #expect(track.runs.allSatisfy { $0.band != .bad })
        // No bridge or segment break caused by them.
        #expect(track.points.filter(\.segmentStart).count == 1)
    }

    @Test("Faded list is capped, keeps the newest, and dedupes by fix time")
    func fadedCap() {
        var track = GPSTrack()
        for i in 0..<500 { track.append(fix(t: Double(i) * 2, accuracy: 3000)) }
        #expect(track.points.isEmpty && track.runs.isEmpty)
        #expect(track.faded.count == GPSTrack.maxFaded)
        #expect(track.faded.last?.t == 998)
        var again = GPSTrack()
        again.append(fix(t: 4, accuracy: 3000))
        again.append(fix(t: 4, accuracy: 3000))
        #expect(again.faded.count == 1)
    }

    // MARK: pin start

    @Test("Pin starts at the estimate, then the GPS fix, then the finger")
    func pinStart() {
        let dr = GeoPoint(latitude: 1, longitude: 1)
        let gps = GeoPoint(latitude: 2, longitude: 2)
        let finger = GeoPoint(latitude: 3, longitude: 3)
        #expect(PinStart.position(dr: dr, gps: gps, finger: finger) == dr)
        #expect(PinStart.position(dr: nil, gps: gps, finger: finger) == gps)
        #expect(PinStart.position(dr: nil, gps: nil, finger: finger) == finger)
        #expect(PinStart.position(dr: nil, gps: nil, finger: nil) == nil)
    }

    // MARK: 300 m rule

    @Test("Confirm needs a visible span of at most 300 m")
    func zoomRule() {
        #expect(PinPrecision.isPreciseEnough(visibleSpanM: 300))
        #expect(PinPrecision.isPreciseEnough(visibleSpanM: 120))
        #expect(!PinPrecision.isPreciseEnough(visibleSpanM: 300.1))
        #expect(!PinPrecision.isPreciseEnough(visibleSpanM: nil))
        #expect(!PinPrecision.isPreciseEnough(visibleSpanM: .nan))
        let ok = ManualFixAvailability(canRecord: true, gate: .init(speedSource: .obd, speedKmh: 3, isAllowed: true))
        #expect(ManualFixText.confirmBlockedReason(ok, visibleSpanM: 250) == nil)
        #expect(ManualFixText.confirmBlockedReason(ok, visibleSpanM: 500) == "Zoom in to place the pin precisely")
        // The recorder's reason wins, and the speed gate itself is unchanged.
        let fast = ManualFixAvailability(canRecord: false, gate: .init(speedSource: .obd, speedKmh: 23, isAllowed: false))
        #expect(ManualFixText.confirmBlockedReason(fast, visibleSpanM: 100) == ManualFixText.disabledReason(fast))
        #expect(ManualFixText.confirmBlockedReason(fast, visibleSpanM: 100)?.hasPrefix("Slow to") == true)
    }

    // MARK: feed write gate

    @Test("Write gate: moves over 1 m or turns over 2 degrees, at most every 0.25 s")
    func writeGate() {
        let g = GateBox()
        #expect(g.admit(nav(), at: t(0)))                              // first
        #expect(!g.admit(nav(lat: 0.001 + 0.00005), at: t(0.1)))       // moved 5.6 m but too soon
        #expect(!g.admit(nav(lat: 0.001 + 0.0000045), at: t(0.5)))     // 0.5 m: not enough
        #expect(g.admit(nav(lat: 0.001 + 0.00005), at: t(0.5)))        // 5.6 m
        #expect(!g.admit(nav(lat: 0.001 + 0.00005, heading: 92), at: t(1)))     // exactly 2 degrees
        #expect(g.admit(nav(lat: 0.001 + 0.00005, heading: 92.5), at: t(1)))
        #expect(!g.admit(nav(lat: 0.001 + 0.00005, heading: 93), at: t(1.1)))   // too soon
    }

    @Test("Write gate: heading change takes the short way round 0/360")
    func writeGateWrap() {
        let g = GateBox()
        #expect(g.admit(nav(heading: 359), at: t(0)))
        #expect(!g.admit(nav(heading: 1), at: t(1)))     // 2 degrees
        #expect(g.admit(nav(heading: 2), at: t(2)))      // 3 degrees
    }

    @Test("Write gate: convergence, appearing and disappearing are written at once")
    func writeGateTransitions() {
        let g = GateBox()
        #expect(!g.admit(nil, at: t(0)))                 // nothing to clear
        #expect(g.admit(nav(converged: false), at: t(0)))
        #expect(g.admit(nav(converged: true), at: t(0.01)))   // flips inside the interval
        #expect(g.admit(nil, at: t(0.02)))               // recording ended
        #expect(!g.admit(nil, at: t(0.5)))
        #expect(g.admit(nav(), at: t(0.5)))              // a new recording starts again
    }

    @Test("Write gate: a growing ellipse is published")
    func writeGateGrowth() {
        let g = GateBox()
        #expect(g.admit(nav(major: 20), at: t(0)))
        #expect(!g.admit(nav(major: 21), at: t(1)))
        #expect(g.admit(nav(major: 40), at: t(2)))
    }

    @Test("Feed: an idle snapshot clears the unobserved latest copy and the stats")
    @MainActor func feedIdle() {
        let feed = NavigationFeed(display: nav(), stats: NavStatsDisplay(.init()))
        #expect(feed.latest != nil && feed.stats != nil)
        _ = feed.apply(.idle(at: .zero), at: t(0))
        #expect(feed.latest == nil)
        #expect(feed.stats == nil)
    }
}
