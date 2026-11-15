import Foundation
import Observation

/// Recent destinations (at most 10, newest first, de-duplicated) and the
/// pinned Home and Work (prompt 52 item 6, decision D5). On the device only,
/// in Application Support, no sync. Never written to a log, to analytics or
/// to the pasteboard: nothing outside this file reads `fileURL`.
@MainActor
@Observable
final class SavedDestinationsStore {
    static let maxRecents = 10
    static let fileName = "saved-destinations.json"

    private(set) var recents: [RoutePlace] = []
    private(set) var home: RoutePlace?
    private(set) var work: RoutePlace?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private(set) var lastWriteFailed = false

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    private struct Stored: Codable {
        var recents: [RoutePlace]
        var home: RoutePlace?
        var work: RoutePlace?
    }

    /// `directory` is injected: Application Support in the app, a temporary
    /// directory in tests. A missing or unreadable file is an empty store.
    init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: fileURL), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            recents = Array(stored.recents.filter(\.isValid).prefix(Self.maxRecents))
            home = stored.home.flatMap { $0.isValid ? $0 : nil }
            work = stored.work.flatMap { $0.isValid ? $0 : nil }
        }
    }

    /// Application Support/Destinations (created on the first write).
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Destinations", isDirectory: true)
    }

    /// Previews: nothing on disk.
    static func preview(recents: [RoutePlace] = [], home: RoutePlace? = nil, work: RoutePlace? = nil) -> SavedDestinationsStore {
        let store = SavedDestinationsStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-destinations-\(UUID().uuidString)", isDirectory: true))
        store.recents = recents
        store.home = home
        store.work = work
        return store
    }

    /// The place was routed to (or the driver kept it): it goes to the top, a
    /// copy of it further down goes away, the list stays at `maxRecents`.
    func addRecent(_ place: RoutePlace) {
        guard place.isValid else { return }
        var list = recents.filter { $0.dedupKey != place.dedupKey }
        list.insert(place, at: 0)
        recents = Array(list.prefix(Self.maxRecents))
        save()
    }

    func setHome(_ place: RoutePlace?) {
        home = place
        save()
    }

    func setWork(_ place: RoutePlace?) {
        work = place
        save()
    }

    func removeRecent(_ place: RoutePlace) {
        recents.removeAll { $0.dedupKey == place.dedupKey }
        save()
    }

    func clearRecents() {
        recents = []
        save()
    }

    var isEmpty: Bool { recents.isEmpty && home == nil && work == nil }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Stored(recents: recents, home: home, work: work))
            // Readable after the first unlock: a background save while the phone is locked works.
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            lastWriteFailed = false
        } catch {
            lastWriteFailed = true
        }
    }
}
