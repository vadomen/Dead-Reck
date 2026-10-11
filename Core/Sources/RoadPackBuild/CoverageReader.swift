import DriveLoggerCore
import Foundation

/// Reads a pack's coverage polygon from GeoJSON: a `Polygon` or
/// `MultiPolygon` geometry, a `Feature` holding one, or a
/// `FeatureCollection` whose first feature holds one (as `osmium extract`
/// reads it). Every ring of every polygon is kept and the result is used
/// with the even-odd rule, which is exact for non-overlapping polygons
/// with holes. Coordinates are rounded to E7; the closing repeat of a
/// ring's first point is dropped.
public enum CoverageReader {
    public struct CoverageError: Error, CustomStringConvertible, Equatable {
        public var message: String
        public var description: String { "coverage: \(message)" }
    }

    public static func rings(fromGeoJSON data: Data) throws -> [[RoadPoint]] {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let geometry = Self.geometry(in: value) else {
            throw CoverageError(message: "no Polygon or MultiPolygon geometry")
        }
        guard case .string(let type)? = geometry["type"], case .array(let coordinates)? = geometry["coordinates"] else {
            throw CoverageError(message: "geometry without type or coordinates")
        }
        let polygons: [JSONValue]
        switch type {
        case "Polygon": polygons = [.array(coordinates)]
        case "MultiPolygon": polygons = coordinates
        default: throw CoverageError(message: "geometry type \(type) is not a polygon")
        }
        var rings: [[RoadPoint]] = []
        for polygon in polygons {
            guard case .array(let polygonRings) = polygon else { throw CoverageError(message: "bad polygon") }
            for ring in polygonRings {
                guard case .array(let positions) = ring else { throw CoverageError(message: "bad ring") }
                var points: [RoadPoint] = []
                points.reserveCapacity(positions.count)
                for position in positions {
                    guard case .array(let pair) = position, pair.count >= 2,
                          let lon = number(pair[0]), let lat = number(pair[1]),
                          abs(lat) <= 90, abs(lon) <= 180 else {
                        throw CoverageError(message: "bad position")
                    }
                    points.append(RoadPoint(latE7: Int32((lat * 1e7).rounded()), lonE7: Int32((lon * 1e7).rounded())))
                }
                if points.count > 1, points.first == points.last { points.removeLast() }
                guard points.count >= 3 else { throw CoverageError(message: "ring with fewer than 3 points") }
                rings.append(points)
            }
        }
        guard !rings.isEmpty else { throw CoverageError(message: "no rings") }
        return rings
    }

    static func geometry(in value: JSONValue) -> [String: JSONValue]? {
        guard case .object(let object) = value, case .string(let type)? = object["type"] else { return nil }
        switch type {
        case "Polygon", "MultiPolygon": return object
        case "Feature":
            guard let geometry = object["geometry"] else { return nil }
            return Self.geometry(in: geometry)
        case "FeatureCollection":
            guard case .array(let features)? = object["features"], let first = features.first else { return nil }
            return Self.geometry(in: first)
        default: return nil
        }
    }

    static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .double(let d): d
        case .int(let i): Double(i)
        default: nil
        }
    }
}
