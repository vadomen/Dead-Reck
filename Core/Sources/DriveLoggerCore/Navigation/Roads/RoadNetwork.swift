import Foundation

/// One or more road packs used together (docs/ROAD_PACK.md, "Duplicates
/// across packs").
///
/// **Canonical order (N3.2c item 7).** The network depends on the SET of
/// packs, never on the order a caller passed them: `init` sorts the packs
/// by ascending `contentHash`, and every pack index below (`packs`,
/// `SegmentRef.pack`, the matcher's global edge numbering, a result's
/// `MatchedRoadEdge.pack`) is an index into that canonical order. The same
/// pack twice (equal content hash) is refused, wherever it appears.
///
/// Every pack must have the same grid ID, so a cell is the same area in
/// each. A segment present in several packs (overlapping extracts) has the
/// same key (osmWayID, way point index) in each, because extracts use
/// `--strategy complete_ways`; the canonically first pack that contains the
/// key (lowest content hash) wins and the other copies are dropped from
/// every query. Which copy wins matters: it decides the edge a particle is
/// on, so the level rule's adjacency (within one pack only) and the matched
/// edge. The road set's identity is `roadSetHash`, FNV-1a 64 over the
/// content hashes in ascending order.
///
/// Data: © OpenStreetMap contributors, ODbL 1.0.
public final class RoadNetwork: @unchecked Sendable {
    // @unchecked: immutable after init; `RoadPack` is read-only.

    /// The packs in canonical order: ascending `contentHash`.
    public let packs: [RoadPack]
    public let grid: RoadGrid
    public let gridID: UInt64
    public let roadSetHash: UInt64
    /// Per pack, the shape-point bounding box (south-west, north-east), for
    /// coverage without `COVR` and for skipping packs in a key lookup.
    public let bounds: [(southWest: RoadPoint, northEast: RoadPoint)?]
    private let coverage: [[[RoadPoint]]?]

    public static let attribution = RoadPackFormat.attribution

    /// A segment in the network: the pack it comes from (canonical order)
    /// and its start point in that pack.
    public struct SegmentRef: Hashable, Comparable, Sendable {
        public var pack: Int
        public var startPoint: Int

        public init(pack: Int, startPoint: Int) {
            self.pack = pack
            self.startPoint = startPoint
        }

        public static func < (a: SegmentRef, b: SegmentRef) -> Bool {
            (a.pack, a.startPoint) < (b.pack, b.startPoint)
        }
    }

    /// Throws for no packs, packs on different grids, or the same pack
    /// (content hash) given more than once. Errors are judged in the order
    /// given; the network itself is built in canonical order.
    public init(packs given: [RoadPack]) throws {
        guard let first = given.first else { throw RoadPackError.noPacks }
        for (i, pack) in given.enumerated() {
            guard pack.gridID == first.gridID else { throw RoadPackError.gridMismatch(first.gridID, pack.gridID) }
            if given[..<i].contains(where: { $0.contentHash == pack.contentHash }) {
                throw RoadPackError.duplicatePack(pack.contentHash)
            }
        }
        // Content hashes are distinct here, so this is a strict total order.
        let packs = given.sorted { $0.contentHash < $1.contentHash }
        self.packs = packs
        grid = first.grid
        gridID = first.gridID
        roadSetHash = RoadPackFormat.roadSetHash(packs.map(\.contentHash))
        bounds = packs.map { $0.pointBounds() }
        coverage = try packs.map { try $0.coverageRings() }
    }

    public var roadSetHashHex: String { NavigationSeed.hex(roadSetHash) }

    /// The packs' summaries in canonical order.
    public var infos: [RoadPackInfo] { packs.map(\.info) }

    /// The segment's data.
    public func segment(_ ref: SegmentRef) -> RoadPack.Segment {
        packs[ref.pack].segment(startingAt: ref.startPoint)
    }

    /// Whether `key` is in a pack before `pack` in canonical order.
    public func isShadowed(_ key: RoadSegmentKey, inPack pack: Int) -> Bool {
        for earlier in 0..<pack where packs[earlier].segment(withKey: key) != nil { return true }
        return false
    }

    /// Calls `body` with every de-duplicated segment listed in the cell:
    /// pack by pack in canonical order, each pack's segments ascending. These
    /// include every segment within `grid.searchRadiusM` true metres of any
    /// point in the cell.
    public func forEachSegment(inCellX cx: Int32, y cy: Int32, _ body: (SegmentRef) -> Void) {
        for p in packs.indices {
            let pack = packs[p]
            pack.forEachSegment(inCellX: cx, y: cy) { start in
                if p > 0 {
                    let s = pack.segment(startingAt: start)
                    if isShadowed(s.key, inPack: p) { return }
                }
                body(SegmentRef(pack: p, startPoint: start))
            }
        }
    }

    /// The de-duplicated segments listed in the cell of a position.
    public func segments(nearLatitude latitude: Double, longitude: Double) -> [SegmentRef] {
        let c = grid.cell(latitude: latitude, longitude: longitude)
        var out: [SegmentRef] = []
        forEachSegment(inCellX: c.cx, y: c.cy) { out.append($0) }
        return out
    }

    /// Whether a position lies inside some pack's coverage: its `COVR`
    /// polygon (even-odd) if present, else its shape-point bounding box.
    public func covers(latitude: Double, longitude: Double) -> Bool {
        let latE7 = latitude * 1e7, lonE7 = longitude * 1e7
        for p in packs.indices {
            if let rings = coverage[p] {
                if Self.evenOddContains(rings: rings, latE7: latE7, lonE7: lonE7) { return true }
            } else if let b = bounds[p],
                      latE7 >= Double(b.southWest.latE7), latE7 <= Double(b.northEast.latE7),
                      lonE7 >= Double(b.southWest.lonE7), lonE7 <= Double(b.northEast.lonE7) {
                return true
            }
        }
        return false
    }

    /// Point in polygon, even-odd rule over all rings.
    static func evenOddContains(rings: [[RoadPoint]], latE7 y: Double, lonE7 x: Double) -> Bool {
        var inside = false
        for ring in rings {
            var j = ring.count - 1
            for i in 0..<ring.count {
                let xi = Double(ring[i].lonE7), yi = Double(ring[i].latE7)
                let xj = Double(ring[j].lonE7), yj = Double(ring[j].latE7)
                if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi { inside.toggle() }
                j = i
            }
        }
        return inside
    }
}
