import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// UX-8 (1) first launch: the coarse one-shot fix and the list model.
// Synthetic names (`zz-01`) and boxes near (0, 0) only; no live network
// (the downloader is offline or on the URLProtocol stub).

// MARK: Coarse fix

@MainActor
final class FakeCoarseSource: CoarseLocationSource {
    var isAuthorized: Bool
    private(set) var starts = 0
    private(set) var stops = 0
    private var onReading: (@MainActor (CoarseLocationReading) -> Void)?

    init(authorized: Bool = true) { isAuthorized = authorized }

    var isRunning: Bool { onReading != nil }

    func start(onReading: @escaping @MainActor (CoarseLocationReading) -> Void) {
        starts += 1
        self.onReading = onReading
    }

    func stop() {
        stops += 1
        onReading = nil
    }

    func deliver(lat: Double = 0.5, lon: Double = 0.5, accuracy: Double, taken: Date) {
        onReading?(CoarseLocationReading(latitude: lat, longitude: lon, horizontalAccuracyM: accuracy, timestamp: taken))
    }
}

/// A settable wall clock.
@MainActor
final class FakeWallClock {
    var now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.now = now }
}

@Suite("Coarse one-shot fix (UX-8)")
@MainActor
struct CoarseFixRequestTests {
    @Test("Stale cached fixes (before the request, or > 60 s old) and inaccurate ones are ignored; the first usable one ends it")
    func filtering() async {
        let source = FakeCoarseSource()
        let clock = FakeWallClock()
        let t0 = clock.now
        let request = CoarseFixRequest(source: source, now: { clock.now }, timeout: .seconds(30))
        let task = Task { await request.run() }
        #expect(await eventually { source.isRunning })
        clock.now = t0.addingTimeInterval(1)
        source.deliver(accuracy: 100, taken: t0.addingTimeInterval(-1_800))   // cached, 30 min old
        source.deliver(accuracy: 100, taken: t0.addingTimeInterval(-5))       // cached, just before the request
        source.deliver(accuracy: 6_000, taken: t0.addingTimeInterval(0.5))    // > 5 km
        source.deliver(accuracy: -1, taken: t0.addingTimeInterval(0.5))       // invalid
        #expect(source.isRunning, "still waiting")
        clock.now = t0.addingTimeInterval(2)
        source.deliver(lat: 0.25, accuracy: 3_000, taken: t0.addingTimeInterval(1.5))
        let result = await task.value
        #expect(result?.fix.latitude == 0.25)
        #expect(result?.requestedAt == t0)
        #expect(result?.fix.arrivedAt == t0.addingTimeInterval(2))
        #expect(request.rejected == [.stale, .stale, .inaccurate, .inaccurate])
        #expect(!source.isRunning && source.stops == 1, "updates stop after the fix")
    }

    @Test("A fix arriving after 10 s is late even before the timer fires")
    func late() async {
        let source = FakeCoarseSource()
        let clock = FakeWallClock()
        let t0 = clock.now
        let request = CoarseFixRequest(source: source, now: { clock.now }, timeout: .milliseconds(300))
        let task = Task { await request.run() }
        #expect(await eventually { source.isRunning })
        clock.now = t0.addingTimeInterval(11)
        source.deliver(accuracy: 100, taken: t0.addingTimeInterval(10.5))
        #expect(await task.value == nil)
        #expect(request.rejected == [.late])
    }

    @Test("Timeout: nil, and updates stop")
    func timeout() async {
        let source = FakeCoarseSource()
        let request = CoarseFixRequest(source: source, timeout: .milliseconds(100))
        let result = await request.run()
        #expect(result == nil)
        #expect(source.starts == 1 && !source.isRunning && source.stops == 1)
    }

    @Test("Not authorised (not determined or denied): nil at once, nothing started")
    func notAuthorised() async {
        let source = FakeCoarseSource(authorized: false)
        let result = await CoarseFixRequest(source: source, timeout: .seconds(30)).run()
        #expect(result == nil && source.starts == 0)
    }

