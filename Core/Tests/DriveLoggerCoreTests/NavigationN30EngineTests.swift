import Foundation
import Testing

@testable import DriveLoggerCore

/// N3.0 engine fixes (docs/N3_PLAN.md, "N3.0", engine-fix table). Each test
/// was run against the code before its fix and failed there.
@Suite("Navigation N3.0 engine fixes")
struct NavigationN30EngineTests {
    typealias S = SyntheticDrive
    typealias H = NavigationHeldFixTests

    /// A GNSS fix at plane (east, north) with time `t`, arriving at
    /// `arrival`, reporting `speed` m/s and `course`°.
    static func gnss(_ t: Double, arrival: Double? = nil, east: Double = 0, north: Double = 0, accuracy: Double = 10,
                     speed: Double, course: Double) -> NavigationInput {
        let p = S.plane.geodetic(east: east, north: north)
        let arrival = arrival ?? t + 0.05
        return .location(LocationSample(latitude: p.latitude, longitude: p.longitude, altitude: 0,
                                        horizontalAccuracy: accuracy, verticalAccuracy: -1,
                                        speed: speed, speedAccuracy: 0.5, course: course, courseAccuracy: 5,
                                        receivedT: S.ms(arrival), ageS: arrival - t),
                         at: S.ms(t))
    }

    /// A tower fix (no speed: a network fix) at plane (east, north).
    static func tower(_ t: Double, east: Double = 0, north: Double = 0, accuracy: Double = 300) -> NavigationInput {
        let p = S.plane.geodetic(east: east, north: north)
        return .location(LocationSample(latitude: p.latitude, longitude: p.longitude, altitude: 0,
                                        horizontalAccuracy: accuracy, verticalAccuracy: -1,
                                        speed: -1, speedAccuracy: -1, course: -1, courseAccuracy: -1,
                                        receivedT: S.ms(t + 0.05), ageS: 0.05),
                         at: S.ms(t))
    }

    /// Motion samples at 100 Hz from `from` to `to` (still, no yaw).
    static func still(_ from: Double, _ to: Double) -> [NavigationInput] {
        stride(from: from, through: to, by: 0.01).map { H.motion($0) }
    }

    /// Inputs sorted by arrival, ties in the given order.
    static func ordered(_ inputs: [NavigationInput]) -> [NavigationInput] {
        inputs.enumerated()
            .sorted { $0.element.arrival != $1.element.arrival ? $0.element.arrival < $1.element.arrival : $0.offset < $1.offset }
            .map(\.element)
    }

    // MARK: R11.1-4 course gate needs a known OBD speed

    @Test("R11.1-4: parked before the adapter connects (no OBD), a 10 m fix with 3.5 m/s speed noise does not set the heading")
    func noOBDAtInitialisationVetoesCourse() throws {
        let inputs = Self.ordered(Self.still(0, 3) + [Self.gnss(1, speed: 3.5, course: 90)])
        let engine = H.engine(inputs, config: S.config(particles: 400))
        let estimate = try #require(engine.estimate(at: S.ms(3)))
        #expect(engine.counters.courseUpdates == 0)
        // Uniform over the circle: a large circular std, not N(90°, 5°).
        #expect(estimate.headingStdDeg > 60, "heading std \(estimate.headingStdDeg)° from a parked course")
    }

    @Test("R11.1-4: parked with OBD gone stale at 0, a clean fix with speed noise neither reseeds nor updates the course")
    func staleZeroVetoesCourse() throws {
        // OBD 0 at 0.05–2.05 s, then the link drops: stale 0, parked latch
        // armed. Initialised by a tower fix (headings uniform), then a 10 m
        // fix at 8 s reporting 3.5 m/s and a course.
        let obd = stride(from: 0.05, through: 2.05, by: 0.1).map { H.obd(0, $0) }
        let inputs = Self.ordered(Self.still(0, 10) + obd + [Self.tower(0.5), Self.gnss(8, speed: 3.5, course: 90)])
        let engine = H.engine(inputs, config: S.config(particles: 400))
        let estimate = try #require(engine.estimate(at: S.ms(10)))
        #expect(engine.counters.staleParkedSteps > 50)
        #expect(engine.counters.reseeds == 0 && engine.counters.courseUpdates == 0,
                "reseeds \(engine.counters.reseeds), course updates \(engine.counters.courseUpdates)")
        #expect(estimate.headingStdDeg > 60, "heading std \(estimate.headingStdDeg)°")
    }

    @Test("R11.1-4: a dropout while driving (stale OBD holding 15 m/s) still lets a clean course through")
    func staleMovingStillUsesCourse() throws {
        // 15 m/s east; OBD stops after 5 s; clean fixes at 10–12 s.
        let drive = S(initialHeadingDeg: 90, initialSpeed: 15, [.straight(seconds: 14, speed: 15)])
        let events = drive.events(obdSpeed: { t, state in t < 5 ? (state.speed * 3.6).rounded(.down) : nil },
                                  fix: { t, state, rng in
                                      t == 0 || t >= 10 ? S.cleanFix(accuracy: 5, positionNoise: 0)(t, state, &rng) : nil
                                  })
        let (engine, samples) = S.run(events, config: S.config(particles: 400), sampleTimes: [13])
        let estimate = try #require(samples.first ?? nil)
        #expect(engine.counters.staleSpeedSteps > 0)
        #expect(engine.counters.courseUpdates >= 4, "course updates \(engine.counters.courseUpdates)")
        #expect(abs(angleDifference(estimate.headingDeg, 90)) < 3)
    }
}
