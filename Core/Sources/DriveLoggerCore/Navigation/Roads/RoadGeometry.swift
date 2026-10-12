import Foundation

/// Plane geometry for road matching: point–segment distance, bearings, the
/// heading test and the layer/bridge/tunnel level rule (docs/N3_PLAN.md,
/// "Road model in the filter"). All arithmetic is Double on exact E7
/// integers, so results are the same on every platform.
public enum RoadGeometry {
    /// The point of a segment nearest to a query point.
    public struct Projection: Hashable, Sendable {
        /// Squared distance from the query point to `q`.
        public var distanceSquared: Double
        /// Position of `q` along the segment, 0 at the start, 1 at the end.
        public var t: Double
        public var qx: Double
        public var qy: Double
        /// True when `q` is strictly inside the segment (not an end vertex).
        public var isInterior: Bool { t > 0 && t < 1 }
        public var distance: Double { distanceSquared.squareRoot() }
    }

    /// The nearest point of segment a–b to p: the projection clamped to the
    /// segment. A zero-length segment projects to `a`.
    @inline(__always)
    public static func project(
        px: Double, py: Double, ax: Double, ay: Double, bx: Double, by: Double
    ) -> Projection {
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        var t = 0.0
        if lengthSquared > 0 {
            t = ((px - ax) * dx + (py - ay) * dy) / lengthSquared
            if t < 0 { t = 0 } else if t > 1 { t = 1 }
        }
        let qx = ax + t * dx, qy = ay + t * dy
        let ex = px - qx, ey = py - qy
        return Projection(distanceSquared: ex * ex + ey * ey, t: t, qx: qx, qy: qy)
    }

    /// Squared distance from p to segment a–b.
    @inline(__always)
    public static func distanceSquared(
        px: Double, py: Double, ax: Double, ay: Double, bx: Double, by: Double
    ) -> Double {
        project(px: px, py: py, ax: ax, ay: ay, bx: bx, by: by).distanceSquared
    }

    /// Squared distance between segment a–b and an axis-aligned rectangle
    /// (0 when they touch or intersect).
    public static func segmentRectangleDistanceSquared(
        a: (x: Double, y: Double), b: (x: Double, y: Double),
        minX: Double, minY: Double, maxX: Double, maxY: Double
    ) -> Double {
        func inside(_ p: (x: Double, y: Double)) -> Bool {
            p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
        }
        if inside(a) || inside(b) { return 0 }
        let corners = [(minX, minY), (maxX, minY), (maxX, maxY), (minX, maxY)]
        // A segment that crosses the rectangle crosses one of its sides.
        for i in 0..<4 {
            let c = corners[i], d = corners[(i + 1) % 4]
            if segmentsIntersect(a, b, (c.0, c.1), (d.0, d.1)) { return 0 }
        }
        var best = Double.infinity
        for i in 0..<4 {
            let c = corners[i], d = corners[(i + 1) % 4]
            // Distance between two disjoint segments: the minimum over the
            // four endpoint-to-segment distances.
            best = min(best, distanceSquared(px: a.x, py: a.y, ax: c.0, ay: c.1, bx: d.0, by: d.1))
            best = min(best, distanceSquared(px: b.x, py: b.y, ax: c.0, ay: c.1, bx: d.0, by: d.1))
            best = min(best, distanceSquared(px: c.0, py: c.1, ax: a.x, ay: a.y, bx: b.x, by: b.y))
        }
        return best
    }

    /// Whether segments p1–p2 and p3–p4 share a point (collinear overlaps
    /// and touching ends included).
    static func segmentsIntersect(
        _ p1: (x: Double, y: Double), _ p2: (x: Double, y: Double),
        _ p3: (x: Double, y: Double), _ p4: (x: Double, y: Double)
    ) -> Bool {
        func cross(_ o: (x: Double, y: Double), _ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        func onSegment(_ o: (x: Double, y: Double), _ a: (x: Double, y: Double), _ p: (x: Double, y: Double)) -> Bool {
            p.x >= min(o.x, a.x) && p.x <= max(o.x, a.x) && p.y >= min(o.y, a.y) && p.y <= max(o.y, a.y)
        }
        let d1 = cross(p3, p4, p1), d2 = cross(p3, p4, p2)
        let d3 = cross(p1, p2, p3), d4 = cross(p1, p2, p4)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) { return true }
        if d1 == 0 && onSegment(p3, p4, p1) { return true }
        if d2 == 0 && onSegment(p3, p4, p2) { return true }
        if d3 == 0 && onSegment(p1, p2, p3) { return true }
        if d4 == 0 && onSegment(p1, p2, p4) { return true }
        return false
    }

