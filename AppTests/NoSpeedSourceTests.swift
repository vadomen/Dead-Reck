import DriveLoggerCore
import Foundation
import Testing

@testable import DriveLogger

/// Prompt 53d: "No speed source" instead of a frozen distance. The rule is `NoSpeedSourceRule`
/// (injected clock, no sensors); the feed stamps it on the display (`NavigationFeed.stamped`) from a
/// scripted probe. The engine's own `stationary` is scripted on the display here; one test reads it
/// from a real engine snapshot. Every position is synthetic, near (0, 0).
@MainActor
@Suite("No speed source (prompt 53d)")
struct NoSpeedSourceTests {
    /// A feed on a scripted probe: the clock, whether a run is active, whether a speed source is present.
    @MainActor
    final class Rig {
        var now = 1_000.0
        var runActive = true
        var source = false
        let feed = NavigationFeed(display: nil)

        init() {
            feed.speedProbe = { [unowned self] in
                NoSpeedSourceRule.Probe(now: now, runActive: runActive, hasSpeedSource: source)
            }
        }

        /// One evaluation at `now`, as the map's poll or guidance's peek does it.
        @discardableResult
        func eval(stationary: Bool = false, estimate: Bool = true) -> Bool {
            let display = estimate ? NavDisplay(
                position: RouteFixtures.origin, semiMajorM: 30, semiMinorM: 10, orientationDeg: 0, headingDeg: 90,
                headingStdDeg: 3, converged: true, stationary: stationary) : nil
            return feed.stamped(display)?.noSpeedSource ?? false
        }

        /// Steps the clock by `dt` and evaluates, repeatedly, until `seconds` have passed.
        func advance(for seconds: Double, every dt: Double = 1, stationary: Bool = false) -> [Bool] {
            var out: [Bool] = []
            var elapsed = 0.0
            while elapsed + 1e-9 < seconds {
                now += dt
                elapsed += dt
                out.append(eval(stationary: stationary))
            }
            return out
        }
    }

    // MARK: Must not flip

    @Test("Fuel stop: OBD 0, then the ECU silent for 7 min, standing held, no GPS: never uncertain")
    func fuelStop() {
        let rig = Rig()
        rig.source = true
        #expect(!rig.eval(stationary: true))
        rig.source = false
        let states = rig.advance(for: 7 * 60, stationary: true)
        #expect(!states.contains(true))
    }

    @Test("Red light: OBD answering 0 (a fresh source), standing: not uncertain, however long")
    func redLight() {
        let rig = Rig()
        rig.source = true
        #expect(!rig.advance(for: 180, stationary: true).contains(true))
    }

    @Test("Reconnect gap: about 20 s of OBD silence while standing: not uncertain")
    func reconnectGap() {
        let rig = Rig()
        rig.source = true
        rig.eval(stationary: true)
        rig.source = false
        #expect(!rig.advance(for: 20, stationary: true).contains(true))
        rig.source = true
        #expect(!rig.eval(stationary: true))
    }

    @Test("GPS off with OBD answering at speed: a source is present, not uncertain")
    func gpsOffObdAtSpeed() {
        let rig = Rig()
        rig.source = true
        #expect(!rig.advance(for: 120, stationary: false).contains(true))
    }

    // MARK: Must flip

    @Test("Adapter unplugged at speed, GPS off: uncertain after more than 5 s, not at 4.9 s (nor at exactly 5)")
    func unpluggedAtSpeed() {
        let rig = Rig()
        rig.source = true
        #expect(!rig.eval())
        rig.source = false
        rig.now += 0.1
        #expect(!rig.eval(), "the loss is first seen here: the count starts")
        let lost = rig.now
        rig.now = lost + 4.9
        #expect(!rig.eval())
        rig.now = lost + 5.0
        #expect(!rig.eval(), "more than 5 s")
        rig.now = lost + 5.1
        #expect(rig.eval())
        #expect(NoSpeedSourceRule.thresholdS == 5)
    }

