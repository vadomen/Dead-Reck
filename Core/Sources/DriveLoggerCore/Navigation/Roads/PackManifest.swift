import Foundation

/// The road pack download manifest (UX-8, docs/BACKLOG_UX.md; prompt 25):
/// what packs the server offers, where they are and how to check them. The
/// app fetches `https://fugps.pages.dev/packs/manifest.json` (written by
/// `site/publish_packs.sh`), hands the bytes and the URL it fetched to
/// `parse(data:manifestURL:)` and downloads from the result. Pure logic:
/// no network, no file system.
///
/// **Schema 2.** Top level: `schema` (2), `generated` (ISO 8601 text),
/// `license`, `licenseUrl`, `attribution`, `packs`. Per pack: `name`,
/// `kind` (`national` | `region`), `title` (`{"uk": …, "en": …}`), `bbox`
/// (`[W, S, E, N]` degrees), `url` (relative to the manifest, e.g.
/// `/packs/v1/<name>-<contentHash>.roadpack`), `size` (bytes), `sha256`
/// (64 lowercase hex), `contentHash` (16 lowercase hex, as in
/// `RoadPackStoreRules`), `formatVersion`, `osmDate` (text; optional, the
/// publisher omits it when the OSM timestamp is unknown) and `osmTimestamp`
/// (Unix seconds).
///
/// **Refusal is per entry.** The whole manifest is refused (`ParseError`)
/// only when it is not JSON, a top-level field is missing or mistyped, or
/// `schema` is not 2. A bad pack entry is dropped (`dropped`, with the
/// reason) and the rest stay usable, so one broken entry cannot hide every
/// pack. The entries are trusted no further than these checks: the file's
/// sha256 after download is the real guard.
///
/// Data: © OpenStreetMap contributors, ODbL 1.0.
public struct PackManifest: Hashable, Sendable {
    /// The one schema this build reads.
    public static let supportedSchema = 2

    /// The URL the manifest was fetched from: relative pack URLs resolve
    /// against it, and a pack URL must have its host.
    public var manifestURL: URL
    /// `generated`, verbatim (ISO 8601 text, e.g. `2026-01-02T03:04:05Z`).
    public var generated: String
    public var license: String
    public var licenseURL: String
    public var attribution: String
    /// The accepted entries, in manifest order.
    public var packs: [Pack]
    /// The refused entries, in manifest order.
    public var dropped: [DroppedEntry]

    public init(manifestURL: URL, generated: String, license: String, licenseURL: String,
                attribution: String, packs: [Pack], dropped: [DroppedEntry] = []) {
        self.manifestURL = manifestURL
        self.generated = generated
        self.license = license
        self.licenseURL = licenseURL
        self.attribution = attribution
        self.packs = packs
        self.dropped = dropped
    }

    /// `generated` as a date; nil when it is not ISO 8601 internet date-time.
    public var generatedDate: Date? { ISO8601DateFormatter().date(from: generated) }

    /// The accepted entry named `name`.
    public func pack(named name: String) -> Pack? { packs.first { $0.name == name } }

    // MARK: Pack

    /// One accepted manifest entry.
    public struct Pack: Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable {
            /// The country-wide main-roads pack.
            case national
            case region
        }

        /// A valid store name (`RoadPackStoreRules.isValidName`).
        public var name: String
        public var kind: Kind
        /// `title.uk`; may be empty when `titleEN` is not.
        public var titleUK: String
        /// `title.en`; may be empty when `titleUK` is not.
        public var titleEN: String
        public var bbox: BBox
        /// The absolute download URL: `url` resolved against the manifest
        /// URL; always `https`, always the manifest's host.
        public var url: URL
        /// Bytes; 1…`RoadPackFormat.maximumFileSize`.
        public var size: Int64
        /// 64 lowercase hex digits: the whole file's SHA-256.
        public var sha256: String
        /// 16 lowercase hex digits: the header's content hash.
        public var contentHash: String
        /// 1…`RoadPackFormat.currentVersion`.
        public var formatVersion: Int
        /// `osmDate`, verbatim; nil when the entry has none.
        public var osmDate: String?
        /// `osmTimestamp`, Unix seconds UTC (0 = unknown, as in the header).
        public var osmTimestamp: Int64

