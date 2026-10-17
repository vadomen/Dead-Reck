import Foundation
import Testing

@testable import DriveLoggerCore

/// `FixOffsetScan` (`replay_nav --fix-offset`): a constant-offset check of a
/// run of fixes against road packs. Synthetic roads near (0, 0) only.
@Suite struct FixOffsetScanTests {
    typealias N = RoadFixture.Node

    /// Default thresholds and range on a 20 m / 2 m grid (1681 coarse shifts
    /// instead of 6561), so the scans do not load the machine while timing
    /// tests run in parallel (NavigationB0Tests R13.1-6c failed under it).
    static var fast: FixOffsetScan.Options {
        var o = FixOffsetScan.Options()
        o.coarseStepM = 20
        o.fineStepM = 2
        return o
    }

    /// One irregular road: no constant shift but zero lays it onto itself.
    static let corners: [(Double, Double)] = [(-500, -200), (-200, -200), (-100, 100), (300, 100), (300, 400)]

    /// The road, and one more copy of it moved by each of `copies`.
    static func network(copies: [(Double, Double)] = []) throws -> RoadNetwork {
        let ways = ([(0.0, 0.0)] + copies).enumerated().map { k, offset in
            let nodes = corners.enumerated().map {
                N(id: Int64(10 * (k + 1) + $0.offset), east: $0.element.0 + offset.0, north: $0.element.1 + offset.1)
            }
            return RoadFixture.way(Int64(k + 1), ["highway": "residential"], nodes)
        }
        return try RoadNetwork(packs: [RoadFixture.build(ways)])
    }