    @Test("Cancelling the caller stops updates and answers nil")
    func cancelled() async {
        let source = FakeCoarseSource()
        let request = CoarseFixRequest(source: source, timeout: .seconds(30))
        let task = Task { await request.run() }
        #expect(await eventually { source.isRunning })
        task.cancel()
        #expect(await task.value == nil)
        #expect(!source.isRunning)
    }

    @Test("DEBUG -uiCoarseFix: none, a synthetic fix, or no override")
    func override() {
        #expect(CoarseLocation.Override.parse("none") == CoarseLocation.Override.none)
        #expect(CoarseLocation.Override.parse("0.5,0.25") == .fix(latitude: 0.5, longitude: 0.25, accuracyM: 1_000))
        #expect(CoarseLocation.Override.parse(" 0.5, 0.25, 300 ") == .fix(latitude: 0.5, longitude: 0.25, accuracyM: 300))
        #expect(CoarseLocation.Override.parse("x") == nil)
        #expect(CoarseLocation.Override.parse("1") == nil)
        #expect(CoarseLocation.Override.parse(nil) == nil)
    }

    @Test("The synthetic source delivers a fresh fix that the request accepts")
    func synthetic() async {
        let result = await CoarseFixRequest(source: SyntheticCoarseSource(latitude: 0.5, longitude: 0.5, accuracyM: 500,
                                                                          delay: .milliseconds(10))).run()
        #expect(result?.fix.latitude == 0.5)
        #expect(await CoarseFixRequest(source: SyntheticCoarseSource()).run() == nil)
    }
}

// MARK: First-launch model

/// A fix the test releases when it likes.
@MainActor
final class FixGate {
    private var continuation: CheckedContinuation<CoarseFixRequest.Result?, Never>?
    private var pending: CoarseFixRequest.Result??
    private(set) var asked = false

    func wait() async -> CoarseFixRequest.Result? {
        asked = true
        if let pending { return pending }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ result: CoarseFixRequest.Result?) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: result)
        } else {
            pending = .some(result)
        }
    }
}

enum FirstLaunchFixture {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// national over everything; zz-01 contains (0.5, 0.9); zz-02 starts
    /// ~11 km east of it (a neighbour); zz-03 is far.
    static func manifestJSON() -> Data {
        let entries: [(String, String, [Double], Int)] = [
            ("zz-03", "region", [3, 2, 4, 3], 30_000_000),
            ("zz-national", "national", [0, 0, 4, 3], 40_000_000),
            ("zz-02", "region", [1, 0, 2, 1], 20_000_000),
            ("zz-01", "region", [0, 0, 1, 1], 10_000_000),
        ]
        let packs: [[String: Any]] = entries.enumerated().map { index, entry in
            let hash = String(repeating: String(index + 1), count: 16)
            return ["name": entry.0, "kind": entry.1, "title": ["uk": "Uk \(entry.0)", "en": "En \(entry.0)"],
                    "bbox": entry.2, "url": "/packs/v1/\(entry.0)-\(hash).roadpack", "size": entry.3,
                    "sha256": String(repeating: "a", count: 64), "contentHash": hash, "formatVersion": 1,
                    "osmTimestamp": 1_760_000_000]
        }
        let root: [String: Any] = ["schema": 2, "generated": "2026-01-01T00:00:00Z", "license": "ODbL",
                                   "licenseUrl": "https://example.invalid/odbl", "attribution": "© OSM", "packs": packs]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    static func fix(lat: Double = 0.5, lon: Double = 0.9) -> CoarseFixRequest.Result {
        CoarseFixRequest.Result(
            fix: PackRegionChoice.Fix(latitude: lat, longitude: lon, horizontalAccuracyM: 1_000,
                                      timestamp: t0.addingTimeInterval(1), arrivedAt: t0.addingTimeInterval(2)),
            requestedAt: t0)
    }

    /// A scratch UserDefaults suite.
    struct Defaults {
        let name = "test.firstLaunchMaps." + UUID().uuidString
        var defaults: UserDefaults { UserDefaults(suiteName: name)! }
        func remove() { UserDefaults.standard.removePersistentDomain(forName: name) }
        var stored: [String: Any] { UserDefaults.standard.persistentDomain(forName: name) ?? [:] }
    }

    struct Env {
        let dirs: StoreFixture.Dirs
        let library: RoadPackLibrary
        let downloader: PackDownloader
        let manifest: PackManifestService
        let defaults = Defaults()

        init(connection: PackDownloadRules.Connection = .none,
             fetch: @escaping PackManifestService.Fetch = { _ in FirstLaunchFixture.manifestJSON() }) throws {
            dirs = try StoreFixture.Dirs()
            library = RoadPackLibrary(store: RoadPackStore(directory: dirs.store), inbox: nil, cacheURL: nil)
            downloader = PackDownloader(directory: dirs.store, library: library, connection: connection,
                                        makeConfiguration: PackStub.configuration)
            manifest = PackManifestService(cacheDirectory: dirs.root, storeDirectory: nil, downloader: downloader,
                                           fetch: fetch, now: { FirstLaunchFixture.t0 })
        }

        @MainActor
        func model(installed: Set<String> = [], fix: @escaping @MainActor () async -> CoarseFixRequest.Result?)
            -> FirstLaunchMapsModel {
            FirstLaunchMapsModel(
                store: FirstLaunchMapsStore(defaults: defaults.defaults), manifest: manifest, downloader: downloader,
                installedNames: { installed }, coarseFix: fix, preferredLanguages: { ["en"] },
                locale: Locale(identifier: "en_US"), now: { FirstLaunchFixture.t0 })
        }

        func remove() {
            dirs.remove()
            defaults.remove()
        }
    }
}

@Suite("First-launch maps model (UX-8)")
@MainActor
struct FirstLaunchMapsModelTests {
    typealias F = FirstLaunchFixture

