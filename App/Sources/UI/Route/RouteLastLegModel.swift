import DriveLoggerCore
import Foundation

/// What the last leg adds to the flow's read-only state (prompt 53a item 3): the gap per offered
/// route for the alternatives card, the dashed segments for the map layer, the points the camera
/// frames. Pure reads of the flow; nothing is stored.
struct LastLegSegment: Equatable, Sendable {
    var leg: LastLeg
    /// The chosen alternative, or the active route (drawn full strength); the other offered routes are muted.
    var chosen: Bool
}

extension RouteFlowModel {
    /// The last leg of an offered alternative towards the card's place; nil when it reaches it.
    func lastLeg(ofAlternative index: Int) -> LastLeg? {
        guard alternatives.indices.contains(index), let place else { return nil }
        return LastLeg.measure(route: alternatives[index], to: place.coordinate)
    }

    /// The segments to draw: every offered alternative's, or the active route's.
    var lastLegSegments: [LastLegSegment] {
        switch phase {
        case .alternatives:
            alternatives.indices.compactMap { index in
                lastLeg(ofAlternative: index).map { LastLegSegment(leg: $0, chosen: index == chosenIndex) }
            }
        case .guiding:
            active?.lastLeg.map { [LastLegSegment(leg: $0, chosen: true)] } ?? []
        default:
            []
        }
    }

    /// The points the camera frames when the alternatives appear: the chosen route and, when it ends
    /// short of the destination, the destination too.
    var framingPoints: [(latitude: Double, longitude: Double)]? {
        guard let route = chosenRoute else { return nil }
        var points = route.polyline.map { (latitude: $0.latitude, longitude: $0.longitude) }
        if let leg = lastLeg(ofAlternative: chosenIndex) { points.append((leg.destination.latitude, leg.destination.longitude)) }
        return points
    }
}

extension RouteFormat {
    /// "Route ends 300 m before the destination" (card line and bar text).
    static func routeEnds(gapM: Double) -> String {
        String(localized: "Route ends \(distance(gapM)) before the destination")
    }
}
