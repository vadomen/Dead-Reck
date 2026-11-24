#if DEBUG
import DriveLoggerCore
import Foundation

/// `-uiRouteStub <state>` (DEBUG, screenshots): the route flow on stub services
/// with invented places and coordinates around (0, 0), far from any real drive.
/// Use with `-uiBlankMap 1 -uiFakeHUD ok,navEllipse` so the map carries no
/// place names. States: `search`, `place`, `uncertain` (place card, uncertain
/// position), `alternatives`, `guiding`, `guidingUncertain`, `away`, `arrived`,
/// `offline`, `uncertainOffline` (the tallest card: uncertain position, then
/// Route anyway fails offline). Prompt 53a, in the search sheet: `coordinates`
/// (the Coordinates row), `coordinatesSwapped` (the "swapped" row),
/// `coordinatesInvalid` (the out-of-range message), `openLink` (the "Open link"
/// row for a short link), `linkNoPoint` (a short link was tapped and led to no
/// point), `linkNoPointTyped` (a full link typed with no point), `coordinatesCard`
/// (the place card for coordinates), `linkCard` (the card for a pasted full link
/// that names the place). Prompt 53a item 3, routes that end 300 m short of the destination:
/// `alternativesLastLeg` (the alternatives card with "Route ends 300 m before the destination" and
/// the dashed leg on the map) and `guidingLastLeg` (the bar past the route end, on the last leg).
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

    /// How far short of the destination the last-leg stubs end their routes, metres.
    static let shortM = 300.0

    /// A route from `origin` along `legs`; the first step is the empty `depart`, the last `arrive`.
    /// With `endingAt`, the last leg is replaced by a straight run to that point (so the offered
    /// routes end together, as Apple's do, and only the last-leg states differ from the destination).
    private static func route(id: String, legs: [Leg], timeS: Double, endingAt target: GeoPoint? = nil) -> Route {
        var points = [RoutePoint(latitude: origin.latitude, longitude: origin.longitude)!]
        var lat = origin.latitude, lon = origin.longitude
        var steps = [RouteStep(instruction: "", distanceM: 0, polylineRange: 0...0, maneuver: .depart)]
        var total = 0.0
        for (index, original) in legs.enumerated() {
            var leg = original
            if let target, index == legs.count - 1 {
                let dy = (target.latitude - lat) * NavGeometry.metersPerDegree
                let dx = (target.longitude - lon) * NavGeometry.metersPerDegree * cos(lat * .pi / 180)
                leg.lengthM = (dx * dx + dy * dy).squareRoot()
                leg.headingDeg = atan2(dx, dy) * 180 / .pi
            }
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

    /// Where the first route ends; the others end here too.
    static func routeEnd(scale: Double = 1) -> GeoPoint {
        let end = route(id: "end", legs: firstLegs(scale), timeS: 0).polyline.last!
        return GeoPoint(latitude: end.latitude, longitude: end.longitude)
    }

    private static func firstLegs(_ scale: Double) -> [Leg] {
        [
            Leg(headingDeg: 40, lengthM: 700 * scale, instruction: "Turn right onto Orchard Lane", maneuver: .right),
            Leg(headingDeg: 130, lengthM: 500 * scale, instruction: "Turn left onto Harbour Street", maneuver: .left),
            Leg(headingDeg: 40, lengthM: 900 * scale, instruction: "Continue to Harbour Café", maneuver: .straight),
        ]
    }

    /// The last-leg states use routes scaled to 0.4, so a 300 m gap is a visible part of the route
    /// at the zoom the camera frames or follows with.
    static let lastLegScale = 0.4

    /// `scale` shortens every leg (the last-leg states): the routes stay the same shape.
    static func routes(scale: Double = 1) -> [Route] {
        let routeEnd = routeEnd(scale: scale)
        return [
            route(id: "stub-1", legs: firstLegs(scale), timeS: 540),
            route(id: "stub-2", legs: [
                Leg(headingDeg: 40, lengthM: 1_200 * scale, instruction: "Turn right onto Mill Road", maneuver: .right),
                Leg(headingDeg: 130, lengthM: 900 * scale, instruction: "Turn left onto Harbour Street", maneuver: .left),
                Leg(headingDeg: 40, lengthM: 600 * scale, instruction: "Continue to Harbour Café", maneuver: .straight),
            ], timeS: 660, endingAt: routeEnd),
            route(id: "stub-3", legs: [
                Leg(headingDeg: 40, lengthM: 300 * scale, instruction: "Turn left onto Lantern Way", maneuver: .left),
                Leg(headingDeg: -50, lengthM: 800 * scale, instruction: "Turn right onto Harbour Street", maneuver: .right),
                Leg(headingDeg: 40, lengthM: 1_500 * scale, instruction: "Continue to Harbour Café", maneuver: .straight),
            ], timeS: 780, endingAt: routeEnd),
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

    /// The destination of the last-leg states: `shortM` beyond where every stub route ends, on the
    /// heading of the last leg.
    static var destinationShort: RoutePlace {
        let routeEnd = routeEnd(scale: lastLegScale)
        let rad = 40.0 * Double.pi / 180
        let lat = routeEnd.latitude + shortM * cos(rad) / NavGeometry.metersPerDegree
        let lon = routeEnd.longitude + shortM * sin(rad) / (NavGeometry.metersPerDegree * cos(lat * .pi / 180))
        return RoutePlace(name: "Harbour Café", addressLine: "12 Orchard Lane", latitude: lat, longitude: lon)
    }

    final class Searcher: DestinationSearching {
        var place = RouteDebugStubs.destination

        func completions(for query: String, region: SearchRegion) async throws -> [DestinationCompletion] {
            ["Harbour Café", "Harbour Books", "Harbour Street 8", "Harbour Park"].enumerated().map {
                DestinationCompletion(id: "\($0.offset)", title: $0.element, subtitle: $0.offset == 2 ? "Lantern Way" : "Orchard Lane")
            }
        }

        func resolve(_ completion: DestinationCompletion) async throws -> RoutePlace { place }
    }

    /// Invented values near (0, 0), like every stub place.
    static let coordinatesText = "0.0231, 0.0182"
    static let shortLink = "https://maps.app.goo.gl/AbCd1234"
    static let linkWithName = "https://www.google.com/maps/place/Harbour+Caf%C3%A9/@0.0231,0.0182,17z/data=!3d0.0231!4d0.0182"
    nonisolated static let linkWithoutPoint = "https://www.google.com/maps/place/Harbour+Caf%C3%A9/data=!4m2"

    /// A short link that ends on a page with no point.
    final class LinkResolver: MapLinkResolving {
        func resolve(_ url: URL) async throws -> URL { URL(string: RouteDebugStubs.linkWithoutPoint)! }
    }

    final class Director: RouteDirecting {
        var failure: RouteServiceError?
        var scale = 1.0

        func routes(from origin: GeoPoint, to destination: GeoPoint, label: String?) async throws -> [Route] {
            if let failure { throw failure }
            return RouteDebugStubs.routes(scale: scale)
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

    /// A point `fromDestinationM` from `destination` on the segment towards `end`.
    private static func point(_ destination: GeoPoint, towards end: GeoPoint, fromDestinationM: Double) -> GeoPoint {
        let total = LastLeg.distanceM(destination, end)
        let t = total > 0 ? fromDestinationM / total : 0
        return GeoPoint(
            latitude: destination.latitude + (end.latitude - destination.latitude) * t,
            longitude: destination.longitude + (end.longitude - destination.longitude) * t)
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
        let searcher = Searcher()
        let lastLegState = state == "alternativesLastLeg" || state == "guidingLastLeg"
        if lastLegState {
            searcher.place = destinationShort
            director.scale = lastLegScale
        }
        let flow = RouteFlowModel(
            searcher: searcher, director: director, pacer: RequestPacer(clock: clock, debounce: 0, minInterval: 0),
            saved: saved, linkResolver: LinkResolver())
        let first = routes(scale: director.scale)[0]
        let uncertain = state == "uncertain" || state == "uncertainOffline"
        let at: GeoPoint = switch state {
        case "away": point(first, alongM: 600, offsetM: 400)
        case "arrived": point(first, alongM: first.distanceM - 10)
        case "guidingLastLeg": point(destinationShort.coordinate, towards: routeEnd(scale: lastLegScale), fromDestinationM: 150)
        default: origin
        }
        let speed: Double? = state == "arrived" ? 0 : 12
        let inputs = RouteLiveInputs(
            origin: RouteOriginInputs(runActive: true, estimate: estimate(at: at, uncertain: uncertain)), speedMS: speed)
        // The map's synthetic estimate marker goes where the flow's estimate is, so the picture agrees with the bar.
        if state == "guidingLastLeg" { MapPreviewData.carOverride = at }
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
            case "coordinates", "coordinatesSwapped", "coordinatesInvalid", "openLink", "linkNoPoint", "linkNoPointTyped",
                 "coordinatesCard", "linkCard":
                await coordinateState(state, flow)
            case "alternatives", "offline", "alternativesLastLeg": step(flow, place: searcher.place)
            case "uncertainOffline":
                flow.longPress(at: destination.coordinate)
                try? await Task.sleep(for: .milliseconds(300))
                flow.route(anyway: true)
            default:
                step(flow, place: searcher.place, start: true)
                if state == "guidingUncertain" {
                    try? await Task.sleep(for: .seconds(1))
                    box.value.origin.estimate = estimate(at: origin, uncertain: true)
                }
            }
        }
        return flow
    }

    private static func coordinateState(_ state: String, _ flow: RouteFlowModel) async {
        flow.openSearch()
        switch state {
        case "coordinatesSwapped": flow.updateQuery("120.25, 0.02")
        case "coordinatesInvalid": flow.updateQuery("95.5, 200.5")
        case "openLink": flow.updateQuery(shortLink)
        case "linkNoPoint":
            flow.updateQuery(shortLink)
            flow.openLink()
        case "linkNoPointTyped": flow.updateQuery(linkWithoutPoint)
        case "linkCard":
            flow.updateQuery(linkWithName)
            flow.selectCoordinates()
        case "coordinatesCard":
            flow.updateQuery(coordinatesText)
            flow.selectCoordinates()
        default: flow.updateQuery(coordinatesText)
        }
    }

    /// place card → Route → (Start).
    private static func step(_ flow: RouteFlowModel, place: RoutePlace, start: Bool = false) {
        Task { @MainActor in
            if flow.phase != .placeCard {
                flow.openSearch()
                flow.select(place)
                try? await Task.sleep(for: .milliseconds(200))
            }
            flow.route()
            try? await Task.sleep(for: .milliseconds(300))
            if start { flow.start() }
        }
    }
}
#endif
