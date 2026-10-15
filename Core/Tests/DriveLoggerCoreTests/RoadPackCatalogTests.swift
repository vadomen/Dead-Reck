import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// N3.3 item 3: the pack catalog (verification cache keyed by file identity)
/// and pack selection by coverage. Synthetic packs near (0, 0), written to a
/// temporary directory; no real pack is involved.
@Suite("Road pack catalog and selection (N3.3)")
struct RoadPackCatalogTests {
    typealias N = RoadFixture.Node

    static func street(_ id: Int64, _ a: (Double, Double), _ b: (Double, Double)) -> String {
        RoadFixture.way(id, ["highway": "residential"], [N(id: id * 10, east: a.0, north: a.1),
                                                         N(id: id * 10 + 1, east: b.0, north: b.1)])
    }

    /// A square coverage ring, metres from (0, 0).
    static func square(_ west: Double, _ south: Double, _ east: Double, _ north: Double) -> [[RoadPoint]] {
        [[RoadFixture.point(west, south), RoadFixture.point(east, south),
          RoadFixture.point(east, north), RoadFixture.point(west, north)]]
    }

    /// A: around (0, 0), coverage ±2 km. B: around (8 km, 0), coverage
    /// 6–10 km east. C: no COVR, one road from (0, 5 km) to (0, 6 km).
    /// D: around (0, 0) on another grid.
    static func packA() throws -> Data {
        try RoadFixture.buildData([street(1, (-500, 0), (500, 0))], coverage: square(-2000, -2000, 2000, 2000))
    }
    static func packB() throws -> Data {
        try RoadFixture.buildData([street(2, (7500, 0), (8500, 0))], coverage: square(6000, -2000, 10_000, 2000))
    }
    static func packC() throws -> Data {
        try RoadFixture.buildData([street(3, (0, 5000), (0, 6000))])
    }
    static func packD() throws -> Data {
        try RoadFixture.buildData([street(4, (-500, 10), (500, 10))], grid: RoadFixture.grid(cellSizeM: 128),
                                  coverage: square(-2000, -2000, 2000, 2000))
    }

    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Writes `data` as `name` with modification date `date`.
    @discardableResult
    static func write(_ data: Data, _ name: String, in scratch: ScratchDirectory, date: Date = t0) throws -> URL {
        let url = scratch.file(name)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    static func candidates(_ named: [(String, Data)]) throws -> [RoadPackSelection.Candidate] {
        try named.map { try RoadPackSelection.Candidate(name: $0.0, pack: RoadPack(data: $0.1)) }
    }

    /// The circle centred `east`, `north` metres from (0, 0).
    static func select(_ candidates: [RoadPackSelection.Candidate], _ east: Double, _ north: Double,
                       _ radius: Double) -> RoadPackSelection.Outcome {
        let p = SyntheticDrive.plane.geodetic(east: east, north: north)
        return RoadPackSelection.select(candidates, latitude: p.latitude, longitude: p.longitude, radiusM: radius)
    }

    static func names(_ outcome: RoadPackSelection.Outcome) -> [String]? {
        if case .selected(_, let names) = outcome { return names }
        return nil
    }

    // MARK: Selection

    @Test("Selection by coverage: covering, not covering, two packs, a far circle reaching one pack, bounding box without COVR")
    func selectionByCoverage() throws {
        let all = try Self.candidates([("A", Self.packA()), ("B", Self.packB()), ("C", Self.packC())])
        #expect(all[0].coverage.rings != nil && all[2].coverage.rings == nil && all[2].coverage.bounds != nil)
        #expect(Self.names(Self.select(all, 0, 0, 100)) == ["A"])
        #expect(Self.names(Self.select(all, 1900, 1900, 0)) == ["A"], "inside, radius 0")
        guard case .noneCovering = Self.select(all, 0, -50_000, 1000) else { Issue.record("far away"); return }
        guard case .noneCovering = Self.select(all, 4000, 0, 1500) else { Issue.record("between, 2 km from each"); return }
        #expect(Self.names(Self.select(all, 4000, 0, 2500)) == ["A", "B"])
        // 3 km from B's coverage, 11 km from A's.
        #expect(Self.names(Self.select(all, 13_000, 0, 3500)) == ["B"])
        // C by its bounding box (a line at x = 0, 5–6 km north).
        guard case .noneCovering = Self.select(all, 100, 5500, 50) else { Issue.record("100 m from C's box"); return }
        #expect(Self.names(Self.select(all, 100, 5500, 150)) == ["C"])
        let both = try #require(Self.select(all, 4000, 0, 2500).network)
        #expect(both.packs.count == 2)
    }

    @Test("An unusable request (non-finite or missing centre or radius) selects nothing and does not crash")
    func unusableRequest() throws {
        let all = try Self.candidates([("A", Self.packA())])
        for (lat, lon, r) in [(Double.nan, 0.0, 10.0), (0, .infinity, 10), (0, 0, .nan), (0, 0, -1), (95, 0, 10)] as [(Double, Double, Double)] {
            guard case .unusableRequest = RoadPackSelection.select(all, latitude: lat, longitude: lon, radiusM: r) else {
                Issue.record("\(lat) \(lon) \(r)")
                continue
            }
        }
        for (lat, lon, r) in [(nil, 0.0, 10.0), (0, nil, 10), (0, 0, nil)] as [(Double?, Double?, Double?)] {
            guard case .unusableRequest = RoadPackSelection.select(all, latitude: lat, longitude: lon, radiusM: r) else {
                Issue.record("missing")
                continue
            }
        }
        var selector = RoadPackSelector(candidates: all)
        let bad = RoadSelectionRequest(latitude: .nan, longitude: 0, radiusM: 10, afterInputs: 1, t: .zero)
        #expect(selector.network(for: bad) == nil)
        let good = RoadSelectionRequest(latitude: 0, longitude: 0, radiusM: 10, afterInputs: 2, t: .zero)
        #expect(selector.network(for: good) != nil && selector.requests == 2)
    }

    @Test("Covering packs that cannot be used together (another grid, the same pack twice) are refused with a reason")
    func refusedSets() throws {
        let grids = try Self.candidates([("A", Self.packA()), ("D", Self.packD())])
        guard case .refused(let mismatch) = Self.select(grids, 0, 0, 100) else { Issue.record("grid mismatch"); return }
        #expect(mismatch.names == ["A", "D"] && mismatch.reason.contains("different grids"))
        let twice = try Self.candidates([("A", Self.packA()), ("A copy", Self.packA())])
        guard case .refused(let duplicate) = Self.select(twice, 0, 0, 100) else { Issue.record("duplicate"); return }
        #expect(duplicate.reason.contains("loaded twice"))
        // The selector keeps the refusal and does not build the set again.
        var selector = RoadPackSelector(candidates: grids)
        let request = RoadSelectionRequest(latitude: 0, longitude: 0, radiusM: 100, afterInputs: 1, t: .zero)
        #expect(selector.network(for: request) == nil && selector.network(for: request) == nil)
        guard case .refused(let kept)? = selector.lastOutcome else { Issue.record("no refusal kept"); return }
        #expect(kept == mismatch)
    }

    // MARK: Catalog

    @Test("Catalog: verified packs, a truncated and a corrupt pack refused with their reason; refused packs are never candidates")
    func catalogRefusals() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let a = try Self.packA()
        let good = try Self.write(a, "a.roadpack", in: scratch)
        let truncated = try Self.write(Data(a.dropLast(64)), "truncated.roadpack", in: scratch)
        var flipped = a
        let points = try #require(try RoadPack(data: a).sections.first { $0.name == "PNTS" })
        flipped[points.offset + 3] ^= 0x40
        let corrupt = try Self.write(flipped, "corrupt.roadpack", in: scratch)
        let missing = scratch.file("missing.roadpack")
        let catalog = RoadPackCatalog(urls: [good, truncated, corrupt, missing], cache: RoadPackVerificationCache())
        #expect(catalog.entries.map(\.isUsable) == [true, false, false, false])
        #expect(catalog.entries[0].verification?.contentHash == NavigationSeed.hex(try RoadPack(data: a).contentHash))
        #expect(catalog.entries[0].verification?.bounds != nil && catalog.entries[0].verification?.hasCoverage == true)
        #expect(catalog.entries[0].verification?.gridID == NavigationSeed.hex(RoadFixture.grid().gridID))
        #expect(catalog.entries[1].refusal?.contains("truncated") == true)
        #expect(catalog.entries[2].refusal?.contains("content hash mismatch") == true)
        #expect(catalog.entries[3].fileError != nil && catalog.entries[3].identity == nil)
        #expect(catalog.entries.allSatisfy { !$0.cacheHit })
        // Refusals are cached (the bytes stay bad until the file changes); an unreadable file is not.
        #expect(catalog.cache.entries.map(\.identity.name) == ["a.roadpack", "corrupt.roadpack", "truncated.roadpack"])
        let (candidates, refused) = RoadPackSelection.candidates(from: catalog.entries)
        #expect(candidates.map(\.name) == ["a.roadpack"])
        #expect(refused.map(\.names) == [["truncated.roadpack"], ["corrupt.roadpack"], ["missing.roadpack"]])
        #expect(candidates[0].coverage.rings != nil)
    }

