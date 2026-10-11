import Foundation

/// Constants and record types of the road pack format (docs/ROAD_PACK.md).
///
/// A road pack is a binary, memory-mappable graph of OpenStreetMap roads
/// with a uniform grid index, versioned independently of the log and the
/// sidecar. Integers are little-endian, coordinates are E7 fixed-point
/// degrees (Int32), sections are 8-byte aligned. Data: © OpenStreetMap
/// contributors, ODbL 1.0.
public enum RoadPackFormat {
    /// `DLRPACK\0`.
    public static let magic: [UInt8] = [0x44, 0x4C, 0x52, 0x50, 0x41, 0x43, 0x4B, 0x00]
    /// The newest version this build reads and the one it writes.
    public static let currentVersion: UInt16 = 1
    public static let headerSize = 96
    public static let sectionEntrySize = 24
    public static let edgeRecordSize = 40
    /// Bytes 16–23 (`contentHash`) are read as zero when hashing.
    public static let contentHashRange = 16..<24
    /// Header bytes 56–95: the grid parameters, hashed into the grid ID.
    public static let gridRange = 56..<96
    /// Header flag bit 0: the `COVR` section is present.
    public static let flagCoverage: UInt32 = 1

    /// The largest pack the app imports and `build_roads` writes, in bytes
    /// (150 MB, decided Q1 in docs/N3_PLAN.md).
    public static let maximumFileSize = 150_000_000

    public static let attribution = "© OpenStreetMap contributors"
    public static let license = "ODbL 1.0"

    /// Four-byte ASCII section tags.
    public enum Tag {
        public static let meta = tag("META")
        public static let nodes = tag("NODE")
        public static let edges = tag("EDGE")
        public static let points = tag("PNTS")
        public static let pointEdges = tag("PTED")
        public static let adjacencyOffsets = tag("ADJO")
        public static let adjacencyEdges = tag("ADJE")
        public static let cellKeys = tag("CELK")
        public static let cellOffsets = tag("CELO")
        public static let cellSegments = tag("CELS")
        public static let coverage = tag("COVR")

        /// Every section a v1 reader requires.
        public static let required: [UInt32] = [
            meta, nodes, edges, points, pointEdges, adjacencyOffsets, adjacencyEdges,
            cellKeys, cellOffsets, cellSegments,
        ]

        /// The tag of four ASCII characters, first character in the low byte
        /// (so it is stored in file order by a little-endian write).
        public static func tag(_ text: String) -> UInt32 {
            let p = Array(text.utf8)
            precondition(p.count == 4, "a section tag is four ASCII bytes")
            return UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
        }

        /// The four characters of `tag`, for messages.
        public static func name(_ tag: UInt32) -> String {
            let bytes = (0..<4).map { UInt8(truncatingIfNeeded: tag >> (8 * $0)) }
            if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
                return String(decoding: bytes, as: UTF8.self)
            }
            return "0x" + String(tag, radix: 16)
        }
    }

    /// FNV-1a 64 over `bytes` with `contentHashRange` read as zero: the pack's
    /// `contentHash`. Same algorithm as `NavigationSeed.fnv1a64`.
    public static func contentHash(of bytes: UnsafeRawBufferPointer) -> UInt64 {
        var hash = NavigationSeed.fnvOffsetBasis
        let prime = NavigationSeed.fnvPrime
        let count = bytes.count
        let zeroStart = min(contentHashRange.lowerBound, count)
        let zeroEnd = min(contentHashRange.upperBound, count)
        var index = 0
        while index < zeroStart {
            hash ^= UInt64(bytes[index])
            hash &*= prime
            index += 1
        }
        while index < zeroEnd {
            hash &*= prime  // hash ^= 0
            index += 1
        }
        while index < count {
            hash ^= UInt64(bytes[index])
            hash &*= prime
            index += 1
        }
        return hash
    }

    /// `contentHash` of a whole file.
    public static func contentHash(of data: Data) -> UInt64 {
        data.withUnsafeBytes { contentHash(of: $0) }
    }

    /// FNV-1a 64 over the packs' content hashes, each as 8 little-endian
    /// bytes, in load order: the identity of a set of packs in a replay.
    public static func roadSetHash(_ contentHashes: [UInt64]) -> UInt64 {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(contentHashes.count * 8)
        for hash in contentHashes {
            for shift in stride(from: 0, to: 64, by: 8) {
                bytes.append(UInt8(truncatingIfNeeded: hash >> UInt64(shift)))
            }
        }
        return NavigationSeed.fnv1a64(bytes)
    }
}

