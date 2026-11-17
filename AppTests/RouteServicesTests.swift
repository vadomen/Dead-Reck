import DriveLoggerCore
import Foundation
import MapKit
import Testing

@testable import DriveLogger

/// The services under `App/Sources/Route/`: pacing, saved destinations and the
/// pure half of the MapKit adapter. No request to Apple from here.
@MainActor
@Suite("Request pacer")
struct RequestPacerTests {
    @Test("Requests start at least 1.5 s apart")
    func spacing() async throws {
        let clock = VirtualClock()
        let pacer = RequestPacer(clock: clock.pacerClock)
        var starts: [Double] = []
        for _ in 0..<3 { try await pacer.perform { starts.append(clock.now) } }
        #expect(starts.count == 3)
        #expect(starts[1] - starts[0] >= 1.5 - 1e-9)
        #expect(starts[2] - starts[1] >= 1.5 - 1e-9)
    }

    @Test("A request after a long pause is not delayed")
    func noDelayAfterPause() async throws {
        let clock = VirtualClock()
        let pacer = RequestPacer(clock: clock.pacerClock)
        try await pacer.perform {}
        clock.sleep(10)
        let before = clock.sleeps.count
        try await pacer.perform {}
        #expect(clock.sleeps.count == before, "no wait needed")
    }

    @Test("The completer's queries are debounced")
    func debounce() async throws {
        let clock = VirtualClock()
        let pacer = RequestPacer(clock: clock.pacerClock)
        let value = try await pacer.performDebounced { 7 }
        #expect(value == 7)
        #expect(clock.sleeps.first == RequestPacer.defaultDebounce)
    }

    @Test("Backoff doubles from 2 s and stops at 30 s")
    func backoff() {
        #expect([1, 2, 3, 4, 5, 6].map(RequestPacer.backoff(attempt:)) == [2, 4, 8, 16, 30, 30])
    }

    @Test("A throttled answer is retried after the backoff; other errors pass through at once")
    func retries() async throws {
        let clock = VirtualClock()
        let pacer = RequestPacer(clock: clock.pacerClock)
        var calls = 0
        let value = try await pacer.perform { () async throws -> Int in
            calls += 1
            if calls < 3 { throw RouteServiceError.throttled }
            return calls
        }
        #expect(value == 3)
        #expect(clock.sleeps.contains(2) && clock.sleeps.contains(4))
        var other = 0
        await #expect(throws: RouteServiceError.offline) {
            try await pacer.perform { () async throws -> Int in
                other += 1
                throw RouteServiceError.offline
            }
        }
        #expect(other == 1)
    }

    @Test("Cancelling the task cancels the wait")
    func cancellation() async {
        let pacer = RequestPacer(clock: .system, debounce: 30, minInterval: 30)
        let task = Task { try await pacer.performDebounced { 1 } }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let result = await task.result
        #expect({ if case .failure = result { return true } else { return false } }())
    }
}

@MainActor
@Suite("Saved destinations")
struct SavedDestinationsStoreTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("saved-destinations-test-\(UUID().uuidString)")
    }

    private func place(_ index: Int) -> RoutePlace {
        RoutePlace(name: "Place \(index)", addressLine: "", latitude: Double(index) * 0.01, longitude: 0.5)
    }

    @Test("Recents: at most 10, most recent first")
    func limit() {
        let store = SavedDestinationsStore(directory: directory())
        for i in 1...12 { store.addRecent(place(i)) }
        #expect(store.recents.count == SavedDestinationsStore.maxRecents)
        #expect(store.recents.first?.name == "Place 12")
        #expect(store.recents.last?.name == "Place 3")
    }

    @Test("A place added again moves to the top; two spellings of one spot are one recent")
    func dedup() {
        let store = SavedDestinationsStore(directory: directory())
        for i in 1...3 { store.addRecent(place(i)) }
        store.addRecent(place(1))
        #expect(store.recents.map(\.name) == ["Place 1", "Place 3", "Place 2"])
        var near = place(2)
        near.name = "Another name"
        near.latitude += 0.000_02
        store.addRecent(near)
        #expect(store.recents.map(\.name) == ["Another name", "Place 1", "Place 3"])
    }

    @Test("Home and Work are kept apart from the recents and survive clearing them")
    func pinned() {
        let store = SavedDestinationsStore(directory: directory())
        store.setHome(place(1))
        store.setWork(place(2))
        store.addRecent(place(3))
        store.clearRecents()
        #expect(store.recents.isEmpty && store.home?.name == "Place 1" && store.work?.name == "Place 2")
        store.setHome(nil)
        #expect(store.home == nil)
    }

    @Test("Per-item delete removes just that recent")
    func removeOne() {
        let store = SavedDestinationsStore(directory: directory())
        for i in 1...3 { store.addRecent(place(i)) }
        store.removeRecent(place(2))
        #expect(store.recents.map(\.name) == ["Place 3", "Place 1"])
    }

    @Test("It is saved to the injected directory and read back; a corrupt file is an empty store")
    func persistence() throws {
        let dir = directory()
        let store = SavedDestinationsStore(directory: dir)
        store.addRecent(place(1))
        store.setHome(place(2))
        let again = SavedDestinationsStore(directory: dir)
        #expect(again.recents.map(\.name) == ["Place 1"] && again.home?.name == "Place 2")
        try Data("not json".utf8).write(to: again.fileURL)
        let broken = SavedDestinationsStore(directory: dir)
        #expect(broken.isEmpty)
        #expect(!store.lastWriteFailed)
    }

    @Test("An invalid coordinate is not saved")
    func invalid() {
        let store = SavedDestinationsStore(directory: directory())
        store.addRecent(RoutePlace(name: "x", addressLine: "", latitude: 91, longitude: 0))
        store.addRecent(RoutePlace(name: "y", addressLine: "", latitude: .nan, longitude: 0))
        #expect(store.recents.isEmpty)
    }
}

