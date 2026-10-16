import Foundation
import Testing

@testable import DriveLoggerCore

/// `FixOffsetScan` (`replay_nav --fix-offset`): a constant-offset check of a
/// run of fixes against road packs. Synthetic roads near (0, 0) only.
@Suite struct FixOffsetScanTests {
    typealias N = RoadFixture.Node

    /// One irregular road: no constant shift but zero lays it onto itself.
    static let corners: [(Double, Double)] = [(-500, -200), (-200, -200), (-100, 100), (300, 100), (300, 400)]

    static func network() throws -> RoadNetwork {
        let nodes = corners.enumerated().map { N(id: Int64(10 + $0.offset), east: $0.element.0, north: $0.element.1) }
        return try RoadNetwork(packs: [RoadFixture.build([RoadFixture.way(1, ["highway": "residential"], nodes)])])
    }

    /// Fixes every `spacing` metres along the road, moved by `shift`, with
    /// the road's course and 10 m/s.
    static func track(shift: (Double, Double) = (0, 0), spacing: Double = 20) -> [FixOffsetScan.Fix] {
        var fixes: [FixOffsetScan.Fix] = []
        var t = 0.0
        for (a, b) in zip(corners, corners.dropFirst()) {
            let dx = b.0 - a.0, dy = b.1 - a.1
            let length = (dx * dx + dy * dy).squareRoot()
            let course = FixOffsetScan.bearing(east: dx, north: dy)
            var s = 0.0
            while s < length {
                let p = RoadFixture.point(a.0 + dx * s / length + shift.0, a.1 + dy * s / length + shift.1)
                fixes.append(FixOffsetScan.Fix(t: t, latitude: p.latitude, longitude: p.longitude, accuracyM: 10,
                                               accessory: true, speed: 10, course: course))
                s += spacing
                t += spacing / 10
            }
        }
        return fixes
    }

    @Test func findsTheConstantShiftOfAShiftedTrack() throws {
        let w = try #require(FixOffsetScan.scan(Self.track(shift: (150, -220)), roads: Self.network()))
        #expect(abs(w.best.east + 150) <= 2 && abs(w.best.north - 220) <= 2)
        #expect(w.bestScore.meanM < 2)
        #expect(w.recorded.meanM > 50)
        #expect(w.recordedRank > 0.5)
        #expect(w.offRoad && w.found && w.unique)
        #expect(FixOffsetScan.text(w).hasSuffix("OFF ROADS, shift fits, unique"))
    }

    @Test func aTrackOnItsRoadHasNoOffset() throws {
        let w = try #require(FixOffsetScan.scan(Self.track(), roads: Self.network()))
        #expect(w.best.lengthM < 2)
        #expect(w.recorded.meanM < 1)
        #expect(!w.offRoad && !w.found)
        #expect(FixOffsetScan.text(w).hasSuffix("on roads"))
        // Only the zero shift (and its neighbours within one step) does as well.
        #expect(w.recordedRank < 0.01)
    }

    @Test func aTestedShiftIsScoredAndRanked() throws {
        var options = FixOffsetScan.Options()
        options.tested = [FixOffsetScan.Shift(east: -150, north: 220), FixOffsetScan.Shift(east: 200, north: 200)]
        let w = try #require(FixOffsetScan.scan(Self.track(shift: (150, -220)), roads: Self.network(), options: options))
        #expect(w.tested.count == 2)
        #expect(w.tested[0].score.meanM < 2 && w.tested[0].rank < 0.01)
        #expect(w.tested[1].score.meanM > 20 && w.tested[1].rank > 0.1)
        #expect(FixOffsetScan.testedText(w)[0].hasPrefix("  tested 266 m @326°"))
    }

    @Test func distancesAreCappedAndTheCourseGateSkipsCrossingRoads() throws {
        let net = try Self.network()
        let plane = LocalTangentPlane(latitude: 0, longitude: 0)
        let field = RoadField(roads: net, plane: plane, points: [(0, 0)], marginM: 1_000, capM: 100)
        // 5 m north of the first (east-running) segment.
        #expect(abs(field.distance(east: -350, north: -195) - 5) < 0.1)
        // Moving north there, the east-running segment does not count; the
        // diagonal one (course ~18°) is ~95 m away along x.
        let north = (0.0, 1.0)
        let gated = field.distance(east: -350, north: -195, course: north, minAbsCos: cos(30 * .pi / 180))
        #expect(gated > 80 && gated <= 100)
        // Far from every road: the cap.
        #expect(field.distance(east: 2_000, north: 2_000) == 100)
    }

