import Foundation

// Road pack catalog (N3.3 item 3, docs/N3_PLAN.md "N3.3" amendment): which
// pack files are usable, each verified once. Independent of where the files
// come from: the caller lists them (the app's developer bridge today, the
// N3.4 import later) and persists the cache where it likes. Pure functions
// and Sendable values, so the app can run them off the main actor.
//
// Data: © OpenStreetMap contributors, ODbL 1.0.

/// A pack file's identity: what the verification cache is keyed by. A
/// content-hash key would need the full read the cache exists to skip; a
/// file copied again (Finder, Files) gets a new modification date and is
/// verified again.
public struct RoadPackFileIdentity: Hashable, Sendable, Codable {
    /// The file name (last path component).
    public var name: String
    /// Bytes.
    public var size: Int64
    /// Modification time, nanoseconds since 1970 (the file system's date,
    /// rounded to the nanosecond).
    public var modificationTimeNs: Int64

    public init(name: String, size: Int64, modificationTimeNs: Int64) {
        self.name = name
        self.size = size
        self.modificationTimeNs = modificationTimeNs
    }

    /// The identity of the file at `url` now.
    public init(contentsOf url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value,
              let date = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let ns = (date.timeIntervalSince1970 * 1e9).rounded()
        self.init(name: url.lastPathComponent, size: size,
                  modificationTimeNs: ns.isFinite && abs(ns) < 9e18 ? Int64(ns) : 0)
    }
}

/// A pack's bounding box in E7 (south-west and north-east corners).
public struct RoadPackBounds: Hashable, Sendable, Codable {
    public var southLatE7: Int32
    public var westLonE7: Int32
    public var northLatE7: Int32
    public var eastLonE7: Int32

    public init(southLatE7: Int32, westLonE7: Int32, northLatE7: Int32, eastLonE7: Int32) {
        self.southLatE7 = southLatE7
        self.westLonE7 = westLonE7
        self.northLatE7 = northLatE7
        self.eastLonE7 = eastLonE7
    }

    public init(southWest: RoadPoint, northEast: RoadPoint) {
        self.init(southLatE7: southWest.latE7, westLonE7: southWest.lonE7,
                  northLatE7: northEast.latE7, eastLonE7: northEast.lonE7)
    }
}

/// The outcome of verifying one pack file (content hash and structure,
/// `RoadPack(contentsOf:verify: true)`).
public struct RoadPackVerification: Hashable, Sendable, Codable {
    /// The pack passed every check.
    public var verified: Bool
    /// Why it was refused; nil when verified.
    public var refusal: String?
    /// Wall time of the verification, seconds.
    public var verifySeconds: Double
    /// From the header, when it could be read: 16 lowercase hex digits.
    public var contentHash: String?
    public var formatVersion: Int?
    /// The OSM data's replication timestamp, Unix seconds (0 unknown).
    public var osmTimestamp: Int64?
    /// 16 lowercase hex digits.
    public var gridID: String?
    /// The shape points' bounding box (nil for an empty or refused pack).
    public var bounds: RoadPackBounds?
    /// The pack has a `COVR` coverage polygon.
    public var hasCoverage: Bool?

    public init(verified: Bool, refusal: String?, verifySeconds: Double, contentHash: String? = nil,
                formatVersion: Int? = nil, osmTimestamp: Int64? = nil, gridID: String? = nil,
                bounds: RoadPackBounds? = nil, hasCoverage: Bool? = nil) {
        self.verified = verified
        self.refusal = refusal
        self.verifySeconds = verifySeconds
        self.contentHash = contentHash
        self.formatVersion = formatVersion
        self.osmTimestamp = osmTimestamp
        self.gridID = gridID
        self.bounds = bounds
        self.hasCoverage = hasCoverage
    }
}

/// Verification results keyed by file identity. Codable; the caller
/// persists it as JSON (`encoded()`, `init(data:)`) wherever it likes.
/// Entries are kept sorted by file name, one per name, so the JSON is
/// byte-stable.
public struct RoadPackVerificationCache: Hashable, Sendable, Codable {
    public struct Entry: Hashable, Sendable, Codable {
        public var identity: RoadPackFileIdentity
        public var verification: RoadPackVerification

        public init(identity: RoadPackFileIdentity, verification: RoadPackVerification) {
            self.identity = identity
            self.verification = verification
        }
    }

    /// The cache's own format version; a cache of another version is
    /// discarded (`init(data:)` returns an empty one), costing one
    /// verification per pack.
    public static let currentVersion = 1

    public var cacheVersion = RoadPackVerificationCache.currentVersion
    public private(set) var entries: [Entry] = []

    public init() {}

    /// Decodes a persisted cache; an undecodable one or one of another
    /// version is empty (every pack is verified again).
    public init(data: Data) {
        guard let decoded = try? JSONDecoder().decode(RoadPackVerificationCache.self, from: data),
              decoded.cacheVersion == Self.currentVersion else { return }
        self = decoded
    }

