import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// Stubs and fixtures of the route tests (prompt 52). No request ever goes to
// Apple from a test: the services are these stubs. Places and coordinates are
// invented, near (0, 0).

/// A clock that never waits: `sleep` advances `now` and remembers the delay.
final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = 100.0
    private var slept: [Double] = []

    var now: Double { lock.withLock { time } }
    var sleeps: [Double] { lock.withLock { slept } }

    func sleep(_ seconds: Double) {
        lock.withLock {
            slept.append(seconds)
            time += seconds
        }
    }

    var pacerClock: PacerClock {
        PacerClock(now: { [self] in now }, sleep: { [self] in
            sleep($0)
            try Task.checkCancellation()
        })
    }
}

/// Scripted search: completions and resolve results, counted.
@MainActor
final class StubSearcher: DestinationSearching {
    var completionResult: Result<[DestinationCompletion], RouteServiceError> = .success([])
    var resolveResult: Result<RoutePlace, RouteServiceError> = .success(RouteFixtures.place)
    private(set) var queries: [String] = []
    private(set) var regions: [SearchRegion] = []
    private(set) var resolved = 0

    func completions(for query: String, region: SearchRegion) async throws -> [DestinationCompletion] {
        queries.append(query)
        regions.append(region)
        return try completionResult.get()
    }

    func resolve(_ completion: DestinationCompletion) async throws -> RoutePlace {
        resolved += 1
        return try resolveResult.get()
    }
}

/// Scripted routing: one result per call (the last repeats), counted; can hold a call open.
@MainActor
final class StubDirector: RouteDirecting {
    var results: [Result<[Route], RouteServiceError>] = [.success(RouteFixtures.routes())]
    private(set) var calls: [(origin: GeoPoint, destination: GeoPoint)] = []
    /// While set, a call waits for `release()` (to test cancelling a request in flight).
    var holds = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func routes(from origin: GeoPoint, to destination: GeoPoint, label: String?) async throws -> [Route] {
        calls.append((origin, destination))
        let index = min(calls.count - 1, results.count - 1)
        if holds {
            await withCheckedContinuation { held.append($0) }
            try Task.checkCancellation()
        }
        return try results[index].get()
    }

    func release() {
        held.forEach { $0.resume() }
        held = []
    }
}

/// The recording's side: the rows the flow asked for.
@MainActor
final class SinkRecorder: RouteEventSink {
    enum Row: Equatable {
        case route(id: String, reason: String, source: String?)
        case cleared(id: String, reason: String)
    }

    private(set) var rows: [Row] = []
    private(set) var origins: [RouteOrigin?] = []

    func routeSet(_ route: Route, reason: RouteSample.Reason, origin: RouteOrigin?) {
        rows.append(.route(id: route.id, reason: reason.rawValue, source: origin?.source?.rawValue))
        origins.append(origin)
    }

    func routeCleared(routeID: String, reason: RouteClearedSample.Reason) {
        rows.append(.cleared(id: routeID, reason: reason.rawValue))
    }
}

enum RouteFixtures {
    static let origin = GeoPoint(latitude: 0.0004, longitude: 0.0004)

    static let place = RoutePlace(name: "Test Café", addressLine: "1 Test Lane", latitude: 0.02, longitude: 0.02)
    static let otherPlace = RoutePlace(name: "Other Café", addressLine: "2 Test Lane", latitude: 0.03, longitude: 0.01)

    static func nav(
        _ point: GeoPoint = origin, major: Double = 30, converged: Bool = true
    ) -> NavDisplay {
        NavDisplay(
            position: point, semiMajorM: major, semiMinorM: min(major, 10), orientationDeg: 0,
            headingDeg: 90, headingStdDeg: 3, converged: converged)
    }

    /// A straight eastbound route of `lengthM` from (0, 0), a right turn in the middle, 100 s per km.
    static func route(id: String = "r1", lengthM: Double = 2_000, label: String? = "Test Café") -> Route {
        let perDegree = 111_320.0
        let spacing = 100.0
        let count = Int(lengthM / spacing)
        let points = (0...count).map { RoutePoint(latitude: 0, longitude: Double($0) * spacing / perDegree)! }
        let mid = count / 2
        let steps = [
            RouteStep(instruction: "", distanceM: 0, polylineRange: 0...0, maneuver: .depart),
            RouteStep(instruction: "Turn right onto Test Road", distanceM: Double(mid) * spacing, polylineRange: 0...mid, maneuver: .right),
            RouteStep(instruction: "Arrive at Test Café", distanceM: Double(count - mid) * spacing, polylineRange: mid...count, maneuver: .arrive),
        ]
        return try! Route(
            id: id, polyline: points, steps: steps, distanceM: lengthM, expectedTravelTimeS: lengthM / 10,
            source: .appleMaps, label: label)
    }

    static func routes(count: Int = 3) -> [Route] {
        (1...count).map { route(id: "r\($0)", lengthM: 2_000 + Double($0) * 200) }
    }

    /// A point on `route()` at `alongM` metres from its start, `offsetM` metres north of it.
    static func point(alongM: Double, offsetM: Double = 0) -> GeoPoint {
        GeoPoint(latitude: offsetM / 111_320, longitude: alongM / 111_320)
    }
}

/// Waits (yielding) until `condition` holds; fails the test after about 2 s.
@MainActor
func waitUntil(_ comment: Comment = "condition", _ condition: () -> Bool) async {
    for _ in 0..<2_000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("timed out waiting for \(comment)")
}
