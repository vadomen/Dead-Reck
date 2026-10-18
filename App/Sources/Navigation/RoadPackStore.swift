import DriveLoggerCore
import Foundation

/// The app's road pack store (N3.4, docs/N3_PLAN.md "N3.4";
/// docs/BACKLOG_UX.md UX-8): `Application Support/RoadPacks/`, excluded
/// from backup. It carries out Core's `RoadPackStoreRules` on the file
/// system; the rules (file names, the active file per name, what launch
/// deletes) live there and are not repeated here.
///
/// - **Files.** `<name>-<contentHash>.roadpack`, written only by
///   `RoadPackInstaller` (copy to a temporary name, verify, rename). A pack
///   file is never overwritten or truncated.
/// - **Install time** is the file's creation date: the installer sets it on
///   its copy and the rename keeps it. A file without one (another file
///   system) falls back to its modification date. No extra record to keep
///   in step with the files.
/// - **Removal marks** live in `RoadPackStoreState.json` next to the packs
///   (`{"markedForRemoval":[<file name>…],"version":1}`). A marked file is
///   never active and is deleted by the next `launchMaintenance`.
/// - **Deletion** happens in `launchMaintenance` (launch, before any
///   session maps a pack) and in `RoadPackLibrary.remove(name:)` when no
///   Navigate or Record run is active. Nothing else deletes a pack file.
///
/// Every method is synchronous file I/O: call it off the main actor.
/// `RoadPackLibrary` serialises the calls that change the store (the first
/// scan; `remove`, `install`, which wait for it).
struct RoadPackStore: Sendable {
    static let directoryName = "RoadPacks"
    static let stateFileName = "RoadPackStoreState.json"

    let directory: URL
    /// The installer's size limit (tests lower it).
    let maxInstallBytes: Int64

    init(directory: URL, maxInstallBytes: Int64 = RoadPackInstaller.defaultMaxBytes) {
        self.directory = directory
        self.maxInstallBytes = maxInstallBytes
    }

    var stateURL: URL { directory.appendingPathComponent(Self.stateFileName) }

    var installer: RoadPackInstaller { RoadPackInstaller(storeDirectory: directory, maxBytes: maxInstallBytes) }

    /// `Application Support/RoadPacks/` (not created here).
    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Creates `directory` if missing and marks it excluded from backup
    /// (packs are re-downloadable and large).
    static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    // MARK: Listing

    /// One pack file in the store.
    struct StoredFile: Sendable, Hashable {
        var file: RoadPackStoreRules.InstalledFile
        var url: URL
        var sizeBytes: Int64
    }

    /// The store directory now: its pack files (with their marks) and the
    /// names of every other entry (temporary files, the state file).
    struct Listing: Sendable, Hashable {
        var files: [StoredFile] = []
        var otherFileNames: [String] = []

        var installedFiles: [RoadPackStoreRules.InstalledFile] { files.map(\.file) }

        /// Bytes of every regular file in the directory (packs, leftovers,
        /// the state file): what the store takes on the phone.
        var totalBytes: Int64 = 0

        func url(of fileName: String) -> URL? { files.first { $0.file.fileName == fileName }?.url }
    }

