import Foundation

/// A road graph ready to be written as a pack: edges with their shape
/// points, end nodes identified by an opaque ID (the OSM node ID from the
/// builder). Order does not matter; the writer makes it canonical.
public struct RoadGraph: Hashable, Sendable {
    public struct Edge: Hashable, Sendable {
        /// Opaque ID of the first point's node (shared by every edge that
        /// starts or ends there).
        public var fromNode: Int64
        public var toNode: Int64
        /// Shape points in driving order (forward for a oneway), both end
        /// nodes included.
        public var points: [RoadPoint]
        public var osmWayID: Int64
        public var wayPointOffset: UInt32
        public var highwayClass: RoadClass
        public var level: Int8
        public var flags: RoadEdgeFlags
        public var lanes: UInt8

        public init(
            fromNode: Int64, toNode: Int64, points: [RoadPoint], osmWayID: Int64, wayPointOffset: UInt32,
            highwayClass: RoadClass, level: Int8 = 0, flags: RoadEdgeFlags = [], lanes: UInt8 = 0
        ) {
            self.fromNode = fromNode
            self.toNode = toNode
            self.points = points
            self.osmWayID = osmWayID
            self.wayPointOffset = wayPointOffset
            self.highwayClass = highwayClass
            self.level = level
            self.flags = flags
            self.lanes = lanes
        }
    }

    public var edges: [Edge]

    public init(edges: [Edge] = []) {
        self.edges = edges
    }

    /// The bounding box of every point, (south-west, north-east).
    public var bounds: (southWest: RoadPoint, northEast: RoadPoint)? {
        var minLat = Int32.max, minLon = Int32.max, maxLat = Int32.min, maxLon = Int32.min
        var any = false
        for edge in edges {
            for p in edge.points {
                any = true
                minLat = min(minLat, p.latE7); maxLat = max(maxLat, p.latE7)
                minLon = min(minLon, p.lonE7); maxLon = max(maxLon, p.lonE7)
            }
        }
        return any ? (RoadPoint(latE7: minLat, lonE7: minLon), RoadPoint(latE7: maxLat, lonE7: maxLon)) : nil
    }
}

/// Writes road packs (docs/ROAD_PACK.md). Deterministic: the same graph
/// (in any edge order), grid, timestamp, metadata and coverage give the
/// same bytes.
///
/// Canonical order: edges by (osmWayID, wayPointOffset); nodes by first
/// appearance as an edge's `from`, then `to`, in that order; cells by key;
/// each cell's segments by start point.
public struct RoadPackWriter {
    public var grid: RoadGrid
    /// Unix seconds UTC of the source extract; 0 = unknown.
    public var osmTimestamp: Int64
    /// `META` content. `attribution` and `license` are always set by the
    /// writer.
    public var meta: [String: JSONValue]
    /// Coverage rings (even-odd rule), or nil for "the bounding box".
    public var coverage: [[RoadPoint]]?
    /// A pack larger than this is refused (nil: no limit).
    public var sizeLimit: Int?

    public init(
        grid: RoadGrid, osmTimestamp: Int64 = 0, meta: [String: JSONValue] = [:],
        coverage: [[RoadPoint]]? = nil, sizeLimit: Int? = RoadPackFormat.maximumFileSize
    ) {
        self.grid = grid
        self.osmTimestamp = osmTimestamp
        self.meta = meta
        self.coverage = coverage
        self.sizeLimit = sizeLimit
    }

    /// Index statistics of a written pack.
    public struct Statistics: Hashable, Sendable, Codable {
        public var nodes = 0
        public var edges = 0
        public var points = 0
        public var segments = 0
        public var cells = 0
        public var cellEntries = 0
        /// R_eff, the frame radius used for the index.
        public var effectiveRadiusM = 0.0
        public var fileSize = 0
    }

    /// The pack's bytes.
    public func write(_ graph: RoadGraph) throws -> Data {
        try writeWithStatistics(graph).data
    }

