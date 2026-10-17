import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// N3.1 properties of the road pack format and index (docs/ROAD_PACK.md).
@Suite("Road pack properties")
struct RoadPackPropertyTests {
    typealias N = RoadFixture.Node

    /// A small synthetic town near (0, 0): a 5 × 5 street grid at 120 m,
    /// a diagonal trunk, a oneway pair, a bridge and a cul-de-sac.
    static func townLines() -> [String] {
        var lines: [String] = []
        var id: Int64 = 1
        func nodeID(_ i: Int, _ j: Int) -> Int64 { Int64(1000 + 10 * i + j) }
        for i in 0..<5 {
            let x = Double(i) * 120 - 240
            lines.append(RoadFixture.way(id, ["highway": "residential"], (0..<5).map { N(id: nodeID(i, $0), east: x, north: Double($0) * 120 - 240) }))
            id += 1
            lines.append(RoadFixture.way(id, ["highway": i == 2 ? "secondary" : "residential"], (0..<5).map { N(id: nodeID($0, i), east: Double($0) * 120 - 240, north: x) }))
            id += 1
        }
        lines.append(RoadFixture.way(50, ["highway": "trunk", "lanes": "2"], [N(id: 1, east: -600, north: -500), N(id: 2, east: -100, north: -40), N(id: 3, east: 610, north: 590)]))
        lines.append(RoadFixture.way(51, ["highway": "primary", "oneway": "yes"], [N(id: 4, east: -700, north: 400), N(id: 5, east: 700, north: 400)]))
        lines.append(RoadFixture.way(52, ["highway": "primary", "oneway": "yes"], [N(id: 6, east: 700, north: 415), N(id: 7, east: -700, north: 415)]))
        lines.append(RoadFixture.way(53, ["highway": "tertiary", "bridge": "yes", "layer": "1"], [N(id: 8, east: 300, north: -600), N(id: 9, east: 300, north: 600)]))
        lines.append(RoadFixture.way(54, ["highway": "living_street"], [N(id: nodeID(4, 4), east: 240, north: 240), N(id: 10, east: 260, north: 300), N(id: 11, east: 255, north: 340)]))
        return lines
    }

    // MARK: Round trip

