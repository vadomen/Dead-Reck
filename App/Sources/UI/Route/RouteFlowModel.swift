import DriveLoggerCore
import Foundation
import Observation

/// What the flow reads from the map and the session, on demand (the flow
/// polls nothing): the origin rule's inputs and the car's speed.
struct RouteLiveInputs: Equatable, Sendable {
    var origin = RouteOriginInputs()
    /// m/s from the HUD's speed (OBD, else GPS); nil = unknown.
    var speedMS: Double?
}

/// The destination → route → guidance flow (prompt 52 = R2), as one pure
/// `@Observable` state machine; views only read it and call its methods.
///
///     idle → search → placeCard → requesting → alternatives → guiding → arrived → idle
///
/// - A long press goes straight to `placeCard`.
/// - `cancel()` returns to `idle` from any state (and clears an active route:
///   `routeCleared` `cancelled`); `dismiss()` closes a sheet and, while a route
///   is active, goes back to `guiding` with that route untouched.
/// - Rebuild: `guiding → requesting → alternatives` with a new set; a failed
///   rebuild keeps the current route. Nothing is written until Start.
/// - A throttled request stays in `requesting` and retries with backoff; it is
///   never shown as "nothing found". A failed request with no route writes nothing.
/// - The alternative set is kept as shown; nothing re-requests to redraw it.
///
/// App-session scoped (it lives in `RootView`), so the route survives the
/// Navigate → Record hand-over: Record asks `handOver` at Start.
@MainActor
@Observable
final class RouteFlowModel {
    enum Phase: Equatable, Sendable {
        case idle, search, placeCard, requesting, alternatives, guiding, arrived
    }

    /// Why a request or search shows a message with Retry.
    enum Failure: Equatable, Sendable {
        case offline
        case nothingFound
        /// Throttled and gave up after the backoffs (still not "nothing found").
        case busy
        case failed
    }

    enum SearchStatus: Equatable, Sendable {
        case idle, loading, ready
        case failure(Failure)
    }

    /// The route being followed, with what prompt 53 will use.
    struct ActiveRoute: Equatable, Sendable {
        var route: Route
        var geometry: RouteGeometry
        var place: RoutePlace
        var origin: RouteOrigin
        /// `RouteEdgeMatcher` run once on the chosen route when road packs cover
        /// it; nil: not covered or not run. Shown only in Diagnostics.
        var edgeMatch: RouteEdgeMatch?
        var edgeMatchDone = false
    }

    // MARK: State

    private(set) var phase: Phase = .idle
    private(set) var query = ""
    private(set) var completions: [DestinationCompletion] = []
    private(set) var searchStatus: SearchStatus = .idle
    private(set) var place: RoutePlace?
    /// The driver's "I'm here" pin for this request (origin source `pin`).
    private(set) var originPin: GeoPoint?
    private(set) var routeAnyway = false
    /// A failure of the last request from the card (Retry shown); nil otherwise.
    private(set) var failure: Failure?
    private(set) var alternatives: [Route] = []
    private(set) var chosenIndex = 0
    /// The origin the shown alternatives were requested from.
    private(set) var requestOrigin: ResolvedOrigin?
    /// The pending request or card is a rebuild of the active route.
    private(set) var isRebuild = false
    private(set) var active: ActiveRoute?
    private(set) var guidance: RouteGuidance?
    /// A rebuild failed and the current route stayed; the bar says so once.
    private(set) var rebuildFailure: Failure?
    /// The destination of the route that was just reached (the Arrived state).
    private(set) var arrivedPlace: RoutePlace?

    // MARK: Collaborators

