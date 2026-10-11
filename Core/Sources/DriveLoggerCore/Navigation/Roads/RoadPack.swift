import Foundation

/// A road pack, memory-mapped and read in place (docs/ROAD_PACK.md).
///
/// Opening runs the structure checks (magic, version, sizes, section
/// bounds and order, record counts against lengths): O(1) in the file size.
/// `verify()` adds the content hash and every index-range and ordering
/// check, O(file size); replay runs it at open, the app once at import.
/// Accessors check their index and trap on a bad one rather than read out
/// of bounds, so an unverified pack can stop a run but never read past the
/// mapping.
///
/// Data: © OpenStreetMap contributors, ODbL 1.0.
public final class RoadPack: @unchecked Sendable {
    // @unchecked: every stored property is immutable after init, and the
    // mapped bytes are owned by `storage` and never written. Reading them
    // from several threads is safe.

    private let storage: NSData
    private let bytes: UnsafeRawBufferPointer

    public let formatVersion: UInt16
    public let flags: UInt32
    public let contentHash: UInt64
    public let fileSize: Int
    /// Unix seconds UTC of the source extract; 0 = unknown.
    public let osmTimestamp: Int64
    public let grid: RoadGrid
    public let gridID: UInt64
    /// Every section in file order, unknown tags included.
    public let sections: [Section]

    public let nodeCount: Int
    public let edgeCount: Int
    public let pointCount: Int
    public let cellCount: Int
    public let cellEntryCount: Int
    public let adjacencyEntryCount: Int

    private let metaRange: Range<Int>
    private let nodeBase: Int
    private let edgeBase: Int
    private let pointBase: Int
    private let pointEdgeBase: Int
    private let adjacencyOffsetBase: Int
    private let adjacencyEdgeBase: Int
    private let cellKeyBase: Int
    private let cellOffsetBase: Int
    private let cellSegmentBase: Int
    private let coverageRange: Range<Int>?

    public struct Section: Hashable, Sendable {
        public var tag: UInt32
        public var flags: UInt32
        public var offset: Int
        public var length: Int
        public var name: String { RoadPackFormat.Tag.name(tag) }
        public var range: Range<Int> { offset..<(offset + length) }
    }

    /// Memory-map and open the pack at `url`. With `verify`, also runs
    /// `verify()`.
    public convenience init(contentsOf url: URL, verify: Bool = true) throws {
        let data = try NSData(contentsOf: url, options: .alwaysMapped)
        try self.init(storage: data)
        if verify { try self.verify() }
    }

    /// Open a pack held in memory (tests, the writer's self-check).
    public convenience init(data: Data, verify: Bool = true) throws {
        try self.init(storage: NSData(data: data))
        if verify { try self.verify() }
    }