    func list() -> Listing {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [])) ?? []
        let marks = markedFileNames()
        var listing = Listing()
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            let regular = values?.isRegularFile == true
            let size = Int64(values?.fileSize ?? 0)
            if regular { listing.totalBytes += size }
            let installTime = (values?.creationDate ?? values?.contentModificationDate)?.timeIntervalSince1970 ?? 0
            guard regular, let file = RoadPackStoreRules.InstalledFile(
                fileName: name, osmTimestamp: Self.osmTimestamp(of: url), installTime: installTime,
                markedForRemoval: marks.contains(name)) else {
                listing.otherFileNames.append(name)
                continue
            }
            listing.files.append(StoredFile(file: file, url: url, sizeBytes: size))
        }
        return listing
    }

    /// The header's `osmTimestamp`; 0 (older than any known one) when the
    /// header does not open. Opens the header only (no verification).
    static func osmTimestamp(of url: URL) -> Int64 {
        (try? RoadPack(contentsOf: url, verify: false))?.osmTimestamp ?? 0
    }

    /// The active file per pack name (`RoadPackStoreRules.activeSet`), by
    /// file name: the library's source.
    func activeURLs() -> [URL] {
        let listing = list()
        let active = Set(RoadPackStoreRules.activeSet(listing.installedFiles).active.map(\.fileName))
        return listing.files.filter { active.contains($0.file.fileName) }.map(\.url)
    }

    /// `activeURLs` as a `RoadPackLibrary.Source`.
    var source: RoadPackLibrary.Source {
        let store = self
        return { store.activeURLs() }
    }

    // MARK: Removal marks

    private struct State: Codable {
        var version = 1
        var markedForRemoval: [String] = []
    }

    /// File names marked for removal; empty when the state file is missing
    /// or unreadable (nothing is deleted on a guess).
    func markedFileNames() -> Set<String> {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return [] }
        return Set(state.markedForRemoval)
    }

    private func writeMarks(_ names: Set<String>) throws {
        if names.isEmpty {
            if FileManager.default.fileExists(atPath: stateURL.path) { try FileManager.default.removeItem(at: stateURL) }
            return
        }
        try Self.prepareDirectory(directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(State(markedForRemoval: names.sorted())).write(to: stateURL, options: .atomic)
    }

    /// Marks `fileNames` for removal at the next launch.
    func mark(_ fileNames: [String]) throws {
        try writeMarks(markedFileNames().union(fileNames))
    }

    /// Clears a mark (the same file was installed again). No-op when unmarked.
    func unmark(_ fileName: String) throws {
        let marks = markedFileNames()
        guard marks.contains(fileName) else { return }
        try writeMarks(marks.subtracting([fileName]))
    }

    // MARK: Deleting

    /// Deletes `fileNames` from the store directory and drops their marks.
    /// **Callers:** `launchMaintenance`, and `RoadPackLibrary.remove(name:)`
    /// when no Navigate or Record run is active. Returns a failure text per
    /// file that could not be deleted.
    @discardableResult
    func delete(_ fileNames: [String]) -> [String] {
        var failures: [String] = []
        for name in fileNames {
            let url = directory.appendingPathComponent(name)
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        let marks = markedFileNames()
        let remaining = marks.subtracting(fileNames)
        if remaining != marks {
            do { try writeMarks(remaining) } catch { failures.append("marks: \(error.localizedDescription)") }
        }
        return failures
    }

    // MARK: Launch

    /// A file left in the developer inbox because it was refused.
    struct InboxRefusal: Sendable, Hashable {
        let fileName: String
        let reason: String
    }

    /// What `launchMaintenance` did.
    struct MaintenanceReport: Sendable, Hashable {
        /// Store file names newly installed from the inbox.
        var installed: [String] = []
        /// Store file names an inbox file turned out to be already.
        var alreadyInstalled: [String] = []
        /// Inbox files refused (left in place).
        var inboxRefused: [InboxRefusal] = []
        /// Store files deleted (superseded, marked, leftover temporaries).
        var deleted: [String] = []
        /// Anything that went wrong besides a refusal: a delete, the inbox
        /// file's removal, the store directory.
        var failures: [String] = []
        /// Verifications of the newly installed files, for the cache.
        var cacheEntries: [RoadPackVerificationCache.Entry] = []
    }

    /// **Launch only, before any session maps a pack**
    /// (`RoadPackLibrary` runs it as the first step of its first scan):
    /// 1. installs every `*.roadpack` in `inbox` (the developer inbox,
    ///    `Documents/RoadPacks/`; pack name from
    ///    `RoadPackStoreRules.inboxName`) with the installer, deleting the
    ///    inbox file after `installed` or `alreadyInstalled` and clearing a
    ///    removal mark of the stored file (pushing a pack again means
    ///    wanting it). A refused file stays in the inbox, reported;
    /// 2. deletes what `RoadPackStoreRules.launchCleanup` says: superseded
    ///    and marked pack files and leftover temporary files.
    func launchMaintenance(inbox: URL?) -> MaintenanceReport {
        var report = MaintenanceReport()
        do {
            try Self.prepareDirectory(directory)
        } catch {
            report.failures.append("store: \(error.localizedDescription)")
        }
        if let inbox {
            let installer = installer
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where url.pathExtension == RoadPackStoreRules.fileExtension {
                let fileName = url.lastPathComponent
                guard let name = RoadPackStoreRules.inboxName(fromFileName: fileName) else {
                    report.inboxRefused.append(InboxRefusal(
                        fileName: fileName, reason: "invalid pack name (a–z, 0–9, _ and -; no leading or trailing -)"))
                    continue
                }
                let outcome = installer.install(from: url, name: name)
                switch outcome {
                case .installed(let pack):
                    report.installed.append(pack.fileName)
                    if let entry = pack.cacheEntry { report.cacheEntries.append(entry) }
                case .alreadyInstalled(let pack):
                    report.alreadyInstalled.append(pack.fileName)
                case .refused(let reason):
                    report.inboxRefused.append(InboxRefusal(fileName: fileName, reason: reason))
                    continue
                }
                if let pack = outcome.installed {
                    do { try unmark(pack.fileName) } catch { report.failures.append("marks: \(error.localizedDescription)") }
                }
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    report.failures.append("inbox \(fileName): \(error.localizedDescription)")
                }
            }
        }
        let listing = list()
        let cleanup = RoadPackStoreRules.launchCleanup(listing.installedFiles, otherFileNames: listing.otherFileNames)
        report.failures += delete(cleanup.delete)
        report.deleted = cleanup.delete.filter { !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        // Marks of files that are gone (deleted by hand, or above).
        let present = Set(list().files.map(\.file.fileName))
        let marks = markedFileNames()
        if !marks.isSubset(of: present) {
            do { try writeMarks(marks.intersection(present)) } catch { report.failures.append("marks: \(error.localizedDescription)") }
        }
        return report
    }
}
