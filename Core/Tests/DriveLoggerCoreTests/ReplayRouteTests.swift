import Foundation
import Testing

@testable import DriveLoggerCore
@testable import RoadPackBuild

/// Routes in replay_nav (prompt 51 item E): the reference route from clean
/// fixes, v7 route rows, the two deliberately wrong routes and the E.3
/// metric math. Synthetic fixes, packs and routes near (0, 0) only.
@Suite("Replay routes (prompt 51 E)")
struct ReplayRouteTests {
    typealias M = RouteEdgeMatcherTests

    static func fix(
        _ t: Double, _ east: Double, _ north: Double, acc: Double = 5, speed: Double = 10, course: Double = 0,
        speedAccuracy: Double = 0.5, courseAccuracy: Double = 5, simulated: Bool? = nil
    ) -> NavigationInput {
        let p = RoadFixture.point(east, north)
        let sample = LocationSample(
            latitude: p.latitude, longitude: p.longitude, altitude: 0, horizontalAccuracy: acc, verticalAccuracy: 5,
            speed: speed, speedAccuracy: speedAccuracy, course: course, courseAccuracy: courseAccuracy, simulated: simulated
        )
        return .location(sample, at: MonotonicTimestamp(seconds: t))
    }

    // MARK: Reference route

    @Test("Clean rule: accuracy (0, 20], valid speed, valid course when moving ≥ 2 m/s, not simulated")
    func cleanRule() {
        let rule = ReferenceRouteRule.standard
        func clean(_ input: NavigationInput) -> Bool {
            guard case .location(let s, _) = input else { return false }
            return rule.isClean(s)
        }
        #expect(clean(Self.fix(0, 0, 0)))
        #expect(clean(Self.fix(0, 0, 0, acc: 20)))
        #expect(!clean(Self.fix(0, 0, 0, acc: 20.01)))
        #expect(!clean(Self.fix(0, 0, 0, acc: 0)))
        #expect(!clean(Self.fix(0, 0, 0, acc: -1)))
        #expect(!clean(Self.fix(0, 0, 0, speed: -1)))
        #expect(!clean(Self.fix(0, 0, 0, speedAccuracy: -1)))
        #expect(!clean(Self.fix(0, 0, 0, speed: 2, course: -1)))
        #expect(!clean(Self.fix(0, 0, 0, speed: 5, courseAccuracy: -1)))
        // Slower than 2 m/s: no course needed.
        #expect(clean(Self.fix(0, 0, 0, speed: 1.9, course: -1)))
        #expect(!clean(Self.fix(0, 0, 0, simulated: true)))
    }

