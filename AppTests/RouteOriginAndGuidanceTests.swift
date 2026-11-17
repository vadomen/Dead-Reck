import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

/// Origin choice and guidance (prompt 52): which position a route starts from,
/// progress along it, the away-from-route display guard and arrival.
@Suite("Route origin rule")
struct RouteOriginRuleTests {
    private func fix(accuracy: Double = 8, age: Double = 1) -> RawFixInput {
        RawFixInput(point: GeoPoint(latitude: 0.001, longitude: 0.001), horizontalAccuracy: accuracy, ageS: age)
    }

    private func inputs(
        run: Bool = true, estimate: NavDisplay? = nil, fix: RawFixInput? = nil, gpsOff: Bool = false, pin: GeoPoint? = nil
    ) -> RouteOriginInputs {
        RouteOriginInputs(runActive: run, estimate: estimate, fix: fix, gpsOff: gpsOff, pin: pin)
    }

    @Test("(a) A converged estimate within 1 km is the origin, source `estimate`, whatever the raw fix says")
    func estimate() {
        let nav = RouteFixtures.nav(major: 400)
        let choice = RouteOriginRule.choose(inputs(estimate: nav, fix: fix(accuracy: 5)))
        #expect(choice == .estimate(nav.position))
        #expect(RouteOriginRule.resolve(choice) == ResolvedOrigin(point: nav.position, source: .estimate))
    }

    @Test("(b) An uncertain estimate: the pin first (source `pin`), Route anyway from the estimate (source `estimate`)")
    func uncertain() {
        let finding = RouteFixtures.nav(major: 2_400, converged: false)
        let wide = RouteFixtures.nav(major: 1_001)
        for nav in [finding, wide] {
            let none = RouteOriginRule.choose(inputs(estimate: nav))
            #expect(none == .uncertain(estimate: nav.position, pin: nil))
            #expect(RouteOriginRule.resolve(none) == nil, "no route until the pin or Route anyway")
            #expect(RouteOriginRule.resolve(none, routeAnyway: true)?.source == .estimate)
            let pin = GeoPoint(latitude: 0.002, longitude: 0.002)
            let withPin = RouteOriginRule.choose(inputs(estimate: nav, pin: pin))
            #expect(RouteOriginRule.resolve(withPin) == ResolvedOrigin(point: pin, source: .pin))
            #expect(RouteOriginRule.resolve(withPin, routeAnyway: true)?.source == .estimate)
        }
    }

    @Test("The 1 km edge is the existing Finding-your-position rule, not a new threshold")
    func sameThreshold() {
        #expect(RouteOriginRule.choose(inputs(estimate: RouteFixtures.nav(major: PositionStatus.maxSemiMajorM)))
            == .estimate(RouteFixtures.origin))
        #expect(RouteOriginRule.choose(inputs(estimate: RouteFixtures.nav(major: PositionStatus.maxSemiMajorM + 1)))
            != .estimate(RouteFixtures.origin))
    }

    @Test("(c) With no estimate, a raw fix only when ≤ 15 m, ≤ 5 s old and GPS is not off; else a pin is asked for")
    func rawFix() {
        #expect(RouteOriginRule.choose(inputs(run: false, fix: fix())) == .fix(fix().point))
        #expect(RouteOriginRule.resolve(.fix(fix().point))?.source == .fix)
        #expect(RouteOriginRule.choose(inputs(run: false, fix: fix(accuracy: 15, age: 5))) == .fix(fix().point))
        #expect(RouteOriginRule.choose(inputs(run: false, fix: fix(accuracy: 15.1))) == .needsPin(pin: nil))
        #expect(RouteOriginRule.choose(inputs(run: false, fix: fix(age: 5.1))) == .needsPin(pin: nil))
        #expect(RouteOriginRule.choose(inputs(run: false, fix: fix(accuracy: -1))) == .needsPin(pin: nil))
        #expect(RouteOriginRule.choose(inputs(run: false, fix: fix(), gpsOff: true)) == .needsPin(pin: nil))
        #expect(RouteOriginRule.choose(inputs(run: false, fix: nil)) == .needsPin(pin: nil))
        #expect(RouteOriginRule.resolve(.needsPin(pin: nil)) == nil)
    }

    @Test("A pin with no estimate and no good fix is the origin, source `pin`")
    func pinWithoutEstimate() {
        let pin = GeoPoint(latitude: 0.003, longitude: 0.001)
        let choice = RouteOriginRule.choose(inputs(run: false, pin: pin))
        #expect(RouteOriginRule.resolve(choice) == ResolvedOrigin(point: pin, source: .pin))
    }

    @Test("An estimate without a running Navigate or Record is not used; the raw fix rule applies")
    func estimateNeedsRun() {
        let choice = RouteOriginRule.choose(inputs(run: false, estimate: RouteFixtures.nav(), fix: fix()))
        #expect(choice == .fix(fix().point))
    }

    @Test("The log origin carries the source as `fix`, `estimate` or `pin`")
    func logOrigin() {
        let origin = ResolvedOrigin(point: GeoPoint(latitude: 1, longitude: 2), source: .pin).logOrigin
        #expect(origin.source?.rawValue == "pin" && origin.latitude == 1 && origin.longitude == 2)
    }

    @Test("The search region: the estimate, else the last good fix, else Kyiv-wide")
    func region() {
        let a = GeoPoint(latitude: 1, longitude: 2), b = GeoPoint(latitude: 3, longitude: 4)
        #expect(SearchRegion.choose(estimate: a, lastGoodFix: b).latitude == 1)
        #expect(SearchRegion.choose(estimate: nil, lastGoodFix: b).latitude == 3)
        #expect(SearchRegion.choose(estimate: nil, lastGoodFix: nil) == .kyivWide)
    }
}