    @Test("Round trip: every edge, point, node and adjacency the writer was given reads back exactly, from memory and from a mapped file")
    func roundTrip() throws {
        let ways = try OPLReader.ways(in: Self.townLines().joined(separator: "\n"))
        let (graph, _) = try RoadGraphBuilder(classes: Set(RoadGraphBuilder.regionClasses)).build(ways: ways)
        let grid = RoadFixture.grid()
        let writer = RoadPackWriter(grid: grid, osmTimestamp: 1_600_000_000, meta: ["note": .string("synthetic")], coverage: [[
            RoadFixture.point(-800, -800), RoadFixture.point(800, -800), RoadFixture.point(800, 800), RoadFixture.point(-800, 800),
        ]])
        let data = try writer.write(graph)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("roadpack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("town.roadpack")
        try data.write(to: url)

        for pack in [try RoadPack(data: data), try RoadPack(contentsOf: url)] {
            #expect(pack.formatVersion == 1)
            #expect(pack.osmTimestamp == 1_600_000_000)
            #expect(pack.grid == grid)
            #expect(pack.gridID == grid.gridID)
            #expect(pack.fileSize == data.count && data.count % 8 == 0)
            #expect(pack.contentHash == RoadPackFormat.contentHash(of: data))
            #expect(pack.sections.allSatisfy { $0.offset % 8 == 0 })
            let expected = graph.edges.sorted { ($0.osmWayID, $0.wayPointOffset) < ($1.osmWayID, $1.wayPointOffset) }
            #expect(pack.edgeCount == expected.count)
            for (i, e) in expected.enumerated() {
                let r = pack.edge(i)
                #expect(r.osmWayID == e.osmWayID && r.wayPointOffset == e.wayPointOffset)
                #expect(r.highwayClass == e.highwayClass && r.level == e.level && r.flags == e.flags && r.lanes == e.lanes)
                #expect(RoadFixture.points(of: pack, edge: i) == e.points)
                #expect(pack.node(Int(r.from)) == e.points.first && pack.node(Int(r.to)) == e.points.last)
                #expect(pack.incidentEdges(Int(r.from)).contains(i) && pack.incidentEdges(Int(r.to)).contains(i))
                for k in 0..<(e.points.count - 1) {
                    let s = pack.segment(startingAt: Int(r.firstPoint) + k)
                    #expect(s.key == RoadSegmentKey(osmWayID: e.osmWayID, index: e.wayPointOffset + UInt32(k)))
                    #expect(pack.segment(withKey: s.key) == s)
                }
            }
            #expect(pack.segment(withKey: RoadSegmentKey(osmWayID: 50, index: 99)) == nil)
            #expect(pack.segment(withKey: RoadSegmentKey(osmWayID: 49, index: 0)) == nil)
            #expect(try pack.coverageRings()?.first?.count == 4)
            let info = pack.info
            #expect(info.attribution == "© OpenStreetMap contributors" && info.license == "ODbL 1.0")
            guard case .string("synthetic")? = pack.meta?["note"] else { Issue.record("META lost"); continue }
            let decoded = try JSONDecoder().decode(RoadPackInfo.self, from: JSONEncoder().encode(info))
            #expect(decoded == info)
        }
    }

    @Test("The OPL reader converts decimal degrees to E7 exactly and unescapes tags")
    func oplReader() throws {
        let line = "w42 v3 dV c0 t2020-01-01T00:00:00Z i0 u Thighway=residential,name=A%20%B%2c%C Nn1x-0.0000001y0.1234567,n2x12.5y-3,n3xy"
        let way = try #require(try OPLReader.ways(in: "n1 v1 x0 y0\n" + line + "\r\nr5 v1 Mw42@\n").first)
        #expect(way.id == 42)
        #expect(way.tags == ["highway": "residential", "name": "A B,C"])
        #expect(way.nodes.map(\.id) == [1, 2, 3])
        #expect(way.nodes[0].location == RoadPoint(latE7: 1_234_567, lonE7: -1))
        #expect(way.nodes[1].location == RoadPoint(latE7: -30_000_000, lonE7: 125_000_000))
        #expect(way.nodes[2].location == nil)
        #expect(throws: OPLError.self) { try OPLReader.ways(in: "w1 v1 Thighway=residential Nn1x0.12345678y0") }
        #expect(throws: OPLError.self) { try OPLReader.ways(in: "w1 v1 Thighway=residential") }
    }

    // MARK: Brute force against the grid

    @Test("Brute force vs grid over 10 000 seeded random points: identical candidate sets within R", arguments: [32.0, 64.0, 128.0])
    func bruteForceAgainstGrid(cellSizeM: Double) throws {
        let pack = try RoadFixture.build(Self.townLines(), grid: RoadFixture.grid(cellSizeM: cellSizeM))
        let radius = pack.grid.searchRadiusM
        var segments: [RoadPack.Segment] = []
        for e in 0..<pack.edgeCount {
            let r = pack.edge(e)
            for k in 0..<(Int(r.pointCount) - 1) { segments.append(pack.segment(startingAt: Int(r.firstPoint) + k)) }
        }
        #expect(segments.count == pack.segmentCount)
        var rng = NavigationRandom(seed: 2026)
        var nonEmpty = 0, nearBoundary = 0
        for _ in 0..<10_000 {
            // Half anywhere in the town's box, half within R + 5 m of a
            // random segment, so the radius boundary is well sampled.
            let point: RoadPoint
            if rng.nextUniform() < 0.5 {
                point = RoadFixture.point(rng.nextUniform() * 1600 - 800, rng.nextUniform() * 1600 - 800)
            } else {
                let s = segments[Int(rng.next() % UInt64(segments.count))]
                let a = RoadFixture.metres(s.a), b = RoadFixture.metres(s.b)
                let t = rng.nextUniform(), angle = 2 * Double.pi * rng.nextUniform(), r = (radius + 5) * rng.nextUniform()
                point = RoadFixture.point(a.east + t * (b.east - a.east) + r * sin(angle), a.north + t * (b.north - a.north) + r * cos(angle))
            }
            let lat = Double(point.latE7), lon = Double(point.lonE7)
            var brute: Set<RoadSegmentKey> = []
            for s in segments {
                let d = RoadFixture.trueDistance(latE7: lat, lonE7: lon, s.a, s.b)
                if d <= radius { brute.insert(s.key) }
                if abs(d - radius) < 1 { nearBoundary += 1 }
            }
            let c = pack.grid.cell(latitude: point.latitude, longitude: point.longitude)
            var gridSet: Set<RoadSegmentKey> = []
            for start in pack.segments(inCellX: c.cx, y: c.cy) {
                let s = pack.segment(startingAt: start)
                if RoadFixture.trueDistance(latE7: lat, lonE7: lon, s.a, s.b) <= radius { gridSet.insert(s.key) }
            }
            #expect(gridSet == brute)
            if !brute.isEmpty { nonEmpty += 1 }
        }
        #expect(nonEmpty > 5000)
        #expect(nearBoundary > 100)
    }

    @Test("R_eff covers the frame's worst scale error over a wide family and is at least R")
    func effectiveRadius() {
        let wide = RoadGrid(
            southWest: RoadPoint(latE7: -100_000_000, lonE7: -100_000_000),
            northEast: RoadPoint(latE7: 100_000_000, lonE7: 100_000_000)
        )
        // At the band's edge (±10°) longitude metres are cos 10° ≈ 0.985 of
        // the centre's, so the frame overstates them by ~1.5 %.
        let scale = wide.maximumScale(minLatitude: -10, maxLatitude: 10)
        let truthAtEdge = RoadGrid.trueMetresPerE7(latitude: 10)
        #expect(abs(scale - wide.metresPerE7Lon / truthAtEdge.lon) < 1e-12)
        #expect(scale > 1.015 && scale < 1.016)
        #expect(wide.effectiveRadiusM(minLatitude: -10, maxLatitude: 10) > 50 * scale)
        #expect(RoadFixture.grid().effectiveRadiusM(minLatitude: 0, maxLatitude: 0) >= 50)
    }

    /// Regression for R16.1-1: the writer must index with R_eff, not R.
    /// Near (0, 0) the builder's frame cannot overstate distance materially
    /// (N·cos φ peaks at the equator), so this uses a synthetic family box
    /// 58°–62° N, 0°–0.1° E built with the same initialiser as
    /// `build_roads --grid-bbox`, and data at its north edge (~62°), where
    /// the frame (scales at 60°) overstates longitude metres by
    /// cos 60° / cos 62° ≈ 1.065. Indexing with R would drop segments
    /// 47–50 true metres east or west of a query.
    @Test("Writer indexes with R_eff: a scale-distorted family frame still lists every segment within R true metres")
    func writerUsesEffectiveRadius() throws {
        let grid = RoadGrid(
            southWest: RoadPoint(latE7: 580_000_000, lonE7: 0),
            northEast: RoadPoint(latE7: 620_000_000, lonE7: 1_000_000)
        )
        let radius = grid.searchRadiusM
        // Local metres around a synthetic origin near the box's north edge.
        let originLatE7 = 619_950_000.0, originLonE7 = 500_000.0
        let k = RoadGrid.trueMetresPerE7(latitude: originLatE7 / 1e7)
        func point(_ east: Double, _ north: Double) -> RoadPoint {
            RoadPoint(latE7: Int32((originLatE7 + north / k.lat).rounded()), lonE7: Int32((originLonE7 + east / k.lon).rounded()))
        }
        func metres(_ p: RoadPoint) -> (east: Double, north: Double) {
            ((Double(p.lonE7) - originLonE7) * k.lon, (Double(p.latE7) - originLatE7) * k.lat)
        }
        // Two north-south streets (distance to them is all longitude), placed
        // so a cell boundary lies 51.6 frame metres east of the first and
        // west of the second: between R and R · 1.065, so a cell beyond that
        // boundary holds points 48.5–50 true metres from the street and is
        // listed only if the writer used R_eff. Any street position is valid
        // input; this one is the unlucky alignment, chosen rather than hoped
        // for. Plus an east-west street and a diagonal with a bend.
        let originFrameX = (originLonE7 - Double(grid.originLonE7)) * grid.metresPerE7Lon
        let boundaryX = (originFrameX / grid.cellSizeM).rounded() * grid.cellSizeM
        func eastOfFrameX(_ frameX: Double) -> Double {
            let lonE7 = (Double(grid.originLonE7) + frameX / grid.metresPerE7Lon).rounded()
            return (lonE7 - originLonE7) * k.lon
        }
        let westStreet = eastOfFrameX(boundaryX - 51.6), eastStreet = eastOfFrameX(boundaryX + 3 * grid.cellSizeM + 51.6)
        let shapes: [[(Double, Double)]] = [
            [(westStreet, -400), (westStreet, 0), (westStreet, 400)],
            [(eastStreet, -400), (eastStreet, 400)],
            [(-400, 20), (400, 20)],
            [(-400, -400), (-50, -120), (400, 300)],
        ]
        var nodeID: Int64 = 1
        let edges = shapes.enumerated().map { i, shape -> RoadGraph.Edge in
            defer { nodeID += 2 }
            return RoadGraph.Edge(
                fromNode: nodeID, toNode: nodeID + 1, points: shape.map { point($0.0, $0.1) },
                osmWayID: Int64(i + 1), wayPointOffset: 0, highwayClass: .residential
            )
        }
        // The alignment survived E7 rounding.
        let westFrameX = grid.frame(edges[0].points[0]).x, eastFrameX = grid.frame(edges[1].points[0]).x
        #expect(abs(boundaryX - westFrameX - 51.6) < 0.01 && abs(eastFrameX - (boundaryX + 3 * grid.cellSizeM) - 51.6) < 0.01)
        let written = try RoadPackWriter(grid: grid).writeWithStatistics(RoadGraph(edges: edges))
        let pack = try RoadPack(data: written.data)
        #expect(pack.grid == grid)
        // The fixture must be material: R_eff well above R.
        let scale = grid.maximumScale(minLatitude: 61.99, maxLatitude: 62.0)
        #expect(scale > 1.06 && scale < 1.07)
        #expect(written.statistics.effectiveRadiusM > radius * 1.06)

        var segments: [RoadPack.Segment] = []
        for e in 0..<pack.edgeCount {
            let r = pack.edge(e)
            for j in 0..<(Int(r.pointCount) - 1) { segments.append(pack.segment(startingAt: Int(r.firstPoint) + j)) }
        }
        #expect(segments.count == 6)
        var rng = NavigationRandom(seed: 1601)
        var nearBoundary = 0, missed = 0
        var firstMiss: String?
        for _ in 0..<20_000 {
            // Three quarters perpendicular to a random segment at R − 6 m to
            // R + 1 m, so the boundary is densely sampled; the rest at a
            // random angle within R + 5 m.
            let s = segments[Int(rng.next() % UInt64(segments.count))]
            let a = metres(s.a), b = metres(s.b)
            let t = rng.nextUniform()
            let dx = b.east - a.east, dy = b.north - a.north, length = (dx * dx + dy * dy).squareRoot()
            let ox: Double, oy: Double
            if rng.nextUniform() < 0.75 {
                let r = (radius - 6 + 7 * rng.nextUniform()) * (rng.nextUniform() < 0.5 ? -1 : 1)
                ox = -dy / length * r; oy = dx / length * r
            } else {
                let angle = 2 * Double.pi * rng.nextUniform(), r = (radius + 5) * rng.nextUniform()
                ox = r * sin(angle); oy = r * cos(angle)
            }
            let q = point(a.east + t * dx + ox, a.north + t * dy + oy)
            let lat = Double(q.latE7), lon = Double(q.lonE7)
            var brute: Set<RoadSegmentKey> = []
            for s in segments {
                let d = RoadFixture.trueDistance(latE7: lat, lonE7: lon, s.a, s.b)
                if d <= radius { brute.insert(s.key) }
                if d <= radius, d > radius - 3.5 { nearBoundary += 1 }
            }
            let c = pack.grid.cell(latitude: q.latitude, longitude: q.longitude)
            let listed = Set(pack.segments(inCellX: c.cx, y: c.cy).map { pack.segment(startingAt: $0).key })
            let missing = brute.subtracting(listed)
            if !missing.isEmpty {
                missed += 1
                if firstMiss == nil {
                    let d = missing.map { key in
                        let s = segments.first { $0.key == key }!
                        return RoadFixture.trueDistance(latE7: lat, lonE7: lon, s.a, s.b)
                    }
                    firstMiss = "query \(q) misses \(missing.map(\.osmWayID).sorted()) at \(d.map { String(format: "%.2f", $0) }) m true"
                }
            }
        }
        #expect(missed == 0, "\(missed) of 20000 queries miss a segment within \(radius) m true; first: \(firstMiss ?? "-")")
        #expect(nearBoundary > 3000)
    }

    // MARK: Determinism

    @Test("Builder determinism: the same bytes from shuffled OPL lines (nodes and relations mixed in) and twice in a row")
    func determinism() throws {
        let lines = Self.townLines() + RoadGraphTests.bridgeLines(idOffset: 90_000)
            + ["n77 v1 dV c0 t i0 u T x0.001 y0.001", "r9 v1 dV c0 t i0 u Ttype=route Mw1@"]
        let reference = try RoadFixture.buildData(lines)
        #expect(try RoadFixture.buildData(lines) == reference)
        var rng = NavigationRandom(seed: 99)
        for _ in 0..<5 {
            var shuffled = lines
            for i in stride(from: shuffled.count - 1, to: 0, by: -1) {
                shuffled.swapAt(i, Int(rng.next() % UInt64(i + 1)))
            }
            #expect(try RoadFixture.buildData(shuffled) == reference)
        }
    }

    /// Pinned: a change here is a format or builder change and needs a new
    /// `formatVersion` or `RoadPackBuild.builderVersion` (like the
    /// `NavigationSeed` pin).
    ///
    /// Builder version 2 (zero-length segments collapsed): the town fixture
    /// has no stacked nodes, so only META's `builder.version` changed; with
    /// version "1" the bytes are those of the previous pin
    /// 0x109F_22B3_A9B5_986E.
    static let goldenContentHash: UInt64 = 0xDA69_74C3_C8F1_0751
    static let goldenFileSize = 10104

    @Test("Golden contentHash of the town fixture (format and builder stability)")
    func goldenHash() throws {
        let data = try RoadFixture.buildData(Self.townLines())
        let pack = try RoadPack(data: data)
        #expect(NavigationSeed.hex(pack.contentHash) == NavigationSeed.hex(Self.goldenContentHash))
        #expect(pack.fileSize == Self.goldenFileSize)
        #expect(NavigationSeed.hex(pack.gridID) == NavigationSeed.hex(RoadFixture.grid().gridID))
    }

    @Test("contentHash is FNV-1a 64 of the file with bytes 16–23 as zero; roadSetHash is over the hashes in ascending order")
    func hashDefinition() throws {
        let data = try RoadFixture.buildData(Self.townLines())
        var zeroed = [UInt8](data)
        for i in 16..<24 { zeroed[i] = 0 }
        #expect(NavigationSeed.fnv1a64(zeroed) == RoadPackFormat.contentHash(of: data))
        let stored = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self)) }
        #expect(stored == NavigationSeed.fnv1a64(zeroed))
        // N3.2c item 7: a set's identity, not the order given.
        #expect(RoadPackFormat.roadSetHash([1, 2]) == RoadPackFormat.roadSetHash([2, 1]))
        #expect(RoadPackFormat.roadSetHash([2, 1]) == NavigationSeed.fnv1a64([1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0]))
        #expect(RoadPackFormat.roadSetHash([]) == NavigationSeed.fnv1a64([UInt8]()))
        #expect(RoadPackFormat.roadSetHash([0x0102_0304_0506_0708]) == NavigationSeed.fnv1a64([8, 7, 6, 5, 4, 3, 2, 1]))
    }

    @Test("META's builder.commit is part of the pack identity: the same commit gives the same bytes, another commit another hash")
    func builderCommitInHash() throws {
        func build(_ commit: String?) throws -> Data {
            var parameters = RoadPackBuild.Parameters(classes: RoadGraphBuilder.regionClasses, grid: RoadFixture.grid())
            parameters.builderCommit = commit
            return try RoadPackBuild.build(opl: Data(Self.townLines().joined(separator: "\n").utf8), parameters: parameters).data
        }
        let a = try build("0123456789ab")
        #expect(try build("0123456789ab") == a)
        #expect(RoadPackFormat.contentHash(of: try build("0123456789ab-dirty")) != RoadPackFormat.contentHash(of: a))
        #expect(RoadPackFormat.contentHash(of: try build(nil)) != RoadPackFormat.contentHash(of: a))
        let meta = try RoadPack(data: a).meta
        guard case .object(let builder)? = meta?["builder"] else { Issue.record("no builder object"); return }
        #expect(builder["commit"] == .string("0123456789ab"))
    }

    // MARK: Networks

    @Test("De-duplication across two overlapping packs: each segment key once, the pack with the lower content hash wins in either order")
    func deduplication() throws {
        let lines = Self.townLines()
        // Pack A: the street grid and the trunk; pack B: the trunk again
        // (overlap) plus the oneways, the bridge and the cul-de-sac.
        let a = try RoadFixture.build(Array(lines[0..<11]))
        let b = try RoadFixture.build(Array(lines[10...]))
        #expect(a.gridID == b.gridID)
        let ab = try RoadNetwork(packs: [a, b])
        let ba = try RoadNetwork(packs: [b, a])
        // N3.2c item 7: one network whatever the order given.
        #expect(ab.roadSetHash == ba.roadSetHash)
        #expect(ab.roadSetHash == RoadPackFormat.roadSetHash([a.contentHash, b.contentHash]))
        let canonical = [a, b].sorted { $0.contentHash < $1.contentHash }
        #expect(ab.packs.map(\.contentHash) == canonical.map(\.contentHash))
        #expect(ba.packs.map(\.contentHash) == canonical.map(\.contentHash))
        let full = try RoadFixture.build(lines)

        var rng = NavigationRandom(seed: 5)
        var sawShared = false
        for _ in 0..<2000 {
            let p = RoadFixture.point(rng.nextUniform() * 1400 - 700, rng.nextUniform() * 1400 - 700)
            let c = full.grid.cell(latitude: p.latitude, longitude: p.longitude)
            let reference = Set(full.segments(inCellX: c.cx, y: c.cy).map { full.segment(startingAt: $0).key })
            for network in [ab, ba] {
                let refs = network.segments(nearLatitude: p.latitude, longitude: p.longitude)
                let keys = refs.map { network.segment($0).key }
                #expect(keys.count == Set(keys).count)
                #expect(Set(keys) == reference)
                for (ref, key) in zip(refs, keys) where key.osmWayID == 50 {
                    sawShared = true
                    #expect(ref.pack == 0)  // the trunk is in both: the lower content hash wins
                    _ = key
                }
                #expect(refs == refs.sorted())
            }
            #expect(ab.segments(nearLatitude: p.latitude, longitude: p.longitude)
                == ba.segments(nearLatitude: p.latitude, longitude: p.longitude))
        }
        #expect(sawShared)
        #expect(ab.infos.map(\.contentHash) == canonical.map { NavigationSeed.hex($0.contentHash) })
        #expect(ba.infos == ab.infos)
    }

    @Test("A network refuses packs with different grids, the same pack twice, and no packs")
    func networkRefusals() throws {
        let lines = Self.townLines()
        let a = try RoadFixture.build(lines)
        let other = try RoadFixture.build(lines, grid: RoadFixture.grid(cellSizeM: 128))
        #expect(throws: RoadPackError.gridMismatch(a.gridID, other.gridID)) { try RoadNetwork(packs: [a, other]) }
        #expect(throws: RoadPackError.duplicatePack(a.contentHash)) { try RoadNetwork(packs: [a, try RoadPack(data: RoadFixture.buildData(lines))]) }
        #expect(throws: RoadPackError.noPacks) { try RoadNetwork(packs: []) }
    }

    @Test("Coverage: the COVR polygon with the even-odd rule, else the bounding box")
    func coverage() throws {
        let outer = [RoadFixture.point(-800, -800), RoadFixture.point(800, -800), RoadFixture.point(800, 800), RoadFixture.point(-800, 800)]
        let hole = [RoadFixture.point(-100, -100), RoadFixture.point(100, -100), RoadFixture.point(100, 100), RoadFixture.point(-100, 100)]
        let polygon = try RoadNetwork(packs: [try RoadFixture.build(Self.townLines(), coverage: [outer, hole])])
        func covers(_ network: RoadNetwork, _ east: Double, _ north: Double) -> Bool {
            let p = RoadFixture.point(east, north)
            return network.covers(latitude: p.latitude, longitude: p.longitude)
        }
        #expect(covers(polygon, 500, 0) && !covers(polygon, 0, 0) && !covers(polygon, 900, 0))
        let box = try RoadNetwork(packs: [try RoadFixture.build(Self.townLines())])
        #expect(covers(box, 0, 0) && covers(box, 690, 580) && !covers(box, 900, 0))
        // GeoJSON coverage as osmium export writes it.
        let geojson = #"{"type":"Feature","properties":{},"geometry":{"type":"MultiPolygon","coordinates":[[[[0,0],[0.001,0],[0.001,0.001],[0,0]],[[0.0002,0.0001],[0.0003,0.0001],[0.0003,0.0002],[0.0002,0.0001]]]]}}"#
        let rings = try CoverageReader.rings(fromGeoJSON: Data(geojson.utf8))
        #expect(rings.map(\.count) == [3, 3])
        #expect(rings[0][1] == RoadPoint(latE7: 0, lonE7: 10_000))
    }

    /// Three short streets, `dx`, `dy` metres from (0, 0): distinct content per offset.
    static func streets(_ dx: Double, _ dy: Double, firstID: Int64) -> [String] {
        (0..<3).map { k in
            let id = firstID + Int64(k), y = dy + Double(k) * 150 - 150
            return RoadFixture.way(id, ["highway": "residential"],
                                   [N(id: 10 * id, east: dx - 300, north: y), N(id: 10 * id + 1, east: dx + 300, north: y)])
        }
    }

    @Test("Coverage: trying the cheapest pack first equals the OR over packs in canonical order")
    func coverageOrderIsAnOR() throws {
        func circle(_ cx: Double, _ cy: Double, _ r: Double, _ n: Int) -> [RoadPoint] {
            (0..<n).map { k in
                let a = 2 * Double.pi * Double(k) / Double(n)
                return RoadFixture.point(cx + r * cos(a), cy + r * sin(a))
            }
        }
        func square(_ cx: Double, _ cy: Double, _ h: Double) -> [RoadPoint] {
            [RoadFixture.point(cx - h, cy - h), RoadFixture.point(cx + h, cy - h),
             RoadFixture.point(cx + h, cy + h), RoadFixture.point(cx - h, cy + h)]
        }
        // Overlapping coverage of every kind: a many-vertex ring with a hole,
        // two bounding boxes (no COVR), a small square with a hole and a
        // triangle, so a point is often covered by several packs and the
        // cheap packs are not the canonical first.
        let packs = [
            try RoadFixture.build(Self.streets(0, 0, firstID: 100), coverage: [circle(0, 0, 900, 400), square(0, 0, 120)]),
            try RoadFixture.build(Self.streets(700, 0, firstID: 200)),
            try RoadFixture.build(Self.streets(0, 800, firstID: 300)),
            try RoadFixture.build(Self.streets(-600, -600, firstID: 400), coverage: [square(-600, -600, 400), square(-600, -600, 50)]),
            try RoadFixture.build(Self.streets(600, -700, firstID: 500),
                                  coverage: [[RoadFixture.point(200, -1100), RoadFixture.point(1100, -1000), RoadFixture.point(500, -300)]]),
        ]
        let network = try RoadNetwork(packs: packs)
        #expect(network.coverageOrder.sorted() == Array(network.packs.indices))
        #expect(network.coverageOrder != Array(network.packs.indices))
        // The rule before the reorder, written out independently: packs in
        // canonical order, the COVR polygon (even-odd) if present, else the
        // shape-point bounding box.
        let canonical = try network.packs.map { (rings: try $0.coverageRings(), box: $0.pointBounds()) }
        func reference(_ latitude: Double, _ longitude: Double) -> Bool {
            let latE7 = latitude * 1e7, lonE7 = longitude * 1e7
            for pack in canonical {
                if let rings = pack.rings {
                    if RoadNetwork.evenOddContains(rings: rings, latE7: latE7, lonE7: lonE7) { return true }
                } else if let b = pack.box,
                          latE7 >= Double(b.southWest.latE7), latE7 <= Double(b.northEast.latE7),
                          lonE7 >= Double(b.southWest.lonE7), lonE7 <= Double(b.northEast.lonE7) {
                    return true
                }
            }
            return false
        }
        // A grid over and beyond every pack, every coverage vertex and every
        // shape point (boundary cases), and points just off the vertices.
        var points: [(Double, Double)] = []
        for i in stride(from: -1500.0, through: 1500, by: 47) {
            for j in stride(from: -1500.0, through: 1500, by: 43) {
                let p = RoadFixture.point(i, j)
                points.append((p.latitude, p.longitude))
            }
        }
        for pack in network.packs {
            var vertices = (try pack.coverageRings() ?? []).flatMap { $0 }
            vertices += (0..<pack.pointCount).map { pack.point($0) }
            for v in vertices {
                points.append((v.latitude, v.longitude))
                points.append((v.latitude + 1e-7, v.longitude - 1e-7))
            }
        }
        var covered = 0, mismatches = 0
        for (latitude, longitude) in points {
            let got = network.covers(latitude: latitude, longitude: longitude)
            if got != reference(latitude, longitude) { mismatches += 1 }
            if got { covered += 1 }
        }
        #expect(mismatches == 0, "\(mismatches) of \(points.count) points")
        #expect(covered > points.count / 10 && covered < points.count * 9 / 10)
        // The input order of the packs changes nothing.
        let reversed = try RoadNetwork(packs: packs.reversed())
        #expect(reversed.coverageOrder == network.coverageOrder)
        #expect(points.allSatisfy { reversed.covers(latitude: $0.0, longitude: $0.1) == network.covers(latitude: $0.0, longitude: $0.1) })
        #expect(points.count > 5000)
    }

    @Test("A pack over the size limit is refused by the writer")
    func sizeLimit() throws {
        let ways = try OPLReader.ways(in: Self.townLines().joined(separator: "\n"))
        let (graph, _) = try RoadGraphBuilder(classes: Set(RoadGraphBuilder.regionClasses)).build(ways: ways)
        let size = try RoadPackWriter(grid: RoadFixture.grid()).write(graph).count
        #expect(throws: RoadPackError.tooLarge(size: size, limit: size - 1)) { try RoadPackWriter(grid: RoadFixture.grid(), sizeLimit: size - 1).write(graph) }
        #expect(try RoadPackWriter(grid: RoadFixture.grid(), sizeLimit: size).write(graph).count == size)
        #expect(RoadPackFormat.maximumFileSize == 150_000_000)
    }
}