    private init(storage: NSData) throws {
        self.storage = storage
        let buffer = UnsafeRawBufferPointer(start: storage.bytes, count: storage.length)
        bytes = buffer
        let count = buffer.count
        let header = RoadPackFormat.headerSize
        guard count >= header else { throw RoadPackError.truncated("file is \(count) bytes, shorter than the header") }
        guard Array(buffer[0..<8]) == RoadPackFormat.magic else { throw RoadPackError.badMagic }
        formatVersion = buffer.le(8)
        guard formatVersion >= 1, formatVersion <= RoadPackFormat.currentVersion else {
            throw RoadPackError.unsupportedVersion(formatVersion)
        }
        let headerSize = Int(buffer.le(10, as: UInt16.self))
        guard headerSize == header else { throw RoadPackError.badHeader("headerSize \(headerSize), expected \(header)") }
        flags = buffer.le(12)
        contentHash = buffer.le(16)
        let declaredSize = buffer.le(24, as: UInt64.self)
        guard declaredSize <= UInt64(Int.max), Int(declaredSize) <= count else {
            throw RoadPackError.truncated("file is \(count) bytes, header declares \(declaredSize)")
        }
        guard Int(declaredSize) == count else { throw RoadPackError.badHeader("\(count - Int(declaredSize)) bytes after the declared end") }
        fileSize = count
        let tableOffset = buffer.le(32, as: UInt64.self)
        let sectionCount = Int(buffer.le(40, as: UInt32.self))
        guard buffer.le(44, as: UInt32.self) == 0 else { throw RoadPackError.badHeader("reserved field is not 0") }
        osmTimestamp = buffer.le(48)
        grid = RoadGrid(
            originLatE7: buffer.le(56), originLonE7: buffer.le(60),
            metresPerE7Lat: buffer.leDouble(64), metresPerE7Lon: buffer.leDouble(72),
            cellSizeM: buffer.leDouble(80), searchRadiusM: buffer.leDouble(88)
        )
        if let reason = grid.invalidReason { throw RoadPackError.badHeader(reason) }
        gridID = NavigationSeed.fnv1a64(buffer[RoadPackFormat.gridRange])

        // Section table.
        let tableLength = sectionCount * RoadPackFormat.sectionEntrySize
        guard tableOffset >= UInt64(header), tableOffset % 8 == 0,
              tableOffset <= UInt64(count), UInt64(count) - tableOffset >= UInt64(tableLength) else {
            throw RoadPackError.sectionOutOfRange("section table")
        }
        let table = Int(tableOffset)..<(Int(tableOffset) + tableLength)
        var sections: [Section] = []
        sections.reserveCapacity(sectionCount)
        for i in 0..<sectionCount {
            let base = table.lowerBound + i * RoadPackFormat.sectionEntrySize
            let tag: UInt32 = buffer.le(base)
            let offset = buffer.le(base + 8, as: UInt64.self)
            let length = buffer.le(base + 16, as: UInt64.self)
            let name = RoadPackFormat.Tag.name(tag)
            guard offset >= UInt64(header), offset <= UInt64(count), length <= UInt64(count) - offset else {
                throw RoadPackError.sectionOutOfRange(name)
            }
            let section = Section(tag: tag, flags: buffer.le(base + 4), offset: Int(offset), length: Int(length))
            if section.range.overlaps(table) { throw RoadPackError.sectionsOverlap(name, "section table") }
            if let previous = sections.last, section.offset < previous.offset + previous.length {
                throw RoadPackError.sectionsOverlap(previous.name, name)
            }
            sections.append(section)
        }
        self.sections = sections

        var byTag: [UInt32: Section] = [:]
        for section in sections {
            let known = RoadPackFormat.Tag.required.contains(section.tag) || section.tag == RoadPackFormat.Tag.coverage
            guard known else { continue }  // unknown sections are skipped
            if byTag[section.tag] != nil { throw RoadPackError.duplicateSection(section.name) }
            byTag[section.tag] = section
        }
        func required(_ tag: UInt32) throws -> Section {
            guard let section = byTag[tag] else { throw RoadPackError.missingSection(RoadPackFormat.Tag.name(tag)) }
            return section
        }
        func records(_ section: Section, size: Int) throws -> Int {
            guard section.length % size == 0 else { throw RoadPackError.recordCountMismatch(section.name) }
            return section.length / size
        }
        typealias T = RoadPackFormat.Tag
        let meta = try required(T.meta)
        let node = try required(T.nodes)
        let edge = try required(T.edges)
        let pnts = try required(T.points)
        let pted = try required(T.pointEdges)
        let adjo = try required(T.adjacencyOffsets)
        let adje = try required(T.adjacencyEdges)
        let celk = try required(T.cellKeys)
        let celo = try required(T.cellOffsets)
        let cels = try required(T.cellSegments)

        nodeCount = try records(node, size: 8)
        edgeCount = try records(edge, size: RoadPackFormat.edgeRecordSize)
        pointCount = try records(pnts, size: 8)
        guard try records(pted, size: 4) == pointCount else { throw RoadPackError.recordCountMismatch(pted.name) }
        guard try records(adjo, size: 4) == nodeCount + 1 else { throw RoadPackError.recordCountMismatch(adjo.name) }
        adjacencyEntryCount = try records(adje, size: 4)
        cellCount = try records(celk, size: 8)
        guard try records(celo, size: 4) == cellCount + 1 else { throw RoadPackError.recordCountMismatch(celo.name) }
        cellEntryCount = try records(cels, size: 4)

        metaRange = meta.range
        nodeBase = node.offset
        edgeBase = edge.offset
        pointBase = pnts.offset
        pointEdgeBase = pted.offset
        adjacencyOffsetBase = adjo.offset
        adjacencyEdgeBase = adje.offset
        cellKeyBase = celk.offset
        cellOffsetBase = celo.offset
        cellSegmentBase = cels.offset

        let hasCoverageFlag = flags & RoadPackFormat.flagCoverage != 0
        if let covr = byTag[T.coverage] {
            guard hasCoverageFlag else { throw RoadPackError.badHeader("COVR present but flag bit 0 clear") }
            coverageRange = covr.range
        } else {
            guard !hasCoverageFlag else { throw RoadPackError.missingSection("COVR") }
            coverageRange = nil
        }

        // The CSR end markers bound every later range read.
        guard buffer.le(adjacencyOffsetBase, as: UInt32.self) == 0,
              Int(buffer.le(adjacencyOffsetBase + 4 * nodeCount, as: UInt32.self)) == adjacencyEntryCount else {
            throw RoadPackError.recordCountMismatch(adjo.name)
        }
        guard buffer.le(cellOffsetBase, as: UInt32.self) == 0,
              Int(buffer.le(cellOffsetBase + 4 * cellCount, as: UInt32.self)) == cellEntryCount else {
            throw RoadPackError.recordCountMismatch(celo.name)
        }
    }

