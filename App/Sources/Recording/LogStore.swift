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
    /// The navigation sidecar (`LogStore.navSidecarURL(for:)`) if it existed
    /// when the list was read; nil otherwise.
    let navSidecar: URL?

    init(url: URL, name: String, sizeBytes: Int, startedAt: Date?, duration: TimeInterval?, navSidecar: URL? = nil) {
        self.url = url
        self.name = name
        self.sizeBytes = sizeBytes
        self.startedAt = startedAt
        self.duration = duration
        self.navSidecar = navSidecar
    }

    /// What Export shares: the recording, then its sidecar when there is one.
    var shareItems: [URL] {
        [url] + (navSidecar.map { [$0] } ?? [])
    }
}

enum LogStoreError: Error, Hashable, Sendable, CustomStringConvertible {
    /// Only files directly inside the store's directory are deleted.
    case notInStore(path: String)
    /// The file is the recording being written right now.
    case recordingInProgress(path: String)

    var description: String {
        switch self {
        case .notInStore(let path): "not a recording in the logs folder: \(path)"
        case .recordingInProgress(let path): "\(path) is being recorded; stop the recording first"
        }
    }
}

/// `Documents/logs`, visible in the Files app (Info.plist sets
/// `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`).
///
/// Never overwrites: `newFileURL` returns a name that doesn't exist yet, and
/// `LogFileWriter` creates the file exclusively (`O_EXCL`) in any case, so a
/// race between the two can only fail a start, never truncate a recording.
///
/// **Navigation sidecar (N4 A).** `<name>.nav.jsonl` next to
/// `<name>.jsonl.gz` (`navSidecarURL(for:)`, the one definition of that path)
/// is a companion file, not a recording: `list()` never returns it, Export
/// shares it with its recording (`RecordingFile.shareItems`), and `delete`
/// removes it with its recording. The store never reads its contents.
struct LogStore: Sendable {
    let directory: URL

    /// `Documents/logs` of this app (not created).
    static var defaultDirectory: URL {
        URL.documentsDirectory.appending(path: "logs", directoryHint: .isDirectory)
    }

    /// The app's `Documents/logs`, created if missing.
    static func documents() throws -> LogStore {
        let store = LogStore(directory: defaultDirectory)
        try store.createDirectory()
        return store
    }

    func createDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// URL for a new recording named with `LogFileName`, using the first
    /// `collisionIndex` whose file doesn't exist yet. Never returns an existing
    /// file.
    func newFileURL(startingAt start: Date, timeZone: TimeZone) -> URL {
        var index = 1
        while true {
            let url = directory.appendingPathComponent(LogFileName.make(for: start, timeZone: timeZone, collisionIndex: index))
            // `lstat`, not `fileExists`: a dangling symlink is still a name
            // that `O_EXCL` would refuse.
            var info = stat()
            if lstat(url.path, &info) != 0 { return url }
            index += 1
        }
    }

    /// The navigation sidecar of `recording`: same folder, `.jsonl.gz`
    /// replaced by `.nav.jsonl` (`NavSidecarFile`). The path the
    /// NavigationService writes to and the one `delete` and Export use.
    static func navSidecarURL(for recording: URL) -> URL {
        NavSidecarFile.url(forRecording: recording)
    }

    /// Recordings (`*.jsonl.gz`) in the directory, newest first by header
    /// start time; files whose header can't be read sort last, by name.
    /// Sidecars are never listed; each recording carries its own in
    /// `navSidecar` when the file exists.
    ///
    /// Cheap per file: the header comes from the first gzip member and the
    /// duration from the last complete one (`RecordingTail`), so a two-hour
    /// drive is not decompressed to list it. Still file I/O: call it off the
    /// main actor for long lists.
    func list() throws -> [RecordingFile] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let files = urls.compactMap { url -> RecordingFile? in
            guard url.lastPathComponent.hasSuffix("." + LogFileName.fileExtension),
                  !NavSidecarFile.isSidecar(url),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { return nil }
            let header = try? LogFileReader(url: url).header
            let sidecar = Self.navSidecarURL(for: url)
            let sidecarIsFile = (try? sidecar.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            return RecordingFile(
                url: url,
                name: url.lastPathComponent,
                sizeBytes: values.fileSize ?? 0,
                startedAt: header?.startedAt,
                duration: header == nil ? nil : RecordingTail.lastEventTimestamp(of: url)?.seconds,
                navSidecar: sidecarIsFile ? sidecar : nil
            )
        }
        return files.sorted { a, b in
            switch (a.startedAt, b.startedAt) {
            case let (a?, b?) where a != b: a > b
            case (_?, nil): true
            case (nil, _?): false
            default: a.name > b.name
            }
        }
    }

