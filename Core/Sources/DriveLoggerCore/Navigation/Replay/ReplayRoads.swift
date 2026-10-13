import Foundation

// Roads in a replay (N3.2b, docs/N3_PLAN.md "N3.2" and "Metrics added to
// replay_nav"): the road set a run uses and how it is named in every output.
//
// Data: © OpenStreetMap contributors, ODbL 1.0.

/// The road network a replay gives its engine (`replay_nav --roads`, in
/// load order). Two road sets are equal when their packs' content hashes
/// are, in the same order: the identity a result records.
public struct ReplayRoadSet: Hashable, Sendable {
    public let network: RoadNetwork

    public init(_ network: RoadNetwork) {
        self.network = network
    }

    public static func == (a: ReplayRoadSet, b: ReplayRoadSet) -> Bool {
        a.network === b.network || a.network.packs.map(\.contentHash) == b.network.packs.map(\.contentHash)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(network.roadSetHash)
    }

    /// Per pack, in load order: what a result records.
    public var packs: [ReplayRoadPack] { network.packs.map(ReplayRoadPack.init) }

    /// FNV-1a 64 over the packs' content hashes in load order, 16 hex digits.
    public var roadSetHashHex: String { network.roadSetHashHex }

    /// The mode label's suffix: `roads-` and the first 8 hex digits of
    /// `roadSetHash`, so runs with and without roads (or with another road
    /// set) never share a `metrics.json` row or a GeoJSON file.
    public var labelSuffix: String { "roads-" + String(roadSetHashHex.prefix(8)) }
}

/// One road pack of a replay, as recorded in `metrics.json`, the summary
/// and the GeoJSON: enough to name the exact pack, nothing about where it
/// covers.
public struct ReplayRoadPack: Hashable, Sendable, Codable {
    /// 16 lowercase hex digits.
    public var contentHash: String
    public var formatVersion: Int
    /// The OSM data's replication timestamp, Unix seconds (0 when unknown).
    public var osmTimestamp: Int64
    /// 16 lowercase hex digits.
    public var gridID: String

    public init(contentHash: String, formatVersion: Int, osmTimestamp: Int64, gridID: String) {
        self.contentHash = contentHash
        self.formatVersion = formatVersion
        self.osmTimestamp = osmTimestamp
        self.gridID = gridID
    }

    public init(_ pack: RoadPack) {
        self.init(contentHash: NavigationSeed.hex(pack.contentHash), formatVersion: Int(pack.formatVersion),
                  osmTimestamp: pack.osmTimestamp, gridID: NavigationSeed.hex(pack.gridID))
    }

    /// "contentHash 0123…, format v1, OSM 2026-01-01T00:00:00Z, grid 89ab…".
    public var text: String {
        let date = osmTimestamp > 0
            ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(osmTimestamp)))
            : "unknown"
        return "contentHash \(contentHash), format v\(formatVersion), OSM \(date), grid \(gridID)"
    }
}
