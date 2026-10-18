import CryptoKit
import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// The road pack downloader against a URLProtocol stub (UX-8, prompt 25): no
// live network. Synthetic names only (`region-a`, `national`), bytes from a
// tiny valid pack written with Core's writer.

/// Serves one pack path; records every request. Each test has its own path,
/// so tests run in parallel. The registry keeps a stub for the whole run (a
/// test that does not read `requests` must not lose it).
final class PackStub: @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// Send the body and never finish (until the request is cancelled).
        var hold = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: PackStub] = [:]

    let path = "/" + UUID().uuidString + "/pack.roadpack"
    var url: URL { URL(string: "https://stub.invalid\(path)")! }
    private let state = NSLock()
    private var _requests: [URLRequest] = []
    private var _served: Int64 = 0
    private let handler: @Sendable (URLRequest, Int) -> Reply

    init(_ handler: @escaping @Sendable (URLRequest, Int) -> Reply) {
        self.handler = handler
        Self.lock.withLock { Self.stubs[path] = self }
    }

    var requests: [URLRequest] { state.withLock { _requests } }
    var bytesServed: Int64 { state.withLock { _served } }

    fileprivate static func stub(for request: URLRequest) -> PackStub? {
        guard let path = request.url?.path else { return nil }
        return lock.withLock { stubs[path] }
    }

    fileprivate func reply(to request: URLRequest) -> Reply {
        let attempt = state.withLock { () -> Int in
            _requests.append(request)
            return _requests.count - 1
        }
        let reply = handler(request, attempt)
        state.withLock { _served += Int64(reply.body.count) }
        return reply
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PackStubProtocol.self]
        return configuration
    }
}