    @Test("Cache hit skips verification; a file re-written (new mtime or size) is verified again; the cache round-trips as JSON")
    func cacheByIdentity() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let a = try Self.packA()
        let url = try Self.write(a, "a.roadpack", in: scratch)
        let first = RoadPackCatalog(urls: [url], cache: RoadPackVerificationCache())
        #expect(first.entries[0].isUsable && !first.entries[0].cacheHit)

        // Persisted and reloaded: the same cache. Garbage loads empty.
        let reloaded = RoadPackVerificationCache(data: first.cache.encoded())
        #expect(reloaded == first.cache && reloaded.encoded() == first.cache.encoded())
        #expect(RoadPackVerificationCache(data: Data("not json".utf8)).entries.isEmpty)

        // The same identity with different bytes (a flipped byte, mtime put
        // back): a hit, so nothing is verified and the stale "verified" stands.
        var flipped = a
        let points = try #require(try RoadPack(data: a).sections.first { $0.name == "PNTS" })
        flipped[points.offset + 3] ^= 0x40
        try Self.write(flipped, "a.roadpack", in: scratch)
        let hit = RoadPackCatalog(urls: [url], cache: reloaded)
        #expect(hit.entries[0].cacheHit && hit.entries[0].isUsable)
        #expect(hit.entries[0].verification == first.entries[0].verification)

