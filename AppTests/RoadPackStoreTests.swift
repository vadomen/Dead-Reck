import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// N3.4: the road pack store (Application Support/RoadPacks), its one
// install path, launch maintenance (developer inbox, cleanup) and Remove.
// Synthetic packs (`RoadPackFixture`) and synthetic names (`region-a`,
// `national`) in temporary directories; never the app's own store.

enum StoreFixture {
    /// A fresh scratch root with `store/` (not created) and `inbox/` and
    /// `sources/` (created).
    struct Dirs {
        let root: URL
        var store: URL { root.appendingPathComponent("store", isDirectory: true) }
        var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
        var sources: URL { root.appendingPathComponent("sources", isDirectory: true) }
        var cache: URL { root.appendingPathComponent("cache.json") }

        init() throws {
            root = try RoadPackFixture.directory()
            try FileManager.default.createDirectory(at: root.appendingPathComponent("inbox"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("sources"), withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    static func contentHash(_ data: Data) throws -> String {
        RoadPackStoreRules.contentHashText(try RoadPack(data: data, verify: false).contentHash)
    }

    static func storedName(_ name: String, _ data: Data) throws -> String {
        try #require(RoadPackStoreRules.fileName(name: name, contentHash: try contentHash(data)))
    }

    /// Every entry of `directory`, hidden ones included, sorted; [] when it
    /// does not exist.
    static func entries(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    struct FileStamp: Equatable {
        let inode: UInt64
        let modified: Date?
        let created: Date?
        let data: Data
    }

    static func stamp(_ url: URL) throws -> FileStamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileStamp(inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                         modified: attributes[.modificationDate] as? Date,
                         created: attributes[.creationDate] as? Date,
                         data: try Data(contentsOf: url))
    }

    static func excludedFromBackup(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }
}

@Suite("Road pack installer (N3.4)", .serialized)
struct RoadPackInstallerTests {
    @Test("A good pack is stored as <name>-<contentHash>.roadpack, the source untouched, no temporary left, excluded from backup")
    func installs() throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        let data = try RoadPackFixture.data()
        let source = try RoadPackFixture.write(data, named: "download.bin", in: dirs.sources)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                              ofItemAtPath: source.path)
        let before = try StoreFixture.stamp(source)

        let outcome = RoadPackInstaller(storeDirectory: dirs.store).install(from: source, name: "region-a")
        guard case .installed(let pack) = outcome else { Issue.record("\(outcome)"); return }
        let expected = try StoreFixture.storedName("region-a", data)
        #expect(pack.fileName == expected && pack.name == "region-a")
        #expect(pack.contentHash == (try StoreFixture.contentHash(data)))
        #expect(StoreFixture.entries(dirs.store) == [expected])
        #expect(try Data(contentsOf: pack.url) == data)
        #expect(try StoreFixture.stamp(source) == before, "the source is byte-for-byte and date-for-date unchanged")
        // The cache entry is the stored file's identity, verified.
        let entry = try #require(pack.cacheEntry)
        #expect(entry.identity == (try RoadPackFileIdentity(contentsOf: pack.url)))
        #expect(entry.verification.verified && entry.verification.contentHash == pack.contentHash)
        // Install time: the copy's own creation date, not the source's.
        let created = try #require(try StoreFixture.stamp(pack.url).created)
        #expect(abs(created.timeIntervalSinceNow) < 60)
        #expect(StoreFixture.excludedFromBackup(dirs.store))
        #expect(StoreFixture.excludedFromBackup(pack.url))
    }

    @Test("A source over the size limit is refused before anything is copied (the store is not even created)")
    func tooLarge() throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        let data = try RoadPackFixture.data()
        let source = try RoadPackFixture.write(data, named: "big.roadpack", in: dirs.sources)
        let installer = RoadPackInstaller(storeDirectory: dirs.store, maxBytes: Int64(data.count - 1))
        let reason = try #require(installer.install(from: source, name: "region-a").refusal)
        #expect(reason.contains("limit"))
        #expect(!FileManager.default.fileExists(atPath: dirs.store.path))
        // The default limit is the format's 150 MB.
        #expect(RoadPackInstaller.defaultMaxBytes == 150_000_000)
        #expect(RoadPackInstaller(storeDirectory: dirs.store, maxBytes: Int64(data.count))
            .install(from: source, name: "region-a").installed != nil)
    }

