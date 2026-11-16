import DriveLoggerCore
import Foundation

/// A raw GNSS fix as the origin rule sees it.
struct RawFixInput: Equatable, Sendable {
    var point: GeoPoint
    /// Metres; negative = invalid.
    var horizontalAccuracy: Double
    /// Seconds since the fix was made.
    var ageS: Double
}

/// What the origin rule reads (prompt 52 item 3): all of it already on the
/// map, nothing new is polled.
struct RouteOriginInputs: Equatable, Sendable {
    /// Navigate or Record is running.
    var runActive = false
    /// The engine's estimate; nil before initialisation or without a run.
    var estimate: NavDisplay?
    var fix: RawFixInput?
    /// The driver's GPS switch is off ("GPS off", the fix is ignored).
    var gpsOff = false
    /// A pin the driver placed as "I'm here" for the route.
    var pin: GeoPoint?
}

/// The origin of a route request, from the state of the estimate.
enum RouteOriginChoice: Equatable, Sendable {
    /// (a) Converged and within `PositionStatus.maxSemiMajorM`: route from it.
    case estimate(GeoPoint)
    /// (b) The estimate is flagged uncertain (`PositionStatus.isFinding`): the
    /// card says so and offers the pin first; "Route anyway" stays secondary.
    case uncertain(estimate: GeoPoint, pin: GeoPoint?)
    /// (c) No estimate, but a good fresh raw fix.
    case fix(GeoPoint)
    /// (c) No estimate and no usable fix: the card asks for a pin.
    case needsPin(pin: GeoPoint?)
}

/// A resolved origin: where the request starts and what it came from.
struct ResolvedOrigin: Equatable, Sendable {
    var point: GeoPoint
    var source: RouteOrigin.Source

    var logOrigin: RouteOrigin { RouteOrigin(latitude: point.latitude, longitude: point.longitude, source: source) }
}

enum RouteOriginRule {
    /// A raw fix is good enough to route from only at or below this accuracy ...
    static let maxFixAccuracyM = 15.0
    /// ... and at most this old.
    static let maxFixAgeS = 5.0

    static func isGoodFix(_ fix: RawFixInput) -> Bool {
        fix.horizontalAccuracy.isFinite && fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= maxFixAccuracyM
            && fix.ageS.isFinite && fix.ageS >= 0 && fix.ageS <= maxFixAgeS
    }

    /// The raw fix as a position to use: good (`isGoodFix`) and GPS not switched
    /// off. The one rule for the origin, the card's distance and the search region.
    static func usableFix(_ inputs: RouteOriginInputs) -> GeoPoint? {
        guard !inputs.gpsOff, let fix = inputs.fix, isGoodFix(fix) else { return nil }
        return fix.point
    }

    static func choose(_ inputs: RouteOriginInputs) -> RouteOriginChoice {
        if inputs.runActive, let estimate = inputs.estimate {
            if PositionStatus.isFinding(estimate) { return .uncertain(estimate: estimate.position, pin: inputs.pin) }
            return .estimate(estimate.position)
        }
        // Raw iOS location is never used silently: it must be good and in use.
        if let point = usableFix(inputs) { return .fix(point) }
        return .needsPin(pin: inputs.pin)
    }

    /// The origin to request from, or nil while the card still needs the
    /// driver's pin. `routeAnyway` is the secondary choice in the uncertain
    /// state: it routes from the estimate.
    static func resolve(_ choice: RouteOriginChoice, routeAnyway: Bool = false) -> ResolvedOrigin? {
        switch choice {
        case .estimate(let point): ResolvedOrigin(point: point, source: .estimate)
        case .fix(let point): ResolvedOrigin(point: point, source: .fix)
        case .uncertain(let estimate, let pin):
            if routeAnyway { ResolvedOrigin(point: estimate, source: .estimate) }
            else if let pin { ResolvedOrigin(point: pin, source: .pin) }
            else { nil }
        case .needsPin(let pin): pin.map { ResolvedOrigin(point: $0, source: .pin) }
        }
    }
}
