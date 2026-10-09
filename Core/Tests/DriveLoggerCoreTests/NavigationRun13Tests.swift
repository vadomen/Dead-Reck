import Foundation
import Testing

@testable import DriveLoggerCore

/// Review run 13, round 1: regression and discriminating tests (R13.1-1..4).
@Suite("Navigation review run 13")
struct NavigationRun13Tests {
    typealias S = SyntheticDrive

    static func pin(at t: Double, east: Double, north: Double, span: Double? = nil) -> LogEvent {
        let p = S.plane.geodetic(east: east, north: north)
        return LogEvent(timestamp: S.ms(t), payload: .manualFix(ManualFixSample(
            latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(t - 2), mapSpanM: span, speedSource: "obd")))
    }

    // MARK: R13.1-1

    @Test("R13.1-1: heading unknown, 3 km straight, a pin at the truth fixes the heading (no reset discarding it)")
    func pinAfterRingKeepsHeadingInformation() throws {
        // Initialised by a pin (heading uniform), 200 s at 15 m/s on a 70°
        // bearing, then parked; a second pin at the true position.
        let drive = S(initialHeadingDeg: 70, initialSpeed: 15, [.straight(seconds: 200, speed: 15), .stop(seconds: 10)])
        let end = drive.truth(at: 205)
        let events = drive.events(extra: [Self.pin(at: 0.005, east: 0, north: 0), Self.pin(at: 205.005, east: end.east, north: end.north)])
        let (engine, samples) = S.run(events, config: S.config(particles: 2000, seed: 3), sampleTimes: [204, 206])
        let before = try #require(samples[0]), after = try #require(samples[1])
        #expect(before.headingStdDeg > 60, "the cloud should be a ring before the pin (σ \(before.headingStdDeg)°)")
        #expect(after.headingStdDeg < 5, "heading σ after the pin \(after.headingStdDeg)°")
        #expect(abs(angleDifference(after.headingDeg, 70)) < 5, "heading \(after.headingDeg)°")
        #expect(drive.error(after, at: 206) < 30)
        #expect(engine.counters.manualResets == 0)
    }

    // MARK: R13.1-2

    /// Drives 20 s, stops with a fresh OBD 0 at about 24 s, then OBD falls
    /// silent at 30 s while the car stays parked for `silentS` seconds. IMU
    /// noise stands in for an idling engine or a hand near the phone.
    static func parkedSilence(silentS: Double, accelNoise: Double) throws -> (atStop: NavigationEstimate, end: NavigationEstimate) {
        let drive = S(initialHeadingDeg: 30, initialSpeed: 10, [
            .straight(seconds: 20, speed: 10), .ramp(seconds: 4, from: 10, to: 0), .stop(seconds: 6 + silentS),
        ])
        let clean = S.cleanFix()
        let events = drive.events(gyroNoise: 0.02, accelNoise: accelNoise,
                                  obdSpeed: { t, state in t >= 30 ? nil : (state.speed * 3.6).rounded(.down) },
                                  fix: { t, state, rng in t < 20 ? clean(t, state, &rng) : nil })
        let samples = S.run(events, config: S.config(particles: 400), sampleTimes: [29.9, 30 + silentS]).samples
        return (try #require(samples[0]), try #require(samples[1]))
    }

    @Test("R13.1-2: 5 min of OBD silence after a fresh stop, no motion: the ellipse stays put (parked until motion shows)")
    func parkedSilenceStaysBounded() throws {
        let (atStop, end) = try Self.parkedSilence(silentS: 300, accelNoise: 0.03)
        let growth = end.ellipse.semiMajorM - atStop.ellipse.semiMajorM
        #expect(growth < 100, "semi-major grew \(growth) m in 5 min parked (\(atStop.ellipse.semiMajorM) → \(end.ellipse.semiMajorM) m)")
        #expect(end.stationary)
        #expect(abs(end.east - atStop.east) < 1 && abs(end.north - atStop.north) < 1)
    }

    @Test("R13.1-2: OBD lost while driving: the speed error is mean-reverting, so the ellipse grows diffusively, not as t^1.5")
    func staleWhileMovingGrowsDiffusively() throws {
        let drive = S(initialHeadingDeg: 0, initialSpeed: 12, [.straight(seconds: 640, speed: 12)])
        let clean = S.cleanFix()
        let events = drive.events(obdSpeed: { t, state in t >= 20 ? nil : (state.speed * 3.6).rounded(.down) },
                                  fix: { t, state, rng in t < 15 ? clean(t, state, &rng) : nil })
        let samples = S.run(events, config: S.config(particles: 400), sampleTimes: [20, 320, 620]).samples
        let start = try #require(samples[0]).ellipse.semiMajorM
        let five = try #require(samples[1]).ellipse.semiMajorM - start
        let ten = try #require(samples[2]).ellipse.semiMajorM - start
        // Unbounded random walk: σ ∝ t^1.5, so doubling the time grows it
        // 2.8×; bounded speed error: about √2 = 1.4×.
        #expect(ten / five < 2, "5 min: \(five) m, 10 min: \(ten) m (ratio \(ten / five))")
        #expect(five < 3_000, "5 min of silence while driving: \(five) m")
    }
}
