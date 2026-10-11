import DriveLoggerCore
import Foundation

/// OPL in, pack bytes out: the whole Mac-side build (docs/ROAD_PACK.md,
/// "Builder"). Mac only; the app does not link this module.
///
/// Deterministic: the same OPL (lines in any order), parameters and builder
/// version give the same bytes. `META` holds no build date or host, only
/// what the parameters and the source say.
public enum RoadPackBuild {
    /// Bumped when the builder's output for the same input changes.
    public static let builderVersion = "1"
    public static let builderName = "build_roads"

    public struct Parameters: Hashable, Sendable {
        /// `highway` values kept.
        public var classes: [String]
        public var grid: RoadGrid
        public var osmTimestamp: Int64 = 0
        /// Recorded in META; never needed to read the pack.
        public var sourceName: String?
        public var sourceSHA256: String?
        public var osmiumVersion: String?
        public var extractStrategy: String?
        /// The builder's git commit, if known.
        public var builderCommit: String?
        /// Coverage description for META: admin level and relation ID. Kept
        /// in the (git-ignored) pack only.
        public var coverageAdminLevel: Int?
        public var coverageRelationID: Int64?
        public var coverage: [[RoadPoint]]?
        public var sizeLimit: Int = RoadPackFormat.maximumFileSize
        /// Extra META entries (tool-specific).
        public var extraMeta: [String: JSONValue] = [:]

        public init(classes: [String], grid: RoadGrid) {
            self.classes = classes
            self.grid = grid
        }
    }

    public struct Result: Sendable {
        public var data: Data
        public var builder: RoadGraphBuilder.Statistics
        public var index: RoadPackWriter.Statistics
    }

    public static func build(opl: Data, parameters: Parameters) throws -> Result {
        try build(ways: try OPLReader.ways(in: opl), parameters: parameters)
    }

    public static func build(ways: [OPLWay], parameters p: Parameters) throws -> Result {
        let builder = RoadGraphBuilder(classes: Set(p.classes))
        let (graph, buildStatistics) = try builder.build(ways: ways)
        let writer = RoadPackWriter(
            grid: p.grid, osmTimestamp: p.osmTimestamp, meta: meta(p),
            coverage: p.coverage, sizeLimit: min(p.sizeLimit, RoadPackFormat.maximumFileSize)
        )
        let (data, indexStatistics) = try writer.writeWithStatistics(graph)
        return Result(data: data, builder: buildStatistics, index: indexStatistics)
    }

    static func meta(_ p: Parameters) -> [String: JSONValue] {
        var builder: [String: JSONValue] = [
            "name": .string(builderName),
            "version": .string(builderVersion),
        ]
        if let commit = p.builderCommit { builder["commit"] = .string(commit) }
        var parameters: [String: JSONValue] = [
            "highwayClasses": .array(p.classes.sorted().map { .string($0) }),
            "cellSizeM": .double(p.grid.cellSizeM),
            "searchRadiusM": .double(p.grid.searchRadiusM),
            "excluded": .array(["area=yes", "service=parking_aisle"].map { .string($0) }),
        ]
        if let strategy = p.extractStrategy { parameters["osmiumExtractStrategy"] = .string(strategy) }
        if let version = p.osmiumVersion { parameters["osmiumVersion"] = .string(version) }
        var source: [String: JSONValue] = [:]
        if let name = p.sourceName { source["fileName"] = .string(name) }
        if let sha = p.sourceSHA256 { source["sha256"] = .string(sha) }
        if p.osmTimestamp != 0 { source["osmTimestamp"] = .string(isoTimestamp(p.osmTimestamp)) }
        var meta: [String: JSONValue] = [
            "builder": .object(builder),
            "parameters": .object(parameters),
            "formatVersion": .int(Int64(RoadPackFormat.currentVersion)),
        ]
        if !source.isEmpty { meta["source"] = .object(source) }
        var coverage: [String: JSONValue] = [:]
        if let level = p.coverageAdminLevel { coverage["adminLevel"] = .int(Int64(level)) }
        if let relation = p.coverageRelationID { coverage["relationID"] = .int(relation) }
        coverage["polygon"] = .bool(p.coverage != nil)
        meta["coverage"] = .object(coverage)
        for (key, value) in p.extraMeta { meta[key] = value }
        return meta
    }

