import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// N3.4 item 6 (engine side): the matched edge's shape for the map's debug
/// drawing, and `onRoadShare` in the snapshot's statistics. Synthetic drive
/// and packs near (0, 0) only.
@Suite("Matched edge geometry for the map (N3.4 item 6)")
struct MatchedEdgeGeometryTests {
    typealias A = NavigationRoadAttachTests
    typealias N = RoadFixture.Node

    /// Two ways meeting at node 2: way 5 (two edges after the split at
    /// node 3, shared with way 6) and way 6.
    static func twoWays() throws -> (RoadNetwork, RoadPack) {
        let pack = try RoadFixture.build([
            RoadFixture.way(5, ["highway": "residential"], [
                N(id: 1, east: 0, north: 0), N(id: 2, east: 0, north: 200), N(id: 3, east: 0, north: 400),
                N(id: 4, east: 0, north: 600),
            ]),
            RoadFixture.way(6, ["highway": "primary", "bridge": "yes"], [
                N(id: 3, east: 0, north: 400), N(id: 7, east: 300, north: 400),
            ]),
        ])
        return (try RoadNetwork(packs: [pack]), pack)
    }

    @Test("RoadNetwork.points(of:) gives the edge's shape points in order; nil for an edge of another network")
    func points() throws {
        let (net, pack) = try Self.twoWays()
        let edges = RoadFixture.edgeIndices(of: pack, way: 5)
        #expect(edges.count == 2)
        let first = MatchedRoadEdge(pack: 0, edge: edges[0], osmWayID: 5)
        #expect(net.points(of: first) == RoadFixture.points(of: pack, edge: edges[0]))
        #expect(net.points(of: first)?.first == RoadFixture.point(0, 0))
        #expect(net.points(of: first)?.last == RoadFixture.point(0, 400))
        #expect(net.points(of: MatchedRoadEdge(pack: 0, edge: edges[0], osmWayID: 6)) == nil)
        #expect(net.points(of: MatchedRoadEdge(pack: 1, edge: 0, osmWayID: 5)) == nil)
        #expect(net.points(of: MatchedRoadEdge(pack: 0, edge: pack.edgeCount, osmWayID: 5)) == nil)
        #expect(net.points(of: MatchedRoadEdge(pack: 0, edge: -1, osmWayID: 5)) == nil)
        let bridge = try #require(RoadFixture.edgeIndices(of: pack, way: 6).first)
        let g = try #require(MatchedEdgeGeometry(edge: MatchedRoadEdge(pack: 0, edge: bridge, osmWayID: 6), network: net))
        #expect(g.highwayClass == .primary && g.level == 1 && g.roadSetHash == net.roadSetHash)
        #expect(g.points == [RoadFixture.point(0, 400), RoadFixture.point(300, 400)])
    }

    @Test("Cache: rebuilt only when the edge or the network changes; nil edge or network gives nil and keeps the last")
    func cache() throws {
        let (net, pack) = try Self.twoWays()
        let (other, _) = try Self.twoWays()  // the same bytes: the same roadSetHash
        let edges = RoadFixture.edgeIndices(of: pack, way: 5)
        let a = MatchedRoadEdge(pack: 0, edge: edges[0], osmWayID: 5)
        let b = MatchedRoadEdge(pack: 0, edge: edges[1], osmWayID: 5)
        var cache = MatchedEdgeGeometry.Cache()
        for _ in 0..<10 { #expect(cache.geometry(for: a, in: net)?.edge == a) }
        #expect(cache.builds == 1)
        #expect(cache.geometry(for: nil, in: net) == nil)
        #expect(cache.geometry(for: a, in: nil) == nil)
        #expect(cache.geometry(for: a, in: other)?.edge == a)
        #expect(cache.builds == 1)
        #expect(cache.geometry(for: b, in: net)?.points == RoadFixture.points(of: pack, edge: edges[1]))
        #expect(cache.builds == 2)
        // Another network (another roadSetHash), same indices: rebuilt.
        let shifted = try RoadNetwork(packs: [RoadFixture.build([
            RoadFixture.way(5, ["highway": "residential"], [N(id: 1, east: 50, north: 0), N(id: 3, east: 50, north: 400),
                                                            N(id: 4, east: 50, north: 600)]),
            RoadFixture.way(6, ["highway": "residential"], [N(id: 3, east: 50, north: 400), N(id: 7, east: 300, north: 400)]),
        ])])
        #expect(shifted.roadSetHash != net.roadSetHash)
        let rebuilt = cache.geometry(for: b, in: shifted)
        let moved = try #require(rebuilt)
        #expect(moved.roadSetHash == shifted.roadSetHash && moved.points.first == RoadFixture.point(50, 400))
        #expect(cache.builds == 3)
        // An edge the network does not have: nil, nothing built.
        #expect(cache.geometry(for: MatchedRoadEdge(pack: 3, edge: 0, osmWayID: 5), in: net) == nil)
        #expect(cache.builds == 3)
    }

    @Test("Live run: snapshots carry the matched edge's shape and onRoadShare; one build over many polls; none without roads")
    func liveSnapshots() throws {
        let net = try A.network()
        let inputs = A.inputs()
        var run = LiveNavigationRun(sessionID: A.sessionID, config: A.config(), appBuild: "test", roads: net)
        var bare = LiveNavigationRun(sessionID: A.sessionID, config: A.config(), appBuild: "test")
        var cache = MatchedEdgeGeometry.Cache()
        var bareCache = MatchedEdgeGeometry.Cache()
        var polls = 0, matched = 0
        for (i, input) in inputs.enumerated() {
            run.ingest(input) { _ in }
            bare.ingest(input) { _ in }
            guard i % 10 == 0 else { continue }
            let t = run.engine.latestArrival ?? .zero
            let s = run.snapshot(at: t, droppedInputs: 0, edgeGeometry: &cache)
            polls += 1
            #expect(s.stats.onRoadShare == s.estimate?.onRoadShare)
            #expect(run.snapshot(at: t, droppedInputs: 0).matchedEdgeGeometry == nil)
            if let edge = s.estimate?.matchedEdge {
                matched += 1
                let g = try #require(s.matchedEdgeGeometry)
                #expect(g.edge == edge && g.roadSetHash == net.roadSetHash)
                #expect(g.points == net.points(of: edge))
            } else {
                #expect(s.matchedEdgeGeometry == nil)
            }
            let b = bare.snapshot(at: bare.engine.latestArrival ?? .zero, droppedInputs: 0, edgeGeometry: &bareCache)
            #expect(b.matchedEdgeGeometry == nil && b.stats.onRoadShare == nil)
        }
        #expect(matched > 100 && polls > matched)
        // One way, one edge: built once for every poll that had a match.
        #expect(cache.builds == 1)
        #expect(bareCache.builds == 0)
    }
}