/// N3.1 rejection cases: every corruption is refused with its own error.
@Suite("Road pack rejection")
struct RoadPackRejectionTests {
    static func fixture() throws -> [UInt8] {
        let outer = [RoadFixture.point(-800, -800), RoadFixture.point(800, -800), RoadFixture.point(800, 800), RoadFixture.point(-800, 800)]
        return [UInt8](try RoadFixture.buildData(RoadPackPropertyTests.townLines(), coverage: [outer]))
    }

    /// Store a fresh content hash, so a structural error is not masked by
    /// the hash check.
    static func rehash(_ bytes: inout [UInt8]) {
        let hash = bytes.withUnsafeBytes { RoadPackFormat.contentHash(of: $0) }
        for i in 0..<8 { bytes[16 + i] = UInt8(truncatingIfNeeded: hash >> UInt64(8 * i)) }
    }

    static func set64(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt64) {
        for i in 0..<8 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> UInt64(8 * i)) }
    }

    static func get64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << UInt64(8 * $1) }
    }

    /// Byte offset of the section table entry for `tag`.
    static func entry(_ bytes: [UInt8], _ tag: String) throws -> Int {
        let table = Int(get64(bytes, 32))
        let count = Int(bytes[40]) | Int(bytes[41]) << 8
        let want = Array(tag.utf8)
        for i in 0..<count where Array(bytes[(table + 24 * i)..<(table + 24 * i + 4)]) == want { return table + 24 * i }
        throw RoadPackError.missingSection(tag)
    }

    static func open(_ bytes: [UInt8]) throws {
        _ = try RoadPack(data: Data(bytes), verify: true)
    }

    @Test("The untouched fixture opens and verifies")
    func fixtureIsValid() throws {
        try Self.open(try Self.fixture())
    }

    @Test("Truncated file: shorter than the header, and shorter than its declared size")
    func truncated() throws {
        let bytes = try Self.fixture()
        #expect(throws: RoadPackError.truncated("file is 50 bytes, shorter than the header")) { try Self.open(Array(bytes[0..<50])) }
        do {
            try Self.open(Array(bytes.dropLast(8)))
            Issue.record("a truncated pack opened")
        } catch let error as RoadPackError {
            guard case .truncated = error else { Issue.record("expected truncated, got \(error)"); return }
        }
    }

    @Test("Bad magic")
    func badMagic() throws {
        var bytes = try Self.fixture()
        bytes[0] = UInt8(ascii: "X")
        #expect(throws: RoadPackError.badMagic) { try Self.open(bytes) }
    }

    @Test("A newer format version is refused, and so is version 0")
    func newerVersion() throws {
        var bytes = try Self.fixture()
        bytes[8] = 2
        Self.rehash(&bytes)
        #expect(throws: RoadPackError.unsupportedVersion(2)) { try Self.open(bytes) }
        bytes[8] = 0
        #expect(throws: RoadPackError.unsupportedVersion(0)) { try Self.open(bytes) }
    }

    @Test("Hash mismatch: one flipped byte anywhere outside the hash field, or a wrong stored hash")
    func hashMismatch() throws {
        let original = try Self.fixture()
        for offset in [60, try Self.entry(original, "META") + 30, original.count / 2, original.count - 9] {
            var bytes = original
            bytes[offset] ^= 0x01
            do {
                try Self.open(bytes)
                Issue.record("flipped byte at \(offset) opened")
            } catch let error as RoadPackError {
                // A flip may first trip a structure check; the content
                // hash must catch any that do not.
                if case .hashMismatch = error {} else if offset >= RoadPackFormat.headerSize + 24 * 11 {
                    Issue.record("byte \(offset): expected hashMismatch, got \(error)")
                }
            }
            // Opening without verify still succeeds when only data changed.
            if offset == original.count / 2 { _ = try RoadPack(data: Data(bytes), verify: false) }
        }
        var bytes = original
        bytes[16] ^= 0xFF
        #expect(throws: RoadPackError.hashMismatch(stored: Self.get64(bytes, 16), computed: Self.get64(original, 16))) { try Self.open(bytes) }
    }

    @Test("Section out of range: length past the end, offset inside the header")
    func sectionOutOfRange() throws {
        var bytes = try Self.fixture()
        let cels = try Self.entry(bytes, "CELS")
        Self.set64(&bytes, cels + 16, UInt64(bytes.count))
        Self.rehash(&bytes)
        #expect(throws: RoadPackError.sectionOutOfRange("CELS")) { try Self.open(bytes) }

        bytes = try Self.fixture()
        let meta = try Self.entry(bytes, "META")
        Self.set64(&bytes, meta + 8, 8)
        Self.rehash(&bytes)
        #expect(throws: RoadPackError.sectionOutOfRange("META")) { try Self.open(bytes) }
    }

    @Test("Overlapping sections are refused")
    func overlappingSections() throws {
        var bytes = try Self.fixture()
        let node = try Self.entry(bytes, "NODE")
        let edge = try Self.entry(bytes, "EDGE")
        Self.set64(&bytes, edge + 8, Self.get64(bytes, node + 8) + 8)
        Self.rehash(&bytes)
        #expect(throws: RoadPackError.sectionsOverlap("NODE", "EDGE")) { try Self.open(bytes) }
    }

    @Test("A zero-length segment is refused by verify()")
    func zeroLengthSegment() throws {
        var bytes = try Self.fixture()
        let pack = try RoadPack(data: Data(bytes))
        // An edge with an interior point, so its end nodes stay intact.
        let e = try #require((0..<pack.edgeCount).first { pack.edge($0).pointCount >= 3 })
        let first = Int(pack.edge(e).firstPoint)
        let pnts = Int(Self.get64(bytes, try Self.entry(bytes, "PNTS") + 8))
        for i in 0..<8 { bytes[pnts + 8 * (first + 1) + i] = bytes[pnts + 8 * first + i] }
        Self.rehash(&bytes)
        _ = try RoadPack(data: Data(bytes), verify: false)  // structure is fine
        #expect(throws: RoadPackError.invalid("EDGE", "edge \(e): zero-length segment at point \(first)")) { try Self.open(bytes) }
    }

    @Test("Unsorted CELK is refused by verify()")
    func unsortedCellKeys() throws {
        var bytes = try Self.fixture()
        let celk = try Self.entry(bytes, "CELK")
        let base = Int(Self.get64(bytes, celk + 8))
        let first = Self.get64(bytes, base), second = Self.get64(bytes, base + 8)
        Self.set64(&bytes, base, second)
        Self.set64(&bytes, base + 8, first)
        Self.rehash(&bytes)
        _ = try RoadPack(data: Data(bytes), verify: false)  // structure is fine
        #expect(throws: RoadPackError.unsorted("CELK")) { try Self.open(bytes) }
    }

    @Test("Record counts must match section lengths; required sections must be present")
    func recordCounts() throws {
        var bytes = try Self.fixture()
        let pted = try Self.entry(bytes, "PTED")
        Self.set64(&bytes, pted + 16, Self.get64(bytes, pted + 16) - 4)
        Self.rehash(&bytes)
        #expect(throws: RoadPackError.recordCountMismatch("PTED")) { try Self.open(bytes) }

        bytes = try Self.fixture()
        let edge = try Self.entry(bytes, "EDGE")
        bytes.replaceSubrange(edge..<(edge + 4), with: Array("EDGX".utf8))
        Self.rehash(&bytes)
        #expect(throws: RoadPackError.missingSection("EDGE")) { try Self.open(bytes) }
    }

    @Test("Unknown sections are skipped: a renamed COVR (flag cleared) opens without coverage")
    func unknownSectionSkipped() throws {
        var bytes = try Self.fixture()
        let covr = try Self.entry(bytes, "COVR")
        bytes.replaceSubrange(covr..<(covr + 4), with: Array("XTRA".utf8))
        bytes[12] = 0
        Self.rehash(&bytes)
        let pack = try RoadPack(data: Data(bytes))
        #expect(!pack.hasCoverage)
        #expect(pack.sections.map(\.name).contains("XTRA"))
        bytes[12] = 1
        Self.rehash(&bytes)
        #expect(throws: RoadPackError.missingSection("COVR")) { try Self.open(bytes) }
    }

    @Test("verify() catches an out-of-range index in CELS and a non-incident edge in ADJE")
    func indexRanges() throws {
        var bytes = try Self.fixture()
        let cels = try Self.entry(bytes, "CELS")
        let base = Int(Self.get64(bytes, cels + 8))
        for i in 0..<4 { bytes[base + i] = 0xFF }
        Self.rehash(&bytes)
        do {
            try Self.open(bytes)
            Issue.record("bad CELS entry accepted")
        } catch let error as RoadPackError {
            switch error {
            case .invalid("CELS", _), .unsorted("CELS"): break
            default: Issue.record("expected a CELS error, got \(error)")
            }
        }

        bytes = try Self.fixture()
        let adje = try Self.entry(bytes, "ADJE")
        let adjeBase = Int(Self.get64(bytes, adje + 8))
        bytes[adjeBase] = bytes[adjeBase] == 0 ? 3 : 0
        Self.rehash(&bytes)
        do {
            try Self.open(bytes)
            Issue.record("bad ADJE entry accepted")
        } catch let error as RoadPackError {
            switch error {
            case .invalid("ADJE", _), .unsorted("ADJE"): break
            default: Issue.record("expected an ADJE error, got \(error)")
            }
        }
    }
}