    /// Deletes a recording in this store together with its navigation
    /// sidecar, if one exists now (whatever `file.navSidecar` says). Refuses
    /// anything outside the directory. (`RecordingSession.deleteRecording`
    /// also refuses the file being recorded and refreshes free space.)
    ///
    /// The sidecar goes first: if removing it fails, the recording is still
    /// listed and the user can retry. The other order could leave an
    /// unlisted sidecar — real positions nobody can see to delete.
    func delete(_ file: RecordingFile) throws {
        guard file.url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              file.url.lastPathComponent.hasSuffix("." + LogFileName.fileExtension),
              !NavSidecarFile.isSidecar(file.url)
        else {
            throw LogStoreError.notInStore(path: file.url.path)
        }
        do {
            try FileManager.default.removeItem(at: Self.navSidecarURL(for: file.url))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // No sidecar: a recording from before N4, or none was written.
        }
        try FileManager.default.removeItem(at: file.url)
    }
}

/// The last event of a recording without decompressing all of it: walks the
/// gzip members by the compressed length in their `DL` subfield (the layout
/// in docs/LOG_FORMAT.md, "File"), inflates only the last complete member and
/// decodes its last line. A truncated or damaged tail ends the walk, so the
/// result is the last event a reader would return. Display only (the
/// sessions list); `LogFileReader` stays the one reader for data.
enum RecordingTail {
    /// Bytes before the DEFLATE data in a DriveLogger member: the 10-byte
    /// gzip header, XLEN, and the 8-byte `DL` subfield.
    static let memberHeaderLength = 20
    /// CRC-32 and ISIZE.
    static let memberTrailerLength = 8

    /// `t` of the last event, nil if the file has none or can't be read.
    static func lastEventTimestamp(of url: URL) -> MonotonicTimestamp? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        var offset: UInt64 = 0
        var memberIndex = 0
        var last: (dataOffset: UInt64, length: Int)?
        while offset + UInt64(memberHeaderLength) <= size {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let head = try? handle.read(upToCount: memberHeaderLength),
                  let length = deflateLength(memberHeader: head)
            else { break }
            let total = UInt64(memberHeaderLength) + UInt64(length) + UInt64(memberTrailerLength)
            guard offset + total <= size else { break }   // truncated tail
            if memberIndex > 0 {                           // member 0 is the header
                last = (offset + UInt64(memberHeaderLength), length)
            }
            offset += total
            memberIndex += 1
        }

        guard let last,
              (try? handle.seek(toOffset: last.dataOffset)) != nil,
              let deflated = try? handle.read(upToCount: last.length),
              deflated.count == last.length,
              let inflated = try? (deflated as NSData).decompressed(using: .zlib) as Data
        else { return nil }

        let codec = LogCodec()
        for line in inflated.split(separator: UInt8(ascii: "\n")).reversed() {
            if let event = try? codec.event(from: Data(line)) {
                return event.timestamp
            }
        }
        return nil
    }

    /// The DEFLATE length from a DriveLogger member header, nil if `bytes`
    /// isn't one: `1f 8b 08`, FLG = FEXTRA, XLEN 8, subfield `DL` of length 4.
    static func deflateLength(memberHeader bytes: Data) -> Int? {
        let b = [UInt8](bytes)
        guard b.count == memberHeaderLength,
              b[0] == 0x1F, b[1] == 0x8B, b[2] == 0x08, b[3] == 0x04,
              b[10] == 8, b[11] == 0,
              b[12] == UInt8(ascii: "D"), b[13] == UInt8(ascii: "L"),
              b[14] == 4, b[15] == 0
        else { return nil }
        return Int(b[16]) | Int(b[17]) << 8 | Int(b[18]) << 16 | Int(b[19]) << 24
    }
}