    // MARK: Records

    /// The topological node `index`.
    @inline(__always)
    public func node(_ index: Int) -> RoadPoint {
        precondition(index >= 0 && index < nodeCount, "node index out of range")
        let base = nodeBase + 8 * index
        return RoadPoint(latE7: bytes.le(base), lonE7: bytes.le(base + 4))
    }

    /// Shape point `index`.
    @inline(__always)
    public func point(_ index: Int) -> RoadPoint {
        precondition(index >= 0 && index < pointCount, "point index out of range")
        let base = pointBase + 8 * index
        return RoadPoint(latE7: bytes.le(base), lonE7: bytes.le(base + 4))
    }

    /// The edge that shape point `index` belongs to.
    @inline(__always)
    public func edgeOfPoint(_ index: Int) -> Int {
        precondition(index >= 0 && index < pointCount, "point index out of range")
        return Int(bytes.le(pointEdgeBase + 4 * index, as: UInt32.self))
    }

    /// Edge `index`. An unknown `highwayClass` (only possible in an
    /// unverified pack) reads as `.road`.
    public func edge(_ index: Int) -> RoadEdgeRecord {
        precondition(index >= 0 && index < edgeCount, "edge index out of range")
        let base = edgeBase + RoadPackFormat.edgeRecordSize * index
        return RoadEdgeRecord(
            from: bytes.le(base), to: bytes.le(base + 4),
            firstPoint: bytes.le(base + 8), pointCount: bytes.le(base + 12),
            osmWayID: bytes.le(base + 16), wayPointOffset: bytes.le(base + 24),
            lengthDm: bytes.le(base + 28),
            highwayClass: RoadClass(rawValue: bytes[base + 32]) ?? .road,
            level: Int8(bitPattern: bytes[base + 33]),
            flags: RoadEdgeFlags(rawValue: bytes[base + 34]),
            lanes: bytes[base + 35]
        )
    }

    /// The edges incident to `node`, ascending.
    public func incidentEdges(_ node: Int) -> [Int] {
        precondition(node >= 0 && node < nodeCount, "node index out of range")
        let range = csrRange(offsetBase: adjacencyOffsetBase, index: node, total: adjacencyEntryCount)
        return range.map { Int(bytes.le(adjacencyEdgeBase + 4 * $0, as: UInt32.self)) }
    }

