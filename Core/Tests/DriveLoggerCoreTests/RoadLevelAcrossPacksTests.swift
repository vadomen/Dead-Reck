import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// N3.2e item 1: the level rule's adjacency across packs. An edge in one
/// pack that continues an edge in another pack is adjacent to it, so a car
/// can change level where two packs meet (docs/N3_PLAN.md, "Layer, bridge
/// and tunnel rule"). Synthetic packs near (0, 0) only.
///
/// A pack stores no OSM node IDs (`NODE` holds coordinates only), so two
/// edges in different packs share an OSM node when either:
/// - **way node:** they hold the same node of the same way, by the
///   pack-independent (osmWayID, normalised node index) that segment keys
///   use; or
/// - **coordinate:** they hold a point with equal E7 coordinates that is an
///   end (topological node) of at least one of them.
///
/// Every test here except the non-matches (`nearbyIsNotEqual`,
/// `equalInteriorPointIsNotANode`) fails on the engine before item 1:
/// across packs there was no adjacency, so the candidate on the other level
/// was blocked.
@Suite("Road level rule across packs (N3.2e item 1)")
struct RoadLevelAcrossPacksTests {
    typealias S = SyntheticDrive
    typealias R = NavigationRoadTests
    typealias N = RoadFixture.Node

    /// One E7 unit of latitude, in metres (≈ 1.1 cm).
    static let oneE7North = RoadFixture.metresPerE7.lat

    static let bridgeTags = ["highway": "primary", "bridge": "yes", "layer": "1"]

    /// A level-0 street (way 10) north–south along x = 0, ending at
    /// A = (0, 0), node `endID`.
    static func street(endID: Int64 = 1) -> String {
        RoadFixture.way(10, ["highway": "residential"], [
            N(id: 100, east: 0, north: -1500), N(id: 101, east: 0, north: -700), N(id: endID, east: 0, north: 0),
        ])
    }

    /// A level-1 bridge (way 12) east–west along y = `north`, through
    /// (0, `north`) as an interior point (node `id`).
    static func bridgeThrough(id: Int64, north: Double = 0) -> String {
        RoadFixture.way(12, bridgeTags, [
            N(id: 120, east: -1500, north: north), N(id: id, east: 0, north: north), N(id: 121, east: 1500, north: north),
        ])
    }

    /// Global matcher edge index of `way`'s first edge in `pack`.
    static func globalEdge(_ net: RoadNetwork, _ pack: RoadPack, way: Int64) throws -> UInt32 {
        let p = try #require(net.packs.firstIndex { $0 === pack })
        let local = try #require(RoadFixture.edgeIndices(of: pack, way: way).first)
        return UInt32(RoadMatcher(network: net).edgeBase[p] + local)
    }

    /// One road update with every particle at `at`, heading `heading`, on
    /// `edge` at `level`.
    static func update(_ net: RoadNetwork, at p: (east: Double, north: Double), heading: Double, edge: UInt32,
                       level: Int8, _ edit: (inout NavigationConfig) -> Void = { _ in }) -> NavigationEngine {
        var engine = R.directEngine(net, edit)
        R.place(&engine, at: p, heading: heading, edge: edge, level: level)
        engine.roadUpdate(evidenceDistanceM: 30)
        return engine
    }

    // MARK: Coordinate

    /// The street in one pack, the bridge in another; the street's end A is
    /// an interior point of the bridge (the bridge's pack does not hold the
    /// street, so A is no junction there). The two node IDs at A differ, so
    /// only the coordinate links them. Both directions: street → bridge and
    /// bridge → street.
    @Test("Coordinate: a street ending on another pack's bridge (equal E7, no shared ID) links in both directions")
    func coordinateBothDirections() throws {
        let local = try RoadFixture.build([Self.street(endID: 1)])
        let national = try RoadFixture.build([Self.bridgeThrough(id: 2)], classes: RoadGraphBuilder.nationalClasses)
        let net = try RoadNetwork(packs: [local, national])
        let street = try Self.globalEdge(net, local, way: 10)
        let bridge = try Self.globalEdge(net, national, way: 12)
        #expect(local.edge(0).level == 0 && national.edge(0).level == 1)

        // On the street (level 0), at the bridge 300 m east of A, heading
        // east: the bridge is the only candidate.
        let up = Self.update(net, at: (300, 2), heading: .pi / 2, edge: street, level: 0)
        #expect(up.counters.roadUpdates == 1)
        #expect(up.counters.roadLevelBlocked == 0)
        #expect(up.roadEdge.allSatisfy { $0 == bridge } && up.roadLevel.allSatisfy { $0 == 1 })

        // On the bridge (level 1), at the street 300 m south of A, heading
        // north: the street is the only candidate.
        let down = Self.update(net, at: (2, -300), heading: 0, edge: bridge, level: 1)
        #expect(down.counters.roadUpdates == 1)
        #expect(down.counters.roadLevelBlocked == 0)
        #expect(down.roadEdge.allSatisfy { $0 == street } && down.roadLevel.allSatisfy { $0 == 0 })
    }