final class PackStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = PackStub.stub(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let reply = stub.reply(to: request)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let half = reply.body.count / 2
        if half > 0 { client?.urlProtocol(self, didLoad: Data(reply.body.prefix(half))) }
        // A short pause between chunks keeps a held request observable.
        if reply.hold { return }
        client?.urlProtocol(self, didLoad: Data(reply.body.dropFirst(half)))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct DownloadEnv {
    let dirs: StoreFixture.Dirs
    let store: RoadPackStore
    let library: RoadPackLibrary
    let data: Data
    let hash: String
    let sha256: String

    init() throws {
        dirs = try StoreFixture.Dirs()
        store = RoadPackStore(directory: dirs.store)
        library = RoadPackLibrary(store: store, inbox: nil, cacheURL: nil)
        data = try Self.bigPack()
        hash = try StoreFixture.contentHash(data)
        sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A valid pack of a few hundred KB: URLSession hands a small body to its
    /// delegate only at the end, and the pause and cancel tests need bytes
    /// to arrive while the request is still open.
    static func bigPack() throws -> Data {
        let grid = RoadGrid(southWest: RoadPoint(latE7: -100_000, lonE7: -100_000),
                            northEast: RoadPoint(latE7: 100_000, lonE7: 100_000), cellSizeM: 64,
                            searchRadiusM: RoadGrid.defaultSearchRadiusM)
        let edges = (0..<4000).map { i -> RoadGraph.Edge in
            let lat = Int32(i % 2000) * 40 - 40_000, lon = Int32(i / 2000) * 400 - 20_000
            return RoadGraph.Edge(
                fromNode: Int64(2 * i), toNode: Int64(2 * i + 1),
                points: [RoadPoint(latE7: lat, lonE7: lon), RoadPoint(latE7: lat + 10, lonE7: lon + 20),
                         RoadPoint(latE7: lat + 20, lonE7: lon + 40)],
                osmWayID: Int64(i + 10), wayPointOffset: 0, highwayClass: .residential)
        }
        return try RoadPackWriter(grid: grid, osmTimestamp: 1_700_000_000).write(RoadGraph(edges: edges))
    }

    func pack(_ stub: PackStub, name: String = "region-a", sha256 shaOverride: String? = nil) -> PackManifest.Pack {
        PackManifest.Pack(
            name: name, kind: .region, titleUK: "Region A", titleEN: "Region A",
            bbox: .init(west: 0, south: 0, east: 1, north: 1), url: stub.url, size: Int64(data.count),
            sha256: shaOverride ?? sha256, contentHash: hash, formatVersion: 1,
            osmDate: nil, osmTimestamp: 1_700_000_000)
    }

    func downloader(connection: PackDownloadRules.Connection = .unmetered, cellular: Bool = false,
                    runActive: @escaping @Sendable () async -> Bool = { false }) -> PackDownloader {
        PackDownloader(directory: dirs.store, library: library, connection: connection, cellularAllowed: cellular,
                       makeConfiguration: PackStub.configuration, runActive: runActive)
    }

    /// `ok` replies with the whole file.
    func full(etag: String? = "\"e1\"") -> PackStub.Reply {
        var headers = ["Content-Length": String(data.count)]
        if let etag { headers["ETag"] = etag }
        return .init(status: 200, headers: headers, body: data)
    }

    func partial(from offset: Int, etag: String? = "\"e1\"") -> PackStub.Reply {
        var headers = ["Content-Range": "bytes \(offset)-\(data.count - 1)/\(data.count)"]
        if let etag { headers["ETag"] = etag }
        return .init(status: 206, headers: headers, body: Data(data.suffix(from: offset)))
    }

    func storeEntries() -> [String] { StoreFixture.entries(dirs.store) }
    var installedFiles: [String] { storeEntries().filter { $0.hasSuffix(".roadpack") } }
    var downloadFiles: [String] { storeEntries().filter { $0.hasPrefix(".download-") } }

    func seedPartial(_ pack: PackManifest.Pack, bytes: Int, etag: String? = "\"e1\"") throws {
        try RoadPackStore.prepareDirectory(dirs.store)
        let files = try #require(PackPartialFiles(directory: dirs.store, pack: pack))
        try Data(data.prefix(bytes)).write(to: files.partial)
        files.writeMetadata(PackDownloadRules.PartialMetadata(pack: pack, etag: etag))
    }
}

func eventually(timeout: Double = 10, _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@Suite("Pack downloader")
struct PackDownloaderTests {
    @Test("A full download is verified and installed; no partial is left")
    func full() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let stub2 = PackStub { _, _ in env.full() }
        let downloader = env.downloader()
        await downloader.start(env.pack(stub2))
        await downloader.waitUntilIdle()
        #expect(env.installedFiles == [try StoreFixture.storedName("region-a", env.data)])
        #expect(env.downloadFiles.isEmpty)
        #expect(stub2.requests.count == 1)
        #expect(stub2.requests[0].value(forHTTPHeaderField: "Range") == nil)
        #expect(await downloader.snapshot().states.isEmpty)
        #expect(await env.library.status().installedPacks.count == 1)
    }

    @Test("A partial with matching metadata resumes with Range and If-Range; only the remainder is fetched")
    func resume() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let half = env.data.count / 2
        let stub = PackStub { request, _ in
            request.value(forHTTPHeaderField: "Range") == "bytes=\(half)-" ? env.partial(from: half) : .init(status: 400)
        }
        let pack = env.pack(stub)
        try env.seedPartial(pack, bytes: half)
        let downloader = env.downloader()
        await downloader.start(pack)
        await downloader.waitUntilIdle()
        #expect(stub.requests.count == 1)
        #expect(stub.requests[0].value(forHTTPHeaderField: "Range") == "bytes=\(half)-")
        #expect(stub.requests[0].value(forHTTPHeaderField: "If-Range") == "\"e1\"")
        #expect(stub.bytesServed == Int64(env.data.count - half))
        #expect(env.installedFiles.count == 1 && env.downloadFiles.isEmpty)
    }

    @Test("Metadata that does not match the manifest discards the partial: a fresh request")
    func metadataMismatch() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let stub = PackStub { _, _ in env.full() }
        let pack = env.pack(stub)
        try env.seedPartial(pack, bytes: 10)
        let files = try #require(PackPartialFiles(directory: env.dirs.store, pack: pack))
        files.writeMetadata(PackDownloadRules.PartialMetadata(
            url: pack.url.absoluteString, etag: "\"e1\"", expectedSize: pack.size + 1, sha256: pack.sha256))
        let downloader = env.downloader()
        await downloader.start(pack)
        await downloader.waitUntilIdle()
        #expect(stub.requests.count == 1)
        #expect(stub.requests[0].value(forHTTPHeaderField: "Range") == nil)
        #expect(env.installedFiles.count == 1)
    }

    @Test("A 200 to a ranged request restarts from zero")
    func ranged200() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let stub = PackStub { _, _ in env.full() }
        let pack = env.pack(stub)
        try env.seedPartial(pack, bytes: env.data.count / 2)
        let downloader = env.downloader()
        await downloader.start(pack)
        await downloader.waitUntilIdle()
        #expect(stub.requests.count == 1)
        #expect(stub.requests[0].value(forHTTPHeaderField: "Range") != nil)
        #expect(env.installedFiles.count == 1 && env.downloadFiles.isEmpty)
    }

    @Test("A 500 to a ranged request restarts once without Range")
    func ranged500() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let stub = PackStub { request, _ in
            request.value(forHTTPHeaderField: "Range") != nil ? .init(status: 500) : env.full()
        }
        let pack = env.pack(stub)
        try env.seedPartial(pack, bytes: env.data.count / 2)
        let downloader = env.downloader()
        await downloader.start(pack)
        await downloader.waitUntilIdle()
        #expect(stub.requests.count == 2)
        #expect(stub.requests[0].value(forHTTPHeaderField: "Range") != nil)
        #expect(stub.requests[1].value(forHTTPHeaderField: "Range") == nil)
        #expect(env.installedFiles.count == 1)
    }

    @Test("A server that is simply down is tried twice, not forever")
    func restartCap() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let stub = PackStub { _, _ in .init(status: 500) }
        let pack = env.pack(stub)
        try env.seedPartial(pack, bytes: env.data.count / 2)
        let downloader = env.downloader()
        await downloader.start(pack)
        await downloader.waitUntilIdle()
        #expect(stub.requests.count == 2)
        guard case .failed? = await downloader.snapshot().states["region-a"] else {
            Issue.record("expected a failed state")
            return
        }
        #expect(env.installedFiles.isEmpty)
    }

    @Test("A complete partial is verified without a request")
    func verifyOnly() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let stub = PackStub { _, _ in .init(status: 500) }
        let pack = env.pack(stub)
        try env.seedPartial(pack, bytes: env.data.count)
        let downloader = env.downloader()
        await downloader.start(pack)
        await downloader.waitUntilIdle()
        #expect(stub.requests.isEmpty)
        #expect(env.installedFiles.count == 1 && env.downloadFiles.isEmpty)
    }

    @Test("A SHA-256 mismatch fails, deletes the partial and installs nothing")
    func shaMismatch() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let stub = PackStub { _, _ in env.full() }
        let pack = env.pack(stub, sha256: String(repeating: "0", count: 64))
        let downloader = env.downloader()
        await downloader.start(pack)
        await downloader.waitUntilIdle()
        #expect(await downloader.snapshot().states["region-a"] == .failed("checksum mismatch"))
        #expect(env.installedFiles.isEmpty && env.downloadFiles.isEmpty)
        #expect(env.storeEntries().filter { RoadPackStoreRules.isTemporaryFileName($0) }.isEmpty)
    }

    @Test("A manifest content hash that differs from the header installs nothing")
    func contentHashMismatch() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let stub = PackStub { _, _ in env.full() }
        var pack = env.pack(stub)
        pack.contentHash = "0123456789abcdef"
        let downloader = env.downloader()
        await downloader.start(pack)
        await downloader.waitUntilIdle()
        guard case .failed(let reason)? = await downloader.snapshot().states["region-a"] else {
            Issue.record("expected a failed state")
            return
        }
        #expect(reason.contains("does not match the manifest"))
        #expect(env.storeEntries().filter { !$0.hasPrefix("RoadPackStoreState") }.isEmpty,
                "no pack, partial or temporary file left: \(env.storeEntries())")
    }

    @Test("Cancel stops the request and deletes the partial and its metadata")
    func cancel() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        var reply = env.full()
        reply.hold = true
        let held = reply
        let stub = PackStub { _, _ in held }
        let pack = env.pack(stub)
        let downloader = env.downloader()
        await downloader.start(pack)
        let started = await eventually {
            if case .downloading(let received, _)? = await downloader.snapshot().states["region-a"] { return received > 0 }
            return false
        }
        #expect(started)
        #expect(!env.downloadFiles.isEmpty)
        await downloader.cancel(name: "region-a")
        await downloader.waitUntilIdle()
        #expect(env.downloadFiles.isEmpty && env.installedFiles.isEmpty)
        #expect(await downloader.snapshot().states["region-a"] == nil)
    }

    @Test("Record pauses a running download (partial kept) and it resumes afterwards")
    func recordPauses() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let first: PackStub.Reply = {
            var r = env.full()
            r.hold = true
            return r
        }()
        let stub = PackStub { request, attempt in
            if attempt == 0 { return first }
            let offset = Int(request.value(forHTTPHeaderField: "Range")?.dropFirst(6).dropLast() ?? "") ?? 0
            return env.partial(from: offset)
        }
        let pack = env.pack(stub)
        let downloader = env.downloader()
        await downloader.start(pack)
        #expect(await eventually {
            if case .downloading(let received, _)? = await downloader.snapshot().states["region-a"] { return received > 0 }
            return false
        })
        await downloader.setRecordActive(true)
        #expect(await eventually { await downloader.snapshot().states["region-a"] == .pausedForRecording })
        #expect(env.downloadFiles.count == 2, "the partial and its metadata are kept")
        #expect(env.installedFiles.isEmpty)
        let requestsWhilePaused = stub.requests.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.count == requestsWhilePaused)
        await downloader.setRecordActive(false)
        await downloader.waitUntilIdle()
        #expect(env.installedFiles.count == 1 && env.downloadFiles.isEmpty)
        #expect(stub.requests.last?.value(forHTTPHeaderField: "Range") != nil)
    }

    @Test("While Record is active nothing is requested or hashed")
    func recordActiveBeforeStart() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let stub = PackStub { _, _ in env.full() }
        let pack = env.pack(stub)
        try env.seedPartial(pack, bytes: env.data.count)
        let downloader = env.downloader()
        await downloader.setRecordActive(true)
        await downloader.start(pack)
        #expect(await downloader.snapshot().states["region-a"] == .pausedForRecording)
        try await Task.sleep(for: .milliseconds(100))
        #expect(env.installedFiles.isEmpty, "no hashing or install while Record runs")
        await downloader.setRecordActive(false)
        await downloader.waitUntilIdle()
        #expect(env.installedFiles.count == 1)
    }

    @Test("Cellular without permission waits for Wi-Fi and makes no request; allowing it starts the download")
    func cellularPolicy() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let stub = PackStub { _, _ in env.full() }
        let pack = env.pack(stub)
        let downloader = env.downloader(connection: .cellularOrExpensive, cellular: false)
        await downloader.start(pack)
        #expect(await downloader.snapshot().states["region-a"] == .waitingForWiFi)
        try await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.isEmpty)
        await downloader.setCellularAllowed(true)
        await downloader.waitUntilIdle()
        #expect(env.installedFiles.count == 1)
    }

    @Test("No network: offline; the queue resumes when a path appears")
    func offline() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let stub = PackStub { _, _ in env.full() }
        let pack = env.pack(stub)
        let downloader = env.downloader(connection: .none)
        await downloader.start(pack)
        #expect(await downloader.snapshot().states["region-a"] == .offline)
        #expect(stub.requests.isEmpty)
        await downloader.setConnection(.unmetered)
        await downloader.waitUntilIdle()
        #expect(env.installedFiles.count == 1)
    }

    @Test("One at a time: the second pack is queued until the first finishes")
    func queue() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        var heldReply = env.full()
        heldReply.hold = true
        let held = heldReply
        let first = PackStub { _, _ in held }
        let second = PackStub { _, _ in env.full() }
        let downloader = env.downloader()
        await downloader.start(env.pack(first, name: "region-a"))
        await downloader.start(env.pack(second, name: "region-b"))
        let snapshot = await downloader.snapshot()
        #expect(snapshot.states["region-b"] == .queued)
        #expect(second.requests.isEmpty)
        await downloader.cancel(name: "region-a")
        await downloader.waitUntilIdle()
        #expect(second.requests.count == 1)
        #expect(env.installedFiles.count == 1)
    }

    @Test("An update installed while a run is active is marked for the next start")
    func updateNextStart() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let stub = PackStub { _, _ in env.full() }
        let pack = env.pack(stub)
        let downloader = env.downloader(runActive: { true })
        await downloader.start(pack, isUpdate: true)
        await downloader.waitUntilIdle()
        #expect(await downloader.snapshot().updatedForNextStart == ["region-a"])
    }
}

