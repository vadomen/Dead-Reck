import Foundation

/// A route polyline with its distances precomputed: cumulative distance,
/// projection of a point onto the line, the point at a distance along it,
/// and the turn angle at a vertex.
///
/// Geometry is planar per segment: each segment is measured in its own local
/// east/north frame scaled at its mid latitude (true meridian and parallel
/// radii, as `RoadGeometry.distanceM`), so a 30 km route's length carries no
/// error from a single anchor. Arithmetic is Double on exact E7 integers;
/// every loop runs in index order, so results are deterministic.
public struct RoutePolyline: Hashable, Sendable {
    public let points: [RoutePoint]
    /// `cumulativeDistanceM[i]`: metres along the line from point 0 to point
    /// `i`. Same count as `points`, starts at 0, never decreases.
    public let cumulativeDistanceM: [Double]
    /// Metres per E7 unit of latitude / longitude for segment `i`
    /// (`points[i]` → `points[i+1]`).
    let segmentMetresPerE7Lat: [Double]
    let segmentMetresPerE7Lon: [Double]

    /// Throws `tooFewPoints` for fewer than two points.
    public init(_ points: [RoutePoint]) throws {
        guard points.count >= 2 else { throw RouteError.tooFewPoints(points.count) }
        self.init(atLeastTwo: points)
    }

    /// The route's polyline (a `Route` always has at least two points).
    public init(route: Route) {
        self.init(atLeastTwo: route.polyline)
    }

