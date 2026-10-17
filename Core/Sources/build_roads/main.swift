import DriveLoggerCore
import Foundation
import RoadPackBuild

// build_roads — build and inspect road packs on the Mac (docs/ROAD_PACK.md).
//
//   swift run -c release build_roads <roads.opl> --out <pack.roadpack>
//       [--classes national|region|<highway,...>] [--grid-bbox <minLon,minLat,maxLon,maxLat>]
//       [--cell-size <m>] [--radius <m>] [--osm-timestamp <ISO 8601|unix>]
//       [--source-name <name>] [--source-sha256 <hex>] [--osmium-version <text>]
//       [--strategy <osmium extract strategy>] [--commit <git hash>]
//       [--coverage <polygon.geojson>] [--admin-level <n>] [--relation-id <id>]
//       [--max-size <bytes>] [--bench <queries>]
//   swift run -c release build_roads --info <pack.roadpack> [--bench <queries>] [--json]
//   swift run -c release build_roads --network <pack.roadpack>...
//
// The OPL comes from `osmium add-locations-to-ways -f opl` (node locations
// on each way); tools/roads/build_packs.sh runs the osmium steps. Every pack
// of one family must be built with the same --grid-bbox, --cell-size and
// --radius (the source extract's bounding box), so they share a grid ID
// and can be loaded together. A pack over 150 MB (or --max-size) is not
// written. The written pack is re-opened and verified.
//
// --info prints the header, counts, sections, META, the hash check and the
// cell statistics; --bench adds seeded lookup statistics (candidates per
// lookup, ns per lookup), only for a pack that verified (a failed verify
// skips it and exits 4). --network loads the packs together (same grid ID
// required; any order: the network sorts them by content hash) and prints
// roadSetHash and, in that canonical order, how many of each later pack's
// segments the earlier packs shadow (de-duplication). Packs
// and their META can reveal where someone
// drives: keep them in the git-ignored osm/.
//
// Data: © OpenStreetMap contributors, ODbL 1.0.
//
// Exit status: 0 ok, 1 input or build failure, 2 usage (a bad option or
// value: --grid-bbox needs four finite numbers with |lat| ≤ 90 and
// |lon| ≤ 180, --bench a positive count), 3 pack over the size limit,
// 4 --info verification failed.

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("build_roads: \(message)\n".utf8))
    exit(status)
}

let usage = """
    usage: build_roads <roads.opl> --out <pack.roadpack> [--classes national|region|<list>] \
    [--grid-bbox <minLon,minLat,maxLon,maxLat>] [--cell-size <m>] [--radius <m>] [--osm-timestamp <ts>] \
    [--source-name <s>] [--source-sha256 <hex>] [--osmium-version <s>] [--strategy <s>] [--commit <s>] \
    [--coverage <polygon.geojson>] [--admin-level <n>] [--relation-id <id>] [--max-size <bytes>] [--bench <n>]
           build_roads --info <pack.roadpack> [--bench <n>] [--json]
           build_roads --network <pack.roadpack>...
    """

var arguments = Array(CommandLine.arguments.dropFirst())
var options: [String: String] = [:]
var flags: Set<String> = []
var positional: [String] = []
let valued: Set<String> = [
    "--out", "--classes", "--grid-bbox", "--cell-size", "--radius", "--osm-timestamp", "--source-name",
    "--source-sha256", "--osmium-version", "--strategy", "--commit", "--coverage", "--admin-level",
    "--relation-id", "--max-size", "--bench", "--info",
]
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    if argument == "-h" || argument == "--help" {
        print(usage)
        exit(0)
    } else if argument == "--json" || argument == "--network" {
        flags.insert(argument)
    } else if valued.contains(argument) {
        guard !arguments.isEmpty else { fail("\(argument) needs a value\n\(usage)", status: 2) }
        options[argument] = arguments.removeFirst()
    } else if argument.hasPrefix("--") {
        fail("unknown option \(argument)\n\(usage)", status: 2)
    } else {
        positional.append(argument)
    }
}

