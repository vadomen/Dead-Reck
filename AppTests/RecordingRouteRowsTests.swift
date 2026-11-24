import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

// Format v7 `route` / `routeCleared`, recorder side (prompt 52 item 5):
// `recordRoute` / `recordRouteCleared` write one row each into a running
// recording, on its clock (`clock.now()`), and nothing outside one;
// `activeRouteProvider` is asked once at Start, after `navPriorProvider`, and
// a route it returns is written as `route` `restored` right after the header
// rows (start, navPrior), before the init replay. No route: the file as
// before. Fakes from RecordingTestSupport.swift, `NavigateRig` from
// RecordingSessionNavigateTests.swift, `RecordingNavPriorTests.record` /
// `checkHead` from RecordingNavPriorTests.swift. Routes, labels and
// coordinates are invented, a few km from (0, 0).

/// The app's route state as the session's provider sees it.
@MainActor
final class RouteHandOverProbe {
    /// The route the app holds; nil: none.
    var active: RecordingRouteHandOver?
    /// Each ask, in order across both providers ("navPrior", "route").
    private(set) var asks: [String] = []

    init(active: RecordingRouteHandOver? = nil) {
        self.active = active
    }

    func install(on session: RecordingSession, withNavPrior prior: ((SessionClock) -> NavPriorSample?)? = nil) {
        session.activeRouteProvider = { [unowned self] in
            self.asks.append("route")
            return self.active
        }
        if let prior {
            session.navPriorProvider = { [unowned self] clock in
                self.asks.append("navPrior")
                return prior(clock)
            }
        }
    }
}

@Suite("RecordingSession route rows (v7)", .serialized)
@MainActor
struct RecordingRouteRowsTests {
    /// A three-point route a little south-west of (0, 0): depart, a right
    /// turn, arrive. `distanceM` is the provider's, not the polyline's.
    static func route(_ id: String, label: String?, distanceM: Double, latOffset: Double = 0) throws -> Route {
        let points = [(-0.0200, -0.0300), (-0.0200, -0.0250), (-0.0150, -0.0250)].map {
            RoutePoint(latitude: $0.0 + latOffset, longitude: $0.1)!
        }
        return try Route(
            id: id,
            polyline: points,
            steps: [
                RouteStep(instruction: "", distanceM: 0, polylineRange: 0...0, maneuver: .depart),
                RouteStep(instruction: "Turn right onto Test Street 1", distanceM: distanceM / 2,
                          polylineRange: 0...1, maneuver: .right),
                RouteStep(instruction: "Arrive", distanceM: distanceM / 2, polylineRange: 1...2, maneuver: .arrive),
            ],
            distanceM: distanceM,
            expectedTravelTimeS: distanceM / 10,
            source: .appleMaps,
            label: label
        )
    }

    static func routeRows(_ events: [LogEvent]) -> [(index: Int, t: MonotonicTimestamp, sample: RouteSample)] {
        events.enumerated().compactMap { offset, event in
            if case .route(let sample) = event.payload { (offset, event.timestamp, sample) } else { nil }
        }
    }

    static func clearedRows(_ events: [LogEvent]) -> [(index: Int, t: MonotonicTimestamp, sample: RouteClearedSample)] {
        events.enumerated().compactMap { offset, event in
            if case .routeCleared(let sample) = event.payload { (offset, event.timestamp, sample) } else { nil }
        }
    }

    static func analyse(_ header: LogHeader, _ events: [LogEvent]) -> RecordingSummary {
        var analyzer = RecordingAnalyzer(header: header)
        for event in events { analyzer.observe(event) }
        return analyzer.summary(report: LogReadReport(members: 1, truncatedTail: false, skippedLineIndices: []))
    }

