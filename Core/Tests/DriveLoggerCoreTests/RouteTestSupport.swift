import Foundation

@testable import DriveLoggerCore

/// Synthetic route polylines for the route model tests. Origins are invented
/// points in open ocean, far from any recorded drive.
enum RouteFixture {
    /// Open ocean on the equator.
    static let equator = (latitude: 0.0, longitude: 0.0)
    /// Open ocean in the far south, where a degree of longitude is half as long.
    static let south = (latitude: -60.0, longitude: -150.0)
    /// Open ocean in the South Pacific.
    static let pacific = (latitude: -45.0, longitude: -120.0)

    /// Points at east/north offsets in metres from an origin.
    static func points(
        _ offsets: [(east: Double, north: Double)],
        origin: (latitude: Double, longitude: Double) = equator
    ) -> [RoutePoint] {
        let plane = LocalTangentPlane(latitude: origin.latitude, longitude: origin.longitude)
        return offsets.map { offset in
            let p = plane.geodetic(east: offset.east, north: offset.north)
            return RoutePoint(latitude: p.latitude, longitude: p.longitude)!
        }
    }

    /// MapKit-style steps over break vertices: a one-point `depart` step at
    /// vertex 0, then one step ending at each break, the last ending at the
    /// final vertex; maneuvers computed from geometry.
    static func steps(polyline: RoutePolyline, breaks: [Int], instruction: (Int) -> String = { _ in "" }) throws
        -> [RouteStep]
    {
        var ranges: [ClosedRange<Int>] = [0...0]
        var from = 0
        for end in breaks + [polyline.points.count - 1] {
            ranges.append(from...end)
            from = end
        }
        let maneuvers = try RouteManeuver.computed(polyline: polyline, stepRanges: ranges)
        return ranges.enumerated().map { index, range in
            RouteStep(
                instruction: instruction(index),
                distanceM: polyline.cumulativeDistanceM[range.upperBound] - polyline.cumulativeDistanceM[range.lowerBound],
                polylineRange: range,
                maneuver: maneuvers[index]
            )
        }
    }

    static func route(
        _ points: [RoutePoint], breaks: [Int] = [], id: String = "test", label: String? = nil,
        instruction: (Int) -> String = { _ in "" }
    ) throws -> Route {
        let polyline = try RoutePolyline(points)
        return try Route(
            id: id, polyline: points,
            steps: steps(polyline: polyline, breaks: breaks, instruction: instruction),
            distanceM: polyline.lengthM.rounded(), expectedTravelTimeS: (polyline.lengthM / 10).rounded(),
            source: .synthetic, label: label
        )
    }

    /// A deterministic city-like route: `count` points `spacingM` apart whose
    /// heading wanders, with a 90° turn every `turnEvery` points.
    static func wandering(count: Int, spacingM: Double, turnEvery: Int,
                          origin: (latitude: Double, longitude: Double) = pacific) -> [RoutePoint] {
        var east = 0.0, north = 0.0, heading = 0.6
        var offsets: [(east: Double, north: Double)] = [(0, 0)]
        for index in 1..<count {
            if index % turnEvery == 0 { heading += index % (2 * turnEvery) == 0 ? .pi / 2 : -.pi / 2 }
            heading += 0.05 * sin(Double(index) * 0.7)
            east += spacingM * sin(heading)
            north += spacingM * cos(heading)
            offsets.append((east, north))
        }
        return points(offsets, origin: origin)
    }

    /// JSON with `LogCodec`'s encoder settings (sorted keys, unescaped slashes).
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func string(_ value: some Encodable) throws -> String {
        String(decoding: try encode(value), as: UTF8.self)
    }
}
