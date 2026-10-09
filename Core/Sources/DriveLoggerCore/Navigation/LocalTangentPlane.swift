import Foundation

/// Local east/north frame in metres, anchored at a WGS-84 position.
///
/// The navigation engine works in this plane; the anchor is the first
/// position information it accepts. North is `Δφ · M(φ₀)` with the meridian
/// radius of curvature at the anchor; east is `Δλ · N(φ) · cos φ` with the
/// prime-vertical radius at the point's own latitude, so distances along a
/// parallel are exact and the inverse is closed-form. Scale distortion grows
/// as `offset² · tan φ / R`: about 0.1 % at 5 km, which is well inside dead
/// reckoning error over the same distance.
public struct LocalTangentPlane: Hashable, Sendable {
    public let anchorLatitude: Double
    public let anchorLongitude: Double

    static let semiMajorAxis = 6_378_137.0
    static let eccentricitySquared = 6.694_379_990_14e-3

    private let meridianRadius: Double

    public init(latitude: Double, longitude: Double) {
        anchorLatitude = latitude
        anchorLongitude = longitude
        meridianRadius = Self.meridianRadius(latitudeRadians: latitude * .pi / 180)
    }

    /// M(φ): radius of curvature in the meridian.
    static func meridianRadius(latitudeRadians phi: Double) -> Double {
        let s = sin(phi)
        let w = 1 - eccentricitySquared * s * s
        return semiMajorAxis * (1 - eccentricitySquared) / (w * w.squareRoot())
    }

    /// N(φ): radius of curvature in the prime vertical.
    static func primeVerticalRadius(latitudeRadians phi: Double) -> Double {
        let s = sin(phi)
        return semiMajorAxis / (1 - eccentricitySquared * s * s).squareRoot()
    }

    /// East and north of a WGS-84 position, in metres from the anchor.
    public func enu(latitude: Double, longitude: Double) -> (east: Double, north: Double) {
        let phi = latitude * .pi / 180
        var dLon = longitude - anchorLongitude
        if dLon > 180 { dLon -= 360 } else if dLon < -180 { dLon += 360 }
        let north = (latitude - anchorLatitude) * .pi / 180 * meridianRadius
        let east = dLon * .pi / 180 * Self.primeVerticalRadius(latitudeRadians: phi) * cos(phi)
        return (east, north)
    }

    /// WGS-84 position of a point in this plane.
    public func geodetic(east: Double, north: Double) -> (latitude: Double, longitude: Double) {
        let latitude = anchorLatitude + north / meridianRadius * 180 / .pi
        let phi = latitude * .pi / 180
        let parallelRadius = Self.primeVerticalRadius(latitudeRadians: phi) * cos(phi)
        var longitude = anchorLongitude + east / parallelRadius * 180 / .pi
        if longitude > 180 { longitude -= 360 } else if longitude < -180 { longitude += 360 }
        return (latitude, longitude)
    }
}
