import DriveLoggerCore
import Foundation

/// The app side of the route flow: what the flow reads from the map and the
/// session, where its rows go, and the one-off road matching. Thin; the rules
/// are in `RouteOriginRule` and `RouteFlowModel`.
enum RouteInputs {
    /// The origin rule's inputs from plain values (split out so a test feeds them).
    static func build(
        runActive: Bool, showsEstimate: Bool, estimate: NavDisplay?, fix: LocationSample?, fixAgeS: Double?,
        gpsOff: Bool, speedKmh: Int?
    ) -> RouteLiveInputs {
        var inputs = RouteOriginInputs()
        inputs.runActive = runActive
        inputs.estimate = runActive && showsEstimate ? estimate : nil
        if let fix, let fixAgeS {
            inputs.fix = RawFixInput(
                point: GeoPoint(latitude: fix.latitude, longitude: fix.longitude),
                horizontalAccuracy: fix.horizontalAccuracy, ageS: fixAgeS)
        }
        inputs.gpsOff = gpsOff
        return RouteLiveInputs(origin: inputs, speedMS: speedKmh.map { Double($0) / 3.6 })
    }

    /// From the live objects, on demand (nothing observed: the flow calls it when it needs it).
    @MainActor
    static func make(session: RecordingSession, model: MapViewModel, navigation: NavigationFeed) -> RouteLiveInputs {
        let status = NavigateStatus.make(
            navigate: session.navigateState, recording: session.state, startedAt: session.navigateStartedAt,
            timings: session.navigateTimings ?? NavigateConfiguration(), now: .now)
        let fixAge = model.lastFixInstant.map { instant -> Double in
            let d = instant.duration(to: .now).components
            return Double(d.seconds) + Double(d.attoseconds) / 1e18
        }
        return build(
            runActive: session.hasActiveRun, showsEstimate: status.showsEstimate, estimate: navigation.latest,
            fix: model.latest, fixAgeS: fixAge, gpsOff: !session.isGPSSwitchOn || model.gpsOff, speedKmh: model.speed.kmh)
    }
}

/// Hooks the flow the map uses into the session: Record asks it for the active
/// route at Start (`restored` row). Called from the kept `@State` flow, never
/// from `RootView.init` (SwiftUI re-runs it, and each run makes a throwaway flow).
enum RouteWiring {
    @MainActor
    static func install(flow: RouteFlowModel, on session: RecordingSession) {
        session.activeRouteProvider = { [weak flow] in flow?.handOver }
    }
}

/// Route rows into the recording (`RecordingSession.recordRoute`,
/// `recordRouteCleared`): written only while Record is running; outside a
/// recording both are no-ops and the session picks the route up at Start
/// through `activeRouteProvider`.
@MainActor
final class RecordingSessionRouteSink: RouteEventSink {
    private let session: RecordingSession

    init(session: RecordingSession) { self.session = session }

    func routeSet(_ route: Route, reason: RouteSample.Reason, origin: RouteOrigin?) {
        session.recordRoute(route, reason: reason, origin: origin)
    }

    func routeCleared(routeID: String, reason: RouteClearedSample.Reason) {
        session.recordRouteCleared(routeID: routeID, reason: reason)
    }
}

/// `RouteEdgeMatcher` on the chosen route, once, when installed road packs
/// cover it. Runs off the main actor; nil when no pack covers any probe point.
enum RouteEdgeMatching {
    /// Probe spacing along the route when asking which packs cover it, metres.
    static let probeSpacingM = 1_000.0

    static func makeMatcher(library: RoadPackLibrary) -> @Sendable (Route) async -> RouteEdgeMatch? {
        { route in
            let candidates = await library.candidates().candidates
            let probes = probes(of: route)
            let covering = candidates.filter { candidate in
                probes.contains { candidate.coverage.intersects(latitude: $0.latitude, longitude: $0.longitude, radiusM: 0) }
            }
            guard !covering.isEmpty, let network = try? RoadNetwork(packs: covering.map(\.pack)) else { return nil }
            return await Task.detached(priority: .utility) { RouteEdgeMatcher(network: network).match(route) }.value
        }
    }

    static func probes(of route: Route) -> [(latitude: Double, longitude: Double)] {
        let polyline = RoutePolyline(route: route)
        let count = max(2, Int(polyline.lengthM / probeSpacingM) + 1)
        return (0..<count).map { polyline.position(atDistanceAlongM: polyline.lengthM * Double($0) / Double(count - 1)) }
    }
}
