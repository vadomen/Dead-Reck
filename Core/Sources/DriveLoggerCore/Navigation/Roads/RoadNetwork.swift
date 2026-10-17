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
/// every query. Which copy wins decides the edge a particle is on and the
/// matched edge. The level rule's adjacency spans packs (`adjacentEdges`,
/// N3.2e item 1): before it, adjacency stopped at a pack border, so the
/// winning copy also decided whether a car could change level there. The
/// road set's identity is `roadSetHash`, FNV-1a 64 over the content hashes
/// in ascending order.
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
    /// The order `covers` tries the packs in: cheapest test first (a
    /// bounding box, then the fewest coverage vertices; ties by index). An
    /// OR over packs, so the order changes only the time (N3-FIXPIN: a
    /// national ring of ~80 k vertices took ~78 % of the road verdict).
    /// Internal for the test that `covers` equals the canonical-order OR.
    let coverageOrder: [Int]

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
        let coverage = try packs.map { try $0.coverageRings() }
        self.coverage = coverage
        coverageOrder = coverage.indices.sorted { a, b in
            let ca = coverage[a].map { $0.reduce(0) { $0 + $1.count } } ?? 0
            let cb = coverage[b].map { $0.reduce(0) { $0 + $1.count } } ?? 0
            return ca != cb ? ca < cb : a < b
        }
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

    // MARK: Adjacency (the level rule)

    /// An edge of the network: its pack (canonical order) and its index in
    /// that pack. Shadowed copies are edges too: adjacency is over every
    /// edge of every pack, as within one pack.
    public struct EdgeRef: Hashable, Comparable, Sendable {
        public var pack: Int
        public var edge: Int

        public init(pack: Int, edge: Int) {
            self.pack = pack
            self.edge = edge
        }

        public static func < (a: EdgeRef, b: EdgeRef) -> Bool {
            (a.pack, a.edge) < (b.pack, b.edge)
        }
    }

    /// The edges adjacent to `e` (one hop), ascending, `e` itself excluded
    /// (N3.2e item 1):
    /// - **within its pack:** every edge incident to one of its two nodes;
    /// - **in every other pack:** every edge that shares an OSM node with it.
    ///   A pack stores no OSM node IDs, so a shared node is either the same
    ///   node of the same way (same `osmWayID`, and their way-node index
    ///   ranges `wayPointOffset … wayPointOffset + pointCount − 1`
    ///   intersect: the pack-independent identity segment keys use), or a
    ///   point with equal E7 coordinates that is an end (a topological node)
    ///   of at least one of the two edges. Equal means equal: a point 1 E7
    ///   unit away does not link.
    ///
    /// A function of the pack set only (symmetric, and independent of the
    /// order the packs were given in). With one pack it is that pack's
    /// adjacency.
    public func adjacentEdges(of e: EdgeRef) -> [EdgeRef] {
        let pack = packs[e.pack]
        let record = pack.edge(e.edge)
        var out: [EdgeRef] = []
        for node in [Int(record.from), Int(record.to)] {
            for f in pack.incidentEdges(node) where f != e.edge { out.append(EdgeRef(pack: e.pack, edge: f)) }
        }
        if packs.count > 1 { appendCrossPackEdges(of: e, record: record, to: &out) }
        out.sort()
        var unique: [EdgeRef] = []
        for x in out where unique.last != x { unique.append(x) }
        return unique
    }

    /// Whether edge `b` is within `hops` of edge `a` in `adjacentEdges`: 0
    /// hops is the edge itself, 1 an adjacent edge, and so on. With one pack
    /// this is `RoadPack.isEdge`.
    public func isEdge(_ b: EdgeRef, withinHops hops: Int, of a: EdgeRef) -> Bool {
        if packs.count == 1 { return packs[0].isEdge(b.edge, withinHops: hops, of: a.edge) }
        if a == b { return true }
        guard hops > 0 else { return false }
        var frontier = [a]
        var seen: Set<EdgeRef> = [a]  // membership only, never iterated
        for _ in 0..<hops {
            var next: [EdgeRef] = []
            for e in frontier {
                for f in adjacentEdges(of: e) where !seen.contains(f) {
                    if f == b { return true }
                    seen.insert(f)
                    next.append(f)
                }
            }
            if next.isEmpty { return false }
            frontier = next
        }
        return false
    }

    @inline(__always)
    private static func coordinateKey(_ p: RoadPoint) -> UInt64 {
        UInt64(UInt32(bitPattern: p.latE7)) << 32 | UInt64(UInt32(bitPattern: p.lonE7))
    }

    /// Appends the edges of the other packs that share an OSM node with
    /// edge `e` (see `adjacentEdges`). Unsorted, possibly repeated.
    private func appendCrossPackEdges(of e: EdgeRef, record: RoadEdgeRecord, to out: inout [EdgeRef]) {
        let pack = packs[e.pack]
        let first = Int(record.firstPoint), count = Int(record.pointCount)
        let points = (first..<(first + count)).map { pack.point($0) }
        let keys = points.map(Self.coordinateKey)
        let sortedKeys = keys.sorted()
        let ends = (keys[0], keys[count - 1])
        func isPoint(_ k: UInt64) -> Bool {
            var lo = 0, hi = sortedKeys.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if sortedKeys[mid] < k { lo = mid + 1 } else { hi = mid }
            }
            return lo < sortedKeys.count && sortedKeys[lo] == k
        }
        // The cells holding a point of e: every segment that touches the
        // point is listed in its cell.
        var cells = points.map { p -> UInt64 in
            let c = grid.cell(latitude: p.latitude, longitude: p.longitude)
            return RoadGrid.key(cx: c.cx, cy: c.cy)
        }
        cells.sort()
        let lo = UInt64(record.wayPointOffset), hi = lo + UInt64(count) - 1
        for q in packs.indices where q != e.pack {
            let other = packs[q]
            // The same node of the same way.
            for f in other.edgeRange(ofWay: record.osmWayID) {
                let r = other.edge(f)
                let flo = UInt64(r.wayPointOffset), fhi = flo + UInt64(r.pointCount) - 1
                if flo <= hi && lo <= fhi { out.append(EdgeRef(pack: q, edge: f)) }
            }
            // An equal coordinate that is an end of e or of the other edge.
            var previous: UInt64?
            for cell in cells where cell != previous {
                previous = cell
                let c = RoadGrid.cell(ofKey: cell)
                other.forEachSegment(inCellX: c.cx, y: c.cy) { start in
                    for k in [Self.coordinateKey(other.point(start)), Self.coordinateKey(other.point(start + 1))] where isPoint(k) {
                        let f = other.edgeOfPoint(start)
                        let r = other.edge(f)
                        if k == ends.0 || k == ends.1
                            || k == Self.coordinateKey(other.node(Int(r.from))) || k == Self.coordinateKey(other.node(Int(r.to))) {
                            out.append(EdgeRef(pack: q, edge: f))
                        }
                    }
                }
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
        for p in coverageOrder {
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
