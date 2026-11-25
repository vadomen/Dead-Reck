import DriveLoggerCore
import Foundation

/// Progress along the active route (prompt 52 item 4). Pure: the position is
/// Core's projection of the FuGPS estimate onto the polyline.
struct RouteGuidance: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// On the route: distances are valid.
        case onRoute
        /// The estimate is uncertain or missing: the bar says so, no distance.
        case uncertain
        /// The estimate is farther than `awayFromRouteM` from the route (a
        /// display guard, not off-route detection: nothing rebuilds by itself).
        case awayFromRoute
        /// Past the end of a route that ends short of the destination (`LastLeg`), on the
        /// straight leg to it: the bar shows the straight-line distance to the destination.
        /// The away guard does not apply here.
        case lastLeg
    }

    /// Display guard: beyond this cross-track distance the bar offers Rebuild.
    static let awayFromRouteM = 150.0

    var status: Status
    /// Metres along the polyline; nil unless `.onRoute`.
    var alongM: Double?
    var remainingM: Double?
    var remainingTimeS: Double?
    var next: RouteNextManeuver?
    /// The next maneuver's step (its instruction text).
    var nextStep: RouteStep?
    var crossTrackM: Double?
    /// Straight-line to the destination; set only for a route with a last leg (the
    /// estimate known, any status but uncertain). Arrival is measured on it.
    var distanceToDestinationM: Double?
    /// `.uncertain` because there is no speed source while not standing (`NoSpeedSourceRule`): the
    /// bar names the reason instead of a distance.
    var noSpeedSource = false

    /// `previousAlongM`: where the car was last, so a route that passes the
    /// same place twice is read in order (a window around the last progress,
    /// widened to the whole route when nothing fits).
    ///
    /// `lastLeg`: the route ends short of the destination (nil: it reaches it, nothing changes).
    /// The car is on the last leg when it is within `LastLeg.corridorM` of the straight
    /// segment from the route's end to the destination AND has reached the route's end:
    /// within `LastLeg.routeEndReachedM` of it along the route, or `lastLegReached` (the
    /// flow remembers that it got there, so a car 200 m down the leg is not "away").
    static func compute(
        geometry: RouteGeometry, estimate: NavDisplay?, previousAlongM: Double? = nil,
        lastLeg: LastLeg? = nil, lastLegReached: Bool = false
    ) -> RouteGuidance {
        if estimate?.noSpeedSource == true { return RouteGuidance(status: .uncertain, noSpeedSource: true) }
        guard let estimate, !PositionStatus.isFinding(estimate) else {
            return RouteGuidance(status: .uncertain)
        }
        let toDestination = lastLeg?.distanceToDestinationM(from: estimate.position)
        let onLeg = lastLeg?.contains(estimate.position) ?? false
        func onLastLeg(along: Double) -> RouteGuidance {
            RouteGuidance(
                status: .lastLeg, alongM: along, crossTrackM: lastLeg?.distanceToLegM(from: estimate.position),
                distanceToDestinationM: toDestination)
        }
        if lastLegReached, onLeg { return onLastLeg(along: geometry.lengthM) }
        var projection: RouteProjection?
        if let previousAlongM {
            projection = geometry.project(
                latitude: estimate.position.latitude, longitude: estimate.position.longitude,
                alongRangeM: max(0, previousAlongM - 200)...(previousAlongM + 3_000))
        }
        if projection == nil || abs(projection!.crossTrackM) > awayFromRouteM {
            let whole = geometry.project(latitude: estimate.position.latitude, longitude: estimate.position.longitude)
            if let whole, projection == nil || abs(whole.crossTrackM) < abs(projection!.crossTrackM) { projection = whole }
        }
        guard let projection else { return RouteGuidance(status: .uncertain) }
        let along = projection.distanceAlongM
        if onLeg, geometry.lengthM - along <= LastLeg.routeEndReachedM { return onLastLeg(along: geometry.lengthM) }
        if abs(projection.crossTrackM) > awayFromRouteM {
            return RouteGuidance(
                status: .awayFromRoute, crossTrackM: projection.crossTrackM, distanceToDestinationM: toDestination)
        }
        let length = max(geometry.lengthM, 1)
        let remaining = max(0, geometry.lengthM - along)
        let ahead = nextAnnounced(geometry, afterAlongM: along)
        return RouteGuidance(
            status: .onRoute, alongM: along, remainingM: remaining,
            remainingTimeS: geometry.route.expectedTravelTimeS * remaining / length,
            next: ahead.maneuver, nextStep: ahead.step, crossTrackM: projection.crossTrackM,
            distanceToDestinationM: toDestination)
    }

    /// The first step ahead with something to say: not the empty `depart`.
    private static func nextAnnounced(
        _ geometry: RouteGeometry, afterAlongM along: Double
    ) -> (maneuver: RouteNextManeuver?, step: RouteStep?) {
        var from = along
        while let next = geometry.nextManeuver(afterDistanceAlongM: from) {
            let step = geometry.route.steps[next.stepIndex]
            if !(step.maneuver == .depart && step.instruction.isEmpty) { return (next, step) }
            from = next.distanceAlongM
        }
        return (nil, nil)
    }
}

/// Arrival (user amendment 1): remaining distance (along the route, or for a route with a last
/// leg the straight line to the destination point: `RouteGuidance.distanceToDestinationM`) under
/// `radiusM` and the car stopped (speed under `stoppedBelowMS`) for
/// `holdS` seconds in a row. Any frame that does not meet both restarts the hold.
struct ArrivalDetector: Equatable, Sendable {
    static let radiusM = 50.0
    static let stoppedBelowMS = 1.0
    static let holdS = 3.0

    private var since: TimeInterval?

    /// True once the conditions have held for `holdS`. `speedMS` nil (unknown)
    /// is not stopped; `remainingM` nil (uncertain, away) restarts the hold.
    mutating func update(remainingM: Double?, speedMS: Double?, now: TimeInterval) -> Bool {
        guard let remainingM, remainingM < Self.radiusM, let speedMS, speedMS < Self.stoppedBelowMS else {
            since = nil
            return false
        }
        if since == nil { since = now }
        return now - since! >= Self.holdS
    }

    mutating func reset() { since = nil }
}
