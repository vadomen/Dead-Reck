import Foundation

/// The uniform grid of a road pack family (docs/ROAD_PACK.md, "Grid").
///
/// A pack-family frame in metres, linear in E7 degrees:
/// `x = (lonE7 − originLonE7) · metresPerE7Lon`,
/// `y = (latE7 − originLatE7) · metresPerE7Lat`, with both scales taken at
/// the family's centre latitude. A cell is `(⌊x / cellSizeM⌋, ⌊y / cellSizeM⌋)`.
///
/// Every pack from one build run shares the grid, so a cell is the same area
/// in each and the grid ID (FNV-1a 64 of header bytes 56–95) tells whether
/// two packs can be used together. A segment is listed in every cell whose
/// rectangle lies within `effectiveRadiusM` of it in this frame, so all
/// segments within `searchRadiusM` true metres of any point in a cell are
/// in that cell's list: one lookup per query.
public struct RoadGrid: Hashable, Sendable, Codable {
    public var originLatE7: Int32
    public var originLonE7: Int32
    public var metresPerE7Lat: Double
    public var metresPerE7Lon: Double
    public var cellSizeM: Double
    /// The guaranteed search radius in true metres.
    public var searchRadiusM: Double

    public init(
        originLatE7: Int32, originLonE7: Int32, metresPerE7Lat: Double, metresPerE7Lon: Double,
        cellSizeM: Double, searchRadiusM: Double
    ) {
        self.originLatE7 = originLatE7
        self.originLonE7 = originLonE7
        self.metresPerE7Lat = metresPerE7Lat
        self.metresPerE7Lon = metresPerE7Lon
        self.cellSizeM = cellSizeM
        self.searchRadiusM = searchRadiusM
    }

    /// The default cell size, metres (docs/ROAD_PACK.md, measured in N3.1).
    public static let defaultCellSizeM = 64.0
    /// The default guaranteed search radius, metres (`roadSearchRadiusM`).
    public static let defaultSearchRadiusM = 50.0

    /// The family grid for a bounding box: origin at its south-west corner,
    /// scales at its centre latitude on the WGS-84 ellipsoid.
    public init(
        southWest: RoadPoint, northEast: RoadPoint,
        cellSizeM: Double = RoadGrid.defaultCellSizeM, searchRadiusM: Double = RoadGrid.defaultSearchRadiusM
    ) {
        let centreLatitude = (southWest.latitude + northEast.latitude) / 2
        let scale = Self.trueMetresPerE7(latitude: centreLatitude)
        self.init(
            originLatE7: southWest.latE7, originLonE7: southWest.lonE7,
            metresPerE7Lat: scale.lat, metresPerE7Lon: scale.lon,
            cellSizeM: cellSizeM, searchRadiusM: searchRadiusM
        )
    }

    /// True metres per E7 unit of latitude and of longitude at `latitude`
    /// (meridian and parallel radii of curvature, as `LocalTangentPlane`).
    public static func trueMetresPerE7(latitude: Double) -> (lat: Double, lon: Double) {
        let phi = latitude * .pi / 180
        let perRadian = Double.pi / 180 / 1e7
        let meridian = LocalTangentPlane.meridianRadius(latitudeRadians: phi)
        let parallel = LocalTangentPlane.primeVerticalRadius(latitudeRadians: phi) * cos(phi)
        return (meridian * perRadian, parallel * perRadian)
    }

    // MARK: Identity

    /// Header bytes 56–95: the grid's on-disk form.
    public var headerBytes: [UInt8] {
        var out = LittleEndianBytes()
        out.append(originLatE7)
        out.append(originLonE7)
        out.append(metresPerE7Lat)
        out.append(metresPerE7Lon)
        out.append(cellSizeM)
        out.append(searchRadiusM)
        return out.bytes
    }

    /// FNV-1a 64 of `headerBytes`.
    public var gridID: UInt64 { NavigationSeed.fnv1a64(headerBytes) }

    /// Why these parameters cannot index a pack, or nil.
    public var invalidReason: String? {
        let values = [metresPerE7Lat, metresPerE7Lon, cellSizeM, searchRadiusM]
        if !values.allSatisfy({ $0.isFinite && $0 > 0 }) { return "grid scales, cell size and radius must be finite and > 0" }
        if cellSizeM < 1 { return "cell size below 1 m" }
        return nil
    }

    // MARK: Frame and cells

    /// Frame coordinates of an E7 point, metres.
    @inline(__always)
    public func frame(_ point: RoadPoint) -> (x: Double, y: Double) {
        (Double(Int64(point.lonE7) - Int64(originLonE7)) * metresPerE7Lon,
         Double(Int64(point.latE7) - Int64(originLatE7)) * metresPerE7Lat)
    }