    @ObservationIgnored private let searcher: any DestinationSearching
    @ObservationIgnored private let director: any RouteDirecting
    @ObservationIgnored private let pacer: RequestPacer
    @ObservationIgnored let saved: SavedDestinationsStore
    @ObservationIgnored private var sink: (any RouteEventSink)?
    @ObservationIgnored private let edgeMatcher: (@Sendable (Route) async -> RouteEdgeMatch?)?
    /// Reads the estimate, the fix, the GPS switch and the speed. Set by the map
    /// (`bindLiveInputs`); screenshot stubs fix it.
    @ObservationIgnored private(set) var liveInputs: () -> RouteLiveInputs = { RouteLiveInputs() }
    @ObservationIgnored private var inputsAreFixed = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var edgeTask: Task<Void, Never>?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var arrival = ArrivalDetector()
    @ObservationIgnored private var lastAlongM: Double?
    /// Time source of the guidance loop (tests step it by hand through `tick`).
    @ObservationIgnored var tickInterval: Duration = .milliseconds(500)

    init(
        searcher: any DestinationSearching, director: any RouteDirecting, pacer: RequestPacer = RequestPacer(),
        saved: SavedDestinationsStore, sink: (any RouteEventSink)? = nil,
        edgeMatcher: (@Sendable (Route) async -> RouteEdgeMatch?)? = nil
    ) {
        self.searcher = searcher
        self.director = director
        self.pacer = pacer
        self.saved = saved
        self.sink = sink
        self.edgeMatcher = edgeMatcher
    }

    func attach(sink: any RouteEventSink) { self.sink = sink }

    /// The map supplies what the flow reads; ignored once `fixInputs` set stub inputs.
    func bindLiveInputs(_ inputs: @escaping () -> RouteLiveInputs) {
        if !inputsAreFixed { liveInputs = inputs }
    }

    /// Fixed inputs (DEBUG screenshot stubs, tests): later `bindLiveInputs` calls do not replace them.
    func fixInputs(_ inputs: @escaping () -> RouteLiveInputs) {
        liveInputs = inputs
        inputsAreFixed = true
    }

    // MARK: Derived

    var originChoice: RouteOriginChoice {
        var inputs = liveInputs().origin
        inputs.pin = originPin
        return RouteOriginRule.choose(inputs)
    }

    /// The straight-line distance from the estimate (else a good fix) to the
    /// place, metres; nil without either.
    var distanceToPlaceM: Double? {
        guard let place else { return nil }
        let inputs = liveInputs().origin
        guard let from = inputs.estimate?.position ?? RouteOriginRule.usableFix(inputs) else { return nil }
        return Self.straightLineM(from, place.coordinate)
    }

    var chosenRoute: Route? { alternatives.indices.contains(chosenIndex) ? alternatives[chosenIndex] : nil }

    /// What Record writes right after its header rows (`restored`): nil when no route is active.
    var handOver: RecordingRouteHandOver? {
        active.map { RecordingRouteHandOver(route: $0.route, origin: $0.origin) }
    }

    // MARK: Search

    func openSearch() {
        cancelWork()
        query = ""
        completions = []
        searchStatus = .idle
        place = nil
        originPin = nil
        routeAnyway = false
        failure = nil
        isRebuild = false
        phase = .search
    }

