import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// REL-DEMO: the bundled demo pack, the demo loop over it and the pack's
/// road polylines. The pack is read from the repository (`#filePath`); no
/// coordinates appear here, only distances, speeds and counts. Synthetic
/// router fixtures are near (0, 0).
@Suite("Demo drive (REL-DEMO)")
struct DemoDriveTests {
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let packURL = repositoryRoot.appendingPathComponent("App/Resources/Demo/demo.roadpack")

    static func pack() throws -> RoadPack { try DemoRoadPack.open(at: packURL) }

    /// One drive for the suite's read-only checks.
    static let shared: (pack: RoadPack, drive: DemoDrive, network: RoadNetwork)? = {
        guard let pack = try? pack(), let drive = try? DemoDrive(pack: pack),
              let network = try? RoadNetwork(packs: [pack]) else { return nil }
        return (pack, drive, network)
    }()

    static func fixture() throws -> (pack: RoadPack, drive: DemoDrive, network: RoadNetwork) {
        try #require(shared, "the bundled demo pack opens and the demo loop builds")
    }

    /// Distance from a position to the nearest pack segment, m.
    static func distanceToRoad(_ latitude: Double, _ longitude: Double, _ network: RoadNetwork) -> Double {
        let plane = LocalTangentPlane(latitude: latitude, longitude: longitude)
        var best = Double.infinity
        for ref in network.segments(nearLatitude: latitude, longitude: longitude) {
            let segment = network.segment(ref)
            let a = plane.enu(latitude: segment.a.latitude, longitude: segment.a.longitude)
            let b = plane.enu(latitude: segment.b.latitude, longitude: segment.b.longitude)
            best = min(best, RoadGeometry.project(px: 0, py: 0, ax: a.east, ay: a.north, bx: b.east, by: b.north).distance)
        }
        return best
    }

    /// States over one lap every `step` seconds.
    static func lap(_ drive: DemoDrive, step: Double) -> [DemoDriveState] {
        stride(from: 0.0, to: drive.lapDurationS, by: step).map { drive.state(at: $0) }
    }

    static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    // MARK: Pack

    @Test("The bundled demo pack: under 1 MB, verifies, is the pack the route was designed on, carries the OSM attribution")
    func bundledPack() throws {
        let size = try #require(try FileManager.default.attributesOfItem(atPath: Self.packURL.path)[.size] as? Int)
        #expect(size < 1_000_000)
        let pack = try Self.pack()
        #expect(pack.contentHash == DemoRoadPack.contentHash)
        #expect(pack.fileSize == size)
        #expect(pack.info.attribution == "© OpenStreetMap contributors")
        #expect(pack.info.license == "ODbL 1.0")
        // A small area: a few km across.
        let bounds = try #require(pack.pointBounds())
        let diagonal = RoadGeometry.distanceM(from: bounds.southWest, to: bounds.northEast)
        #expect(diagonal > 2000 && diagonal < 6000)
        // Every drivable class of a region pack was asked for.
        guard case .object(let meta)? = pack.info.meta, case .object(let parameters)? = meta["parameters"],
              case .array(let classes)? = parameters["highwayClasses"] else {
            Issue.record("META has no parameters.highwayClasses")
            return
        }
        #expect(classes.count == RoadGraphBuilder.regionClasses.count)
    }