    /// The same street and bridge, but the bridge passes 1 E7 unit (≈ 1 cm)
    /// north of A: no shared point, no link. Passes before and after item 1.
    @Test("Non-match: a bridge 1 E7 unit (about 1 cm) from the street's end does not link; the level rule still blocks it")
    func nearbyIsNotEqual() throws {
        let local = try RoadFixture.build([Self.street(endID: 1)])
        let national = try RoadFixture.build([Self.bridgeThrough(id: 2, north: Self.oneE7North)],
                                             classes: RoadGraphBuilder.nationalClasses)
        let a = RoadFixture.points(of: local, edge: 0).last!
        let b = RoadFixture.points(of: national, edge: 0)[1]
        #expect(b.latE7 == a.latE7 + 1 && b.lonE7 == a.lonE7)
        let net = try RoadNetwork(packs: [local, national])
        let street = try Self.globalEdge(net, local, way: 10)
        let bridge = try Self.globalEdge(net, national, way: 12)
        let up = Self.update(net, at: (300, 2), heading: .pi / 2, edge: street, level: 0)
        #expect(up.counters.roadUpdates == 1)
        #expect(up.counters.roadLevelBlocked == up.east.count)
        #expect(up.roadEdge.allSatisfy { $0 == street } && up.roadLevel.allSatisfy { $0 == 0 })
        // Hops never reach it, however many.
        let far = Self.update(net, at: (300, 2), heading: .pi / 2, edge: street, level: 0) { $0.roadLevelHops = 10 }
        #expect(far.counters.roadLevelBlocked == far.east.count)
        _ = bridge
    }

    /// A street (way 10, pack "local") and a bridge (way 12, pack
    /// "national") crossing at A = (0, 0): both hold A as an equal E7 point,
    /// but it is interior to both edges (an end of neither), as where a
    /// bridge passes over a road with a coincident vertex. No shared OSM
    /// node, so no link: the level rule still blocks the bridge from the
    /// street and the street from the bridge. (R28.1-1: fails if any equal
    /// point linked.)
    @Test("Non-match: an equal E7 point interior to both edges (a crossing) does not link; the level rule still blocks")
    func equalInteriorPointIsNotANode() throws {
        let local = try RoadFixture.build([
            RoadFixture.way(10, ["highway": "residential"], [
                N(id: 100, east: 0, north: -1500), N(id: 1, east: 0, north: 0), N(id: 101, east: 0, north: 1500),
            ]),
        ])
        let national = try RoadFixture.build([Self.bridgeThrough(id: 2)], classes: RoadGraphBuilder.nationalClasses)
        #expect(local.edgeCount == 1 && national.edgeCount == 1)
        #expect(RoadFixture.points(of: local, edge: 0)[1] == RoadFixture.points(of: national, edge: 0)[1])
        for order in [[local, national], [national, local]] {
            let net = try RoadNetwork(packs: order)
            for p in net.packs.indices {
                #expect(net.adjacentEdges(of: .init(pack: p, edge: 0)).isEmpty)
            }
            let street = try Self.globalEdge(net, local, way: 10)
            let bridge = try Self.globalEdge(net, national, way: 12)
            for hops in [2, 10] {
                let up = Self.update(net, at: (300, 2), heading: .pi / 2, edge: street, level: 0) { $0.roadLevelHops = hops }
                #expect(up.counters.roadUpdates == 1)
                #expect(up.counters.roadLevelBlocked == up.east.count)
                #expect(up.roadEdge.allSatisfy { $0 == street } && up.roadLevel.allSatisfy { $0 == 0 })
                let down = Self.update(net, at: (2, -300), heading: 0, edge: bridge, level: 1) { $0.roadLevelHops = hops }
                #expect(down.counters.roadUpdates == 1)
                #expect(down.counters.roadLevelBlocked == down.east.count)
                #expect(down.roadEdge.allSatisfy { $0 == bridge } && down.roadLevel.allSatisfy { $0 == 1 })
            }
        }
    }

