import Foundation
import Testing

@testable import DriveLoggerCore

/// N4-B1 (backlog N4B-1): a stale fix that arrives before OBD can say
/// whether the car is stopped is held, and the first fresh OBD reply
/// decides. Live, the pre-session fix is written before the first OBD 0
/// (its row lands up to 0.27 s after its own `t`); before N4-B1 the engine
/// dropped it there, while an arrival-order replay used it.
@Suite("Navigation N4 B1: held stale fix")
struct NavigationHeldFixTests {
    typealias S = SyntheticDrive

    /// √χ²₉₅: the 95 % semi-axis of a circular σ.
    static let k95 = ErrorEllipse.chiSquare95.squareRoot()
    /// σ of a 30 m fix at face value.
    static let base = 30 / 1.51

    /// A 30 m GNSS-like fix at plane (east, 0), fix time `t`, arriving at
    /// `arrival` (speed 0 so it is not a network fix).
    static func fix(_ t: Double, arrival: Double, east: Double = 0) -> NavigationInput {
        let p = S.plane.geodetic(east: east, north: 0)
        return .location(LocationSample(latitude: p.latitude, longitude: p.longitude, altitude: 0,
                                        horizontalAccuracy: 30, verticalAccuracy: -1, speed: 0, speedAccuracy: 0.5,
                                        course: -1, courseAccuracy: -1, receivedT: S.ms(arrival), ageS: arrival - t),
                         at: S.ms(t))
    }

    static func obd(_ kmh: Double, _ t: Double) -> NavigationInput {
        .obd(OBDSample(pid: .vehicleSpeed, value: kmh, unit: .kilometersPerHour, ecu: "7E8"), at: S.ms(t))
    }

    static func motion(_ t: Double) -> NavigationInput {
        .motion(MotionSample(userAcceleration: .zero, gravity: Vector3(x: 0, y: 0, z: -1),
                             rotationRate: .zero, attitude: .identity), at: S.ms(t))
    }

    static func engine(_ inputs: [NavigationInput], config: NavigationConfig = S.config(particles: 50)) -> NavigationEngine {
        var engine = NavigationEngine(config: config)
        for input in inputs { engine.ingest(input) }
        return engine
    }

    /// The pre-session case as the live tap delivers it: a 60 s old fix
    /// arriving 0.06 s into the session, then motion samples written in
    /// between, then the first OBD 0 whose own `t` (0.015 s) is earlier.
    static let liveOrder: [NavigationInput] = [motion(0.01), fix(-60, arrival: 0.06), motion(0.07), motion(0.08),
                                               obd(0, 0.015), motion(0.09)]
    /// The same inputs in arrival order: the OBD 0 first.
    static let arrivalOrder: [NavigationInput] = [motion(0.01), obd(0, 0.015), fix(-60, arrival: 0.06),
                                                  motion(0.07), motion(0.08), motion(0.09)]

    @Test("A stale pre-session fix fed before the first OBD 0 is used, exactly as in arrival order")
    func staleFixBeforeFirstZeroIsUsed() throws {
        let live = Self.engine(Self.liveOrder)
        #expect(live.isInitialized, "the held fix must be applied once OBD says 0")
        #expect(live.counters.fixesUsed == 1 && live.counters.fixesIgnoredStale == 0)
        #expect(live.counters.fixesHeld == 1 && live.counters.heldFixesUsed == 1 && !live.hasHeldFix)

        let replay = Self.engine(Self.arrivalOrder)
        #expect(replay.counters.fixesHeld == 0, "arrival order sees the stop first: nothing to hold")
        let a = try #require(live.estimate(at: S.ms(0.09)))
        let b = try #require(replay.estimate(at: S.ms(0.09)))
        #expect(a == b, "file order and arrival order must give the same estimate")
        // Same age (60.06 s at its own arrival), same stale σ.
        #expect(abs(a.ellipse.semiMajorM / Self.k95 - (Self.base + 60.06)) < 1e-6)
        #expect(a.stationary)
    }

    @Test("The same stale fix before a moving OBD reply is dropped and counted")
    func staleFixBeforeMovingReplyIsDropped() {
        let engine = Self.engine([Self.fix(-60, arrival: 0.06), Self.motion(0.07), Self.obd(30, 0.015),
                                  Self.motion(0.2), Self.obd(0, 0.3), Self.motion(0.4)])
        #expect(!engine.isInitialized, "moving at the fix's arrival: the stale fix must not be used")
        #expect(engine.counters.fixesHeld == 1 && engine.counters.heldFixesDroppedMoving == 1)
        #expect(engine.counters.fixesIgnoredStale == 1 && engine.counters.fixesUsed == 0 && !engine.hasHeldFix)
    }

