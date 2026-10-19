import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// R66.1-7 (a fresh manifest never deletes the partial of a running job;
// queued jobs take the new entry) and R66.1-8 (path changes reach the
// downloader in order). URLProtocol stub only; synthetic names.

@Suite("Fresh manifest and running downloads (R66.1-7)")
struct PackManifestRunningJobTests {
    /// A manifest listing `region-a` with `contentHash` (another hash than
    /// the running pack's: an update published mid-download).
    static func manifestJSON(region contentHash: String) -> Data {
        PackManifestServiceTests.manifestJSON(names: [("national", "0f0e0d0c0b0a0908"), ("region-a", contentHash)])
    }

    @Test("A fresh manifest that changes the running pack's hash keeps its partial; other stale partials go")
    func runningPartialKept() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        var heldReply = env.full()
        heldReply.hold = true
        let held = heldReply
        let stub = PackStub { _, _ in held }
        let pack = env.pack(stub)
        let files = try #require(PackPartialFiles(directory: env.dirs.store, pack: pack))
        let downloader = env.downloader()
        try RoadPackStore.prepareDirectory(env.dirs.store)
        let gone = env.dirs.store.appendingPathComponent(".download-gone-1111111111111111.part")
        try Data("x".utf8).write(to: gone)

        await downloader.start(pack)
        // Bytes are on disk through an open handle.
        #expect(await eventually {
            if case .downloading(let received, _)? = await downloader.snapshot().states["region-a"] { return received > 0 }
            return false
        })
        let service = PackManifestService(cacheDirectory: env.dirs.root, storeDirectory: env.dirs.store,
                                          downloader: downloader,
                                          fetch: { _ in Self.manifestJSON(region: "2222222222222222") })
        await service.refresh(force: true)
        #expect(await service.snapshot().refresh == .ok)
        #expect(FileManager.default.fileExists(atPath: files.partial.path), "the running job's partial survives")
        #expect(FileManager.default.fileExists(atPath: files.metadata.path))
        #expect((files.partialBytes() ?? 0) > 0)
        #expect(!FileManager.default.fileExists(atPath: gone.path), "an unrelated stale partial is still deleted")
        #expect(await downloader.activeNames() == ["region-a"])
        await downloader.cancel(name: "region-a")
        await downloader.waitUntilIdle()
    }

    @Test("A queued job takes the fresh manifest's entry: its old partial is deleted and the new version downloads")
    func queuedTakesNewEntry() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let oldStub = PackStub { _, _ in .init(status: 404) }
        let newStub = PackStub { _, _ in env.full() }
        var old = env.pack(oldStub)
        old.contentHash = "1111111111111111"
        let fresh = env.pack(newStub)
        try env.seedPartial(old, bytes: 10)
        let oldFiles = try #require(PackPartialFiles(directory: env.dirs.store, pack: old))
        let downloader = env.downloader(connection: .none)
        await downloader.start(old)
        #expect(await downloader.snapshot().states["region-a"] == .offline)

        let manifest = PackManifest(manifestURL: PackManifestService.manifestURL, generated: "2026-01-01T00:00:00Z",
                                    license: "ODbL", licenseURL: "https://example.invalid/odbl", attribution: "© OSM",
                                    packs: [fresh])
        await downloader.manifestApplied(manifest)
        #expect(!FileManager.default.fileExists(atPath: oldFiles.partial.path), "the outdated partial is gone")
        #expect(await downloader.activeNames() == ["region-a"], "still queued")
        await downloader.setConnection(.unmetered)
        await downloader.waitUntilIdle()
        #expect(oldStub.requests.isEmpty)
        #expect(newStub.requests.count == 1)
        #expect(env.installedFiles == [try StoreFixture.storedName("region-a", env.data)])
    }
}

/// Collects what an `OrderedRelay` delivers.
private actor ConnectionSink {
    private(set) var values: [PackDownloadRules.Connection] = []
    func add(_ value: PackDownloadRules.Connection) async {
        if values.count % 7 == 0 { await Task.yield() }
        values.append(value)
    }
}

@Suite("Path changes in order (R66.1-8)")
struct PackPathRelayTests {
    static let burst: [PackDownloadRules.Connection] = (0..<300).map {
        [.cellularOrExpensive, .unmetered, .none][$0 % 3]
    }

    @Test("The relay delivers every path change in the order sent")
    func order() async {
        let sink = ConnectionSink()
        let relay = OrderedRelay<PackDownloadRules.Connection> { await sink.add($0) }
        for value in Self.burst { relay.send(value) }
        #expect(await eventually { await sink.values.count == Self.burst.count })
        #expect(await sink.values == Self.burst)
    }

    @Test("A burst ending on Wi-Fi leaves the downloader on Wi-Fi, and a queued pack starts")
    func endsOnLatest() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let stub = PackStub { _, _ in env.full() }
        let downloader = env.downloader(connection: .none)
        let relay = AppServices.pathRelay(to: downloader)
        await downloader.start(env.pack(stub))
        for value in Self.burst { relay.send(value) }
        relay.send(.unmetered)
        #expect(await eventually { await downloader.snapshot().connection == .unmetered && env.installedFiles.count == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(await downloader.snapshot().connection == .unmetered)

        for value in Self.burst { relay.send(value) }
        relay.send(.none)
        #expect(await eventually { await downloader.snapshot().connection == .none })
        try await Task.sleep(for: .milliseconds(200))
        #expect(await downloader.snapshot().connection == .none, "no older value lands after the latest")
    }
}