@Suite("Installer expected content hash")
struct InstallerExpectedHashTests {
    @Test("A wrong expected hash refuses before the rename and leaves nothing; the right one installs")
    func expected() throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        let data = try RoadPackFixture.data()
        let source = try RoadPackFixture.write(data, named: "a.roadpack", in: dirs.sources)
        let installer = RoadPackStore(directory: dirs.store).installer
        let refused = installer.install(from: source, name: "region-a", expectedContentHash: "0123456789abcdef")
        #expect(refused.refusal?.contains("does not match the manifest") == true)
        #expect(StoreFixture.entries(dirs.store).filter { $0.hasPrefix(".install-") || $0.hasSuffix(".roadpack") }.isEmpty)
        let hash = try StoreFixture.contentHash(data)
        let installed = installer.install(from: source, name: "region-a", expectedContentHash: hash)
        #expect(installed.installed != nil)
        // The same pack again counts as success; with a wrong hash it is refused and the file stays.
        if case .alreadyInstalled = installer.install(from: source, name: "region-a", expectedContentHash: hash) {} else {
            Issue.record("expected alreadyInstalled")
        }
        #expect(installer.install(from: source, name: "region-a", expectedContentHash: "0123456789abcdef").refusal != nil)
        #expect(StoreFixture.entries(dirs.store).filter { $0.hasSuffix(".roadpack") }.count == 1)
        // Without an expectation (the inbox path) anything valid installs.
        #expect(installer.install(from: source, name: "region-b").installed != nil)
    }
}