/// Reference wrapper: `#expect` cannot call a mutating member on a local value.
private final class Detector {
    private var detector = ArrivalDetector()

    func update(remainingM: Double?, speedMS: Double?, now: TimeInterval) -> Bool {
        detector.update(remainingM: remainingM, speedMS: speedMS, now: now)
    }
}

@Suite("Route guidance")
struct RouteGuidanceTests {
    private let geometry = RouteGeometry(route: RouteFixtures.route())

    @Test("On the route: distance to the next manoeuvre, remaining distance and time from the projection")
    func onRoute() {
        let g = RouteGuidance.compute(geometry: geometry, estimate: RouteFixtures.nav(RouteFixtures.point(alongM: 400)))
        #expect(g.status == .onRoute)
        #expect(abs((g.alongM ?? 0) - 400) < 2)
        #expect(abs((g.next?.distanceToM ?? 0) - 600) < 2, "the right turn is at 1 km")
        #expect(g.nextStep?.maneuver == .right)
        #expect(abs((g.remainingM ?? 0) - 1_600) < 3)
        #expect(abs((g.remainingTimeS ?? 0) - 160) < 1)
    }

    @Test("The empty first step (depart) is never the next manoeuvre")
    func skipsDepart() {
        let g = RouteGuidance.compute(geometry: geometry, estimate: RouteFixtures.nav(RouteFixtures.point(alongM: 0)))
        #expect(g.nextStep?.maneuver == .right)
        #expect(RouteConversion.displaySteps(geometry.route).first?.maneuver != .depart)
        #expect(geometry.route.steps.first?.maneuver == .depart, "kept in the data")
    }

    @Test("An uncertain estimate says so instead of a distance")
    func uncertain() {
        let finding = RouteFixtures.nav(RouteFixtures.point(alongM: 400), major: 2_400, converged: false)
        let g = RouteGuidance.compute(geometry: geometry, estimate: finding)
        #expect(g.status == .uncertain && g.remainingM == nil && g.alongM == nil)
        #expect(RouteGuidance.compute(geometry: geometry, estimate: nil).status == .uncertain)
    }

    @Test("Display guard: beyond 150 m (160 m here, metres of latitude differ by under 1 %) from the route the bar says `Away from the route`; 140 m is still on it")
    func awayFromRoute() {
        #expect(RouteGuidance.awayFromRouteM == 150)
        let near = RouteGuidance.compute(
            geometry: geometry, estimate: RouteFixtures.nav(RouteFixtures.point(alongM: 500, offsetM: 140)))
        let far = RouteGuidance.compute(
            geometry: geometry, estimate: RouteFixtures.nav(RouteFixtures.point(alongM: 500, offsetM: 160)))
        #expect(near.status == .onRoute)
        #expect(far.status == .awayFromRoute && far.remainingM == nil)
    }

    @Test("Progress is read in order near the last position (a route that passes a place twice)")
    func previousAlong() {
        let g = RouteGuidance.compute(
            geometry: geometry, estimate: RouteFixtures.nav(RouteFixtures.point(alongM: 700)), previousAlongM: 650)
        #expect(abs((g.alongM ?? 0) - 700) < 2)
    }

    @Test("Arrival needs under 50 m to go AND speed under 1 m/s for 3 s in a row")
    func arrival() {
        let d = Detector()
        #expect(!d.update(remainingM: 49, speedMS: 0.5, now: 0))
        #expect(!d.update(remainingM: 49, speedMS: 0.5, now: 2.9))
        #expect(d.update(remainingM: 49, speedMS: 0.5, now: 3.0))
        let moving = Detector()
        #expect(!moving.update(remainingM: 20, speedMS: 1.0, now: 0))
        #expect(!moving.update(remainingM: 20, speedMS: 1.0, now: 10), "1 m/s is not stopped")
        let far = Detector()
        #expect(!far.update(remainingM: 50, speedMS: 0, now: 0))
        #expect(!far.update(remainingM: 50, speedMS: 0, now: 10), "50 m is not under 50 m")
        let unknown = Detector()
        #expect(!unknown.update(remainingM: 10, speedMS: nil, now: 0))
        #expect(!unknown.update(remainingM: 10, speedMS: nil, now: 10), "unknown speed is not stopped")
    }

    @Test("A frame that breaks the conditions restarts the 3 s hold")
    func arrivalRestarts() {
        let d = Detector()
        _ = d.update(remainingM: 20, speedMS: 0, now: 0)
        _ = d.update(remainingM: 20, speedMS: 2, now: 2)
        #expect(!d.update(remainingM: 20, speedMS: 0, now: 3), "hold restarted at 3")
        #expect(d.update(remainingM: 20, speedMS: 0, now: 6.1))
        _ = d.update(remainingM: nil, speedMS: 0, now: 7)
        #expect(!d.update(remainingM: 20, speedMS: 0, now: 8))
    }

    @Test("The flow keeps the last instruction while the estimate is uncertain")
    @MainActor func flowKeepsInstruction() async {
        let rig = RouteFlowTests.Rig()
        await rig.toGuiding()
        rig.flow.tick(estimate: RouteFixtures.nav(RouteFixtures.point(alongM: 300)), speedMS: 10, now: 0)
        let step = rig.flow.guidance?.nextStep
        #expect(step?.maneuver == .right)
        rig.flow.tick(estimate: RouteFixtures.nav(RouteFixtures.point(alongM: 300), major: 3_000, converged: false), speedMS: 10, now: 1)
        #expect(rig.flow.guidance?.status == .uncertain)
        #expect(rig.flow.guidance?.nextStep == step)
    }
}