    // MARK: Way node

    /// Pack "old" holds the street and the first part of the bridge way
    /// (A → (700, 0)), joined at A. Pack "new" holds the whole bridge way
    /// with every point 1 E7 unit north (as if the nodes were moved between
    /// extracts): no coordinate is shared with "old". The bridge's second
    /// segment (700 → 1500 m) exists in "new" only. A particle on the
    /// street, at x = 1100 on the bridge, reaches "new"'s bridge edge in two
    /// hops: street → old bridge (shared node A, within "old") → new bridge
    /// (the same way node, way 12 index 0 and 1). So hops 2 admit it and
    /// hops 1 block it.
    @Test("Way node: the same node of the same way in two packs links them, with no equal coordinate (2 hops admits, 1 blocks)")
    func sameWayNode() throws {
        let old = try RoadFixture.build([
            Self.street(endID: 1),
            RoadFixture.way(12, Self.bridgeTags, [N(id: 1, east: 0, north: 0), N(id: 120, east: 700, north: 0)]),
        ])
        let new = try RoadFixture.build([
            RoadFixture.way(12, Self.bridgeTags, [
                N(id: 1, east: 0, north: Self.oneE7North), N(id: 120, east: 700, north: Self.oneE7North),
                N(id: 121, east: 1500, north: Self.oneE7North),
            ]),
        ], classes: RoadGraphBuilder.nationalClasses)
        let oldPoints = Set((0..<old.pointCount).map { old.point($0) })
        #expect((0..<new.pointCount).allSatisfy { !oldPoints.contains(new.point($0)) })
        let net = try RoadNetwork(packs: [old, new])
        let street = try Self.globalEdge(net, old, way: 10)
        let newBridge = try Self.globalEdge(net, new, way: 12)
        for (hops, admitted) in [(2, true), (1, false)] {
            let e = Self.update(net, at: (1100, 2), heading: .pi / 2, edge: street, level: 0) { $0.roadLevelHops = hops }
            #expect(e.counters.roadUpdates == 1, "hops \(hops)")
            #expect(e.counters.roadLevelBlocked == (admitted ? 0 : e.east.count), "hops \(hops)")
            if admitted {
                #expect(e.roadEdge.allSatisfy { $0 == newBridge } && e.roadLevel.allSatisfy { $0 == 1 }, "hops \(hops)")
            } else {
                #expect(e.roadEdge.allSatisfy { $0 == street } && e.roadLevel.allSatisfy { $0 == 0 }, "hops \(hops)")
            }
        }
    }

    // MARK: The adjacency itself

