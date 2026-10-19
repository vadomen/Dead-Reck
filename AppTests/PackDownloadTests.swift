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
                    runActive: @escaping @Sendable () async -> Bool = { false },
                    hash: @escaping @Sendable (URL) throws -> String? = { try PackDownloader.sha256(of: $0) })
        -> PackDownloader {
        PackDownloader(directory: dirs.store, library: library, connection: connection, cellularAllowed: cellular,
                       makeConfiguration: PackStub.configuration, runActive: runActive, hash: hash)
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

    @Test("Record starting mid-hash: the hash is abandoned promptly, the partial kept; after Record a verify-only pass installs it")
    func recordPausesHashing() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let stub = PackStub { _, _ in .init(status: 500) }
        let pack = env.pack(stub)
        try env.seedPartial(pack, bytes: env.data.count)
        let calls = HashCallCounter()
        // The first hash runs until its task is cancelled (at most 10 s,
        // then it finishes and the test fails on the install below).
        let downloader = env.downloader(hash: { url in
            if calls.next() == 1 {
                let deadline = Date(timeIntervalSinceNow: 10)
                while !Task.isCancelled, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
            }
            return try PackDownloader.sha256(of: url)
        })
        await downloader.start(pack)
        #expect(await eventually { await downloader.snapshot().states["region-a"] == .verifying && calls.value == 1 })
        let paused = ContinuousClock.now
        await downloader.setRecordActive(true)
        #expect(await eventually(timeout: 2) { await downloader.snapshot().states["region-a"] == .pausedForRecording })
        #expect(ContinuousClock.now - paused < .seconds(2), "abandoned promptly")
        #expect(env.downloadFiles.count == 2, "the partial and its metadata are kept: \(env.storeEntries())")
        #expect(env.installedFiles.isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        #expect(calls.value == 1, "no hash starts while Record is active")
        #expect(await downloader.snapshot().states["region-a"] == .pausedForRecording)
        await downloader.setRecordActive(false)
        await downloader.waitUntilIdle()
        #expect(calls.value == 2)
        #expect(stub.requests.isEmpty, "verify-only: the complete partial needs no request")
        #expect(env.installedFiles.count == 1 && env.downloadFiles.isEmpty)
    }

    @Test("Navigate-style activity (runActive) never pauses a download")
    func runActiveDoesNotPause() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        let stub = PackStub { _, _ in env.full() }
        let downloader = env.downloader(runActive: { true })
        await downloader.start(env.pack(stub))
        await downloader.waitUntilIdle()
        #expect(env.installedFiles.count == 1 && stub.requests.count == 1)
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

    @Test("SHA-256 of a cancelled task is nil, not a digest")
    func hashCancelled() async throws {
        let env = try DownloadEnv()
        defer { env.dirs.remove() }
        try FileManager.default.createDirectory(at: env.dirs.store, withIntermediateDirectories: true)
        let file = env.dirs.store.appendingPathComponent("blob")
        try Data(count: 3 << 20).write(to: file)
        let cancelled = await Task.detached { () -> String?? in
            withUnsafeCurrentTask { $0?.cancel() }
            return try? PackDownloader.sha256(of: file)
        }.value
        #expect(cancelled == .some(nil))
        let digest = try PackDownloader.sha256(of: file)
        #expect(digest == SHA256.hash(data: Data(count: 3 << 20)).map { String(format: "%02x", $0) }.joined())
    }

    @Test("Downloads never touch the recordings: the pack store and the manifest cache are outside Documents/logs")
    func separateFromRecordings() {
        let logs = LogStore.defaultDirectory.standardizedFileURL.path + "/"
        let others = [RoadPackStore.defaultDirectory(), RoadPackLibrary.defaultCacheURL().deletingLastPathComponent()]
            .map { $0.standardizedFileURL.path + "/" }
        for other in others {
            #expect(!other.hasPrefix(logs) && !logs.hasPrefix(other), "\(other) vs \(logs)")
        }
    }
}

