import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// Synthetic road fixtures near (0, 0): ways given in local metres, written
/// as the OPL `osmium add-locations-to-ways -f opl` produces. No real
/// place or extract is involved.
enum RoadFixture {
    /// The family grid used by most tests: a box around (0, 0).
    static let familySouthWest = RoadPoint(latE7: -1_000_000, lonE7: -1_000_000)
    static let familyNorthEast = RoadPoint(latE7: 1_000_000, lonE7: 1_000_000)

    static func grid(cellSizeM: Double = 64, radiusM: Double = 50) -> RoadGrid {
        RoadGrid(southWest: familySouthWest, northEast: familyNorthEast, cellSizeM: cellSizeM, searchRadiusM: radiusM)
    }

    static let metresPerE7 = RoadGrid.trueMetresPerE7(latitude: 0)

    /// The E7 point `east`, `north` metres from (0, 0), rounded.
    static func point(_ east: Double, _ north: Double) -> RoadPoint {
        RoadPoint(latE7: Int32((north / metresPerE7.lat).rounded()), lonE7: Int32((east / metresPerE7.lon).rounded()))
    }

    /// Local metres of an E7 point (inverse of `point`, up to rounding).
    static func metres(_ p: RoadPoint) -> (east: Double, north: Double) {
        (Double(p.lonE7) * metresPerE7.lon, Double(p.latE7) * metresPerE7.lat)
    }

    /// E7 as OPL decimal degrees text, exactly.
    static func degrees(_ v: Int32) -> String {
        let a = abs(Int64(v))
        let fraction = String(a % 10_000_000)
        return (v < 0 ? "-" : "") + "\(a / 10_000_000)." + String(repeating: "0", count: 7 - fraction.count) + fraction
    }

    struct Node {
        var id: Int64
        var east: Double
        var north: Double
        var point: RoadPoint { RoadFixture.point(east, north) }
    }

    /// One OPL way line. Tag values must not need escaping.
    static func way(_ id: Int64, _ tags: [String: String], _ nodes: [Node]) -> String {
        let t = tags.keys.sorted().map { "\($0)=\(tags[$0]!)" }.joined(separator: ",")
        let n = nodes.map { node in
            let p = node.point
            return "n\(node.id)x\(degrees(p.lonE7))y\(degrees(p.latE7))"
        }.joined(separator: ",")
        return "w\(id) v1 dV c0 t2020-01-01T00:00:00Z i0 u T\(t) N\(n)"
    }

    static func build(
        _ lines: [String], classes: [String] = RoadGraphBuilder.regionClasses, grid: RoadGrid = grid(),
        coverage: [[RoadPoint]]? = nil
    ) throws -> RoadPack {
        let data = try buildData(lines, classes: classes, grid: grid, coverage: coverage)
        return try RoadPack(data: data)
    }

    static func buildData(
        _ lines: [String], classes: [String] = RoadGraphBuilder.regionClasses, grid: RoadGrid = grid(),
        coverage: [[RoadPoint]]? = nil
    ) throws -> Data {
        var parameters = RoadPackBuild.Parameters(classes: classes, grid: grid)
        parameters.coverage = coverage
        parameters.sourceName = "synthetic.osm.pbf"
        return try RoadPackBuild.build(opl: Data(lines.joined(separator: "\n").utf8), parameters: parameters).data
    }

    /// Edges of a pack, by way, in pack order.
    static func edges(of pack: RoadPack, way: Int64) -> [RoadEdgeRecord] {
        (0..<pack.edgeCount).map { pack.edge($0) }.filter { $0.osmWayID == way }
    }

    static func edgeIndices(of pack: RoadPack, way: Int64) -> [Int] {
        (0..<pack.edgeCount).filter { pack.edge($0).osmWayID == way }
    }

    /// Points of edge `index`.
    static func points(of pack: RoadPack, edge index: Int) -> [RoadPoint] {
        let r = pack.edge(index)
        return (0..<Int(r.pointCount)).map { pack.point(Int(r.firstPoint) + $0) }
    }

    /// Ways listed in the cell of the point `east`, `north` metres from (0, 0).
    static func waysNear(_ pack: RoadPack, _ east: Double, _ north: Double) -> Set<Int64> {
        let p = point(east, north)
        let c = pack.grid.cell(latitude: p.latitude, longitude: p.longitude)
        return Set(pack.segments(inCellX: c.cx, y: c.cy).map { pack.segment(startingAt: $0).key.osmWayID })
    }

    /// True-metre distance from a query point to a segment, in a local
    /// frame at the query's latitude (the brute-force reference).
    static func trueDistance(latE7: Double, lonE7: Double, _ a: RoadPoint, _ b: RoadPoint) -> Double {
        let k = RoadGrid.trueMetresPerE7(latitude: latE7 / 1e7)
        return RoadGeometry.distanceSquared(
            px: 0, py: 0,
            ax: (Double(a.lonE7) - lonE7) * k.lon, ay: (Double(a.latE7) - latE7) * k.lat,
            bx: (Double(b.lonE7) - lonE7) * k.lon, by: (Double(b.latE7) - latE7) * k.lat
        ).squareRoot()
    }
}