    @Test("Spans join fixes ≤ 5 s apart; a longer gap splits; a lone fix and unclean fixes are left out")
    func referenceSpans() throws {
        var inputs: [NavigationInput] = []
        for k in 0...10 { inputs.append(Self.fix(Double(k), 0, Double(k) * 10)) }   // span 1: 0–10 s
        inputs.append(Self.fix(15, 0, 150))                                            // 5 s later: joins
        inputs.append(Self.fix(17, 0, 170, acc: 50))                                   // unclean
        inputs.append(Self.fix(30, 0, 300))                                            // lone: dropped
        for k in 40...45 { inputs.append(Self.fix(Double(k), 0, 300 + Double(k - 40) * 10)) }  // span 2: 40–45 s
        inputs.append(.obd(OBDSample(pid: .vehicleSpeed, value: 36, unit: .kilometersPerHour), at: MonotonicTimestamp(seconds: 3)))
        // Input order does not matter: fixes are sorted by time.
        let reference = try #require(ReferenceRouteBuilder.build(inputs: inputs.reversed()))
        #expect(reference.spans.count == 2)
        #expect(reference.windows == [ReplayTimeWindow(fromT: 0, toT: 15), ReplayTimeWindow(fromT: 40, toT: 45)])
        #expect(reference.spans.map(\.fixes) == [12, 6])
        #expect(reference.fixesSeen == 20 && reference.fixesUsed == 18)
        #expect(reference.route.polyline.count == 18 && reference.route.source == .synthetic)
        #expect(reference.spans[0].vertices == 0...11 && reference.spans[1].vertices == 12...17)
        #expect(abs(reference.spans[0].alongM.upperBound - 150) < 0.1)
        // The chord from 150 m north back to 300 m north is not in a span.
        #expect(abs(reference.spans[1].alongM.lowerBound - 300) < 0.1)
        #expect(reference.route.steps.map(\.maneuver) == [.depart, .arrive])
        #expect(abs(reference.route.expectedTravelTimeS - 45) < 1e-9)
        // Truth excludeFixes leaves fixes out.
        let excluded = try #require(ReferenceRouteBuilder.build(
            inputs: inputs, excluded: [TruthFile.ExcludedFixRange(fromT: 40, toT: 45)]
        ))
        #expect(excluded.spans.count == 1 && excluded.fixesExcludedByTruth == 6)
        // Nothing clean: no reference.
        #expect(ReferenceRouteBuilder.build(inputs: [Self.fix(0, 0, 0, acc: 100), Self.fix(1, 0, 10, acc: 100)]) == nil)
    }

    // MARK: v7 route rows

    @Test("A v7 recording's route rows: each active from its row to the next route or routeCleared row, or the end")
    func recordedRoutes() throws {
        func route(_ id: String) throws -> Route {
            try Route(id: id, polyline: [RoutePoint(latE7: 0, lonE7: 0), RoutePoint(latE7: 9000, lonE7: 0)], steps: [],
                      distanceM: 100, expectedTravelTimeS: 10, source: .appleMaps)
        }
        func event(_ t: Double, _ payload: LogEvent.Payload) -> LogEvent {
            LogEvent(timestamp: MonotonicTimestamp(seconds: t), payload: payload)
        }
        let events = [
            event(10, .route(RouteSample(reason: .user, route: try route("a")))),
            event(20, .obd(OBDSample(pid: .vehicleSpeed, value: 30, unit: .kilometersPerHour))),
            event(50, .route(RouteSample(reason: .offRoute, route: try route("b")))),
            event(80, .routeCleared(RouteClearedSample(reason: .cancelled, routeID: "b"))),
            event(100, .route(RouteSample(reason: .user, route: try route("c")))),
        ]
        let routes = ReplayRecordedRoutes.routes(in: events, endT: 300)
        #expect(routes.map { $0.route.id } == ["a", "b", "c"])
        #expect(routes.map { $0.window } == [ReplayTimeWindow(fromT: 10, toT: 50), ReplayTimeWindow(fromT: 50, toT: 80),
                                         ReplayTimeWindow(fromT: 100, toT: 300)])
        // Through LogCodec, as a v7 file holds them.
        let codec = LogCodec()
        let decoded = try events.map { try codec.event(from: codec.line(for: $0).dropLast()) }
        #expect(ReplayRecordedRoutes.routes(in: decoded, endT: 300).map { $0.window } == routes.map { $0.window })
        #expect(ReplayRecordedRoutes.routes(in: [LogEvent](), endT: 300).isEmpty)
    }

    // MARK: Wrong routes

    /// A cross of two streets at (0, 0) plus a third street 400 m east.
    static func crossNetwork() throws -> RoadNetwork {
        try M.network([
            M.way(1, M.residential, [(1, 0, -800), (2, 0, 0), (3, 0, 800)]),
            M.way(2, M.residential, [(4, -800, 0), (2, 0, 0), (5, 800, 0), (7, 1600, 0)]),
            M.way(3, M.residential, [(6, 400, -800), (5, 800, 0)]),
        ])
    }

    static func route(_ offsets: [(Double, Double)]) throws -> Route {
        let polyline = try M.polyline(offsets)
        return try Route(id: "base", polyline: polyline.points,
                         steps: [RouteStep(instruction: "", distanceM: 0, polylineRange: 0...0, maneuver: .depart)],
                         distanceM: polyline.lengthM, expectedTravelTimeS: 100, source: .synthetic)
    }

    @Test("missed-turn: straight on through the junction where the route turned, for 500 m, then the end")
    func missedTurn() throws {
        let net = try Self.crossNetwork()
        let base = try Self.route([(0, -600), (0, 0), (600, 0)])
        let match = RouteEdgeMatcher(network: net).match(base)
        #expect(match.coverage > 0.99)
        let (wrong, info) = try #require(RoutePerturber.perturb(base, mode: .missedTurn, match: match, network: net, seed: 7))
        #expect(info.candidates == 1 && info.chosen == 0 && info.mode == "missed-turn" && info.seed == 7)
        #expect(abs(info.atAlongM - 600) < 1)
        #expect(abs(info.wrongLengthM - 500) < 1)
        let end = RoadFixture.metres(RoadPoint(latE7: wrong.polyline.last!.latE7, lonE7: wrong.polyline.last!.lonE7))
        #expect(abs(end.east) < 0.5 && abs(end.north - 500) < 1, "end \(end)")
        #expect(wrong.source == .synthetic && wrong.id == "base-missed-turn")
        // It matches the straight street, not the turn.
        let wrongMatch = RouteEdgeMatcher(network: net).match(wrong)
        #expect(M.ways(wrongMatch) == [1])
        // Deterministic.
        #expect(RoutePerturber.perturb(base, mode: .missedTurn, match: match, network: net, seed: 7)?.route == wrong)
    }

    @Test("missed-turn across packs: the straight way on is in the other pack, and ends where nothing goes on")
    func missedTurnAcrossPacks() throws {
        // Pack A: the street up to the junction and the side street east;
        // pack B: the street on north of the junction, 300 m long.
        let a = try RoadFixture.build([
            M.way(1, M.residential, [(1, 0, -600), (2, 0, 0)]),
            M.way(2, M.residential, [(2, 0, 0), (3, 600, 0)]),
        ])
        let b = try RoadFixture.build([M.way(3, M.residential, [(2, 0, 0), (4, 0, 300)])])
        let net = try RoadNetwork(packs: [a, b])
        let base = try Self.route([(0, -500), (0, 0), (500, 0)])
        let match = RouteEdgeMatcher(network: net).match(base)
        #expect(match.coverage > 0.99)
        let (wrong, info) = try #require(RoutePerturber.perturb(base, mode: .missedTurn, match: match, network: net, seed: 0))
        #expect(info.candidates == 1 && abs(info.wrongLengthM - 300) < 1)
        let end = RoadFixture.metres(RoadPoint(latE7: wrong.polyline.last!.latE7, lonE7: wrong.polyline.last!.lonE7))
        #expect(abs(end.east) < 0.5 && abs(end.north - 300) < 1, "end \(end)")
    }

    @Test("missed-turn: the seed picks among the turns in route order")
    func missedTurnSeed() throws {
        let net = try Self.crossNetwork()
        // Two turns: right at (0, 0) and sharp right at (800, 0) onto street 3; the seed picks one.
        let base = try Self.route([(0, -600), (0, 0), (800, 0), (400, -800)])
        let match = RouteEdgeMatcher(network: net).match(base)
        let a = try #require(RoutePerturber.perturb(base, mode: .missedTurn, match: match, network: net, seed: 0))
        let b = try #require(RoutePerturber.perturb(base, mode: .missedTurn, match: match, network: net, seed: 1))
        #expect(a.info.candidates == 2 && b.info.candidates == 2)
        #expect(a.info.chosen == 0 && b.info.chosen == 1)
        #expect(abs(a.info.atAlongM - 600) < 1 && abs(b.info.atAlongM - 1400) < 1)
        // Seeds wrap: seed 2 is place 1 again.
        #expect(RoutePerturber.perturb(base, mode: .missedTurn, match: match, network: net, seed: 2)?.route == a.route)
    }

    @Test("parallel: the stretch is replaced by the neighbouring street 60 m to the side, then the route rejoins")
    func parallel() throws {
        let net = try M.network([
            M.way(1, M.residential, [(1, 0, -800), (2, 0, 800)]),
            M.way(2, M.residential, [(3, 60, -800), (4, 60, 800)]),
        ])
        let base = try Self.route([(0, -500), (0, 500)])
        let match = RouteEdgeMatcher(network: net).match(base)
        let (wrong, info) = try #require(RoutePerturber.perturb(base, mode: .parallel, match: match, network: net, seed: 3))
        #expect(info.candidates == 1 && info.mode == "parallel")
        #expect(abs((info.lateralM ?? 0) - 60) < 0.5)
        #expect(abs(info.wrongLengthM - 1000) < 1)
        // Every point but the first is on the parallel street (the stretch is the whole route here).
        let eastings = wrong.polyline.map { RoadFixture.metres(RoadPoint(latE7: $0.latE7, lonE7: $0.lonE7)).east }
        #expect(abs(eastings[0]) < 0.5 && eastings.dropFirst().allSatisfy { abs($0 - 60) < 0.5 }, "\(eastings)")
        #expect(M.ways(RouteEdgeMatcher(network: net).match(wrong)).contains(2))
        // No neighbouring street: no candidate.
        let alone = try M.network([M.way(1, M.residential, [(1, 0, -800), (2, 0, 800)])])
        let aloneMatch = RouteEdgeMatcher(network: alone).match(base)
        #expect(RoutePerturber.perturb(base, mode: .parallel, match: aloneMatch, network: alone, seed: 0) == nil)
    }

    @Test("The perturbation modes' raw names are the flag values")
    func modeNames() {
        #expect(RoutePerturbation.allCases.map(\.rawValue) == ["missed-turn", "parallel"])
    }

    // MARK: E.3 metric math

    static func track(_ points: [(t: Double, east: Double, north: Double, heading: Double)]) -> [ReplayResult.TrackPoint] {
        points.map { p in
            let q = RoadFixture.point(p.east, p.north)
            return ReplayResult.TrackPoint(t: p.t, latitude: q.latitude, longitude: q.longitude, headingDeg: p.heading,
                                           headingStdDeg: 1, converged: true, distanceM: 0, speedScale: 1)
        }
    }

    @Test("Cross-track median / p95 / max (nearest rank), on-route-edge and off-road shares, time windows")
    func stats() throws {
        let net = try M.network([
            M.way(1, M.residential, [(1, 0, -800), (2, 0, 800)]),
            M.way(2, M.residential, [(3, 12, -800), (4, 12, 800)]),
        ])
        let base = try Self.route([(0, -700), (0, 700)])
        let active = ReplayActiveRoute(route: base, match: RouteEdgeMatcher(network: net).match(base),
                                       windows: [ReplayTimeWindow(fromT: 0, toT: 19)])
        // 20 samples in the window: 10 on the route street (1 m off), 5 on way 2 (12 m), 5 off any road (40 m);
        // one more after the window, ignored.
        var points: [(t: Double, east: Double, north: Double, heading: Double)] = []
        for k in 0..<10 { points.append((Double(k), 1, Double(k) * 10, 0)) }
        for k in 10..<15 { points.append((Double(k), 12, Double(k) * 10, 0)) }
        for k in 15..<20 { points.append((Double(k), 40, Double(k) * 10, 0)) }
        points.append((25, 500, 0, 0))
        let s = ReplayRouteEvaluation.stats(track: Self.track(points), routes: [active], network: net)
        #expect(s.samples == 20)
        #expect(abs((s.crossTrackMedianM ?? 0) - 1) < 0.05)        // rank 10 of 20
        #expect(abs((s.crossTrackP95M ?? 0) - 40) < 0.05)          // rank 19
        #expect(abs((s.crossTrackMaxM ?? 0) - 40) < 0.05)
        #expect(s.onRouteEdgeShare == 0.5)
        #expect(s.offRoadShare == 0.25)
        // From t 14 on: 5 samples off road.
        let late = ReplayRouteEvaluation.stats(track: Self.track(points), routes: [active], network: net, from: 14)
        #expect(late.samples == 5 && late.offRoadShare == 1 && late.onRouteEdgeShare == 0)
        // A heading across the road is not on it.
        let across = ReplayRouteEvaluation.stats(track: Self.track([(1, 1, 0, 90)]), routes: [active], network: net)
        #expect(across.onRouteEdgeShare == 0 && across.offRoadShare == 1)
        // Nothing in the window: no numbers.
        let none = ReplayRouteEvaluation.stats(track: Self.track([(50, 0, 0, 0)]), routes: [active], network: net)
        #expect(none.samples == 0 && none.crossTrackMedianM == nil)
    }

    @Test("A reference route's chord between spans never counts: cross-track only to the spans")
    func spansOnly() throws {
        let net = try M.network([M.way(1, M.residential, [(1, 0, -800), (2, 0, 800)])])
        // Span 1 northbound at x = 0, then (chord) span 2 at x = 300.
        let first: [NavigationInput] = (0...10).map { k in Self.fix(Double(k), 0, Double(k) * 10) }
        let second: [NavigationInput] = (20...30).map { k in Self.fix(Double(k), 300, 100 + Double(k - 20) * 10) }
        let inputs = first + second
        let reference = try #require(ReferenceRouteBuilder.build(inputs: inputs))
        let active = ReplayActiveRoute(route: reference.route, match: RouteEdgeMatcher(network: net).match(reference.route),
                                       windows: reference.windows, alongRanges: reference.projectionRanges)
        let whole = ReplayActiveRoute(route: reference.route, match: active.match, windows: reference.windows)
        // At t 5, 150 m east of span 1, right next to the chord (x 0 → 300 at y 100).
        let point = Self.track([(5, 150, 100, 0)])
        let spans = ReplayRouteEvaluation.stats(track: point, routes: [active], network: net)
        let chord = ReplayRouteEvaluation.stats(track: point, routes: [whole], network: net)
        #expect((spans.crossTrackMaxM ?? 0) > 140)
        #expect((chord.crossTrackMaxM ?? 100) < 1)
    }

    @Test("Span-only coverage leaves the chords out; gaps are split into span and chord parts; isWeak stays on the whole polyline")
    func spanCoverage() throws {
        // Roads under both spans, none under the 300 m chord between them.
        let net = try M.network([
            M.way(1, M.residential, [(1, 0, -800), (2, 0, 800)]),
            M.way(2, M.residential, [(3, 300, -800), (4, 300, 800)]),
        ])
        let first: [NavigationInput] = (0...10).map { k in Self.fix(Double(k), 0, Double(k) * 10) }
        let second: [NavigationInput] = (20...30).map { k in Self.fix(Double(k), 300, 100 + Double(k - 20) * 10) }
        let reference = try #require(ReferenceRouteBuilder.build(inputs: first + second))
        let match = RouteEdgeMatcher(network: net).match(reference.route)
        let active = ReplayActiveRoute(route: reference.route, match: match, windows: reference.windows,
                                       alongRanges: reference.projectionRanges, spans: reference.spans.map(\.alongM))
        let e = ReplayRouteEvaluation.entry(active)
        // Whole polyline: 500 m, the chord mostly unmatched.
        #expect(abs(e.lengthM - 500) < 0.5)
        #expect(e.coverage < 0.6 && e.isWeak)
        // Spans only: 200 m driven, matched.
        #expect(abs((e.spanLengthM ?? 0) - 200) < 0.5)
        #expect((e.spanCoverage ?? 0) > 0.95, "\(String(describing: e.spanCoverage))")
        let chord = (e.chordGaps ?? []).reduce(0) { $0 + $1.lengthM }
        let inSpans = (e.spanGaps ?? []).reduce(0) { $0 + $1.lengthM }
        #expect(chord > 200)
        // Every unmatched metre is in exactly one of the two lists.
        #expect(abs(chord + inSpans - e.gaps.reduce(0) { $0 + $1.lengthM }) < 1e-6)
        #expect(abs((e.spanMatchedLengthM ?? 0) - ((e.spanLengthM ?? 0) - inSpans)) < 1e-9)
        // Not a reference route: no span numbers.
        let plain = ReplayRouteEvaluation.entry(ReplayActiveRoute(route: reference.route, match: match, windows: reference.windows))
        #expect(plain.spanCoverage == nil && plain.chordGaps == nil)
        // The split itself: a gap across a span end is cut there.
        let split = ReplayRouteEvaluation.splitGaps([RouteMatchGap(startM: 80, endM: 150)], spans: [0...100, 400...500], lengthM: 500)
        #expect(split.inSpans == [RouteMatchGap(startM: 80, endM: 100)])
        #expect(split.inChords == [RouteMatchGap(startM: 100, endM: 150)])
    }
}