/// Thread-safe call counter for `@Sendable` test closures.
final class HashCallCounter: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var count = 0   // guarded by `lock`

    /// Increments and returns the new value.
    func next() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}

/// What `RecordingSession.onRecordActiveChange` saw, and the session at that
/// moment.
@MainActor
final class RecordActiveSpy {
    struct Change: Equatable {
        var active: Bool
        var state: RecordingState
        var isStarting: Bool
        var hasFile: Bool
        var storeEntries: Int
        var sourcesRunning: Bool
        /// When `watch` is set at a change to false: the file reads strictly
        /// and has a `stop` or `error` row and a final `stats` row.
        var fileFinished: Bool?
    }

    private(set) var changes: [Change] = []
    var values: [Bool] { changes.map(\.active) }
    /// The recording to check when Record ends.
    var watch: URL?

    init(_ session: RecordingSession, store: LogStore, sources: [FakeSource] = []) {
        session.onRecordActiveChange = { [weak self, weak session] active in
            guard let self, let session else { return }
            #expect(session.isRecordActive == active, "the hook runs after the property changed")
            var finished: Bool?
            if !active, let url = watch {
                finished = (try? RecordingFixtures.read(url)).map { read in
                    let rows = RecordingFixtures.lifecycle(read.events).map(\.sample.event)
                    return read.report.failure == nil && !read.report.truncatedTail && read.report.readError == nil
                        && (rows.contains("stop") || rows.contains("error"))
                        && read.events.last?.payload.kind == LogEventKind.stats.rawValue
                } ?? false
            }
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path).count) ?? 0
            changes.append(Change(active: active, state: session.state, isStarting: session.isStarting,
                                  hasFile: session.currentFile != nil, storeEntries: entries,
                                  sourcesRunning: sources.contains { $0.isRunning }, fileFinished: finished))
        }
    }
}

/// Collects what a `RecordActivityRelay` delivers; notes overlapping calls.
private actor RelaySink {
    private(set) var values: [Bool] = []
    private(set) var overlapped = false
    private var inFlight = 0

    func add(_ value: Bool) async {
        inFlight += 1
        if inFlight > 1 { overlapped = true }
        if values.count % 5 == 0 { await Task.yield() }
        values.append(value)
        inFlight -= 1
    }
}

/// UX-8: Record pauses road-pack downloads. The session's `isRecordActive`
/// and its hook, the relay that carries it to the downloader, and the two
/// together. Navigate never pauses them.
@Suite("Record-active signal (UX-8)", .serialized)
@MainActor
struct RecordActiveSignalTests {
    @Test("Start → calibrating → recording → stop: true before the file, writer or sources exist; false only once the file is finished")
    func recordCycle() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let source = FakeSource()
        let session = RecordingFixtures.session(sources: [source], store: scratch.store)
        let spy = RecordActiveSpy(session, store: scratch.store, sources: [source])
        #expect(!session.isRecordActive && spy.values.isEmpty)

