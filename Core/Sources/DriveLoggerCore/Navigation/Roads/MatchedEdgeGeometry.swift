import Foundation

/// The matched edge's shape, for the map's debug drawing of the edge the
/// road update favours (N3.4 item 6). Built from the attached
/// `RoadNetwork`; carried by `NavigationSnapshot.matchedEdgeGeometry`. Never
/// written to the sidecar.
///
/// Data: © OpenStreetMap contributors, ODbL 1.0.
public struct MatchedEdgeGeometry: Hashable, Sendable {
    /// The edge (`NavigationEstimate.matchedEdge`): pack index in the
    /// network's canonical order, edge index in that pack, OSM way.
    public var edge: MatchedRoadEdge
    /// The network the indices refer to (`RoadNetwork.roadSetHash`).
    public var roadSetHash: UInt64
    /// Shape points in edge order, both end nodes included (≥ 2). WGS-84
    /// through `RoadPoint.latitude` / `longitude`.
    public var points: [RoadPoint]
    public var highwayClass: RoadClass
    /// Level for the layer rule, −5…5.
    public var level: Int8

    /// nil when `edge` is not an edge of `network` (`RoadNetwork.points(of:)`).
    public init?(edge: MatchedRoadEdge, network: RoadNetwork) {
        guard let points = network.points(of: edge) else { return nil }
        let record = network.packs[edge.pack].edge(edge.edge)
        self.edge = edge
        roadSetHash = network.roadSetHash
        self.points = points
        highwayClass = record.highwayClass
        level = record.level
    }

    /// Keeps the last geometry so a reader polling at 10 Hz rebuilds it only
    /// when the matched edge (or the network) changes: otherwise one
    /// comparison and a copy-on-write array reference.
    public struct Cache: Sendable {
        public private(set) var last: MatchedEdgeGeometry?
        /// Geometries built so far (tests).
        public private(set) var builds = 0

        public init() {}

        /// The geometry of `edge` in `network`; nil when either is nil or
        /// the edge is not in the network. A nil answer keeps the last
        /// geometry for a later match of the same edge.
        public mutating func geometry(for edge: MatchedRoadEdge?, in network: RoadNetwork?) -> MatchedEdgeGeometry? {
            guard let edge, let network else { return nil }
            if let last, last.edge == edge, last.roadSetHash == network.roadSetHash { return last }
            guard let built = MatchedEdgeGeometry(edge: edge, network: network) else { return nil }
            builds += 1
            last = built
            return built
        }
    }
}
