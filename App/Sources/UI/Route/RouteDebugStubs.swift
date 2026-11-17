#if DEBUG
import DriveLoggerCore
import Foundation

/// `-uiRouteStub <state>` (DEBUG, screenshots): the route flow on stub services
/// with invented places and coordinates around (0, 0), far from any real drive.
/// Use with `-uiBlankMap 1 -uiFakeHUD ok,navEllipse` so the map carries no
/// place names. States: `search`, `place`, `uncertain` (place card, uncertain
/// position), `alternatives`, `guiding`, `guidingUncertain`, `away`, `arrived`,
/// `offline`, `uncertainOffline` (the tallest card: uncertain position, then
/// Route anyway fails offline).
@MainActor
enum RouteDebugStubs {
    /// Start of every stub route: where `MapPreviewData.fakeNav` puts the estimate.
    static let origin = GeoPoint(latitude: 0.0004, longitude: 0.0004)

    private struct Leg {
        var headingDeg: Double
        var lengthM: Double
        var instruction: String
        var maneuver: RouteManeuver
    }

    /// A route from `origin` along `legs`; the first step is the empty `depart`, the last `arrive`.
    private static func route(id: String, legs: [Leg], timeS: Double) -> Route {
        var points = [RoutePoint(latitude: origin.latitude, longitude: origin.longitude)!]
        var lat = origin.latitude, lon = origin.longitude
        var steps = [RouteStep(instruction: "", distanceM: 0, polylineRange: 0...0, maneuver: .depart)]
        var total = 0.0
        for leg in legs {
            let from = points.count - 1
            let n = max(1, Int(leg.lengthM / 50))
            let rad = leg.headingDeg * .pi / 180
            for _ in 0..<n {
                let d = leg.lengthM / Double(n)
                lat += d * cos(rad) / NavGeometry.metersPerDegree
                lon += d * sin(rad) / (NavGeometry.metersPerDegree * cos(lat * .pi / 180))
                points.append(RoutePoint(latitude: lat, longitude: lon)!)
            }
            steps.append(RouteStep(
                instruction: leg.instruction, distanceM: leg.lengthM, polylineRange: from...(points.count - 1),
                maneuver: leg.maneuver))
            total += leg.lengthM
        }
        steps.append(RouteStep(
            instruction: "Arrive at the destination", distanceM: 0,
            polylineRange: (points.count - 1)...(points.count - 1), maneuver: .arrive))
        // swiftlint:disable:next force_try
        return try! Route(
            id: id, polyline: points, steps: steps, distanceM: total, expectedTravelTimeS: timeS,
            source: .synthetic, label: "Harbour Café")
    }

    static func routes() -> [Route] {
        [
            route(id: "stub-1", legs: [
                Leg(headingDeg: 40, lengthM: 700, instruction: "Turn right onto Orchard Lane", maneuver: .right),
                Leg(headingDeg: 130, lengthM: 500, instruction: "Turn left onto Harbour Street", maneuver: .left),
                Leg(headingDeg: 40, lengthM: 900, instruction: "Continue to Harbour Café", maneuver: .straight),
            ], timeS: 540),
            route(id: "stub-2", legs: [
                Leg(headingDeg: 40, lengthM: 1_200, instruction: "Turn right onto Mill Road", maneuver: .right),
                Leg(headingDeg: 130, lengthM: 900, instruction: "Turn left onto Harbour Street", maneuver: .left),
                Leg(headingDeg: 40, lengthM: 600, instruction: "Continue to Harbour Café", maneuver: .straight),
            ], timeS: 660),
            route(id: "stub-3", legs: [
                Leg(headingDeg: 40, lengthM: 300, instruction: "Turn left onto Lantern Way", maneuver: .left),
                Leg(headingDeg: -50, lengthM: 800, instruction: "Turn right onto Harbour Street", maneuver: .right),
                Leg(headingDeg: 40, lengthM: 1_500, instruction: "Continue to Harbour Café", maneuver: .straight),
            ], timeS: 780),
        ]
    }

    static var destination: RoutePlace {
        let end = routes()[0].polyline.last!
        return RoutePlace(name: "Harbour Café", addressLine: "12 Orchard Lane", latitude: end.latitude, longitude: end.longitude)
    }