@Suite("Pack manifest service")
struct PackManifestServiceTests {
    static func manifestJSON(names: [(String, String)]) -> Data {
        let packs: [[String: Any]] = names.map { name, hash in
            ["name": name, "kind": name == "national" ? "national" : "region",
             "title": ["uk": name, "en": name], "bbox": [0, 0, 1, 1],
             "url": "/packs/v1/\(name)-\(hash).roadpack", "size": 1000,
             "sha256": String(repeating: "a", count: 64), "contentHash": hash, "formatVersion": 1,
             "osmTimestamp": 1_760_000_000]
        }
        let root: [String: Any] = ["schema": 2, "generated": "2026-01-01T00:00:00Z", "license": "ODbL",
                                   "licenseUrl": "https://example.invalid/odbl", "attribution": "© OSM", "packs": packs]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
    }

    @Test("The cache round-trips and survives a failed refresh (offline note, list kept)")
    func cacheAndOffline() async throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        let json = Self.manifestJSON(names: [("national", "0f0e0d0c0b0a0908"), ("region-a", "a1b2c3d4e5f60718")])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = PackManifestService(cacheDirectory: dirs.root, storeDirectory: nil, fetch: { _ in json }, now: { now })
        await first.refresh(force: false)
        let fresh = await first.snapshot()
        #expect(fresh.manifest?.packs.map(\.name) == ["national", "region-a"])
        #expect(fresh.refresh == .ok && fresh.fetchedAt == now)