        let starting = Task { try await session.start(mount: "", vehicle: "", allowWithoutOBD: false,
                                                      calibration: .milliseconds(300)) }
        #expect(await eventually(5) { session.state == .calibrating })
        let first = try #require(spy.changes.first)
        #expect(first == .init(active: true, state: .idle, isStarting: true, hasFile: false, storeEntries: 0,
                               sourcesRunning: false, fileFinished: nil),
                "flipped in the starting phase, before anything of the recording exists")
        #expect(session.isRecordActive && spy.values == [true])
        try await starting.value
        #expect(session.state == .recording && session.isRecordActive && spy.values == [true])
        spy.watch = session.currentFile
        await session.stop()
        #expect(spy.values == [true, false])
        let last = try #require(spy.changes.last)
        #expect(last.state == .idle && !last.hasFile && !last.sourcesRunning && !last.isStarting)
        #expect(last.fileFinished == true, "the writer's finish() is done when Record releases")
        #expect(!session.isRecordActive)
    }

    @Test("Stop during calibration: stays true through stopping, false once ended; the late calibration wake-up changes nothing")
    func stopWhileCalibrating() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let source = FakeSource()
        let session = RecordingFixtures.session(sources: [source], store: scratch.store)
        let spy = RecordActiveSpy(session, store: scratch.store)
        // The end path stops the sources while `stopping`, before finish().
        var duringStop: (state: RecordingState, active: Bool)?
        source.onStop = { [weak session] in
            if let session { duringStop = (session.state, session.isRecordActive) }
        }
        let starting = Task { try await session.start(mount: "", vehicle: "", allowWithoutOBD: false,
                                                      calibration: .milliseconds(500)) }
        #expect(await eventually(5) { session.state == .calibrating })
        spy.watch = session.currentFile
        await session.stop()
        #expect(duringStop?.state == .stopping && duringStop?.active == true)
        try await starting.value
        #expect(spy.values == [true, false])
        #expect(spy.changes.last?.fileFinished == true && spy.changes.last?.state == .idle)
    }

    @Test("A write failure: false only when the state is failed, after finish()")
    func failure() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let session = RecordingFixtures.session(store: scratch.store)
        let spy = RecordActiveSpy(session, store: scratch.store)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        let generation = try #require(session.currentGeneration)
        await session.handleWriteFailure(.diskFull, generation: generation)
        #expect(spy.values == [true, false])
        guard case .failed? = spy.changes.last?.state else {
            Issue.record("released in \(String(describing: spy.changes.last?.state))")
            return
        }
        #expect(!session.isRecordActive)
    }

    @Test("A Start that throws (no OBD, low disk, store not creatable) releases at once; the next Start flips again")
    func startThatThrows() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let link = FakeLink()
        link.state = .idle
        let disk = FakeDisk(RecordingFixtures.roomy)
        let session = RecordingFixtures.session(link: link, store: scratch.store, disk: disk)
        let spy = RecordActiveSpy(session, store: scratch.store)

        await #expect(throws: RecordingStartBlocker.obdNotReady) {
            try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        }
        #expect(spy.values == [true, false] && !session.isRecordActive)

        disk.set(1)
        await #expect(throws: RecordingStartBlocker.self) {
            try await session.start(mount: "", vehicle: "", allowWithoutOBD: true, calibration: .zero)
        }
        #expect(spy.values == [true, false, true, false] && !session.isRecordActive)
        disk.set(RecordingFixtures.roomy)

        try await session.start(mount: "", vehicle: "", allowWithoutOBD: true, calibration: .zero)
        #expect(spy.values == [true, false, true, false, true])
        await session.stop()
        #expect(spy.values == [true, false, true, false, true, false])

        // The store's parent is a file: creating it throws after the checks.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("drivelogger-ux8-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let broken = RecordingFixtures.session(store: LogStore(directory: blocker.appendingPathComponent("logs")))
        let brokenSpy = RecordActiveSpy(broken, store: scratch.store)
        await #expect(throws: (any Error).self) {
            try await broken.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        }
        #expect(brokenSpy.values == [true, false] && !broken.isRecordActive && broken.state == .idle)
    }

    @Test("Navigate never flips it; Navigate → Record → Navigate flips exactly once each way")
    func navigate() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let rig = NavigateRig(store: scratch.store)
        let spy = RecordActiveSpy(rig.session, store: scratch.store)
        await rig.connect(speed: 0)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)
        let first = try #require(rig.session.navigateGeneration)
        await rig.drive(0..<2)
        #expect(spy.values.isEmpty && !rig.session.isRecordActive, "Navigate is not Record")

        try await rig.session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        #expect(spy.values == [true])
        #expect(spy.changes.first?.state == .idle && spy.changes.first?.hasFile == false)
        spy.watch = rig.session.currentFile
        await rig.session.stop()
        #expect(spy.values == [true, false])
        #expect(spy.changes.last?.fileFinished == true)
        let second = try #require(rig.session.navigateGeneration, "back to Navigate")
        #expect(second != first)
        await rig.drive(2..<3)
        rig.session.disableNavigate()
        #expect(spy.values == [true, false] && !rig.session.isRecordActive)
    }

    @Test("The relay delivers every value in the order sent, one at a time")
    nonisolated func relayOrder() async {
        let sink = RelaySink()
        let relay = RecordActivityRelay { await sink.add($0) }
        let sent = (0..<400).map { ($0 * 7919) % 3 == 0 }
        for value in sent { relay.send(value) }
        #expect(await eventually { await sink.values.count == sent.count })
        #expect(await sink.values == sent)
        #expect(await !sink.overlapped)
    }

    @Test("Session → relay → downloader: Record pauses a running download (partial kept) and its end resumes it; Navigate does not")
    func endToEnd() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
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
        let downloader = env.downloader()
        let rig = NavigateRig(store: scratch.store)
        let relay = RecordActivityRelay { await downloader.setRecordActive($0) }
        rig.session.onRecordActiveChange = { relay.send($0) }
        await rig.connect(speed: 0)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)
        #expect(rig.session.navigateGeneration != nil)

        await downloader.start(env.pack(stub))
        #expect(await eventually { @Sendable in
            if case .downloading(let received, _)? = await downloader.snapshot().states["region-a"] { return received > 0 }
            return false
        }, "downloading while Navigate runs")

        try await rig.session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        #expect(await eventually { @Sendable in await downloader.snapshot().states["region-a"] == .pausedForRecording })
        #expect(env.downloadFiles.count == 2 && env.installedFiles.isEmpty)
        let requests = stub.requests.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(stub.requests.count == requests, "nothing requested while Record runs")
        #expect(await downloader.snapshot().states["region-a"] == .pausedForRecording)

        await rig.session.stop()
        #expect(rig.session.navigateGeneration != nil, "back in Navigate, which does not pause")
        await downloader.waitUntilIdle()
        #expect(env.installedFiles.count == 1 && env.downloadFiles.isEmpty)
        #expect(stub.requests.last?.value(forHTTPHeaderField: "Range") != nil, "resumed, not restarted")
        rig.session.disableNavigate()
    }
}

