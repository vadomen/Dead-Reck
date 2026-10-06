import DriveLoggerCore
import Foundation

/// A recording on disk, as the sessions list shows it.
struct RecordingFile: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let sizeBytes: Int
    /// Header wall clock (`startedAt`).
    let startedAt: Date?
    /// Last event timestamp; nil if the file could not be read.
    let duration: TimeInterval?
}

/// `Documents/logs`, visible in the Files app. Implemented in M2.
struct LogStore: Sendable {
    let directory: URL

    /// The app's `Documents/logs`, created if missing.
    static func documents() throws -> LogStore {
        fatalError("M2: LogStore.documents")
    }

    /// URL for a new recording named with `LogFileName`.
    func newFileURL(startingAt start: Date, timeZone: TimeZone) -> URL {
        fatalError("M2: LogStore.newFileURL")
    }

    /// Newest first.
    func list() throws -> [RecordingFile] {
        fatalError("M2: LogStore.list")
    }

    func delete(_ file: RecordingFile) throws {
        fatalError("M2: LogStore.delete")
    }
}