        let fetches = Counter()
        let second = PackManifestService(cacheDirectory: dirs.root, storeDirectory: nil, fetch: { _ in
            _ = fetches.next()
            throw URLError(.notConnectedToInternet)
        }, now: { now.addingTimeInterval(60) })
        await second.loadCache()
        let loaded = await second.snapshot()
        #expect(loaded.manifest == fresh.manifest && loaded.fetchedAt == now && loaded.refresh == .idle)
        await second.refresh(force: false)
        #expect(fetches.count == 0, "a 1-minute-old list is current")
        await second.refresh(force: true)
        let failed = await second.snapshot()
        #expect(fetches.count == 1)
        #expect(failed.refresh == .failed(offline: true))
        #expect(failed.manifest == fresh.manifest, "the cached list stays")
        #expect(MapsText.listNote(failed.refresh, hasManifest: true) == "Offline. Showing the saved list.")

        let stale = PackManifestService(cacheDirectory: dirs.root, storeDirectory: nil, fetch: { _ in
            _ = fetches.next()
            return json
        }, now: { now.addingTimeInterval(25 * 3600) })
        await stale.loadCache()
        await stale.refresh(force: false)
        #expect(fetches.count == 2, "a 25-hour-old list is refreshed")
    }

    @Test("A response that is not a manifest keeps the cached list and says the update failed")
    func badResponse() async throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        let json = Self.manifestJSON(names: [("national", "0f0e0d0c0b0a0908")])
        let good = PackManifestService(cacheDirectory: dirs.root, storeDirectory: nil, fetch: { _ in json })
        await good.refresh(force: true)
        let bad = PackManifestService(cacheDirectory: dirs.root, storeDirectory: nil, fetch: { _ in Data("nope".utf8) })
        await bad.loadCache()
        await bad.refresh(force: true)
        let snapshot = await bad.snapshot()
        #expect(snapshot.refresh == .failed(offline: false) && snapshot.manifest != nil)
        #expect(MapsText.listNote(snapshot.refresh, hasManifest: true) == "Couldn't update the list. Showing the saved list.")
        #expect(MapsText.listNote(.ok, hasManifest: true) == nil)
        #expect(MapsText.listNote(.idle, hasManifest: false) == nil)
        #expect(MapsText.listNote(.failed(offline: true), hasManifest: false) == "Offline.")
    }

    @Test("Applying a fresh manifest deletes stale partials and metadata, never a .roadpack")
    func stalePartials() async throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        try FileManager.default.createDirectory(at: dirs.store, withIntermediateDirectories: true)
        let listed = "a1b2c3d4e5f60718", old = "1111111111111111"
        let files = [
            ".download-region-a-\(listed).part", ".download-region-a-\(listed).json",
            ".download-region-a-\(old).part", ".download-region-a-\(old).json",
            ".download-gone-\(listed).part", "gone-\(old).roadpack", "region-a-\(old).roadpack",
        ]
        for file in files { try Data("x".utf8).write(to: dirs.store.appendingPathComponent(file)) }
        let json = Self.manifestJSON(names: [("region-a", listed)])
        let service = PackManifestService(cacheDirectory: dirs.root, storeDirectory: dirs.store, fetch: { _ in json })
        await service.loadCache()
        #expect(StoreFixture.entries(dirs.store).count == files.count, "loading the cache deletes nothing")
        await service.refresh(force: true)
        #expect(Set(StoreFixture.entries(dirs.store)) == [
            ".download-region-a-\(listed).part", ".download-region-a-\(listed).json",
            "gone-\(old).roadpack", "region-a-\(old).roadpack",
        ])
    }
}

