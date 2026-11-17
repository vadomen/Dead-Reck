import DriveLoggerCore
import Foundation

/// The pure half of the MapKit route adapter (prompt 52 item 1): plain
/// numbers in, a Core `Route` out. The thin MapKit-reading half
/// (`MapKitRouteDirector`) copies an `MKRoute` into `DirectionsRouteInput`.
struct DirectionsRouteInput: Sendable {
    struct Point: Hashable, Sendable {
        var latitude: Double
        var longitude: Double
    }

    struct Step: Sendable {
        var instruction: String
        var distanceM: Double
        /// The step's own polyline. The first ("depart") step has none or one point.
        var points: [Point]
    }

    var points: [Point]
    var steps: [Step]
    var distanceM: Double
    var expectedTravelTimeS: Double
}

enum RouteConversion {
    /// Two points closer than this (about 1 m) are the same vertex when a step's
    /// last point is looked up in the route's polyline.
    static let vertexToleranceM = 1.0
    /// Metres per degree of latitude, for that comparison only.
    private static let metresPerDegree = 111_320.0

    /// The `Route`, or nil when MapKit's polyline is unusable (fewer than two
    /// valid points). Steps get their polyline range by walking forward through
    /// the route's points: each step ends at the first vertex at or after the
    /// previous step's end that equals the step's own last point; a step whose
    /// end cannot be found keeps the previous end (a point-like step). The
    /// empty first step stays in the data as `depart` at vertex 0. Maneuvers come
    /// from Core's geometry (`RouteManeuver.computed`).
    static func route(from input: DirectionsRouteInput, id: String, label: String?) -> Route? {
        let points = input.points.compactMap { RoutePoint(latitude: $0.latitude, longitude: $0.longitude) }
        guard points.count >= 2, points.count == input.points.count,
              let polyline = try? RoutePolyline(points) else { return nil }
        var ranges: [ClosedRange<Int>] = []
        var cursor = 0
        for step in input.steps {
            let from = cursor
            if let last = step.points.last, let end = vertex(of: last, in: points, from: cursor) {
                cursor = end
            }
            ranges.append(from...cursor)
        }
        // The route ends where its last step ends: close any remaining stretch.
        if !ranges.isEmpty, let lastRange = ranges.last, lastRange.upperBound < points.count - 1,
           input.steps.last?.points.last == nil || isNear(input.steps.last?.points.last, points[points.count - 1]) {
            ranges[ranges.count - 1] = lastRange.lowerBound...(points.count - 1)
        }
        guard let maneuvers = try? RouteManeuver.computed(polyline: polyline, stepRanges: ranges) else { return nil }
        let steps = zip(zip(input.steps, ranges), maneuvers).map { pair, maneuver in
            RouteStep(
                instruction: pair.0.instruction, distanceM: max(0, pair.0.distanceM.isFinite ? pair.0.distanceM : 0),
                polylineRange: pair.1, maneuver: maneuver)
        }
        return try? Route(
            id: id, polyline: points, steps: steps,
            distanceM: input.distanceM.isFinite ? max(0, input.distanceM) : polyline.lengthM,
            expectedTravelTimeS: input.expectedTravelTimeS.isFinite ? max(0, input.expectedTravelTimeS) : 0,
            source: .appleMaps, label: label)
    }

    private static func isNear(_ a: DirectionsRouteInput.Point?, _ b: RoutePoint) -> Bool {
        guard let a else { return false }
        return distanceM(a.latitude, a.longitude, b.latitude, b.longitude) <= vertexToleranceM * 5
    }

    private static func vertex(of point: DirectionsRouteInput.Point, in points: [RoutePoint], from start: Int) -> Int? {
        for index in start..<points.count
        where distanceM(point.latitude, point.longitude, points[index].latitude, points[index].longitude) <= vertexToleranceM {
            return index
        }
        return nil
    }

    private static func distanceM(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let dLat = (lat2 - lat1) * metresPerDegree
        let dLon = (lon2 - lon1) * metresPerDegree * cos((lat1 + lat2) / 2 * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }

    /// The steps the driver sees: the empty first step (no instruction) is
    /// dropped from display, not from the data.
    static func displaySteps(_ route: Route) -> [RouteStep] {
        route.steps.filter { !($0.maneuver == .depart && $0.instruction.isEmpty) }
    }
}
