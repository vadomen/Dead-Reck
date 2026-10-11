import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// N3.1 graph fixtures (docs/N3_PLAN.md): hand-written OPL near (0, 0),
/// built into packs and checked through the reader.
@Suite("Road graphs")
struct RoadGraphTests {
    typealias N = RoadFixture.Node
    static let residential = ["highway": "residential"]

    @Test("4-way junction: two crossing ways sharing a node give four edges meeting at one node")
    func fourWayJunction() throws {
        let pack = try RoadFixture.build([
            RoadFixture.way(1, Self.residential, [N(id: 10, east: -100, north: 0), N(id: 11, east: 0, north: 0), N(id: 12, east: 100, north: 0)]),
            RoadFixture.way(2, Self.residential, [N(id: 20, east: 0, north: -100), N(id: 11, east: 0, north: 0), N(id: 22, east: 0, north: 100)]),
        ])
        #expect(pack.edgeCount == 4)
        #expect(pack.nodeCount == 5)
        let centre = RoadFixture.point(0, 0)
        let junction = try #require((0..<pack.nodeCount).first { pack.node($0) == centre })
        #expect(pack.incidentEdges(junction).count == 4)
        for n in 0..<pack.nodeCount where n != junction {
            #expect(pack.incidentEdges(n).count == 1)
        }
        // The two halves of each way keep their way point offsets.
        #expect(RoadFixture.edges(of: pack, way: 1).map(\.wayPointOffset) == [0, 1])
        #expect(RoadFixture.waysNear(pack, 5, 5) == [1, 2])
        try pack.verify()
    }

    @Test("15° Y-fork: both branches are candidates at the fork, bearings 15° apart, only one 300 m out")
    func yFork() throws {
        let half = 7.5 * Double.pi / 180
        let left = (east: -sin(half) * 300, north: cos(half) * 300)
        let right = (east: sin(half) * 300, north: cos(half) * 300)
        let pack = try RoadFixture.build([
            RoadFixture.way(1, Self.residential, [N(id: 10, east: 0, north: -200), N(id: 11, east: 0, north: 0)]),
            RoadFixture.way(2, Self.residential, [N(id: 11, east: 0, north: 0), N(id: 12, east: left.east, north: left.north)]),
            RoadFixture.way(3, Self.residential, [N(id: 11, east: 0, north: 0), N(id: 13, east: right.east, north: right.north)]),
        ])
        #expect(pack.edgeCount == 3)
        let fork = try #require((0..<pack.nodeCount).first { pack.node($0) == RoadFixture.point(0, 0) })
        #expect(pack.incidentEdges(fork).count == 3)

        let bLeft = RoadGeometry.bearing(from: pack.point(Int(RoadFixture.edges(of: pack, way: 2)[0].firstPoint)), to: RoadFixture.point(left.east, left.north))
        let bRight = RoadGeometry.bearing(from: RoadFixture.point(0, 0), to: RoadFixture.point(right.east, right.north))
        let spread = RoadGeometry.wrapPi(bRight - bLeft) * 180 / .pi
        #expect(abs(spread - 15) < 0.01)

        #expect(RoadFixture.waysNear(pack, 0, 20).isSuperset(of: [1, 2, 3]))
        // 300 m out the branches are 78 m apart: the right one is within
        // the radius of a point on it, the left one is not.
        let onRight = RoadFixture.point(right.east * 0.99, right.north * 0.99)
        let within = Self.within(pack, onRight, radius: 50)
        #expect(within == [3])
    }

    @Test("Opposite oneway carriageways 15 m apart: both within the radius, heading selects one")
    func oppositeOneways() throws {
        let pack = try RoadFixture.build([
            RoadFixture.way(1, ["highway": "primary", "oneway": "yes"], [N(id: 10, east: 0, north: -500), N(id: 11, east: 0, north: 500)]),
            RoadFixture.way(2, ["highway": "primary", "oneway": "yes"], [N(id: 20, east: 15, north: 500), N(id: 21, east: 15, north: -500)]),
        ])
        let query = RoadFixture.point(7, 100)
        #expect(Self.within(pack, query, radius: 50) == [1, 2])
        let gate = 45 * Double.pi / 180
        func compatible(heading: Double) -> Set<Int64> {
            var ways: Set<Int64> = []
            for e in 0..<pack.edgeCount {
                let r = pack.edge(e)
                #expect(r.isOneway && !r.flags.contains(.onewayImplied))
                let points = RoadFixture.points(of: pack, edge: e)
                let beta = RoadGeometry.bearing(from: points[0], to: points[1])
                if RoadGeometry.headingDifference(heading: heading, bearing: beta, oneway: r.isOneway) <= gate { ways.insert(r.osmWayID) }
            }
            return ways
        }
        #expect(compatible(heading: 0) == [1])
        #expect(compatible(heading: .pi) == [2])
        #expect(compatible(heading: .pi / 2) == [])
    }

