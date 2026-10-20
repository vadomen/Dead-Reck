import Foundation

/// One OSM way's run of road as a polyline, for drawing a pack's roads on a
/// map (the demo pack's overlay, REL-DEMO).
///
/// Data: © OpenStreetMap contributors, ODbL 1.0.
public struct RoadPolyline: Hashable, Sendable {
    public var osmWayID: Int64
    public var highwayClass: RoadClass
    /// Drivable only in point order.
    public var isOneway: Bool
    /// Shape points in way order (driving order for a oneway), ≥ 2. WGS-84
    /// through `RoadPoint.latitude` / `longitude`.
    public var points: [RoadPoint]
}

extension RoadPack {
    /// Every road of the pack as polylines, one per contiguous run of a way
    /// (a way's consecutive edges are joined), in edge order. Meant for a
    /// small pack such as the demo pack: it reads every edge.
    public func polylines(classes: Set<RoadClass> = Set(RoadClass.allCases)) -> [RoadPolyline] {
        var out: [RoadPolyline] = []
        var lastEnd: (way: Int64, index: UInt32)?
        for e in 0..<edgeCount {
            let r = edge(e)
            guard classes.contains(r.highwayClass) else {
                lastEnd = nil
                continue
            }
            let first = Int(r.firstPoint), count = Int(r.pointCount)
            let continues = lastEnd.map { $0.way == r.osmWayID && $0.index == r.wayPointOffset } ?? false
            if continues {
                for k in (first + 1)..<(first + count) { out[out.count - 1].points.append(point(k)) }
            } else {
                out.append(RoadPolyline(
                    osmWayID: r.osmWayID, highwayClass: r.highwayClass, isOneway: r.flags.contains(.oneway),
                    points: (first..<(first + count)).map { point($0) }
                ))
            }
            lastEnd = (r.osmWayID, r.wayPointOffset + r.pointCount - 1)
        }
        return out
    }
}
