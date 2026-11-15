import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// The route-to-roads matcher (prompt 51 item C): Viterbi over candidate
/// road positions every 10 m, transitions along the graph. Synthetic packs
/// and routes near (0, 0) only.
@Suite("Route edge matcher (prompt 51 C)")
struct RouteEdgeMatcherTests {
    typealias N = RoadFixture.Node

    static func way(_ id: Int64, _ tags: [String: String], _ nodes: [(Int64, Double, Double)]) -> String {
        RoadFixture.way(id, tags, nodes.map { N(id: $0.0, east: $0.1, north: $0.2) })
    }

    static let residential = ["highway": "residential"]
    static let oneway = ["highway": "residential", "oneway": "yes"]

    static func network(_ lines: [String]) throws -> RoadNetwork {
        try RoadNetwork(packs: [RoadFixture.build(lines)])
    }

    static func polyline(_ offsets: [(Double, Double)]) throws -> RoutePolyline {
        try RoutePolyline(offsets.map { offset in
            let p = RoadFixture.point(offset.0, offset.1)
            return RoutePoint(latE7: p.latE7, lonE7: p.lonE7)
        })
    }

    static func match(_ net: RoadNetwork, _ offsets: [(Double, Double)]) throws -> RouteEdgeMatch {
        RouteEdgeMatcher(network: net).match(try polyline(offsets))
    }

    /// The ways of the matched edges, consecutive repeats collapsed.
    static func ways(_ m: RouteEdgeMatch) -> [Int64] {
        var out: [Int64] = []
        for e in m.edges where out.last != e.osmWayID { out.append(e.osmWayID) }
        return out
    }

    @Test("The three decided values and the tuning defaults")
    func thresholds() {
        let t = RouteMatchThresholds.standard
        #expect(t.resampleSpacingM == 10 && t.matchDistanceM == 15 && t.weakCoverageBelow == 0.90)
        #expect(t.candidateRadiusM == 25 && t.maxHeadingDifferenceDegrees == 60 && t.breakCost == 20)
    }

    @Test("A straight street: one edge, full coverage, along-edge and route ranges, per-edge distance")
    func straightStreet() throws {
        let net = try Self.network([Self.way(1, Self.residential, [(1, 0, -500), (2, 0, 0), (3, 0, 500)])])
        let m = try Self.match(net, [(2, -400), (2, 400)])
        #expect(m.coverage > 0.999 && !m.isWeak && m.gaps.isEmpty)
        // E7 rounding makes the length a hair over 800 m: one more, shorter last interval.
        let samples = Int((m.routeLengthM / 10).rounded(.up)) + 1
        #expect(abs(m.routeLengthM - 800) < 0.1 && m.sampleCount == samples)
        #expect(m.edges.count == 1)
        let e = try #require(m.edges.first)
        #expect(e.osmWayID == 1 && e.wayPointOffset == 0 && e.forward)
        #expect(abs(e.edgeFromM - 100) < 0.1 && abs(e.edgeToM - 900) < 0.1)
        #expect(e.segmentIndices == 0...1)
        #expect(e.routeFromM == 0 && e.routeToM == m.routeLengthM)
        #expect(e.sampleCount == samples)
        let maxDistance = try #require(e.maxDistanceM), meanDistance = try #require(e.meanDistanceM)
        #expect(abs(maxDistance - 2) < 0.05 && abs(meanDistance - 2) < 0.05)
        // Driven the other way: the same two-way edge, backwards.
        let back = try Self.match(net, [(-2, 400), (-2, -400)])
        #expect(back.coverage > 0.999 && back.edges.count == 1 && back.edges[0].forward == false)
        #expect(abs(back.edges[0].edgeFromM - 900) < 0.1 && abs(back.edges[0].edgeToM - 100) < 0.1)
    }