    @Test("With a usable fix: national and the fix's region preselected, the neighbour listed next to it but not selected")
    func regionFromFix() async throws {
        let env = try F.Env()
        defer { env.remove() }
        let model = env.model { F.fix() }
        #expect(model.isPresented)
        model.start()
        await model.waitUntilLoaded()
        #expect(model.listState == .ready)
        #expect(model.rows.map(\.id) == ["zz-national", "zz-01", "zz-02", "zz-03"])
        #expect(model.rows.map(\.role) == [.national, .region, .neighbour, .other])
        #expect(model.rows.filter(\.isSelected).map(\.id) == ["zz-national", "zz-01"])
        #expect(model.rows.first?.title == "En zz-national", "title in the app language")
        #expect(model.selectedCount == 2 && model.selectedBytes == 50_000_000)
        #expect(model.fixState == .found(region: "zz-01"))
        #expect(await env.downloader.activeNames().isEmpty, "nothing downloads before confirm")
    }

    @Test("No usable fix: national only, no region or neighbours, the rest by title")
    func noFix() async throws {
        let env = try F.Env()
        defer { env.remove() }
        let model = env.model { nil }
        model.start()
        await model.waitUntilLoaded()
        #expect(model.rows.map(\.id) == ["zz-national", "zz-01", "zz-02", "zz-03"])
        #expect(model.rows.map(\.role) == [.national, .other, .other, .other])
        #expect(model.rows.filter(\.isSelected).map(\.id) == ["zz-national"])
        #expect(model.fixState == .none)
    }

    @Test("A fix arriving after the list, with no edits, selects the region")
    func lateFixNoEdits() async throws {
        let env = try F.Env()
        defer { env.remove() }
        let gate = FixGate()
        let model = env.model { await gate.wait() }
        model.start()
        await model.waitForList()
        #expect(model.rows.filter(\.isSelected).map(\.id) == ["zz-national"])
        #expect(model.fixState == .waiting, "the list never waits for the fix")
        gate.release(F.fix())
        await model.waitUntilLoaded()
        #expect(model.rows.filter(\.isSelected).map(\.id) == ["zz-national", "zz-01"])
    }

    @Test("User edits are not overridden by a late fix: neither the selection nor the order changes")
    func lateFixAfterEdit() async throws {
        let env = try F.Env()
        defer { env.remove() }
        let gate = FixGate()
        let model = env.model { await gate.wait() }
        model.start()
        await model.waitForList()
        let order = model.rows.map(\.id)
        model.toggle("zz-03")
        model.toggle("zz-national")
        #expect(model.userEdited)
        gate.release(F.fix())
        await model.waitUntilLoaded()
        #expect(model.rows.map(\.id) == order)
        #expect(model.rows.filter(\.isSelected).map(\.id) == ["zz-03"])
        #expect(model.fixState == .found(region: "zz-01"))
    }

