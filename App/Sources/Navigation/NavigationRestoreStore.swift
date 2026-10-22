import DriveLoggerCore
import Foundation
import os

/// The saved estimate (UX-20) on disk: `Application Support/NavigationRestore/estimate.json`,
/// excluded from backup, `completeUntilFirstUserAuthentication`, replaced
/// atomically on every save. The bytes are Core's
/// (`NavigationRestoreState.encoded()` / `decode(_:)`); this type only
/// stores them.
///
/// - **One serial queue** does every encode, write, read and delete, in the
///   order they were asked for. `save` and `delete` return at once (the
///   navigation actor's hot path never waits for the disk); `load` and
///   `drain` wait for everything asked before them. So a `load` after a
///   `save` always sees that save: the Record → Navigate hand-over relies on
///   it (`NavigationService.restorePrior`).
/// - **Unreadable** (malformed, truncated, unknown version, a field out of
///   range): `load` deletes the file and returns `.discarded`; the run
///   starts fresh.
/// - **Nothing is logged.** No coordinate reaches the system log, a
///   recording or a sidecar; `Loaded.discarded` carries the decode error's
///   kind only.
///
/// Owned by the app's `NavigationService` (`AppServices`), which reads it
/// for Navigate runs only and writes it from every run (Record's too). The
/// demo's service and the services tests construct have none.
final class NavigationRestoreStore: Sendable {
    static let directoryName = "NavigationRestore"
    static let fileName = "estimate.json"

    /// What `load` found.
    enum Loaded: Sendable, Hashable {
        /// No saved estimate.
        case none
        case state(NavigationRestoreState)
        /// The file could not be restored from and was deleted; the reason
        /// names the decode error's kind, never a value.
        case discarded(String)
    }

    /// Work done so far (diagnostics and tests).
    struct Counts: Sendable, Hashable {
        var saves = 0
        var saveFailures = 0
        var loads = 0
        var deletes = 0
    }

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    private let queue = DispatchQueue(label: "DriveLogger.NavigationRestoreStore", qos: .userInitiated)
    private let countsLock = OSAllocatedUnfairLock(initialState: Counts())

    init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/NavigationRestore/` (created at the first save).
    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    var counts: Counts { countsLock.withLock { $0 } }

    /// Encodes and writes `state` on the store's queue; returns at once. A
    /// failure is counted (`Counts.saveFailures`) and leaves the previous
    /// file in place (atomic write).
    func save(_ state: NavigationRestoreState) {
        let directory = directory, url = fileURL, counts = countsLock
        queue.async {
            do {
                let data = try state.encoded()
                // Created (and marked excluded from backup) on every save:
                // cheap, and a directory removed meanwhile comes back.
                try RoadPackStore.prepareDirectory(directory)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                counts.withLock { $0.saves += 1 }
            } catch {
                counts.withLock { $0.saveFailures += 1 }
            }
        }
    }

    /// The saved state, after every `save` and `delete` asked before this
    /// call. An unreadable file is deleted (`.discarded`).
    func load() async -> Loaded {
        let url = fileURL, counts = countsLock
        return await withCheckedContinuation { continuation in
            queue.async {
                counts.withLock { $0.loads += 1 }
                guard let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: .none)
                    return
                }
                do throws(NavigationRestoreState.DecodeError) {
                    continuation.resume(returning: .state(try NavigationRestoreState.decode(data)))
                } catch {
                    Self.remove(url, counts: counts)
                    continuation.resume(returning: .discarded(Self.kind(of: error)))
                }
            }
        }
    }

    /// Deletes the saved state (a refused one, or a reset); returns at once.
    func delete() {
        let url = fileURL, counts = countsLock
        queue.async { Self.remove(url, counts: counts) }
    }

    /// Returns once everything asked before this call is done: the file is
    /// on disk after a `save` (the app's flush on background awaits it).
    func drain() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private static func remove(_ url: URL, counts: OSAllocatedUnfairLock<Counts>) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        counts.withLock { $0.deletes += 1 }
    }

    /// The decode error's kind, without the decoder's text (which may quote
    /// the file).
    private static func kind(of error: NavigationRestoreState.DecodeError) -> String {
        switch error {
        case .malformed: "malformed"
        case .unsupportedVersion(let version): "unsupported version \(version)"
        case .invalid(let field): "invalid \(field)"
        }
    }
}

/// The phone's boot session (UX-20, `NavigationRestoreState.bootSessionID`):
/// with the same boot the restore's age is bounded below by uptime, so a
/// wall clock set back cannot make a saved estimate look younger.
enum BootSession {
    /// `kern.bootsessionuuid`; nil when the sysctl is unavailable (the age
    /// then uses the wall clock alone). Read once per process: it cannot
    /// change without a reboot.
    static let current: String? = read()

    private static func read() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size <= 128 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        // `NavigationRestoreState` accepts 1…64 characters.
        return (1...64).contains(value.count) ? value : nil
    }
}