    @Test("Adapter never connected, only network fixes (no source), moving: uncertain within the threshold")
    func neverConnected() {
        let rig = Rig()
        let states = rig.advance(for: 8, every: 0.5)
        // The count starts at the first evaluation (0.5 s in); it flips once more than 5 s have passed since.
        let firstTrue = states.firstIndex(of: true).map { Double($0 + 1) * 0.5 - 0.5 }
        #expect(firstTrue != nil && firstTrue! > 5 && firstTrue! <= 5.5, "flipped \(String(describing: firstTrue)) s after the first look")
        #expect(states.last == true)
    }

    @Test("2026-11-02 case: OBD lost at a stop, then the car moves on network fixes: standing first (no flip), uncertain at once when the engine's motion check clears it")
    func lostAtAStopThenMoves() {
        let rig = Rig()
        rig.source = true
        rig.eval(stationary: true)
        rig.source = false
        #expect(!rig.advance(for: 30, stationary: true).contains(true), "parked: no flip")
        // The IMU shows motion: the engine's `stationary` clears; no source for 30 s already.
        rig.now += 1
        #expect(rig.eval(stationary: false))
    }

    @Test("Clearing: the first fresh speed source clears at once; losing it again restarts the 5 s count")
    func clearing() {
        let rig = Rig()
        _ = rig.advance(for: 7)
        #expect(rig.eval())
        rig.source = true
        rig.now += 0.1
        #expect(!rig.eval(), "no hysteresis")
        rig.source = false
        rig.now += 0.1
        #expect(!rig.eval())
        rig.now += 4.9
        #expect(!rig.eval())
        rig.now += 0.3
        #expect(rig.eval())
    }

    // MARK: Scope

    @Test("Idle: no run, or no estimate yet: the state is false, the timer does not run, and the status line is unchanged")
    func idleScope() {
        let rig = Rig()
        rig.runActive = false
        #expect(!rig.advance(for: 60).contains(true), "no run")
        // Rebuild: run active but no estimate yet for a minute.
        let idle = Rig()
        for _ in 0..<60 {
            idle.now += 1
            #expect(!idle.eval(estimate: false))
        }
        idle.now += 1
        #expect(!idle.eval(), "the count starts with the estimate, not before")
        idle.now += 5.1
        #expect(idle.eval())
        // With no run, the display is untouched and the line is the usual one.
        let nav = RouteFixtures.nav()
        #expect(PositionStatus.line(nav) == nil)
        #expect(!PositionStatus.isFinding(nav))
        let quiet = Rig()
        quiet.runActive = false
        quiet.now += 100
        #expect(quiet.feed.stamped(nav) == nav)
    }

    @Test("A feed with no probe (previews, the demo, tests) never sets the state")
    func noProbe() {
        let feed = NavigationFeed(display: nil)
        #expect(feed.stamped(RouteFixtures.nav())?.noSpeedSource == false)
    }

    @Test("A run ending resets the count: the next run starts from zero")
    func runEndResets() {
        let rig = Rig()
        _ = rig.advance(for: 7)
        rig.runActive = false
        #expect(!rig.eval())
        rig.runActive = true
        rig.now += 1
        #expect(!rig.eval(), "a new count")
    }

    @Test("A clock that goes backwards restarts the count instead of going negative")
    func clockBackwards() {
        var rule = NoSpeedSourceRule()
        func at(_ now: Double) -> Bool {
            rule.evaluate(.init(now: now, runActive: true, hasSpeedSource: false), hasEstimate: true, stationary: false)
        }
        #expect(!at(100))
        #expect(!at(50))
        #expect(!at(54))
        #expect(at(55.5))
    }

    // MARK: Where it shows

    private func noSpeedNav(at point: GeoPoint = RouteFixtures.origin) -> NavDisplay {
        NavDisplay(
            position: point, semiMajorM: 30, semiMinorM: 10, orientationDeg: 0, headingDeg: 90, headingStdDeg: 3,
            converged: true, noSpeedSource: true)
    }

