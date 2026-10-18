import Foundation

/// The rules of the app's road pack store (N3.4, docs/N3_PLAN.md "N3.4";
/// docs/BACKLOG_UX.md UX-8): file names, which installed file is active per
/// pack name, and what is deleted at launch. Pure logic: no file system.
/// The app lists the store directory, feeds the result in and carries out
/// the answer.
///
/// **File names.** A stored pack is `<name>-<contentHash>.roadpack`: the
/// pack's `name` (supplied by the caller, it is not inside the pack) and the
/// header's content hash as 16 lowercase hex digits, the same scheme as the
/// server keys `packs/v1/<name>-<contentHash>.roadpack`. A new version of a
/// pack is therefore always a new file: nothing is ever overwritten in
/// place, so a pack a running session has memory-mapped never changes under
/// it (a write would raise SIGBUS in the reader).
///
/// **One active file per name.** With several files of one name, the newest
/// is active (`activeSet`). The others are superseded.
///
/// **Deletion happens only while no session can have a pack mapped:** at
/// launch (`launchCleanup`), before any Navigate or Record session has
/// mapped one, and for "Remove" when no Navigate or Record run is active
/// (the app deletes that name's files at once). "Remove" during a session
/// only marks the files (`filesToMark(removingName:in:)`), a marked file is
/// never active again, and the next launch deletes it. A superseded file
/// stays on disk until the next launch: the running session may have it
/// mapped.
///
/// Data: © OpenStreetMap contributors, ODbL 1.0.
public enum RoadPackStoreRules {
    /// The file extension of a road pack, without the dot.
    public static let fileExtension = "roadpack"
    /// The longest accepted pack name, in characters.
    public static let maxNameLength = 64
    /// Digits in a content hash as written in a file name.
    public static let contentHashDigits = 16

    // MARK: Names