    // MARK: Bearings and headings

    /// Bearing of the direction (east, north), radians clockwise from north,
    /// in [0, 2π). 0 for a zero vector.
    @inline(__always)
    public static func bearing(east: Double, north: Double) -> Double {
        let b = atan2(east, north)
        return b < 0 ? b + 2 * .pi : b
    }

    /// Bearing from `a` to `b`, radians clockwise from north, on a local
    /// equirectangular approximation at their mid latitude (exact enough
    /// for segments up to a few km). Undefined (0) for a = b; a verified
    /// pack has no such segment (docs/ROAD_PACK.md, "Zero-length segments").
    public static func bearing(from a: RoadPoint, to b: RoadPoint) -> Double {
        let d = localOffset(from: a, to: b)
        return bearing(east: d.east, north: d.north)
    }

    /// Length of a–b in metres, same approximation as `bearing(from:to:)`.
    public static func distanceM(from a: RoadPoint, to b: RoadPoint) -> Double {
        let d = localOffset(from: a, to: b)
        return (d.east * d.east + d.north * d.north).squareRoot()
    }

    static func localOffset(from a: RoadPoint, to b: RoadPoint) -> (east: Double, north: Double) {
        let midLatitude = (Double(a.latE7) + Double(b.latE7)) / 2e7
        let k = RoadGrid.trueMetresPerE7(latitude: midLatitude)
        return (Double(Int64(b.lonE7) - Int64(a.lonE7)) * k.lon, Double(Int64(b.latE7) - Int64(a.latE7)) * k.lat)
    }

    /// `angle` wrapped to (−π, π].
    @inline(__always)
    public static func wrapPi(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi } else if a <= -.pi { a += 2 * .pi }
        return a
    }

    /// |Δψ| between a heading of travel and a segment of bearing β: for a
    /// two-way segment the smaller of |wrapPi(ψ − β)| and |wrapPi(ψ − β − π)|,
    /// for a oneway segment only the forward bearing counts.
    @inline(__always)
    public static func headingDifference(heading: Double, bearing: Double, oneway: Bool) -> Double {
        let forward = abs(wrapPi(heading - bearing))
        if oneway { return forward }
        return min(forward, .pi - forward)
    }

    // MARK: Level rule

    /// `roadLevel` value of a particle whose level is unknown.
    public static let unknownLevel = Int8.min
    public static let levelRange: ClosedRange<Int8> = -5...5

    /// level(e) from a way's tags: the `layer` tag clamped to −5…5 when it
    /// is an integer; otherwise +1 for `bridge` (not `no`), −1 for `tunnel`
    /// (not `no`, `building_passage` included); otherwise 0.
    public static func level(tags: [String: String]) -> Int8 {
        if let text = tags["layer"], let layer = Int(text.trimmingCharacters(in: .whitespaces)) {
            return Int8(max(Int(levelRange.lowerBound), min(Int(levelRange.upperBound), layer)))
        }
        if isBridge(tags: tags) { return 1 }
        if isTunnel(tags: tags) { return -1 }
        return 0
    }

    public static func isBridge(tags: [String: String]) -> Bool {
        guard let value = tags["bridge"] else { return false }
        return value != "no"
    }

    public static func isTunnel(tags: [String: String]) -> Bool {
        guard let value = tags["tunnel"] else { return false }
        return value != "no"
    }

    /// Whether a candidate edge at `candidateLevel` is eligible for a
    /// particle at `particleLevel`: the particle's level is unknown, or the
    /// levels are equal, or the candidate is within the allowed hops of the
    /// particle's edge (asked only when the levels differ).
    @inline(__always)
    public static func levelAllows(
        particleLevel: Int8, candidateLevel: Int8, withinHops: () -> Bool
    ) -> Bool {
        if particleLevel == unknownLevel || particleLevel == candidateLevel { return true }
        return withinHops()
    }
}
