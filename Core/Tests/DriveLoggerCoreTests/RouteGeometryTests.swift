import Foundation
import Testing

@testable import DriveLoggerCore

/// Route helpers (prompt 51 item B): cumulative distance, projection onto
/// the route, the point at a distance along it, and the distance to the next
/// maneuver. Synthetic polylines only.
@Suite("Route geometry (prompt 51 B)")
struct RouteGeometryTests {
    typealias F = RouteFixture

    /// 200 m north, then 300 m east, then 100 m south.
    static func hook(origin: (latitude: Double, longitude: Double) = F.equator) throws -> RoutePolyline {
        try RoutePolyline(F.points([(0, 0), (0, 200), (300, 200), (300, 100)], origin: origin))
    }

    @Test("Cumulative distance follows the segments, at the equator and at 60° south")
    func cumulative() throws {
        for origin in [F.equator, F.south] {
            let line = try Self.hook(origin: origin)
            let expected = [0.0, 200, 500, 600]
            #expect(line.cumulativeDistanceM.count == 4)
            for (got, want) in zip(line.cumulativeDistanceM, expected) {
                #expect(abs(got - want) < 0.05, "\(origin): \(got) vs \(want)")
            }
            #expect(abs(line.lengthM - 600) < 0.05)
            #expect(abs(line.segmentLengthM(1) - 300) < 0.05)
        }
    }

    @Test("Fewer than two points is not a polyline")
    func tooFew() {
        #expect(throws: RouteError.tooFewPoints(1)) { try RoutePolyline([RoutePoint(latE7: 0, lonE7: 0)]) }
        #expect(throws: RouteError.tooFewPoints(0)) { try RoutePolyline([]) }
    }

    @Test("A segment across ±180° is measured the short way")
    func antimeridian() throws {
        let line = try RoutePolyline([
            RoutePoint(latE7: 0, lonE7: 1_799_999_000), RoutePoint(latE7: 0, lonE7: -1_799_999_000),
        ])
        // 2000 E7 units of longitude at the equator: about 22.3 m.
        #expect(abs(line.lengthM - 22.26) < 0.05)
        let mid = line.position(atDistanceAlongM: line.lengthM / 2)
        #expect(abs(abs(mid.longitude) - 180) < 1e-9)
        let p = try #require(line.project(latitude: 0.000_05, longitude: 179.999_95))
        #expect(abs(p.distanceAlongM - line.lengthM / 4) < 0.05)
        #expect(abs(abs(p.crossTrackM) - 5.53) < 0.05)
    }

    @Test("Projection gives distance along, signed cross-track (right positive) and the segment", arguments: [
        F.equator, F.south,
    ])
    func projection(origin: (latitude: Double, longitude: Double)) throws {
        let line = try Self.hook(origin: origin)
        let plane = LocalTangentPlane(latitude: origin.latitude, longitude: origin.longitude)
        func project(_ east: Double, _ north: Double) throws -> RouteProjection {
            let q = plane.geodetic(east: east, north: north)
            return try #require(line.project(latitude: q.latitude, longitude: q.longitude))
        }
        // 12 m east of the northbound first leg: right of travel.
        var p = try project(12, 80)
        #expect(p.segmentIndex == 0)
        #expect(abs(p.fraction - 0.4) < 1e-3)
        #expect(abs(p.distanceAlongM - 80) < 0.05)
        #expect(abs(p.crossTrackM - 12) < 0.05)
        // 7 m west of it: left.
        p = try project(-7, 150)
        #expect(abs(p.crossTrackM + 7) < 0.05)
        #expect(abs(p.distanceAlongM - 150) < 0.05)
        // North of the eastbound leg is left of travel.
        p = try project(100, 230)
        #expect(p.segmentIndex == 1)
        #expect(abs(p.distanceAlongM - 300) < 0.05)
        #expect(abs(p.crossTrackM + 30) < 0.05)
        // The projected point lies on the leg.
        let snapped = plane.enu(latitude: p.latitude, longitude: p.longitude)
        #expect(abs(snapped.east - 100) < 0.05 && abs(snapped.north - 200) < 0.05)
        // West of the southbound last leg is right of travel.
        p = try project(290, 150)
        #expect(p.segmentIndex == 2)
        #expect(abs(p.distanceAlongM - 550) < 0.05)
        #expect(abs(p.crossTrackM - 10) < 0.05)
        // Past the end: clamped to the last vertex.
        p = try project(300, 50)
        #expect(p.segmentIndex == 2 && p.fraction == 1)
        #expect(abs(p.distanceAlongM - 600) < 0.05)
        #expect(abs(abs(p.crossTrackM) - 50) < 0.05)
        // Before the start: clamped to the first vertex.
        p = try project(0, -20)
        #expect(p.segmentIndex == 0 && p.fraction == 0 && p.distanceAlongM == 0)
    }

