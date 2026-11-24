import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

/// Scripted link resolver: one answer per call (the last repeats), counted.
final class StubLinkResolver: MapLinkResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<URL, RouteServiceError>]
    private var urls: [URL] = []

    init(_ results: [Result<URL, RouteServiceError>]) { self.results = results }

    var calls: [URL] { lock.withLock { urls } }

    func resolve(_ url: URL) async throws -> URL {
        let result = lock.withLock { () -> Result<URL, RouteServiceError> in
            urls.append(url)
            return results[min(urls.count - 1, results.count - 1)]
        }
        return try result.get()
    }
}

/// Coordinates and map links through the route flow (prompt 53a): the row's state, the card, and that the
/// place takes the long-press path. Coordinates are invented, far from any real drive.
@MainActor
@Suite("Coordinates and links in the route flow")
struct CoordinateFlowTests {
    static let full = URL(string: "https://www.google.com/maps/place/Test+Cove/@-45.5,-120.5,17z/data=!3d-45.12345!4d-120.54321")!
    static let noPoint = URL(string: "https://www.google.com/maps/place/Test+Cove/data=!4m2")!
    static let short = "https://maps.app.goo.gl/AbCd1234"

    @MainActor struct Rig {
        let flow: RouteFlowModel
        let searcher = StubSearcher()
        let director = StubDirector()
        let sink = SinkRecorder()
        let clock = VirtualClock()
        let store = SavedDestinationsStore.preview()
        let resolver: StubLinkResolver

        init(_ results: [Result<URL, RouteServiceError>] = [.success(CoordinateFlowTests.full)], estimate: NavDisplay? = RouteFixtures.nav()) {
            resolver = StubLinkResolver(results)
            flow = RouteFlowModel(
                searcher: searcher, director: director,
                pacer: RequestPacer(clock: clock.pacerClock, debounce: 0.5, minInterval: 1.5),
                saved: store, sink: sink, linkResolver: resolver)
            let inputs = RouteLiveInputs(origin: RouteOriginInputs(runActive: estimate != nil, estimate: estimate), speedMS: 12)
            flow.fixInputs { inputs }
            flow.openSearch()
        }
    }

    @Test("Typed coordinates are one row; the card is titled Coordinates with the values, no request but the completer's")
    func typedCoordinates() async {
        let rig = Rig()
        rig.flow.updateQuery("-45.12345, -120.54321")
        guard case .point(let point) = rig.flow.input else { Issue.record("no point"); return }
        #expect(point.latitude == -45.12345 && point.longitude == -120.54321)
        rig.flow.selectCoordinates()
        #expect(rig.flow.phase == .placeCard)
        #expect(rig.flow.place?.name == "Coordinates")
        #expect(rig.flow.place?.addressLine == "-45.12345, -120.54321")
        #expect(rig.flow.place?.latitude == -45.12345 && rig.flow.place?.longitude == -120.54321)
        #expect(rig.resolver.calls.isEmpty && rig.director.calls.isEmpty, "nothing is requested by showing the card")
    }