@MainActor
func number(_ key: String) -> Double? {
    guard let text = options[key] else { return nil }
    guard let value = Double(text), value.isFinite else { fail("\(key): not a number: \(text)", status: 2) }
    return value
}

@MainActor
func integer(_ key: String) -> Int64? {
    guard let text = options[key] else { return nil }
    guard let value = Int64(text) else { fail("\(key): not an integer: \(text)", status: 2) }
    return value
}

// --bench is checked before anything is read or built (R16.1-2).
let benchQueries: Int? = options["--bench"].map { text in
    switch BuildRoadsArguments.benchQueries(text) {
    case .success(let n): n
    case .failure(let refusal): fail("\(refusal)\n\(usage)", status: 2)
    }
}

func printBench(_ report: RoadPackBench.Report) {
    print("lookup bench (seed \(report.seed), \(report.queries) queries within the radius of a random segment):")
    print("  candidates per lookup: p50 \(report.candidatesP50), p95 \(report.candidatesP95), max \(report.candidatesMax), mean \(String(format: "%.1f", report.candidatesMean))")
    print("  of which within radius: mean \(String(format: "%.1f", report.withinRadiusMean))")
    print("  lookup + distance test: \(String(format: "%.0f", report.nanosecondsPerLookup)) ns per lookup; cell search alone \(String(format: "%.0f", report.nanosecondsPerCellSearch)) ns")
    print("  entries per cell: p50 \(report.cellEntriesP50), p95 \(report.cellEntriesP95), max \(report.cellEntriesMax)")
}

// MARK: --info

