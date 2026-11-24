import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

/// A route that ends short of the destination (prompt 53a item 3): the measure, the card text, the dashed
/// segment, the bar states, the away guard, arrival at the destination point, and the row's destination.
/// Routes are the fixtures' eastbound ones from (0, 0); invented coordinates near (0, 0).
@MainActor
@Suite("Route that ends short of the destination")
struct LastLegTests {
    /// A place `alongM` metres east of (0, 0), on the line of the fixture routes.
    static func place(alongM: Double) -> RoutePlace {
        RoutePlace(name: "Far Café", addressLine: "", latitude: 0, longitude: alongM / 111_320)
    }

    /// Two routes of 2 000 m and one of 2 300 m (the fixture routes have a point per 100 m), to a place at 2 300 m: gaps 300, 300 and 0.
    static let destinationAlongM = 2_300.0

    @MainActor struct Rig {
        let flow: RouteFlowModel
        let searcher = StubSearcher()
        let director = StubDirector()
        let sink = SinkRecorder()
        let clock = VirtualClock()

        init(routes: [Route]? = nil) {
            director.results = [.success(routes ?? [
                RouteFixtures.route(id: "a", lengthM: 2_000), RouteFixtures.route(id: "b", lengthM: 2_000),
                RouteFixtures.route(id: "c", lengthM: 2_300),
            ])]
            flow = RouteFlowModel(
                searcher: searcher, director: director,
                pacer: RequestPacer(clock: clock.pacerClock, debounce: 0.5, minInterval: 1.5),
                saved: SavedDestinationsStore.preview(), sink: sink)
            let inputs = RouteLiveInputs(origin: RouteOriginInputs(runActive: true, estimate: RouteFixtures.nav()), speedMS: 12)
            flow.fixInputs { inputs }
        }

        func toAlternatives(_ place: RoutePlace) async {
            flow.openSearch()
            flow.select(place)
            flow.route()
            await waitUntil("alternatives") { flow.phase == .alternatives }
        }

        func toGuiding(_ place: RoutePlace) async {
            await toAlternatives(place)
            flow.start()
        }

        func tick(alongM: Double, offsetM: Double = 0, speed: Double = 12, now: Double = 0) {
            flow.tick(estimate: RouteFixtures.nav(RouteFixtures.point(alongM: alongM, offsetM: offsetM)), speedMS: speed, now: now)
        }
    }

    // MARK: The measure

    @Test("The threshold is one constant, 50 m: above it there is a last leg, at or below it the route reaches the destination")
    func threshold() {
        #expect(LastLeg.thresholdM == 50)
        let route = RouteFixtures.route(lengthM: 2_000)
        #expect(LastLeg.measure(route: route, to: RouteFixtures.point(alongM: 2_040)) == nil)
        #expect(LastLeg.measure(route: route, to: RouteFixtures.point(alongM: 1_950)) == nil, "short of the end counts the same")
        let leg = LastLeg.measure(route: route, to: RouteFixtures.point(alongM: 2_060))
        #expect(abs((leg?.gapM ?? 0) - 60) < 1)
        #expect(abs(LastLeg.distanceM(leg!.end, leg!.destination) - leg!.gapM) < 0.001)
    }

    @Test("Distance to the leg is to the segment: clamped at both ends, 150 m corridor")
    func corridor() throws {
        let leg = try #require(LastLeg.measure(route: RouteFixtures.route(lengthM: 2_000), to: RouteFixtures.point(alongM: 2_300)))
        #expect(abs(leg.distanceToLegM(from: RouteFixtures.point(alongM: 2_150, offsetM: 40)) - 40) < 0.5)
        #expect(abs(leg.distanceToLegM(from: RouteFixtures.point(alongM: 1_900)) - 100) < 0.5, "before the end: to the end point")
        #expect(abs(leg.distanceToLegM(from: RouteFixtures.point(alongM: 2_400)) - 100) < 0.5, "beyond the destination")
        #expect(leg.contains(RouteFixtures.point(alongM: 2_100, offsetM: 149)))
        #expect(!leg.contains(RouteFixtures.point(alongM: 2_100, offsetM: 160)))
    }

