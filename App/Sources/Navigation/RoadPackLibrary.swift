import DriveLoggerCore
import Foundation

/// The road packs the app can use (N3.3 item 5, docs/N3_PLAN.md "N3.3"
/// amendment; N3.4): lists the pack files its source offers, verifies each
/// once (Core's `RoadPackCatalog`, cached by file identity in a JSON file)
/// and hands `NavigationService` the usable candidates.
///
/// **The source is injectable.** The app's is the store
/// (`RoadPackStore`, `Application Support/RoadPacks/`): only its active
/// file per pack name (`RoadPackStoreRules.activeSet`), so a superseded or
/// marked file is never offered. Tests pass a plain directory
/// (`directorySource`). Nothing else here depends on where the files come
/// from.
///
/// **Launch maintenance runs first, before anything can map a pack.** With
/// a store, the first scan starts with `RoadPackStore.launchMaintenance`
/// (installing the developer inbox `Documents/RoadPacks/`, deleting
/// superseded, marked and leftover files), inside the detached task, before
/// it lists the store. Sessions map packs only through `candidates()`,
/// which awaits a scan in progress and starts the first one if none ran;
/// `remove(name:)` and `install(from:name:)` wait for the first scan too.
/// So no pack is mapped, and no other store change happens, until
/// maintenance has finished, and no later scan deletes anything.
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
    /// Whether a Navigate or Record run is active, so packs may be mapped
    /// (`AppServices` asks the recording session and the navigation service).
    typealias RunActivity = @Sendable () async -> Bool

    /// The file extension of a road pack.
    static let fileExtension = RoadPackStoreRules.fileExtension
    static let cacheFileName = "RoadPackVerification.json"
    /// The `refusal` of a pack marked for removal.
    static let removalPendingText = "removal pending (after restart)"

    /// One pack file as Diagnostics and Settings → Maps show it.
    struct PackStatus: Sendable, Hashable, Identifiable {
        var id: String { (inInbox ? "inbox/" : "") + name }
        /// The file name (`<name>-<contentHash>.roadpack` in the store).
        let name: String
        /// Verified, and every later check passed: the pack can be selected.
        let verified: Bool
        /// Why it is not usable; nil when it is. `removalPendingText` for a
        /// pack marked for removal.
        let refusal: String?
        let sizeBytes: Int64?
        /// The OSM data's replication timestamp, Unix seconds (0 unknown).
        let osmTimestamp: Int64?
        /// First 8 hex digits of the content hash, when the header opened.
        let hashPrefix: String?
        /// The verification came from the cache (no re-read of the file).
        let cacheHit: Bool
        let verifySeconds: Double?
        /// The pack's name (`<name>` of a store file name); nil for a file
        /// not named like a stored pack (a test directory).
        var packName: String?
        /// The shape points' bounding box, from the verification.
        var bounds: RoadPackBounds?
        /// The pack has a `COVR` coverage polygon; nil when not verified.
        var hasCoverage: Bool?
        /// "Remove" was chosen while a run was active: never offered again,
        /// deleted at the next launch.
        var pendingRemoval = false
        /// A file refused at launch and left in the developer inbox
        /// (`Documents/RoadPacks/`); not installed, never offered.
        var inInbox = false

        /// In the store (active or pending removal), not an inbox refusal.
        var installed: Bool { !inInbox }
        /// What a list shows as the title: the pack name, else the file name.
        var displayName: String { packName ?? name }
    }

    struct Status: Sendable, Hashable {
        /// The active packs (verified or refused), the ones pending removal
        /// and the inbox refusals of this launch.
        var packs: [PackStatus] = []
        /// A scan is running now.
        var scanning = false
        /// Scans finished since launch.
        var scansCompleted = 0
        /// Bytes of every file in the store directory at the latest scan;
        /// nil without a store or before the first scan.
        var storeBytes: Int64?

        /// Settings → Maps: the installed packs (active and pending removal).
        var installedPacks: [PackStatus] { packs.filter(\.installed) }
        /// Files left in the developer inbox because they were refused.
        var inboxRefusals: [PackStatus] { packs.filter(\.inInbox) }

        static let empty = Status()
    }

    /// What `remove(name:)` did.
    enum RemoveOutcome: Sendable, Hashable {
        /// No run was active: these files were deleted now.
        case deleted([String])
        /// A run was active (packs may be mapped): these files are marked,
        /// out of the active set from the next scan on, and deleted at the
        /// next launch.
        case removalPending([String])
        /// No file of that name is installed (or there is no store).
        case notInstalled
        /// The files could not be deleted or marked; the reason.
        case failed(String)
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
        /// The candidates' coverages by pack name (`coverages()`).
        var coverages: [InstalledPackCoverage]
        var cache: RoadPackVerificationCache
        /// Files verified (not cache hits) in this scan.
        var verifications: Int
        var storeBytes: Int64?
        /// The launch maintenance this scan ran (the first scan with a store).
        var maintenance: RoadPackStore.MaintenanceReport?
    }

    private let source: Source
    private let cacheURL: URL?
    private let store: RoadPackStore?
    private let inbox: URL?
    private var runActivity: RunActivity?
    private var cache: RoadPackVerificationCache?
    /// Verifications of files installed since the last scan started, merged
    /// into the cache the next scan starts from.
    private var pendingCacheEntries: [RoadPackVerificationCache.Entry] = []
    private var latest: ScanResult?
    private var scanTask: Task<Void, Never>?
    private var rescanQueued = false
    private var maintenanceStarted = false
    /// The launch maintenance's report (kept for status and the row).
    private(set) var maintenanceReport: RoadPackStore.MaintenanceReport?
    /// `rescan()` callers waiting for scan number `target` (1-based).
    private var waiters: [(target: Int, continuation: CheckedContinuation<[PackStatus], Never>)] = []
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
        store = nil
        inbox = nil
    }

    /// A library over `store`'s active files, which runs the store's launch
    /// maintenance (installing `inbox`) as the first step of its first scan.
    init(store: RoadPackStore, inbox: URL?, cacheURL: URL?) {
        source = store.source
        self.cacheURL = cacheURL
        self.store = store
        self.inbox = inbox
    }

    /// How `remove(name:)` learns whether a run is active. Until it is set,
    /// a run counts as active (Remove marks, never deletes).
    func setRunActivity(_ check: @escaping RunActivity) {
        runActivity = check
    }

    // MARK: Scanning

    /// Starts a scan in the background (during a scan, queues exactly one
    /// more) and returns the packs that scan found once it has finished.
    /// Callers that don't need the result wrap the call in a `Task`.
    @discardableResult
    func rescan() async -> [PackStatus] {
        let target: Int
        if scanTask == nil {
            startScan()
            target = scansStarted
        } else {
            rescanQueued = true
            target = scansStarted + 1
        }
        return await withCheckedContinuation { waiters.append((target, $0)) }
    }

    /// The `detail` of the `roadPacks` lifecycle row for a scan's `packs`:
    /// `<n> found, <m> verified` over the active packs plus `; <file>:
    /// <reason>` per refused one, then `; <file>: removal pending (after
    /// restart)` per pack marked for removal and `; inbox <file>: <reason>`
    /// per file refused from the developer inbox (each part sorted by file
    /// name). `none installed` instead of the counts when no pack is active.
    static func roadPacksDetail(_ packs: [PackStatus]) -> String {
        let active = packs.filter { !$0.inInbox && !$0.pendingRemoval }.sorted { $0.name < $1.name }
        var parts: [String] = []
        if active.isEmpty {
            parts.append("none installed")
        } else {
            parts.append("\(active.count) found, \(active.filter(\.verified).count) verified")
            for pack in active where !pack.verified { parts.append("\(pack.name): \(pack.refusal ?? "refused")") }
        }
        for pack in packs.filter(\.pendingRemoval).sorted(by: { $0.name < $1.name }) {
            parts.append("\(pack.name): \(removalPendingText)")
        }
        for pack in packs.filter(\.inInbox).sorted(by: { $0.name < $1.name }) {
            parts.append("inbox \(pack.name): \(pack.refusal ?? "refused")")
        }
        return parts.joined(separator: "; ")
    }

    private func startScan() {
        scansStarted += 1
        let source = source, cacheURL = cacheURL, memory = cache, store = store
        let extra = pendingCacheEntries
        pendingCacheEntries = []
        var maintenance: (store: RoadPackStore, inbox: URL?)?
        if let store, !maintenanceStarted {
            maintenanceStarted = true
            maintenance = (store, inbox)
        }
        let launch = maintenance
        scanTask = Task(priority: .utility) { [self] in
            let result = await Task.detached(priority: .utility) {
                Self.perform(source: source, cacheURL: cacheURL, memory: memory, extra: extra, store: store,
                             maintenance: launch)
            }.value
            finish(result)
        }
    }

    private func finish(_ result: ScanResult) {
        if let report = result.maintenance { maintenanceReport = report }
        var result = result
        result.packs += (maintenanceReport?.inboxRefused ?? []).map {
            PackStatus(name: $0.fileName, verified: false, refusal: $0.reason, sizeBytes: nil, osmTimestamp: nil,
                       hashPrefix: nil, cacheHit: false, verifySeconds: nil, inInbox: true)
        }
        latest = result
        cache = result.cache
        scansCompleted += 1
        verifications += result.verifications
        scanTask = nil
        let ready = waiters.filter { $0.target <= scansCompleted }
        waiters.removeAll { $0.target <= scansCompleted }
        for waiter in ready { waiter.continuation.resume(returning: result.packs) }
        if rescanQueued {
            rescanQueued = false
            startScan()
        }
    }

    /// The scan itself: off every actor. With `maintenance`, the store's
    /// launch maintenance runs first, before the source is listed.
    private nonisolated static func perform(source: Source, cacheURL: URL?, memory: RoadPackVerificationCache?,
                                            extra: [RoadPackVerificationCache.Entry], store: RoadPackStore?,
                                            maintenance: (store: RoadPackStore, inbox: URL?)?) -> ScanResult {
        let report = maintenance.map { $0.store.launchMaintenance(inbox: $0.inbox) }
        var old = memory
        if old == nil, let cacheURL, let data = try? Data(contentsOf: cacheURL) {
            old = RoadPackVerificationCache(data: data)
        }
        let loaded = old ?? RoadPackVerificationCache()
        var known = loaded
        // The installer's verifications: the stored files are cache hits.
        for entry in extra + (report?.cacheEntries ?? []) { known.store(entry.verification, for: entry.identity) }
        let catalog = RoadPackCatalog(urls: source(), cache: known)
        let selection = RoadPackSelection.candidates(from: catalog.entries)
        if let cacheURL, catalog.cache != loaded {
            try? catalog.cache.encoded().write(to: cacheURL, options: .atomic)
        }
        var reasons: [String: String] = [:]
        for refusal in selection.refused {
            for name in refusal.names where reasons[name] == nil { reasons[name] = refusal.reason }
        }
        var packs = catalog.entries.map { entry -> PackStatus in
            let name = entry.url.lastPathComponent
            let reason = reasons[name] ?? entry.refusal
            return PackStatus(
                name: name, verified: reason == nil, refusal: reason,
                sizeBytes: entry.identity?.size,
                osmTimestamp: entry.verification?.osmTimestamp,
                hashPrefix: entry.verification?.contentHash.map { String($0.prefix(8)) },
                cacheHit: entry.cacheHit, verifySeconds: entry.verification?.verifySeconds,
                packName: RoadPackStoreRules.parseFileName(name)?.name,
                bounds: entry.verification?.bounds, hasCoverage: entry.verification?.hasCoverage)
        }
        var storeBytes: Int64?
        if let store {
            let listing = store.list()
            storeBytes = listing.totalBytes
            let marked = RoadPackStoreRules.activeSet(listing.installedFiles).markedForRemoval
            for file in marked {
                let stored = listing.files.first { $0.file.fileName == file.fileName }
                packs.append(PackStatus(
                    name: file.fileName, verified: false, refusal: removalPendingText,
                    sizeBytes: stored?.sizeBytes, osmTimestamp: file.osmTimestamp,
                    hashPrefix: String(file.contentHash.prefix(8)), cacheHit: false, verifySeconds: nil,
                    packName: file.name, pendingRemoval: true))
            }
        }
        // The coverage each candidate already carries (`COVR` from the file,
        // else the verification's bounding box): no pass over the points.
        let coverages = selection.candidates.map {
            InstalledPackCoverage(name: RoadPackStoreRules.parseFileName($0.name)?.name ?? $0.name, coverage: $0.coverage)
        }
        return ScanResult(packs: packs, candidates: Candidates(candidates: selection.candidates, refused: selection.refused),
                          coverages: coverages, cache: catalog.cache,
                          verifications: catalog.entries.filter { !$0.cacheHit && $0.identity != nil }.count,
                          storeBytes: storeBytes, maintenance: report)
    }

    // MARK: Reading

    /// The packs found by the latest scan and whether one is running.
    func status() -> Status {
        Status(packs: latest?.packs ?? [], scanning: scanTask != nil, scansCompleted: scansCompleted,
               storeBytes: latest?.storeBytes)
    }

    /// The usable candidates. Awaits a scan in progress (starting the first
    /// one if none has run), so a caller never sees a half-verified list,
    /// and never a pack before launch maintenance has finished.
    func candidates() async -> Candidates {
        if latest == nil && scanTask == nil { startScan() }
        if let task = scanTask { await task.value }
        return latest?.candidates ?? Candidates()
    }

    /// The verified active packs' coverages, by pack name (the at-a-stop
    /// offer, UX-8: `PackOfferRule.Input.installed`). Built once per scan
    /// from the candidates that scan opened anyway (`COVR`, else the cached
    /// bounding box), so a call is an actor hop and a copy: cheap at 1 Hz.
    /// Before the first scan it awaits it, starting it if none runs (as
    /// `candidates()` does: launch maintenance first, no other mapping);
    /// afterwards it answers at once with the latest finished scan's list,
    /// never waiting for a rescan in progress. Refused files and packs
    /// pending removal are not in it.
    func coverages() async -> [InstalledPackCoverage] {
        if latest == nil {
            if scanTask == nil { startScan() }
            if let task = scanTask { await task.value }
        }
        return latest?.coverages ?? []
    }

    /// Returns once the first scan (with a store: launch maintenance) has
    /// finished, starting it if none has.
    private func firstScanFinished() async {
        while scansCompleted == 0 {
            if scanTask == nil { startScan() }
            if let task = scanTask { await task.value }
        }
    }

    // MARK: Changing the store

    /// Removes every installed file of pack `name` (Settings → Maps).
    /// If a Navigate or Record run is active (`setRunActivity`; unknown
    /// counts as active), it may have them mapped: they are marked
    /// (`RoadPackStoreRules.filesToMark`), drop out of the active set at
    /// the rescan this starts and are deleted at the next launch; status
    /// shows them `pendingRemoval`. Otherwise they are deleted now. Either
    /// way a rescan follows and has finished when this returns.
    /// Unlinking a mapped file would not corrupt the mapping (only a write
    /// or truncation does), but deleting only between runs keeps one rule.
    /// Waits for the first scan (launch maintenance).
    @discardableResult
    func remove(name: String) async -> RemoveOutcome {
        guard let store else { return .notInstalled }
        await firstScanFinished()
        let runActive = await runActivity?() ?? true
        // No await between the listing and the change: two removes run one
        // after the other on this actor.
        let files = RoadPackStoreRules.filesToMark(removingName: name, in: store.list().installedFiles)
        guard !files.isEmpty else { return .notInstalled }
        let outcome: RemoveOutcome
        if runActive {
            do {
                try store.mark(files)
                outcome = .removalPending(files)
            } catch {
                outcome = .failed("cannot mark for removal: \(error.localizedDescription)")
            }
        } else {
            let failures = store.delete(files)
            outcome = failures.isEmpty ? .deleted(files) : .failed(failures.joined(separator: "; "))
        }
        await rescan()
        return outcome
    }

    /// Installs a pack file from outside the store (a finished download,
    /// prompt 25) through `RoadPackInstaller`, off this actor; clears a
    /// removal mark of the stored file, so the pack is offered again, and
    /// keeps the verification for the next scan (a cache hit). Never
    /// overwrites a stored file; never deletes one. A rescan follows and
    /// has finished when this returns. Waits for the first scan.
    /// `expectedContentHash` (the manifest's) is checked against the verified
    /// header before the rename; nil (the inbox path) accepts any.
    func install(from source: URL, name: String, expectedContentHash: String? = nil) async -> RoadPackInstaller.Outcome {
        guard let store else { return .refused("no road pack store") }
        await firstScanFinished()
        let installer = store.installer
        let outcome = await Task.detached(priority: .utility) { installer.install(from: source, name: name, expectedContentHash: expectedContentHash) }.value
        if let pack = outcome.installed {
            if let entry = pack.cacheEntry { pendingCacheEntries.append(entry) }
            try? store.unmark(pack.fileName)
            await rescan()
        }
        return outcome
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
    /// Files (UIFileSharingEnabled): the developer inbox
    /// (`scripts/push_packs.sh`). Launch maintenance installs what it holds
    /// into the store and empties it; no pack is ever mapped from here.
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

    /// The app's library: the store in `Application Support/RoadPacks/`,
    /// the developer inbox and the persisted cache.
    static func makeDefault() -> RoadPackLibrary {
        RoadPackLibrary(store: RoadPackStore(directory: RoadPackStore.defaultDirectory()),
                        inbox: documentsDirectory(), cacheURL: defaultCacheURL())
    }
}