@Suite("Pack hashing memory (R66.1-3)", .serialized)
struct PackHashMemoryTests {
    /// Samples `phys_footprint` from a thread until stopped.
    final class Poller: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: UInt64 = 0
        private var stop = false

        func start() {
            let thread = Thread { [self] in
                while true {
                    if let now = MemoryFootprint.currentBytes() { lock.withLock { peak = max(peak, now) } }
                    if lock.withLock({ stop }) { return }
                    Thread.sleep(forTimeInterval: 0.002)
                }
            }
            thread.start()
        }

        func finish() -> UInt64 {
            lock.withLock { stop = true }
            Thread.sleep(forTimeInterval: 0.02)
            return lock.withLock { peak }
        }
    }

    @Test("Hashing a 128 MB file does not hold its chunks: footprint growth stays far below the file size")
    func footprint() async throws {
        let directory = try RoadPackFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("big.bin")
        let chunk = Data(count: 1 << 20)
        let chunks = 128
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        for _ in 0..<chunks { try handle.write(contentsOf: chunk) }
        try handle.close()
        var expected = SHA256()
        for _ in 0..<chunks { expected.update(data: chunk) }
        let expectedHex = expected.finalize().map { String(format: "%02x", $0) }.joined()

        try await Task.sleep(for: .milliseconds(100))
        let baseline = try #require(MemoryFootprint.currentBytes())
        let poller = Poller()
        poller.start()
        let hex = try await Task.detached(priority: .utility) { try PackDownloader.sha256(of: file) }.value
        let peak = poller.finish()
        #expect(hex == expectedHex)
        let growth = peak > baseline ? peak - baseline : 0
        #expect(growth < 48 << 20, "footprint grew \(growth >> 20) MB while hashing \(chunks) MB")
    }
}