    @Test("A window of distance along picks the right pass of an out-and-back route; outside it gives nil")
    func window() throws {
        // 400 m east, then back west 10 m further south: the two passes are 10 m apart.
        let line = try RoutePolyline(F.points([(0, 0), (400, 0), (400, -10), (0, -10)]))
        let q = LocalTangentPlane(latitude: 0, longitude: 0).geodetic(east: 100, north: -6)
        let global = try #require(line.project(latitude: q.latitude, longitude: q.longitude))
        #expect(global.segmentIndex == 2)
        #expect(abs(global.distanceAlongM - 710) < 0.05)
        let outbound = try #require(line.project(latitude: q.latitude, longitude: q.longitude, alongRangeM: 0...300))
        #expect(outbound.segmentIndex == 0)
        #expect(abs(outbound.distanceAlongM - 100) < 0.05)
        #expect(abs(outbound.crossTrackM - 6) < 0.05)
        // The window only selects segments; one that overlaps it is searched whole.
        let partial = try #require(line.project(latitude: q.latitude, longitude: q.longitude, alongRangeM: 405...420))
        #expect(partial.segmentIndex == 2)
        #expect(line.project(latitude: q.latitude, longitude: q.longitude, alongRangeM: 900...1000) == nil)
        #expect(line.project(latitude: q.latitude, longitude: q.longitude, alongRangeM: -50 ... -1) == nil)
        // A window touching a vertex includes both segments that meet there.
        let r = LocalTangentPlane(latitude: 0, longitude: 0).geodetic(east: 403, north: -5)
        let corner = line.cumulativeDistanceM[1], back = line.cumulativeDistanceM[2]
        #expect(line.project(latitude: r.latitude, longitude: r.longitude, alongRangeM: corner...corner)?.segmentIndex == 1)
        #expect(line.project(latitude: r.latitude, longitude: r.longitude, alongRangeM: 0...corner.nextDown)?
            .segmentIndex == 0)
        #expect(line.project(latitude: q.latitude, longitude: q.longitude, alongRangeM: back...back)?.segmentIndex == 2)
        #expect(line.project(latitude: q.latitude, longitude: q.longitude, alongRangeM: back.nextUp...2000)?
            .segmentIndex == 2)
    }

    @Test("Equal distances go to the lower segment index")
    func tieBreak() throws {
        // Out and back on the same line: every point is equally near both passes.
        let line = try RoutePolyline(F.points([(0, 0), (0, 100), (0, 0)]))
        let q = LocalTangentPlane(latitude: 0, longitude: 0).geodetic(east: 3, north: 40)
        let p = try #require(line.project(latitude: q.latitude, longitude: q.longitude))
        #expect(p.segmentIndex == 0)
        #expect(abs(p.distanceAlongM - 40) < 0.05)
    }

    @Test("Position at a distance along interpolates and clamps")
    func positionAlong() throws {
        let line = try Self.hook()
        let plane = LocalTangentPlane(latitude: 0, longitude: 0)
        for (s, east, north) in [(0.0, 0.0, 0.0), (50, 0, 50), (200, 0, 200), (350, 150, 200), (600, 300, 100),
                                 (-10, 0, 0), (900, 300, 100)] {
            let p = line.position(atDistanceAlongM: s)
            let enu = plane.enu(latitude: p.latitude, longitude: p.longitude)
            #expect(abs(enu.east - east) < 0.05 && abs(enu.north - north) < 0.05, "s=\(s): \(enu)")
        }
    }

    @Test("Next maneuver: the first step whose maneuver vertex lies strictly ahead, with its distance")
    func nextManeuver() throws {
        let points = F.points([(0, 0), (0, 200), (300, 200), (300, 100)])
        let route = try F.route(points, breaks: [1, 2])
        #expect(route.steps.map(\.maneuver) == [.depart, .right, .right, .arrive])
        let geometry = RouteGeometry(route: route)
        #expect(geometry.maneuverDistanceAlongM.count == 4)
        var next = try #require(geometry.nextManeuver(afterDistanceAlongM: 0))
        #expect(next.stepIndex == 1 && next.maneuver == .right)
        #expect(abs(next.distanceToM - 200) < 0.05)
        next = try #require(geometry.nextManeuver(afterDistanceAlongM: 120))
        #expect(next.stepIndex == 1 && abs(next.distanceToM - 80) < 0.05)
        // At the maneuver vertex itself, the next one is the following step.
        next = try #require(geometry.nextManeuver(afterDistanceAlongM: geometry.maneuverDistanceAlongM[1]))
        #expect(next.stepIndex == 2 && abs(next.distanceToM - 300) < 0.05)
        next = try #require(geometry.nextManeuver(afterDistanceAlongM: 590))
        #expect(next.stepIndex == 3 && next.maneuver == .arrive && abs(next.distanceToM - 10) < 0.05)
        #expect(abs(next.distanceAlongM - geometry.lengthM) < 1e-9)
        #expect(geometry.nextManeuver(afterDistanceAlongM: geometry.lengthM) == nil)
        // Before the start, depart (at 0) is ahead.
        #expect(geometry.nextManeuver(afterDistanceAlongM: -5)?.maneuver == .depart)
        // From a projection.
        let q = LocalTangentPlane(latitude: 0, longitude: 0).geodetic(east: 150, north: 215)
        let p = try #require(geometry.project(latitude: q.latitude, longitude: q.longitude))
        let ahead = try #require(geometry.nextManeuver(afterDistanceAlongM: p.distanceAlongM))
        #expect(ahead.stepIndex == 2 && abs(ahead.distanceToM - 150) < 0.05)
    }

    @Test("Same input, same output: geometry is deterministic")
    func deterministic() throws {
        let points = F.wandering(count: 300, spacingM: 40, turnEvery: 30)
        let a = try RoutePolyline(points), b = try RoutePolyline(points)
        #expect(a == b)
        #expect(a.cumulativeDistanceM.map(\.bitPattern) == b.cumulativeDistanceM.map(\.bitPattern))
        let q = a.position(atDistanceAlongM: 4321)
        #expect(a.project(latitude: q.latitude + 1e-4, longitude: q.longitude)
            == b.project(latitude: q.latitude + 1e-4, longitude: q.longitude))
    }
}