/// Why a road pack was refused.
public enum RoadPackError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Shorter than its header or its declared `fileSize`.
    case truncated(String)
    case badMagic
    /// `formatVersion` is newer than this reader (or 0).
    case unsupportedVersion(UInt16)
    case badHeader(String)
    case sectionOutOfRange(String)
    case sectionsOverlap(String, String)
    case missingSection(String)
    case duplicateSection(String)
    case recordCountMismatch(String)
    case hashMismatch(stored: UInt64, computed: UInt64)
    /// An index or value out of range found by `verify()`.
    case invalid(String, String)
    /// A section that must be sorted is not.
    case unsorted(String)
    /// Packs with different grid IDs cannot be used together.
    case gridMismatch(UInt64, UInt64)
    case duplicatePack(UInt64)
    case noPacks
    /// Writer input that cannot be written as a valid pack.
    case invalidContent(String)
    case tooLarge(size: Int, limit: Int)

    public var description: String {
        switch self {
        case .truncated(let what): "truncated: \(what)"
        case .badMagic: "not a road pack (bad magic)"
        case .unsupportedVersion(let version): "unsupported format version \(version) (this build reads up to \(RoadPackFormat.currentVersion))"
        case .badHeader(let what): "bad header: \(what)"
        case .sectionOutOfRange(let tag): "section \(tag) lies outside the file or overlaps the header"
        case .sectionsOverlap(let a, let b): "sections \(a) and \(b) overlap or are out of order"
        case .missingSection(let tag): "missing section \(tag)"
        case .duplicateSection(let tag): "duplicate section \(tag)"
        case .recordCountMismatch(let tag): "section \(tag): length does not match its record count"
        case .hashMismatch(let stored, let computed):
            "content hash mismatch: stored \(NavigationSeed.hex(stored)), computed \(NavigationSeed.hex(computed))"
        case .invalid(let tag, let what): "section \(tag): \(what)"
        case .unsorted(let tag): "section \(tag) is not sorted"
        case .gridMismatch(let a, let b): "packs use different grids (\(NavigationSeed.hex(a)) vs \(NavigationSeed.hex(b)))"
        case .duplicatePack(let hash): "pack \(NavigationSeed.hex(hash)) loaded twice"
        case .noPacks: "no packs"
        case .invalidContent(let what): "invalid pack content: \(what)"
        case .tooLarge(let size, let limit): "pack is \(size) bytes, over the \(limit)-byte limit"
        }
    }
}

/// A position in E7 fixed-point degrees, as OSM stores it.
public struct RoadPoint: Hashable, Sendable, Codable {
    public var latE7: Int32
    public var lonE7: Int32

    public init(latE7: Int32, lonE7: Int32) {
        self.latE7 = latE7
        self.lonE7 = lonE7
    }

    public var latitude: Double { Double(latE7) / 1e7 }
    public var longitude: Double { Double(lonE7) / 1e7 }
}

/// OSM `highway` class of an edge. The raw values are on disk (EDGE
/// `highwayClass`): never renumber a case.
public enum RoadClass: UInt8, CaseIterable, Sendable, Codable {
    case motorway = 1
    case trunk = 2
    case primary = 3
    case secondary = 4
    case tertiary = 5
    case unclassified = 6
    case residential = 7
    case livingStreet = 8
    case service = 9
    case road = 10

    /// The OSM tag value (without `_link`).
    public var osmValue: String {
        switch self {
        case .motorway: "motorway"
        case .trunk: "trunk"
        case .primary: "primary"
        case .secondary: "secondary"
        case .tertiary: "tertiary"
        case .unclassified: "unclassified"
        case .residential: "residential"
        case .livingStreet: "living_street"
        case .service: "service"
        case .road: "road"
        }
    }

    /// The class and link flag of a `highway` value, or nil when it is not
    /// a drivable class this format knows. Only the five main classes have
    /// links.
    public static func parse(highway value: String) -> (roadClass: RoadClass, isLink: Bool)? {
        let isLink = value.hasSuffix("_link")
        let base = isLink ? String(value.dropLast(5)) : value
        guard let roadClass = allCases.first(where: { $0.osmValue == base }) else { return nil }
        if isLink, roadClass.rawValue > RoadClass.tertiary.rawValue { return nil }
        return (roadClass, isLink)
    }
}

