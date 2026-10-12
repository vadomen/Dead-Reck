import DriveLoggerCore
import Foundation

/// Turns OSM ways into a `RoadGraph` (docs/ROAD_PACK.md, "Builder").
///
/// - Keeps ways whose `highway` value is in `classes`, minus `area=yes`
///   and (by default) `service=parking_aisle`.
/// - Normalises direction: `oneway=-1` reverses the node list and makes it
///   forward-only; `yes`/`true`/`1` is forward-only; `motorway`,
///   `motorway_link`, `junction=roundabout` and `junction=circular` imply
///   oneway unless `oneway=no`; `reversible`/`alternating` and anything
///   else are two-way.
/// - Removes consecutive repeats of a node, and consecutive nodes with
///   equal E7 coordinates (distinct OSM nodes stacked on one spot), keeping
///   the first of each run. The resulting list is the way's normalised node
///   list; a segment's key is (way, index of its start in that list). The
///   list depends only on the way's own node IDs and locations, so a key is
///   the same in every pack built from the same data. No edge therefore has
///   a zero-length segment.
/// - Merges the node IDs of each such equal-coordinate run into one
///   topological node (the smallest ID), across all kept ways, so a way
///   that met the dropped node still meets the kept one.
/// - Splits ways into edges at topological nodes: nodes used more than
///   once (by two ways, or twice by one), way ends, and the neighbours of a
///   node without a location (the segments next to it are dropped).
///
/// Deterministic: ways are processed in ascending ID order, so the input
/// order does not matter. Dictionaries are lookup-only.
public struct RoadGraphBuilder {
    /// `highway` values kept (with `_link` variants listed explicitly).
    public var classes: Set<String>
    /// Drop `service=parking_aisle` (decided Q5: car parks are left to the
    /// off-road component).
    public var excludeParkingAisles = true

    public init(classes: Set<String>) {
        self.classes = classes
    }

    /// National highways: motorway, trunk, primary and their links.
    public static let nationalClasses: [String] = [
        "motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
    ]

    /// Region packs: every drivable class (decided Q2, Q5; `track` excluded).
    public static let regionClasses: [String] = [
        "motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
        "secondary", "secondary_link", "tertiary", "tertiary_link",
        "unclassified", "residential", "living_street", "service", "road",
    ]

    public struct Statistics: Hashable, Sendable, Codable {
        public var waysRead = 0
        public var waysKept = 0
        public var waysWrongClass = 0
        public var waysArea = 0
        public var waysParkingAisle = 0
        /// Kept ways with fewer than two located nodes.
        public var waysDegenerate = 0
        public var waysOneway = 0
        public var waysReversed = 0
        /// Node references without a location (segments next to them dropped).
        public var nodesWithoutLocation = 0
        /// Node references dropped from a normalised node list because their
        /// E7 coordinates equal the previous node's (a different node ID):
        /// each one would have been a zero-length segment.
        public var pointsAtRepeatedCoordinate = 0
        /// Distinct node IDs merged into another node at the same coordinates
        /// (each set counts its size − 1).
        public var nodesMerged = 0
        public var edges = 0
    }

    public struct BuildError: Error, CustomStringConvertible, Equatable {
        public var message: String
        public var description: String { message }
    }

    /// The direction rule for a way's tags.
    public enum Direction: Equatable, Sendable {
        case twoWay
        case forward(implied: Bool)
        case reversed
    }

    public static func direction(tags: [String: String]) -> Direction {
        switch tags["oneway"] {
        case "yes", "true", "1": return .forward(implied: false)
        case "-1", "reverse": return .reversed
        case "no", "false", "0", "reversible", "alternating": return .twoWay
        default:
            let highway = tags["highway"] ?? ""
            let junction = tags["junction"] ?? ""
            if highway == "motorway" || highway == "motorway_link" || junction == "roundabout" || junction == "circular" {
                return .forward(implied: true)
            }
            return .twoWay
        }
    }