    @Test("The state is uncertain for every consumer: PositionStatus, the feed's published flag, the origin rule")
    func uncertainEverywhere() {
        let nav = noSpeedNav()
        #expect(PositionStatus.isFinding(nav))
        #expect(NavigationFeed(display: nav).positionFinding)
        #expect(RouteOriginRule.choose(RouteOriginInputs(runActive: true, estimate: nav))
            == .uncertain(estimate: nav.position, pin: nil), "a requested route offers I'm here first")
        #expect(NoSpeedSourceText.symbol != "location.magnifyingglass")
    }

    @Test("The HUD line says why while the state lasts, and returns to Finding your position for the other reasons")
    func hudLine() {
        #expect(PositionStatus.line(noSpeedNav()) == NoSpeedSourceText.text)
        #expect(PositionStatus.line(noSpeedNav()) != PositionStatus.text)
        #expect(PositionStatus.symbol(noSpeedNav()) == NoSpeedSourceText.symbol)
        let finding = RouteFixtures.nav(major: 2_400, converged: false)
        #expect(PositionStatus.line(finding) == PositionStatus.text)
        #expect(PositionStatus.symbol(finding) == "location.magnifyingglass")
        // Both reasons: the speed one wins.
        var both = finding
        both.noSpeedSource = true
        #expect(PositionStatus.line(both) == NoSpeedSourceText.text)
        #expect(NoSpeedSourceText.text == "No speed source — position not updating")
    }

    @Test("Guidance: the bar gets the reason, no distance and no time; the last known instruction stays")
    func guidanceReason() async {
        let geometry = RouteGeometry(route: RouteFixtures.route())
        let g = RouteGuidance.compute(geometry: geometry, estimate: noSpeedNav(at: RouteFixtures.point(alongM: 400)))
        #expect(g.status == .uncertain && g.noSpeedSource)
        #expect(g.remainingM == nil && g.remainingTimeS == nil && g.alongM == nil && g.next == nil)
        #expect(g.distanceToDestinationM == nil)
        // Ordinary uncertain keeps its own text.
        let finding = RouteGuidance.compute(
            geometry: geometry, estimate: RouteFixtures.nav(RouteFixtures.point(alongM: 400), major: 2_400, converged: false))
        #expect(finding.status == .uncertain && !finding.noSpeedSource)
        // Through the flow: the last instruction stays, the distance is hidden, not frozen.
        let rig = RouteFlowTests.Rig()
        await rig.toGuiding()
        rig.flow.tick(estimate: RouteFixtures.nav(RouteFixtures.point(alongM: 400)), speedMS: 10, now: 0)
        #expect(rig.flow.guidance?.status == .onRoute && rig.flow.guidance?.remainingM != nil)
        rig.flow.tick(estimate: noSpeedNav(at: RouteFixtures.point(alongM: 400)), speedMS: nil, now: 1)
        #expect(rig.flow.guidance?.noSpeedSource == true)
        #expect(rig.flow.guidance?.remainingM == nil && rig.flow.guidance?.remainingTimeS == nil)
        #expect(rig.flow.guidance?.nextStep?.maneuver == .right, "the last known instruction")
        rig.flow.tick(estimate: RouteFixtures.nav(RouteFixtures.point(alongM: 400)), speedMS: 10, now: 2)
        #expect(rig.flow.guidance?.status == .onRoute, "clears with the state")
    }

    @Test("Arrival does not fire in the state: within 50 m of the end and stopped-looking inputs, still no arrival")
    func arrivalSuppressed() async {
        let rig = RouteFlowTests.Rig()
        await rig.toGuiding()
        let end = noSpeedNav(at: RouteFixtures.point(alongM: 2_180))
        for second in 0...12 { rig.flow.tick(estimate: end, speedMS: 0, now: Double(second)) }
        #expect(rig.flow.phase == .guiding)
        #expect(rig.flow.guidance?.remainingM == nil)
        // The same place without the state arrives, so the suppression is the state's doing.
        let ok = RouteFixtures.nav(RouteFixtures.point(alongM: 2_180))
        rig.flow.tick(estimate: ok, speedMS: 0, now: 20)
        rig.flow.tick(estimate: ok, speedMS: 0, now: 23.5)
        #expect(rig.flow.phase == .arrived)
    }

    @Test("A write-gated display still publishes the flip at once (same position, inside the 0.25 s interval)")
    func gateAdmitsTheFlip() {
        var gate = NavWriteGate()
        func admit(_ d: NavDisplay, _ at: ContinuousClock.Instant) -> Bool { gate.admit(d, at: at) }
        let now = ContinuousClock.now
        let a = RouteFixtures.nav()
        var b = a
        b.noSpeedSource = true
        #expect(admit(a, now))
        #expect(!admit(a, now + .milliseconds(50)))
        #expect(admit(b, now + .milliseconds(100)))
        #expect(admit(a, now + .milliseconds(120)), "and the clear")
    }

    @Test("The feed publishes the state through `apply` (the map's poll) and `latest`, with no source and a real snapshot")
    func applyPublishes() {
        let rig = Rig()
        let snapshot = Self.engineSnapshot(obdKmh: 36)
        let now = ContinuousClock.now
        _ = rig.feed.apply(snapshot, at: now)
        #expect(rig.feed.latest?.noSpeedSource == false, "the count has just started")
        rig.now += 6
        _ = rig.feed.apply(snapshot, at: now + .seconds(1))
        #expect(rig.feed.latest?.noSpeedSource == true)
        #expect(rig.feed.display?.noSpeedSource == true)
        rig.source = true
        _ = rig.feed.apply(snapshot, at: now + .seconds(2))
        #expect(rig.feed.display?.noSpeedSource == false)
    }

    // MARK: How `stationary` reaches the app

    /// A snapshot from a real engine: a first fix, then motion and OBD at `obdKmh` for 3 s.
    static func engineSnapshot(obdKmh: Double) -> NavigationSnapshot {
        var engine = NavigationEngine()
        func t(_ s: Double) -> MonotonicTimestamp { MonotonicTimestamp(seconds: s) }
        engine.ingest(.location(LocationSample(
            latitude: 0, longitude: 0, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1,
            speed: obdKmh / 3.6, speedAccuracy: 0.5, course: 90, courseAccuracy: 5,
            receivedT: t(0), ageS: 0), at: t(0)))
        for k in 1...150 {
            let s = Double(k) / 50
            engine.ingest(.motion(MotionSample(
                userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -1),
                rotationRate: Vector3(x: 0, y: 0, z: 0), attitude: .identity), at: t(s)))
            if k % 10 == 5 {
                engine.ingest(.obd(OBDSample(pid: .vehicleSpeed, value: obdKmh, unit: .kilometersPerHour, ecu: "7E8"), at: t(s)))
            }
        }
        return NavigationSnapshot(t: t(3), sessionID: UUID(), estimate: engine.estimate(at: t(3)), stats: .init())
    }

    @Test("`stationary` comes from the engine's estimate: a fresh OBD 0 freezes it, driving does not")
    func stationaryFromTheEngine() throws {
        let parked = Self.engineSnapshot(obdKmh: 0)
        #expect(try #require(parked.estimate).stationary)
        #expect(try #require(NavDisplay(parked)).stationary)
        let driving = Self.engineSnapshot(obdKmh: 36)
        #expect(try #require(NavDisplay(driving)).stationary == false)
        #expect(NavDisplay(NavigationSnapshot(t: .zero, sessionID: UUID(), estimate: nil, stats: .init())) == nil)
    }

    // MARK: The probe

    @Test("RouteWiring binds the probe to the session: an idle app has no run and no speed source")
    func wiring() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let session = RecordingFixtures.session(store: scratch.store)
        let rig = RouteFlowTests.Rig()
        let feed = NavigationFeed(display: nil)
        #expect(feed.speedProbe == nil)
        RouteWiring.install(flow: rig.flow, on: session, navigation: feed)
        let probe = try #require(feed.speedProbe?())
        #expect(!probe.runActive && !probe.hasSpeedSource)
        #expect(probe.now == session.currentUptimeSeconds || abs(probe.now - session.currentUptimeSeconds) < 5)
        // Idle: no run, so the state stays false whatever the (absent) speed says.
        #expect(feed.stamped(RouteFixtures.nav())?.noSpeedSource == false)
    }

    // MARK: R95.1-1: the driver's GPS switch

    @Test("The probe drops the fix while the driver's GPS switch is off: a fresh valid-speed fix every second is no source, and the state flips after 5 s; switched on, the fix is a source again")
    func probeHonoursTheGPSSwitch() async throws {
        let scratch = try ScratchStore()
        defer { scratch.remove() }
        let location = FakeReferenceFixSource(name: "fakeLocation")
        let rig = NavigateRig(store: scratch.store, extraSources: [location])
        await rig.connect(speed: nil)
        rig.session.enableNavigate(RecordingSessionNavigateTests.quick)
        let session = rig.session
        func fixArrives(at seconds: Double) {
            rig.uptime.set(NavigateRig.base + seconds)
            location.show(location.fix(speed: 14))
        }

        fixArrives(at: 0)
        #expect(RouteInputs.speedProbe(session).hasSpeedSource, "GPS on: the fix is the speed")
        #expect(RouteInputs.speedProbe(session).runActive)

        session.setGPSSwitch(on: false)
        var rule = NoSpeedSourceRule()
        var states: [Bool] = []
        for second in 1...8 {
            fixArrives(at: Double(second))
            #expect(session.latestFix != nil, "the session keeps showing fixes while the switch is off")
            let probe = RouteInputs.speedProbe(session)
            #expect(!probe.hasSpeedSource, "second \(second)")
            states.append(rule.evaluate(probe, hasEstimate: true, stationary: false))
        }
        #expect(states.firstIndex(of: true) == 6, "flips once more than 5 s have passed since the first look: \(states)")
        // Arrival's own speed is not changed: it still reads the fix.
        #expect(RouteInputs.sessionSpeed(session).source == .gps)

        session.setGPSSwitch(on: true)
        fixArrives(at: 9)
        #expect(RouteInputs.speedProbe(session).hasSpeedSource)
        let cleared = rule.evaluate(RouteInputs.speedProbe(session), hasEstimate: true, stationary: false)
        #expect(!cleared, "clears at once")
    }

    // MARK: R95.1-2: guidance's own read path

    @Test("Guidance's read path (`RouteEstimate.source` over `peekEstimate`) carries the state from the probe: the bar gets the reason, no distance or time, and no arrival")
    func peekPathCarriesTheState() async {
        let snapshot = Self.engineSnapshot(obdKmh: 36)   // not stationary
        let rig = Rig()
        let feed = NavigationFeed(display: nil, source: { snapshot })
        feed.speedProbe = { [unowned rig] in
            NoSpeedSourceRule.Probe(now: rig.now, runActive: rig.runActive, hasSpeedSource: rig.source)
        }
        let read = RouteEstimate.source(feed: feed)

        let first = await read()
        #expect(first != nil && first?.noSpeedSource == false, "the count starts at the first look")
        rig.now += 6
        let later = await read()
        #expect(later?.noSpeedSource == true, "past 5 s with no source and not standing")
        #expect(later?.stationary == false)

        // The flow's loop reads it itself, with no map polling.
        let flowRig = RouteFlowTests.Rig()
        await flowRig.toGuiding()
        flowRig.flow.estimateSource = read
        flowRig.flow.fixInputs {
            RouteLiveInputs(origin: RouteOriginInputs(runActive: true, estimate: nil), speedMS: 0)
        }
        for second in 0...12 { await flowRig.flow.loopStep(now: Double(second)) }
        #expect(flowRig.flow.guidance?.status == .uncertain && flowRig.flow.guidance?.noSpeedSource == true)
        #expect(flowRig.flow.guidance?.remainingM == nil && flowRig.flow.guidance?.remainingTimeS == nil)
        #expect(flowRig.flow.phase == .guiding, "no arrival")

        // A source returns: the peek clears the state at once.
        rig.source = true
        #expect(await read()?.noSpeedSource == false)
    }
}