    @Test("Corrupt, truncated and foreign files are refused with a reason; no temporary file is left")
    func refusesBadFiles() throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        let good = try RoadPackFixture.data()
        var corrupt = good
        corrupt[corrupt.count - 16] ^= 0xFF
        var magic = good
        magic[0] = 0x58
        let cases: [(String, Data)] = [
            ("corrupt", corrupt), ("truncated", good.prefix(good.count / 2)),
            ("text", Data("not a road pack\n".utf8)), ("magic", magic), ("empty", Data()),
        ]
        let installer = RoadPackInstaller(storeDirectory: dirs.store)
        for (label, data) in cases {
            let source = try RoadPackFixture.write(data, named: "\(label).roadpack", in: dirs.sources)
            let reason = installer.install(from: source, name: "region-a").refusal
            #expect(reason?.isEmpty == false, "\(label)")
            #expect(StoreFixture.entries(dirs.store) == [], "\(label): nothing left in the store")
            #expect(try Data(contentsOf: source) == data, "\(label): source unchanged")
        }
        // A missing source and a directory are refused too.
        #expect(installer.install(from: dirs.sources.appendingPathComponent("missing.roadpack"), name: "region-a").refusal != nil)
        #expect(installer.install(from: dirs.inbox, name: "region-a").refusal == "not a regular file")
        #expect(StoreFixture.entries(dirs.store) == [])
    }

    @Test("An invalid pack name is refused before copying")
    func invalidName() throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        let source = try RoadPackFixture.write(try RoadPackFixture.data(), named: "a.roadpack", in: dirs.sources)
        let installer = RoadPackInstaller(storeDirectory: dirs.store)
        for name in ["", "Region-a", "-region", "region-", "a/b", "a b"] {
            #expect(installer.install(from: source, name: name).refusal != nil, "\(name)")
        }
        #expect(!FileManager.default.fileExists(atPath: dirs.store.path))
    }

    @Test("The same content twice: alreadyInstalled, the existing file keeps its inode, dates and bytes")
    func sameContentTwice() throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        let data = try RoadPackFixture.data()
        let first = try RoadPackFixture.write(data, named: "first.roadpack", in: dirs.sources)
        let second = try RoadPackFixture.write(data, named: "second.roadpack", in: dirs.sources)
        let installer = RoadPackInstaller(storeDirectory: dirs.store)
        let stored = try #require(installer.install(from: first, name: "region-a").installed)
        // Old dates, so a rewrite would show.
        let old = Date(timeIntervalSince1970: 1_650_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stored.url.path)
        let before = try StoreFixture.stamp(stored.url)

        let again = installer.install(from: second, name: "region-a")
        guard case .alreadyInstalled(let pack) = again else { Issue.record("\(again)"); return }
        #expect(pack.fileName == stored.fileName && pack.cacheEntry == nil)
        #expect(try StoreFixture.stamp(stored.url) == before)
        #expect(StoreFixture.entries(dirs.store) == [stored.fileName], "no temporary left")
        // Another name for the same bytes is another file.
        #expect(installer.install(from: second, name: "national").installed?.fileName
                == (try StoreFixture.storedName("national", data)))
    }

    @Test("Library install: the verification is cached, so the following scan and a relaunch are cache hits")
    func libraryInstallIsCacheHit() async throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        let data = try RoadPackFixture.data()
        let source = try RoadPackFixture.write(data, named: "download.bin", in: dirs.sources)
        let store = RoadPackStore(directory: dirs.store)
        let library = RoadPackLibrary(store: store, inbox: nil, cacheURL: dirs.cache)
        #expect(await library.candidates().candidates.isEmpty)

        let outcome = await library.install(from: source, name: "region-a")
        let name = try StoreFixture.storedName("region-a", data)
        #expect(outcome.installed?.fileName == name)
        let status = await library.status()
        let pack = try #require(status.packs.first)
        #expect(status.packs.count == 1 && pack.name == name && pack.verified && pack.cacheHit)
        #expect(pack.packName == "region-a" && pack.displayName == "region-a" && pack.hashPrefix?.count == 8)
        #expect(pack.hasCoverage == false && pack.bounds != nil && pack.osmTimestamp == 1_700_000_000)
        #expect(pack.sizeBytes == Int64(data.count) && !pack.pendingRemoval && pack.installed)
        #expect((status.storeBytes ?? 0) >= Int64(data.count))
        #expect(await library.verifications == 0, "installed means verified once, by the installer")
        #expect(await library.candidates().candidates.map(\.name) == [name])

        let relaunched = RoadPackLibrary(store: store, inbox: nil, cacheURL: dirs.cache)
        #expect(await relaunched.candidates().candidates.map(\.name) == [name])
        #expect(await relaunched.status().packs.first?.cacheHit == true)
        #expect(await relaunched.verifications == 0)
    }
}