@Suite("MapKit route conversion (pure half)")
struct RouteConversionTests {
    typealias P = DirectionsRouteInput.Point

    /// An eastbound line 100 m per vertex along the equator, then a turn north, in invented coordinates.
    private func input() -> DirectionsRouteInput {
        let per = 111_320.0
        let east = (0...10).map { P(latitude: 0, longitude: Double($0) * 100 / per) }
        let north = (1...10).map { P(latitude: Double($0) * 100 / per, longitude: 10 * 100 / per) }
        let all = east + north
        return DirectionsRouteInput(
            points: all,
            steps: [
                .init(instruction: "", distanceM: 0, points: []),
                .init(instruction: "Turn left onto North Road", distanceM: 1_000, points: Array(east)),
                .init(instruction: "Arrive at the destination", distanceM: 1_000, points: [east.last!] + north),
            ],
            distanceM: 2_010, expectedTravelTimeS: 300)
    }

    @Test("Points, steps, distances and times become a Core route; the empty first step stays in the data")
    func conversion() throws {
        let route = try #require(RouteConversion.route(from: input(), id: "x", label: "Test Café"))
        #expect(route.polyline.count == 21)
        #expect(route.distanceM == 2_010 && route.expectedTravelTimeS == 300)
        #expect(route.source == .appleMaps && route.label == "Test Café" && route.id == "x")
        #expect(route.steps.count == 3)
        #expect(route.steps[0].polylineRange == 0...0 && route.steps[0].instruction.isEmpty && route.steps[0].maneuver == .depart)
        #expect(route.steps[1].polylineRange == 0...10)
        #expect(route.steps[2].polylineRange == 10...20)
        #expect(route.steps[2].maneuver == .arrive)
    }

    @Test("The maneuver comes from Core's geometry: a left turn at the corner")
    func maneuver() throws {
        let route = try #require(RouteConversion.route(from: input(), id: "x", label: nil))
        #expect(route.steps[1].maneuver == .left)
        #expect(route.label == nil)
    }

    @Test("The empty first step is dropped from display only")
    func display() throws {
        let route = try #require(RouteConversion.route(from: input(), id: "x", label: nil))
        #expect(RouteConversion.displaySteps(route).count == 2)
        #expect(route.steps.count == 3)
    }

    @Test("A step whose end is not found keeps the previous end; a valid Route still results")
    func unknownStepEnd() throws {
        var bad = input()
        bad.steps[1].points = [P(latitude: 5, longitude: 5)]
        let route = try #require(RouteConversion.route(from: bad, id: "x", label: nil))
        #expect(route.steps[1].polylineRange == 0...0)
    }

    @Test("Unusable polylines give nil, never a crash", arguments: [0, 1])
    func tooShort(count: Int) {
        var bad = input()
        bad.points = Array(bad.points.prefix(count))
        #expect(RouteConversion.route(from: bad, id: "x", label: nil) == nil)
        var invalid = input()
        invalid.points[3] = P(latitude: 200, longitude: 0)
        #expect(RouteConversion.route(from: invalid, id: "x", label: nil) == nil)
    }

    @Test("Non-finite distances and times are made safe")
    func nonFinite() throws {
        var odd = input()
        odd.distanceM = .nan
        odd.expectedTravelTimeS = .infinity
        let route = try #require(RouteConversion.route(from: odd, id: "x", label: nil))
        #expect(route.distanceM > 1_900 && route.expectedTravelTimeS == 0)
    }

    @Test("MapKit's throttle code 3 is `throttled`, not `nothing found`; a lost network is `offline`")
    func errorMapping() {
        #expect(MapKitErrorMapping.map(code: 3, domain: MKError.errorDomain) == .throttled)
        #expect(MapKitErrorMapping.map(code: Int(MKError.directionsNotFound.rawValue), domain: MKError.errorDomain) == .nothingFound)
        #expect(MapKitErrorMapping.map(code: NSURLErrorNotConnectedToInternet, domain: NSURLErrorDomain) == .offline)
        #expect(MapKitErrorMapping.map(code: 999, domain: "other") == .failed)
    }
}
