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

    /// The speed from the session itself (OBD, else the latest fix): the map model's speed
    /// is not fed GPS while the scene is inactive, and arrival must work with the phone locked.
    @MainActor
    static func sessionSpeed(_ session: RecordingSession) -> MapSpeedReadout {
        let uptime = session.currentUptimeSeconds
        let obdAge = session.obdSpeedReplyUptime.map { uptime - $0 }
        let fix = session.latestFix
        var fixAge: Double?
        if let fix, let received = fix.receivedT {
            let elapsed = session.manualFixTapTime()?.seconds ?? session.live.elapsed
            fixAge = max(0, elapsed - (received.seconds - (fix.ageS ?? 0)))
        }
        return MapSpeedRule.resolve(obdKmh: session.live.obdSpeedKmh, obdAgeS: obdAge, fix: fix, fixAgeS: fixAge)
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
            fix: model.latest, fixAgeS: fixAge, gpsOff: !session.isGPSSwitchOn || model.gpsOff,
            speedKmh: sessionSpeed(session).kmh)
    }
}

/// Guidance's own estimate: polls the feed itself (the map's poll stops when the map
/// is hidden or the phone is locked) and uses it only if it was applied just now.
enum RouteEstimate {
    /// An estimate older than this is none.
    static let maxAge: Duration = .seconds(1)

    static func fresh(_ display: NavDisplay?, appliedAt: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> NavDisplay? {
        guard let display, let appliedAt, now - appliedAt <= maxAge else { return nil }
        return display
    }

    @MainActor
    static func source(feed: NavigationFeed) -> @MainActor () async -> NavDisplay? {
        { [weak feed] in
            guard let feed else { return nil }
            await feed.poll()
            return fresh(feed.latest, appliedAt: feed.latestAppliedAt, now: .now)
        }
    }
}

/// Hooks the flow the map uses into the session: Record asks it for the active
/// route at Start (`restored` row). Called from the kept `@State` flow, never
/// from `RootView.init` (SwiftUI re-runs it, and each run makes a throwaway flow).
enum RouteWiring {
    /// Also binds what the flow reads to the app's own session, estimate feed and
    /// map model, once. The map must not bind it: while the demo runs the map's
    /// session and feed are the demo's, and a bind then would outlive the demo.
    @MainActor
    static func install(
        flow: RouteFlowModel, on session: RecordingSession, navigation: NavigationFeed? = nil, model: MapViewModel? = nil
    ) {
        session.activeRouteProvider = { [weak flow] in flow?.handOver }
        if let navigation, let model {
            flow.estimateSource = RouteEstimate.source(feed: navigation)
            flow.bindLiveInputs { [weak session, weak model, weak navigation] in
                guard let session, let model, let navigation else { return RouteLiveInputs() }
                return RouteInputs.make(session: session, model: model, navigation: navigation)
            }
        }
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