@Suite("Road pack store: launch maintenance (N3.4)", .serialized)
struct RoadPackLaunchMaintenanceTests {
    @Test("The inbox is installed and emptied; a refused file stays and is reported; the first scan is a cache hit")
    func inbox() async throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        let good = try RoadPackFixture.data()
        let other = try RoadPackFixture.data(latShiftE7: 1_000)
        try RoadPackFixture.write(good, named: "region-a.roadpack", in: dirs.inbox)
        // A store-style name: the hash in it is not trusted, the header's is.
        try RoadPackFixture.write(other, named: "national-0000000000000000.roadpack", in: dirs.inbox)
        try RoadPackFixture.write(good.prefix(200), named: "broken.roadpack", in: dirs.inbox)
        try RoadPackFixture.write(good, named: "Bad Name.roadpack", in: dirs.inbox)
        try RoadPackFixture.write(Data("x".utf8), named: "notes.txt", in: dirs.inbox)

        let library = RoadPackLibrary(store: RoadPackStore(directory: dirs.store), inbox: dirs.inbox, cacheURL: dirs.cache)
        let names = await library.candidates().candidates.map(\.name).sorted()
        let a = try StoreFixture.storedName("region-a", good), n = try StoreFixture.storedName("national", other)
        #expect(names == [n, a].sorted())
        #expect(StoreFixture.entries(dirs.store) == [n, a].sorted())
        #expect(StoreFixture.entries(dirs.inbox) == ["Bad Name.roadpack", "broken.roadpack", "notes.txt"])
        #expect(await library.verifications == 0)

