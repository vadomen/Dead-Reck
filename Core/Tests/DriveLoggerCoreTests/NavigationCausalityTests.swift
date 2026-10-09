import Foundation
import Testing

@testable import DriveLoggerCore

/// The engine never sees the future: its belief at T depends only on inputs
/// that arrived by T.
@Suite("Navigation causality")
struct NavigationCausalityTests {
    typealias S = SyntheticDrive

    static let drive = S(initialHeadingDeg: 120, initialSpeed: 9, [
        .straight(seconds: 15, speed: 9), .turn(degrees: -70, seconds: 5, speed: 8), .ramp(seconds: 4, from: 8, to: 0),
        .stop(seconds: 6), .ramp(seconds: 4, from: 0, to: 12), .straight(seconds: 20, speed: 12),
    ])

    /// A mix of everything: gyro noise, clean fixes with latency, tower
    /// fixes, an OBD dropout and a manual fix.
    static func events() -> [LogEvent] {
        let pin = drive.truth(at: 30)
        let p = S.plane.geodetic(east: pin.east + 20, north: pin.north - 10)
        let manual = LogEvent(timestamp: S.ms(30), payload: .manualFix(ManualFixSample(
            latitude: p.latitude, longitude: p.longitude, pressedT: S.ms(28), speedSource: "obd")))
        let clean = S.cleanFix(accuracy: 8, positionNoise: 3)
        return drive.events(
            gyroNoise: 0.01,
            obdSpeed: { t, state in (40...43).contains(t) ? nil : (state.speed * 3.6).rounded(.down) },
            fix: { t, state, rng in
                if t < 10 { return clean(t, state, &rng) }
                if Int(t.rounded()) % 5 == 0 {
                    return S.Fix(east: state.east + 300, north: state.north - 200, accuracy: 1414, latency: 0.4)
                }
                return nil
            },
            extra: [manual]
        )
    }

    static let cuts: [Double] = [0.04, 3.333, 9.95, 17.5, 26.02, 30.0, 41.7, 50.0]

    @Test("For every cut T, an engine fed only the prefix up to T estimates exactly what the full run did at T")
    func prefixEqualsFullRun() throws {
        let events = Self.events()
        let config = S.config(particles: 300, seed: 11)
        let full = S.run(events, config: config, sampleTimes: Self.cuts).samples
        for (cut, sampled) in zip(Self.cuts, full) {
            let prefix = events.filter { NavigationInput($0)!.arrival <= S.ms(cut) }
            var engine = NavigationEngine(config: config)
            for input in S.inputs(prefix) { engine.ingest(input) }
            #expect(engine.estimate(at: S.ms(cut)) == sampled, "cut \(cut)")
        }
    }

    @Test("Rewriting every input after T with garbage leaves every estimate at or before T unchanged")
    func futureGarbageIsInvisible() throws {
        let events = Self.events()
        let config = S.config(particles: 300, seed: 5)
        let times = stride(from: 0.5, through: 55, by: 0.5).map { $0 }
        let reference = S.run(events, config: config, sampleTimes: times).samples
        var rng = NavigationRandom(seed: 99)
        for cut in [5.0, 22.2, 35.0] {
            let garbage: [LogEvent] = events.map { event in
                let input = NavigationInput(event)!
                guard input.arrival > S.ms(cut) else { return event }
                let t = event.timestamp
                switch event.payload {
                case .motion:
                    return .motion(MotionSample(userAcceleration: .zero,
                                                gravity: Vector3(x: rng.nextGaussian(), y: rng.nextGaussian(), z: -1),
                                                rotationRate: Vector3(x: 0, y: 3 * rng.nextGaussian(), z: 5 * rng.nextGaussian()),
                                                attitude: .identity), at: t)
                case .obd:
                    return .obd(OBDSample(pid: .vehicleSpeed, value: (200 * rng.nextUniform()).rounded(),
                                          unit: .kilometersPerHour, ecu: "7E8"), at: t)
                case .location(let sample):
                    var s = sample
                    s.latitude += rng.nextGaussian() * 0.1
                    s.longitude += rng.nextGaussian() * 0.1
                    s.course = 360 * rng.nextUniform()
                    s.courseAccuracy = 1
                    return .location(s, at: t)
                case .manualFix(var sample):
                    sample.latitude += 0.05
                    return LogEvent(timestamp: t, payload: .manualFix(sample))
                default:
                    return event
                }
            }
            let rewritten = S.run(garbage, config: config, sampleTimes: times).samples
            for (index, t) in times.enumerated() where t <= cut {
                #expect(rewritten[index] == reference[index], "cut \(cut), t \(t)")
            }
            let after = times.indices.filter { times[$0] > cut + 2 }
            #expect(after.contains { rewritten[$0] != reference[$0] }, "garbage after \(cut) changed nothing — test is vacuous")
        }
    }
}

@Suite("Navigation performance")
struct NavigationPerformanceTests {
    @Test("Smoke: 2000 particles × 600 steps with fixes stays far from pathological (debug build)")
    func perfSmoke() throws {
        let drive = SyntheticDrive(initialHeadingDeg: 0, initialSpeed: 15, [
            .straight(seconds: 30, speed: 15), .turn(degrees: 120, seconds: 10, speed: 12), .straight(seconds: 20, speed: 15),
        ])
        let events = drive.events(gyroNoise: 0.01, fix: SyntheticDrive.cleanFix(accuracy: 20, positionNoise: 8))
        let inputs = SyntheticDrive.inputs(events)
        var engine = NavigationEngine(config: SyntheticDrive.config(particles: 2000))
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for input in inputs { engine.ingest(input) }
        }
        let steps = engine.counters.steps
        #expect(steps >= 590)
        let msPerStep = Double(elapsed.components.attoseconds) / 1e15 / Double(steps)
            + Double(elapsed.components.seconds) * 1000 / Double(steps)
        // Generous: the real budget (≤ 2 ms on an iPhone) is checked on the
        // release replay and on the device.
        #expect(msPerStep < 40, "\(msPerStep) ms/step")
    }
}