    @inline(__always)
    private func csrRange(offsetBase: Int, index: Int, total: Int) -> Range<Int> {
        let lo = Int(bytes.le(offsetBase + 4 * index, as: UInt32.self))
        let hi = Int(bytes.le(offsetBase + 4 * (index + 1), as: UInt32.self))
        // Clamped so an unverified pack cannot read past CELS/ADJE.
        let a = min(lo, total), b = min(max(hi, a), total)
        return a..<b
    }

    // MARK: Segments

    /// Number of segments: one per pair of consecutive points in an edge.
    public var segmentCount: Int { pointCount - edgeCount }

    /// A segment, by its start point.
    public struct Segment: Hashable, Sendable {
        public var startPoint: Int
        public var edgeIndex: Int
        public var a: RoadPoint
        public var b: RoadPoint
        public var key: RoadSegmentKey
    }

    /// The segment starting at shape point `start` (which must not be the
    /// last point of its edge).
    public func segment(startingAt start: Int) -> Segment {
        let e = edgeOfPoint(start)
        let record = edge(e)
        let k = start - Int(record.firstPoint)
        precondition(k >= 0 && k + 1 < Int(record.pointCount), "not a segment start point")
        return Segment(
            startPoint: start, edgeIndex: e, a: point(start), b: point(start + 1),
            key: RoadSegmentKey(osmWayID: record.osmWayID, index: record.wayPointOffset + UInt32(k))
        )
    }