    @Test("A coordinates place takes the long-press path: same card state, origin rules, alternatives, recents, saved places")
    func samePathAsLongPress() async {
        let pressed = Rig()
        pressed.flow.longPress(at: GeoPoint(latitude: -45.12345, longitude: -120.54321))
        let typed = Rig()
        typed.flow.updateQuery("-45.12345, -120.54321")
        typed.flow.selectCoordinates()
        #expect(typed.flow.phase == pressed.flow.phase)
        #expect(typed.flow.originPin == pressed.flow.originPin && typed.flow.failure == pressed.flow.failure)
        #expect(typed.flow.routeAnyway == pressed.flow.routeAnyway && typed.flow.isRebuild == pressed.flow.isRebuild)
        #expect(typed.flow.place?.coordinate == pressed.flow.place?.coordinate)
        #expect(typed.flow.originChoice == pressed.flow.originChoice)
        // Origin rule: no position and no pin -> Route is refused, exactly as for a pin.
        let lost = Rig(estimate: nil)
        lost.flow.updateQuery("-45.12345, -120.54321")
        lost.flow.selectCoordinates()
        lost.flow.route()
        #expect(lost.flow.phase == .placeCard, "no usable origin: the card stays and asks for the pin")
        // Alternatives and recents, then a route row.
        typed.flow.route()
        await waitUntil("alternatives") { typed.flow.phase == .alternatives }
        #expect(typed.director.calls.first?.destination == GeoPoint(latitude: -45.12345, longitude: -120.54321))
        #expect(typed.flow.alternatives.count == 3)
        typed.flow.start()
        #expect(typed.store.recents.first?.coordinate == GeoPoint(latitude: -45.12345, longitude: -120.54321))
        #expect(typed.sink.rows == [.route(id: "r1", reason: "user", source: "estimate")])
        // Saved places take it like any card.
        typed.store.setHome(RouteFlowModel.place(for: ParsedPoint(latitude: -45.12345, longitude: -120.54321)))
        #expect(typed.store.home?.coordinate == GeoPoint(latitude: -45.12345, longitude: -120.54321))
    }

    @Test("Plain coordinates still reach the completer (the row sits above its results); links never do")
    func completerSplit() async {
        let rig = Rig()
        rig.searcher.completionResult = .success([DestinationCompletion(id: "1", title: "Test Café", subtitle: "Test Lane")])
        rig.flow.updateQuery("-45.12345, -120.54321")
        await waitUntil("completions") { rig.flow.searchStatus == .ready }
        #expect(rig.searcher.queries == ["-45.12345, -120.54321"])
        #expect(rig.flow.completions.count == 1)
        for link in [Self.short, Self.full.absoluteString, "geo:-45.1,-120.5", "https://evil.example/x", "javascript:alert(1)"] {
            rig.flow.updateQuery(link)
            #expect(rig.flow.completions.isEmpty && rig.flow.searchStatus == .idle, "\(link)")
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.searcher.queries == ["-45.12345, -120.54321"], "no link text was sent to the completer")
    }

    @Test("A full link opens the card at once, titled with the place name from the link")
    func fullLink() {
        let rig = Rig()
        rig.flow.updateQuery(Self.full.absoluteString)
        rig.flow.selectCoordinates()
        #expect(rig.flow.phase == .placeCard)
        #expect(rig.flow.place?.name == "Test Cove")
        #expect(rig.flow.place?.addressLine == "-45.12345, -120.54321")
        #expect(rig.resolver.calls.isEmpty)
    }

    @Test("A swapped pair is its own row; tapping it uses the swapped values, and out-of-range opens nothing")
    func swappedAndInvalid() {
        let rig = Rig()
        rig.flow.updateQuery("-120.54321, -45.12345")
        guard case .swapped(let point) = rig.flow.input else { Issue.record("not swapped"); return }
        #expect(point.latitude == -45.12345 && point.longitude == -120.54321)
        rig.flow.selectCoordinates()
        #expect(rig.flow.place?.coordinate == GeoPoint(latitude: -45.12345, longitude: -120.54321))
        let bad = Rig()
        bad.flow.updateQuery("95.5, 200.5")
        #expect(bad.flow.input == .outOfRange)
        bad.flow.selectCoordinates()
        #expect(bad.flow.phase == .search && bad.flow.place == nil)
    }

    @Test("A short link is an Open link row: nothing is requested until it is tapped, then the final link opens the card")
    func shortLinkTapped() async {
        let rig = Rig()
        rig.flow.updateQuery(Self.short)
        #expect(rig.flow.input == .shortLink(URL(string: Self.short)!))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.resolver.calls.isEmpty, "typing or pasting a link requests nothing")
        rig.flow.openLink()
        #expect(rig.flow.searchStatus == .loading)
        await waitUntil("card") { rig.flow.phase == .placeCard }
        #expect(rig.resolver.calls == [URL(string: Self.short)!])
        #expect(rig.flow.place?.name == "Test Cove")
        #expect(rig.flow.place?.coordinate == GeoPoint(latitude: -45.12345, longitude: -120.54321))
    }