        public init(name: String, kind: Kind, titleUK: String, titleEN: String, bbox: BBox, url: URL,
                    size: Int64, sha256: String, contentHash: String, formatVersion: Int,
                    osmDate: String?, osmTimestamp: Int64) {
            self.name = name
            self.kind = kind
            self.titleUK = titleUK
            self.titleEN = titleEN
            self.bbox = bbox
            self.url = url
            self.size = size
            self.sha256 = sha256
            self.contentHash = contentHash
            self.formatVersion = formatVersion
            self.osmDate = osmDate
            self.osmTimestamp = osmTimestamp
        }

        /// The store file name this pack installs as,
        /// `<name>-<contentHash>.roadpack` (valid by construction).
        public var fileName: String { RoadPackStoreRules.fileName(name: name, contentHash: contentHash) ?? "" }

        /// The title for the user's languages (`PackManifest.title`).
        public func title(preferredLanguages: [String]) -> String {
            PackManifest.title(uk: titleUK, en: titleEN, name: name, preferredLanguages: preferredLanguages)
        }
    }

    /// A bounding box in degrees, `[W, S, E, N]` in the manifest. Finite,
    /// longitudes in -180…180, latitudes in -90…90, `west <= east`,
    /// `south <= north` (a box across the antimeridian is refused).
    public struct BBox: Hashable, Sendable {
        public var west: Double
        public var south: Double
        public var east: Double
        public var north: Double

        public init(west: Double, south: Double, east: Double, north: Double) {
            self.west = west
            self.south = south
            self.east = east
            self.north = north
        }

        /// Whether the four values form a box as described above.
        public var isValid: Bool {
            let all = [west, south, east, north]
            guard all.allSatisfy(\.isFinite) else { return false }
            guard (-180...180).contains(west), (-180...180).contains(east),
                  (-90...90).contains(south), (-90...90).contains(north) else { return false }
            return west <= east && south <= north
        }
    }

    // MARK: Refusals

    /// Why the whole manifest was refused.
    public enum ParseError: Error, Hashable, Sendable, CustomStringConvertible {
        /// Not JSON at all, or JSON whose top level is not an object.
        case notJSON
        case missingField(String)
        case mistypedField(String)
        /// `schema` is not `supportedSchema`.
        case unsupportedSchema(Int64)

        public var description: String {
            switch self {
            case .notJSON: "the manifest is not a JSON object"
            case .missingField(let f): "the manifest has no \"\(f)\""
            case .mistypedField(let f): "the manifest's \"\(f)\" has the wrong type"
            case .unsupportedSchema(let s): "manifest schema \(s) is not supported (this build reads schema \(PackManifest.supportedSchema))"
            }
        }
    }

    /// Why one pack entry was dropped.
    public enum DropReason: Error, Hashable, Sendable, CustomStringConvertible {
        /// The entry is not a JSON object.
        case notAnObject
        case missingField(String)
        case mistypedField(String)
        /// Not a valid store name (`RoadPackStoreRules.isValidName`).
        case invalidName(String)
        case unknownKind(String)
        /// Below 1 or above `RoadPackFormat.currentVersion`.
        case unsupportedFormatVersion(Int64)
        /// Not 1…`RoadPackFormat.maximumFileSize` bytes.
        case invalidSize(Int64)
        /// Not 64 lowercase hex digits.
        case invalidSHA256
        /// Not 16 lowercase hex digits.
        case invalidContentHash
        case invalidBBox
        /// Empty, or does not resolve to an absolute URL with a host.
        case invalidURL(String)
        /// Resolves to a scheme other than `https`.
        case notHTTPS(String)
        /// Resolves to a host other than the manifest's.
        case otherHost(String)
        /// An earlier accepted entry has the same name (the first is kept).
        case duplicateName
        /// Both `title.uk` and `title.en` are empty or whitespace.
        case emptyTitles

        public var description: String {
            switch self {
            case .notAnObject: "not a JSON object"
            case .missingField(let f): "no \"\(f)\""
            case .mistypedField(let f): "\"\(f)\" has the wrong type"
            case .invalidName(let n): "invalid pack name \"\(n)\""
            case .unknownKind(let k): "unknown kind \"\(k)\""
            case .unsupportedFormatVersion(let v): "format version \(v) is not supported (this build reads 1…\(RoadPackFormat.currentVersion))"
            case .invalidSize(let s): "size \(s) is not 1…\(RoadPackFormat.maximumFileSize) bytes"
            case .invalidSHA256: "sha256 is not 64 lowercase hex digits"
            case .invalidContentHash: "contentHash is not 16 lowercase hex digits"
            case .invalidBBox: "bbox is not [W, S, E, N] with W <= E and S <= N"
            case .invalidURL(let u): "url \"\(u)\" is not a usable URL"
            case .notHTTPS(let u): "url \(u) is not https"
            case .otherHost(let u): "url \(u) is not on the manifest's host"
            case .duplicateName: "a pack with this name came earlier"
            case .emptyTitles: "both titles are empty"
            }
        }
    }

    /// A dropped entry: its index in `packs`, its name when it had a string
    /// one, and why.
    public struct DroppedEntry: Hashable, Sendable, CustomStringConvertible {
        public var index: Int
        public var name: String?
        public var reason: DropReason

        public init(index: Int, name: String?, reason: DropReason) {
            self.index = index
            self.name = name
            self.reason = reason
        }

        public var description: String { "\(name ?? "#\(index)"): \(reason)" }
    }

    // MARK: Parsing

    /// Parses and validates a manifest fetched from `manifestURL`. Throws
    /// only for a manifest that is not usable at all (`ParseError`); bad
    /// entries land in `dropped`. Duplicate names: the first ACCEPTED entry
    /// wins, so a broken earlier entry does not hide a good later one.
    public static func parse(data: Data, manifestURL: URL) throws -> PackManifest {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let top) = root else { throw ParseError.notJSON }
        func topString(_ key: String) throws -> String {
            guard let value = top[key] else { throw ParseError.missingField(key) }
            guard case .string(let s) = value else { throw ParseError.mistypedField(key) }
            return s
        }
        guard let schemaValue = top["schema"] else { throw ParseError.missingField("schema") }
        guard let schema = integer(schemaValue) else { throw ParseError.mistypedField("schema") }
        guard schema == Int64(supportedSchema) else { throw ParseError.unsupportedSchema(schema) }
        let generated = try topString("generated")
        let license = try topString("license")
        let licenseURL = try topString("licenseUrl")
        let attribution = try topString("attribution")
        guard let packsValue = top["packs"] else { throw ParseError.missingField("packs") }
        guard case .array(let entries) = packsValue else { throw ParseError.mistypedField("packs") }

        var packs: [Pack] = []
        var dropped: [DroppedEntry] = []
        var names: Set<String> = []
        for (index, entry) in entries.enumerated() {
            var entryName: String?
            if case .object(let o) = entry, case .string(let n)? = o["name"] { entryName = n }
            switch parseEntry(entry, manifestURL: manifestURL) {
            case .failure(let reason):
                dropped.append(DroppedEntry(index: index, name: entryName, reason: reason))
            case .success(let pack):
                if names.contains(pack.name) {
                    dropped.append(DroppedEntry(index: index, name: pack.name, reason: .duplicateName))
                } else {
                    names.insert(pack.name)
                    packs.append(pack)
                }
            }
        }
        return PackManifest(manifestURL: manifestURL, generated: generated, license: license,
                            licenseURL: licenseURL, attribution: attribution, packs: packs, dropped: dropped)
    }

    /// One entry, validated in field order (the first problem is reported).
    static func parseEntry(_ entry: JSONValue, manifestURL: URL) -> Result<Pack, DropReason> {
        guard case .object(let o) = entry else { return .failure(.notAnObject) }
        func field(_ key: String) -> Result<JSONValue, DropReason> {
            guard let v = o[key] else { return .failure(.missingField(key)) }
            return .success(v)
        }
        func string(_ key: String) -> Result<String, DropReason> {
            field(key).flatMap { v in
                if case .string(let s) = v { return .success(s) }
                return .failure(.mistypedField(key))
            }
        }
        func int(_ key: String) -> Result<Int64, DropReason> {
            field(key).flatMap { v in integer(v).map { .success($0) } ?? .failure(.mistypedField(key)) }
        }
        do throws(DropReason) {
            let name = try string("name").get()
            guard RoadPackStoreRules.isValidName(name) else { return .failure(.invalidName(name)) }
            let kindText = try string("kind").get()
            guard let kind = Pack.Kind(rawValue: kindText) else { return .failure(.unknownKind(kindText)) }

            guard case .object(let title) = try field("title").get() else { return .failure(.mistypedField("title")) }
            guard let ukValue = title["uk"] else { return .failure(.missingField("title.uk")) }
            guard case .string(let uk) = ukValue else { return .failure(.mistypedField("title.uk")) }
            guard let enValue = title["en"] else { return .failure(.missingField("title.en")) }
            guard case .string(let en) = enValue else { return .failure(.mistypedField("title.en")) }

            guard case .array(let box) = try field("bbox").get() else { return .failure(.mistypedField("bbox")) }
            let coordinates = box.compactMap(number)
            guard coordinates.count == box.count else { return .failure(.mistypedField("bbox")) }
            guard coordinates.count == 4 else { return .failure(.invalidBBox) }
            let bbox = BBox(west: coordinates[0], south: coordinates[1], east: coordinates[2], north: coordinates[3])
            guard bbox.isValid else { return .failure(.invalidBBox) }

            let urlText = try string("url").get()
            let url = try resolve(urlText, against: manifestURL).get()

            let size = try int("size").get()
            guard size > 0, size <= Int64(RoadPackFormat.maximumFileSize) else { return .failure(.invalidSize(size)) }
            let sha256 = try string("sha256").get()
            guard isLowercaseHex(sha256, digits: 64) else { return .failure(.invalidSHA256) }
            let contentHash = try string("contentHash").get()
            guard RoadPackStoreRules.isValidContentHash(contentHash) else { return .failure(.invalidContentHash) }
            let formatVersion = try int("formatVersion").get()
            guard formatVersion >= 1, formatVersion <= Int64(RoadPackFormat.currentVersion) else {
                return .failure(.unsupportedFormatVersion(formatVersion))
            }
            var osmDate: String?
            if let value = o["osmDate"] {
                guard case .string(let s) = value else { return .failure(.mistypedField("osmDate")) }
                osmDate = s
            }
            let osmTimestamp = try int("osmTimestamp").get()

            guard !(uk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
                return .failure(.emptyTitles)
            }
            return .success(Pack(name: name, kind: kind, titleUK: uk, titleEN: en, bbox: bbox, url: url,
                                 size: size, sha256: sha256, contentHash: contentHash,
                                 formatVersion: Int(formatVersion), osmDate: osmDate, osmTimestamp: osmTimestamp))
        } catch {
            return .failure(error)
        }
    }

    /// `text` resolved against `manifestURL`: must give an absolute `https`
    /// URL on the manifest's host (compared case-insensitively). A
    /// protocol-relative or absolute URL to another host is refused, so a
    /// tampered entry cannot point the download elsewhere.
    public static func resolve(_ text: String, against manifestURL: URL) -> Result<URL, DropReason> {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: text, relativeTo: manifestURL)?.absoluteURL,
              let host = url.host, !host.isEmpty else { return .failure(.invalidURL(text)) }
        guard url.scheme?.lowercased() == "https" else { return .failure(.notHTTPS(url.absoluteString)) }
        guard let manifestHost = manifestURL.host, host.lowercased() == manifestHost.lowercased() else {
            return .failure(.otherHost(url.absoluteString))
        }
        return .success(url)
    }

    // MARK: Titles

    /// The title to show: `uk` when the first preferred language is
    /// Ukrainian (`uk`, `uk-UA`, …), otherwise `en`; the other language
    /// when the chosen one is empty; `name` when both are. Pass
    /// `Locale.preferredLanguages`.
    public static func title(uk: String, en: String, name: String, preferredLanguages: [String]) -> String {
        let first = preferredLanguages.first?.lowercased() ?? ""
        let wantsUK = first == "uk" || first.hasPrefix("uk-") || first.hasPrefix("uk_")
        let isBlank = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let (primary, secondary) = wantsUK ? (uk, en) : (en, uk)
        if !isBlank(primary) { return primary }
        if !isBlank(secondary) { return secondary }
        return name
    }

    // MARK: Updates, list order, staleness

    /// Whether the manifest offers a different build of an installed pack:
    /// the caller matches by name; an update is a different content hash.
    /// nil (not installed) is never an update. A newer pack pushed by the
    /// developer also differs, and shows as an update too.
    public static func updateAvailable(installedContentHash: String?, manifestContentHash: String) -> Bool {
        guard let installed = installedContentHash else { return false }
        return installed != manifestContentHash
    }

    /// How long a fetched manifest is current.
    public static let refreshInterval: TimeInterval = 24 * 60 * 60

    /// Whether to fetch the manifest again: never fetched, `refreshInterval`
    /// or more ago, or "fetched in the future" (the clock was set back).
    public static func needsRefresh(fetchedAt: Date?, now: Date) -> Bool {
        guard let fetchedAt else { return true }
        let age = now.timeIntervalSince(fetchedAt)
        return age < 0 || age >= refreshInterval
    }

    /// The order of Settings → Maps: `national` first, then installed
    /// packs, then by `title` (case-insensitive, localized compare in
    /// `locale`), `name` last, so the order is total and never depends on
    /// the input order. Pass the user's locale, not `en_US_POSIX`: there
    /// Foundation was measured to ignore `.caseInsensitive` ("Gamma" before
    /// "alpha").
    public static func listOrder(_ entries: [ListEntry], locale: Locale = .current) -> [ListEntry] {
        entries.sorted { a, b in
            let aNational = a.kind == .national, bNational = b.kind == .national
            if aNational != bNational { return aNational }
            if a.installed != b.installed { return a.installed }
            switch a.title.compare(b.title, options: .caseInsensitive, range: nil, locale: locale) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.name < b.name
            }
        }
    }

    /// One row of Settings → Maps as `listOrder` sees it. `kind` is nil for
    /// an installed pack the manifest does not list (developer push).
    public struct ListEntry: Hashable, Sendable {
        public var name: String
        public var kind: Pack.Kind?
        public var installed: Bool
        /// The display title (`Pack.title(preferredLanguages:)`, or the
        /// name for a pack the manifest does not list).
        public var title: String

        public init(name: String, kind: Pack.Kind?, installed: Bool, title: String) {
            self.name = name
            self.kind = kind
            self.installed = installed
            self.title = title
        }

        public init(pack: Pack, installed: Bool, preferredLanguages: [String]) {
            self.init(name: pack.name, kind: pack.kind, installed: installed,
                      title: pack.title(preferredLanguages: preferredLanguages))
        }
    }

    // MARK: Helpers

    /// An integer: a JSON integer, or a float with an integral value that
    /// fits Int64 (`5.0`). `true` is not an integer.
    static func integer(_ value: JSONValue) -> Int64? {
        switch value {
        case .int(let i): return i
        case .double(let d):
            guard d.isFinite, d == d.rounded(), abs(d) < 9.0e18 else { return nil }
            return Int64(d)
        default: return nil
        }
    }

    /// A JSON number as a Double.
    static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    /// Exactly `digits` characters from `0-9a-f`.
    static func isLowercaseHex(_ text: String, digits: Int) -> Bool {
        let scalars = text.unicodeScalars
        return scalars.count == digits && scalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}