    /// Fixes every `spacing` metres along the polyline `path` (by default
    /// the road), moved by `shift`, with the polyline's course and 10 m/s.
    static func track(shift: (Double, Double) = (0, 0), spacing: Double = 20,
                      along path: [(Double, Double)] = corners) -> [FixOffsetScan.Fix] {
        var fixes: [FixOffsetScan.Fix] = []
        var t = 0.0
        for (a, b) in zip(path, path.dropFirst()) {
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
        let w = try #require(FixOffsetScan.scan(Self.track(shift: (150, -220)), roads: Self.network(), options: Self.fast))
        #expect(abs(w.best.east + 150) <= 2 && abs(w.best.north - 220) <= 2)
        #expect(w.bestScore.meanM < 2)
        #expect(w.recorded.meanM > 50)
        #expect(w.recordedRank > 0.5)
        #expect(w.offRoad && w.found && w.unique)
        #expect(FixOffsetScan.text(w).hasSuffix("OFF ROADS, shift fits, unique"))
    }

    /// A shift shorter than `foundMinShiftM` is not an offset, however well
    /// it fits (an ordinary GNSS bias). The 266 m shift with the minimum
    /// raised to 300 m stands in for a short shift.
    @Test func aShiftShorterThanTheMinimumIsNotFound() throws {
        var options = Self.fast
        options.foundMinShiftM = 300
        let w = try #require(FixOffsetScan.scan(Self.track(shift: (150, -220)), roads: Self.network(), options: options))
        #expect(w.bestScore.meanM < 2 && w.best.lengthM < 300)
        #expect(w.offRoad && !w.found)
        #expect(FixOffsetScan.text(w).hasSuffix("OFF ROADS, no shift fits"))
    }

    @Test func aTrackOnItsRoadHasNoOffset() throws {
        let w = try #require(FixOffsetScan.scan(Self.track(), roads: Self.network(), options: Self.fast))
        #expect(w.best.lengthM < 2)
        #expect(w.recorded.meanM < 1)
        #expect(!w.offRoad && !w.found)
        #expect(FixOffsetScan.text(w).hasSuffix("on roads"))
        // Only the zero shift (and its neighbours within one step) does as well.
        #expect(w.recordedRank < 0.01)
    }

    /// 20 m east and 20 m north of the road: the mean (~18 m) passes
    /// `offRoadMinM`, but almost no other shift does as well (one road in an
    /// empty area), so the rank keeps the window "on roads".
    @Test func aSmallOffsetWithALowRankIsOnRoads() throws {
        let options = Self.fast
        let w = try #require(FixOffsetScan.scan(Self.track(shift: (20, 20)), roads: Self.network(), options: options))
        #expect(w.recorded.value(options.statistic) >= options.offRoadMinM)
        #expect(w.recordedRank < options.offRoadMinRank)
        #expect(!w.offRoad && !w.found)
        #expect(FixOffsetScan.text(w).hasSuffix("on roads"))
    }

    /// The road mirrored north–south matches no shift of the road: off roads
    /// (every fix capped, rank 100 %), and the best shift (one leg laid on
    /// the road) keeps far more than half the mean.
    @Test func aTrackOfAnotherShapeIsOffRoadsWithNoShiftFitting() throws {
        let options = Self.fast
        let mirrored = Self.corners.map { ($0.0, -$0.1) }
        let w = try #require(FixOffsetScan.scan(Self.track(along: mirrored), roads: Self.network(), options: options))
        #expect(w.recorded.value(options.statistic) >= options.offRoadMinM && w.recordedRank >= options.offRoadMinRank)
        #expect(w.best.lengthM >= options.foundMinShiftM)
        #expect(w.bestScore.value(options.statistic) > options.foundRatio * w.recorded.value(options.statistic))
        #expect(w.offRoad && !w.found)
        #expect(FixOffsetScan.text(w).hasSuffix("OFF ROADS, no shift fits"))
    }

    /// Two copies of the road 140 m apart (north): the shifted track fits
    /// both, so the runner-up is as good as the best. Both fits lie on the
    /// 20 m coarse grid (the runner-up is not refined).
    @Test func aShiftFittingTwoPlacesIsNotUnique() throws {
        let w = try #require(FixOffsetScan.scan(Self.track(shift: (160, -220)), roads: Self.network(copies: [(0, 140)]), options: Self.fast))
        #expect(w.bestScore.meanM < 2)
        let runner = try #require(w.runnerUp)
        let other = [(-160.0, 220.0), (-160, 360)].first { abs($0.0 - w.best.east) > 5 || abs($0.1 - w.best.north) > 5 }!
        #expect(abs(runner.east - other.0) <= 10 && abs(runner.north - other.1) <= 10)
        #expect(try #require(w.runnerUpScore).meanM < 2)
        #expect(w.offRoad && w.found && !w.unique)
        #expect(FixOffsetScan.text(w).hasSuffix("OFF ROADS, shift fits, not unique"))
    }

    @Test func aTestedShiftIsScoredAndRanked() throws {
        var options = Self.fast
        options.tested = [FixOffsetScan.Shift(east: -150, north: 220), FixOffsetScan.Shift(east: 200, north: 200)]
        let w = try #require(FixOffsetScan.scan(Self.track(shift: (150, -220)), roads: Self.network(), options: options))
        #expect(w.tested.count == 2)
        #expect(w.tested[0].score.meanM < 2 && w.tested[0].rank < 0.01)
        #expect(w.tested[1].score.meanM > 20 && w.tested[1].rank > 0.1)
        #expect(FixOffsetScan.testedText(w)[0].hasPrefix("  tested 266 m @326°"))
    }

    /// R35.1-3: a tested shift longer than the grid's reach is scored
    /// against the roads it lands on. The track sits 1500 m east of its
    /// road, the grid only reaches ±50 m: before, the road field stopped at
    /// the grid's margin, so the shift back onto the road scored every fix
    /// at the cap (mean 100 m) instead of on the road.
    @Test func aTestedShiftBeyondTheGridIsScoredAgainstItsRoads() throws {
        var options = Self.fast
        options.maxShiftM = 50
        options.tested = [FixOffsetScan.Shift(east: -1500, north: 0)]
        let w = try #require(FixOffsetScan.scan(Self.track(shift: (1500, 0)), roads: Self.network(), options: options))
        #expect(w.recorded.meanM == options.capM)
        #expect(w.tested.count == 1 && w.tested[0].score.meanM < 1)
        // Within the grid's reach the margin is the grid's, as before.
        options.tested = [FixOffsetScan.Shift(east: 40, north: -60)]
        #expect(FixOffsetScan.fieldMarginM(options) == options.maxShiftM + options.capM + options.fineStepM + options.coarseStepM)
        options.tested.append(FixOffsetScan.Shift(east: 10, north: -1500))
        #expect(FixOffsetScan.fieldMarginM(options) == 1500 + options.capM)
    }

    /// R35.2-3: `replay_nav --fix-offset` refuses the engine run's flags
    /// (it exited 0 with `--compare`, `--out` or `--truth` silently
    /// ignored) and keeps the ones the scan uses.
    @Test func fixOffsetRefusesTheEngineRunsFlags() {
        let given = ["--fix-offset", "--roads", "--compare", "--fix-offset-max", "--out", "--truth", "--compare", "--strict",
                     "--gps", "--set", "--write-sidecar", "--fix-source", "--fix-offset-test", "--fix-offset-trace"]
        #expect(FixOffsetScan.refusedFlags(given) == ["--compare", "--out", "--truth", "--gps", "--set", "--write-sidecar"])
        let scanOnly = ["--fix-offset", "--roads", "--fix-source", "--fix-offset-max", "--fix-offset-step", "--fix-max-acc",
                        "--fix-offset-stat", "--fix-offset-course", "--fix-offset-test", "--fix-offset-trace", "--strict"]
        #expect(FixOffsetScan.refusedFlags(scanOnly).isEmpty)
        for flag in ["--hold-out-acc", "--seed", "--particles", "--as-live", "--file-order", "--tolerance",
                     "--heading-tolerance", "--pin-pair-window", "--wrong-road-tolerance", "--fixpin-inject"] {
            #expect(FixOffsetScan.refusedFlags(["--fix-offset", flag]) == [flag])
        }
    }

    /// R49.1-1: the refused set is exactly the list docs/NAVIGATION.md gives
    /// ("replay_nav", `--fix-offset`), written out here: "--compare and its
    /// tolerances" and "--fixpin-*" as `replay_nav` spells them. A member
    /// dropped from (or added to) `engineOnlyFlags` fails here.
    @Test func engineOnlyFlagsAreTheDocumentedList() {
        let documented: Set<String> = [
            "--gps", "--hold-out-acc", "--truth", "--seed", "--particles", "--set", "--out", "--as-live", "--file-order",
            "--compare", "--tolerance", "--heading-tolerance", "--write-sidecar", "--pin-pair-window",
            "--wrong-road-tolerance",
            "--fixpin-inject", "--fixpin-two-pins", "--fixpin-survey", "--fixpin-pins", "--fixpin-separation",
            "--fixpin-engine-no-roads",
        ]
        #expect(FixOffsetScan.engineOnlyFlags == documented,
                "missing \(documented.subtracting(FixOffsetScan.engineOnlyFlags).sorted()), extra \(FixOffsetScan.engineOnlyFlags.subtracting(documented).sorted())")
        for flag in documented.sorted() {
            #expect(FixOffsetScan.refusedFlags(["--fix-offset", "--roads", flag]) == [flag], "\(flag)")
        }
        #expect(documented.filter { $0.hasPrefix("--fixpin-") }.count == 6)
    }