        let report = try #require(await library.maintenanceReport)
        #expect(report.installed.sorted() == [n, a].sorted() && report.alreadyInstalled.isEmpty)
        #expect(report.inboxRefused.map(\.fileName) == ["Bad Name.roadpack", "broken.roadpack"])
        #expect(report.failures.isEmpty)
        let status = await library.status()
        #expect(status.installedPacks.map(\.name).sorted() == [n, a].sorted())
        #expect(status.inboxRefusals.map(\.name) == ["Bad Name.roadpack", "broken.roadpack"])
        #expect(status.inboxRefusals.allSatisfy { !$0.verified && $0.refusal?.isEmpty == false })
        let detail = RoadPackLibrary.roadPacksDetail(await library.rescan())
        #expect(detail.hasPrefix("2 found, 2 verified; inbox Bad Name.roadpack: invalid pack name"))
        #expect(detail.contains("; inbox broken.roadpack: "))
        // Later scans run no maintenance: the inbox refusal stays reported
        // and a file pushed now waits for the next launch.
        try RoadPackFixture.write(try RoadPackFixture.data(latShiftE7: 2_000), named: "late.roadpack", in: dirs.inbox)
        await library.rescan()
        #expect(StoreFixture.entries(dirs.inbox).contains("late.roadpack"))
        #expect(await library.status().inboxRefusals.count == 2)
    }

    @Test("An inbox file already stored is removed from the inbox; the stored file is untouched")
    func inboxAlreadyInstalled() async throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        let data = try RoadPackFixture.data()
        let store = RoadPackStore(directory: dirs.store)
        let source = try RoadPackFixture.write(data, named: "s.roadpack", in: dirs.sources)
        let stored = try #require(store.installer.install(from: source, name: "region-a").installed)
        let before = try StoreFixture.stamp(stored.url)
        try RoadPackFixture.write(data, named: "region-a.roadpack", in: dirs.inbox)

        let library = RoadPackLibrary(store: store, inbox: dirs.inbox, cacheURL: nil)
        #expect(await library.candidates().candidates.map(\.name) == [stored.fileName])
        #expect(await library.maintenanceReport?.alreadyInstalled == [stored.fileName])
        #expect(StoreFixture.entries(dirs.inbox) == [])
        #expect(try StoreFixture.stamp(stored.url) == before)
    }

    @Test("Launch deletes superseded and marked files and leftover temporaries; unknown files stay; later scans delete nothing")
    func cleanup() async throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        let store = RoadPackStore(directory: dirs.store)
        let installer = store.installer
        func install(_ data: Data, _ name: String, _ file: String) throws -> RoadPackInstaller.Installed {
            try #require(installer.install(from: try RoadPackFixture.write(data, named: file, in: dirs.sources),
                                           name: name).installed)
        }
        let oldData = try RoadPackFixture.data(osmTimestamp: 1_700_000_000)
        let old = try install(oldData, "region-a", "old.roadpack")
        let new = try install(try RoadPackFixture.data(osmTimestamp: 1_750_000_000), "region-a", "new.roadpack")
        let marked = try install(try RoadPackFixture.data(latShiftE7: 1_000), "region-b", "b.roadpack")
        let national = try install(try RoadPackFixture.data(latShiftE7: 2_000), "national", "n.roadpack")
        try store.mark([marked.fileName])
        let temp = RoadPackStoreRules.temporaryFileName(token: "leftover")
        try RoadPackFixture.write(Data("partial".utf8), named: temp, in: dirs.store)
        try RoadPackFixture.write(Data("keep".utf8), named: "notes.txt", in: dirs.store)
        // Before launch the rules already pick the newest unmarked file.
        #expect(store.activeURLs().map(\.lastPathComponent) == [national.fileName, new.fileName].sorted())

        let library = RoadPackLibrary(store: store, inbox: dirs.inbox, cacheURL: nil)
        #expect(await library.candidates().candidates.map(\.name).sorted() == [national.fileName, new.fileName].sorted())
        #expect(StoreFixture.entries(dirs.store) == [national.fileName, new.fileName, "notes.txt"].sorted())
        #expect(await library.maintenanceReport?.deleted == [old.fileName, marked.fileName, temp].sorted())
        #expect(!FileManager.default.fileExists(atPath: store.stateURL.path), "marks of deleted files are dropped")

        // After launch: an older version installed again is superseded and
        // stays on disk (a session may map packs now); never offered.
        let back = try #require(await library.install(
            from: try RoadPackFixture.write(oldData, named: "again.roadpack", in: dirs.sources), name: "region-a").installed)
        #expect(back.fileName == old.fileName)
        await library.rescan()
        #expect(FileManager.default.fileExists(atPath: back.url.path))
        #expect(await library.candidates().candidates.map(\.name).sorted() == [national.fileName, new.fileName].sorted())
        // The next launch deletes it.
        let relaunched = RoadPackLibrary(store: store, inbox: dirs.inbox, cacheURL: nil)
        _ = await relaunched.candidates()
        #expect(!FileManager.default.fileExists(atPath: back.url.path))
    }
}

@Suite("Road pack remove (N3.4)", .serialized)
struct RoadPackRemoveTests {
    func installed(_ dirs: StoreFixture.Dirs, _ store: RoadPackStore, latShiftE7: Int32 = 0, name: String = "region-a",
                   osmTimestamp: Int64 = 1_700_000_000) throws -> RoadPackInstaller.Installed {
        let source = try RoadPackFixture.write(
            try RoadPackFixture.data(osmTimestamp: osmTimestamp, latShiftE7: latShiftE7),
            named: "\(UUID().uuidString).roadpack", in: dirs.sources)
        return try #require(store.installer.install(from: source, name: name).installed)
    }

    @Test("Remove during a run: marked, still on disk, gone from the active set, pending in status; deleted by the next launch")
    func removeWhileRunning() async throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        let store = RoadPackStore(directory: dirs.store)
        let pack = try installed(dirs, store)
        let keep = try installed(dirs, store, latShiftE7: 1_000, name: "national")
        let library = RoadPackLibrary(store: store, inbox: nil, cacheURL: nil)
        await library.setRunActivity { true }
        #expect(await library.candidates().candidates.map(\.name).sorted() == [keep.fileName, pack.fileName].sorted())
        // An older version installed after launch: superseded, on disk.
        let older = try installed(dirs, store, osmTimestamp: 1_600_000_000)
        #expect(await library.candidates().candidates.map(\.name).sorted() == [keep.fileName, pack.fileName].sorted())