if let path = options["--info"] {
    guard positional.isEmpty, options["--out"] == nil else { fail(usage, status: 2) }
    let url = URL(fileURLWithPath: path)
    let pack: RoadPack
    do {
        pack = try RoadPack(contentsOf: url, verify: false)
    } catch {
        fail("\(path): \(error)", status: 4)
    }
    // The bench runs only on a pack that verified (R16.2-1).
    let inspection = BuildRoadsArguments.inspect(pack, benchQueries: benchQueries)
    let verifyError = inspection.verifyError, bench = inspection.bench
    if flags.contains("--json") {
        struct Output: Encodable {
            var info: RoadPackInfo
            var verified: Bool
            var verifyError: String?
            var verifySeconds: Double
            var bench: RoadPackBench.Report?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let output = Output(info: pack.info, verified: verifyError == nil, verifyError: verifyError.map { "\($0)" }, verifySeconds: inspection.verifySeconds, bench: bench)
        print(String(decoding: try encoder.encode(output), as: UTF8.self))
    } else {
        let g = pack.grid
        print("road pack \(url.lastPathComponent): format v\(pack.formatVersion), \(pack.fileSize) bytes")
        print("  data: \(RoadPackFormat.attribution), \(RoadPackFormat.license)")
        print("  contentHash \(NavigationSeed.hex(pack.contentHash)), gridID \(NavigationSeed.hex(pack.gridID))")
        print("  osmTimestamp \(pack.osmTimestamp == 0 ? "unknown" : RoadPackBuild.isoTimestamp(pack.osmTimestamp))")
        print("  grid: cell \(g.cellSizeM) m, radius \(g.searchRadiusM) m, k_lat \(g.metresPerE7Lat), k_lon \(g.metresPerE7Lon) m per E7")
        print("  nodes \(pack.nodeCount), edges \(pack.edgeCount), points \(pack.pointCount), segments \(pack.segmentCount)")
        print("  cells \(pack.cellCount), cell entries \(pack.cellEntryCount) (\(String(format: "%.2f", Double(pack.cellEntryCount) / Double(max(1, pack.segmentCount)))) per segment), coverage polygon: \(pack.hasCoverage ? "yes" : "no")")
        print("  sections:")
        for s in pack.sections {
            print("    \(s.name)  offset \(s.offset)  length \(s.length)")
        }
        print("  META: \(String(decoding: pack.metaData, as: UTF8.self))")
        let ms = inspection.verifySeconds * 1000
        if let verifyError {
            print("  verify: FAILED (\(verifyError)) in \(String(format: "%.0f", ms)) ms")
        } else {
            print("  verify: ok (hash and structure) in \(String(format: "%.0f", ms)) ms")
        }
        if let bench { printBench(bench) } else if benchQueries != nil, verifyError != nil { print("  bench: skipped (verify failed)") }
    }
    exit(verifyError == nil ? 0 : 4)
}

// MARK: --network

if flags.contains("--network") {
    guard !positional.isEmpty, options.isEmpty else { fail(usage, status: 2) }
    let network: RoadNetwork
    // The network's packs are in content-hash order, not the order given:
    // each is named by its own file.
    var fileName: [UInt64: String] = [:]
    do {
        let packs = try positional.map { try RoadPack(contentsOf: URL(fileURLWithPath: $0)) }
        for (pack, path) in zip(packs, positional) { fileName[pack.contentHash] = URL(fileURLWithPath: path).lastPathComponent }
        network = try RoadNetwork(packs: packs)
    } catch {
        fail("\(error)", status: 4)
    }
    print("road network of \(network.packs.count) packs: roadSetHash \(network.roadSetHashHex), gridID \(NavigationSeed.hex(network.gridID))")
    print("  data: \(RoadPackFormat.attribution), \(RoadPackFormat.license)")
    for (p, pack) in network.packs.enumerated() {
        var shadowed = 0
        if p > 0 {
            for e in 0..<pack.edgeCount {
                let r = pack.edge(e)
                for k in 0..<(Int(r.pointCount) - 1) {
                    let key = RoadSegmentKey(osmWayID: r.osmWayID, index: r.wayPointOffset + UInt32(k))
                    if network.isShadowed(key, inPack: p) { shadowed += 1 }
                }
            }
        }
        print("  [\(p)] \(fileName[pack.contentHash] ?? "?"): contentHash \(NavigationSeed.hex(pack.contentHash)), segments \(pack.segmentCount), shadowed by earlier packs \(shadowed)")
    }
    exit(0)
}

// MARK: Build

guard positional.count == 1, let outPath = options["--out"] else { fail(usage, status: 2) }
let inputURL = URL(fileURLWithPath: positional[0])
let outURL = URL(fileURLWithPath: outPath)

let classes: [String]
switch options["--classes"] ?? "region" {
case "national": classes = RoadGraphBuilder.nationalClasses
case "region": classes = RoadGraphBuilder.regionClasses
case let list:
    classes = list.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    for c in classes where RoadClass.parse(highway: c) == nil {
        fail("--classes: unknown or non-drivable highway class \(c)", status: 2)
    }
}

let clock = ContinuousClock()
let started = clock.now
let opl: Data
do {
    opl = try Data(contentsOf: inputURL, options: .alwaysMapped)
} catch {
    fail("\(inputURL.path): \(error.localizedDescription)", status: 1)
}
let ways: [OPLWay]
do {
    ways = try OPLReader.ways(in: opl)
} catch {
    fail("\(inputURL.path): \(error)", status: 1)
}
let parsed = clock.now

let cellSize = number("--cell-size") ?? RoadGrid.defaultCellSizeM
let radius = number("--radius") ?? RoadGrid.defaultSearchRadiusM
let grid: RoadGrid
if let text = options["--grid-bbox"] {
    switch BuildRoadsArguments.gridBox(text) {
    case .success(let box):
        grid = RoadGrid(southWest: box.southWest, northEast: box.northEast, cellSizeM: cellSize, searchRadiusM: radius)
    case .failure(let refusal):
        fail("\(refusal)", status: 2)
    }
} else {
    // The pack's own bounding box: fine for one pack, but another pack
    // gets a different grid ID and cannot be loaded with it.
    var minLat = Int32.max, minLon = Int32.max, maxLat = Int32.min, maxLon = Int32.min
    for way in ways { for node in way.nodes { if let p = node.location {
        minLat = min(minLat, p.latE7); maxLat = max(maxLat, p.latE7); minLon = min(minLon, p.lonE7); maxLon = max(maxLon, p.lonE7)
    } } }
    guard minLat <= maxLat else { fail("\(inputURL.path): no located way nodes", status: 1) }
    FileHandle.standardError.write(Data("build_roads: no --grid-bbox; the grid is this pack's own, so it cannot be combined with other packs\n".utf8))
    grid = RoadGrid(southWest: RoadPoint(latE7: minLat, lonE7: minLon), northEast: RoadPoint(latE7: maxLat, lonE7: maxLon), cellSizeM: cellSize, searchRadiusM: radius)
}
if let reason = grid.invalidReason { fail("grid: \(reason)", status: 2) }

var parameters = RoadPackBuild.Parameters(classes: classes, grid: grid)
if let text = options["--osm-timestamp"] {
    guard let ts = RoadPackBuild.parseTimestamp(text) else { fail("--osm-timestamp: not ISO 8601 or Unix seconds: \(text)", status: 2) }
    parameters.osmTimestamp = ts
}
parameters.sourceName = options["--source-name"]
parameters.sourceSHA256 = options["--source-sha256"]
parameters.osmiumVersion = options["--osmium-version"]
parameters.extractStrategy = options["--strategy"]
parameters.builderCommit = options["--commit"]
parameters.coverageAdminLevel = integer("--admin-level").map { Int($0) }
parameters.coverageRelationID = integer("--relation-id")
if let limit = integer("--max-size") {
    guard limit > 0 else { fail("--max-size must be > 0", status: 2) }
    parameters.sizeLimit = Int(min(limit, Int64(RoadPackFormat.maximumFileSize)))
}
if let path = options["--coverage"] {
    do {
        parameters.coverage = try CoverageReader.rings(fromGeoJSON: Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        fail("\(path): \(error)", status: 1)
    }
}

let result: RoadPackBuild.Result
do {
    result = try RoadPackBuild.build(ways: ways, parameters: parameters)
    // An empty pack is almost always a broken pipeline (an empty or
    // misplaced extract), not a real region without roads.
    guard result.index.edges > 0 else { fail("\(inputURL.path): no roads of the selected classes (\(ways.count) ways read); not written", status: 1) }
} catch let error as RoadPackError {
    if case .tooLarge = error { fail("\(error); not written (split the region at admin_level 6)", status: 3) }
    fail("\(error)", status: 1)
} catch {
    fail("\(error)", status: 1)
}
let built = clock.now

do {
    try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try result.data.write(to: outURL, options: .atomic)
    let reopened = try RoadPack(contentsOf: outURL, verify: true)
    guard reopened.contentHash == RoadPackFormat.contentHash(of: result.data) else { fail("re-read hash differs", status: 1) }
} catch {
    fail("\(outURL.path): \(error)", status: 1)
}
let finished = clock.now

func seconds(_ d: Duration) -> String {
    String(format: "%.2f s", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
}
let b = result.builder, i = result.index
print("built \(outURL.lastPathComponent): \(i.fileSize) bytes, contentHash \(NavigationSeed.hex(RoadPackFormat.contentHash(of: result.data)))")
print("  data: \(RoadPackFormat.attribution), \(RoadPackFormat.license)")
print("  ways read \(b.waysRead), kept \(b.waysKept) (oneway \(b.waysOneway), reversed \(b.waysReversed)); dropped: class \(b.waysWrongClass), area \(b.waysArea), parking aisle \(b.waysParkingAisle), degenerate \(b.waysDegenerate); node refs without location \(b.nodesWithoutLocation); points at a repeated coordinate \(b.pointsAtRepeatedCoordinate) (node IDs merged \(b.nodesMerged))")
print("  nodes \(i.nodes), edges \(i.edges), points \(i.points), segments \(i.segments), cells \(i.cells), cell entries \(i.cellEntries) (R_eff \(String(format: "%.3f", i.effectiveRadiusM)) m)")
print("  time: read \(seconds(parsed - started)), build \(seconds(built - parsed)), write + verify \(seconds(finished - built)), total \(seconds(finished - started))")
if let n = benchQueries {
    do {
        printBench(RoadPackBench.run(pack: try RoadPack(contentsOf: outURL, verify: false), queries: n))
    } catch {
        fail("\(outURL.path): \(error)", status: 1)
    }
}