    @Test func distancesAreCappedAndTheCourseGateSkipsCrossingRoads() throws {
        let net = try Self.network()
        let plane = LocalTangentPlane(latitude: 0, longitude: 0)
        let field = RoadField(roads: net, plane: plane, points: [(0, 0)], marginM: 1_000, capM: 100)
        // 5 m north of the first (east-running) segment.
        #expect(abs(field.distance(east: -260, north: -195) - 5) < 0.1)
        // Moving north there, the east-running segments do not count; the
        // diagonal one (course ~18°) does, nearest at its start corner
        // (-200, -200): √(60² + 5²) ≈ 60.2 m, below the cap.
        let north = (0.0, 1.0)
        let gated = field.distance(east: -260, north: -195, course: north, minAbsCos: cos(30 * .pi / 180))
        #expect(abs(gated - (60.0 * 60 + 5 * 5).squareRoot()) < 0.5)
        // Far from every road: the cap.
        #expect(field.distance(east: 2_000, north: 2_000) == 100)
    }

    /// Cells are floor(v / capM) from the (0, 0) anchor: each road below is
    /// listed only in a cell next to its query point's, never in it.
    @Test func distancesSearchTheNeighbouringCells() throws {
        let net = try RoadNetwork(packs: [RoadFixture.build([
            // East-running at north 105 (cell y 1) and at north −105 (cell y −2).
            RoadFixture.way(1, ["highway": "residential"], [N(id: 10, east: -50, north: 105), N(id: 11, east: 250, north: 105)]),
            RoadFixture.way(2, ["highway": "residential"], [N(id: 20, east: -50, north: -105), N(id: 21, east: 250, north: -105)]),
            // A short north-running stub inside cell (6, 6) only.
            RoadFixture.way(3, ["highway": "residential"], [N(id: 30, east: 605, north: 605), N(id: 31, east: 605, north: 650)]),
        ])])
        let points: [(east: Double, north: Double)] = [(50, 95), (50, -95), (595, 595)]
        let field = RoadField(roads: net, plane: LocalTangentPlane(latitude: 0, longitude: 0), points: points,
                              marginM: 1_000, capM: 100)
        // Cell (0, 0), road in (0, 1).
        #expect(abs(field.distance(east: 50, north: 95) - 10) < 0.1)
        // Cell (0, −1), road in (0, −2).
        #expect(abs(field.distance(east: 50, north: -95) - 10) < 0.1)
        // Diagonal: cell (5, 5), stub in (6, 6), nearest at its end (605, 605).
        #expect(abs(field.distance(east: 595, north: 595) - 200.0.squareRoot()) < 0.1)
    }