        let outcome = await library.remove(name: "region-a")
        #expect(outcome == .removalPending([older.fileName, pack.fileName].sorted()))
        #expect(FileManager.default.fileExists(atPath: pack.url.path) && FileManager.default.fileExists(atPath: older.url.path))
        #expect(await library.candidates().candidates.map(\.name) == [keep.fileName])
        let status = await library.status()
        let pending = status.installedPacks.filter(\.pendingRemoval)
        #expect(pending.map(\.name) == [older.fileName, pack.fileName].sorted())
        #expect(pending.allSatisfy { $0.packName == "region-a" && !$0.verified
                && $0.refusal == "removal pending (after restart)" && $0.hashPrefix?.count == 8 && $0.sizeBytes != nil })
        #expect(RoadPackLibrary.roadPacksDetail(status.packs).hasPrefix("1 found, 1 verified; "))
        #expect(await library.remove(name: "region-c") == .notInstalled)

        // Next launch.
        let relaunched = RoadPackLibrary(store: store, inbox: nil, cacheURL: nil)
        #expect(await relaunched.candidates().candidates.map(\.name) == [keep.fileName])
        #expect(!FileManager.default.fileExists(atPath: pack.url.path) && !FileManager.default.fileExists(atPath: older.url.path))
        #expect(await relaunched.status().packs.map(\.name) == [keep.fileName])
        #expect(!FileManager.default.fileExists(atPath: store.stateURL.path))
    }

    @Test("Remove with no run active deletes now; with the run check unset it only marks")
    func removeIdle() async throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        let store = RoadPackStore(directory: dirs.store)
        let pack = try installed(dirs, store)
        let library = RoadPackLibrary(store: store, inbox: nil, cacheURL: nil)
        #expect(await library.remove(name: "region-a") == .removalPending([pack.fileName]), "unknown counts as running")
        #expect(FileManager.default.fileExists(atPath: pack.url.path))

        await library.setRunActivity { false }
        #expect(await library.remove(name: "region-a") == .deleted([pack.fileName]))
        #expect(StoreFixture.entries(dirs.store) == [])
        let status = await library.status()
        #expect(status.packs.isEmpty && status.storeBytes == 0)
        #expect(await library.candidates().candidates.isEmpty)
    }

    @Test("Installing a pack marked for removal again clears the mark: it is offered again and survives the next launch")
    func reinstallClearsMark() async throws {
        let dirs = try StoreFixture.Dirs()
        defer { dirs.remove() }
        let store = RoadPackStore(directory: dirs.store)
        let data = try RoadPackFixture.data()
        let pack = try #require(store.installer.install(
            from: try RoadPackFixture.write(data, named: "a.roadpack", in: dirs.sources), name: "region-a").installed)
        let library = RoadPackLibrary(store: store, inbox: nil, cacheURL: nil)
        await library.setRunActivity { true }
        #expect(await library.remove(name: "region-a") == .removalPending([pack.fileName]))
        #expect(await library.candidates().candidates.isEmpty)

        let again = await library.install(from: try RoadPackFixture.write(data, named: "b.roadpack", in: dirs.sources),
                                          name: "region-a")
        #expect(again == .alreadyInstalled(RoadPackInstaller.Installed(
            name: "region-a", fileName: pack.fileName, url: pack.url, contentHash: pack.contentHash, cacheEntry: nil)))
        #expect(await library.candidates().candidates.map(\.name) == [pack.fileName])
        let relaunched = RoadPackLibrary(store: store, inbox: nil, cacheURL: nil)
        #expect(await relaunched.candidates().candidates.map(\.name) == [pack.fileName])
    }
}

@Suite("Run activity for Remove (N3.4)", .serialized)
@MainActor
struct RoadPackRunActivityTests {
    @Test("The navigation service has an active run from its feed's start until the feed has drained")
    func navigationService() async throws {
        let service = NavigationService()
        #expect(!(await service.hasActiveRun))
        let (feed, tap) = NavigationServiceNavigateTests.feed(1, header: NavigationServiceNavigateTests.header(),
                                                              sidecarIn: nil)
        let task = service.start(feed)
        var active = false
        for _ in 0..<500 where !active {
            active = await service.hasActiveRun
            if !active { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(active)
        tap.finish()
        await task.value
        #expect(!(await service.hasActiveRun))
    }

    @Test("The recording session has an active run while recording")
    func recordingSession() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let session = RecordingFixtures.session(sources: [FakeSource()], store: scratch.store)
        #expect(!session.hasActiveRun)
        try await session.start(mount: "", vehicle: "", allowWithoutOBD: false, calibration: .zero)
        #expect(session.hasActiveRun)
        await session.stop()
        #expect(!session.hasActiveRun)
    }
}