    @Test("Confirm queues exactly the selected packs through the downloader (offline: they wait) and closes the step")
    func confirmQueues() async throws {
        let env = try F.Env(connection: .none)
        defer { env.remove() }
        let model = env.model { F.fix() }
        model.start()
        await model.waitUntilLoaded()
        model.toggle("zz-02")
        await model.refreshNetwork()
        #expect(model.network == .offline)
        await model.confirm()
        #expect(await env.downloader.activeNames() == ["zz-national", "zz-01", "zz-02"])
        #expect(await env.downloader.snapshot().states["zz-01"] == .offline)
        #expect(!model.isPresented)
        #expect(FirstLaunchMapsStore(defaults: env.defaults.defaults).isDone)
        #expect(Set(env.defaults.stored.keys) == [FirstLaunchMapsStore.key], "only the done flag is stored")
    }

    @Test("Offline with no cached list: no list, only 'later'; later stores only the done flag")
    func offlineNoCache() async throws {
        let env = try F.Env(fetch: { _ in throw URLError(.notConnectedToInternet) })
        defer { env.remove() }
        let model = env.model { nil }
        model.start()
        await model.waitUntilLoaded()
        #expect(model.listState == .noList && model.rows.isEmpty && !model.canConfirm)
        await model.confirm()
        #expect(model.isPresented, "confirm does nothing without a list")
        model.later()
        #expect(!model.isPresented)
        #expect(await env.downloader.activeNames().isEmpty)
        #expect(Set(env.defaults.stored.keys) == [FirstLaunchMapsStore.key])
        #expect(!env.model { nil }.isPresented, "not shown again")
    }

    @Test("Offline with a cached list: the cached list is shown")
    func offlineCached() async throws {
        let env = try F.Env()
        defer { env.remove() }
        await env.manifest.refresh(force: true)   // writes the cache
        let offline = PackManifestService(cacheDirectory: env.dirs.root, storeDirectory: nil,
                                          fetch: { _ in throw URLError(.notConnectedToInternet) })
        let model = FirstLaunchMapsModel(
            store: FirstLaunchMapsStore(defaults: env.defaults.defaults), manifest: offline, downloader: env.downloader,
            coarseFix: { nil }, preferredLanguages: { ["en"] }, now: { F.t0 })
        model.start()
        await model.waitUntilLoaded()
        #expect(model.listState == .ready && model.rows.count == 4)
    }

    @Test("Cellular without permission: 'will wait for Wi-Fi'; Use cellular sets the Maps switch and makes it ready")
    func cellularWording() async throws {
        let env = try F.Env(connection: .cellularOrExpensive)
        defer { env.remove() }
        let model = env.model { nil }
        await model.refreshNetwork()
        #expect(model.network == .waitsForWiFi)
        await model.useCellular()
        #expect(model.network == .ready)
        #expect(env.defaults.defaults.bool(forKey: MapsSettings.cellularKey))
        await env.downloader.setConnection(.unmetered)
        env.defaults.defaults.set(false, forKey: MapsSettings.cellularKey)
        await model.refreshNetwork()
        #expect(model.network == .ready, "Wi-Fi needs no permission")
    }

    @Test("Installed packs are listed as installed and never preselected or queued")
    func installed() async throws {
        let env = try F.Env()
        defer { env.remove() }
        let model = env.model(installed: ["zz-national"]) { F.fix() }
        model.start()
        await model.waitUntilLoaded()
        #expect(model.rows.first { $0.id == "zz-national" }?.isInstalled == true)
        #expect(model.rows.filter(\.isSelected).map(\.id) == ["zz-01"])
        model.toggle("zz-national")
        #expect(model.rows.filter(\.isSelected).map(\.id) == ["zz-01"])
        await model.confirm()
        #expect(await env.downloader.activeNames() == ["zz-01"])
    }
}