    @Test("A short link that ends with no point says so and offers no retry; the text stays")
    func shortLinkNoPoint() async {
        let rig = Rig([.success(Self.noPoint)])
        rig.flow.updateQuery(Self.short)
        rig.flow.openLink()
        await waitUntil("no point") { rig.flow.searchStatus == .failure(.linkNoPoint) }
        #expect(rig.flow.phase == .search)
        #expect(RouteFormat.message(.linkNoPoint) == RouteFormat.noPointMessage)
        // The resolver stopping at a host that is not a map ends the same way.
        let stopped = Rig([.failure(.nothingFound)])
        stopped.flow.updateQuery(Self.short)
        stopped.flow.openLink()
        await waitUntil("stopped") { stopped.flow.searchStatus == .failure(.linkNoPoint) }
        // And a link that resolves to another short link is no point (no loop).
        let loop = Rig([.success(URL(string: "https://goo.gl/maps/Other1234")!)])
        loop.flow.updateQuery(Self.short)
        loop.flow.openLink()
        await waitUntil("loop") { loop.flow.searchStatus == .failure(.linkNoPoint) }
        #expect(loop.resolver.calls.count == 1)
    }

    @Test("A link failure by the network is the usual message with Retry, and Retry follows the link again")
    func shortLinkOffline() async {
        let rig = Rig([.failure(.offline), .success(Self.full)])
        rig.flow.updateQuery(Self.short)
        rig.flow.openLink()
        await waitUntil("offline") { rig.flow.searchStatus == .failure(.offline) }
        rig.flow.retrySearch()
        await waitUntil("card") { rig.flow.phase == .placeCard }
        #expect(rig.resolver.calls.count == 2)
        #expect(rig.clock.sleeps.contains(1.5), "the second request waited out the pacer's interval")
    }

    @Test("A throttled link answer is retried with the pacer's backoff, never shown as no point")
    func shortLinkThrottled() async {
        let rig = Rig([.failure(.throttled), .success(Self.full)])
        rig.flow.updateQuery(Self.short)
        rig.flow.openLink()
        await waitUntil("card") { rig.flow.phase == .placeCard }
        #expect(rig.resolver.calls.count == 2)
        #expect(rig.clock.sleeps.contains(RequestPacer.backoff(attempt: 1)))
    }

    @Test("Without a resolver the row fails instead of doing nothing")
    func noResolver() {
        let flow = RouteFlowModel(
            searcher: StubSearcher(), director: StubDirector(), pacer: RequestPacer(clock: VirtualClock().pacerClock),
            saved: SavedDestinationsStore.preview())
        flow.openSearch()
        flow.updateQuery(Self.short)
        flow.openLink()
        #expect(flow.searchStatus == .failure(.failed))
    }

    @Test("Editing the text while a link is being opened drops its answer")
    func editedWhileOpening() async {
        let rig = Rig()
        rig.flow.updateQuery(Self.short)
        rig.flow.openLink()
        rig.flow.updateQuery("harbour")
        try? await Task.sleep(for: .milliseconds(60))
        #expect(rig.flow.phase == .search && rig.flow.place == nil)
    }

    @Test("Only tapping works in the search phase: no card from the other phases")
    func phaseGuard() {
        let rig = Rig()
        rig.flow.updateQuery("-45.12345, -120.54321")
        rig.flow.dismiss()
        rig.flow.selectCoordinates()
        rig.flow.openLink()
        #expect(rig.flow.phase == .idle && rig.flow.place == nil)
    }
}