    @Test func tooFewFixesAreNotScanned() throws {
        #expect(FixOffsetScan.scan(Array(Self.track().prefix(4)), roads: try Self.network()) == nil)
    }

    @Test func cleanFixesFilterBySourceAndAccuracy() {
        func event(_ t: Double, acc: Double, accessory: Bool?) -> LogEvent {
            LogEvent(timestamp: MonotonicTimestamp(seconds: t), payload: .location(LocationSample(
                latitude: 0, longitude: 0, altitude: 0, horizontalAccuracy: acc, verticalAccuracy: 3,
                speed: -1, speedAccuracy: -1, course: -1, courseAccuracy: -1, accessory: accessory)))
        }
        let events = [event(3, acc: 10, accessory: true), event(1, acc: 5, accessory: nil), event(2, acc: 20, accessory: true),
                      event(4, acc: -1, accessory: false), event(5, acc: 15, accessory: false)]
        #expect(FixOffsetScan.cleanFixes(from: events).map(\.t) == [1, 3, 5])
        #expect(FixOffsetScan.cleanFixes(from: events, source: .accessory).map(\.t) == [3])
        #expect(FixOffsetScan.cleanFixes(from: events, source: .phone).map(\.t) == [1, 5])
        #expect(FixOffsetScan.cleanFixes(from: events, source: .accessory, maxAccuracyM: 50).map(\.t) == [2, 3])
    }

    @Test func pinChecksUseTheTimeNearestFixWithinTheGap() {
        let fix = RoadFixture.point(0, 0), pin = RoadFixture.point(300, 100)
        let fixes = [FixOffsetScan.Fix(t: 10, latitude: fix.latitude, longitude: fix.longitude, accuracyM: 10)]
        let checks = FixOffsetScan.pinChecks(pins: [(10.4, pin.latitude, pin.longitude), (20, pin.latitude, pin.longitude)],
                                             fixes: fixes)
        #expect(checks.count == 1)
        let c = try! #require(checks.first)
        #expect(abs(c.vector.lengthM - (300.0 * 300 + 100 * 100).squareRoot()) < 0.5)
        #expect(abs(c.vector.bearingDeg - 71.57) < 0.1)
        #expect(abs(c.fixDtS + 0.4) < 1e-9)
    }

    @Test func dynamicsCompareTheFixesWithOBDAndTheGyro() {
        // 100 m east then a 90° right turn and 100 m south, at 10 m/s.
        let points: [(Double, Double, Double)] = (0...10).map { (Double($0) * 10, 0, 90) } + (1...10).map { (100, -Double($0) * 10, 180) }
        let fixes = points.enumerated().map { i, p in
            let q = RoadFixture.point(p.0, p.1)
            return FixOffsetScan.Fix(t: Double(i), latitude: q.latitude, longitude: q.longitude, accuracyM: 10, speed: 10, course: p.2)
        }
        let obd = stride(from: -0.5, through: 20.5, by: 0.5).map { (t: $0, mps: 10.0) }
        // The turn happens between t = 10 and 11: −90°/s about up (clockwise).
        let yaw = stride(from: 0.0, through: 20.0, by: 0.01).map { (t: $0, radPerS: $0 >= 10 && $0 < 11 ? -Double.pi / 2 : 0) }
        let d = FixOffsetScan.dynamics(fixes, obdSpeed: obd, yawRate: yaw)
        #expect(abs(d.fixPathM - 200) < 0.5)
        #expect(abs(try! #require(d.obdDistanceM) - 200) < 1e-6)
        #expect(try! #require(d.speedDifferenceMedianKmh) < 1e-9)
        #expect(d.courseChangeDeg == 90)
        #expect(abs(try! #require(d.gyroYawDeg) - 90) < 1)
    }

    @Test func yawRateIsAboutUpCounterClockwise() {
        // Phone flat, screen up: gravity −z; a positive z rate is counter-clockwise from above.
        let m = MotionSample.testFlat(rotationZ: 0.5)
        let rates = FixOffsetScan.yawRate(from: [LogEvent(timestamp: .zero, payload: .motion(m))])
        #expect(rates.count == 1 && abs(rates[0].radPerS - 0.5) < 1e-12)
    }
}

extension MotionSample {
    static func testFlat(rotationZ: Double) -> MotionSample {
        MotionSample(userAcceleration: Vector3(x: 0, y: 0, z: 0), gravity: Vector3(x: 0, y: 0, z: -1),
                     rotationRate: Vector3(x: 0, y: 0, z: rotationZ), attitude: Quaternion(x: 0, y: 0, z: 0, w: 1))
    }
}
