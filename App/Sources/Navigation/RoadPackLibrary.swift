import DriveLoggerCore
import Foundation

/// The road packs the app can use (N3.3 item 5, docs/N3_PLAN.md "N3.3"
/// amendment): lists the pack files its source offers, verifies each once
/// (Core's `RoadPackCatalog`, cached by file identity in a JSON file) and
/// hands `NavigationService` the usable candidates.
///
/// **The source is injectable.** Today it is the developer bridge,
/// `Documents/RoadPacks/` (`directorySource`); N3.4's import into
/// Application Support swaps only the closure. Nothing else here depends on
/// where the files come from.
///
/// **Never on the main actor, never in the way of a recording.** Listing,
/// verification (O(file size)) and opening the packs run in a detached
/// `.utility` task; this actor only holds the latest result, so `status()`
/// and `candidates()` answer at once between scans. A scan runs at launch,
/// when a recording starts and when Diagnostics appears; a cache hit costs
/// one `stat` per file. A trigger during a scan queues one more scan.
actor RoadPackLibrary {
    /// The pack files to consider now, in the order they are to be used.
    typealias Source = @Sendable () -> [URL]

    /// The file extension of a road pack.
    static let fileExtension = "roadpack"
    static let cacheFileName = "RoadPackVerification.json"

    /// One pack file as Diagnostics shows it.
    struct PackStatus: Sendable, Hashable, Identifiable {
        var id: String { name }
        let name: String
        /// Verified, and every later check passed: the pack can be selected.
        let verified: Bool
        /// Why it is not usable; nil when it is.
        let refusal: String?
        let sizeBytes: Int64?
        /// The OSM data's replication timestamp, Unix seconds (0 unknown).
        let osmTimestamp: Int64?
        /// First 8 hex digits of the content hash, when the header opened.
        let hashPrefix: String?
        /// The verification came from the cache (no re-read of the file).
        let cacheHit: Bool
        let verifySeconds: Double?
    }

    struct Status: Sendable, Hashable {
        var packs: [PackStatus] = []
        /// A scan is running now.
        var scanning = false
        /// Scans finished since launch.
        var scansCompleted = 0

        static let empty = Status()
    }

    /// What selection works from: the open, verified packs, and the files
    /// that are listed but unusable.
    struct Candidates: Sendable {
        var candidates: [RoadPackSelection.Candidate] = []
        var refused: [RoadPackSelection.Refusal] = []
    }

    private struct ScanResult: Sendable {
        var packs: [PackStatus]
        var candidates: Candidates
        var cache: RoadPackVerificationCache
    }

    private let source: Source
    private let cacheURL: URL?
    private var cache: RoadPackVerificationCache?
    private var latest: ScanResult?
    private var scanTask: Task<Void, Never>?
    private var rescanQueued = false
    private var scansCompleted = 0
    /// Scans started since init (tests).
    private(set) var scansStarted = 0
    /// Files verified, not found in the cache, over all scans (tests).
    private(set) var verifications = 0

    /// - Parameters:
    ///   - source: the pack files now.
    ///   - cacheURL: where the verification cache is persisted as JSON; nil
    ///     keeps it in memory only.
    init(source: @escaping Source, cacheURL: URL?) {
        self.source = source
        self.cacheURL = cacheURL
    }

    // MARK: Scanning

    /// Starts a scan in the background and returns at once. During a scan,
    /// queues exactly one more.
    func rescan() {
        guard scanTask == nil else {
            rescanQueued = true
            return
        }
        startScan()
    }

    private func startScan() {
        scansStarted += 1
        let source = source, cacheURL = cacheURL, memory = cache
        scanTask = Task(priority: .utility) { [self] in
            let result = await Task.detached(priority: .utility) {
                Self.perform(source: source, cacheURL: cacheURL, memory: memory)
            }.value
            finish(result)
        }
    }

    private func finish(_ result: ScanResult) {
        latest = result
        cache = result.cache
        scansCompleted += 1
        verifications += result.packs.filter { !$0.cacheHit && $0.sizeBytes != nil }.count
        scanTask = nil
        if rescanQueued {
            rescanQueued = false
            startScan()
        }
    }

    /// The scan itself: off every actor.
    private nonisolated static func perform(source: Source, cacheURL: URL?, memory: RoadPackVerificationCache?) -> ScanResult {
        var old = memory
        if old == nil, let cacheURL, let data = try? Data(contentsOf: cacheURL) {
            old = RoadPackVerificationCache(data: data)
        }
        let known = old ?? RoadPackVerificationCache()
        let catalog = RoadPackCatalog(urls: source(), cache: known)
        let selection = RoadPackSelection.candidates(from: catalog.entries)
        if let cacheURL, catalog.cache != known || (old == nil && !catalog.cache.entries.isEmpty) {
            try? catalog.cache.encoded().write(to: cacheURL, options: .atomic)
        }
        var reasons: [String: String] = [:]
        for refusal in selection.refused {
            for name in refusal.names where reasons[name] == nil { reasons[name] = refusal.reason }
        }
        let packs = catalog.entries.map { entry -> PackStatus in
            let name = entry.url.lastPathComponent
            let reason = reasons[name] ?? entry.refusal
            return PackStatus(
                name: name, verified: reason == nil, refusal: reason,
                sizeBytes: entry.identity?.size,
                osmTimestamp: entry.verification?.osmTimestamp,
                hashPrefix: entry.verification?.contentHash.map { String($0.prefix(8)) },
                cacheHit: entry.cacheHit, verifySeconds: entry.verification?.verifySeconds)
        }
        return ScanResult(packs: packs, candidates: Candidates(candidates: selection.candidates, refused: selection.refused),
                          cache: catalog.cache)
    }

    // MARK: Reading

    /// The packs found by the latest scan and whether one is running.
    func status() -> Status {
        Status(packs: latest?.packs ?? [], scanning: scanTask != nil, scansCompleted: scansCompleted)
    }

    /// The usable candidates. Awaits a scan in progress (starting the first
    /// one if none has run), so a caller never sees a half-verified list.
    func candidates() async -> Candidates {
        if latest == nil && scanTask == nil { startScan() }
        if let task = scanTask { await task.value }
        return latest?.candidates ?? Candidates()
    }

    // MARK: Default source

    /// `*.roadpack` files of `directory`, by name.
    static func directorySource(_ directory: URL) -> Source {
        { listing(directory) }
    }

    static func listing(_ directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `Documents/RoadPacks/`, created if missing so it shows in Finder and
    /// Files (UIFileSharingEnabled). The temporary developer bridge.
    static func documentsDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("RoadPacks", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// `Application Support/RoadPackVerification.json`.
    static func defaultCacheURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent(cacheFileName)
    }

    /// The app's library: the developer bridge and the persisted cache.
    static func makeDefault() -> RoadPackLibrary {
        RoadPackLibrary(source: directorySource(documentsDirectory()), cacheURL: defaultCacheURL())
    }
}