        // A new modification date: verified again, and refused.
        try Self.write(flipped, "a.roadpack", in: scratch, date: Self.t0.addingTimeInterval(10))
        let newDate = RoadPackCatalog(urls: [url], cache: hit.cache)
        #expect(!newDate.entries[0].cacheHit && !newDate.entries[0].isUsable)
        #expect(newDate.entries[0].refusal?.contains("content hash mismatch") == true)

        // A new size with the old date: verified again (a different pack).
        let b = try RoadFixture.buildData([Self.street(1, (-500, 0), (500, 0)), Self.street(5, (0, -500), (0, 500))],
                                          coverage: Self.square(-2000, -2000, 2000, 2000))
        #expect(b.count != a.count)
        try Self.write(b, "a.roadpack", in: scratch)
        let newSize = RoadPackCatalog(urls: [url], cache: newDate.cache)
        #expect(!newSize.entries[0].cacheHit && newSize.entries[0].isUsable)
        #expect(newSize.entries[0].verification?.contentHash == NavigationSeed.hex(try RoadPack(data: b).contentHash))
        #expect(newSize.cache.entries.count == 1)
    }

    @Test("Candidates after a cache hit: the file must keep its identity and its header the verified content hash")
    func candidatesCheckIdentityAndHash() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let url = try Self.write(Self.packA(), "a.roadpack", in: scratch)
        let catalog = RoadPackCatalog(urls: [url], cache: RoadPackVerificationCache())
        #expect(RoadPackSelection.candidates(from: catalog.entries).candidates.count == 1)

        var forged = catalog.entries
        forged[0].verification?.contentHash = "0000000000000000"
        let wrongHash = RoadPackSelection.candidates(from: forged)
        #expect(wrongHash.candidates.isEmpty && wrongHash.refused[0].reason.contains("is not the verified"))

        try FileManager.default.setAttributes([.modificationDate: Self.t0.addingTimeInterval(5)], ofItemAtPath: url.path)
        let touched = RoadPackSelection.candidates(from: catalog.entries)
        #expect(touched.candidates.isEmpty && touched.refused[0].reason.contains("changed since it was verified"))
    }
}
