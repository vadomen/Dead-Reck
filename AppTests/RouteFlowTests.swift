import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

/// The flow's state machine (prompt 52): every transition, the failure rules
/// and what is written to the recording.
@MainActor
@Suite("Route flow")
struct RouteFlowTests {
    @MainActor struct Rig {
        let flow: RouteFlowModel
        let searcher = StubSearcher()
        let director = StubDirector()
        let sink = SinkRecorder()
        let clock = VirtualClock()
        let store: SavedDestinationsStore
        var inputs: RouteLiveInputs

        init(
            estimate: NavDisplay? = RouteFixtures.nav(), fix: RawFixInput? = nil, gpsOff: Bool = false,
            speedMS: Double? = 12
        ) {
            store = SavedDestinationsStore.preview()
            inputs = RouteLiveInputs(
                origin: RouteOriginInputs(runActive: estimate != nil, estimate: estimate, fix: fix, gpsOff: gpsOff),
                speedMS: speedMS)
            flow = RouteFlowModel(
                searcher: searcher, director: director,
                pacer: RequestPacer(clock: clock.pacerClock, debounce: 0.5, minInterval: 1.5),
                saved: store, sink: sink)
            let fixed = inputs
            flow.fixInputs { fixed }
        }

        /// Drives to the alternatives with the stub's routes.
        func toAlternatives(place: RoutePlace = RouteFixtures.place) async {
            flow.openSearch()
            flow.select(place)
            flow.route()
            await waitUntil("alternatives") { flow.phase == .alternatives }
        }

        func toGuiding(place: RoutePlace = RouteFixtures.place) async {
            await toAlternatives(place: place)
            flow.start()
        }
    }

    // MARK: The path

    @Test("idle → search → place card → requesting → alternatives → guiding, one route row `user` from the estimate")
    func wholePath() async {
        let rig = Rig()
        #expect(rig.flow.phase == .idle)
        rig.flow.openSearch()
        #expect(rig.flow.phase == .search)
        rig.searcher.completionResult = .success([DestinationCompletion(id: "1", title: "Test Café", subtitle: "Test Lane")])
        rig.flow.updateQuery("test")
        await waitUntil("completions") { rig.flow.searchStatus == .ready }
        #expect(rig.flow.completions.count == 1)
        rig.flow.select(rig.flow.completions[0])
        await waitUntil("place card") { rig.flow.phase == .placeCard }
        #expect(rig.flow.place == RouteFixtures.place)
        rig.flow.route()
        #expect(rig.flow.phase == .requesting)
        await waitUntil("alternatives") { rig.flow.phase == .alternatives }
        #expect(rig.flow.alternatives.count == 3)
        #expect(rig.flow.chosenIndex == 0)
        #expect(rig.sink.rows.isEmpty, "nothing is written before Start")
        rig.flow.start()
        #expect(rig.flow.phase == .guiding)
        #expect(rig.sink.rows == [.route(id: "r1", reason: "user", source: "estimate")])
        #expect(rig.flow.active?.place == RouteFixtures.place)
        #expect(rig.store.recents == [RouteFixtures.place])
        #expect(rig.flow.alternatives.isEmpty)
    }

    @Test("A long press goes straight to the place card, at the point as it is")
    func longPress() {
        let rig = Rig()
        let point = GeoPoint(latitude: 0.01234567, longitude: 0.02345678)
        rig.flow.longPress(at: point)
        #expect(rig.flow.phase == .placeCard)
        #expect(rig.flow.place?.latitude == 0.01234567)
        #expect(rig.flow.place?.longitude == 0.02345678)
        #expect(rig.flow.place?.addressLine == "")
        #expect(rig.searcher.resolved == 0 && rig.searcher.queries.isEmpty, "no search, no snapping")
    }

