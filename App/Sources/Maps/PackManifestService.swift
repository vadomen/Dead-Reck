import DriveLoggerCore
import Foundation

/// The road pack manifest for Settings → Maps (UX-8, docs/BACKLOG_UX.md;
/// prompt 25): fetches `https://fugps.pages.dev/packs/manifest.json`, keeps
/// the last good copy on disk so Maps works offline, and clears partial
/// downloads the new manifest no longer lists.
///
/// - The fetch is a plain `GET`: ephemeral session, no cookies, no cache, no
///   query, no extra headers, nothing that names the device or the user. The
///   manifest is small (~16 KB), so it is fetched on any network.
/// - Parsing and validation are Core's (`PackManifest.parse`). A response
///   that does not parse leaves the cached manifest in place.
/// - The cache is `Application Support/PackManifestCache.json` (the raw
///   bytes and the fetch time), outside the `RoadPacks/` store directory.
/// - It is fetched when Maps opens and `PackManifest.needsRefresh`, and on
///   pull to refresh (`force`). Never at launch.
/// - On applying a fresh manifest the store directory's stale partials
///   (`RoadPackStoreRules.stalePartials`) are deleted; a `.roadpack` is never
///   touched.
actor PackManifestService {
    static let manifestURL = URL(string: "https://fugps.pages.dev/packs/manifest.json")!
    static let cacheFileName = "PackManifestCache.json"
    /// A manifest larger than this is refused (the real one is ~16 KB).
    static let maxBytes = 2_000_000

    typealias Fetch = @Sendable (URL) async throws -> Data

    /// How the latest refresh went.
    enum Refresh: Hashable, Sendable {
        /// No refresh since launch.
        case idle
        case ok
        /// Failed; `offline` when the cause is no network. The cached list
        /// stays.
        case failed(offline: Bool)
    }

    struct Snapshot: Sendable, Equatable {
        var manifest: PackManifest?
        var fetchedAt: Date?
        var refresh: Refresh = .idle
    }

    private struct Envelope: Codable {
        var fetchedAt: Double
        var manifest: Data
    }

    private let cacheURL: URL
    private let storeDirectory: URL?
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private var snapshotValue = Snapshot()
    private var inflight: Task<Void, Never>?

    /// - Parameters:
    ///   - cacheDirectory: where the cache file lives (Application Support).
    ///   - storeDirectory: the road pack store, for stale partials; nil skips.
    init(cacheDirectory: URL, storeDirectory: URL?, fetch: @escaping Fetch = PackManifestService.defaultFetch,
         now: @escaping @Sendable () -> Date = { Date() }) {
        cacheURL = cacheDirectory.appendingPathComponent(Self.cacheFileName)
        self.storeDirectory = storeDirectory
        self.fetch = fetch
        self.now = now
    }

    /// The app's service: cache in Application Support, store partials.
    static func makeDefault() -> PackManifestService {
        PackManifestService(cacheDirectory: RoadPackLibrary.defaultCacheURL().deletingLastPathComponent(),
                            storeDirectory: RoadPackStore.defaultDirectory())
    }

    func snapshot() -> Snapshot { snapshotValue }

    /// Reads the cache (launch). Does not touch the network or the store.
    func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let manifest = try? PackManifest.parse(data: envelope.manifest, manifestURL: Self.manifestURL)
        else { return }
        snapshotValue.manifest = manifest
        snapshotValue.fetchedAt = Date(timeIntervalSince1970: envelope.fetchedAt)
    }

    /// Fetches when `force` or the cached copy is due (`needsRefresh`).
    /// Concurrent calls share one fetch.
    func refresh(force: Bool) async {
        if let inflight { await inflight.value; return }
        guard force || PackManifest.needsRefresh(fetchedAt: snapshotValue.fetchedAt, now: now()) else { return }
        let task = Task { await self.fetchAndApply() }
        inflight = task
        await task.value
        inflight = nil
    }

    private func fetchAndApply() async {
        do {
            let data = try await fetch(Self.manifestURL)
            guard data.count <= Self.maxBytes else { throw FetchError.tooLarge }
            let manifest = try PackManifest.parse(data: data, manifestURL: Self.manifestURL)
            let fetchedAt = now()
            let envelope = Envelope(fetchedAt: fetchedAt.timeIntervalSince1970, manifest: data)
            if let encoded = try? JSONEncoder().encode(envelope) { try? encoded.write(to: cacheURL, options: .atomic) }
            snapshotValue = Snapshot(manifest: manifest, fetchedAt: fetchedAt, refresh: .ok)
            deleteStalePartials(manifest)
        } catch {
            snapshotValue.refresh = .failed(offline: Self.isOffline(error))
        }
    }

    /// Partial downloads and their metadata the manifest does not list; a
    /// `.roadpack` is never touched (`stalePartials` only names download
    /// files).
    private func deleteStalePartials(_ manifest: PackManifest) {
        guard let storeDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: storeDirectory.path) else { return }
        for name in RoadPackStoreRules.stalePartials(fileNames: names, manifest: manifest) {
            try? FileManager.default.removeItem(at: storeDirectory.appendingPathComponent(name))
        }
    }

    enum FetchError: Error { case badStatus(Int), tooLarge }

    static func isOffline(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        switch url.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
             .cannotFindHost, .cannotConnectToHost, .timedOut, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    /// A plain GET on an ephemeral session.
    @Sendable
    static func defaultFetch(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw FetchError.badStatus(http.statusCode) }
        return data
    }
}
