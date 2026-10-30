import Foundation
import Testing

@testable import DriveLoggerCore

/// `PinSnap` (prompt 46 Part B): the snapping geometry on synthetic roads
/// near (0, 0) (`RoadFixture`), in local metres. No real place.
@Suite("Pin snap")
struct PinSnapTests {
    typealias Node = RoadFixture.Node

    /// The reference viewport height (points) used with these spans.
    static let viewport = 852.0

    static func network(_ lines: [String]) throws -> RoadNetwork {
        try RoadNetwork(packs: [RoadFixture.build(lines)])
    }

    static func degrees(_ east: Double, _ north: Double) -> (latitude: Double, longitude: Double) {
        let k = RoadFixture.metresPerE7
        return (north / k.lat / 1e7, east / k.lon / 1e7)
    }

    static func metres(latitude: Double, longitude: Double) -> (east: Double, north: Double) {
        let k = RoadFixture.metresPerE7
        return (longitude * 1e7 * k.lon, latitude * 1e7 * k.lat)
    }

    static func snap(
        _ east: Double, _ north: Double, span: Double?, network: RoadNetwork?, cloud: [PinSnap.Particle]? = nil
    ) -> PinSnap.Outcome {
        let p = degrees(east, north)
        return PinSnap.snap(latitude: p.latitude, longitude: p.longitude, mapSpanM: span,
                            viewportHeightPt: viewport, network: network, cloud: cloud)
    }

    /// `count` equal-weight particles at (east, north) with `headingDeg`.
    static func cloud(_ east: Double, _ north: Double, headingDeg: Double, count: Int = 10) -> [PinSnap.Particle] {
        let p = degrees(east, north)
        return (0..<count).map { _ in
            PinSnap.Particle(latitude: p.latitude, longitude: p.longitude, headingRad: headingDeg * .pi / 180,
                             weight: 1 / Double(count))
        }
    }