    @Test("oneway=-1: geometry reversed into driving order, forward-only, offsets in the reversed list")
    func onewayReversed() throws {
        let line = RoadFixture.way(1, ["highway": "secondary", "oneway": "-1"], [
            N(id: 10, east: 0, north: 0), N(id: 11, east: 0, north: 100), N(id: 12, east: 0, north: 200),
        ])
        let pack = try RoadFixture.build([line])
        let edge = try #require(RoadFixture.edges(of: pack, way: 1).first)
        #expect(pack.edgeCount == 1)
        #expect(edge.isOneway && !edge.flags.contains(.onewayImplied))
        let points = RoadFixture.points(of: pack, edge: 0)
        #expect(points == [RoadFixture.point(0, 200), RoadFixture.point(0, 100), RoadFixture.point(0, 0)])
        #expect(abs(RoadGeometry.bearing(from: points[0], to: points[1]) - .pi) < 1e-9)
        // Segment 0 starts at the way's last node, now first in driving order.
        #expect(pack.segment(startingAt: 0).key == RoadSegmentKey(osmWayID: 1, index: 0))
        let ways = try OPLReader.ways(in: line)
        #expect(try RoadGraphBuilder(classes: ["secondary"]).build(ways: ways).statistics.waysReversed == 1)
    }

    @Test("Direction rules: motorway, links and roundabouts imply oneway unless oneway=no; reversible is two-way")
    func directionRules() {
        typealias B = RoadGraphBuilder
        #expect(B.direction(tags: ["highway": "motorway"]) == .forward(implied: true))
        #expect(B.direction(tags: ["highway": "motorway_link"]) == .forward(implied: true))
        #expect(B.direction(tags: ["highway": "motorway", "oneway": "no"]) == .twoWay)
        #expect(B.direction(tags: ["highway": "tertiary", "junction": "roundabout"]) == .forward(implied: true))
        #expect(B.direction(tags: ["highway": "tertiary", "junction": "roundabout", "oneway": "no"]) == .twoWay)
        #expect(B.direction(tags: ["highway": "primary", "oneway": "reversible"]) == .twoWay)
        #expect(B.direction(tags: ["highway": "primary", "oneway": "alternating"]) == .twoWay)
        #expect(B.direction(tags: ["highway": "primary", "oneway": "yes"]) == .forward(implied: false))
        #expect(B.direction(tags: ["highway": "primary", "oneway": "-1"]) == .reversed)
        #expect(B.direction(tags: ["highway": "trunk"]) == .twoWay)
    }

    @Test("Roundabout: a closed implied-oneway way split at its approach nodes; alone it is one self-loop")
    func roundabout() throws {
        let ring = (0..<8).map { i -> N in
            let a = Double(i) * .pi / 4
            return N(id: 100 + Int64(i), east: 20 * sin(a), north: 20 * cos(a))
        }
        let tags = ["highway": "tertiary", "junction": "roundabout"]
        let closed = ring + [ring[0]]
        let pack = try RoadFixture.build([
            RoadFixture.way(1, tags, closed),
            RoadFixture.way(2, Self.residential, [N(id: 200, east: 0, north: 200), ring[0]]),
            RoadFixture.way(3, Self.residential, [ring[4], N(id: 201, east: 0, north: -200)]),
        ])
        let arcs = RoadFixture.edges(of: pack, way: 1)
        #expect(arcs.count == 2)
        #expect(arcs.allSatisfy { $0.flags.isSuperset(of: [.oneway, .onewayImplied, .roundabout]) })
        #expect(arcs.map(\.pointCount) == [5, 5])
        #expect(arcs[0].from == arcs[1].to && arcs[0].to == arcs[1].from)
        try pack.verify()

        // Alone: the closing node is used twice by one way, so it is a
        // topological node and the ring is one edge from it to itself.
        let alone = try RoadFixture.build([RoadFixture.way(1, tags, closed)])
        #expect(alone.edgeCount == 1)
        #expect(alone.nodeCount == 1)
        let loop = alone.edge(0)
        #expect(loop.from == loop.to && loop.pointCount == 9)
        #expect(alone.incidentEdges(0) == [0])
        try alone.verify()
    }

