import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// N3.4 item 8 (b): a way that crosses the border between two region packs,
/// loaded together with a national pack. Synthetic packs near (0, 0) only;
/// the border is the line east = 0.
///
/// - **Complete ways** (what `osmium extract --strategy complete_ways`
///   produces): the crossing way is in full in both region packs and in the
///   national pack. Each pack splits it at its own junctions only, so the
///   edges differ between packs while the segment keys do not.
/// - **Split way** (a pack built without `complete_ways`: the nodes outside
///   the extract have no location, so the builder drops the segments next to
///   them and keeps the node indices). Each region pack holds one half; the
///   halves meet at one way node.
///
/// In both: every segment key once in every cell (no duplicate segments),
/// the union equals one pack built from all the ways, and the junctions on
/// each side of the border link to every copy of the crossing way.
@Suite("Road packs across a border (N3.4 item 8)")
struct RoadPackBorderTests {
    typealias N = RoadFixture.Node

    /// The crossing way (primary, so the national pack keeps it): west to
    /// east through the border; node 701 is region A's junction, 703 region B's.
    static let crossing: [N] = [
        N(id: 700, east: -900, north: 0), N(id: 701, east: -400, north: 0), N(id: 702, east: 0, north: 0),
        N(id: 703, east: 400, north: 0), N(id: 704, east: 900, north: 0),
    ]
    static let crossingTags = ["highway": "primary"]
    /// A street only in region A, ending on the crossing way at node 701.
    static let streetA = RoadFixture.way(71, ["highway": "residential"], [
        N(id: 710, east: -400, north: -600), N(id: 701, east: -400, north: 0),
    ])
    /// A street only in region B, starting on the crossing way at node 703.
    static let streetB = RoadFixture.way(72, ["highway": "residential"], [
        N(id: 703, east: 400, north: 0), N(id: 720, east: 400, north: 600),
    ])

    /// The crossing way with the nodes in `unlocated` written without a
    /// location (`n<id>xy`), as an extract without `complete_ways` gives it.
    static func crossingWay(unlocated: Set<Int64> = []) -> String {
        var line = RoadFixture.way(70, crossingTags, crossing)
        for node in crossing where unlocated.contains(node.id) {
            let p = node.point
            line = line.replacingOccurrences(
                of: "n\(node.id)x\(RoadFixture.degrees(p.lonE7))y\(RoadFixture.degrees(p.latE7))", with: "n\(node.id)xy")
        }
        return line
    }

    static func edgeRef(_ net: RoadNetwork, _ pack: RoadPack, way: Int64) throws -> [RoadNetwork.EdgeRef] {
        let p = try #require(net.packs.firstIndex { $0 === pack })
        return RoadFixture.edgeIndices(of: pack, way: way).map { RoadNetwork.EdgeRef(pack: p, edge: $0) }
    }

    /// Every cell any pack of the network lists.
    static func cells(_ net: RoadNetwork) -> [UInt64] {
        Set(net.packs.flatMap { pack in (0..<pack.cellCount).map { pack.cellKey($0) } }).sorted()
    }

    /// No duplicate segments: in every cell each key once, and the cell's
    /// key set equals the reference pack's (all ways in one pack). Returns
    /// the pack each key of the crossing way came from.
    static func expectNoDuplicates(_ net: RoadNetwork, reference: RoadPack) -> [RoadSegmentKey: Set<Int>] {
        var winner: [RoadSegmentKey: Set<Int>] = [:]
        var union = Set<RoadSegmentKey>()
        for key in cells(net) {
            let c = RoadGrid.cell(ofKey: key)
            var keys: [RoadSegmentKey] = []
            net.forEachSegment(inCellX: c.cx, y: c.cy) { ref in
                let k = net.segment(ref).key
                keys.append(k)
                if k.osmWayID == 70 { winner[k, default: []].insert(ref.pack) }
            }
            #expect(keys.count == Set(keys).count, "duplicate segment in cell \(key)")
            let expected = Set(reference.segments(inCellX: c.cx, y: c.cy).map { reference.segment(startingAt: $0).key })
            #expect(Set(keys) == expected, "cell \(key)")
            union.formUnion(keys)
        }
        let all = Set((0..<reference.pointCount).compactMap { i -> RoadSegmentKey? in
            let r = reference.edge(reference.edgeOfPoint(i))
            return i + 1 < Int(r.firstPoint + r.pointCount) ? reference.segment(startingAt: i).key : nil
        })
        #expect(union == all)
        #expect(Set(union.filter { $0.osmWayID == 70 }.map(\.index)) == [0, 1, 2, 3])
        return winner
    }

    /// The edges of way 70, over every pack, whose way-node range holds `index`.
    static func crossingEdges(_ net: RoadNetwork, holding index: UInt32) -> [RoadNetwork.EdgeRef] {
        net.packs.indices.flatMap { p in
            net.packs[p].edgeRange(ofWay: 70).compactMap { e -> RoadNetwork.EdgeRef? in
                let r = net.packs[p].edge(e)
                return r.wayPointOffset <= index && index < r.wayPointOffset + r.pointCount ? .init(pack: p, edge: e) : nil
            }
        }
    }

