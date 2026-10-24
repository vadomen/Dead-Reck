import DriveLoggerCore
import Darwin
import Foundation

/// The one way a road pack gets into the app's store (N3.4,
/// docs/N3_PLAN.md "N3.4"; docs/BACKLOG_UX.md UX-8): the developer inbox
/// at launch today (`RoadPackStore.launchMaintenance`), a finished download
/// later. It does not care where the source file came from.
///
/// `install(from:name:)`:
/// 1. refuses an invalid pack name (`RoadPackStoreRules.isValidName`) and a
///    source that is not a regular file or is larger than `maxBytes`
///    (150 MB, `RoadPackFormat.maximumFileSize`), **before copying**;
/// 2. copies the source to a temporary file in the store directory
///    (`RoadPackStoreRules.temporaryFileName`), sets that copy's creation and
///    modification dates to now (the creation date is the install time the
///    active-set rule reads; a rename keeps it) and excludes it from backup;
/// 3. verifies the **copy** with Core's check (`RoadPackCatalog`, i.e.
///    `RoadPack(contentsOf:verify: true)`): a truncated, corrupt or
///    foreign-format file is refused with the reason and the copy deleted.
///    The source is only read by the copy: never mapped, never modified;
/// 4. with `expectedContentHash` (a finished download, UX-8), refuses a pack
///    whose verified header hash differs, before the rename and also for a
///    name that already exists (the copy is deleted; nothing is stored);
/// 5. names the file by the verified header's content hash
///    (`RoadPackStoreRules.fileName(name:contentHash:)`) and renames the copy
///    to it with `renamex_np(RENAME_EXCL)`: atomic, in one directory, and
///    refused by the kernel if the name exists. An existing file of that
///    name has the same name and content hash, so the same content: the copy
///    is deleted and the outcome is `alreadyInstalled`. **An existing pack
///    file is never overwritten or truncated** (a session may have it
///    memory-mapped; a write would raise SIGBUS in it).
///
/// The verification of a new file comes back as a cache entry for the
/// stored file's identity (its final name; size and modification date
/// survive the rename), so the library's next scan is a cache hit, not a
/// second O(file size) read. Runs synchronously: call it off the main
/// actor.
struct RoadPackInstaller: Sendable {
    /// Bytes; a larger source is refused before it is copied.
    static let defaultMaxBytes = Int64(RoadPackFormat.maximumFileSize)

    let storeDirectory: URL
    let maxBytes: Int64

    init(storeDirectory: URL, maxBytes: Int64 = RoadPackInstaller.defaultMaxBytes) {
        self.storeDirectory = storeDirectory
        self.maxBytes = maxBytes
    }

    /// A pack in the store.
    struct Installed: Sendable, Hashable {
        /// The pack's name (`<name>` of the file name).
        let name: String
        /// `<name>-<contentHash>.roadpack`.
        let fileName: String
        let url: URL
        /// 16 lowercase hex digits.
        let contentHash: String
        /// The verification of the new file under its final identity; nil
        /// for `alreadyInstalled` (the existing file keeps its own entry:
        /// the copy's result is not evidence about another file's bytes).
        let cacheEntry: RoadPackVerificationCache.Entry?
    }

    enum Outcome: Sendable, Hashable {
        /// Verified and stored under a new file name.
        case installed(Installed)
        /// The same name and content hash was already stored; the existing
        /// file was left untouched and the copy deleted.
        case alreadyInstalled(Installed)
        /// Not installed; nothing was left in the store.
        case refused(PackFailure)

        var installed: Installed? {
            switch self {
            case .installed(let pack), .alreadyInstalled(let pack): pack
            case .refused: nil
            }
        }

        /// The English reason (the inbox report, diagnostics).
        var refusal: String? { failure?.text }

        var failure: PackFailure? {
            if case .refused(let reason) = self { return reason }
            return nil
        }
    }