    @Test("Dead end: the far end is a node with one incident edge, and the road is still indexed to its end")
    func deadEnd() throws {
        let pack = try RoadFixture.build([
            RoadFixture.way(1, Self.residential, [N(id: 10, east: -200, north: 0), N(id: 11, east: 0, north: 0), N(id: 12, east: 200, north: 0)]),
            RoadFixture.way(2, Self.residential, [N(id: 11, east: 0, north: 0), N(id: 30, east: 0, north: 50), N(id: 31, east: 0, north: 120)]),
        ])
        let end = try #require((0..<pack.nodeCount).first { pack.node($0) == RoadFixture.point(0, 120) })
        #expect(pack.incidentEdges(end).count == 1)
        // The interior point (id 30) is not a topological node.
        #expect(!(0..<pack.nodeCount).contains { pack.node($0) == RoadFixture.point(0, 50) })
        #expect(RoadFixture.waysNear(pack, 0, 165).contains(2))
        #expect(Self.within(pack, RoadFixture.point(0, 175), radius: 50) == [])
    }

    /// The stacked crossing of the plan's level rule: a `layer=1` bridge
    /// over a level-0 street with no shared node, and a level-0 ramp from
    /// the bridge's end down to the street, 200 m east of the crossing. A
    /// side street at 60 m east makes the crossing edge 3 hops from the
    /// bridge.
    static func bridgeLines(idOffset o: Int64 = 0) -> [String] {
        [
            RoadFixture.way(o + 100, ["highway": "secondary"], [
                N(id: o + 1, east: -300, north: 0), N(id: o + 2, east: 60, north: 0), N(id: o + 3, east: 200, north: 0), N(id: o + 4, east: 300, north: 0),
            ]),
            RoadFixture.way(o + 101, ["highway": "primary", "bridge": "yes", "layer": "1"], [
                N(id: o + 10, east: 0, north: -300), N(id: o + 11, east: 0, north: 300),
            ]),
            RoadFixture.way(o + 102, ["highway": "primary_link"], [
                N(id: o + 11, east: 0, north: 300), N(id: o + 12, east: 150, north: 150), N(id: o + 3, east: 200, north: 0),
            ]),
            RoadFixture.way(o + 103, Self.residential, [N(id: o + 2, east: 60, north: 0), N(id: o + 20, east: 60, north: -200)]),
        ]
    }

    @Test("Bridge stacked over a level-0 road: both indexed at the crossing; the level rule blocks the street below and admits the ramp")
    func stackedBridge() throws {
        let pack = try RoadFixture.build(Self.bridgeLines())
        #expect(Self.within(pack, RoadFixture.point(3, 3), radius: 50) == [100, 101])
        let bridge = try #require(RoadFixture.edgeIndices(of: pack, way: 101).first)
        let ramp = try #require(RoadFixture.edgeIndices(of: pack, way: 102).first)
        let streetEdges = RoadFixture.edgeIndices(of: pack, way: 100)
        #expect(streetEdges.count == 3)
        let crossing = streetEdges[0]  // −300 … 60 m: passes under the bridge
        #expect(pack.edge(bridge).level == 1 && pack.edge(bridge).flags.contains(.bridge))
        #expect(pack.edge(crossing).level == 0 && pack.edge(ramp).level == 0)
        #expect(pack.edge(ramp).flags.contains(.link))

        #expect(pack.isEdge(bridge, withinHops: 1, of: ramp))
        #expect(!pack.isEdge(bridge, withinHops: 2, of: crossing))
        #expect(pack.isEdge(bridge, withinHops: 3, of: crossing))
        #expect(pack.isEdge(ramp, withinHops: 2, of: crossing))

        let hops = 2
        func allows(particleOn edge: Int, candidate: Int) -> Bool {
            RoadGeometry.levelAllows(particleLevel: pack.edge(edge).level, candidateLevel: pack.edge(candidate).level) {
                pack.isEdge(candidate, withinHops: hops, of: edge)
            }
        }
        #expect(!allows(particleOn: crossing, candidate: bridge))   // below the viaduct: blocked
        #expect(allows(particleOn: ramp, candidate: bridge))        // via the ramp: admitted
        #expect(allows(particleOn: bridge, candidate: ramp))
        #expect(allows(particleOn: crossing, candidate: ramp))      // same level
        #expect(RoadGeometry.levelAllows(particleLevel: RoadGeometry.unknownLevel, candidateLevel: 1) { false })
    }