    @Test("A turn at a junction follows the graph onto the side street; a cross street is no candidate")
    func turn() throws {
        let net = try Self.network([
            Self.way(1, Self.residential, [(1, 0, -500), (2, 0, 0), (3, 0, 500)]),
            Self.way(2, Self.residential, [(2, 0, 0), (4, 500, 0)]),
            Self.way(3, Self.residential, [(5, -300, -200), (6, 300, -200)]),
        ])
        let m = try Self.match(net, [(1, -400), (1, -1), (300, -1)])
        #expect(m.coverage > 0.999 && m.gaps.isEmpty)
        #expect(Self.ways(m) == [1, 2])
        #expect(m.edges.allSatisfy { $0.forward })
        // Contiguous along the route.
        for (a, b) in zip(m.edges, m.edges.dropFirst()) { #expect(abs(a.routeToM - b.routeFromM) < 1e-6) }
    }

    @Test("A oneway against the route never matches; the two-way street beside it does")
    func onewayAgainst() throws {
        let alone = try Self.network([Self.way(1, Self.oneway, [(1, 0, -500), (2, 0, 500)])])
        let against = try Self.match(alone, [(0, 400), (0, -400)])
        #expect(against.edges.isEmpty && against.coverage == 0 && against.isWeak)
        #expect(against.gaps == [RouteMatchGap(startM: 0, endM: against.routeLengthM)])
        let with = try Self.match(alone, [(0, -400), (0, 400)])
        #expect(with.coverage > 0.999 && Self.ways(with) == [1])

        let both = try Self.network([
            Self.way(1, Self.oneway, [(1, 0, -500), (2, 0, 500)]),
            Self.way(2, Self.residential, [(3, 12, -500), (4, 12, 500)]),
        ])
        let south = try Self.match(both, [(0, 400), (0, -400)])
        #expect(Self.ways(south) == [2] && south.coverage > 0.999)
        let north = try Self.match(both, [(0, -400), (0, 400)])
        #expect(Self.ways(north) == [1])
    }

    /// A roundabout of radius 30 m, anticlockwise (right-hand traffic), with
    /// ring nodes every 45° from the south and arms south, east, north, west.
    static func roundabout() throws -> RoadNetwork {
        let r = 30.0
        let ring: [(Int64, Double, Double)] = (0..<8).map { k in
            let a = (-90 + 45 * Double(k)) * .pi / 180
            return (Int64(100 + k), r * cos(a), r * sin(a))
        }
        return try network([
            way(10, ["highway": "tertiary", "junction": "roundabout"], ring + [ring[0]]),
            way(11, residential, [(1, 0, -300), (100, 0, -30)]),
            way(12, residential, [(102, 30, 0), (2, 300, 0)]),
            way(13, residential, [(104, 0, 30), (3, 0, 300)]),
            way(14, residential, [(106, -30, 0), (4, -300, 0)]),
        ])
    }

    static func ringPoint(_ k: Int) -> (Double, Double) {
        let a = (-90 + 45 * Double(k)) * .pi / 180
        return (30 * cos(a), 30 * sin(a))
    }

    @Test("A roundabout: in from the south, out to the north; the road context gives exit 2")
    func roundaboutPassage() throws {
        let net = try Self.roundabout()
        let offsets = [(0.0, -250.0), Self.ringPoint(0), Self.ringPoint(1), Self.ringPoint(2), Self.ringPoint(3),
                       Self.ringPoint(4), (0.0, 250.0)]
        let polyline = try Self.polyline(offsets)
        let matcher = RouteEdgeMatcher(network: net)
        let m = matcher.match(polyline)
        #expect(m.coverage > 0.99 && !m.isWeak, "coverage \(m.coverage), gaps \(m.gaps)")
        #expect(Self.ways(m) == [11, 10, 13])
        #expect(m.edges.filter { $0.osmWayID == 10 }.allSatisfy { $0.forward && $0.flags.contains(.roundabout) })

        // Steps: depart, to the ring entry, through the ring to the exit, arrive.
        let ranges = [0...0, 0...1, 1...5, 5...6]
        let route = try Route(
            id: "ring", polyline: polyline.points,
            steps: ranges.map { RouteStep(instruction: "", distanceM: 0, polylineRange: $0, maneuver: .straight) },
            distanceM: polyline.lengthM, expectedTravelTimeS: 60, source: .synthetic
        )
        let contexts = matcher.roadContexts(for: route, match: m)
        #expect(contexts.count == 4)
        let entry = try #require(contexts[1])
        #expect(entry.roundabout && entry.roundaboutExit == 2)
        #expect(contexts[2]?.roundabout == true && contexts[2]?.roundaboutExit == 2)
        let maneuvers = try RouteManeuver.computed(polyline: polyline, stepRanges: ranges, roadContexts: contexts)
        #expect(maneuvers == [.depart, .roundaboutExit(exit: 2), .roundaboutExit(exit: 2), .arrive])
    }

    @Test("A bridge over a road at another level, 6° apart and overlapping: no jump between them")
    func bridge() throws {
        let net = try Self.network([
            Self.way(1, ["highway": "primary"], [(1, 0, -500), (2, 0, 500)]),
            Self.way(2, ["highway": "primary", "bridge": "yes", "layer": "1"], [(3, -40, -400), (4, 40, 400)]),
        ])
        #expect(net.packs[0].edge(RoadFixture.edgeIndices(of: net.packs[0], way: 2)[0]).level == 1)
        let below = try Self.match(net, [(0, -450), (0, 450)])
        #expect(Self.ways(below) == [1] && below.coverage > 0.999)
        let over = try Self.match(net, [(-36, -360), (36, 360)])
        #expect(Self.ways(over) == [2] && over.coverage > 0.999)
    }

    @Test("Parallel carriageways 20 m apart: each direction matches its own, even nearer the other one")
    func carriageways() throws {
        let net = try Self.network([
            Self.way(1, ["highway": "primary", "oneway": "yes"], [(1, 10, -500), (2, 10, 500)]),
            Self.way(2, ["highway": "primary", "oneway": "yes"], [(3, -10, 500), (4, -10, -500)]),
        ])
        #expect(Self.ways(try Self.match(net, [(6, -400), (6, 400)])) == [1])
        #expect(Self.ways(try Self.match(net, [(-6, 400), (-6, -400)])) == [2])
        // 6 m from the southbound road, 14 m from the northbound one: northbound.
        let near = try Self.match(net, [(-4, -400), (-4, 400)])
        #expect(Self.ways(near) == [1] && near.coverage > 0.999)
    }

    /// A north-south street with cross streets every 200 m.
    static func ladder() throws -> RoadNetwork {
        var lines = [Self.way(1, residential, (0...10).map { (Int64(1 + $0), 0, -1000 + 200 * Double($0)) })]
        for k in 1...9 {
            let y = -1000 + 200 * Double(k)
            lines.append(Self.way(Int64(100 + k), residential, [(Int64(1000 + k), -500, y), (Int64(1 + k), 0, y),
                                                                 (Int64(2000 + k), 500, y)]))
        }
        return try network(lines)
    }

    @Test("A polyline shifted sideways: 10 m still matches, 20 and 30 m do not (cross streets are no candidates)",
          arguments: [(10.0, true), (20, false), (30, false)])
    func shifted(shiftM: Double, matches: Bool) throws {
        let net = try Self.ladder()
        let m = try Self.match(net, [(shiftM, -900), (shiftM, 900)])
        if matches {
            #expect(m.coverage > 0.99 && !m.isWeak && Self.ways(m) == [1])
        } else {
            #expect(m.coverage == 0 && m.isWeak && m.edges.isEmpty, "coverage \(m.coverage)")
        }
    }

    @Test("A route that leaves the roads and comes back: one gap, no jump across it, weak")
    func leaveAndReturn() throws {
        let net = try Self.network([
            Self.way(1, Self.residential, [(1, 0, -1000), (2, 0, -200)]),
            Self.way(2, Self.residential, [(3, 0, 200), (4, 0, 1000)]),
        ])
        let m = try Self.match(net, [(0, -900), (0, 900)])
        #expect(m.gaps.count == 1)
        let gap = try #require(m.gaps.first)
        // Matched up to 15 m past each road end, at 10 m sampling.
        #expect(gap.startM >= 700 && gap.startM <= 720, "gap \(gap)")
        #expect(gap.endM >= 1080 && gap.endM <= 1100, "gap \(gap)")
        #expect(abs(m.coverage - (1 - gap.lengthM / m.routeLengthM)) < 1e-9)
        #expect(m.isWeak)
        #expect(Self.ways(m) == [1, 2])
        #expect(m.edges[0].routeToM <= gap.startM && m.edges[1].routeFromM >= gap.endM)
        // With a lower bar the same coverage is not weak.
        var lenient = RouteMatchThresholds.standard
        lenient.weakCoverageBelow = 0.5
        let line = try Self.polyline([(0, -900), (0, 900)])
        #expect(!RouteEdgeMatcher(network: net, thresholds: lenient).match(line).isWeak)
    }

    /// Two packs that share the border way 100 (east-west, nodes every
    /// 250 m). Pack A also has street 101 going north from node 2; pack B
    /// has street 201 going south from node 4, which in A is only a shape
    /// point of way 100.
    static func borderPacks() throws -> (RoadPack, RoadPack) {
        let border = way(100, ["highway": "secondary"], [(1, -500, 0), (2, -250, 0), (3, 0, 0), (4, 250, 0), (5, 500, 0)])
        let a = try RoadFixture.build([border, way(101, residential, [(2, -250, 0), (6, -250, 400)])])
        let b = try RoadFixture.build([border, way(201, residential, [(4, 250, 0), (7, 250, -400)])])
        return (a, b)
    }

    @Test("Across two packs sharing a border way: the route leaves it where it is a node in one pack only")
    func twoPacks() throws {
        let (a, b) = try Self.borderPacks()
        let net = try RoadNetwork(packs: [a, b])
        // The border way's copy in the second pack is shadowed.
        let second = net.packs[1]
        let key = RoadSegmentKey(osmWayID: 100, index: 0)
        #expect(net.isShadowed(key, inPack: 1) && second.segment(withKey: key) != nil)
        let offsets: [(Double, Double)] = [(-250, 350), (-250, 0), (250, 0), (250, -350)]
        let m = try Self.match(net, offsets)
        #expect(m.coverage > 0.99 && m.gaps.isEmpty, "coverage \(m.coverage), gaps \(m.gaps)")
        #expect(Self.ways(m) == [101, 100, 201])
        // Border-way edges are the winning copy's.
        #expect(m.edges.filter { $0.osmWayID == 100 }.allSatisfy { $0.edge.pack == 0 })
        // The same result with the packs given the other way round.
        let other = try RoadNetwork(packs: [b, a])
        let reversed = try Self.match(other, offsets)
        #expect(reversed == m)
    }

    @Test("Road context from the match: onto a link is an exit ramp, off a link a merge")
    func rampAndMerge() throws {
        // Link 3 joins motorway 1 at node 8; link 2 leaves it at node 2.
        let net = try Self.network([
            Self.way(1, ["highway": "motorway"], [(1, 0, -1000), (8, 0, -100), (2, 0, 0), (3, 0, 1000)]),
            Self.way(2, ["highway": "motorway_link"], [(2, 0, 0), (4, 40, 300), (5, 80, 600)]),
            Self.way(3, ["highway": "motorway_link"], [(6, -80, -600), (7, -40, -300), (8, 0, -100)]),
        ])
        let offsets: [(Double, Double)] = [(-80, -600), (-40, -300), (0, -100), (0, 0), (40, 300), (80, 600)]
        let polyline = try Self.polyline(offsets)
        let matcher = RouteEdgeMatcher(network: net)
        let m = matcher.match(polyline)
        #expect(m.coverage > 0.99 && Self.ways(m) == [3, 1, 2], "\(Self.ways(m))")
        let ranges = [0...0, 0...2, 2...3, 3...5]
        let route = try Route(
            id: "ramp", polyline: polyline.points,
            steps: ranges.map { RouteStep(instruction: "", distanceM: 0, polylineRange: $0, maneuver: .straight) },
            distanceM: polyline.lengthM, expectedTravelTimeS: 60, source: .synthetic
        )
        let contexts = matcher.roadContexts(for: route, match: m)
        #expect(contexts[1] == RouteManeuverRoadContext(incomingIsLink: true, outgoingIsLink: false))
        #expect(contexts[2] == RouteManeuverRoadContext(incomingIsLink: false, outgoingIsLink: true))
        let maneuvers = try RouteManeuver.computed(polyline: polyline, stepRanges: ranges, roadContexts: contexts)
        #expect(maneuvers == [.depart, .merge, .exitRamp, .arrive])
    }

    @Test("Deterministic: the same route and network give the same match")
    func deterministic() throws {
        let net = try Self.roundabout()
        let offsets = [(0.0, -250.0), Self.ringPoint(0), Self.ringPoint(1), Self.ringPoint(2), (250.0, 0.0)]
        let first = try Self.match(net, offsets), second = try Self.match(net, offsets)
        #expect(first == second)
        #expect(Self.ways(first) == [11, 10, 12])
    }

    @Test("R90.1-1: the graph search never enters a oneway backwards, even where it would be the only short way on")
    func searchRespectsOneway() throws {
        // A ends at node 2 (0, 0); B starts at node 3 (8, 0); the 8 m
        // connector C runs from 3 to 2, oneway against the route. No other
        // way joins A and B. The route drives straight across.
        let net = try Self.network([
            Self.way(1, Self.residential, [(1, -300, 0), (2, 0, 0)]),
            Self.way(2, Self.residential, [(3, 8, 0), (4, 300, 0)]),
            Self.way(3, Self.oneway, [(3, 8, 0), (2, 0, 0)]),
        ])
        let m = try Self.match(net, [(-250, 1), (250, 1)])
        #expect(Self.ways(m) == [1, 2], "\(Self.ways(m))")
        #expect(!m.edges.contains { $0.flags.contains(.oneway) && !$0.forward })
        // No way through: the junction is a gap, not a jump.
        #expect(m.gaps.count == 1)
        // Driven the oneway's way, the connector is used, forwards.
        let back = try Self.match(net, [(250, 1), (-250, 1)])
        #expect(Self.ways(back) == [2, 3, 1] && back.gaps.isEmpty)
        #expect(back.edges.filter { $0.osmWayID == 3 }.allSatisfy { $0.forward })
    }

    @Test("R90.1-2: exits are counted only at ring nodes with a drivable way out; an entry-only oneway arm and a roundabout piece are not exits")
    func roundaboutExitRule() throws {
        let ring: [(Int64, Double, Double)] = (0..<8).map { k in
            let p = Self.ringPoint(k)
            return (Int64(100 + k), p.0, p.1)
        }
        let net = try Self.network([
            Self.way(10, ["highway": "tertiary", "junction": "roundabout"], ring + [ring[0]]),
            Self.way(11, Self.residential, [(1, 0, -300), (100, 0, -30)]),
            // At the SE node a roundabout-tagged piece leaves (not an exit).
            Self.way(17, ["highway": "tertiary", "junction": "roundabout"], [(101, Self.ringPoint(1).0, Self.ringPoint(1).1), (7, 120, -120)]),
            // At the east node only an entry (oneway into the ring).
            Self.way(15, Self.oneway, [(5, 300, 0), (102, 30, 0)]),
            // At the NE node only an exit (oneway out of the ring).
            Self.way(16, Self.oneway, [(103, Self.ringPoint(3).0, Self.ringPoint(3).1), (6, 250, 250)]),
            Self.way(13, Self.residential, [(104, 0, 30), (3, 0, 300)]),
        ])
        let offsets = [(0.0, -250.0), Self.ringPoint(0), Self.ringPoint(1), Self.ringPoint(2), Self.ringPoint(3),
                       Self.ringPoint(4), (0.0, 250.0)]
        let polyline = try Self.polyline(offsets)
        let matcher = RouteEdgeMatcher(network: net)
        let m = matcher.match(polyline)
        #expect(Self.ways(m) == [11, 10, 13] && m.coverage > 0.99, "\(Self.ways(m)) \(m.coverage)")
        let ranges = [0...0, 0...1, 1...5, 5...6]
        let route = try Route(
            id: "ring", polyline: polyline.points,
            steps: ranges.map { RouteStep(instruction: "", distanceM: 0, polylineRange: $0, maneuver: .straight) },
            distanceM: polyline.lengthM, expectedTravelTimeS: 60, source: .synthetic
        )
        let contexts = matcher.roadContexts(for: route, match: m)
        // Passed: SE (roundabout piece, no), E (entry only, no), NE (exit, yes); left at N: exit 2.
        #expect(contexts[1]?.roundabout == true && contexts[1]?.roundaboutExit == 2)
    }
}