/// EDGE `flags`. Bit positions are on disk.
public struct RoadEdgeFlags: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Drivable only from `from` to `to` (the stored point order).
    public static let oneway = RoadEdgeFlags(rawValue: 1 << 0)
    public static let bridge = RoadEdgeFlags(rawValue: 1 << 1)
    public static let tunnel = RoadEdgeFlags(rawValue: 1 << 2)
    public static let roundabout = RoadEdgeFlags(rawValue: 1 << 3)
    public static let link = RoadEdgeFlags(rawValue: 1 << 4)
    /// `oneway` came from the class or junction, not an explicit tag.
    public static let onewayImplied = RoadEdgeFlags(rawValue: 1 << 5)

    static let known: UInt8 = 0b0011_1111
}

/// One EDGE record (40 bytes on disk).
public struct RoadEdgeRecord: Hashable, Sendable, Codable {
    /// NODE index of the first point.
    public var from: UInt32
    /// NODE index of the last point.
    public var to: UInt32
    /// PNTS index of the first point; the edge's points are contiguous.
    public var firstPoint: UInt32
    /// Number of points, both end nodes included (≥ 2).
    public var pointCount: UInt32
    public var osmWayID: Int64
    /// Index of the first point in the way's normalised node list (driving
    /// order for a oneway, consecutive duplicates removed). Segment k of the
    /// edge has the key (osmWayID, wayPointOffset + k) in every pack.
    public var wayPointOffset: UInt32
    /// Length in decimetres.
    public var lengthDm: UInt32
    public var highwayClass: RoadClass
    /// Level for the layer rule, −5…5 (`RoadGeometry.level`).
    public var level: Int8
    public var flags: RoadEdgeFlags
    /// 0 = unknown.
    public var lanes: UInt8

    public init(
        from: UInt32, to: UInt32, firstPoint: UInt32, pointCount: UInt32, osmWayID: Int64,
        wayPointOffset: UInt32, lengthDm: UInt32, highwayClass: RoadClass, level: Int8,
        flags: RoadEdgeFlags, lanes: UInt8
    ) {
        self.from = from
        self.to = to
        self.firstPoint = firstPoint
        self.pointCount = pointCount
        self.osmWayID = osmWayID
        self.wayPointOffset = wayPointOffset
        self.lengthDm = lengthDm
        self.highwayClass = highwayClass
        self.level = level
        self.flags = flags
        self.lanes = lanes
    }

    public var isOneway: Bool { flags.contains(.oneway) }
}

/// The identity of a segment across packs: (way, index of its start point
/// in the way's normalised node list). Ordered by way, then index.
public struct RoadSegmentKey: Hashable, Comparable, Sendable, Codable {
    public var osmWayID: Int64
    public var index: UInt32

    public init(osmWayID: Int64, index: UInt32) {
        self.osmWayID = osmWayID
        self.index = index
    }

    public static func < (a: RoadSegmentKey, b: RoadSegmentKey) -> Bool {
        (a.osmWayID, a.index) < (b.osmWayID, b.index)
    }
}

// MARK: Little-endian byte buffer

/// Append-only little-endian writer for the pack writer.
struct LittleEndianBytes {
    var bytes: [UInt8] = []

    mutating func append(_ value: UInt8) { bytes.append(value) }
    mutating func append(_ value: Int8) { bytes.append(UInt8(bitPattern: value)) }
    mutating func append(_ value: UInt16) { appendInteger(value) }
    mutating func append(_ value: UInt32) { appendInteger(value) }
    mutating func append(_ value: Int32) { appendInteger(UInt32(bitPattern: value)) }
    mutating func append(_ value: UInt64) { appendInteger(value) }
    mutating func append(_ value: Int64) { appendInteger(UInt64(bitPattern: value)) }
    mutating func append(_ value: Double) { appendInteger(value.bitPattern) }
    mutating func append(contentsOf other: [UInt8]) { bytes.append(contentsOf: other) }

    private mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) }
    }

    mutating func padToMultiple(of alignment: Int) {
        while bytes.count % alignment != 0 { bytes.append(0) }
    }

    /// Overwrite 8 bytes at `offset` with `value`, little-endian.
    mutating func set(_ value: UInt64, at offset: Int) {
        for i in 0..<8 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> UInt64(8 * i)) }
    }

    mutating func set(_ value: UInt32, at offset: Int) {
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> UInt32(8 * i)) }
    }
}

extension UnsafeRawBufferPointer {
    @inline(__always)
    func le<T: FixedWidthInteger>(_ offset: Int, as type: T.Type = T.self) -> T {
        T(littleEndian: loadUnaligned(fromByteOffset: offset, as: T.self))
    }

    @inline(__always)
    func leDouble(_ offset: Int) -> Double {
        Double(bitPattern: le(offset, as: UInt64.self))
    }
}