    @Test("Tunnel, bridge and layer tags give the level and flags of the plan's rule")
    func tunnelLevels() throws {
        let cases: [([String: String], Int8, RoadEdgeFlags)] = [
            (["tunnel": "yes"], -1, [.tunnel]),
            (["tunnel": "building_passage"], -1, [.tunnel]),
            (["tunnel": "yes", "layer": "-2"], -2, [.tunnel]),
            (["tunnel": "no"], 0, []),
            (["bridge": "viaduct"], 1, [.bridge]),
            (["bridge": "no"], 0, []),
            (["layer": "7"], 5, []),
            (["layer": "-9"], -5, []),
            (["layer": "x", "bridge": "yes"], 1, [.bridge]),
            ([:], 0, []),
        ]
        var lines: [String] = []
        for (i, c) in cases.enumerated() {
            var tags = c.0
            tags["highway"] = "residential"
            let north = Double(i) * 200
            lines.append(RoadFixture.way(Int64(i + 1), tags, [N(id: Int64(10 * i + 1), east: 0, north: north), N(id: Int64(10 * i + 2), east: 100, north: north)]))
        }
        let pack = try RoadFixture.build(lines)
        for (i, c) in cases.enumerated() {
            let edge = try #require(RoadFixture.edges(of: pack, way: Int64(i + 1)).first)
            #expect(edge.level == c.1, "case \(c.0)")
            #expect(edge.flags.intersection([.bridge, .tunnel]) == c.2, "case \(c.0)")
            #expect(RoadGeometry.level(tags: c.0) == c.1)
        }
    }

    @Test("A 3 km straight segment crossing many cells is listed in every cell it passes and found all along it")
    func longSegment() throws {
        let pack = try RoadFixture.build([
            RoadFixture.way(1, ["highway": "trunk"], [N(id: 1, east: -1060, north: -1060), N(id: 2, east: 1060, north: 1060)]),
        ])
        #expect(pack.segmentCount == 1)
        #expect(abs(Double(pack.edge(0).lengthDm) / 10 - 2120 * 2.0.squareRoot()) < 1)
        // Every cell within R_eff of the segment, and no other: bracketed
        // by an independent scan that samples each cell rectangle every
        // 2 m (so its distance is at most 1.5 m too large).
        let grid = pack.grid
        let a = grid.frame(RoadFixture.point(-1060, -1060)), b = grid.frame(RoadFixture.point(1060, 1060))
        let rEff = grid.effectiveRadiusM(minLatitude: -0.01, maxLatitude: 0.01)
        var surely: Set<UInt64> = [], possibly: Set<UInt64> = []
        let lo = grid.cell(x: a.x - rEff, y: a.y - rEff), hi = grid.cell(x: b.x + rEff, y: b.y + rEff)
        for cy in lo.cy...hi.cy {
            for cx in lo.cx...hi.cx {
                var nearest = Double.infinity
                for i in 0...32 {
                    for j in 0...32 {
                        let x = (Double(cx) + Double(i) / 32) * grid.cellSizeM, y = (Double(cy) + Double(j) / 32) * grid.cellSizeM
                        nearest = min(nearest, RoadGeometry.distanceSquared(px: x, py: y, ax: a.x, ay: a.y, bx: b.x, by: b.y))
                    }
                }
                let d = nearest.squareRoot()
                if d <= rEff - 1.5 { surely.insert(RoadGrid.key(cx: cx, cy: cy)) }
                if d <= rEff + 1.5 { possibly.insert(RoadGrid.key(cx: cx, cy: cy)) }
            }
        }
        let listed = Set((0..<pack.cellCount).map { pack.cellKey($0) })
        #expect(surely.isSubset(of: listed))
        #expect(listed.isSubset(of: possibly))
        #expect(surely.count > 100)
        #expect(pack.cellEntryCount == pack.cellCount)
        var rng = NavigationRandom(seed: 7)
        for _ in 0..<500 {
            let t = rng.nextUniform() * 2 - 1
            let offset = (rng.nextUniform() * 2 - 1) * 49.9
            let east = 1060 * t + offset / 2.0.squareRoot(), north = 1060 * t - offset / 2.0.squareRoot()
            #expect(RoadFixture.waysNear(pack, east, north) == [1])
        }
        #expect(RoadFixture.waysNear(pack, 0, 120).isEmpty)
    }

