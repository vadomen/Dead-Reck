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
}