@Suite("Pack network and Record signal")
struct PackNetworkTests {
    @Test("Path to connection: none, unmetered, cellular/expensive/constrained")
    func connection() {
        #expect(PackNetwork.connection(satisfied: false, expensive: false, constrained: false, cellular: false) == .none)
        #expect(PackNetwork.connection(satisfied: true, expensive: false, constrained: false, cellular: false) == .unmetered)
        #expect(PackNetwork.connection(satisfied: true, expensive: true, constrained: false, cellular: false) == .cellularOrExpensive)
        #expect(PackNetwork.connection(satisfied: true, expensive: false, constrained: true, cellular: false) == .cellularOrExpensive)
        #expect(PackNetwork.connection(satisfied: true, expensive: false, constrained: false, cellular: true) == .cellularOrExpensive)
        #expect(PackNetwork.connection(satisfied: false, expensive: true, constrained: true, cellular: true) == .none)
    }

    @Test("Calibrating, recording and stopping are Record-active; idle and failed are not")
    func recordActive() {
        #expect(RecordActiveObserver.isActive(.calibrating))
        #expect(RecordActiveObserver.isActive(.recording))
        #expect(RecordActiveObserver.isActive(.stopping))
        #expect(!RecordActiveObserver.isActive(.idle))
        #expect(!RecordActiveObserver.isActive(.failed(reason: "x", unwrittenEvents: 0)))
    }
}