    @Test("Segments exactly on cell boundaries are listed on both sides and nowhere beyond the radius")
    func cellBoundary() throws {
        // A grid whose frame puts lonE7 6400 exactly on x = 64 m and
        // latE7 0 exactly on y = 0.
        let k = RoadGrid.trueMetresPerE7(latitude: 0)
        let grid = RoadGrid(originLatE7: 0, originLonE7: 0, metresPerE7Lat: k.lat, metresPerE7Lon: 0.01, cellSizeM: 64, searchRadiusM: 50)
        let vertical = "w1 v1 dV c0 t i0 u Thighway=residential Nn1x0.00064y-0.0005,n2x0.00064y0.0005"
        let horizontal = "w2 v1 dV c0 t i0 u Thighway=residential Nn3x0.0002y0,n4x0.0003y0"
        let pack = try RoadFixture.build([vertical, horizontal], grid: grid)
        #expect(grid.frame(RoadPoint(latE7: 0, lonE7: 6400)).x == 64)
        func ways(cx: Int32, cy: Int32) -> Set<Int64> {
            Set(pack.segments(inCellX: cx, y: cy).map { pack.segment(startingAt: $0).key.osmWayID })
        }
        #expect(ways(cx: 0, cy: 0).contains(1) && ways(cx: 1, cy: 0).contains(1))
        #expect(!ways(cx: -1, cy: 0).contains(1) && !ways(cx: 2, cy: 0).contains(1))
        #expect(ways(cx: 0, cy: 0).contains(2) && ways(cx: 0, cy: -1).contains(2))
        #expect(!ways(cx: 0, cy: 1).contains(2) && !ways(cx: 0, cy: -2).contains(2))
        for lonE7 in [6399, 6400, 6401] {
            let c = grid.cell(latitude: 0.0001, longitude: Double(lonE7) / 1e7)
            #expect(ways(cx: c.cx, cy: c.cy).contains(1))
        }
    }

    @Test("Excluded classes, area=yes, parking aisles and nodes without a location")
    func exclusions() throws {
        let lines = [
            RoadFixture.way(1, ["highway": "footway"], [N(id: 1, east: 0, north: 0), N(id: 2, east: 10, north: 0)]),
            RoadFixture.way(2, ["highway": "track"], [N(id: 3, east: 0, north: 10), N(id: 4, east: 10, north: 10)]),
            RoadFixture.way(3, ["highway": "service", "service": "parking_aisle"], [N(id: 5, east: 0, north: 20), N(id: 6, east: 10, north: 20)]),
            RoadFixture.way(4, ["highway": "pedestrian", "area": "yes"], [N(id: 7, east: 0, north: 30), N(id: 8, east: 10, north: 30)]),
            RoadFixture.way(5, ["highway": "residential", "area": "yes"], [N(id: 9, east: 0, north: 40), N(id: 10, east: 10, north: 40)]),
            RoadFixture.way(6, ["highway": "service", "access": "private"], [N(id: 11, east: 0, north: 50), N(id: 12, east: 10, north: 50)]),
            // Node 15 has no location: the segments next to it are dropped
            // and the way splits around it.
            "w7 v1 dV c0 t i0 u Thighway=residential Nn13x0.0000000y0.0010000,n14x0.0001000y0.0010000,n15xy,n16x0.0003000y0.0010000,n17x0.0004000y0.0010000",
        ]
        let ways = try OPLReader.ways(in: lines.joined(separator: "\n"))
        let (graph, stats) = try RoadGraphBuilder(classes: Set(RoadGraphBuilder.regionClasses)).build(ways: ways)
        #expect(Set(graph.edges.map(\.osmWayID)) == [6, 7])
        // footway, track and pedestrian are not drivable classes; a
        // drivable class tagged area=yes is dropped as an area.
        #expect(stats.waysWrongClass == 3 && stats.waysParkingAisle == 1 && stats.waysArea == 1)
        #expect(stats.nodesWithoutLocation == 1)
        let pieces = graph.edges.filter { $0.osmWayID == 7 }.sorted { $0.wayPointOffset < $1.wayPointOffset }
        #expect(pieces.map(\.wayPointOffset) == [0, 3])
        #expect(pieces.map(\.points.count) == [2, 2])
        // National classes keep only motorway/trunk/primary and links.
        #expect(RoadClass.parse(highway: "unclassified_link") == nil)
        #expect(RoadClass.parse(highway: "primary_link")?.isLink == true)
    }

    /// Ways with a segment within `radius` true metres of `point`, from the
    /// point's cell.
    static func within(_ pack: RoadPack, _ point: RoadPoint, radius: Double) -> Set<Int64> {
        let c = pack.grid.cell(latitude: point.latitude, longitude: point.longitude)
        var ways: Set<Int64> = []
        for s in pack.segments(inCellX: c.cx, y: c.cy) {
            let seg = pack.segment(startingAt: s)
            let d = RoadFixture.trueDistance(latE7: Double(point.latE7), lonE7: Double(point.lonE7), seg.a, seg.b)
            if d <= radius { ways.insert(seg.key.osmWayID) }
        }
        return ways
    }
}