    /// Frame coordinates of a position in degrees, metres.
    @inline(__always)
    public func frame(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
        ((longitude * 1e7 - Double(originLonE7)) * metresPerE7Lon,
         (latitude * 1e7 - Double(originLatE7)) * metresPerE7Lat)
    }

    /// The cell containing frame point (x, y).
    @inline(__always)
    public func cell(x: Double, y: Double) -> (cx: Int32, cy: Int32) {
        (Self.clampedCell(x / cellSizeM), Self.clampedCell(y / cellSizeM))
    }

    /// The cell containing a position in degrees.
    @inline(__always)
    public func cell(latitude: Double, longitude: Double) -> (cx: Int32, cy: Int32) {
        let f = frame(latitude: latitude, longitude: longitude)
        return cell(x: f.x, y: f.y)
    }

    /// ⌊v⌋ clamped to Int32 (positions far outside a family land in edge
    /// cells that no pack lists, never trap).
    @inline(__always)
    static func clampedCell(_ v: Double) -> Int32 {
        let f = v.rounded(.down)
        if !(f >= Double(Int32.min)) { return Int32.min }
        if f > Double(Int32.max) { return Int32.max }
        return Int32(f)
    }

    /// The on-disk cell key: `cy << 32 | cx`, each as its 32-bit pattern.
    @inline(__always)
    public static func key(cx: Int32, cy: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: cy)) << 32 | UInt64(UInt32(bitPattern: cx))
    }

    @inline(__always)
    public static func cell(ofKey key: UInt64) -> (cx: Int32, cy: Int32) {
        (Int32(bitPattern: UInt32(truncatingIfNeeded: key)), Int32(bitPattern: UInt32(truncatingIfNeeded: key >> 32)))
    }

    // MARK: Guaranteed radius

    /// The frame's largest ratio of frame metres to true metres over the
    /// latitudes `minLatitude…maxLatitude` (≥ 1). Both radii of curvature
    /// are monotonic in |φ|, so the ends of the band (and the equator, if
    /// the band crosses it) bound it.
    public func maximumScale(minLatitude: Double, maxLatitude: Double) -> Double {
        var latitudes = [minLatitude, maxLatitude]
        if minLatitude < 0, maxLatitude > 0 { latitudes.append(0) }
        var worst = 1.0
        for latitude in latitudes {
            let truth = Self.trueMetresPerE7(latitude: max(-89.9, min(89.9, latitude)))
            worst = max(worst, metresPerE7Lat / truth.lat, metresPerE7Lon / truth.lon)
        }
        return worst
    }

    /// Relative slack on the frame radius for the straight-segment and
    /// short-distance approximations, and an absolute one in metres.
    public static let radiusSlackRelative = 1e-3
    public static let radiusSlackM = 0.05

    /// R_eff: the frame-metre radius that guarantees `searchRadiusM` true
    /// metres for data between these latitudes.
    public func effectiveRadiusM(minLatitude: Double, maxLatitude: Double) -> Double {
        // Query points up to a cell and the radius beyond the data count too.
        let marginDegrees = (cellSizeM + 2 * searchRadiusM) / 100_000
        let scale = maximumScale(minLatitude: minLatitude - marginDegrees, maxLatitude: maxLatitude + marginDegrees)
        return searchRadiusM * scale * (1 + Self.radiusSlackRelative) + Self.radiusSlackM
    }

    /// Calls `body` with every cell whose rectangle lies within `radius`
    /// frame metres of the segment (ax, ay)–(bx, by), in ascending key order
    /// within each row (row by row, south to north).
    public func forEachCell(
        nearSegmentFrom a: (x: Double, y: Double), to b: (x: Double, y: Double), radius: Double,
        _ body: (Int32, Int32) -> Void
    ) {
        let lo = cell(x: min(a.x, b.x) - radius, y: min(a.y, b.y) - radius)
        let hi = cell(x: max(a.x, b.x) + radius, y: max(a.y, b.y) + radius)
        let r2 = radius * radius
        var cy = lo.cy
        while cy <= hi.cy {
            var cx = lo.cx
            while cx <= hi.cx {
                let x0 = Double(cx) * cellSizeM, y0 = Double(cy) * cellSizeM
                let d2 = RoadGeometry.segmentRectangleDistanceSquared(
                    a: a, b: b, minX: x0, minY: y0, maxX: x0 + cellSizeM, maxY: y0 + cellSizeM
                )
                if d2 <= r2 { body(cx, cy) }
                if cx == Int32.max { break }
                cx += 1
            }
            if cy == Int32.max { break }
            cy += 1
        }
    }
}