    @Test("Choosing another alternative changes the chosen one and asks nothing")
    func choosing() async {
        let rig = Rig()
        await rig.toAlternatives()
        rig.flow.chooseAlternative(2)
        #expect(rig.flow.chosenIndex == 2)
        rig.flow.chooseAlternative(7)
        #expect(rig.flow.chosenIndex == 2)
        #expect(rig.director.calls.count == 1, "the set that was shown is kept; nothing re-requests to redraw it")
        rig.flow.start()
        #expect(rig.sink.rows == [.route(id: "r3", reason: "user", source: "estimate")])
    }

    // MARK: Cancel and dismiss

    @Test("Cancel returns to idle from every state; an active route ends with `cancelled`", arguments: [
        "search", "placeCard", "requesting", "alternatives", "guiding",
    ])
    func cancelFromAnywhere(state: String) async {
        let rig = Rig()
        switch state {
        case "search": rig.flow.openSearch()
        case "placeCard": rig.flow.longPress(at: RouteFixtures.origin)
        case "requesting":
            rig.director.holds = true
            rig.flow.longPress(at: RouteFixtures.origin)
            rig.flow.route()
        case "alternatives": await rig.toAlternatives()
        default: await rig.toGuiding()
        }
        rig.flow.cancel()
        #expect(rig.flow.phase == .idle)
        #expect(rig.flow.active == nil && rig.flow.handOver == nil)
        if state == "guiding" {
            #expect(rig.sink.rows.last == .cleared(id: "r1", reason: "cancelled"))
        } else {
            #expect(rig.sink.rows.isEmpty)
        }
        rig.director.release()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(rig.flow.phase == .idle, "a cancelled request does not come back")
    }

    @Test("Dismiss closes a sheet and, with a route active, goes back to guiding with it untouched")
    func dismissKeepsRoute() async {
        let rig = Rig()
        await rig.toGuiding()
        rig.flow.longPress(at: RouteFixtures.point(alongM: 500))
        #expect(rig.flow.phase == .placeCard)
        rig.flow.dismiss()
        #expect(rig.flow.phase == .guiding)
        #expect(rig.flow.active?.route.id == "r1")
        #expect(rig.sink.rows == [.route(id: "r1", reason: "user", source: "estimate")])
        let idle = Rig()
        idle.flow.openSearch()
        idle.flow.dismiss()
        #expect(idle.flow.phase == .idle)
    }

    // MARK: Failures

    @Test("A failed request with no route writes nothing and offers Retry; nothing found and offline are told apart",
          arguments: [(RouteServiceError.offline, RouteFlowModel.Failure.offline),
                      (.nothingFound, .nothingFound), (.failed, .failed)])
    func failureWithoutRoute(error: RouteServiceError, shown: RouteFlowModel.Failure) async {
        let rig = Rig()
        rig.director.results = [.failure(error), .success(RouteFixtures.routes())]
        rig.flow.longPress(at: RouteFixtures.origin)
        rig.flow.route()
        await waitUntil("failure") { rig.flow.failure != nil }
        #expect(rig.flow.failure == shown)
        #expect(rig.flow.phase == .placeCard)
        #expect(rig.sink.rows.isEmpty)
        rig.flow.retry()
        await waitUntil("alternatives after Retry") { rig.flow.phase == .alternatives }
        #expect(rig.flow.failure == nil)
    }

    @Test("A throttled request stays in requesting and is retried with backoff; it is never `nothing found`")
    func throttled() async {
        let rig = Rig()
        rig.director.results = [.failure(.throttled), .failure(.throttled), .success(RouteFixtures.routes())]
        rig.flow.longPress(at: RouteFixtures.origin)
        rig.flow.route()
        await waitUntil("alternatives") { rig.flow.phase == .alternatives }
        #expect(rig.director.calls.count == 3)
        #expect(rig.flow.failure == nil)
        let sleeps = rig.clock.sleeps
        #expect(sleeps.contains(RequestPacer.backoff(attempt: 1)) && sleeps.contains(RequestPacer.backoff(attempt: 2)))
    }