    public func build(ways input: [OPLWay]) throws -> (graph: RoadGraph, statistics: Statistics) {
        var stats = Statistics()
        stats.waysRead = input.count
        let ways = input.sorted { $0.id < $1.id }
        for i in ways.indices.dropFirst() where ways[i].id == ways[i - 1].id {
            throw BuildError(message: "way \(ways[i].id) appears twice")
        }

        struct Kept {
            var way: OPLWay
            var roadClass: RoadClass
            var isLink: Bool
            var nodes: [OPLWay.NodeRef]
            var flags: RoadEdgeFlags
            var level: Int8
            var lanes: UInt8
        }
        var kept: [Kept] = []
        var merged = NodeMerger()
        for way in ways {
            guard let highway = way.tags["highway"], classes.contains(highway),
                  let parsed = RoadClass.parse(highway: highway) else {
                stats.waysWrongClass += 1
                continue
            }
            if way.tags["area"] == "yes" { stats.waysArea += 1; continue }
            if excludeParkingAisles, way.tags["service"] == "parking_aisle" { stats.waysParkingAisle += 1; continue }

            var nodes = way.nodes
            var flags: RoadEdgeFlags = []
            switch Self.direction(tags: way.tags) {
            case .twoWay: break
            case .forward(let implied):
                flags.insert(.oneway)
                if implied { flags.insert(.onewayImplied) }
            case .reversed:
                flags.insert(.oneway)
                nodes.reverse()
                stats.waysReversed += 1
            }
            if flags.contains(.oneway) { stats.waysOneway += 1 }
            var deduplicated: [OPLWay.NodeRef] = []
            deduplicated.reserveCapacity(nodes.count)
            for node in nodes {
                guard let last = deduplicated.last else { deduplicated.append(node); continue }
                if last.id == node.id { continue }
                if let a = last.location, a == node.location {
                    // A different node at the same E7 position: drop it and
                    // let the kept node stand for both.
                    stats.pointsAtRepeatedCoordinate += 1
                    merged.union(last.id, node.id)
                    continue
                }
                deduplicated.append(node)
            }
            // Ways dropped here still merge their stacked nodes: the
            // zero-length way joined them.
            if deduplicated.filter({ $0.location != nil }).count < 2 {
                stats.waysDegenerate += 1
                continue
            }
            if RoadGeometry.isBridge(tags: way.tags) { flags.insert(.bridge) }
            if RoadGeometry.isTunnel(tags: way.tags) { flags.insert(.tunnel) }
            if let junction = way.tags["junction"], junction == "roundabout" || junction == "circular" { flags.insert(.roundabout) }
            if parsed.isLink { flags.insert(.link) }
            var lanes: UInt8 = 0
            if let text = way.tags["lanes"], let value = Int(text.trimmingCharacters(in: .whitespaces)), value > 0 {
                lanes = UInt8(min(value, 255))
            }
            kept.append(Kept(
                way: way, roadClass: parsed.roadClass, isLink: parsed.isLink, nodes: deduplicated,
                flags: flags, level: RoadGeometry.level(tags: way.tags), lanes: lanes
            ))
        }
        stats.waysKept = kept.count

        // One ID per set of merged nodes. Nodes are merged only with nodes
        // at the same coordinates, which each way has already collapsed, so
        // this creates no new consecutive repeat.
        stats.nodesMerged = merged.mergedCount
        if stats.nodesMerged > 0 {
            for i in kept.indices {
                for j in kept[i].nodes.indices { kept[i].nodes[j].id = merged.representative(kept[i].nodes[j].id) }
            }
        }

        // Uses of each node across kept ways (lookup-only).
        var uses: [Int64: Int] = [:]
        for k in kept { for node in k.nodes { uses[node.id, default: 0] += 1 } }

        var edges: [RoadGraph.Edge] = []
        for k in kept {
            let nodes = k.nodes
            var pieceStart: Int?
            var points: [RoadPoint] = []
            func flush(endingAt index: Int) {
                guard let start = pieceStart, points.count >= 2 else { return }
                edges.append(RoadGraph.Edge(
                    fromNode: nodes[start].id, toNode: nodes[index].id, points: points,
                    osmWayID: k.way.id, wayPointOffset: UInt32(start), highwayClass: k.roadClass,
                    level: k.level, flags: k.flags, lanes: k.lanes
                ))
            }
            for i in nodes.indices {
                guard let location = nodes[i].location else {
                    stats.nodesWithoutLocation += 1
                    if let _ = pieceStart, i > 0 { flush(endingAt: i - 1) }
                    pieceStart = nil
                    points = []
                    continue
                }
                if pieceStart == nil {
                    pieceStart = i
                    points = [location]
                    continue
                }
                points.append(location)
                let isLast = i == nodes.count - 1 || nodes[i + 1].location == nil
                if isLast || (uses[nodes[i].id] ?? 0) > 1 {
                    flush(endingAt: i)
                    pieceStart = i
                    points = [location]
                }
            }
        }
        stats.edges = edges.count
        return (RoadGraph(edges: edges), stats)
    }
}

/// Union–find over node IDs whose representative is the smallest ID of its
/// set, so the result does not depend on the order of the unions. The
/// dictionary is lookup-only.
struct NodeMerger {
    private var parent: [Int64: Int64] = [:]
    private(set) var mergedCount = 0

    func representative(_ id: Int64) -> Int64 {
        var x = id
        while let p = parent[x], p != x { x = p }
        return x
    }

    mutating func union(_ a: Int64, _ b: Int64) {
        let ra = representative(a), rb = representative(b)
        guard ra != rb else { return }
        let (low, high) = ra < rb ? (ra, rb) : (rb, ra)
        parent[high] = low
        mergedCount += 1
        // Keep chains short: point both inputs at the root.
        if a != low { parent[a] = low }
        if b != low { parent[b] = low }
    }
}