    /// Unix seconds → `yyyy-MM-ddTHH:mm:ssZ`.
    public static func isoTimestamp(_ seconds: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    /// `yyyy-MM-ddTHH:mm:ssZ` or Unix seconds → Unix seconds.
    public static func parseTimestamp(_ text: String) -> Int64? {
        if let seconds = Int64(text) { return seconds }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text).map { Int64($0.timeIntervalSince1970) }
    }
}

/// Lookup statistics of a pack: how many candidates one cell lookup
/// returns and how long a lookup with the distance test takes. Query
/// points are seeded: a random segment, a random point on it, a random
/// offset within the search radius, as particles near a road would be.
public enum RoadPackBench {
    public struct Report: Hashable, Sendable, Codable {
        public var queries: Int
        public var seed: UInt64
        /// Segments listed in the query's cell.
        public var candidatesP50: Int
        public var candidatesP95: Int
        public var candidatesMax: Int
        public var candidatesMean: Double
        /// Of those, within `searchRadiusM` (frame metres) of the query.
        public var withinRadiusMean: Double
        /// Mean wall time per lookup (cell search + distance test on every
        /// candidate), nanoseconds.
        public var nanosecondsPerLookup: Double
        /// CELS entries per non-empty cell.
        public var cellEntriesP50: Int
        public var cellEntriesP95: Int
        public var cellEntriesMax: Int
    }

    public static func run(pack: RoadPack, queries: Int = 100_000, seed: UInt64 = 1) -> Report {
        var rng = NavigationRandom(seed: seed)
        let grid = pack.grid
        let radius = grid.searchRadiusM
        // Segment starts (all points that are not the last of their edge).
        var starts: [Int] = []
        starts.reserveCapacity(pack.segmentCount)
        for e in 0..<pack.edgeCount {
            let r = pack.edge(e)
            for k in 0..<(Int(r.pointCount) - 1) { starts.append(Int(r.firstPoint) + k) }
        }
        var xs: [Double] = [], ys: [Double] = []
        xs.reserveCapacity(queries); ys.reserveCapacity(queries)
        if !starts.isEmpty {
            for _ in 0..<queries {
                let s = starts[Int(rng.next() % UInt64(starts.count))]
                let a = grid.frame(pack.point(s)), b = grid.frame(pack.point(s + 1))
                let t = rng.nextUniform()
                let angle = 2 * Double.pi * rng.nextUniform()
                let r = radius * rng.nextUniform().squareRoot()
                xs.append(a.x + t * (b.x - a.x) + r * cos(angle))
                ys.append(a.y + t * (b.y - a.y) + r * sin(angle))
            }
        }

        var counts: [Int] = []
        counts.reserveCapacity(xs.count)
        var within = 0
        let r2 = radius * radius
        let clock = ContinuousClock()
        var sink = 0.0
        let elapsed = clock.measure {
            for q in xs.indices {
                let c = grid.cell(x: xs[q], y: ys[q])
                var n = 0
                pack.forEachSegment(inCellX: c.cx, y: c.cy) { s in
                    n += 1
                    let a = grid.frame(pack.point(s)), b = grid.frame(pack.point(s + 1))
                    let d2 = RoadGeometry.distanceSquared(px: xs[q], py: ys[q], ax: a.x, ay: a.y, bx: b.x, by: b.y)
                    if d2 <= r2 { within += 1 }
                    sink += d2
                }
                counts.append(n)
            }
        }
        if sink.isNaN { print("") }  // keeps the loop from being optimised away
        let ns = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9

        var cellSizes: [Int] = []
        cellSizes.reserveCapacity(pack.cellCount)
        for c in 0..<pack.cellCount { cellSizes.append(pack.cellEntryRange(c).count) }
        let sortedCounts = counts.sorted(), sortedCells = cellSizes.sorted()
        func pct(_ v: [Int], _ p: Double) -> Int {
            v.isEmpty ? 0 : v[min(v.count - 1, Int((Double(v.count - 1) * p).rounded()))]
        }
        let n = max(1, counts.count)
        return Report(
            queries: counts.count, seed: seed,
            candidatesP50: pct(sortedCounts, 0.5), candidatesP95: pct(sortedCounts, 0.95),
            candidatesMax: sortedCounts.last ?? 0,
            candidatesMean: Double(counts.reduce(0, +)) / Double(n),
            withinRadiusMean: Double(within) / Double(n),
            nanosecondsPerLookup: ns / Double(n),
            cellEntriesP50: pct(sortedCells, 0.5), cellEntriesP95: pct(sortedCells, 0.95),
            cellEntriesMax: sortedCells.last ?? 0
        )
    }
}