    @Test("Complete ways: a way in full in both region packs and the national pack: no duplicate segment, junctions on both sides link to every copy")
    func completeWays() throws {
        let regionA = try RoadFixture.build([Self.crossingWay(), Self.streetA])
        let regionB = try RoadFixture.build([Self.crossingWay(), Self.streetB])
        let national = try RoadFixture.build([Self.crossingWay(), Self.streetA, Self.streetB],
                                             classes: RoadGraphBuilder.nationalClasses)
        let reference = try RoadFixture.build([Self.crossingWay(), Self.streetA, Self.streetB])
        // Each pack splits the crossing way at its own junctions only.
        #expect(RoadFixture.edges(of: regionA, way: 70).map(\.wayPointOffset) == [0, 1])
        #expect(RoadFixture.edges(of: regionB, way: 70).map(\.wayPointOffset) == [0, 3])
        #expect(RoadFixture.edges(of: national, way: 70).map(\.wayPointOffset) == [0])
        #expect(RoadFixture.edges(of: national, way: 71).isEmpty && RoadFixture.edges(of: national, way: 72).isEmpty)

        let sets: [[RoadPack]] = [
            [regionA, regionB], [regionB, regionA],
            [regionA, regionB, national], [national, regionB, regionA], [regionB, national, regionA],
        ]
        var roadSetHashes = Set<UInt64>()
        for given in sets {
            let net = try RoadNetwork(packs: given)
            if given.count == 3 { roadSetHashes.insert(net.roadSetHash) }
            let winner = Self.expectNoDuplicates(net, reference: reference)
            // One copy of the crossing way serves every one of its keys.
            #expect(Set(winner.values.flatMap { $0 }).count == 1)

            let streetA = try #require(Self.edgeRef(net, regionA, way: 71).first)
            let streetB = try #require(Self.edgeRef(net, regionB, way: 72).first)
            // Junction 701 (way index 1) and 703 (index 3): every copy of the
            // crossing way that holds the node links to the street, both ways
            // round, whether the node is an edge end or interior in that copy.
            for (street, index) in [(streetA, UInt32(1)), (streetB, UInt32(3))] {
                let copies = Self.crossingEdges(net, holding: index)
                #expect(Set(copies.map(\.pack)).count == given.count)
                let fromStreet = Set(net.adjacentEdges(of: street))
                for copy in copies {
                    #expect(fromStreet.contains(copy), "street \(street) -> copy \(copy)")
                    #expect(net.adjacentEdges(of: copy).contains(street), "copy \(copy) -> street \(street)")
                }
            }
            // Across the border: street A -> crossing way -> street B.
            #expect(net.isEdge(streetB, withinHops: 2, of: streetA))
            #expect(net.isEdge(streetA, withinHops: 2, of: streetB))
            #expect(!net.isEdge(streetB, withinHops: 1, of: streetA))
        }
        #expect(roadSetHashes.count == 1)
    }

    @Test("Split way: each region pack holds one half of the crossing way (no complete_ways): the halves meet at one way node, no duplicate, no gap")
    func splitWay() throws {
        // Region A has the way's nodes up to the border, region B from it.
        let regionA = try RoadFixture.build([Self.crossingWay(unlocated: [703, 704]), Self.streetA])
        let regionB = try RoadFixture.build([Self.crossingWay(unlocated: [700, 701]), Self.streetB])
        let reference = try RoadFixture.build([Self.crossingWay(), Self.streetA, Self.streetB])
        let halfA = RoadFixture.edges(of: regionA, way: 70)
        let halfB = RoadFixture.edges(of: regionB, way: 70)
        #expect(halfA.map(\.wayPointOffset) == [0, 1] && halfA.map(\.pointCount) == [2, 2])
        #expect(halfB.map(\.wayPointOffset) == [2, 3] && halfB.map(\.pointCount) == [2, 2])

        for given in [[regionA, regionB], [regionB, regionA]] {
            let net = try RoadNetwork(packs: given)
            let winner = Self.expectNoDuplicates(net, reference: reference)
            // Nothing to shadow: each key has exactly one copy, in its own half.
            let a = try #require(net.packs.firstIndex { $0 === regionA })
            let b = try #require(net.packs.firstIndex { $0 === regionB })
            for (key, packs) in winner { #expect(packs == (key.index < 2 ? [a] : [b]), "key \(key.index)") }

            // The border node (way index 2) ends one edge in each half: they link.
            let atBorder = Self.crossingEdges(net, holding: 2)
            #expect(Set(atBorder.map(\.pack)) == [a, b])
            for e in atBorder {
                for f in atBorder where f != e { #expect(net.adjacentEdges(of: e).contains(f)) }
            }
            let streetA = try #require(Self.edgeRef(net, regionA, way: 71).first)
            let streetB = try #require(Self.edgeRef(net, regionB, way: 72).first)
            // street A -> half A (701..702) -> half B (702..703) -> street B.
            #expect(net.isEdge(streetB, withinHops: 3, of: streetA))
            #expect(!net.isEdge(streetB, withinHops: 2, of: streetA))
        }
    }
}
