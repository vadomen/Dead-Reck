import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// N3.3 item 5: the road pack library and the live attach in the service.
// Synthetic packs written at test time next to (0, 0); no real pack, no
// real place. What the phone does with a real pack is a device item.

enum RoadPackFixture {
    /// A one-road pack around (0.001, 0.002) degrees. A different
    /// `cellSizeM` gives a different grid, so two such packs cannot be
    /// combined.
    static func data(cellSizeM: Double = 64, osmTimestamp: Int64 = 1_700_000_000) throws -> Data {
        let grid = RoadGrid(southWest: RoadPoint(latE7: -100_000, lonE7: -100_000),
                            northEast: RoadPoint(latE7: 100_000, lonE7: 100_000), cellSizeM: cellSizeM)
        let graph = RoadGraph(edges: [RoadGraph.Edge(
            fromNode: 1, toNode: 2,
            points: [RoadPoint(latE7: 0, lonE7: 0), RoadPoint(latE7: 10_000, lonE7: 20_000),
                     RoadPoint(latE7: 20_000, lonE7: 40_000)],
            osmWayID: 10, wayPointOffset: 0, highwayClass: .residential)])
        return try RoadPackWriter(grid: grid, osmTimestamp: osmTimestamp).write(graph)
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drivelogger-roadpacks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

@Suite("Road pack library", .serialized)
struct RoadPackLibraryTests {
    @Test("A valid pack is verified; a corrupt and a truncated one are refused with a reason and never offered")
    func verifiesAndRefuses() async throws {
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = try RoadPackFixture.data()
        try RoadPackFixture.write(good, named: "good.roadpack", in: dir)
        try RoadPackFixture.write(good.prefix(good.count / 2), named: "truncated.roadpack", in: dir)
        var corrupt = good
        corrupt[corrupt.count - 16] ^= 0xFF
        try RoadPackFixture.write(corrupt, named: "corrupt.roadpack", in: dir)
        try RoadPackFixture.write(Data("x".utf8), named: "ignored.txt", in: dir)

        let library = RoadPackLibrary(source: RoadPackLibrary.directorySource(dir), cacheURL: nil)
        let candidates = await library.candidates()
        #expect(candidates.candidates.map(\.name) == ["good.roadpack"])
        let status = await library.status()
        #expect(status.packs.map(\.name) == ["corrupt.roadpack", "good.roadpack", "truncated.roadpack"])
        let byName = Dictionary(uniqueKeysWithValues: status.packs.map { ($0.name, $0) })
        #expect(byName["good.roadpack"]?.verified == true)
        #expect(byName["good.roadpack"]?.hashPrefix?.count == 8)
        #expect(byName["good.roadpack"]?.osmTimestamp == 1_700_000_000)
        #expect(byName["corrupt.roadpack"]?.verified == false && byName["corrupt.roadpack"]?.refusal != nil)
        #expect(byName["truncated.roadpack"]?.verified == false && byName["truncated.roadpack"]?.refusal != nil)
        #expect(!status.scanning && status.scansCompleted == 1)
    }

    @Test("Relaunch: a second library on the same cache file gets cache hits; a rewritten file is verified again")
    func cacheSurvivesRelaunch() async throws {
        let dir = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("cache.json")
        let packs = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: packs) }
        let url = try RoadPackFixture.write(try RoadPackFixture.data(), named: "a.roadpack", in: packs)

        let first = RoadPackLibrary(source: RoadPackLibrary.directorySource(packs), cacheURL: cache)
        _ = await first.candidates()
        #expect(await first.status().packs.first?.cacheHit == false)
        #expect(await first.verifications == 1)
        #expect(FileManager.default.fileExists(atPath: cache.path))

        let second = RoadPackLibrary(source: RoadPackLibrary.directorySource(packs), cacheURL: cache)
        let again = await second.candidates()
        #expect(again.candidates.count == 1)
        #expect(await second.status().packs.first?.cacheHit == true)
        #expect(await second.verifications == 0)

        // Same bytes, new modification date: the file's identity changed.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: url.path)
        let third = RoadPackLibrary(source: RoadPackLibrary.directorySource(packs), cacheURL: cache)
        _ = await third.candidates()
        #expect(await third.status().packs.first?.cacheHit == false)
        #expect(await third.verifications == 1)
    }

    @Test("A rescan sees a file copied in later")
    func rescanSeesNewFile() async throws {
        let packs = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: packs) }
        let library = RoadPackLibrary(source: RoadPackLibrary.directorySource(packs), cacheURL: nil)
        #expect(await library.candidates().candidates.isEmpty)
        try RoadPackFixture.write(try RoadPackFixture.data(), named: "late.roadpack", in: packs)
        await library.rescan()
        #expect(await library.candidates().candidates.map(\.name) == ["late.roadpack"])
    }
}

@Suite("Roads diagnostics text")
struct RoadsDiagnosticsTextTests {
    @Test("The attribution shows exactly when a pack is in use")
    func attribution() {
        #expect(!RoadsDiagnosticsText.attributionVisible(packsInUse: 0))
        #expect(RoadsDiagnosticsText.attributionVisible(packsInUse: 1))
        #expect(RoadsDiagnosticsText.attributionVisible(packsInUse: 3))
        #expect(RoadsDiagnosticsText.attribution == "© OpenStreetMap contributors")
    }

    @Test("Usage text: none, looking, refused, in use")
    func usage() {
        #expect(RoadsDiagnosticsText.usage(.none) == "none")
        #expect(RoadsDiagnosticsText.usage(.init(selectionPending: true)).hasPrefix("none yet"))
        #expect(RoadsDiagnosticsText.usage(.init(refusal: "grid")) == "none (refused: grid)")
        let used = NavigationService.RoadsStatus(packNames: ["a.roadpack"], activeAtSessionS: 12)
        #expect(RoadsDiagnosticsText.usage(used) == "a.roadpack from 12 s")
    }

    @Test("Memory footprint is readable and formats in MB")
    func footprint() {
        #expect((MemoryFootprint.currentBytes() ?? 0) > 0)
        #expect(MemoryFootprint.format(210_000_000) == "210.0 MB")
        #expect(MemoryFootprint.format(nil) == "--")
    }
}