    @Test("DemoRoadPack.open refuses a valid pack that is not the bundled one")
    func openRefusesAnotherPack() throws {
        let data = try RoadFixture.buildData([
            RoadFixture.way(1, ["highway": "residential"], [
                RoadFixture.Node(id: 1, east: 0, north: 0), RoadFixture.Node(id: 2, east: 0, north: 100),
            ]),
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString).roadpack")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let other = try RoadPack(data: data)
        #expect(throws: DemoDriveError.unexpectedPack(contentHash: other.contentHash)) { try DemoRoadPack.open(at: url) }
    }

    @Test("DemoRoadPack.url finds demo.roadpack in a bundle and is nil when the bundle has none")
    func bundleLookup() throws {
        // Two directories: Bundle caches an instance (and its listing) per path.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("demo-bundles-\(UUID().uuidString)")
        let emptyDirectory = base.appendingPathComponent("empty.bundle"), directory = base.appendingPathComponent("demo.bundle")
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let empty = try #require(Bundle(path: emptyDirectory.path))
        #expect(DemoRoadPack.url(in: empty) == nil)
        try FileManager.default.copyItem(at: Self.packURL, to: directory.appendingPathComponent("demo.roadpack"))
        let bundle = try #require(Bundle(path: directory.path))
        let url = try #require(DemoRoadPack.url(in: bundle))
        #expect(try DemoRoadPack.open(at: url).contentHash == DemoRoadPack.contentHash)
    }

    // MARK: Route

    @Test("The loop: 4–6 km (pinned, so a routing change is seen), several left and right turns")
    func loop() throws {
        let (_, drive, _) = try Self.fixture()
        #expect(drive.lapLengthM > 4000 && drive.lapLengthM < 6000)
        #expect(abs(drive.lapLengthM - 5057.16) < 0.5, "lap \(drive.lapLengthM) m")
        #expect(drive.lapDurationS > 400 && drive.lapDurationS < 700)
        let turns = drive.path.pieces.filter { abs($0.turn) > 45 * Double.pi / 180 }
        #expect(turns.filter { $0.turn > 0 }.count >= 3, "right turns")
        #expect(turns.filter { $0.turn < 0 }.count >= 3, "left turns")
        // The road shape is a closed loop starting at the lap start.
        let shape = drive.roadShape
        #expect(shape.count > 100)
        #expect(RoadGeometry.distanceM(from: shape[0], to: shape[shape.count - 1]) < 0.05)
        let start = drive.state(at: 0)
        #expect(RoadGeometry.distanceM(from: shape[0], to: RoadPoint(latE7: Int32((start.latitude * 1e7).rounded()),
                                                                    lonE7: Int32((start.longitude * 1e7).rounded()))) < 0.05)
    }

    @Test("Deterministic: two independently built drives give equal states, any time, any lap, before the start too")
    func deterministic() throws {
        let a = try DemoDrive(pack: try Self.pack())
        let b = try DemoDrive(pack: try Self.pack())
        #expect(a.lapLengthM == b.lapLengthM && a.lapDurationS == b.lapDurationS)
        var t = -1234.5
        while t < 5 * a.lapDurationS {
            #expect(a.state(at: t) == b.state(at: t))
            t += 7.31
        }
    }

    @Test("Periodic and continuous at the wrap: the lap ends stopped where it starts, heading unchanged")
    func wrap() throws {
        let (_, drive, _) = try Self.fixture()
        let period = drive.lapDurationS
        let start = drive.state(at: 0)
        for end in [drive.state(at: period - 1e-6), drive.state(at: period - 1e-3)] {
            let d = drive.plane.enu(latitude: end.latitude, longitude: end.longitude)
            let s = drive.plane.enu(latitude: start.latitude, longitude: start.longitude)
            #expect(hypot(d.east - s.east, d.north - s.north) < 1e-3)
            #expect(abs(RoadGeometry.wrapPi((end.headingDeg - start.headingDeg) * .pi / 180)) < 1e-6)
            #expect(end.speedMps < 1e-3 && abs(end.accelerationMps2) < 1e-2 && abs(end.yawRateRadPerS) < 1e-6)
        }
        let next = drive.state(at: period)
        #expect(next.lap == 1 && next.lapTime == 0 && next.isStationary && next.activity == .startStop)
        #expect(abs(next.odometerM - drive.lapLengthM) < 1e-6)
        // Lap n repeats lap 0.
        for t in stride(from: 0.0, to: period, by: 3.7) {
            let a = drive.state(at: t), b = drive.state(at: t + 3 * period)
            #expect(b.lap == 3)
            #expect(abs(a.latitude - b.latitude) < 1e-9 && abs(a.longitude - b.longitude) < 1e-9)
            #expect(abs(a.speedMps - b.speedMps) < 1e-6)
            #expect(abs(b.odometerM - a.odometerM - 3 * drive.lapLengthM) < 1e-3)
        }
        let before = drive.state(at: -1)
        #expect(before.lap == -1 && abs(before.lapTime - (period - 1)) < 1e-9)
    }

    @Test("On the pack's roads: ≥ 95 % of the lap within 1 m of a pack segment, all of it within 4.5 m (junction corners)")
    func onRoads() throws {
        let (_, drive, network) = try Self.fixture()
        var within1 = 0.0, total = 0.0, worst = 0.0
        var previous: DemoDriveState?
        for state in Self.lap(drive, step: 0.1) {
            let d = Self.distanceToRoad(state.latitude, state.longitude, network)
            worst = max(worst, d)
            if let p = previous {
                let travelled = state.distanceAlongLapM - p.distanceAlongLapM
                total += travelled
                if d <= 1.0 { within1 += travelled }
            }
            previous = state
        }
        #expect(within1 / total >= 0.95, "\(within1 / total)")
        #expect(worst <= 4.5, "\(worst) m")
    }

    @Test("Speed, acceleration, jerk, yaw rate, lateral acceleration within plausible car limits; top speed ~50 km/h on a straight")
    func bounds() throws {
        let (_, drive, _) = try Self.fixture()
        let states = Self.lap(drive, step: 0.01)
        #expect(states.allSatisfy { $0.speedMps >= 0 && $0.speedMps <= 50 / 3.6 + 1e-6 })
        #expect(states.allSatisfy { abs($0.accelerationMps2) <= 2.5 })
        #expect(states.allSatisfy { abs($0.jerkMps3) <= 2.0 })
        #expect(states.allSatisfy { abs(Self.degrees($0.yawRateRadPerS)) <= 35 })
        #expect(states.allSatisfy { abs($0.lateralAccelerationMps2) <= 2.5 })
        #expect(states.allSatisfy { $0.headingDeg >= 0 && $0.headingDeg < 360 })
        // ≥ 49 km/h held for at least 10 s at a stretch somewhere.
        var run = 0.0, longest = 0.0
        for s in states {
            run = s.speedMps >= 49 / 3.6 ? run + 0.01 : 0
            longest = max(longest, run)
        }
        #expect(longest >= 10, "\(longest) s at ≥ 49 km/h")
        // Slows for turns: through every sharp turn below 20 km/h.
        for turn in drive.path.pieces where abs(turn.turn) > 60 * Double.pi / 180 {
            #expect(turn.speedLimit < 20 / 3.6)
        }
        #expect(states.contains { abs(Self.degrees($0.yawRateRadPerS)) > 15 }, "real turns, not only gentle bends")
    }

    @Test("Continuous and self-consistent: v = ds/dt, a = dv/dt, yaw rate = dψ/dt, position moves along the heading")
    func consistent() throws {
        let (_, drive, _) = try Self.fixture()
        let dt = 0.01
        var previous = drive.state(at: 0)
        var t = dt
        while t < drive.lapDurationS {
            let state = drive.state(at: t)
            let ds = state.distanceAlongLapM - previous.distanceAlongLapM
            let meanSpeed = (state.speedMps + previous.speedMps) / 2
            #expect(abs(ds - meanSpeed * dt) < 1e-4)
            #expect(abs(state.speedMps - previous.speedMps - (state.accelerationMps2 + previous.accelerationMps2) / 2 * dt) < 1e-4)
            #expect(abs(state.accelerationMps2 - previous.accelerationMps2) <= 2.0 * dt + 1e-9, "acceleration jumps at \(t)")
            let dHeading = RoadGeometry.wrapPi((state.headingDeg - previous.headingDeg) * .pi / 180)
            #expect(abs(dHeading - (state.yawRateRadPerS + previous.yawRateRadPerS) / 2 * dt) < 1e-4, "heading jumps at \(t)")
            let a = drive.plane.enu(latitude: previous.latitude, longitude: previous.longitude)
            let b = drive.plane.enu(latitude: state.latitude, longitude: state.longitude)
            #expect(abs(hypot(b.east - a.east, b.north - a.north) - ds) < 1e-4)
            if ds > 0.05 {
                let bearing = atan2(b.east - a.east, b.north - a.north)
                let mid = previous.headingDeg * .pi / 180 + dHeading / 2
                #expect(abs(RoadGeometry.wrapPi(bearing - mid)) < 0.01)
            }
            previous = state
            t += dt
        }
    }

    @Test("Stationary 5 s at the start of every lap, one full stop of 8–12 s at a junction, moving otherwise")
    func stops() throws {
        let (pack, drive, _) = try Self.fixture()
        #expect(drive.startDwellS == 5)
        #expect(drive.stationaryIntervals.count == 2)
        let start = try #require(drive.stationaryIntervals.first)
        #expect(start.lowerBound == 0 && start.upperBound == 5)
        let first = drive.state(at: 0)
        for t in stride(from: 0.0, through: 5.0, by: 0.05) {
            let s = drive.state(at: t)
            #expect(s.speedMps == 0 && s.isStationary && s.activity == .startStop)
            #expect(s.latitude == first.latitude && s.longitude == first.longitude && s.headingDeg == first.headingDeg)
        }
        let stop = try #require(drive.stationaryIntervals.last)
        let duration = stop.upperBound - stop.lowerBound
        #expect(duration >= 8 && duration <= 12)
        #expect(stop.lowerBound > 30, "the stop comes after a stretch of driving")
        let atStop = drive.state(at: stop.lowerBound)
        for t in stride(from: stop.lowerBound, through: stop.upperBound, by: 0.05) {
            let s = drive.state(at: t)
            #expect(s.speedMps == 0 && s.activity == .junctionStop)
            #expect(s.latitude == atStop.latitude && s.longitude == atStop.longitude)
        }
        // The stop is at a junction: a pack node with three or more edges
        // within 15 m.
        let plane = LocalTangentPlane(latitude: atStop.latitude, longitude: atStop.longitude)
        let junctionNear = (0..<pack.nodeCount).contains { n in
            guard pack.incidentEdges(n).count >= 3 else { return false }
            let p = plane.enu(latitude: pack.node(n).latitude, longitude: pack.node(n).longitude)
            return hypot(p.east, p.north) < 15
        }
        #expect(junctionNear)
        // Moving everywhere else (the approach to a stop included).
        let moving = Self.lap(drive, step: 0.05).filter { s in
            !drive.stationaryIntervals.contains { $0.contains(s.lapTime) }
        }
        #expect(moving.allSatisfy { $0.speedMps > 0 && $0.activity == .driving })
    }

    // MARK: Router (synthetic)

    @Test("The router keeps oneway direction and never uses service roads; nil without a legal path")
    func router() throws {
        typealias N = RoadFixture.Node
        // A square block, 1 → 2 → 3 → 4 → 1, 200 m sides. Side 1–2 is oneway
        // 2 → 1; a service road gives a short cut 1 → 3.
        let pack = try RoadFixture.build([
            RoadFixture.way(10, ["highway": "residential", "oneway": "yes"], [N(id: 2, east: 0, north: 200), N(id: 1, east: 0, north: 0)]),
            RoadFixture.way(11, ["highway": "residential"], [N(id: 2, east: 0, north: 200), N(id: 3, east: 200, north: 200)]),
            RoadFixture.way(12, ["highway": "residential"], [N(id: 3, east: 200, north: 200), N(id: 4, east: 200, north: 0)]),
            RoadFixture.way(13, ["highway": "residential"], [N(id: 4, east: 200, north: 0), N(id: 1, east: 0, north: 0)]),
            RoadFixture.way(14, ["highway": "service"], [N(id: 1, east: 0, north: 0), N(id: 3, east: 200, north: 200)]),
        ])
        func node(_ way: Int64, _ index: UInt32) throws -> Int {
            guard let n = DemoRouter.node(of: .init(osmWayID: way, pointIndex: index), in: pack) else {
                throw DemoDriveError.viaNotFound(index: Int(index))
            }
            return n
        }
        let one = try node(13, 1), two = try node(10, 0), three = try node(11, 1)
        #expect(DemoRouter.node(of: .init(osmWayID: 10, pointIndex: 7), in: pack) == nil)
        // 1 → 2: not up the oneway, round the block (3 sides).
        let path = try #require(DemoRouter.path(from: one, to: two, in: pack))
        #expect(path.map { pack.edge($0.edge).osmWayID } == [13, 12, 11])
        // 2 → 1: straight down the oneway.
        #expect(try #require(DemoRouter.path(from: two, to: one, in: pack)).map { pack.edge($0.edge).osmWayID } == [10])
        // 1 → 3 ignores the service road.
        #expect(try #require(DemoRouter.path(from: one, to: three, in: pack)).allSatisfy { pack.edge($0.edge).highwayClass != .service })
        // An isolated node: no path.
        let island = try RoadFixture.build([
            RoadFixture.way(20, ["highway": "residential", "oneway": "yes"], [N(id: 1, east: 0, north: 0), N(id: 2, east: 0, north: 100)]),
        ])
        let a = try #require(DemoRouter.node(of: .init(osmWayID: 20, pointIndex: 0), in: island))
        let b = try #require(DemoRouter.node(of: .init(osmWayID: 20, pointIndex: 1), in: island))
        #expect(DemoRouter.path(from: b, to: a, in: island) == nil)
        #expect(DemoRouter.path(from: a, to: a, in: island) == [])
    }

    // MARK: Overlay

    @Test("RoadPack.polylines: every segment drawn exactly once, ways joined, class filter")
    func polylines() throws {
        let (pack, _, _) = try Self.fixture()
        let all = pack.polylines()
        #expect(all.allSatisfy { $0.points.count >= 2 })
        #expect(all.reduce(0) { $0 + $1.points.count - 1 } == pack.segmentCount)
        #expect(all.count < pack.edgeCount, "consecutive edges of a way are joined")
        #expect(all.count < 5000, "cheap to draw")
        let main: Set<RoadClass> = [.primary, .secondary, .tertiary]
        let filtered = pack.polylines(classes: main)
        #expect(!filtered.isEmpty && filtered.allSatisfy { main.contains($0.highwayClass) })
        var expected = 0
        for e in 0..<pack.edgeCount where main.contains(pack.edge(e).highwayClass) { expected += Int(pack.edge(e).pointCount) - 1 }
        #expect(filtered.reduce(0) { $0 + $1.points.count - 1 } == expected)
    }

    @Test("Polylines join only contiguous edges of one way (synthetic)")
    func polylinesJoin() throws {
        typealias N = RoadFixture.Node
        // Way 5 is split at node 2 by way 6: two edges, one polyline.
        let pack = try RoadFixture.build([
            RoadFixture.way(5, ["highway": "residential"], [N(id: 1, east: 0, north: 0), N(id: 2, east: 0, north: 100), N(id: 3, east: 0, north: 200)]),
            RoadFixture.way(6, ["highway": "primary", "oneway": "yes"], [N(id: 2, east: 0, north: 100), N(id: 4, east: 100, north: 100)]),
        ])
        #expect(pack.edgeCount == 3)
        let lines = pack.polylines()
        #expect(lines.count == 2)
        let five = try #require(lines.first { $0.osmWayID == 5 })
        #expect(five.points == [RoadFixture.point(0, 0), RoadFixture.point(0, 100), RoadFixture.point(0, 200)])
        #expect(!five.isOneway && five.highwayClass == .residential)
        let six = try #require(lines.first { $0.osmWayID == 6 })
        #expect(six.isOneway && six.highwayClass == .primary && six.points.count == 2)
        #expect(pack.polylines(classes: [.primary]).map(\.osmWayID) == [6])
    }
}