    /// The pack's bytes and its index statistics.
    public func writeWithStatistics(_ graph: RoadGraph) throws -> (data: Data, statistics: Statistics) {
        if let reason = grid.invalidReason { throw RoadPackError.invalidContent(reason) }

        // Canonical edge order, unique keys.
        let edges = graph.edges.sorted { ($0.osmWayID, $0.wayPointOffset) < ($1.osmWayID, $1.wayPointOffset) }
        for i in edges.indices {
            let e = edges[i]
            guard e.points.count >= 2 else { throw RoadPackError.invalidContent("way \(e.osmWayID) offset \(e.wayPointOffset): fewer than 2 points") }
            guard RoadGeometry.levelRange.contains(e.level) else { throw RoadPackError.invalidContent("way \(e.osmWayID): level \(e.level)") }
            guard UInt64(e.wayPointOffset) + UInt64(e.points.count) <= UInt64(UInt32.max) else {
                throw RoadPackError.invalidContent("way \(e.osmWayID): offset overflow")
            }
            if i > 0, edges[i - 1].osmWayID == e.osmWayID, edges[i - 1].wayPointOffset == e.wayPointOffset {
                throw RoadPackError.invalidContent("duplicate edge key (way \(e.osmWayID), offset \(e.wayPointOffset))")
            }
        }
        guard edges.count < Int(UInt32.max) else { throw RoadPackError.invalidContent("too many edges") }

        // Nodes by first appearance. The dictionary is lookup-only.
        var nodeIndex: [Int64: UInt32] = [:]
        var nodes: [RoadPoint] = []
        func index(of id: Int64, at point: RoadPoint) throws -> UInt32 {
            if let i = nodeIndex[id] {
                guard nodes[Int(i)] == point else { throw RoadPackError.invalidContent("node \(id) has two positions") }
                return i
            }
            let i = UInt32(nodes.count)
            nodeIndex[id] = i
            nodes.append(point)
            return i
        }
        var records: [RoadEdgeRecord] = []
        records.reserveCapacity(edges.count)
        var pointTotal = 0
        for e in edges {
            let from = try index(of: e.fromNode, at: e.points[0])
            let to = try index(of: e.toNode, at: e.points[e.points.count - 1])
            var length = 0.0
            for k in 1..<e.points.count { length += RoadGeometry.distanceM(from: e.points[k - 1], to: e.points[k]) }
            let dm = (length * 10).rounded()
            records.append(RoadEdgeRecord(
                from: from, to: to, firstPoint: UInt32(pointTotal), pointCount: UInt32(e.points.count),
                osmWayID: e.osmWayID, wayPointOffset: e.wayPointOffset,
                lengthDm: dm >= Double(UInt32.max) ? UInt32.max : UInt32(dm),
                highwayClass: e.highwayClass, level: e.level,
                flags: RoadEdgeFlags(rawValue: e.flags.rawValue & RoadEdgeFlags.known), lanes: e.lanes
            ))
            pointTotal += e.points.count
            guard pointTotal < Int(UInt32.max) else { throw RoadPackError.invalidContent("too many points") }
        }

        // Adjacency (CSR, each node's edges ascending, a self-loop once).
        var degree = [UInt32](repeating: 0, count: nodes.count + 1)
        for r in records {
            degree[Int(r.from)] += 1
            if r.to != r.from { degree[Int(r.to)] += 1 }
        }
        var adjacencyOffsets = [UInt32](repeating: 0, count: nodes.count + 1)
        for n in 0..<nodes.count { adjacencyOffsets[n + 1] = adjacencyOffsets[n] + degree[n] }
        var fill = adjacencyOffsets
        var adjacency = [UInt32](repeating: 0, count: Int(adjacencyOffsets[nodes.count]))
        for (e, r) in records.enumerated() {  // ascending e, so each list is ascending
            adjacency[Int(fill[Int(r.from)])] = UInt32(e); fill[Int(r.from)] += 1
            if r.to != r.from { adjacency[Int(fill[Int(r.to)])] = UInt32(e); fill[Int(r.to)] += 1 }
        }

        // Grid index: (cell key, segment start point) pairs, sorted.
        let latitudes = edges.lazy.flatMap(\.points).map(\.latitude)
        let minLatitude = latitudes.min() ?? 0, maxLatitude = latitudes.max() ?? 0
        let radius = grid.effectiveRadiusM(minLatitude: minLatitude, maxLatitude: maxLatitude)
        var pairs: [(key: UInt64, start: UInt32)] = []
        var start = 0
        for e in edges {
            var a = grid.frame(e.points[0])
            for k in 1..<e.points.count {
                let b = grid.frame(e.points[k])
                let s = UInt32(start + k - 1)
                grid.forEachCell(nearSegmentFrom: a, to: b, radius: radius) { cx, cy in
                    pairs.append((RoadGrid.key(cx: cx, cy: cy), s))
                }
                a = b
            }
            start += e.points.count
        }
        pairs.sort { ($0.key, $0.start) < ($1.key, $1.start) }
        var cellKeys: [UInt64] = []
        var cellOffsets: [UInt32] = [0]
        var cellSegments: [UInt32] = []
        cellSegments.reserveCapacity(pairs.count)
        for p in pairs {
            if cellKeys.last != p.key {
                if !cellKeys.isEmpty { cellOffsets.append(UInt32(cellSegments.count)) }
                cellKeys.append(p.key)
            }
            cellSegments.append(p.start)
        }
        if !cellKeys.isEmpty { cellOffsets.append(UInt32(cellSegments.count)) }
        guard cellSegments.count < Int(UInt32.max) else { throw RoadPackError.invalidContent("index too large") }

        // META.
        var metaObject = meta
        metaObject["attribution"] = .string(RoadPackFormat.attribution)
        metaObject["license"] = .string(RoadPackFormat.license)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let metaBytes = Array(try encoder.encode(JSONValue.object(metaObject)))

        // Sections.
        typealias T = RoadPackFormat.Tag
        var sectionPayloads: [(tag: UInt32, bytes: [UInt8])] = []
        sectionPayloads.append((T.meta, metaBytes))
        var b = LittleEndianBytes()
        for n in nodes { b.append(n.latE7); b.append(n.lonE7) }
        sectionPayloads.append((T.nodes, b.bytes))
        b = LittleEndianBytes()
        for r in records {
            b.append(r.from); b.append(r.to); b.append(r.firstPoint); b.append(r.pointCount)
            b.append(r.osmWayID); b.append(r.wayPointOffset); b.append(r.lengthDm)
            b.append(r.highwayClass.rawValue); b.append(r.level); b.append(r.flags.rawValue); b.append(r.lanes)
            b.append(UInt32(0))
        }
        sectionPayloads.append((T.edges, b.bytes))
        b = LittleEndianBytes()
        var pointEdges = LittleEndianBytes()
        for (i, e) in edges.enumerated() {
            for p in e.points {
                b.append(p.latE7); b.append(p.lonE7)
                pointEdges.append(UInt32(i))
            }
        }
        sectionPayloads.append((T.points, b.bytes))
        sectionPayloads.append((T.pointEdges, pointEdges.bytes))
        sectionPayloads.append((T.adjacencyOffsets, Self.uint32Bytes(adjacencyOffsets)))
        sectionPayloads.append((T.adjacencyEdges, Self.uint32Bytes(adjacency)))
        b = LittleEndianBytes()
        for k in cellKeys { b.append(k) }
        sectionPayloads.append((T.cellKeys, b.bytes))
        sectionPayloads.append((T.cellOffsets, Self.uint32Bytes(cellOffsets)))
        sectionPayloads.append((T.cellSegments, Self.uint32Bytes(cellSegments)))
        if let rings = coverage {
            guard !rings.isEmpty, rings.allSatisfy({ $0.count >= 3 }) else {
                throw RoadPackError.invalidContent("coverage needs at least one ring of ≥ 3 points")
            }
            b = LittleEndianBytes()
            b.append(UInt32(rings.count))
            for ring in rings {
                b.append(UInt32(ring.count))
                for p in ring { b.append(p.latE7); b.append(p.lonE7) }
            }
            sectionPayloads.append((T.coverage, b.bytes))
        }

        // Assemble: header, section table, sections, each 8-byte aligned.
        let tableOffset = RoadPackFormat.headerSize
        let tableLength = sectionPayloads.count * RoadPackFormat.sectionEntrySize
        var offset = tableOffset + tableLength
        offset = (offset + 7) & ~7
        var table = LittleEndianBytes()
        var placed: [Int] = []
        for s in sectionPayloads {
            placed.append(offset)
            table.append(s.tag); table.append(UInt32(0)); table.append(UInt64(offset)); table.append(UInt64(s.bytes.count))
            offset = (offset + s.bytes.count + 7) & ~7
        }
        let fileSize = offset
        if let limit = sizeLimit, fileSize > limit { throw RoadPackError.tooLarge(size: fileSize, limit: limit) }

        var out = LittleEndianBytes()
        out.bytes.reserveCapacity(fileSize)
        out.append(contentsOf: RoadPackFormat.magic)
        out.append(RoadPackFormat.currentVersion)
        out.append(UInt16(RoadPackFormat.headerSize))
        out.append(coverage == nil ? UInt32(0) : RoadPackFormat.flagCoverage)
        out.append(UInt64(0))  // contentHash, set below
        out.append(UInt64(fileSize))
        out.append(UInt64(tableOffset))
        out.append(UInt32(sectionPayloads.count))
        out.append(UInt32(0))
        out.append(osmTimestamp)
        out.append(contentsOf: grid.headerBytes)
        precondition(out.bytes.count == RoadPackFormat.headerSize)
        out.append(contentsOf: table.bytes)
        for (i, s) in sectionPayloads.enumerated() {
            out.padToMultiple(of: 8)
            precondition(out.bytes.count == placed[i])
            out.append(contentsOf: s.bytes)
        }
        out.padToMultiple(of: 8)
        precondition(out.bytes.count == fileSize)
        let hash = out.bytes.withUnsafeBytes { RoadPackFormat.contentHash(of: $0) }
        out.set(hash, at: RoadPackFormat.contentHashRange.lowerBound)

        let statistics = Statistics(
            nodes: nodes.count, edges: records.count, points: pointTotal, segments: pointTotal - records.count,
            cells: cellKeys.count, cellEntries: cellSegments.count, effectiveRadiusM: radius, fileSize: fileSize
        )
        return (Data(out.bytes), statistics)
    }

    static func uint32Bytes(_ values: [UInt32]) -> [UInt8] {
        var b = LittleEndianBytes()
        b.bytes.reserveCapacity(values.count * 4)
        for v in values { b.append(v) }
        return b.bytes
    }
}