    /// `RoadNetwork.adjacentEdges` on the fixtures above: which edges link,
    /// symmetry, independence of the order the packs are given in, and one
    /// pack equal to that pack's own adjacency.
    @Test("adjacentEdges: the expected cross-pack links, symmetric, independent of pack order; one pack = RoadPack.isEdge")
    func adjacency() throws {
        let local = try RoadFixture.build([Self.street(endID: 1)])
        let national = try RoadFixture.build([Self.bridgeThrough(id: 2)], classes: RoadGraphBuilder.nationalClasses)
        let shifted = try RoadFixture.build([Self.bridgeThrough(id: 2, north: Self.oneE7North)],
                                            classes: RoadGraphBuilder.nationalClasses)
        let old = try RoadFixture.build([
            Self.street(endID: 1),
            RoadFixture.way(12, Self.bridgeTags, [N(id: 1, east: 0, north: 0), N(id: 120, east: 700, north: 0)]),
        ])
        #expect(old.edgeRange(ofWay: 12).count == 1 && old.edgeRange(ofWay: 10).count == 1)
        #expect(old.edgeRange(ofWay: 11).isEmpty && old.edgeRange(ofWay: 13).isEmpty && old.edgeRange(ofWay: 9).isEmpty)

        /// Every adjacency of a network as (pack content hash, edge) pairs.
        func links(_ net: RoadNetwork) -> Set<[UInt64]> {
            var out: Set<[UInt64]> = []
            for p in net.packs.indices {
                for e in 0..<net.packs[p].edgeCount {
                    for f in net.adjacentEdges(of: .init(pack: p, edge: e)) {
                        out.insert([net.packs[p].contentHash, UInt64(e), net.packs[f.pack].contentHash, UInt64(f.edge)])
                    }
                }
            }
            return out
        }
        func link(_ a: RoadPack, _ ae: Int, _ b: RoadPack, _ be: Int) -> [UInt64] {
            [a.contentHash, UInt64(ae), b.contentHash, UInt64(be)]
        }
        let street = RoadFixture.edgeIndices(of: local, way: 10)[0]
        let bridge = RoadFixture.edgeIndices(of: national, way: 12)[0]
        // Coordinate: exactly the street–bridge pair, both ways.
        for order in [[local, national], [national, local]] {
            #expect(links(try RoadNetwork(packs: order)) == [link(local, street, national, bridge), link(national, bridge, local, street)])
        }
        // 1 E7 unit apart: nothing.
        #expect(links(try RoadNetwork(packs: [local, shifted])).isEmpty)
        // Way node: "old"'s bridge part and "shifted"'s whole bridge, both
        // ways; within "old" the street and its bridge part.
        let oldStreet = RoadFixture.edgeIndices(of: old, way: 10)[0], oldBridge = RoadFixture.edgeIndices(of: old, way: 12)[0]
        let newBridge = RoadFixture.edgeIndices(of: shifted, way: 12)[0]
        for order in [[old, shifted], [shifted, old]] {
            #expect(links(try RoadNetwork(packs: order)) == [
                link(old, oldStreet, old, oldBridge), link(old, oldBridge, old, oldStreet),
                link(old, oldBridge, shifted, newBridge), link(shifted, newBridge, old, oldBridge),
            ])
        }
        // One pack: the pack's own adjacency, hop for hop.
        let one = try RoadNetwork(packs: [RoadFixture.build(RoadGraphTests.bridgeLines())])
        let pack = one.packs[0]
        for a in 0..<pack.edgeCount {
            for b in 0..<pack.edgeCount {
                for hops in 0...3 {
                    #expect(one.isEdge(.init(pack: 0, edge: b), withinHops: hops, of: .init(pack: 0, edge: a))
                            == pack.isEdge(b, withinHops: hops, of: a), "\(a) \(b) \(hops)")
                }
            }
        }
    }

    /// Way-node ranges that only touch: pack "old" holds way 12 nodes 0…1
    /// as one edge; in pack "split" way 13 joins way 12 at node 1, so way 12
    /// is two edges, nodes 0…1 and 1…2, every point 1 E7 unit north (no
    /// equal coordinate). "old"'s edge shares node 1 with both, so both are
    /// adjacent to it, not only the one whose range overlaps it.
    @Test("Way node: ranges touching at one node (0…1 and 1…2) link")
    func touchingWayNodeRanges() throws {
        let old = try RoadFixture.build([
            RoadFixture.way(12, Self.bridgeTags, [N(id: 1, east: 0, north: 0), N(id: 120, east: 700, north: 0)]),
        ])
        let y = Self.oneE7North
        let split = try RoadFixture.build([
            RoadFixture.way(12, Self.bridgeTags, [N(id: 1, east: 0, north: y), N(id: 120, east: 700, north: y), N(id: 121, east: 1500, north: y)]),
            RoadFixture.way(13, ["highway": "primary"], [N(id: 120, east: 700, north: y), N(id: 130, east: 700, north: 800)]),
        ], classes: RoadGraphBuilder.nationalClasses)
        let oldPoints = Set((0..<old.pointCount).map { old.point($0) })
        #expect((0..<split.pointCount).allSatisfy { !oldPoints.contains(split.point($0)) })
        let parts = RoadFixture.edgeIndices(of: split, way: 12)
        #expect(parts.map { split.edge($0).wayPointOffset } == [0, 1])
        let net = try RoadNetwork(packs: [old, split])
        let o = try #require(net.packs.firstIndex { $0 === old }), s = 1 - o
        let oldEdge = RoadNetwork.EdgeRef(pack: o, edge: RoadFixture.edgeIndices(of: old, way: 12)[0])
        #expect(net.adjacentEdges(of: oldEdge) == parts.map { RoadNetwork.EdgeRef(pack: s, edge: $0) })
        #expect(net.adjacentEdges(of: .init(pack: s, edge: parts[1])).contains(oldEdge))
    }

    // MARK: The level rule's memo

    /// `RoadMatcher.isEdge(_:withinHops:of:memo:)` with one memo shared by
    /// several questions, as in one road update: from the street, the
    /// bridge (another pack, linked at A) is within 1 hop and way 13 (the
    /// bridge's pack, linked to nothing) is not; from way 13 the bridge is
    /// not either. Every answer equals the unmemoised one, whatever the
    /// order the questions come in. (R28.1-2: fails if the key dropped
    /// either edge.)
    @Test("isEdge memo: answers for one particle edge and two candidates (and two particle edges, one candidate) stay distinct")
    func memoKeysBothEdges() throws {
        let local = try RoadFixture.build([Self.street(endID: 1)])
        let national = try RoadFixture.build([
            Self.bridgeThrough(id: 2),
            RoadFixture.way(13, ["highway": "primary"], [N(id: 130, east: 500, north: 500), N(id: 131, east: 1500, north: 500)]),
        ], classes: RoadGraphBuilder.nationalClasses)
        let net = try RoadNetwork(packs: [local, national])
        let matcher = RoadMatcher(network: net)
        let street = try Self.globalEdge(net, local, way: 10)
        let bridge = try Self.globalEdge(net, national, way: 12)
        let other = try Self.globalEdge(net, national, way: 13)
        let questions: [(a: UInt32, b: UInt32, expected: Bool)] = [
            (street, bridge, true), (street, other, false), (other, bridge, false),
        ]
        for q in questions {
            #expect(matcher.isEdge(q.b, withinHops: 1, of: q.a) == q.expected, "\(q.a) \(q.b)")
        }
        for order in [[0, 1, 2], [1, 0, 2], [2, 0, 1], [1, 2, 0]] {
            var memo: [UInt64: Bool] = [:]
            for _ in 0..<2 {
                for k in order {
                    let q = questions[k]
                    #expect(matcher.isEdge(q.b, withinHops: 1, of: q.a, memo: &memo) == q.expected, "\(order) \(k)")
                }
            }
            #expect(memo.count == questions.count)
        }
    }

    // MARK: A drive

    /// North on the street (pack "local") to A, a right turn, then east on
    /// the bridge (pack "national"). Clean fixes for the first 10 s only.
    /// The particles carry level 0 from the street; the bridge is never
    /// blocked, and is matched 50 m past A.
    @Test("A drive from a street in one pack onto a bridge in another: never level-blocked, on the bridge 50 m past the junction")
    func driveAcrossPacks() throws {
        let local = try RoadFixture.build([Self.street(endID: 1)])
        let national = try RoadFixture.build([Self.bridgeThrough(id: 2)], classes: RoadGraphBuilder.nationalClasses)
        let bridge = try Self.globalEdge(try RoadNetwork(packs: [local, national]), national, way: 12)
        let v = 12.0
        let drive = S(initialHeadingDeg: 0, initialSpeed: v, [
            .straight(seconds: 1200 / v, speed: v), .turn(degrees: 90, seconds: 1, speed: v), .straight(seconds: 30, speed: v),
        ])
        let clean = S.cleanFix()
        let inputs = R.shifted(drive, by: (0, -1200), fix: { t, s, r in t < 10 ? clean(t, s, &r) : nil })
        for order in [[local, national], [national, local]] {
            let net = try RoadNetwork(packs: order)
            var engine = NavigationEngine(config: R.config(particles: 300), roads: net)
            var shareAt50: Double?
            let turnAt = 1200 / v + 1
            for input in inputs {
                engine.ingest(input)
                let t = Double(input.arrival.nanoseconds) / 1e9
                if shareAt50 == nil, t >= turnAt + 50 / v {
                    shareAt50 = zip(engine.roadEdge, engine.weight).reduce(0.0) { $0 + ($1.0 == bridge ? $1.1 : 0) }
                }
            }
            #expect(engine.counters.roadUpdates > 50)
            #expect(engine.counters.roadLevelBlocked == 0)
            let share = try #require(shareAt50)
            #expect(share > 0.9, "share on the bridge 50 m past A: \(share)")
            #expect(engine.estimate(at: S.ms(drive.duration))?.matchedEdge?.osmWayID == 12)
        }
    }
}
