import DriveLoggerCore
import Foundation

/// A route that ends short of the destination (prompt 53a item 3): the provider routes to the nearest
/// road, so its last point can lie some way from the point the driver named. Pure geometry; no MapKit.
///
/// The last leg is the straight segment from the route's last point (`end`) to the destination.
/// It exists only above `thresholdM`; at or below it the route "reaches" the destination and
/// nothing about guidance or arrival differs from a route that ends on it.
struct LastLeg: Equatable, Sendable {
    /// The one constant: a route whose last point is farther than this from the destination has a last leg.
    static let thresholdM = 50.0
    /// The car has reached the route's end when this close to it along the route (guidance only).
    static let routeEndReachedM = 30.0
    /// The car is on the last leg while within this of the segment (the same margin as the
    /// "Away from the route" guard, so the two never disagree about the corridor).
    static let corridorM = RouteGuidance.awayFromRouteM

    /// The route's last point.
    var end: GeoPoint
    var destination: GeoPoint
    /// Straight-line `end` to `destination`, metres; always above `thresholdM`.
    var gapM: Double

    /// The last leg of `route` towards `destination`, or nil when the route reaches it (gap of
    /// `thresholdM` or less) or has no points.
    static func measure(route: Route, to destination: GeoPoint) -> LastLeg? {
        guard let last = route.polyline.last else { return nil }
        let end = GeoPoint(latitude: last.latitude, longitude: last.longitude)
        let gap = distanceM(end, destination)
        guard gap.isFinite, gap > thresholdM else { return nil }
        return LastLeg(end: end, destination: destination, gapM: gap)
    }

    /// Straight-line distance from `point` to the destination.
    func distanceToDestinationM(from point: GeoPoint) -> Double { Self.distanceM(point, destination) }

    /// Distance from `point` to the segment `end` to `destination`.
    func distanceToLegM(from point: GeoPoint) -> Double {
        // Local metres around `end`.
        let (dx, dy) = Self.offsetM(from: end, to: destination)
        let (px, py) = Self.offsetM(from: end, to: point)
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return (px * px + py * py).squareRoot() }
        let t = min(max((px * dx + py * dy) / lengthSquared, 0), 1)
        let cx = px - t * dx, cy = py - t * dy
        return (cx * cx + cy * cy).squareRoot()
    }

    /// Whether `point` is within the corridor of the leg.
    func contains(_ point: GeoPoint) -> Bool { distanceToLegM(from: point) <= Self.corridorM }

    // Equirectangular, well under 1 % over the distances here.
    private static let metresPerDegree = 111_320.0

    private static func offsetM(from a: GeoPoint, to b: GeoPoint) -> (x: Double, y: Double) {
        let y = (b.latitude - a.latitude) * metresPerDegree
        let x = (b.longitude - a.longitude) * metresPerDegree * cos((a.latitude + b.latitude) / 2 * .pi / 180)
        return (x, y)
    }

    static func distanceM(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let (x, y) = offsetM(from: a, to: b)
        return (x * x + y * y).squareRoot()
    }
}