    @Test("Navigate → Record with an active route: no row while only Navigate runs; restored right after start; replace, rebuild and arrival each one row on the recording's clock; nothing after Stop; inspect_log's analysis shows the route line")
    func routeRowsInRecording() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let rig = NavigateRig(store: scratch.store, undoWindow: .milliseconds(50))
        let first = try Self.route("route-a", label: "Test Point Б", distanceM: 1_200)
        let firstOrigin = RouteOrigin(latitude: -0.0201, longitude: -0.0301, source: .estimate)
        let firstDestination = RouteDestination(latitude: -0.0501, longitude: -0.0601, source: .coordinates)
        let probe = RouteHandOverProbe()
        probe.install(on: rig.session)
        await rig.connect(speed: 0)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)
        _ = try #require(rig.session.navigateGeneration)
        await rig.drive(0..<1)

        // Navigate only: the route is the app's; the session writes nothing.
        #expect(rig.session.recordRoute(first, reason: .user, origin: firstOrigin) == nil)
        probe.active = RecordingRouteHandOver(route: first, origin: firstOrigin, destination: firstDestination)
        #expect(probe.asks.isEmpty, "a Navigate run never asks")

        rig.uptime.set(NavigateRig.base + 50)
        try await rig.session.start(mount: "m", vehicle: "v", allowWithoutOBD: false, calibration: .zero)
        let url = try #require(rig.session.currentFile)
        #expect(probe.asks == ["route"], "asked once, at Start")

        let second = try Self.route("route-b", label: "Test Point Б", distanceM: 1_800, latOffset: 0.001)
        let third = try Self.route("route-c", label: "Test Point В", distanceM: 1_500, latOffset: 0.002)
        let pinOrigin = RouteOrigin(latitude: -0.0190, longitude: -0.0290, source: .pin)
        rig.uptime.set(NavigateRig.base + 52)
        let tSecond = rig.session.recordRoute(second, reason: .alternative, origin: firstOrigin, destination: firstDestination)
        rig.uptime.set(NavigateRig.base + 53.5)
        let tThird = rig.session.recordRoute(third, reason: .user, origin: pinOrigin)
        rig.uptime.set(NavigateRig.base + 55.25)
        let tCleared = rig.session.recordRouteCleared(routeID: third.id, reason: .arrived)
        #expect(tSecond == MonotonicTimestamp(nanoseconds: 2_000_000_000))
        #expect(tThird == MonotonicTimestamp(nanoseconds: 3_500_000_000))
        #expect(tCleared == MonotonicTimestamp(nanoseconds: 5_250_000_000))
        rig.uptime.set(NavigateRig.base + 56)
        await rig.session.stop()

        // After Stop (Navigate again, or idle): no row anywhere.
        #expect(rig.session.recordRoute(first, reason: .user, origin: nil) == nil)
        #expect(rig.session.recordRouteCleared(routeID: first.id, reason: .cancelled) == nil)
        #expect(probe.asks == ["route"], "asked once per recording")

        let (header, events, report) = try RecordingFixtures.read(url)
        #expect(report.failure == nil && !report.truncatedTail)
        #expect(header.formatVersion == LogFormatVersion.current)
        #expect(events[0].payload == .lifecycle(LifecycleSample(.start)))

        let routes = Self.routeRows(events)
        #expect(routes.map(\.sample) == [
            RouteSample(reason: .restored, route: first, origin: firstOrigin, destination: firstDestination),
            RouteSample(reason: .alternative, route: second, origin: firstOrigin, destination: firstDestination),
            RouteSample(reason: .user, route: third, origin: pinOrigin),
        ], "written field for field, the label as given")
        #expect(routes.first?.index == 1, "the restored row right after the start row")
        #expect(routes.first?.t == .zero, "stamped clock.now() at Start")
        #expect(routes.dropFirst().map(\.t) == [tSecond, tThird].compactMap { $0 })
        let replay = events.dropFirst(2).prefix { $0.timestamp.nanoseconds < 0 }
        #expect(replay.count == 17, "the init replay follows the restored row: \(replay.count)")
        let cleared = Self.clearedRows(events)
        #expect(cleared.map(\.sample) == [RouteClearedSample(reason: .arrived, routeID: "route-c")])
        #expect(cleared.first?.t == tCleared)
        let stop = try #require(RecordingFixtures.index(of: .stop, in: events))
        #expect(routes.allSatisfy { $0.index < stop } && cleared.allSatisfy { $0.index < stop })
        #expect(!RecordingFixtures.lifecycle(events).contains { $0.sample.event == "error" })

        // What inspect_log prints (`RecordingSummary.render`).
        let summary = Self.analyse(header, events)
        #expect(summary.routes.count == 3 && summary.routeClears.count == 1)
        let rendered = summary.render()
        #expect(rendered.contains("Routes        3 set (user 1, alternative 1, restored 1), 4.50 km in total; cleared 1 (arrived 1)\n"),
                "\(rendered)")
        #expect(!summary.healthWarnings.contains { $0.contains("route") }, "\(summary.healthWarnings)")

        rig.session.disableNavigate()
    }

    @Test("No route, no calls (no provider, or a provider with none): no route rows, the head of the file as before, `Routes none`")
    func noRoute() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let none = try await RecordingNavPriorTests.record(scratch: scratch) { _ in }
        let head = RecordingNavPriorTests.checkHead(none, between: [])
        let probe = RouteHandOverProbe()
        let empty = try await RecordingNavPriorTests.record(scratch: scratch) { probe.install(on: $0) }
        #expect(probe.asks == ["route"])
        #expect(RecordingNavPriorTests.checkHead(empty, between: []) == head, "a provider with no route changes nothing")
        for recorded in [none, empty] {
            #expect(Self.routeRows(recorded.events).isEmpty && Self.clearedRows(recorded.events).isEmpty)
            #expect(!RecordingFixtures.lifecycle(recorded.events).contains { $0.sample.event == "error" })
        }
        let url = try #require(scratch.files.first { $0.lastPathComponent.hasSuffix(".jsonl.gz") })
        let (header, events, _) = try RecordingFixtures.read(url)
        #expect(Self.analyse(header, events).render().contains("Routes        none\n"))
    }

    @Test("A navPrior and an active route at Start: navPrior asked first; start, navPrior, route restored, then the init replay")
    func handOverAfterNavPrior() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let route = try Self.route("route-h", label: nil, distanceM: 900)
        let probe = RouteHandOverProbe(active: RecordingRouteHandOver(route: route))
        let recorded = try await RecordingNavPriorTests.record(scratch: scratch) { session in
            probe.install(on: session) { clock in
                RecordingNavPriorTests.sample(on: clock, uptime: clock.referenceUptimeSeconds - 1)
            }
        }
        #expect(probe.asks == ["navPrior", "route"])
        RecordingNavPriorTests.checkHead(recorded, between: ["navPrior", "route"])
        let rows = Self.routeRows(recorded.events)
        #expect(rows.map(\.index) == [2])
        #expect(rows.first?.sample == RouteSample(reason: .restored, route: route, origin: nil),
                "no origin when the app did not give one")
        #expect(recorded.feed.navPrior != nil, "the feed is unchanged by the route")
    }

    @Test("While calibrating a recording takes route rows; a cancel is one routeCleared row")
    func duringCalibration() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let session = RecordingFixtures.session(link: FakeLink(), store: scratch.store)
        let route = try Self.route("route-k", label: "Test Point Г", distanceM: 600)
        #expect(session.recordRoute(route, reason: .user, origin: nil) == nil, "idle: no-op")
        let start = Task { try await session.start(mount: "", vehicle: "", allowWithoutOBD: true, calibration: .seconds(2)) }
        #expect(await eventually(10) { session.state == .calibrating })
        let url = try #require(session.currentFile)
        let origin = RouteOrigin(latitude: -0.03, longitude: -0.04, source: .fix)
        let tSet = try #require(session.recordRoute(route, reason: .user, origin: origin))
        let tCleared = try #require(session.recordRouteCleared(routeID: route.id, reason: .cancelled))
        #expect(tSet <= tCleared)
        await session.stop()
        try await start.value
        let (_, events, _) = try RecordingFixtures.read(url)
        #expect(Self.routeRows(events).map(\.sample) == [RouteSample(reason: .user, route: route, origin: origin)])
        #expect(Self.routeRows(events).map(\.t) == [tSet])
        #expect(Self.clearedRows(events).map(\.sample) == [RouteClearedSample(reason: .cancelled, routeID: "route-k")])
        let calibrationStart = try #require(RecordingFixtures.index(of: .calibrationStart, in: events))
        #expect(Self.routeRows(events).allSatisfy { $0.index > calibrationStart })
    }
}