    /// Sorted keys, compact.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return (try? encoder.encode(self)) ?? Data()
    }

    /// The cached verification of the file with exactly this identity.
    public func verification(for identity: RoadPackFileIdentity) -> RoadPackVerification? {
        entries.first { $0.identity == identity }?.verification
    }

    /// Stores `verification` for `identity`, replacing any entry of the
    /// same file name.
    public mutating func store(_ verification: RoadPackVerification, for identity: RoadPackFileIdentity) {
        entries.removeAll { $0.identity.name == identity.name }
        entries.append(Entry(identity: identity, verification: verification))
        entries.sort { $0.identity.name < $1.identity.name }
    }
}

/// The pack files a caller offers, each verified once (N3.3 item 3).
///
/// For each URL, in the order given:
/// - its identity (name, size, modification date) is read; a file that
///   cannot be read is listed with `fileError` and not cached;
/// - **cache hit** (the same identity verified before): the cached outcome,
///   no verification;
/// - **miss**: `RoadPack(contentsOf:verify: true)` (structure and content
///   hash, O(file size)), timed. A truncated, corrupt or structurally bad
///   pack is refused with its reason and never used; the refusal is cached
///   too (the same bytes stay bad until the file changes). A file that
///   changed while it was being verified is not cached.
///
/// `cache` holds the scanned files only, ready to persist.
public struct RoadPackCatalog: Sendable {
    public struct Entry: Hashable, Sendable {
        public var url: URL
        /// nil when the file could not be read.
        public var identity: RoadPackFileIdentity?
        /// nil when the file could not be read.
        public var verification: RoadPackVerification?
        /// The verification came from the cache.
        public var cacheHit: Bool
        /// The file could not be read or changed while it was verified (not cached).
        public var fileError: String?

        /// Verified, and nothing is wrong with the file.
        public var isUsable: Bool { fileError == nil && identity != nil && verification?.verified == true }

        /// Why the pack is not usable; nil when it is.
        public var refusal: String? {
            if let fileError { return fileError }
            guard let verification else { return "not verified" }
            return verification.verified ? nil : (verification.refusal ?? "refused")
        }
    }

    public private(set) var entries: [Entry]
    public private(set) var cache: RoadPackVerificationCache

    public init(urls: [URL], cache old: RoadPackVerificationCache) {
        var cache = RoadPackVerificationCache()
        var entries: [Entry] = []
        for url in urls {
            let identity: RoadPackFileIdentity
            do {
                identity = try RoadPackFileIdentity(contentsOf: url)
            } catch {
                entries.append(Entry(url: url, identity: nil, verification: nil, cacheHit: false,
                                     fileError: "cannot read the file: \(error.localizedDescription)"))
                continue
            }
            if let cached = old.verification(for: identity) {
                cache.store(cached, for: identity)
                entries.append(Entry(url: url, identity: identity, verification: cached, cacheHit: true))
                continue
            }
            let outcome = Self.verify(url)
            guard let verification = outcome.verification else {
                entries.append(Entry(url: url, identity: identity, verification: nil, cacheHit: false,
                                     fileError: outcome.fileError))
                continue
            }
            // A file copied in while it was verified: the result may not be
            // this file's; verify it again next time.
            guard (try? RoadPackFileIdentity(contentsOf: url)) == identity else {
                entries.append(Entry(url: url, identity: identity, verification: nil, cacheHit: false,
                                     fileError: "the file changed while it was being verified"))
                continue
            }
            cache.store(verification, for: identity)
            entries.append(Entry(url: url, identity: identity, verification: verification, cacheHit: false))
        }
        self.entries = entries
        self.cache = cache
    }

    /// The usable entries, in the order given.
    public var usable: [Entry] { entries.filter(\.isUsable) }

    /// Full verification of one file. A pack error is a refusal (cached);
    /// any other error (the file cannot be read) is a file error (not).
    static func verify(_ url: URL) -> (verification: RoadPackVerification?, fileError: String?) {
        let clock = ContinuousClock()
        let start = clock.now
        func seconds() -> Double {
            let (s, attoseconds) = (clock.now - start).components
            return Double(s) + Double(attoseconds) / 1e18
        }
        do {
            let pack = try RoadPack(contentsOf: url, verify: true)
            let bounds = pack.pointBounds().map { RoadPackBounds(southWest: $0.southWest, northEast: $0.northEast) }
            return (RoadPackVerification(
                verified: true, refusal: nil, verifySeconds: seconds(),
                contentHash: NavigationSeed.hex(pack.contentHash), formatVersion: Int(pack.formatVersion),
                osmTimestamp: pack.osmTimestamp, gridID: NavigationSeed.hex(pack.gridID), bounds: bounds,
                hasCoverage: pack.hasCoverage), nil)
        } catch let error as RoadPackError {
            // The header, when it opens: what the refused file claims to be.
            let header = try? RoadPack(contentsOf: url, verify: false)
            return (RoadPackVerification(
                verified: false, refusal: error.description, verifySeconds: seconds(),
                contentHash: header.map { NavigationSeed.hex($0.contentHash) },
                formatVersion: header.map { Int($0.formatVersion) }, osmTimestamp: header?.osmTimestamp,
                gridID: header.map { NavigationSeed.hex($0.gridID) }), nil)
        } catch {
            return (nil, "cannot read the file: \(error.localizedDescription)")
        }
    }
}