    /// The edge holding the segment with `key`, and its start point, by
    /// binary search over EDGE (sorted by way, then offset); nil if absent.
    public func segment(withKey key: RoadSegmentKey) -> Segment? {
        var lo = 0, hi = edgeCount
        while lo < hi {
            let mid = (lo + hi) / 2
            let base = edgeBase + RoadPackFormat.edgeRecordSize * mid
            let way: Int64 = bytes.le(base + 16)
            let offset: UInt32 = bytes.le(base + 24)
            if way < key.osmWayID || (way == key.osmWayID && offset <= key.index) { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        let record = edge(lo - 1)
        guard record.osmWayID == key.osmWayID, key.index >= record.wayPointOffset else { return nil }
        let k = Int(key.index - record.wayPointOffset)
        guard k + 1 < Int(record.pointCount) else { return nil }
        return segment(startingAt: Int(record.firstPoint) + k)
    }

    // MARK: Cells

    /// The CELK index of a cell, or nil when the cell is empty.
    @inline(__always)
    public func cellIndex(cx: Int32, cy: Int32) -> Int? {
        let key = RoadGrid.key(cx: cx, cy: cy)
        var lo = 0, hi = cellCount
        while lo < hi {
            let mid = (lo + hi) &>> 1
            let k: UInt64 = bytes.le(cellKeyBase + 8 * mid)
            if k < key { lo = mid + 1 } else { hi = mid }
        }
        guard lo < cellCount, bytes.le(cellKeyBase + 8 * lo, as: UInt64.self) == key else { return nil }
        return lo
    }

    /// The key of cell `index` (ascending in `index`).
    public func cellKey(_ index: Int) -> UInt64 {
        precondition(index >= 0 && index < cellCount, "cell index out of range")
        return bytes.le(cellKeyBase + 8 * index)
    }

    /// The CELS entries of cell `index`.
    @inline(__always)
    public func cellEntryRange(_ index: Int) -> Range<Int> {
        precondition(index >= 0 && index < cellCount, "cell index out of range")
        return csrRange(offsetBase: cellOffsetBase, index: index, total: cellEntryCount)
    }

    /// CELS entry `index`: a segment start point.
    @inline(__always)
    public func cellEntry(_ index: Int) -> Int {
        Int(bytes.le(cellSegmentBase + 4 * index, as: UInt32.self))
    }

    /// Calls `body` with the start point of every segment listed in the
    /// cell, ascending. These are all segments within `grid.searchRadiusM`
    /// of any point in the cell (and possibly some farther ones).
    @inline(__always)
    public func forEachSegment(inCellX cx: Int32, y cy: Int32, _ body: (Int) -> Void) {
        guard let index = cellIndex(cx: cx, cy: cy) else { return }
        for entry in cellEntryRange(index) { body(cellEntry(entry)) }
    }

    /// The segment start points listed in a cell, ascending.
    public func segments(inCellX cx: Int32, y cy: Int32) -> [Int] {
        var out: [Int] = []
        forEachSegment(inCellX: cx, y: cy) { out.append($0) }
        return out
    }

    // MARK: Adjacency

    /// Whether edge `b` is within `hops` of edge `a`: 0 hops is the edge
    /// itself, 1 hop an edge sharing a node with it, and so on.
    public func isEdge(_ b: Int, withinHops hops: Int, of a: Int) -> Bool {
        if a == b { return true }
        guard hops > 0 else { return false }
        var frontier = [a]
        var seen = [a]
        for _ in 0..<hops {
            var next: [Int] = []
            for e in frontier {
                let record = edge(e)
                for node in [Int(record.from), Int(record.to)] {
                    for f in incidentEdges(node) where !seen.contains(f) {
                        if f == b { return true }
                        seen.append(f)
                        next.append(f)
                    }
                }
            }
            if next.isEmpty { return false }
            frontier = next
        }
        return false
    }

    // MARK: Metadata and coverage

    /// The raw `META` bytes (UTF-8 JSON, sorted keys).
    public var metaData: Data { Data(bytes[metaRange]) }

    /// `META` decoded, or nil when it is not a JSON object.
    public var meta: [String: JSONValue]? {
        guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: metaData) else { return nil }
        return object
    }

    public var hasCoverage: Bool { coverageRange != nil }

    /// The coverage polygon rings (even-odd rule), or nil without `COVR`.
    public func coverageRings() throws -> [[RoadPoint]]? {
        guard let range = coverageRange else { return nil }
        return try Self.parseCoverage(bytes, range: range)
    }

    static func parseCoverage(_ bytes: UnsafeRawBufferPointer, range: Range<Int>) throws -> [[RoadPoint]] {
        let tag = "COVR"
        var cursor = range.lowerBound
        func need(_ n: Int) throws {
            guard n >= 0, range.upperBound - cursor >= n else { throw RoadPackError.invalid(tag, "truncated") }
        }
        try need(4)
        let ringCount = Int(bytes.le(cursor, as: UInt32.self))
        cursor += 4
        var rings: [[RoadPoint]] = []
        for _ in 0..<ringCount {
            try need(4)
            let n = Int(bytes.le(cursor, as: UInt32.self))
            cursor += 4
            guard n >= 3 else { throw RoadPackError.invalid(tag, "ring with \(n) points") }
            try need(8 * n)
            var ring: [RoadPoint] = []
            ring.reserveCapacity(n)
            for i in 0..<n {
                ring.append(RoadPoint(latE7: bytes.le(cursor + 8 * i), lonE7: bytes.le(cursor + 8 * i + 4)))
            }
            cursor += 8 * n
            rings.append(ring)
        }
        guard rings.count > 0 else { throw RoadPackError.invalid(tag, "no rings") }
        // Only zero padding to the next multiple of 8 may follow.
        guard range.upperBound - cursor < 8, bytes[cursor..<range.upperBound].allSatisfy({ $0 == 0 }) else {
            throw RoadPackError.invalid(tag, "trailing bytes")
        }
        return rings
    }

    /// The bounding box of every shape point, (south-west, north-east);
    /// nil for an empty pack. O(points).
    public func pointBounds() -> (southWest: RoadPoint, northEast: RoadPoint)? {
        guard pointCount > 0 else { return nil }
        var minLat = Int32.max, minLon = Int32.max, maxLat = Int32.min, maxLon = Int32.min
        for i in 0..<pointCount {
            let p = point(i)
            minLat = min(minLat, p.latE7); maxLat = max(maxLat, p.latE7)
            minLon = min(minLon, p.lonE7); maxLon = max(maxLon, p.lonE7)
        }
        return (RoadPoint(latE7: minLat, lonE7: minLon), RoadPoint(latE7: maxLat, lonE7: maxLon))
    }

    // MARK: Info

    public var info: RoadPackInfo {
        RoadPackInfo(pack: self)
    }

    // MARK: Verification

    /// The content hash recomputed from the bytes.
    public func computeContentHash() -> UInt64 {
        RoadPackFormat.contentHash(of: bytes)
    }

    /// The full check: content hash, then every index range and ordering
    /// rule of docs/ROAD_PACK.md. O(file size). Throws the first problem.
    public func verify() throws {
        let computed = computeContentHash()
        guard computed == contentHash else { throw RoadPackError.hashMismatch(stored: contentHash, computed: computed) }
        let edgeTag = "EDGE", pointTag = "PTED", adjTag = "ADJE", cellTag = "CELS"

        // META is a JSON object.
        guard meta != nil else { throw RoadPackError.invalid("META", "not a JSON object") }

        // EDGE: points partition PNTS in edge order; ends are the nodes;
        // sorted strictly by (way, offset).
        var expectedFirst = 0
        var previousKey: (Int64, UInt32)?
        for e in 0..<edgeCount {
            let base = edgeBase + RoadPackFormat.edgeRecordSize * e
            guard RoadClass(rawValue: bytes[base + 32]) != nil else { throw RoadPackError.invalid(edgeTag, "edge \(e): unknown highway class") }
            guard bytes.le(base + 36, as: UInt32.self) == 0 else { throw RoadPackError.invalid(edgeTag, "edge \(e): reserved field is not 0") }
            let r = edge(e)
            guard r.flags.rawValue & ~RoadEdgeFlags.known == 0 else { throw RoadPackError.invalid(edgeTag, "edge \(e): unknown flags") }
            guard RoadGeometry.levelRange.contains(r.level) else { throw RoadPackError.invalid(edgeTag, "edge \(e): level out of range") }
            guard Int(r.from) < nodeCount, Int(r.to) < nodeCount else { throw RoadPackError.invalid(edgeTag, "edge \(e): node out of range") }
            guard r.pointCount >= 2, Int(r.firstPoint) == expectedFirst,
                  Int(r.firstPoint) + Int(r.pointCount) <= pointCount else {
                throw RoadPackError.invalid(edgeTag, "edge \(e): points out of range or not contiguous")
            }
            expectedFirst += Int(r.pointCount)
            guard point(Int(r.firstPoint)) == node(Int(r.from)),
                  point(Int(r.firstPoint) + Int(r.pointCount) - 1) == node(Int(r.to)) else {
                throw RoadPackError.invalid(edgeTag, "edge \(e): end points are not its nodes")
            }
            guard r.wayPointOffset <= UInt32.max - r.pointCount else { throw RoadPackError.invalid(edgeTag, "edge \(e): offset overflow") }
            if let p = previousKey, !(p < (r.osmWayID, r.wayPointOffset)) { throw RoadPackError.unsorted(edgeTag) }
            previousKey = (r.osmWayID, r.wayPointOffset)
            for i in Int(r.firstPoint)..<(Int(r.firstPoint) + Int(r.pointCount)) where edgeOfPoint(i) != e {
                throw RoadPackError.invalid(pointTag, "point \(i) is not marked with its edge \(e)")
            }
        }
        guard expectedFirst == pointCount else { throw RoadPackError.invalid(edgeTag, "edges do not cover every point") }

        // ADJO/ADJE: monotone; each node's edges ascending, in range, and
        // incident to the node; every edge listed at both ends.
        var incidence = 0
        for n in 0..<nodeCount {
            let lo = Int(bytes.le(adjacencyOffsetBase + 4 * n, as: UInt32.self))
            let hi = Int(bytes.le(adjacencyOffsetBase + 4 * (n + 1), as: UInt32.self))
            guard lo <= hi, hi <= adjacencyEntryCount else { throw RoadPackError.invalid("ADJO", "offsets not monotone") }
            var previous = -1
            for i in lo..<hi {
                let e = Int(bytes.le(adjacencyEdgeBase + 4 * i, as: UInt32.self))
                guard e < edgeCount else { throw RoadPackError.invalid(adjTag, "edge out of range") }
                guard e > previous else { throw RoadPackError.unsorted(adjTag) }
                previous = e
                let r = edge(e)
                guard Int(r.from) == n || Int(r.to) == n else { throw RoadPackError.invalid(adjTag, "edge \(e) is not incident to node \(n)") }
            }
        }
        for e in 0..<edgeCount {
            let r = edge(e)
            incidence += r.from == r.to ? 1 : 2
        }
        guard incidence == adjacencyEntryCount else { throw RoadPackError.invalid(adjTag, "does not list every edge at both ends") }

        // CELK strictly ascending; CELO monotone; CELS ascending segment
        // starts inside their edge.
        var previousCell: UInt64?
        for c in 0..<cellCount {
            let key = cellKey(c)
            if let p = previousCell, key <= p { throw RoadPackError.unsorted("CELK") }
            previousCell = key
            let lo = Int(bytes.le(cellOffsetBase + 4 * c, as: UInt32.self))
            let hi = Int(bytes.le(cellOffsetBase + 4 * (c + 1), as: UInt32.self))
            guard lo < hi, hi <= cellEntryCount else { throw RoadPackError.invalid("CELO", "offsets not increasing (empty cell or out of range)") }
            var previous = -1
            for i in lo..<hi {
                let s = cellEntry(i)
                guard s > previous else { throw RoadPackError.unsorted(cellTag) }
                previous = s
                guard s + 1 < pointCount, edgeOfPoint(s) == edgeOfPoint(s + 1) else {
                    throw RoadPackError.invalid(cellTag, "entry \(i) is not a segment start")
                }
            }
        }

        if let range = coverageRange { _ = try Self.parseCoverage(bytes, range: range) }
    }
}

/// What `build_roads --info`, the replay summary and (later) the app's
/// pack list show about a pack. Codable for `metrics.json`.
public struct RoadPackInfo: Hashable, Sendable, Codable {
    public var formatVersion: Int
    /// 16 lowercase hex digits.
    public var contentHash: String
    public var gridID: String
    public var fileSize: Int
    public var osmTimestamp: Int64
    public var nodeCount: Int
    public var edgeCount: Int
    public var pointCount: Int
    public var segmentCount: Int
    public var cellCount: Int
    public var cellEntryCount: Int
    public var cellSizeM: Double
    public var searchRadiusM: Double
    public var hasCoverage: Bool
    public var attribution: String
    public var license: String
    public var meta: JSONValue?

    public init(pack: RoadPack) {
        formatVersion = Int(pack.formatVersion)
        contentHash = NavigationSeed.hex(pack.contentHash)
        gridID = NavigationSeed.hex(pack.gridID)
        fileSize = pack.fileSize
        osmTimestamp = pack.osmTimestamp
        nodeCount = pack.nodeCount
        edgeCount = pack.edgeCount
        pointCount = pack.pointCount
        segmentCount = pack.segmentCount
        cellCount = pack.cellCount
        cellEntryCount = pack.cellEntryCount
        cellSizeM = pack.grid.cellSizeM
        searchRadiusM = pack.grid.searchRadiusM
        hasCoverage = pack.hasCoverage
        let meta = pack.meta
        if case .string(let text)? = meta?["attribution"] { attribution = text } else { attribution = RoadPackFormat.attribution }
        if case .string(let text)? = meta?["license"] { license = text } else { license = RoadPackFormat.license }
        self.meta = meta.map { .object($0) }
    }
}