    /// - Parameter expectedContentHash: 16 lowercase hex digits the verified
    ///   header must carry (the manifest's `contentHash`); nil (the inbox
    ///   path) accepts any.
    func install(from source: URL, name: String, expectedContentHash: String? = nil) -> Outcome {
        guard RoadPackStoreRules.isValidName(name) else {
            return .refused(.invalidInstallName(maxLength: RoadPackStoreRules.maxNameLength))
        }
        let fileManager = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: source.path)
        } catch {
            return .refused(.cannotReadFile(error.localizedDescription))
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return .refused(.notRegularFile) }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if let reason = sizeRefusal(size) { return .refused(reason) }

        do {
            try RoadPackStore.prepareDirectory(storeDirectory)
        } catch {
            return .refused(.cannotCreateStore(error.localizedDescription))
        }
        let temp = storeDirectory.appendingPathComponent(
            RoadPackStoreRules.temporaryFileName(token: UUID().uuidString))
        func refuse(_ reason: PackFailure) -> Outcome {
            try? fileManager.removeItem(at: temp)
            return .refused(reason)
        }
        do {
            try fileManager.copyItem(at: source, to: temp)
        } catch {
            return refuse(.cannotCopyFile(error.localizedDescription))
        }
        // The source may have grown between the check and the copy.
        let copied = ((try? fileManager.attributesOfItem(atPath: temp.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if let reason = sizeRefusal(copied) { return refuse(reason) }
        let now = Date()
        try? fileManager.setAttributes([.creationDate: now, .modificationDate: now], ofItemAtPath: temp.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var tempURL = temp
        try? tempURL.setResourceValues(values)

        let catalog = RoadPackCatalog(urls: [temp], cache: RoadPackVerificationCache())
        guard let entry = catalog.entries.first else { return refuse(.notVerified) }
        guard entry.isUsable, let verification = entry.verification, let identity = entry.identity else {
            return refuse(.other(entry.refusal ?? "refused"))
        }
        guard let hash = verification.contentHash,
              let fileName = RoadPackStoreRules.fileName(name: name, contentHash: hash) else {
            return refuse(.other("no valid content hash"))
        }
        if let expected = expectedContentHash, hash != expected {
            return refuse(.contentHashMismatch(found: hash, expected: expected))
        }
        let final = storeDirectory.appendingPathComponent(fileName)
        if renamex_np(temp.path, final.path, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            if code == EEXIST {
                try? fileManager.removeItem(at: temp)
                return .alreadyInstalled(Installed(name: name, fileName: fileName, url: final, contentHash: hash,
                                                   cacheEntry: nil))
            }
            return refuse(.cannotStoreFile(String(cString: strerror(code))))
        }
        // The verified identity, under the final name; checked against the
        // stored file so a cache entry never vouches for other bytes.
        var stored = identity
        stored.name = fileName
        let entryForStore = (try? RoadPackFileIdentity(contentsOf: final)) == stored
            ? RoadPackVerificationCache.Entry(identity: stored, verification: verification) : nil
        return .installed(Installed(name: name, fileName: fileName, url: final, contentHash: hash,
                                    cacheEntry: entryForStore))
    }

    private func sizeRefusal(_ size: Int64) -> PackFailure? {
        guard size > maxBytes else { return nil }
        return .tooLarge(bytes: size, limit: maxBytes)
    }
}

/// Why a road pack could not be downloaded, installed or removed (UX-15).
/// `text` is the English wording, unchanged: it goes into the recording's
/// `roadPacks` row (inbox refusals), Diagnostics and tests, and is never
/// reworded. `display` is the catalog text for Settings → Maps ("Failed:
/// <reason>", "Could not remove <pack>: <reason>"): a lower-case fragment.
/// Reasons that come from elsewhere (Core's rules and verification, the
/// server, URLSession) are `other` and shown as they are.
enum PackFailure: Hashable, Sendable, CustomStringConvertible {
    /// The downloader's pack name check (`PackPartialFiles`, `enqueue`).
    case invalidPackName
    /// The installer's name check.
    case invalidInstallName(maxLength: Int)
    case cannotCreateStore(String)
    case moreBytesThanManifest
    case incompleteDownload
    case checksumMismatch
    case notHTTPResponse
    case cannotWriteFile(String)
    case serverSentMore(limit: Int64)
    case cannotReadFile(String)
    case notRegularFile
    case cannotCopyFile(String)
    case notVerified
    case contentHashMismatch(found: String, expected: String)
    case cannotStoreFile(String)
    case tooLarge(bytes: Int64, limit: Int64)
    case cannotMarkForRemoval(String)
    case noStore
    /// Text that is not this file's to translate.
    case other(String)

    /// English, as written before UX-15 (diagnostics, the recording).
    var text: String {
        switch self {
        case .invalidPackName: "invalid pack name"
        case .invalidInstallName(let maxLength): "invalid pack name (1–\(maxLength) of a–z, 0–9, _ and -)"
        case .cannotCreateStore(let error): "cannot create the store: \(error)"
        case .moreBytesThanManifest: "more bytes than the manifest says"
        case .incompleteDownload: "incomplete download"
        case .checksumMismatch: "checksum mismatch"
        case .notHTTPResponse: "not an HTTP response"
        case .cannotWriteFile(let error): "cannot write the file: \(error)"
        case .serverSentMore(let limit): "the server sent more than \(limit) bytes"
        case .cannotReadFile(let error): "cannot read the file: \(error)"
        case .notRegularFile: "not a regular file"
        case .cannotCopyFile(let error): "cannot copy the file: \(error)"
        case .notVerified: "not verified"
        case .contentHashMismatch(let found, let expected): "content hash \(found) does not match the manifest (\(expected))"
        case .cannotStoreFile(let error): "cannot store the file: \(error)"
        case .tooLarge(let bytes, let limit): "\(bytes) bytes, larger than the \(limit) byte limit"
        case .cannotMarkForRemoval(let error): "cannot mark for removal: \(error)"
        case .noStore: "no road pack store"
        case .other(let text): text
        }
    }

    /// The catalog entry of `display` (the key is the English text); nil
    /// for `other`, which is shown as it is. Byte counts go through
    /// `DisplayFormat.bytes` in `locale` (no plural keys: units do not decline).
    func resource(locale: Locale = .current) -> LocalizedStringResource? {
        switch self {
        case .invalidPackName: "invalid pack name"
        case .invalidInstallName(let maxLength): "invalid pack name (1–\(maxLength) of a–z, 0–9, _ and -)"
        case .cannotCreateStore(let error): "cannot create the store: \(error)"
        case .moreBytesThanManifest: "more bytes than the manifest says"
        case .incompleteDownload: "incomplete download"
        case .checksumMismatch: "checksum mismatch"
        case .notHTTPResponse: "not an HTTP response"
        case .cannotWriteFile(let error): "cannot write the file: \(error)"
        case .serverSentMore(let limit): "the server sent more than \(DisplayFormat.bytes(limit, locale: locale))"
        case .cannotReadFile(let error): "cannot read the file: \(error)"
        case .notRegularFile: "not a regular file"
        case .cannotCopyFile(let error): "cannot copy the file: \(error)"
        case .notVerified: "not verified"
        case .contentHashMismatch(let found, let expected): "content hash \(found) does not match the manifest (\(expected))"
        case .cannotStoreFile(let error): "cannot store the file: \(error)"
        case .tooLarge(let bytes, let limit):
            "\(DisplayFormat.bytes(bytes, locale: locale)), larger than the \(DisplayFormat.bytes(limit, locale: locale)) limit"
        case .cannotMarkForRemoval(let error): "cannot mark for removal: \(error)"
        case .noStore: "no road pack store"
        case .other: nil
        }
    }

    /// What Settings → Maps shows, in the app language.
    var display: String { display(language: nil) }

    /// The text in `language` ("uk", "en"); nil: the app language.
    func display(language: String?) -> String {
        let locale = language.map(Locale.init(identifier:)) ?? .current
        guard var r = resource(locale: locale) else { return text }
        if language != nil { r.locale = locale }
        return String(localized: r)
    }

    /// The English `text`, so an interpolation that misses `display` shows
    /// what it showed before UX-15.
    var description: String { text }
}