    @Test("No deciding OBD reply within heldFixTimeoutS: the held fix is dropped; within it, used with the wait in its age")
    func timeout() throws {
        var inputs: [NavigationInput] = [Self.fix(-60, arrival: 0.06)]
        inputs += stride(from: 0.1, through: 5.2, by: 0.1).map(Self.motion)
        inputs.append(Self.obd(0, 5.25))
        let late = Self.engine(inputs)
        #expect(!late.isInitialized)
        #expect(late.counters.heldFixesDroppedTimeout == 1 && late.counters.fixesIgnoredStale == 1)
        #expect(late.counters.heldFixesUsed == 0 && !late.hasHeldFix)

        // A reply 3 s after the arrival decides: the fix counts as arriving
        // with it, so its age is 63 s, not 60.06 s.
        var inTime: [NavigationInput] = [Self.fix(-60, arrival: 0.06)]
        inTime += stride(from: 0.1, through: 2.9, by: 0.1).map(Self.motion)
        inTime.append(Self.obd(0, 3.0))
        let used = Self.engine(inTime)
        #expect(used.counters.heldFixesUsed == 1 && used.counters.heldFixesDroppedTimeout == 0)
        let estimate = try #require(used.estimate(at: S.ms(3.0)))
        #expect(abs(estimate.ellipse.semiMajorM / Self.k95 - (Self.base + 63)) < 1e-6)

        // The limit itself: a reply exactly heldFixTimeoutS after the arrival
        // still decides.
        var config = S.config(particles: 50)
        config.heldFixTimeoutS = 2
        let edge = Self.engine([Self.fix(-60, arrival: 1.0), Self.motion(2.9), Self.obd(0, 3.0)], config: config)
        #expect(edge.counters.heldFixesUsed == 1)
    }

    @Test("heldFixTimeoutS 0 restores the drop on arrival")
    func holdingOff() {
        var config = S.config(particles: 50)
        config.heldFixTimeoutS = 0
        let engine = Self.engine(Self.liveOrder, config: config)
        #expect(!engine.isInitialized)
        #expect(engine.counters.fixesIgnoredStale == 1 && engine.counters.fixesHeld == 0)
        #expect(NavigationConfig().heldFixTimeoutS == 5)
    }

    @Test("One fix is held, the newest by fix time; a reply older than obdMaxAgeS before the arrival does not decide")
    func newestWinsAndOldReplyDoesNotDecide() throws {
        // Newer second: replaces the first. Older second: dropped.
        for (second, keptEast) in [(-30.0, 100.0), (-90.0, 0.0)] {
            let engine = Self.engine([Self.fix(-60, arrival: 0.05, east: 0), Self.fix(second, arrival: 0.06, east: 100),
                                      Self.obd(0, 0.02), Self.motion(0.1)])
            #expect(engine.counters.fixesHeld == (second > -60 ? 2 : 1))
            #expect(engine.counters.heldFixesReplaced == 1 && engine.counters.heldFixesUsed == 1)
            #expect(engine.counters.fixesUsed == 1 && engine.counters.fixesIgnoredStale == 1)
            let estimate = try #require(engine.estimate(at: S.ms(0.1)))
            // The plane is anchored at the fix that initialised it.
            let kept = S.plane.geodetic(east: keptEast, north: 0)
            #expect(abs(estimate.longitude - kept.longitude) < 1e-9 && estimate.east == 0, "second fix at \(second) s")
        }

        // A reply 2.5 s older than the arrival was already stale there: it
        // does not decide; the next fresh one does.
        let engine = Self.engine([Self.fix(-60, arrival: 3.0), Self.obd(30, 0.5), Self.motion(3.1), Self.obd(0, 3.2)])
        #expect(engine.counters.heldFixesDroppedMoving == 0 && engine.counters.heldFixesUsed == 1)
    }

    @Test("Mid-drive OBD dropout: a stale fix is held and dropped by the moving reply that ends the dropout")
    func dropoutWhileMoving() throws {
        let drive = S([.straight(seconds: 20, speed: 10), .straight(seconds: 10, speed: 10)])
        var events = drive.events(
            obdSpeed: { t, state in t > 15 && t < 18 ? nil : (state.speed * 3.6).rounded(.down) },
            fix: { t, state, rng in t <= 10 ? S.cleanFix()(t, state, &rng) : nil }
        )
        // At 17.5 s (OBD silent since 15 s), a fix 20 s old.
        let p = S.plane.geodetic(east: 0, north: 0)
        events.append(.location(LocationSample(latitude: p.latitude, longitude: p.longitude, altitude: 0,
                                               horizontalAccuracy: 30, verticalAccuracy: -1, speed: 0, speedAccuracy: 0.5,
                                               course: -1, courseAccuracy: -1, receivedT: S.ms(17.5), ageS: 20),
                                at: S.ms(-2.5)))
        let (engine, _) = S.run(events, config: S.config(particles: 200))
        #expect(engine.counters.fixesHeld == 1 && engine.counters.heldFixesDroppedMoving == 1)
        #expect(engine.counters.heldFixesUsed == 0 && engine.counters.fixesIgnoredStale == 1)
        let estimate = try #require(engine.estimate(at: S.ms(30)))
        #expect(abs(estimate.north - drive.truth(at: 30).north) < 30)
    }

    @Test("Counters from an earlier build without the held-fix keys still decode (as 0)")
    func countersDecodeWithoutNewKeys() throws {
        let old = #"{"steps":12,"fixesUsed":3,"fixesIgnoredStale":1,"inputsRejectedTimeJump":0}"#
        let counters = try JSONDecoder().decode(NavigationCounters.self, from: Data(old.utf8))
        #expect(counters.steps == 12 && counters.fixesUsed == 3 && counters.fixesIgnoredStale == 1)
        #expect(counters.fixesHeld == 0 && counters.heldFixesUsed == 0)
        var full = NavigationCounters()
        full.heldFixesDroppedTimeout = 2
        full.macroSteps = 5
        let roundTrip = try JSONDecoder().decode(NavigationCounters.self, from: JSONEncoder().encode(full))
        #expect(roundTrip == full)
    }
}