    /// A pack name: 1…`maxNameLength` characters from `a-z`, `0-9`, `_` and
    /// `-`, not starting or ending with `-` (a leading `-` reads as an option
    /// to command-line tools; a trailing one would make
    /// `<name>-<hash>` ambiguous). No case folding: `A` is refused.
    public static func isValidName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= maxNameLength,
              scalars.first != "-", scalars.last != "-" else { return false }
        return scalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }
    }

    /// Exactly `contentHashDigits` lowercase hex digits.
    public static func isValidContentHash(_ hex: String) -> Bool {
        let scalars = hex.unicodeScalars
        return scalars.count == contentHashDigits
            && scalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// A content hash as a file name writes it: 16 lowercase hex digits,
    /// zero-padded (the same text as `RoadPackInfo.contentHash`).
    public static func contentHashText(_ contentHash: UInt64) -> String {
        NavigationSeed.hex(contentHash)
    }

    /// `<name>-<contentHash>.roadpack`; nil when the name or the hash is
    /// not valid.
    public static func fileName(name: String, contentHash: String) -> String? {
        guard isValidName(name), isValidContentHash(contentHash) else { return nil }
        return "\(name)-\(contentHash).\(fileExtension)"
    }

    /// `<name>-<contentHash>.roadpack` for a header's content hash; nil
    /// when the name is not valid.
    public static func fileName(name: String, contentHash: UInt64) -> String? {
        fileName(name: name, contentHash: contentHashText(contentHash))
    }

    /// A stored file's name, parsed.
    public struct StoredFileName: Hashable, Sendable {
        public var name: String
        /// 16 lowercase hex digits.
        public var contentHash: String

        public init(name: String, contentHash: String) {
            self.name = name
            self.contentHash = contentHash
        }

        /// The content hash as a number (it is valid hex by construction).
        public var contentHashValue: UInt64 { UInt64(contentHash, radix: 16) ?? 0 }
    }

    /// The name and content hash of a store file name, split on the LAST
    /// `-` (names may contain `-`); nil for anything that `fileName` would
    /// not produce: another extension, a missing or malformed hash, an
    /// invalid name, a path.
    public static func parseFileName(_ fileName: String) -> StoredFileName? {
        let suffix = ".\(fileExtension)"
        guard fileName.hasSuffix(suffix) else { return nil }
        let stem = fileName.dropLast(suffix.count)
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        let name = String(stem[..<dash])
        let hash = String(stem[stem.index(after: dash)...])
        guard isValidName(name), isValidContentHash(hash) else { return nil }
        return StoredFileName(name: name, contentHash: hash)
    }

    /// The pack name for a file found in the developer inbox: `<name>.roadpack`
    /// gives `<name>`, and a store-style `<name>-<16 hex>.roadpack` gives
    /// `<name>` too (the hash in a file name is never trusted: the installer
    /// names the stored file by the header's hash). nil when the result is
    /// not a valid name or the extension is not `.roadpack`.
    public static func inboxName(fromFileName fileName: String) -> String? {
        if let stored = parseFileName(fileName) { return stored.name }
        let suffix = ".\(fileExtension)"
        guard fileName.hasSuffix(suffix) else { return nil }
        let stem = String(fileName.dropLast(suffix.count))
        return isValidName(stem) ? stem : nil
    }

    // MARK: Temporary files

    /// The prefix of an installer's temporary file in the store directory.
    /// Hidden (leading dot) and never a valid store file name, so a listing
    /// never offers it as a pack.
    public static let temporaryPrefix = ".install-"

    /// A temporary file name for an install in progress; `token` must be
    /// unique per install (e.g. a UUID string). The installer writes and
    /// verifies this file, then renames it to `fileName(name:contentHash:)`.
    public static func temporaryFileName(token: String) -> String {
        "\(temporaryPrefix)\(token).tmp"
    }

    /// Whether `fileName` is an installer's temporary file. One found at
    /// launch is a leftover of an interrupted install and is deleted.
    public static func isTemporaryFileName(_ fileName: String) -> Bool {
        fileName.hasPrefix(temporaryPrefix) && fileName.hasSuffix(".tmp")
    }

    // MARK: The active set

    /// One installed pack file, as the app knows it.
    public struct InstalledFile: Hashable, Sendable {
        public var fileName: String
        public var name: String
        /// 16 lowercase hex digits.
        public var contentHash: String
        /// The header's `osmTimestamp`, Unix seconds UTC; 0 = unknown, which
        /// is older than any known timestamp.
        public var osmTimestamp: Int64
        /// When the file was installed, seconds since 1970 (the file's
        /// creation date is enough).
        public var installTime: Double
        /// "Remove" was chosen for it: never active, deleted at the next launch.
        public var markedForRemoval: Bool

        public init(fileName: String, name: String, contentHash: String, osmTimestamp: Int64,
                    installTime: Double, markedForRemoval: Bool = false) {
            self.fileName = fileName
            self.name = name
            self.contentHash = contentHash
            self.osmTimestamp = osmTimestamp
            self.installTime = installTime
            self.markedForRemoval = markedForRemoval
        }

        /// From a store file name (`parseFileName`); nil when it is not one.
        public init?(fileName: String, osmTimestamp: Int64, installTime: Double, markedForRemoval: Bool = false) {
            guard let parsed = RoadPackStoreRules.parseFileName(fileName) else { return nil }
            self.init(fileName: fileName, name: parsed.name, contentHash: parsed.contentHash,
                      osmTimestamp: osmTimestamp, installTime: installTime, markedForRemoval: markedForRemoval)
        }
    }

    /// Whether `a` is newer than `b` (same name assumed): later
    /// `osmTimestamp`, then later install time, then the greater content
    /// hash, then the greater file name. A strict total order on distinct
    /// files, so the choice never depends on the listing order.
    public static func isNewer(_ a: InstalledFile, than b: InstalledFile) -> Bool {
        if a.osmTimestamp != b.osmTimestamp { return a.osmTimestamp > b.osmTimestamp }
        if a.installTime != b.installTime { return a.installTime > b.installTime }
        if a.contentHash != b.contentHash { return a.contentHash > b.contentHash }
        return a.fileName > b.fileName
    }

    /// The installed files split by role.
    public struct ActiveSet: Hashable, Sendable {
        /// One per name that has an unmarked file: the newest unmarked file.
        /// Sorted by name.
        public var active: [InstalledFile]
        /// Unmarked files that are not the newest of their name. Sorted by
        /// file name.
        public var superseded: [InstalledFile]
        /// Files marked for removal. Sorted by file name.
        public var markedForRemoval: [InstalledFile]
    }

    /// Which file is active per name. Marked files are never active, so a
    /// name whose only file is marked has no active file, and removing a
    /// name marks every file of it (`filesToMark(removingName:in:)`), so an
    /// older version never comes back. Safe to call at any time: it decides,
    /// it deletes nothing.
    public static func activeSet(_ files: [InstalledFile]) -> ActiveSet {
        var newest: [String: InstalledFile] = [:]
        var marked: [InstalledFile] = []
        for file in files {
            if file.markedForRemoval { marked.append(file); continue }
            if let current = newest[file.name], !isNewer(file, than: current) { continue }
            newest[file.name] = file
        }
        let activeNames = Set(newest.values.map(\.fileName))
        let superseded = files.filter { !$0.markedForRemoval && !activeNames.contains($0.fileName) }
        return ActiveSet(
            active: newest.values.sorted { $0.name < $1.name },
            superseded: superseded.sorted { $0.fileName < $1.fileName },
            markedForRemoval: marked.sorted { $0.fileName < $1.fileName }
        )
    }

    /// The file names to mark when the user removes pack `name`: every file
    /// of that name, sorted. Marking (not deleting) is the only thing
    /// "Remove" does; `launchCleanup` deletes them.
    public static func filesToMark(removingName name: String, in files: [InstalledFile]) -> [String] {
        files.filter { $0.name == name }.map(\.fileName).sorted()
    }

    /// What launch does with the store, before any session maps a pack.
    public struct LaunchCleanup: Hashable, Sendable {
        /// File names to delete, sorted: superseded files, marked files and
        /// leftover temporary files.
        public var delete: [String]
        /// The active files that remain (`activeSet(...).active`).
        public var active: [InstalledFile]
    }

    /// **Launch only, before any session maps a pack** — the one place a
    /// superseded or marked pack file is deleted ("Remove" with no run
    /// active deletes that name's files itself). Deletes superseded and marked files and
    /// installer leftovers among `otherFileNames` (the directory's other
    /// entries); any other unknown file is left alone. Calling this while a
    /// Navigate or Record session runs would delete a file it may have
    /// mapped: callers must not.
    public static func launchCleanup(_ files: [InstalledFile], otherFileNames: [String] = []) -> LaunchCleanup {
        let set = activeSet(files)
        let delete = set.superseded.map(\.fileName) + set.markedForRemoval.map(\.fileName)
            + otherFileNames.filter(isTemporaryFileName)
        return LaunchCleanup(delete: Array(Set(delete)).sorted(), active: set.active)
    }
}
