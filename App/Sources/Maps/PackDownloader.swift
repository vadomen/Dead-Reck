import CryptoKit
import DriveLoggerCore
import Foundation

/// Downloads road packs from the manifest into the store (UX-8,
/// docs/BACKLOG_UX.md; prompt 25). One download at a time, the others queue.
///
/// **Per pack.** Bytes go to `.download-<name>-<hash>.part` in the store
/// directory with a metadata sidecar (URL, ETag, size, SHA-256; Core's names
/// and `PartialMetadata`), written in chunks as they arrive, so a kill leaves
/// a usable partial. `PackDownloadRules.plan` chooses fresh / resume (`Range`,
/// `If-Range`) / verify-only; `decide` judges the response (`PackTransfer`).
/// A partial whose metadata does not `match` the manifest pack is discarded.
/// A `restartWithoutRange` answer deletes the partial and retries once
/// without `Range`; a second one fails the attempt.
///
/// **After the last byte:** SHA-256 of the file (streaming, `.utility`);
/// a mismatch deletes partial and metadata and fails with "checksum
/// mismatch". Then the install goes through `RoadPackLibrary.install` with
/// the manifest's content hash, so a pack whose header hash differs is
/// refused before anything is stored. The partial and its metadata are
/// deleted after the install, whatever its outcome. A stored `.roadpack` is
/// never overwritten or deleted here (the installer guarantees it).
///
/// **Network policy.** `PackDownloadRules.networkState(connection:
/// cellularAllowed:recordActive:)` decides whether a download may run; the
/// session also gets `allowsCellularAccess` and `allowsExpensiveNetworkAccess`
/// from the cellular switch. While it is not `.allowed`, queued packs show
/// the waiting state and the running one is stopped (partial kept); when it
/// turns `.allowed` again the queue resumes by itself. Record pauses
/// downloads (Navigate does not): the running request and any hashing are
/// cancelled, and no hashing or install starts while Record is active.
///
/// Plain GETs only: no coordinates, no device or user identifiers.
actor PackDownloader {
    enum State: Hashable, Sendable {
        case queued
        case waitingForWiFi
        case offline
        case pausedForRecording
        case downloading(received: Int64, total: Int64)
        /// Hashing and installing.
        case verifying
        case failed(String)

        /// Queued, waiting, running or paused: Cancel applies.
        var isActive: Bool {
            if case .failed = self { return false }
            return true
        }
    }

    struct Job: Sendable, Hashable {
        var pack: PackManifest.Pack
        var isUpdate: Bool
    }

    struct Snapshot: Sendable, Equatable {
        var states: [String: State] = [:]
        /// Packs installed as an update while a Navigate or Record run was
        /// active: used from the next session start.
        var updatedForNextStart: Set<String> = []
        /// The path monitor's latest connection (Settings → Maps shows
        /// "Offline" from it, whatever the age of the cached list).
        var connection: PackDownloadRules.Connection = .unmetered
    }

    private enum Stop { case pause, cancel, network }

    private struct Running {
        var job: Job
        var transfer: PackTransfer?
        var hashTask: Task<Result<String?, Error>, Never>?
        var stop: Stop?
    }

    private let directory: URL
    private let library: RoadPackLibrary
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    private let runActive: @Sendable () async -> Bool
    /// `sha256(of:)` in the app; tests slow it down to pause mid-hash.
    private let hash: @Sendable (URL) throws -> String?

    private var queue: [Job] = []
    private var running: Running?
    private var states: [String: State] = [:]
    private var updatedForNextStart: Set<String> = []
    private var connection: PackDownloadRules.Connection
    private var cellularAllowed: Bool
    private var recordActive = false
    private var pumping: Task<Void, Never>?
    /// Finished or stopped runs (tests wait on it).
    private(set) var finishedRuns = 0

    /// - Parameters:
    ///   - directory: the store directory (partials live next to the packs).
    ///   - makeConfiguration: the URL session configuration; tests add a
    ///     `URLProtocol`. The cellular flags are set on top of it.
    ///   - runActive: whether a Navigate or Record run is active (for the
    ///     "used from the next start" note), as for `RoadPackLibrary`.
    ///   - hash: the file's SHA-256, nil when cancelled (`sha256(of:)`);
    ///     run detached at `.utility`. Tests only.
    init(directory: URL, library: RoadPackLibrary, connection: PackDownloadRules.Connection = .none,
         cellularAllowed: Bool = false,
         makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration = PackDownloader.defaultConfiguration,
         runActive: @escaping @Sendable () async -> Bool = { false },
         hash: @escaping @Sendable (URL) throws -> String? = { try PackDownloader.sha256(of: $0) }) {
        self.directory = directory
        self.library = library
        self.connection = connection
        self.cellularAllowed = cellularAllowed
        self.makeConfiguration = makeConfiguration
        self.runActive = runActive
        self.hash = hash
    }

    @Sendable
    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        return configuration
    }

    // MARK: Reading

    func snapshot() -> Snapshot {
        var current = states
        if let running, case .downloading(_, let total)? = states[running.job.pack.name],
           let transfer = running.transfer {
            current[running.job.pack.name] = .downloading(received: transfer.receivedBytes, total: total)
        }
        return Snapshot(states: current, updatedForNextStart: updatedForNextStart, connection: connection)
    }

    var isIdle: Bool { running == nil && queue.isEmpty }

    // MARK: Commands

    /// Queues `pack` (a new download, a retry after a failure or an update).
    /// Ignored while it is already queued or running.
    func start(_ pack: PackManifest.Pack, isUpdate: Bool = false) {
        let name = pack.name
        if running?.job.pack.name == name || queue.contains(where: { $0.pack.name == name }) { return }
        guard PackPartialFiles(directory: directory, pack: pack) != nil else {
            states[name] = .failed("invalid pack name")
            return
        }
        updatedForNextStart.remove(name)
        queue.append(Job(pack: pack, isUpdate: isUpdate))
        states[name] = .queued
        pump()
    }

    /// Stops and forgets a download: partial and metadata are deleted. A
    /// failed one is just cleared.
    func cancel(name: String) {
        if var run = running, run.job.pack.name == name {
            run.stop = .cancel
            run.transfer?.cancel()
            run.hashTask?.cancel()
            running = run
            return
        }
        if let index = queue.firstIndex(where: { $0.pack.name == name }) {
            let job = queue.remove(at: index)
            PackPartialFiles(directory: directory, pack: job.pack)?.delete()
        }
        states[name] = nil
    }

    func setConnection(_ value: PackDownloadRules.Connection) {
        connection = value
        networkChanged()
    }

    func setCellularAllowed(_ value: Bool) {
        cellularAllowed = value
        networkChanged()
    }

    /// Record pauses downloads (Navigate does not).
    func setRecordActive(_ value: Bool) {
        recordActive = value
        if value, var run = running {
            run.stop = run.stop ?? .pause
            run.transfer?.cancel()
            run.hashTask?.cancel()
            running = run
        }
        networkChanged()
    }

    /// Waits until nothing runs or queues (tests).
    func waitUntilIdle() async {
        while true {
            if let pumping { await pumping.value }
            if running == nil, queue.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Scheduling

    private var policy: PackDownloadRules.NetworkState {
        PackDownloadRules.networkState(connection: connection, cellularAllowed: cellularAllowed, recordActive: recordActive)
    }

    private func waitingState(_ policy: PackDownloadRules.NetworkState) -> State {
        switch policy {
        case .allowed: .queued
        case .waitingForWiFi: .waitingForWiFi
        case .pausedForRecording: .pausedForRecording
        case .offline: .offline
        }
    }

    private func networkChanged() {
        if policy != .allowed, var run = running, run.stop == nil {
            run.stop = .network
            run.transfer?.cancel()
            running = run
        }
        pump()
    }

    private func pump() {
        let policy = self.policy
        for job in queue { states[job.pack.name] = waitingState(policy) }
        guard running == nil, policy == .allowed, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        running = Running(job: job)
        states[job.pack.name] = .downloading(received: 0, total: job.pack.size)
        // `.utility` whoever queued it (the UI): the download's file I/O
        // must not compete with a recording's writer.
        pumping = Task(priority: .utility) { [self] in
            await run(job)
            finishRun()
        }
        for other in queue { states[other.pack.name] = .queued }
    }

    private func finishRun() {
        running = nil
        finishedRuns += 1
        pumping = nil
        pump()
    }

    /// The job goes back to the head of the queue, to continue when allowed.
    private func requeue(_ job: Job) {
        queue.insert(job, at: 0)
        states[job.pack.name] = waitingState(policy)
    }

    private func setStopOutcome(_ job: Job, files: PackPartialFiles?) {
        let stop = running?.stop
        switch stop {
        case .cancel?:
            files?.delete()
            states[job.pack.name] = nil
        default:
            requeue(job)
        }
    }

    private func stopped() -> Bool { running?.stop != nil }

    private func fail(_ job: Job, _ reason: String) {
        states[job.pack.name] = .failed(reason)
    }

    // MARK: One pack

    private func run(_ job: Job) async {
        let pack = job.pack
        guard let files = PackPartialFiles(directory: directory, pack: pack) else {
            return fail(job, "invalid pack name")
        }
        do {
            try RoadPackStore.prepareDirectory(directory)
        } catch {
            return fail(job, "cannot create the store: \(error.localizedDescription)")
        }
        var restarted = false
        while true {
            if stopped() { return setStopOutcome(job, files: files) }
            let (plan, storedETag) = Self.prepare(files, pack: pack)
            var needsBody = true
            var request = URLRequest(url: pack.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.httpShouldHandleCookies = false
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            var offset: Int64?
            switch plan {
            case .fresh, .discardAndRestart:
                files.writeMetadata(PackDownloadRules.PartialMetadata(pack: pack, etag: nil))
                try? Data().write(to: files.partial)
            case .resume(let from, let ifRange):
                offset = from
                request.setValue("bytes=\(from)-", forHTTPHeaderField: "Range")
                if let ifRange { request.setValue(ifRange, forHTTPHeaderField: "If-Range") }
                files.writeMetadata(PackDownloadRules.PartialMetadata(pack: pack, etag: storedETag))
            case .verifyOnly:
                needsBody = false
            }

            if needsBody {
                let configuration = makeConfiguration()
                configuration.allowsCellularAccess = cellularAllowed
                configuration.allowsExpensiveNetworkAccess = cellularAllowed
                configuration.allowsConstrainedNetworkAccess = cellularAllowed
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                let transfer = PackTransfer(request: request, pack: pack, files: files, requestedOffset: offset,
                                            storedETag: storedETag, configuration: configuration)
                if stopped() { return setStopOutcome(job, files: files) }
                running?.transfer = transfer
                states[pack.name] = .downloading(received: offset ?? 0, total: pack.size)
                let result = await transfer.run()
                running?.transfer = nil
                switch result {
                case .completed:
                    break
                case .restart(let reason):
                    if restarted { return fail(job, "server: " + reason) }
                    restarted = true
                    files.delete()
                    continue
                case .failed(let reason):
                    return fail(job, reason)
                case .cancelled:
                    return setStopOutcome(job, files: files)
                case .transport(let message):
                    if stopped() { return setStopOutcome(job, files: files) }
                    return fail(job, message)
                }
                if stopped() { return setStopOutcome(job, files: files) }
            }

            // The last byte is in.
            let bytes = files.partialBytes() ?? 0
            if bytes > pack.size {
                files.delete()
                return fail(job, "more bytes than the manifest says")
            }
            if bytes < pack.size { return fail(job, "incomplete download") }
            await verifyAndInstall(job, files: files)
            return
        }
    }

    /// What to do with whatever is on disk: discards a partial the manifest
    /// no longer describes, then asks Core's `plan`.
    private static func prepare(_ files: PackPartialFiles, pack: PackManifest.Pack)
        -> (PackDownloadRules.Plan, String?) {
        var bytes = files.partialBytes()
        var metadata = files.readMetadata()
        if let found = metadata, !found.matches(pack) {
            files.delete()
            bytes = nil
            metadata = nil
        }
        let plan = PackDownloadRules.plan(partialBytes: bytes, expectedSize: pack.size, storedETag: metadata?.etag)
        if plan == .discardAndRestart {
            files.delete()
            return (.fresh, nil)
        }
        return (plan, metadata?.etag)
    }

    private func verifyAndInstall(_ job: Job, files: PackPartialFiles) async {
        let pack = job.pack
        // No hashing and no install while Record runs (they wait, paused).
        if recordActive || stopped() { return setStopOutcome(job, files: files) }
        states[pack.name] = .verifying
        let file = files.partial
        let hash = self.hash
        let hashTask = Task.detached(priority: .utility) { () -> Result<String?, Error> in
            Result { try hash(file) }
        }
        running?.hashTask = hashTask
        let hashed = await hashTask.value
        running?.hashTask = nil
        let digest: String
        switch hashed {
        case .failure(let error):
            return fail(job, "cannot read the file: \(error.localizedDescription)")
        case .success(nil):
            return setStopOutcome(job, files: files)
        case .success(let value?):
            digest = value
        }
        if stopped() { return setStopOutcome(job, files: files) }
        guard digest == pack.sha256 else {
            files.delete()
            return fail(job, "checksum mismatch")
        }
        if recordActive { return setStopOutcome(job, files: files) }
        let outcome = await library.install(from: files.partial, name: pack.name, expectedContentHash: pack.contentHash)
        files.delete()
        if outcome.installed != nil {
            states[pack.name] = nil
            if job.isUpdate, await runActive() { updatedForNextStart.insert(pack.name) }
        } else {
            fail(job, outcome.refusal ?? "refused")
        }
    }

    /// SHA-256 of a file in 1 MB chunks, lower-case hex; nil when the task
    /// was cancelled; throws when the file cannot be read.
    nonisolated static func sha256(of url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if Task.isCancelled { return nil }
            // `read` returns autoreleased data and this runs in one detached
            // job whose pool never drains: without the pool every chunk
            // stays alive until the hash ends (a 300 MB file peaked at 307 MB).
            let more: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }
            if !more { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