    @Test func tooFewFixesAreNotScanned() throws {
        #expect(FixOffsetScan.scan(Array(Self.track().prefix(4)), roads: try Self.network(), options: Self.fast) == nil)
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

    /// R35.1-2: each OBD reply's speed is held until the next one, at most
    /// 2 s: an adapter gap is not integrated at the last speed. Fixes 0–20 s
    /// along a straight line at 10 m/s; replies (10 m/s) at −1.5 s, then
    /// every 0.5 s over 3–5 s and 12–20.5 s. Counted: 0–0.5 s (the −1.5 s
    /// reply's 2 s hold), 3–7 s (the 5 s reply held 2 s), 12–20 s: 125 m.
    /// Without the cap the gaps are filled: 200 m.
    @Test func dynamicsHoldsAnOBDReplyAtMostTwoSeconds() {
        let fixes = (0...20).map { i in
            let q = RoadFixture.point(Double(i) * 10, 0)
            return FixOffsetScan.Fix(t: Double(i), latitude: q.latitude, longitude: q.longitude, accuracyM: 10, speed: 10, course: 90)
        }
        let obd = [(t: -1.5, mps: 10.0)]
            + stride(from: 3.0, through: 5.0, by: 0.5).map { (t: $0, mps: 10.0) }
            + stride(from: 12.0, through: 20.5, by: 0.5).map { (t: $0, mps: 10.0) }
        let d = FixOffsetScan.dynamics(fixes, obdSpeed: obd, yawRate: [])
        #expect(abs(d.fixPathM - 200) < 0.5)
        #expect(abs(try! #require(d.obdDistanceM) - 125) < 1e-6, "\(String(describing: d.obdDistanceM))")
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