    static func expectAt(_ snap: PinSnap.Snap?, _ east: Double, _ north: Double, tolerance: Double = 0.05,
                         sourceLocation: SourceLocation = #_sourceLocation) {
        guard let snap else {
            Issue.record("no snap", sourceLocation: sourceLocation)
            return
        }
        let m = metres(latitude: snap.latitude, longitude: snap.longitude)
        #expect(abs(m.east - east) <= tolerance && abs(m.north - north) <= tolerance,
                "at \(m.east), \(m.north)", sourceLocation: sourceLocation)
    }

    static let road: [String: String] = ["highway": "residential"]

    /// One east-west road along north = 0.
    static func straight() throws -> RoadNetwork {
        try network([RoadFixture.way(1, Self.road, [Node(id: 1, east: -500, north: 0), Node(id: 2, east: 500, north: 0)])])
    }

    // MARK: Radius

    @Test("Radius: points × span / viewport height; σ = max(30, span / 12); unusable inputs give nil")
    func radius() {
        #expect(PinSnap.radiusM(points: 44, mapSpanM: 852, viewportHeightPt: 852) == 44)
        let r = PinSnap.radiusM(points: 44, mapSpanM: 1500, viewportHeightPt: 852)
        #expect(abs((r ?? 0) - 77.464788) < 1e-5)
        #expect(PinSnap.radiusM(points: 8, mapSpanM: 426, viewportHeightPt: 852) == 4)
        for span in [nil, 0, -1, Double.nan, .infinity] as [Double?] {
            #expect(PinSnap.radiusM(points: 44, mapSpanM: span, viewportHeightPt: 852) == nil)
        }
        #expect(PinSnap.radiusM(points: 44, mapSpanM: 1000, viewportHeightPt: 0) == nil)
        #expect(PinSnap.sigmaM(mapSpanM: 1500) == 125)
        #expect(PinSnap.sigmaM(mapSpanM: 300) == 30)
        #expect(PinSnap.sigmaM(mapSpanM: nil) == 30)
        #expect(PinSnap.sigmaM(mapSpanM: 600) == 50)
    }

    // MARK: Nearest edge

    @Test("Nearest edge: the foot of the perpendicular, within the radius at this zoom only")
    func nearestEdge() throws {
        let net = try Self.straight()
        let o = Self.snap(100, 20, span: 1500, network: net)
        guard case .edge(let s) = o.result else { Issue.record("\(o.result)"); return }
        Self.expectAt(s, 100, 0)
        #expect(abs(s.distanceM - 20) < 0.05)
        #expect(s.decision == .onlyRoad)
        #expect(s.candidate.osmWayID == 1)
        #expect(abs(s.candidate.bearingDeg - 90) < 0.01)
        #expect(o.nearest?.edge == s.candidate.edge)
        // 20 m is outside 44 pt at a 300 m span (15.5 m) and 77.5 m at 1500.
        #expect(Self.snap(100, 20, span: 300, network: net).result == .noEdgeInRadius)
        #expect(Self.snap(100, 15, span: 300, network: net).result.snap != nil)
        #expect(Self.snap(100, 78, span: 1500, network: net).result == .noEdgeInRadius)
        #expect(Self.snap(100, 77, span: 1500, network: net).result.snap != nil)
        // No usable span: no radius, no snap.
        #expect(Self.snap(100, 1, span: nil, network: net).result == .noEdgeInRadius)
    }

    @Test("A radius wider than a grid cell finds an edge several cells away")
    func radiusAcrossCells() throws {
        let net = try Self.straight()
        // 6000 m span: 44 pt = 310 m, about 5 cells of 64 m.
        let o = Self.snap(37, 290, span: 6000, network: net)
        Self.expectAt(o.result.snap, 37, 0)
    }

    @Test("No network: noNetwork, whatever the tap")
    func noNetwork() {
        #expect(Self.snap(0, 0, span: 1000, network: nil).result == .noNetwork)
        #expect(Self.snap(0, 0, span: 1000, network: nil, cloud: Self.cloud(0, 0, headingDeg: 0)).result == .noNetwork)
    }

    @Test("Non-drivable ways are not in the graph: a footway nearer the tap is ignored")
    func nonDrivableIgnored() throws {
        let net = try Self.network([
            RoadFixture.way(1, ["highway": "footway"], [Node(id: 1, east: -300, north: 5), Node(id: 2, east: 300, north: 5)]),
            RoadFixture.way(2, Self.road, [Node(id: 3, east: -300, north: -20), Node(id: 4, east: 300, north: -20)]),
        ])
        let o = Self.snap(0, 3, span: 1500, network: net)
        guard case .edge(let s) = o.result else { Issue.record("\(o.result)"); return }
        #expect(s.candidate.osmWayID == 2)
        #expect(s.decision == .onlyRoad)
        Self.expectAt(s, 0, -20)
        // Only the footway in reach: nothing to snap to.
        #expect(Self.snap(0, 70, span: 1500, network: net).result == .noEdgeInRadius)
    }

    // MARK: Junction

    /// Two roads crossing at grade: way 1 east-west, way 2 north-south,
    /// sharing node 10 at (0, 0).
    static func crossing() throws -> RoadNetwork {
        try network([
            RoadFixture.way(1, Self.road, [Node(id: 1, east: -300, north: 0), Node(id: 10, east: 0, north: 0),
                                      Node(id: 2, east: 300, north: 0)]),
            RoadFixture.way(2, Self.road, [Node(id: 3, east: 0, north: -300), Node(id: 10, east: 0, north: 0),
                                      Node(id: 4, east: 0, north: 300)]),
        ])
    }

    @Test("Junction: within 8 pt of a shared node → the node; beyond, the nearer road if clearly nearer, else ambiguous")
    func junctionNode() throws {
        let net = try Self.crossing()
        // 1500 m span: 8 pt = 14.08 m.
        let o = Self.snap(5, 6, span: 1500, network: net)
        guard case .node(let s) = o.result else { Issue.record("\(o.result)"); return }
        Self.expectAt(s, 0, 0, tolerance: 0.01)
        #expect(s.decision == .junction)
        #expect(abs(s.distanceM - (25.0 + 36.0).squareRoot()) < 0.05)
        // 13.9 m from the node: still the node; 14.2 m: not.
        if case .node = Self.snap(13.9, 0.5, span: 1500, network: net).result {} else { Issue.record("13.9 m") }
        let beyond = Self.snap(14.2, 0.5, span: 1500, network: net)
        guard case .edge(let e) = beyond.result else { Issue.record("\(beyond.result)"); return }
        #expect(e.candidate.osmWayID == 1 && e.decision == .clearlyNearer)
        Self.expectAt(e, 14.2, 0)
        // At 300 m span 8 pt is 2.8 m: (5, 6) is a contested corner, 6 vs 5 m;
        // the two points are 7.8 m apart (≤ σ/2 = 15 m): the nearer road.
        let corner = Self.snap(5, 6, span: 300, network: net)
        #expect(corner.result.snap?.candidate.osmWayID == 2 && corner.result.snap?.decision == .closeRoads)
        #expect(corner.contested.map(\.osmWayID) == [2, 1])
    }

    @Test("Edges of one road meeting at a node are not rivals: a continuation way ends where the tap's road does")
    func sameRoadAtJunction() throws {
        // One road split into two ways at node 10 (no side road).
        let net = try Self.network([
            RoadFixture.way(1, Self.road, [Node(id: 1, east: -300, north: 0), Node(id: 10, east: 0, north: 0)]),
            RoadFixture.way(3, Self.road, [Node(id: 10, east: 0, north: 0), Node(id: 2, east: 300, north: 0)]),
        ])
        // Way 1 at 10 m; way 3's nearest point is the shared node at 15.6 m
        // (< 2 × 10 m, and outside the 14.1 m junction radius).
        let o = Self.snap(-12, 10, span: 1500, network: net)
        guard case .edge(let s) = o.result else { Issue.record("\(o.result)"); return }
        #expect(s.candidate.osmWayID == 1)
        #expect(s.decision == .onlyRoad)
        #expect(o.contested.isEmpty)
        Self.expectAt(s, -12, 0)
    }

    @Test("R84.1-4: a continuation way drawn toward the shared node (its `to` end) is not a rival either")
    func sameRoadAtJunctionToEnd() throws {
        // Way 3 drawn from (300, 0) to the shared node: its nearest point to
        // the tap is its last point, the `to` end node.
        let net = try Self.network([
            RoadFixture.way(1, Self.road, [Node(id: 1, east: -300, north: 0), Node(id: 10, east: 0, north: 0)]),
            RoadFixture.way(3, Self.road, [Node(id: 2, east: 300, north: 0), Node(id: 10, east: 0, north: 0)]),
        ])
        let o = Self.snap(-12, 10, span: 1500, network: net)
        guard case .edge(let s) = o.result else { Issue.record("\(o.result)"); return }
        #expect(s.candidate.osmWayID == 1)
        #expect(s.decision == .onlyRoad, "way 3 ends at a node of way 1: no rival, no close-roads contest")
        #expect(o.contested.isEmpty)
        Self.expectAt(s, -12, 0)
    }

    @Test("R84.1-4: a side road drawn toward the junction on the through road is not a rival when its nearest point is that junction")
    func sideRoadToEndAtJunction() throws {
        // Through road N (way 1) east-west through J = (0, 0); side road S
        // (way 2) drawn from the south toward J, so J is S's `to` end.
        let net = try Self.network([
            RoadFixture.way(1, Self.road, [Node(id: 1, east: -300, north: 0), Node(id: 10, east: 0, north: 0),
                                           Node(id: 2, east: 300, north: 0)]),
            RoadFixture.way(2, Self.road, [Node(id: 3, east: 0, north: -300), Node(id: 10, east: 0, north: 0)]),
        ])
        // 1000 m span: radius 51.6 m, 8 pt = 9.4 m, σ/2 = 41.7 m. Tap 43 m
        // along N from J and 27 m off it: N at 27 m; S's nearest point is J
        // at 50.8 m (< 2 × 27 m, and 43 m from N's point: not close roads).
        // J is a node of N's way, so S is no rival and N wins outright; were
        // J not seen as S's end node, S would be contested and the tap
        // ambiguous.
        let o = Self.snap(43, 27, span: 1000, network: net)
        guard case .edge(let s) = o.result else { Issue.record("\(o.result)"); return }
        #expect(s.candidate.osmWayID == 1)
        #expect(s.decision == .onlyRoad)
        #expect(o.contested.isEmpty)
        Self.expectAt(s, 43, 0)
    }

    @Test("R84.1-3: a dead end within 8 pt is not a junction: the node must end at least two candidate edges")
    func deadEndIsNotAJunction() throws {
        // Through road A (way 1) on north = 0; road B (way 2) ends at (5, 10)
        // and runs north from there.
        let net = try Self.network([
            RoadFixture.way(1, Self.road, [Node(id: 1, east: -300, north: 0), Node(id: 2, east: 300, north: 0)]),
            RoadFixture.way(2, Self.road, [Node(id: 3, east: 5, north: 10), Node(id: 4, east: 5, north: 300)]),
        ])
        // 1500 m span: 8 pt = 14.1 m. Tap 3 m from A; B's dead end 7 m away.
        let o = Self.snap(5, 3, span: 1500, network: net)
        guard case .edge(let s) = o.result else { Issue.record("expected an edge, got \(o.result)"); return }
        #expect(s.candidate.osmWayID == 1 && s.decision == .clearlyNearer)
        Self.expectAt(s, 5, 0)
    }

    /// A through road on north = 0 with side roads north from junctions at
    /// east = `a` and east = `b`.
    static func twoJunctions(_ a: Double, _ b: Double) throws -> RoadNetwork {
        try network([
            RoadFixture.way(1, Self.road, [Node(id: 1, east: -300, north: 0), Node(id: 10, east: a, north: 0),
                                           Node(id: 11, east: b, north: 0), Node(id: 2, east: 300, north: 0)]),
            RoadFixture.way(2, Self.road, [Node(id: 10, east: a, north: 0), Node(id: 3, east: a, north: 300)]),
            RoadFixture.way(3, Self.road, [Node(id: 11, east: b, north: 0), Node(id: 4, east: b, north: 300)]),
        ])
    }

    @Test("R84.2-1: two junction nodes within 8 pt: the nearer one wins")
    func nearestJunctionWins() throws {
        let net = try Self.twoJunctions(0, 40)
        // 6000 m span: 8 pt = 56.3 m, both junctions in reach.
        let west = Self.snap(12, 5, span: 6000, network: net)  // 13.0 m vs 28.4 m
        guard case .node(let w) = west.result else { Issue.record("\(west.result)"); return }
        Self.expectAt(w, 0, 0, tolerance: 0.01)
        let east = Self.snap(30, 5, span: 6000, network: net)  // 30.4 m vs 11.2 m
        guard case .node(let e) = east.result else { Issue.record("\(east.result)"); return }
        Self.expectAt(e, 40, 0, tolerance: 0.01)
    }

    @Test("R84.2-1: two junction nodes exactly equidistant: the smaller node key wins (the east one here, positive longitude)")
    func equidistantJunctionsTieBreak() throws {
        // Nodes at ±20 m east: their E7 longitudes are exact negatives, so a
        // tap on east = 0 is exactly as far from both.
        let net = try Self.twoJunctions(-20, 20)
        let west = RoadFixture.point(-20, 0), east = RoadFixture.point(20, 0)
        #expect(west.lonE7 == -east.lonE7 && west.latE7 == east.latE7)
        #expect(PinSnap.key(east) < PinSnap.key(west))
        let o = Self.snap(0, 5, span: 6000, network: net)
        guard case .node(let n) = o.result else { Issue.record("\(o.result)"); return }
        #expect(abs(n.distanceM - (400.0 + 25).squareRoot()) < 0.05)
        Self.expectAt(n, 20, 0, tolerance: 0.01)
    }

    @Test("R84.2-2: the engine's own cloud carries its heading: driving east on the eastbound carriageway, a tap between the carriageways snaps to it")
    func engineCloudHeadingPicksCarriageway() throws {
        let net = try Self.carriageways()
        // 40 s east at 10 m/s along way 1 (north = 0, eastbound one-way),
        // clean fixes with course, OBD speed.
        let drive = SyntheticDrive(initialHeadingDeg: 90, initialSpeed: 10, [.straight(seconds: 40, speed: 10)])
        var engine = NavigationEngine(config: SyntheticDrive.config(), roads: net)
        for input in SyntheticDrive.inputs(drive.events(fix: SyntheticDrive.cleanFix())) { engine.ingest(input) }
        let end = drive.truth(at: drive.duration)
        let estimate = try #require(engine.estimate(at: SyntheticDrive.ms(drive.duration)))
        #expect(abs(angleDifference(estimate.headingDeg, 90)) < 5, "engine heading \(estimate.headingDeg)")
        // The cloud's weighted circular mean heading is the estimate's.
        let cloud = try #require(engine.pinSnapCloud())
        let s = cloud.reduce(0) { $0 + $1.weight * sin($1.headingRad) }
        let c = cloud.reduce(0) { $0 + $1.weight * cos($1.headingRad) }
        #expect(abs(angleDifference(atan2(s, c) * 180 / .pi, estimate.headingDeg)) < 0.01)
        // Tap 17.7 m north of the car: way 1 at 17.7 m, way 2 (westbound) at
        // 26.3 m; 600 m span (σ/2 25 m < 44 m apart): the cloud decides.
        let tap = SyntheticDrive.plane.geodetic(east: end.east, north: 17.7)
        let o = engine.snapPin(latitude: tap.latitude, longitude: tap.longitude, mapSpanM: 600, viewportHeightPt: 852)
        guard case .edge(let snap) = o.result else { Issue.record("\(o.result) support \(o.support)"); return }
        #expect(snap.candidate.osmWayID == 1 && snap.decision == .cloud)
        #expect(o.support.count == 2 && o.support[0] > 0.9 && o.support[1] < 0.05, "\(o.support)")
    }

    @Test("R84.3-1: a side road whose nearest point is a junction on another edge of N's way is no rival")
    func sideRoadAtJunctionOnAnotherEdgeOfN() throws {
        // Way 1 split at J1 (10, 0) and J2 (63, 0); side roads north from both.
        let net = try Self.network([
            RoadFixture.way(1, Self.road, [Node(id: 1, east: -300, north: 0), Node(id: 10, east: 10, north: 0),
                                           Node(id: 11, east: 63, north: 0), Node(id: 2, east: 300, north: 0)]),
            RoadFixture.way(2, Self.road, [Node(id: 10, east: 10, north: 0), Node(id: 3, east: 10, north: 300)]),
            RoadFixture.way(3, Self.road, [Node(id: 11, east: 63, north: 0), Node(id: 4, east: 63, north: 300)]),
        ])
        // 1500 m span. N = way 1's west edge at 40 m (foot (0, 0)); way 3's
        // nearest point is J2 at 74.6 m (< 2 × 40 m, 63 m from N's point:
        // more than σ/2 = 62.5 m), a node of way 1's other edge.
        let o = Self.snap(0, -40, span: 1500, network: net)
        guard case .edge(let s) = o.result else { Issue.record("\(o.result) \(o.contested.map(\.osmWayID))"); return }
        #expect(s.candidate.osmWayID == 1 && s.decision == .onlyRoad)
        #expect(o.contested.isEmpty)
        Self.expectAt(s, 0, 0)
    }

    @Test("A junction snap reports the nearest edge that ends at the node")
    func junctionReportsNearestEdge() throws {
        let net = try Self.crossing()
        // Tap (5, 2) at 1500 m: the node (0, 0) is 5.4 m away; of the four
        // edges ending there, way 1's east edge is nearest (2 m).
        let o = Self.snap(5, 2, span: 1500, network: net)
        guard case .node(let n) = o.result else { Issue.record("\(o.result)"); return }
        #expect(n.candidate.osmWayID == 1)
        #expect(abs(n.candidate.distanceM - 2) < 0.05)
        #expect(n.candidate.edge == o.nearest?.edge)
    }

    @Test("A tap exactly on an overpass crossing (0 m from both roads): contested, then close roads, not 'clearly nearer'")
    func tapOnCrossingIsContested() throws {
        let net = try Self.network([
            RoadFixture.way(1, Self.road, [Node(id: 1, east: -300, north: 0), Node(id: 2, east: 300, north: 0)]),
            RoadFixture.way(2, ["highway": "primary", "bridge": "yes", "layer": "1"],
                            [Node(id: 3, east: 0, north: -300), Node(id: 4, east: 0, north: 300)]),
        ])
        let a = RoadFixture.point(0, 0)
        let o = PinSnap.snap(latitude: a.latitude, longitude: a.longitude, mapSpanM: 300, viewportHeightPt: Self.viewport,
                             network: net, cloud: nil)
        #expect(o.contested.count == 2, "\(o.contested.map(\.distanceM))")
        #expect(o.result.snap?.decision == .closeRoads)
    }

    @Test("One candidate per road: a rival way with two edges in reach is weighed once (else its own two edges would split the cloud's support)")
    func onePerRoadInTheContest() throws {
        // Way 1 on north = 0; way 2 on north = 20, split at (5, 20) by side
        // road way 3 going north. 300 m span: radius 15.5 m, σ 30 m.
        let net = try Self.network([
            RoadFixture.way(1, Self.road, [Node(id: 1, east: -300, north: 0), Node(id: 2, east: 300, north: 0)]),
            RoadFixture.way(2, Self.road, [Node(id: 3, east: -300, north: 20), Node(id: 10, east: 5, north: 20),
                                           Node(id: 4, east: 300, north: 20)]),
            RoadFixture.way(3, Self.road, [Node(id: 10, east: 5, north: 20), Node(id: 5, east: 5, north: 300)]),
        ])
        // Tap (0, 8): way 1 at 8 m, way 2's west edge at 12 m, its east edge
        // and way 3 at 13 m (both at the node (5, 20)).
        let alone = Self.snap(0, 8, span: 300, network: net)
        #expect(alone.result == .ambiguous)
        #expect(alone.contested.map(\.osmWayID) == [1, 2, 3])
        // A cloud 45 m north of way 2 heading east: only way 2 is supported
        // (way 1's point is 65 m away, way 3 runs north): way 2 by the cloud.
        let cloud = Self.snap(0, 8, span: 300, network: net, cloud: Self.cloud(0, 65, headingDeg: 90))
        #expect(cloud.contested.map(\.osmWayID) == [1, 2, 3])
        #expect(cloud.result.snap?.candidate.osmWayID == 2 && cloud.result.snap?.decision == .cloud, "\(cloud.support)")
    }

    // MARK: Ambiguity

    /// Two parallel east-west roads, 20 m apart (north = 0 and north = 20).
    static func parallel() throws -> RoadNetwork {
        try network([
            RoadFixture.way(1, Self.road, [Node(id: 1, east: -300, north: 0), Node(id: 2, east: 300, north: 0)]),
            RoadFixture.way(2, Self.road, [Node(id: 3, east: -300, north: 20), Node(id: 4, east: 300, north: 20)]),
        ])
    }

    @Test("Parallel roads: the nearer one when ≥ 2× nearer, else ambiguous without a cloud")
    func parallelRatio() throws {
        let net = try Self.parallel()
        // 6 vs 14 m: 2.33×.
        let clear = Self.snap(0, 6, span: 300, network: net)
        guard case .edge(let s) = clear.result else { Issue.record("\(clear.result)"); return }
        #expect(s.candidate.osmWayID == 1 && s.decision == .clearlyNearer)
        // Exactly 2×: 20/3 vs 40/3 m → clearly nearer (the ratio is inclusive).
        let edge = Self.snap(0, 20.0 / 3, span: 300, network: net)
        #expect(edge.result.snap?.candidate.osmWayID == 1)
        // 8 vs 12 m: contested.
        let close = Self.snap(0, 8, span: 300, network: net)
        #expect(close.result == .ambiguous)
        #expect(close.contested.map(\.osmWayID) == [1, 2])
        #expect(close.support.isEmpty)
        // From the other side, mirrored.
        #expect(Self.snap(0, 14, span: 300, network: net).result.snap?.candidate.osmWayID == 2)
        // Equidistant (10 / 10 m): contested.
        #expect(Self.snap(0, 10, span: 300, network: net).result == .ambiguous)
    }

    @Test("Parallel roads: the cloud decides with ≥ 2× support within 2σ and heading within 45°, either direction")
    func parallelCloud() throws {
        let net = try Self.parallel()
        // 300 m span: σ 30 m, reach 60 m. Tap 8 m from way 1, 12 m from way 2.
        // Particles 45 m south of way 1 (65 m from way 2's point): way 1 only.
        let south = Self.snap(0, 8, span: 300, network: net, cloud: Self.cloud(0, -45, headingDeg: 90))
        guard case .edge(let s) = south.result else { Issue.record("\(south.result)"); return }
        #expect(s.candidate.osmWayID == 1 && s.decision == .cloud)
        #expect(south.support.count == 2 && abs(south.support[0] - 1) < 1e-12 && south.support[1] == 0)
        // Westbound is as consistent as eastbound on a two-way road.
        #expect(Self.snap(0, 8, span: 300, network: net, cloud: Self.cloud(0, -45, headingDeg: 270)).result.snap?.candidate.osmWayID == 1)
        // 45° off is still consistent; 46° is not.
        #expect(Self.snap(0, 8, span: 300, network: net, cloud: Self.cloud(0, -45, headingDeg: 135)).result.snap != nil)
        #expect(Self.snap(0, 8, span: 300, network: net, cloud: Self.cloud(0, -45, headingDeg: 136)).result == .ambiguous)
        // The cloud picks the farther road: particles 45 m north of way 2.
        let north = Self.snap(0, 8, span: 300, network: net, cloud: Self.cloud(0, 65, headingDeg: 90))
        #expect(north.result.snap?.candidate.osmWayID == 2)
        #expect(north.result.snap?.decision == .cloud)
        #expect(north.nearest?.osmWayID == 1)
        // Between the roads: both supported equally → ambiguous.
        #expect(Self.snap(0, 8, span: 300, network: net, cloud: Self.cloud(0, 10, headingDeg: 90)).result == .ambiguous)
        // Heading across both roads: no support → ambiguous.
        #expect(Self.snap(0, 8, span: 300, network: net, cloud: Self.cloud(0, -45, headingDeg: 0)).result == .ambiguous)
        // Empty cloud: ambiguous.
        #expect(Self.snap(0, 8, span: 300, network: net, cloud: []).result == .ambiguous)
    }

    /// A dual carriageway: way 1 eastbound one-way on north = 0, way 2
    /// westbound one-way on north = 44 (stored in driving order).
    static func carriageways() throws -> RoadNetwork {
        try network([
            RoadFixture.way(1, ["highway": "primary", "oneway": "yes"],
                            [Node(id: 1, east: -400, north: 0), Node(id: 2, east: 400, north: 0)]),
            RoadFixture.way(2, ["highway": "primary", "oneway": "yes"],
                            [Node(id: 3, east: 400, north: 44), Node(id: 4, east: -400, north: 44)]),
        ])
    }

    @Test("One-way carriageways: a tap between them (17.7 / 26.3 m) goes to the one the cloud drives along, in its direction")
    func oneWayCarriageways() throws {
        let net = try Self.carriageways()
        // 600 m span: radius 31 m, σ 50 m, reach 100 m; both carriageways' points are in reach of the cloud.
        let alone = Self.snap(0, 17.7, span: 600, network: net)
        #expect(alone.result == .ambiguous)
        #expect(alone.contested.map(\.osmWayID) == [1, 2])
        #expect(alone.contested.map(\.isOneway) == [true, true])
        #expect(abs(alone.contested[1].bearingDeg - 270) < 0.01, "way 2 is stored westbound")
        // The car on way 1, 30 m from the tap, eastbound at 50 km/h.
        let east = Self.snap(0, 17.7, span: 600, network: net, cloud: Self.cloud(30, 0, headingDeg: 90))
        #expect(east.support.count == 2 && abs(east.support[0] - 1) < 1e-9 && east.support[1] == 0)
        guard case .edge(let s) = east.result else { Issue.record("\(east.result)"); return }
        #expect(s.candidate.osmWayID == 1 && s.decision == .cloud)
        Self.expectAt(s, 0, 0)
        // The car on way 2, westbound: way 2, although way 1 is nearer.
        let west = Self.snap(0, 17.7, span: 600, network: net, cloud: Self.cloud(-30, 44, headingDeg: 270))
        #expect(west.support.count == 2 && west.support[0] == 0 && abs(west.support[1] - 1) < 1e-9)
        #expect(west.result.snap?.candidate.osmWayID == 2)
        Self.expectAt(west.result.snap, 0, 44)
        // Heading against both one-ways' directions? None: a westbound cloud
        // on way 1's line supports way 2 only (its direction), not way 1.
        let wrongWay = Self.snap(0, 17.7, span: 600, network: net, cloud: Self.cloud(30, 0, headingDeg: 270))
        #expect(wrongWay.support.count == 2 && wrongWay.support[0] == 0 && abs(wrongWay.support[1] - 1) < 1e-9)
        // A two-way road still accepts either direction (parallelCloud).
    }

    @Test("Cloud ratio: 2× the support decides, 1.9× does not")
    func cloudRatio() throws {
        let net = try Self.parallel()
        func split(_ a: Int, _ b: Int) -> [PinSnap.Particle] {
            let n = Double(a + b)
            let pa = Self.degrees(0, -45), pb = Self.degrees(0, 65)
            return (0..<a).map { _ in PinSnap.Particle(latitude: pa.latitude, longitude: pa.longitude, headingRad: .pi / 2, weight: 1 / n) }
                + (0..<b).map { _ in PinSnap.Particle(latitude: pb.latitude, longitude: pb.longitude, headingRad: .pi / 2, weight: 1 / n) }
        }
        #expect(Self.snap(0, 8, span: 300, network: net, cloud: split(20, 10)).result.snap?.candidate.osmWayID == 1)
        #expect(Self.snap(0, 8, span: 300, network: net, cloud: split(19, 10)).result == .ambiguous)
        #expect(Self.snap(0, 8, span: 300, network: net, cloud: split(10, 20)).result.snap?.candidate.osmWayID == 2)
    }

    @Test("Overpass: different roads crossing without a shared node never snap to a node; heading picks the road")
    func overpass() throws {
        let net = try Self.network([
            RoadFixture.way(1, Self.road, [Node(id: 1, east: -300, north: 0), Node(id: 2, east: 300, north: 0)]),
            RoadFixture.way(2, ["highway": "primary", "bridge": "yes", "layer": "1"],
                            [Node(id: 3, east: 0, north: -300), Node(id: 4, east: 0, north: 300)]),
        ])
        // On the crossing, well inside the junction radius: no node (the two
        // points are 1.4 m apart: the nearer road, as close roads).
        let onCrossing = Self.snap(1, 1, span: 1500, network: net)
        if case .node = onCrossing.result { Issue.record("no shared node: never a node snap") }
        #expect(onCrossing.result.snap?.decision == .closeRoads)
        // 300 m span (σ 30 m, σ/2 15 m): points (10, 0) and (0, 12) are 15.6 m
        // apart, so the cloud decides.
        let tap = (east: 10.0, north: 12.0)  // way 2 at 10 m, way 1 at 12 m
        #expect(Self.snap(tap.east, tap.north, span: 300, network: net).result == .ambiguous)
        // At 1500 m (σ/2 62.5 m) the same tap is a close-roads snap to the nearer, way 2.
        let wide = Self.snap(tap.east, tap.north, span: 1500, network: net, cloud: Self.cloud(10, 0, headingDeg: 85))
        #expect(wide.result.snap?.candidate.osmWayID == 2 && wide.result.snap?.decision == .closeRoads)
        // Heading east: way 1, although way 2 is nearer.
        let east = Self.snap(tap.east, tap.north, span: 300, network: net, cloud: Self.cloud(10, 0, headingDeg: 85))
        guard case .edge(let s) = east.result else { Issue.record("\(east.result)"); return }
        #expect(s.candidate.osmWayID == 1 && s.decision == .cloud)
        #expect(east.nearest?.osmWayID == 2)
        Self.expectAt(s, 10, 0)
        // Heading south (bridge drawn south to north): way 2.
        let south = Self.snap(tap.east, tap.north, span: 300, network: net, cloud: Self.cloud(0, 12, headingDeg: 180))
        #expect(south.result.snap?.candidate.osmWayID == 2)
        #expect(south.result.snap?.candidate.level == 1)
        Self.expectAt(south.result.snap, 0, 12)
    }

    @Test("A third road beyond 2× does not join the contest")
    func contestedSet() throws {
        let net = try Self.network([
            RoadFixture.way(1, Self.road, [Node(id: 1, east: -300, north: 0), Node(id: 2, east: 300, north: 0)]),
            RoadFixture.way(2, Self.road, [Node(id: 3, east: -300, north: 18), Node(id: 4, east: 300, north: 18)]),
            RoadFixture.way(3, Self.road, [Node(id: 5, east: -300, north: -40), Node(id: 6, east: 300, north: -40)]),
        ])
        // Way 1 at 8 m, way 2 at 10 m, way 3 at 48 m (> 16 m). Ways 1 and 2's
        // points are 18 m apart (≤ σ/2 = 62.5 m): close roads, the nearer.
        let o = Self.snap(0, 8, span: 1500, network: net)
        #expect(o.result.snap?.candidate.osmWayID == 1 && o.result.snap?.decision == .closeRoads)
        #expect(o.contested.map(\.osmWayID) == [1, 2])
    }

    /// Two two-way roads `gap` metres apart (north = 0 and north = gap).
    static func pair(gap: Double) throws -> RoadNetwork {
        try network([
            RoadFixture.way(1, Self.road, [Node(id: 1, east: -300, north: 0), Node(id: 2, east: 300, north: 0)]),
            RoadFixture.way(2, Self.road, [Node(id: 3, east: -300, north: gap), Node(id: 4, east: 300, north: gap)]),
        ])
    }

    @Test("Close roads: contested roads 2–5 m apart are one road, the nearer wins without the cloud")
    func closeRoads() throws {
        for gap in [2.0, 3.5, 5.0] {
            let net = try Self.pair(gap: gap)
            // Tap 45 % of the way across: nearer way 1, contested (ratio < 2).
            let o = Self.snap(0, 0.45 * gap, span: 300, network: net, cloud: Self.cloud(0, gap, headingDeg: 90))
            guard case .edge(let s) = o.result else { Issue.record("gap \(gap): \(o.result)"); continue }
            #expect(s.candidate.osmWayID == 1 && s.decision == .closeRoads, "gap \(gap)")
            #expect(o.contested.map(\.osmWayID) == [1, 2])
            #expect(o.support.isEmpty, "the cloud is not consulted")
            Self.expectAt(s, 0, 0)
            // The other side: way 2.
            #expect(Self.snap(0, 0.55 * gap, span: 300, network: net).result.snap?.candidate.osmWayID == 2)
        }
    }

    @Test("Close roads boundary: points 14.6 m apart at σ 30 m are one road; 15.4 m apart go to the cloud or stay ambiguous")
    func closeRoadsBoundary() throws {
        // 300 m span: σ 30 m, σ/2 15 m; radius 15.5 m.
        let near = try Self.pair(gap: 14.6)
        #expect(Self.snap(0, 7, span: 300, network: near).result.snap?.decision == .closeRoads)
        let apart = try Self.pair(gap: 15.4)
        let alone = Self.snap(0, 7, span: 300, network: apart)
        #expect(alone.result == .ambiguous)
        #expect(alone.contested.map(\.osmWayID) == [1, 2])
        // A cloud 50 m south of way 1 (65.4 m from way 2's point, beyond 2σ = 60 m): way 1 by the cloud.
        let cloud = Self.snap(0, 7, span: 300, network: apart, cloud: Self.cloud(0, -50, headingDeg: 90))
        #expect(cloud.result.snap?.candidate.osmWayID == 1 && cloud.result.snap?.decision == .cloud)
        // At a 1000 m span (σ/2 41.7 m) the same pair is one road.
        #expect(Self.snap(0, 7, span: 1000, network: apart).result.snap?.decision == .closeRoads)
    }

    @Test("Deterministic: the same tap gives the same outcome; pack order does not matter")
    func deterministic() throws {
        let a = try Self.parallel()
        let lines = [
            RoadFixture.way(2, Self.road, [Node(id: 3, east: -300, north: 20), Node(id: 4, east: 300, north: 20)]),
            RoadFixture.way(1, Self.road, [Node(id: 1, east: -300, north: 0), Node(id: 2, east: 300, north: 0)]),
        ]
        let b = try Self.network(lines)
        let cloud = Self.cloud(0, -45, headingDeg: 90)
        for tap in [(0.0, 8.0), (3.0, 10.0), (-7.0, 13.0)] {
            let x = Self.snap(tap.0, tap.1, span: 300, network: a, cloud: cloud)
            #expect(x == Self.snap(tap.0, tap.1, span: 300, network: a, cloud: cloud))
            #expect(x.result.snap?.latitude == Self.snap(tap.0, tap.1, span: 300, network: b, cloud: cloud).result.snap?.latitude)
        }
    }

    // MARK: Accept / refuse

    @Test("Placement: snapped up to 1500 m at the road with the tap kept; otherwise the 300 m rule")
    func placement() throws {
        let net = try Self.straight()
        let tap = Self.degrees(100, 20)
        let snapped = Self.snap(100, 20, span: 1500, network: net).result
        let pin = try #require(snapped.snap)
        for span in [100.0, 1200, 1500] {
            #expect(PinSnap.placement(tapLatitude: tap.latitude, tapLongitude: tap.longitude, mapSpanM: span, result: snapped)
                    == .place(latitude: pin.latitude, longitude: pin.longitude, tapLatitude: tap.latitude, tapLongitude: tap.longitude))
        }
        #expect(PinSnap.placement(tapLatitude: tap.latitude, tapLongitude: tap.longitude, mapSpanM: 1500.1, result: snapped) == .zoomIn)
        for result in [PinSnap.Result.ambiguous, .noEdgeInRadius, .noNetwork] {
            #expect(PinSnap.placement(tapLatitude: tap.latitude, tapLongitude: tap.longitude, mapSpanM: 300, result: result)
                    == .place(latitude: tap.latitude, longitude: tap.longitude, tapLatitude: nil, tapLongitude: nil))
            #expect(PinSnap.placement(tapLatitude: tap.latitude, tapLongitude: tap.longitude, mapSpanM: 300.1, result: result) == .zoomIn)
        }
        for span in [nil, Double.nan, -1] as [Double?] {
            #expect(PinSnap.placement(tapLatitude: tap.latitude, tapLongitude: tap.longitude, mapSpanM: span, result: snapped) == .zoomIn)
        }
        let node = try #require(Self.snap(5, 6, span: 1500, network: Self.crossing()).result.snap)
        #expect(PinSnap.placement(tapLatitude: 0, tapLongitude: 0, mapSpanM: 1500, result: .node(node))
                == .place(latitude: node.latitude, longitude: node.longitude, tapLatitude: 0, tapLongitude: 0))
    }

    // MARK: Engine accessors

    @Test("Engine: no cloud before initialisation; the cloud after a pin; snapPin without roads is noNetwork")
    func engineAccessors() throws {
        var config = NavigationConfig()
        config.particleCount = 200
        var engine = NavigationEngine(config: config)
        #expect(engine.pinSnapCloud() == nil)
        let p = Self.degrees(30, 40)
        let fix = ManualFixSample(latitude: p.latitude, longitude: p.longitude, pressedT: .zero, mapSpanM: 300, speedSource: "unknown")
        engine.ingest(.manualFix(fix, at: .zero))
        let cloud = try #require(engine.pinSnapCloud())
        #expect(cloud.count == 200)
        #expect(abs(cloud.reduce(0) { $0 + $1.weight } - 1) < 1e-9)
        let mean = cloud.reduce((0.0, 0.0)) { ($0.0 + $1.weight * $1.latitude, $0.1 + $1.weight * $1.longitude) }
        let m = Self.metres(latitude: mean.0, longitude: mean.1)
        #expect(abs(m.east - 30) < 15 && abs(m.north - 40) < 15)
        let before = engine.estimate(at: .zero)
        #expect(engine.snapPin(latitude: p.latitude, longitude: p.longitude, mapSpanM: 300, viewportHeightPt: 852).result == .noNetwork)
        #expect(engine.estimate(at: .zero) == before)

        // With roads: the engine's network.
        var withRoads = NavigationEngine(config: config, roads: try Self.straight())
        withRoads.ingest(.manualFix(fix, at: .zero))
        let o = withRoads.snapPin(latitude: p.latitude, longitude: p.longitude, mapSpanM: 1500, viewportHeightPt: 852)
        Self.expectAt(o.result.snap, 30, 0)
    }
}