    func updateQuery(_ text: String) {
        guard phase == .search else { return }
        query = text
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completions = []
            searchStatus = .idle
            return
        }
        searchStatus = .loading
        let inputs = liveInputs().origin
        let region = SearchRegion.choose(
            estimate: inputs.estimate?.position,
            lastGoodFix: RouteOriginRule.usableFix(inputs))
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await pacer.performDebounced { try await searcher.completions(for: trimmed, region: region) }
                guard !Task.isCancelled, phase == .search, query == text else { return }
                completions = found
                searchStatus = found.isEmpty ? .failure(.nothingFound) : .ready
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, phase == .search, query == text else { return }
                completions = []
                searchStatus = .failure(Self.failure(of: error))
            }
        }
    }

    /// A completion was tapped: resolve it to a place and open the card.
    func select(_ completion: DestinationCompletion) {
        guard phase == .search else { return }
        searchTask?.cancel()
        searchStatus = .loading
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await pacer.perform { try await searcher.resolve(completion) }
                guard !Task.isCancelled, phase == .search else { return }
                showCard(resolved)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, phase == .search else { return }
                searchStatus = .failure(Self.failure(of: error))
            }
        }
    }

    /// A saved place (recent, Home, Work) was tapped: straight to its card.
    func select(_ saved: RoutePlace) {
        guard phase == .search else { return }
        searchTask?.cancel()
        showCard(saved)
    }

    /// Retry in the search sheet: the same query again.
    func retrySearch() {
        guard phase == .search else { return }
        let text = query
        query = ""
        updateQuery(text)
    }

    /// A long press on the map: the point as it is, no snapping to road packs.
    func longPress(at point: GeoPoint) {
        let found = RoutePlace(
            name: String(localized: "Dropped pin"), addressLine: "", latitude: point.latitude, longitude: point.longitude)
        guard found.isValid else { return }
        cancelWork()
        showCard(found)
    }

    private func showCard(_ found: RoutePlace) {
        place = found
        originPin = nil
        routeAnyway = false
        failure = nil
        isRebuild = false
        phase = .placeCard
    }

    // MARK: Origin and request

    /// The driver placed the "I'm here" pin (a double tap while the card is open).
    /// Under the same span rule as the recorded pin (`PinPrecision`): a tap on a
    /// map zoomed out past 300 m is refused, here too.
    func setOriginPin(_ point: GeoPoint, visibleSpanM: Double?) {
        guard phase == .placeCard, PinPrecision.isPreciseEnough(visibleSpanM: visibleSpanM) else { return }
        originPin = point
        routeAnyway = false
    }

    /// Route (or, in the uncertain state, Route anyway): requests the routes.
    func route(anyway: Bool = false) {
        guard phase == .placeCard, let place else { return }
        routeAnyway = anyway
        guard let origin = RouteOriginRule.resolve(originChoice, routeAnyway: anyway) else { return }
        request(from: origin, to: place)
    }

    /// Retry after a failure on the card.
    func retry() {
        guard phase == .placeCard, failure != nil else { return }
        route(anyway: routeAnyway)
    }

    private func request(from origin: ResolvedOrigin, to place: RoutePlace) {
        requestTask?.cancel()
        failure = nil
        phase = .requesting
        let label = place.name
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let routes = try await pacer.perform {
                    try await director.routes(from: origin.point, to: place.coordinate, label: label)
                }
                guard !Task.isCancelled, phase == .requesting else { return }
                alternatives = Array(routes.prefix(3))
                chosenIndex = 0
                requestOrigin = origin
                phase = .alternatives
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, phase == .requesting else { return }
                requestFailed(Self.failure(of: error))
            }
        }
    }

    /// Nothing is written. With an active route (a rebuild or a new destination
    /// while guiding) the route stays and the bar says so; otherwise the card
    /// comes back with the message and Retry.
    private func requestFailed(_ reason: Failure) {
        if isRebuild, active != nil {
            rebuildFailure = reason
            alternatives = []
            phase = .guiding
        } else {
            failure = reason
            phase = .placeCard
        }
    }

    func chooseAlternative(_ index: Int) {
        guard phase == .alternatives, alternatives.indices.contains(index) else { return }
        chosenIndex = index
    }

    // MARK: Guidance

    /// Start: the chosen route becomes the active one; the `route` row goes
    /// out (`user` for a new destination, `alternative` for another route to
    /// the same one), the destination joins the recents, and the edge matcher
    /// runs once.
    func start() {
        guard phase == .alternatives, let route = chosenRoute, let place, let origin = requestOrigin else { return }
        let reason: RouteSample.Reason = active?.place.dedupKey == place.dedupKey ? .alternative : .user
        let logOrigin = origin.logOrigin
        active = ActiveRoute(route: route, geometry: RouteGeometry(route: route), place: place, origin: logOrigin)
        alternatives = []
        isRebuild = false
        rebuildFailure = nil
        guidance = nil
        lastAlongM = nil
        arrival.reset()
        phase = .guiding
        saved.addRecent(place)
        sink?.routeSet(route, reason: reason, origin: logOrigin)
        runEdgeMatch(for: route)
        startLoop()
    }

    private func runEdgeMatch(for route: Route) {
        edgeTask?.cancel()
        guard let edgeMatcher else { return }
        edgeTask = Task { [weak self] in
            let match = await edgeMatcher(route)
            guard !Task.isCancelled, let self, active?.route.id == route.id else { return }
            active?.edgeMatch = match
            active?.edgeMatchDone = true
        }
    }

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.tickInterval ?? .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                let inputs = liveInputs()
                tick(estimate: inputs.origin.runActive ? inputs.origin.estimate : nil, speedMS: inputs.speedMS,
                     now: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    /// One guidance step: progress along the route, the away guard and arrival.
    func tick(estimate: NavDisplay?, speedMS: Double?, now: TimeInterval) {
        guard phase == .guiding, let active else { return }
        var next = RouteGuidance.compute(geometry: active.geometry, estimate: estimate, previousAlongM: lastAlongM)
        if let along = next.alongM { lastAlongM = along }
        if next.status != .onRoute, let old = guidance, next.next == nil {
            // Uncertain or away: keep the last known instruction on screen.
            next.next = old.next
            next.nextStep = old.nextStep
        }
        if next != guidance { guidance = next }
        if arrival.update(remainingM: next.remainingM, speedMS: speedMS, now: now) { arrive() }
    }

    private func arrive() {
        guard let active else { return }
        sink?.routeCleared(routeID: active.route.id, reason: .arrived)
        arrivedPlace = active.place
        endRoute()
        phase = .arrived
    }

    /// The Arrived state is closed (its button, or after a few seconds).
    func acknowledgeArrival() {
        guard phase == .arrived else { return }
        arrivedPlace = nil
        phase = .idle
    }

    /// Rebuild from where the car is, to the same destination. With no usable
    /// origin the card opens and asks for the pin first.
    func rebuild() {
        guard phase == .guiding, let active else { return }
        rebuildFailure = nil
        place = active.place
        originPin = nil
        routeAnyway = false
        failure = nil
        isRebuild = true
        if let origin = RouteOriginRule.resolve(originChoice) {
            request(from: origin, to: active.place)
        } else {
            phase = .placeCard
        }
    }

    /// Back from a sheet or a pending request: closes it and, while a route is
    /// active, returns to guiding with that route untouched; else idle.
    func dismiss() {
        cancelWork()
        alternatives = []
        failure = nil
        isRebuild = false
        place = nil
        phase = active == nil ? .idle : .guiding
    }

    /// Cancel route: `idle` from any state. An active route ends with
    /// `routeCleared` `cancelled`.
    func cancel() {
        cancelWork()
        if let active { sink?.routeCleared(routeID: active.route.id, reason: .cancelled) }
        endRoute()
        alternatives = []
        place = nil
        failure = nil
        isRebuild = false
        arrivedPlace = nil
        phase = .idle
    }

    private func endRoute() {
        loopTask?.cancel()
        edgeTask?.cancel()
        active = nil
        guidance = nil
        lastAlongM = nil
        arrival.reset()
        rebuildFailure = nil
    }

    private func cancelWork() {
        searchTask?.cancel()
        requestTask?.cancel()
    }

    // MARK: Helpers

    static func failure(of error: Error) -> Failure {
        switch error as? RouteServiceError {
        case .offline: .offline
        case .throttled: .busy
        case .nothingFound: .nothingFound
        default: .failed
        }
    }

    /// Equirectangular distance, accurate to well under 1 % over the ranges shown on the card.
    static func straightLineM(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let metresPerDegree = 111_320.0
        let dLat = (b.latitude - a.latitude) * metresPerDegree
        let dLon = (b.longitude - a.longitude) * metresPerDegree * cos((a.latitude + b.latitude) / 2 * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }
}