    private init(atLeastTwo points: [RoutePoint]) {
        var cumulative: [Double] = [0]
        var kLat: [Double] = [], kLon: [Double] = []
        cumulative.reserveCapacity(points.count)
        kLat.reserveCapacity(points.count - 1)
        kLon.reserveCapacity(points.count - 1)
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            let k = RoadGrid.trueMetresPerE7(latitude: (Double(a.latE7) + Double(b.latE7)) / 2e7)
            kLat.append(k.lat)
            kLon.append(k.lon)
            let east = Self.lonDeltaE7(Double(b.lonE7) - Double(a.lonE7)) * k.lon
            let north = (Double(b.latE7) - Double(a.latE7)) * k.lat
            cumulative.append(cumulative[index - 1] + (east * east + north * north).squareRoot())
        }
        self.points = points
        cumulativeDistanceM = cumulative
        segmentMetresPerE7Lat = kLat
        segmentMetresPerE7Lon = kLon
    }

    /// Geometric length in metres.
    public var lengthM: Double { cumulativeDistanceM[cumulativeDistanceM.count - 1] }

    public var segmentCount: Int { points.count - 1 }

    /// Length of segment `index` in metres.
    public func segmentLengthM(_ index: Int) -> Double {
        cumulativeDistanceM[index + 1] - cumulativeDistanceM[index]
    }

    // MARK: Projection

    /// The point of the line nearest to a position.
    ///
    /// With `alongRangeM`, only segments that overlap that range of distance
    /// along are searched (for a route that passes the same place twice, or
    /// to track progress near the last known position); nil when none does.
    /// Ties go to the lower segment index.
    public func project(
        latitude: Double, longitude: Double, alongRangeM: ClosedRange<Double>? = nil
    ) -> RouteProjection? {
        let qLat = latitude * 1e7, qLon = longitude * 1e7
        var first = 0
        var last = segmentCount - 1
        if let range = alongRangeM {
            // Segment i overlaps the range when its end is at or after the
            // lower bound and its start at or before the upper bound.
            first = max(firstIndex(withCumulativeAtLeast: range.lowerBound) - 1, 0)
            last = min(firstIndex(withCumulativeAbove: range.upperBound) - 1, segmentCount - 1)
            if first > last { return nil }
        }
        var best: (index: Int, projection: RoadGeometry.Projection, cross: Double)?
        for index in first...last {
            let a = points[index], b = points[index + 1]
            let kLat = segmentMetresPerE7Lat[index], kLon = segmentMetresPerE7Lon[index]
            let bx = Self.lonDeltaE7(Double(b.lonE7) - Double(a.lonE7)) * kLon
            let by = (Double(b.latE7) - Double(a.latE7)) * kLat
            let px = Self.lonDeltaE7(qLon - Double(a.lonE7)) * kLon
            let py = (qLat - Double(a.latE7)) * kLat
            let projection = RoadGeometry.project(px: px, py: py, ax: 0, ay: 0, bx: bx, by: by)
            if best == nil || projection.distanceSquared < best!.projection.distanceSquared {
                best = (index, projection, bx * py - by * px)
            }
        }
        guard let best else { return nil }
        let index = best.index, a = points[index]
        let distance = best.projection.distance
        // Cross product of direction × offset: negative when the point is to
        // the right (east of a northbound segment).
        let crossTrack = best.cross > 0 ? -distance : distance
        let lat = Double(a.latE7) + best.projection.qy / segmentMetresPerE7Lat[index]
        let lon = Self.wrapLonE7(Double(a.lonE7) + best.projection.qx / segmentMetresPerE7Lon[index])
        return RouteProjection(
            segmentIndex: index,
            fraction: best.projection.t,
            distanceAlongM: cumulativeDistanceM[index] + best.projection.t * segmentLengthM(index),
            crossTrackM: crossTrack,
            latitude: lat / 1e7,
            longitude: lon / 1e7
        )
    }

    // MARK: Along the line

    /// The position `distanceM` along the line, clamped to [0, `lengthM`].
    public func position(atDistanceAlongM distanceM: Double) -> (latitude: Double, longitude: Double) {
        let p = positionE7(atDistanceAlongM: distanceM)
        return (p.lat / 1e7, p.lon / 1e7)
    }

    func positionE7(atDistanceAlongM distanceM: Double) -> (lat: Double, lon: Double) {
        let s = min(max(distanceM, 0), lengthM)
        // Last segment whose start is at or before s.
        let index = min(max(firstIndex(withCumulativeAbove: s) - 1, 0), segmentCount - 1)
        let a = points[index], b = points[index + 1]
        let length = segmentLengthM(index)
        let t = length > 0 ? min(max((s - cumulativeDistanceM[index]) / length, 0), 1) : 0
        let lat = Double(a.latE7) + t * (Double(b.latE7) - Double(a.latE7))
        let lon = Double(a.lonE7) + t * Self.lonDeltaE7(Double(b.lonE7) - Double(a.lonE7))
        return (lat, Self.wrapLonE7(lon))
    }

    /// Signed change of direction at vertex `vertex`, degrees in (−180, 180],
    /// positive = right (clockwise seen from above).
    ///
    /// The incoming direction is the chord from the point `chordLengthM`
    /// before the vertex to the point `junctionGapM` before it; the outgoing
    /// one from `junctionGapM` after the vertex to `chordLengthM` after it
    /// (distances along the line, clamped at its ends). The gap skips the
    /// junction itself, so a rounded corner or a short U-turn connector reads
    /// as the change between the roads on either side
    /// (`RouteManeuverThresholds`). A chord that clamps to nothing (a vertex
    /// within the gap of an end) falls back to running up to the vertex
    /// itself. 0 when a chord still has no length (an end vertex, or
    /// duplicate points).
    public func turnDegrees(atVertex vertex: Int, chordLengthM: Double, junctionGapM: Double = 0) -> Double {
        let s = cumulativeDistanceM[vertex]
        let v = points[vertex]
        let k = RoadGrid.trueMetresPerE7(latitude: v.latitude)
        func offset(_ from: (lat: Double, lon: Double), _ to: (lat: Double, lon: Double)) -> (east: Double, north: Double) {
            (Self.lonDeltaE7(to.lon - from.lon) * k.lon, (to.lat - from.lat) * k.lat)
        }
        func hasLength(_ d: (east: Double, north: Double)) -> Bool {
            (d.east * d.east + d.north * d.north).squareRoot() > 1e-6
        }
        let vertexE7 = (lat: Double(v.latE7), lon: Double(v.lonE7))
        let farBefore = positionE7(atDistanceAlongM: s - chordLengthM)
        let farAfter = positionE7(atDistanceAlongM: s + chordLengthM)
        var incoming = offset(farBefore, positionE7(atDistanceAlongM: s - junctionGapM))
        if !hasLength(incoming) { incoming = offset(farBefore, vertexE7) }
        var outgoing = offset(positionE7(atDistanceAlongM: s + junctionGapM), farAfter)
        if !hasLength(outgoing) { outgoing = offset(vertexE7, farAfter) }
        guard hasLength(incoming), hasLength(outgoing) else { return 0 }
        let change = RoadGeometry.bearing(east: outgoing.east, north: outgoing.north)
            - RoadGeometry.bearing(east: incoming.east, north: incoming.north)
        return RoadGeometry.wrapPi(change) * 180 / .pi
    }

    // MARK: Helpers

    /// First index whose cumulative distance is >= `s` (count if none).
    func firstIndex(withCumulativeAtLeast s: Double) -> Int {
        var low = 0, high = cumulativeDistanceM.count
        while low < high {
            let mid = (low + high) / 2
            if cumulativeDistanceM[mid] < s { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// First index whose cumulative distance is > `s` (count if none).
    func firstIndex(withCumulativeAbove s: Double) -> Int {
        var low = 0, high = cumulativeDistanceM.count
        while low < high {
            let mid = (low + high) / 2
            if cumulativeDistanceM[mid] <= s { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// A longitude difference in E7 units, wrapped across ±180°.
    static func lonDeltaE7(_ delta: Double) -> Double {
        if delta > 1.8e9 { return delta - 3.6e9 }
        if delta < -1.8e9 { return delta + 3.6e9 }
        return delta
    }

    static func wrapLonE7(_ lon: Double) -> Double {
        if lon > 1.8e9 { return lon - 3.6e9 }
        if lon < -1.8e9 { return lon + 3.6e9 }
        return lon
    }
}

/// A position projected onto a route polyline.
public struct RouteProjection: Hashable, Sendable {
    /// Segment `i` runs from polyline point `i` to point `i + 1`.
    public var segmentIndex: Int
    /// Position along that segment: 0 at its start, 1 at its end (clamped,
    /// so a position before the start or past the end projects to the end
    /// vertex).
    public var fraction: Double
    /// Metres along the polyline from its first point to the projection.
    public var distanceAlongM: Double
    /// Distance from the position to the line, signed: positive when the
    /// position is to the right of the direction of travel, negative to the
    /// left, 0 on the line.
    public var crossTrackM: Double
    /// The projected point.
    public var latitude: Double
    public var longitude: Double

    public init(
        segmentIndex: Int, fraction: Double, distanceAlongM: Double, crossTrackM: Double,
        latitude: Double, longitude: Double
    ) {
        self.segmentIndex = segmentIndex
        self.fraction = fraction
        self.distanceAlongM = distanceAlongM
        self.crossTrackM = crossTrackM
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// A route with its geometry precomputed, for progress along it: projection
/// and the distance to the next maneuver.
public struct RouteGeometry: Hashable, Sendable {
    public let route: Route
    public let polyline: RoutePolyline
    /// Distance along the polyline of each step's maneuver (its last vertex,
    /// `RouteStep.maneuverVertex`). Same count as `route.steps`.
    public let maneuverDistanceAlongM: [Double]

    public init(route: Route) {
        let polyline = RoutePolyline(route: route)
        self.route = route
        self.polyline = polyline
        maneuverDistanceAlongM = route.steps.map { polyline.cumulativeDistanceM[$0.maneuverVertex] }
    }

    public var lengthM: Double { polyline.lengthM }

    /// `RoutePolyline.project`.
    public func project(
        latitude: Double, longitude: Double, alongRangeM: ClosedRange<Double>? = nil
    ) -> RouteProjection? {
        polyline.project(latitude: latitude, longitude: longitude, alongRangeM: alongRangeM)
    }

    /// The first step whose maneuver lies strictly ahead of `distanceAlongM`
    /// (so a maneuver exactly at the position is behind it, and `depart` at
    /// 0 never comes next), or nil past the last one. Every step counts,
    /// `straight` ones included; the UI decides what to announce.
    public func nextManeuver(afterDistanceAlongM distanceAlongM: Double) -> RouteNextManeuver? {
        for (index, along) in maneuverDistanceAlongM.enumerated() where along > distanceAlongM {
            return RouteNextManeuver(
                stepIndex: index,
                maneuver: route.steps[index].maneuver,
                distanceAlongM: along,
                distanceToM: along - distanceAlongM
            )
        }
        return nil
    }
}

/// The next maneuver ahead of a position on the route.
public struct RouteNextManeuver: Hashable, Sendable {
    public var stepIndex: Int
    public var maneuver: RouteManeuver
    /// Metres along the polyline to the maneuver vertex.
    public var distanceAlongM: Double
    /// Metres from the position to the maneuver, along the polyline.
    public var distanceToM: Double

    public init(stepIndex: Int, maneuver: RouteManeuver, distanceAlongM: Double, distanceToM: Double) {
        self.stepIndex = stepIndex
        self.maneuver = maneuver
        self.distanceAlongM = distanceAlongM
        self.distanceToM = distanceToM
    }
}