    // MARK: Alternatives card and map layer

    @Test("Each offered route is measured on its own: the card text shows for those 300 m short, not for the one that reaches it")
    func cardTextPerRoute() async throws {
        let rig = Rig()
        await rig.toAlternatives(Self.place(alongM: Self.destinationAlongM))
        let gaps = rig.flow.alternatives.indices.map { rig.flow.lastLeg(ofAlternative: $0)?.gapM }
        #expect(gaps.count == 3)
        #expect(abs((gaps[0] ?? 0) - 300) < 1 && abs((gaps[1] ?? 0) - 300) < 1)
        #expect(gaps[2] == nil)
        let text = RouteFormat.routeEnds(gapM: try #require(gaps[0]))
        #expect(text.contains("300"), "\(text)")
        #expect(text.localizedCaseInsensitiveContains("before the destination") || text.contains("пункту призначення"), "\(text)")
    }

    @Test("The dashed leg is in the map layer model for every route that needs one, the chosen emphasised; none when the route reaches it")
    func dashedLegSegments() async throws {
        let rig = Rig()
        await rig.toAlternatives(Self.place(alongM: Self.destinationAlongM))
        #expect(rig.flow.lastLegSegments.map(\.chosen) == [true, false])
        rig.flow.chooseAlternative(1)
        #expect(rig.flow.lastLegSegments.map(\.chosen) == [false, true])
        rig.flow.chooseAlternative(2)
        #expect(rig.flow.lastLegSegments.map(\.chosen) == [false, false], "the chosen route reaches it: no emphasised leg")
        let leg = try #require(rig.flow.lastLegSegments.first?.leg)
        #expect(leg.destination == Self.place(alongM: Self.destinationAlongM).coordinate)
        #expect(!RouteColors.lastLegDash.isEmpty && RouteColors.lastLegDash.allSatisfy { $0 > 0 })
        // The camera frames the destination too, not only the chosen route.
        rig.flow.chooseAlternative(0)
        let points = try #require(rig.flow.framingPoints)
        #expect(points.last?.longitude == leg.destination.longitude)
        #expect(points.count == RouteFixtures.route(lengthM: 2_000).polyline.count + 1)
        rig.flow.start()
        #expect(rig.flow.lastLegSegments.count == 1 && rig.flow.lastLegSegments[0].chosen, "the active route's leg while guiding")
    }

    @Test("A route that reaches the destination: no leg, no text, no extra framing point")
    func reachesDestination() async {
        let rig = Rig(routes: [RouteFixtures.route(id: "a", lengthM: 2_000)])
        await rig.toAlternatives(Self.place(alongM: 2_030))
        #expect(rig.flow.lastLeg(ofAlternative: 0) == nil)
        #expect(rig.flow.lastLegSegments.isEmpty)
        #expect(rig.flow.framingPoints?.count == RouteFixtures.route(lengthM: 2_000).polyline.count)
        rig.flow.start()
        #expect(rig.flow.active?.lastLeg == nil && rig.flow.lastLegSegments.isEmpty)
    }

    @Test("A rebuild measures again, from the new route")
    func rebuildMeasuresAgain() async {
        let rig = Rig(routes: [RouteFixtures.route(id: "a", lengthM: 2_000)])
        await rig.toGuiding(Self.place(alongM: 2_300))
        #expect(rig.flow.active?.lastLeg != nil)
        rig.director.results = [.success([RouteFixtures.route(id: "b", lengthM: 2_300)])]
        rig.flow.rebuild()
        await waitUntil("alternatives") { rig.flow.phase == .alternatives }
        #expect(rig.flow.lastLeg(ofAlternative: 0) == nil, "the new route ends on it")
        rig.flow.start()
        #expect(rig.flow.active?.route.id == "b" && rig.flow.active?.lastLeg == nil)
    }

    // MARK: Guidance

    @Test("Normal manoeuvre guidance up to the route end; at the end the bar is on the last leg with the straight-line distance counting down")
    func barStates() async throws {
        let rig = Rig(routes: [RouteFixtures.route(id: "a", lengthM: 2_000)])
        await rig.toGuiding(Self.place(alongM: 2_300))
        rig.tick(alongM: 900)
        #expect(rig.flow.guidance?.status == .onRoute && rig.flow.guidance?.next != nil)
        rig.tick(alongM: 1_900)
        #expect(rig.flow.guidance?.status == .onRoute, "100 m from the route end: still the route's guidance")
        rig.tick(alongM: 1_990)
        #expect(rig.flow.guidance?.status == .lastLeg)
        #expect(abs((rig.flow.guidance?.distanceToDestinationM ?? 0) - 310) < 1)
        rig.tick(alongM: 2_150)
        #expect(rig.flow.guidance?.status == .lastLeg)
        #expect(abs((rig.flow.guidance?.distanceToDestinationM ?? 0) - 150) < 1, "counts down")
        #expect(rig.flow.guidance?.next == nil && rig.flow.guidance?.remainingM == nil)
        let gap = try #require(rig.flow.active?.lastLeg?.gapM)
        #expect(abs(gap - 300) < 1)
        #expect(RouteFormat.routeEnds(gapM: gap).contains("300"))
        // Back on the route (a u-turn before the end) is the route's guidance again.
        rig.tick(alongM: 1_700)
        #expect(rig.flow.guidance?.status == .onRoute)
    }

    @Test("\"Away from the route\" does not fire on the last leg: 200 m past the route end is on the leg, 200 m beside it is away")
    func noAwayOnLastLeg() async {
        let rig = Rig(routes: [RouteFixtures.route(id: "a", lengthM: 2_000)])
        await rig.toGuiding(Self.place(alongM: 2_300))
        rig.tick(alongM: 2_200)
        #expect(rig.flow.guidance?.status == .lastLeg, "200 m from the route's end, 100 m from the destination")
        rig.tick(alongM: 2_150, offsetM: 200)
        #expect(rig.flow.guidance?.status == .awayFromRoute, "outside the leg's corridor the guard applies as before")
        rig.tick(alongM: 2_150, offsetM: 100)
        #expect(rig.flow.guidance?.status == .lastLeg, "inside the corridor")
        // The same place on a route with no last leg is away: the rule only relaxes the guard for a leg.
        let plain = RouteGuidance.compute(
            geometry: RouteGeometry(route: RouteFixtures.route(lengthM: 2_000)),
            estimate: RouteFixtures.nav(RouteFixtures.point(alongM: 2_200)))
        #expect(plain.status == .awayFromRoute)
    }

    /// A destination beside the route end, so the leg bends away from the route's line: points on it are
    /// far from the route (cross-track over the 150 m guard) while still on the leg.
    static func besidePlace() -> RoutePlace {
        let p = RouteFixtures.point(alongM: 1_850, offsetM: 250)
        return RoutePlace(name: "Far Café", addressLine: "", latitude: p.latitude, longitude: p.longitude)
    }

    @Test("R94.1-4: once the route end is reached the leg is sticky: a point on the leg over 30 m from the end along the route and over 150 m off it is the last leg, not away")
    func stickyLastLeg() async {
        let rig = Rig(routes: [RouteFixtures.route(id: "a", lengthM: 2_000)])
        await rig.toGuiding(Self.besidePlace())
        #expect(rig.flow.active?.lastLeg != nil)
        let onLeg = RouteFixtures.point(alongM: 1_886, offsetM: 190)
        #expect(rig.flow.active?.lastLeg?.contains(onLeg) == true)
        rig.tick(alongM: 1_886, offsetM: 190)
        #expect(rig.flow.guidance?.status == .awayFromRoute, "not yet at the route end: the guard applies")
        rig.tick(alongM: 2_000)
        #expect(rig.flow.guidance?.status == .lastLeg, "at the route end")
        rig.tick(alongM: 1_886, offsetM: 190)
        #expect(rig.flow.guidance?.status == .lastLeg, "remembered: 114 m from the end along the route, 190 m off it")
    }

    @Test("R94.1-4: the memory is cleared by driving back onto the route over 150 m from its end: re-entering the leg's corridor without reaching the end is away again")
    func stickyLastLegResets() async {
        let rig = Rig(routes: [RouteFixtures.route(id: "a", lengthM: 2_000)])
        await rig.toGuiding(Self.besidePlace())
        rig.tick(alongM: 2_000)
        #expect(rig.flow.guidance?.status == .lastLeg)
        rig.tick(alongM: 1_500)
        #expect(rig.flow.guidance?.status == .onRoute)
        rig.tick(alongM: 1_886, offsetM: 190)
        #expect(rig.flow.guidance?.status == .awayFromRoute, "reset: the end was not reached again")
    }

    @Test("Mid-route the leg changes nothing: a car near the leg's corridor but far from the route end is not on the last leg")
    func leavesRouteMidway() {
        let route = RouteFixtures.route(lengthM: 2_000)
        let leg = LastLeg.measure(route: route, to: RouteFixtures.point(alongM: 2_300))
        let guidance = RouteGuidance.compute(
            geometry: RouteGeometry(route: route), estimate: RouteFixtures.nav(RouteFixtures.point(alongM: 500, offsetM: 400)),
            lastLeg: leg)
        #expect(guidance.status == .awayFromRoute)
        #expect(guidance.distanceToDestinationM != nil, "arrival can still see the destination")
    }

    // MARK: Arrival

    @Test("Stopped at the route end 300 m short: not arrived, the route stays; stopped within 50 m of the destination: arrived")
    func arrivalAtDestination() async {
        let rig = Rig(routes: [RouteFixtures.route(id: "a", lengthM: 2_000)])
        await rig.toGuiding(Self.place(alongM: 2_300))
        for now in [0.0, 2, 3.1, 10, 30] { rig.tick(alongM: 2_000, speed: 0, now: now) }
        #expect(rig.flow.phase == .guiding && rig.flow.active != nil, "reaching the route end alone never clears the route")
        #expect(rig.sink.rows.count == 1)
        // Near but not within 50 m, stopped: no arrival.
        for now in [40.0, 44, 50] { rig.tick(alongM: 2_240, speed: 0, now: now) }
        #expect(rig.flow.phase == .guiding)
        // Moving through the 50 m circle does not count; stopped there for 3 s does.
        rig.tick(alongM: 2_270, speed: 8, now: 60)
        rig.tick(alongM: 2_270, speed: 0, now: 61)
        rig.tick(alongM: 2_270, speed: 0, now: 63)
        #expect(rig.flow.phase == .guiding)
        rig.tick(alongM: 2_270, speed: 0, now: 64.1)
        #expect(rig.flow.phase == .arrived)
        #expect(rig.sink.rows.last == .cleared(id: "a", reason: "arrived"))
        #expect(rig.flow.arrivedPlace == Self.place(alongM: 2_300))
    }

    @Test("Arriving at the destination from beside the leg still counts: it is the point that is measured")
    func arrivalFromBesideTheLeg() async {
        let rig = Rig(routes: [RouteFixtures.route(id: "a", lengthM: 2_000)])
        await rig.toGuiding(Self.place(alongM: 2_300))
        for now in [0.0, 1, 3.5] { rig.tick(alongM: 2_300, offsetM: 30, speed: 0, now: now) }
        #expect(rig.flow.phase == .arrived)
    }

    @Test("A route that reaches the destination (50 m or less): arrival along the route and the bar exactly as before")
    func unchangedWithinThreshold() async {
        let rig = Rig(routes: [RouteFixtures.route(id: "a", lengthM: 2_000)])
        await rig.toGuiding(Self.place(alongM: 2_040))
        #expect(rig.flow.active?.lastLeg == nil)
        rig.tick(alongM: 1_990, speed: 12)
        #expect(rig.flow.guidance?.status == .onRoute && rig.flow.guidance?.distanceToDestinationM == nil)
        rig.tick(alongM: 2_100, speed: 12)
        #expect(rig.flow.guidance?.status != .lastLeg)
        for now in [0.0, 2, 3.1] { rig.tick(alongM: 1_990, speed: 0, now: now) }
        #expect(rig.flow.phase == .arrived, "50 m of the route's end, as today")
    }

    // MARK: The row's destination

    @Test("Every route row carries the destination as named, with how it was chosen; the hand-over carries it too")
    func rowDestination() async throws {
        let rig = Rig(routes: [RouteFixtures.route(id: "a", lengthM: 2_000)])
        let place = Self.place(alongM: 2_300)
        await rig.toGuiding(place)
        #expect(rig.sink.destinations == [RouteDestination(latitude: place.latitude, longitude: place.longitude, source: .recent)])
        #expect(rig.flow.handOver?.destination == rig.sink.destinations[0])
        // Another route to the same place (a rebuild): the row has it again.
        rig.flow.rebuild()
        await waitUntil("alternatives") { rig.flow.phase == .alternatives }
        rig.flow.start()
        #expect(rig.sink.destinations.count == 2 && rig.sink.destinations[1] == rig.sink.destinations[0])
    }

    @Test("The source names the way in: search, pin, coordinates, link, saved, recent")
    func sources() async throws {
        let rig = Rig(routes: [RouteFixtures.route(id: "a", lengthM: 2_000)])
        func sourceAfter(_ open: () -> Void) async -> RouteDestination.Source? {
            rig.flow.cancel()
            rig.flow.openSearch()
            open()
            await waitUntil("card") { rig.flow.phase == .placeCard }
            rig.flow.route()
            await waitUntil("alternatives") { rig.flow.phase == .alternatives }
            rig.flow.start()
            return rig.sink.destinations.last??.source
        }
        rig.searcher.completionResult = .success([DestinationCompletion(id: "1", title: "Far Café", subtitle: "")])
        #expect(await sourceAfter { rig.flow.longPress(at: RouteFixtures.point(alongM: 2_300)) } == .pin)
        #expect(await sourceAfter { rig.flow.updateQuery("-0.5, -0.5"); rig.flow.selectCoordinates() } == .coordinates)
        #expect(await sourceAfter {
            rig.flow.updateQuery("https://www.google.com/maps/place/Test+Cove/@-0.5,-0.5,17z/data=!3d-0.5!4d-0.5")
            rig.flow.selectCoordinates()
        } == .link)
        #expect(await sourceAfter { rig.flow.select(Self.place(alongM: 2_300)) } == .recent)
        rig.flow.saved.setHome(Self.place(alongM: 2_400))
        #expect(await sourceAfter { rig.flow.select(Self.place(alongM: 2_400)) } == .saved)
        rig.flow.cancel()
        rig.flow.openSearch()
        rig.flow.updateQuery("far")
        await waitUntil("completions") { rig.flow.searchStatus == .ready }
        rig.flow.select(rig.flow.completions[0])
        await waitUntil("card") { rig.flow.phase == .placeCard }
        rig.flow.route()
        await waitUntil("alternatives") { rig.flow.phase == .alternatives }
        rig.flow.start()
        #expect(rig.sink.destinations.last??.source == .search)
    }
}