    private final class InputBox {
        var value: RouteLiveInputs
        init(_ value: RouteLiveInputs) { self.value = value }
    }

    final class Searcher: DestinationSearching {
        func completions(for query: String, region: SearchRegion) async throws -> [DestinationCompletion] {
            ["Harbour Café", "Harbour Books", "Harbour Street 8", "Harbour Park"].enumerated().map {
                DestinationCompletion(id: "\($0.offset)", title: $0.element, subtitle: $0.offset == 2 ? "Lantern Way" : "Orchard Lane")
            }
        }

        func resolve(_ completion: DestinationCompletion) async throws -> RoutePlace { RouteDebugStubs.destination }
    }

    final class Director: RouteDirecting {
        var failure: RouteServiceError?

        func routes(from origin: GeoPoint, to destination: GeoPoint, label: String?) async throws -> [Route] {
            if let failure { throw failure }
            return RouteDebugStubs.routes()
        }
    }

    private static func estimate(at point: GeoPoint, uncertain: Bool) -> NavDisplay {
        uncertain
            ? NavDisplay(position: point, semiMajorM: 2_400, semiMinorM: 1_800, orientationDeg: 20, converged: false)
            : NavDisplay(position: point, semiMajorM: 40, semiMinorM: 12, orientationDeg: 130, headingDeg: 40, headingStdDeg: 3, converged: true)
    }

    private static func point(_ route: Route, alongM: Double, offsetM: Double = 0) -> GeoPoint {
        let polyline = RoutePolyline(route: route)
        let p = polyline.position(atDistanceAlongM: alongM)
        return GeoPoint(latitude: p.latitude + offsetM / NavGeometry.metersPerDegree, longitude: p.longitude)
    }

    /// The flow for a stub state, or nil when `argument` is nil or unknown.
    static func flow(argument: String?) -> RouteFlowModel? {
        guard let state = argument else { return nil }
        let director = Director()
        let clock = PacerClock(now: { 0 }, sleep: { _ in })
        let saved = SavedDestinationsStore.preview(
            recents: [
                RoutePlace(name: "Harbour Café", addressLine: "12 Orchard Lane", latitude: 0.01, longitude: 0.01),
                RoutePlace(name: "Lantern Park", addressLine: "Mill Road", latitude: 0.02, longitude: 0.0),
            ],
            home: RoutePlace(name: "Home", addressLine: "3 Lantern Way", latitude: 0.005, longitude: 0.03))
        let flow = RouteFlowModel(
            searcher: Searcher(), director: director, pacer: RequestPacer(clock: clock, debounce: 0, minInterval: 0),
            saved: saved)
        let first = routes()[0]
        let uncertain = state == "uncertain" || state == "uncertainOffline"
        let at: GeoPoint = switch state {
        case "away": point(first, alongM: 600, offsetM: 400)
        case "arrived": point(first, alongM: first.distanceM - 10)
        default: origin
        }
        let speed: Double? = state == "arrived" ? 0 : 12
        let inputs = RouteLiveInputs(
            origin: RouteOriginInputs(runActive: true, estimate: estimate(at: at, uncertain: uncertain)), speedMS: speed)
        let box = InputBox(inputs)
        flow.fixInputs { box.value }
        if state == "offline" || state == "uncertainOffline" { director.failure = .offline }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            switch state {
            case "search":
                flow.openSearch()
                flow.updateQuery("harb")
            case "place", "uncertain": flow.longPress(at: destination.coordinate)
            case "alternatives", "offline": step(flow)
            case "uncertainOffline":
                flow.longPress(at: destination.coordinate)
                try? await Task.sleep(for: .milliseconds(300))
                flow.route(anyway: true)
            default:
                step(flow, start: true)
                if state == "guidingUncertain" {
                    try? await Task.sleep(for: .seconds(1))
                    box.value.origin.estimate = estimate(at: origin, uncertain: true)
                }
            }
        }
        return flow
    }

    /// place card → Route → (Start).
    private static func step(_ flow: RouteFlowModel, start: Bool = false) {
        Task { @MainActor in
            if flow.phase != .placeCard {
                flow.openSearch()
                flow.select(destination)
                try? await Task.sleep(for: .milliseconds(200))
            }
            flow.route()
            try? await Task.sleep(for: .milliseconds(300))
            if start { flow.start() }
        }
    }
}
#endif
