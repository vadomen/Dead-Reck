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
        default:
            // Whenever the active route is drawn (guiding, and requesting / place card while a rebuild
            // waits), its leg is drawn with it.
            active?.lastLeg.map { [LastLegSegment(leg: $0, chosen: true)] } ?? []
        }
    }

    /// The glyph of the bar while the text is "Route ends N m before the destination".
    static let routeEndsGlyph = "arrow.up.forward"

    /// The gap for the bar's "Route ends N m before the destination" (R94.2-2): on the last leg, and
    /// once the last manoeuvre is passed (the next announced step is Apple's `arrive`, which counts down
    /// to a route end that is short of the destination). Nil otherwise: the normal instruction.
    /// The bar shows `routeEndsDistanceM` with it.
    var routeEndsGapM: Double? {
        guard let gap = active?.lastLeg?.gapM, let guidance else { return nil }
        switch guidance.status {
        case .lastLeg: return gap
        case .onRoute: return guidance.nextStep?.maneuver == .arrive ? gap : nil
        case .uncertain, .awayFromRoute: return nil
        }
    }

    /// The distance shown with `routeEndsGapM`: the straight line to the destination, the same quantity
    /// on the route end's approach and on the leg (it counts down without a jump at the route end, and
    /// is never less than the gap the text names).
    var routeEndsDistanceM: Double? {
        routeEndsGapM == nil ? nil : guidance?.distanceToDestinationM
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