    @Test("Still throttled after the last attempt: a busy message, not `nothing found`")
    func throttledForever() async {
        let rig = Rig()
        rig.director.results = [.failure(.throttled)]
        rig.flow.longPress(at: RouteFixtures.origin)
        rig.flow.route()
        await waitUntil("busy") { rig.flow.failure != nil }
        #expect(rig.flow.failure == .busy)
        #expect(rig.director.calls.count == RequestPacer.maxThrottledAttempts)
        #expect(rig.sink.rows.isEmpty)
    }

    @Test("The destination changing cancels the request in flight")
    func destinationChangeCancels() async {
        let rig = Rig()
        rig.director.holds = true
        rig.flow.longPress(at: RouteFixtures.origin)
        rig.flow.route()
        await waitUntil("request") { rig.director.calls.count == 1 }
        rig.flow.longPress(at: RouteFixtures.point(alongM: 900))
        #expect(rig.flow.phase == .placeCard)
        rig.director.release()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.flow.phase == .placeCard && rig.flow.alternatives.isEmpty)
    }

    // MARK: Stale answers (live MapKit ignores cancellation; the flow's own guard is the protection)

    private func routes(prefix: String) -> [Route] {
        (1...3).map { RouteFixtures.route(id: "\(prefix)\($0)", lengthM: 2_000 + Double($0) * 100) }
    }

    @Test("A request cancelled and replaced: A's late answer, while B is still requesting, is dropped")
    func staleRequestWhileRequesting() async {
        let rig = Rig()
        rig.director.holds = true
        rig.director.results = [.success(routes(prefix: "a")), .success(routes(prefix: "b"))]
        rig.flow.longPress(at: RouteFixtures.point(alongM: 300))
        rig.flow.route()
        await waitUntil("A in flight") { rig.director.calls.count == 1 }
        rig.flow.dismiss()
        rig.flow.longPress(at: RouteFixtures.point(alongM: 900))
        rig.flow.route()
        await waitUntil("B in flight") { rig.director.calls.count == 2 }
        rig.director.release(call: 0)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.flow.phase == .requesting && rig.flow.alternatives.isEmpty, "A's answer is not B's")
        rig.director.release(call: 1)
        await waitUntil("B's alternatives") { rig.flow.phase == .alternatives }
        #expect(rig.flow.alternatives.map(\.id) == ["b1", "b2", "b3"])
        rig.flow.start()
        #expect(rig.sink.rows == [.route(id: "b1", reason: "user", source: "estimate")])
    }

    @Test("A's answer arriving after B's is dropped too; the written route row is B's")
    func staleRequestAfterAnswer() async {
        let rig = Rig()
        rig.director.holds = true
        rig.director.results = [.success(routes(prefix: "a")), .success(routes(prefix: "b"))]
        rig.flow.longPress(at: RouteFixtures.point(alongM: 300))
        rig.flow.route()
        await waitUntil("A in flight") { rig.director.calls.count == 1 }
        rig.flow.dismiss()
        rig.flow.longPress(at: RouteFixtures.point(alongM: 900))
        rig.flow.route()
        await waitUntil("B in flight") { rig.director.calls.count == 2 }
        rig.director.release(call: 1)
        await waitUntil("B's alternatives") { rig.flow.phase == .alternatives }
        rig.director.release(call: 0)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.flow.alternatives.map(\.id) == ["b1", "b2", "b3"])
        rig.flow.start()
        #expect(rig.sink.rows == [.route(id: "b1", reason: "user", source: "estimate")])
        #expect(rig.flow.active?.place.latitude == RouteFixtures.point(alongM: 900).latitude)
    }

    @Test("A resolve cancelled and replaced: A's late answer does not open A's card; B's place stays")
    func staleResolve() async {
        let rig = Rig()
        rig.searcher.holdsResolve = true
        let a = RoutePlace(name: "Place A", addressLine: "", latitude: 0.01, longitude: 0.01)
        let b = RoutePlace(name: "Place B", addressLine: "", latitude: 0.02, longitude: 0.02)
        rig.searcher.resolveResults = [.success(a), .success(b)]
        rig.flow.openSearch()
        rig.flow.select(DestinationCompletion(id: "a", title: "A", subtitle: ""))
        await waitUntil("A resolving") { rig.searcher.resolved == 1 }
        rig.flow.dismiss()
        rig.flow.openSearch()
        rig.flow.select(DestinationCompletion(id: "b", title: "B", subtitle: ""))
        await waitUntil("B resolving") { rig.searcher.resolved == 2 }
        rig.searcher.releaseResolve(call: 0)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.flow.phase == .search && rig.flow.place == nil, "A's answer is not B's")
        rig.searcher.releaseResolve(call: 1)
        await waitUntil("B's card") { rig.flow.phase == .placeCard }
        #expect(rig.flow.place == b)
        // And A answering after B's card is open changes nothing.
        let late = Rig()
        late.searcher.holdsResolve = true
        late.searcher.resolveResults = [.success(a), .success(b)]
        late.flow.openSearch()
        late.flow.select(DestinationCompletion(id: "a", title: "A", subtitle: ""))
        await waitUntil("A resolving") { late.searcher.resolved == 1 }
        late.flow.dismiss()
        late.flow.openSearch()
        late.flow.select(DestinationCompletion(id: "b", title: "B", subtitle: ""))
        await waitUntil("B resolving") { late.searcher.resolved == 2 }
        late.searcher.releaseResolve(call: 1)
        await waitUntil("B's card") { late.flow.phase == .placeCard }
        late.searcher.releaseResolve(call: 0)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(late.flow.place == b)
    }

    // MARK: Pin span rule, usable fix

    @Test("The origin pin follows the recorded pin's span rule: a tap on a map zoomed out past 300 m is refused")
    func originPinSpan() {
        let rig = Rig(estimate: RouteFixtures.nav(major: 2_400, converged: false))
        rig.flow.longPress(at: RouteFixtures.origin)
        let pin = GeoPoint(latitude: 0.001, longitude: 0.001)
        rig.flow.setOriginPin(pin, visibleSpanM: 5_000)
        rig.flow.setOriginPin(pin, visibleSpanM: nil)
        #expect(rig.flow.originPin == nil)
        rig.flow.setOriginPin(pin, visibleSpanM: 250)
        #expect(rig.flow.originPin == pin)
    }

    @Test("With GPS switched off and no estimate: no straight-line distance from the spoofed fix, search not centred on it")
    func gpsOffFix() async {
        let fix = RawFixInput(point: GeoPoint(latitude: 0.001, longitude: 0.001), horizontalAccuracy: 5, ageS: 1)
        let off = Rig(estimate: nil, fix: fix, gpsOff: true)
        off.flow.longPress(at: RouteFixtures.origin)
        #expect(off.flow.distanceToPlaceM == nil)
        off.flow.openSearch()
        off.flow.updateQuery("x")
        await waitUntil("query") { !off.searcher.regions.isEmpty }
        #expect(off.searcher.regions.last == .kyivWide)
        let on = Rig(estimate: nil, fix: fix, gpsOff: false)
        on.flow.longPress(at: RouteFixtures.origin)
        #expect(on.flow.distanceToPlaceM != nil)
        on.flow.openSearch()
        on.flow.updateQuery("x")
        await waitUntil("query") { !on.searcher.regions.isEmpty }
        #expect(on.searcher.regions.last?.latitude == 0.001)
        let bad = Rig(estimate: nil, fix: RawFixInput(point: fix.point, horizontalAccuracy: 50, ageS: 1))
        bad.flow.longPress(at: RouteFixtures.origin)
        #expect(bad.flow.distanceToPlaceM == nil)
    }

    // MARK: Wiring

    @Test("The provider Record asks returns the active route of the flow the map uses, with its origin")
    func providerWiring() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let session = RecordingFixtures.session(store: scratch.store)
        let rig = Rig()
        RouteWiring.install(flow: rig.flow, on: session)
        #expect(session.activeRouteProvider?() == nil)
        await rig.toGuiding()
        let handOver = session.activeRouteProvider?()
        #expect(handOver?.route.id == "r1" && handOver?.origin?.source?.rawValue == "estimate")
        rig.flow.cancel()
        #expect(session.activeRouteProvider?() == nil, "follows the flow's state, not a copy")
    }

    // MARK: Search

    @Test("Typing is debounced and a new query cancels the one waiting; the region is centred on the estimate")
    func searchDebounce() async {
        let rig = Rig()
        rig.searcher.completionResult = .success([DestinationCompletion(id: "1", title: "A", subtitle: "")])
        rig.flow.openSearch()
        rig.flow.updateQuery("te")
        rig.flow.updateQuery("tes")
        rig.flow.updateQuery("test")
        await waitUntil("completions") { rig.flow.searchStatus == .ready }
        #expect(rig.searcher.queries.last == "test")
        #expect(rig.clock.sleeps.contains(0.5))
        #expect(rig.searcher.regions.last?.latitude == RouteFixtures.origin.latitude)
        #expect(rig.searcher.regions.last?.radiusM == SearchRegion.nearbyRadiusM)
        rig.flow.updateQuery("")
        #expect(rig.flow.completions.isEmpty && rig.flow.searchStatus == .idle)
    }

    @Test("No results and a lost network are told apart in the search sheet; Retry asks again")
    func searchFailures() async {
        let rig = Rig()
        rig.searcher.completionResult = .success([])
        rig.flow.openSearch()
        rig.flow.updateQuery("zzz")
        await waitUntil("nothing found") { rig.flow.searchStatus == .failure(.nothingFound) }
        rig.searcher.completionResult = .failure(.offline)
        rig.flow.updateQuery("zzzz")
        await waitUntil("offline") { rig.flow.searchStatus == .failure(.offline) }
        rig.searcher.completionResult = .success([DestinationCompletion(id: "1", title: "A", subtitle: "")])
        rig.flow.retrySearch()
        await waitUntil("ready") { rig.flow.searchStatus == .ready }
    }

    @Test("A saved place goes straight to its card")
    func savedPlace() {
        let rig = Rig()
        rig.flow.openSearch()
        rig.flow.select(RouteFixtures.otherPlace)
        #expect(rig.flow.phase == .placeCard && rig.flow.place == RouteFixtures.otherPlace)
    }

    // MARK: Rebuild

    @Test("Rebuild asks again from the current origin; the same destination writes `alternative`")
    func rebuild() async {
        let rig = Rig()
        await rig.toGuiding()
        rig.director.results = [.success(RouteFixtures.routes().map { route in
            try! Route(
                id: route.id + "b", polyline: route.polyline, steps: route.steps, distanceM: route.distanceM,
                expectedTravelTimeS: route.expectedTravelTimeS, source: .appleMaps, label: route.label)
        })]
        rig.flow.rebuild()
        #expect(rig.flow.phase == .requesting && rig.flow.isRebuild)
        await waitUntil("alternatives") { rig.flow.phase == .alternatives }
        #expect(rig.flow.active?.route.id == "r1", "the current route stays until Start")
        #expect(rig.sink.rows.count == 1)
        rig.flow.chooseAlternative(1)
        rig.flow.start()
        #expect(rig.sink.rows.last == .route(id: "r2b", reason: "alternative", source: "estimate"))
        #expect(rig.flow.phase == .guiding)
    }

    @Test("A new destination while guiding writes `user`")
    func newDestinationReason() async {
        let rig = Rig()
        await rig.toGuiding()
        rig.flow.longPress(at: GeoPoint(latitude: 0.05, longitude: 0.05))
        rig.flow.route()
        await waitUntil("alternatives") { rig.flow.phase == .alternatives }
        rig.flow.start()
        #expect(rig.sink.rows.last?.isUserRoute == true)
    }

    @Test("A failed rebuild keeps the current route and writes nothing")
    func failedRebuild() async {
        let rig = Rig()
        await rig.toGuiding()
        rig.director.results = [.failure(.offline)]
        rig.flow.rebuild()
        await waitUntil("back to guiding") { rig.flow.rebuildFailure != nil }
        #expect(rig.flow.phase == .guiding)
        #expect(rig.flow.active?.route.id == "r1")
        #expect(rig.flow.rebuildFailure == .offline)
        #expect(rig.sink.rows == [.route(id: "r1", reason: "user", source: "estimate")])
    }

    @Test("Backing out of a rebuild's alternatives keeps the current route")
    func backOutOfRebuild() async {
        let rig = Rig()
        await rig.toGuiding()
        rig.flow.rebuild()
        await waitUntil("alternatives") { rig.flow.phase == .alternatives }
        rig.flow.dismiss()
        #expect(rig.flow.phase == .guiding && rig.flow.active?.route.id == "r1")
        #expect(rig.sink.rows.count == 1)
    }

    // MARK: Arrival and hand-over

    @Test("Arrival: close to the end and stopped for 3 s writes `arrived` once and shows Arrived")
    func arrival() async {
        let rig = Rig()
        await rig.toGuiding()
        let end = RouteFixtures.nav(RouteFixtures.point(alongM: 2_180))
        rig.flow.tick(estimate: end, speedMS: 0, now: 0)
        rig.flow.tick(estimate: end, speedMS: 0, now: 2)
        #expect(rig.flow.phase == .guiding)
        rig.flow.tick(estimate: end, speedMS: 0, now: 3.1)
        #expect(rig.flow.phase == .arrived)
        #expect(rig.sink.rows.last == .cleared(id: "r1", reason: "arrived"))
        #expect(rig.flow.active == nil && rig.flow.handOver == nil)
        #expect(rig.flow.arrivedPlace == RouteFixtures.place)
        rig.flow.tick(estimate: end, speedMS: 0, now: 9)
        #expect(rig.sink.rows.count == 2, "written once")
        rig.flow.acknowledgeArrival()
        #expect(rig.flow.phase == .idle)
    }

    @Test("The route is held for the hand-over to Record, with its origin, and gone after cancel")
    func handOver() async {
        let rig = Rig()
        #expect(rig.flow.handOver == nil)
        await rig.toGuiding()
        let handOver = rig.flow.handOver
        #expect(handOver?.route.id == "r1")
        #expect(handOver?.route.label == "Test Café")
        #expect(handOver?.origin?.source?.rawValue == "estimate")
        #expect(handOver?.origin?.latitude == RouteFixtures.origin.latitude)
        rig.flow.cancel()
        #expect(rig.flow.handOver == nil)
    }

    @Test("The edge matcher runs once on the chosen route and its result is kept with the active route")
    func edgeMatch() async {
        let calls = RouteCallCounter()
        let store = SavedDestinationsStore.preview()
        let flow = RouteFlowModel(
            searcher: StubSearcher(), director: StubDirector(),
            pacer: RequestPacer(clock: VirtualClock().pacerClock, debounce: 0, minInterval: 0), saved: store,
            edgeMatcher: { _ in
                calls.increment()
                return nil
            })
        flow.fixInputs { RouteLiveInputs(origin: RouteOriginInputs(runActive: true, estimate: RouteFixtures.nav())) }
        flow.openSearch()
        flow.select(RouteFixtures.place)
        flow.route()
        await waitUntil("alternatives") { flow.phase == .alternatives }
        #expect(calls.count == 0, "not before Start")
        flow.start()
        await waitUntil("matched") { flow.active?.edgeMatchDone == true }
        #expect(calls.count == 1)
        #expect(flow.active?.edgeMatch == nil)
    }
}

final class RouteCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

extension SinkRecorder.Row {
    var isUserRoute: Bool {
        if case .route(_, let reason, _) = self { return reason == "user" }
        return false
    }
}
