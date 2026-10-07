import Foundation
import Testing

@testable import DriveLoggerCore

/// Drains a sink the way the writer would, for tests that use a bare sink.
func drain(_ sink: LogSink) async -> [LogEvent] {
    sink.finish()
    var events: [LogEvent] = []
    for await event in sink.events {
        events.append(event)
        sink.noteConsumed()
    }
    return events
}

@Suite("Simulated motion")
@MainActor
struct SimulatedMotionSourceTests {
    @Test("Delivers motion, accel and gyro per tick, exactly 1/rate apart from start")
    func deliversAtRate() async throws {
        let clock = SessionClock()
        let sink = LogSink()
        let source = SimulatedMotionSource(rateHz: 100)
        let startT = clock.now()
        try source.start(clock: clock, sink: sink)
        try await Task.sleep(for: .milliseconds(200))
        source.stop()

        let events = await drain(sink)
        #expect(events.count >= 6)  // at least two instants, even on a loaded machine
        #expect(events.count % 3 == 0)
        let kinds = events.map(\.payload.kind)
        for (index, kind) in kinds.enumerated() {
            #expect(kind == ["motion", "accel", "gyro"][index % 3])
        }
        let motion = events.filter { $0.payload.kind == "motion" }.map(\.timestamp.nanoseconds)
        #expect(motion.first! >= startT.nanoseconds)
        #expect(motion.first! - startT.nanoseconds < 50_000_000)
        for (earlier, later) in zip(motion, motion.dropFirst()) {
            #expect(later - earlier == 10_000_000)
        }
        // Every sample of one instant shares its timestamp.
        for index in stride(from: 0, to: events.count, by: 3) {
            #expect(events[index].timestamp == events[index + 1].timestamp)
            #expect(events[index].timestamp == events[index + 2].timestamp)
        }
        // Nothing is stamped in the future.
        #expect(motion.last! <= clock.now().nanoseconds)
    }

    @Test("Deterministic: the nth sample's values depend only on n and the rate")
    func deterministic() async throws {
        var runs: [[LogEvent.Payload]] = []
        for _ in 0..<2 {
            let sink = LogSink()
            let source = SimulatedMotionSource(rateHz: 200)
            try source.start(clock: SessionClock(), sink: sink)
            try await Task.sleep(for: .milliseconds(80))
            source.stop()
            runs.append(await drain(sink).map(\.payload))
        }
        let common = min(runs[0].count, runs[1].count)
        #expect(common >= 6)
        #expect(Array(runs[0].prefix(common)) == Array(runs[1].prefix(common)))
        #expect(runs[0].first == SimulatedMotionModel.payloads(index: 0, rateHz: 200).first)
    }

    @Test("Plausible car in a mount: 1 g gravity, a gentle turn, raw accel = gravity + user accel")
    func plausible() {
        for index in [0, 137, 10_000] {
            let payloads = SimulatedMotionModel.payloads(index: index, rateHz: 100)
            guard case .motion(let motion) = payloads[0],
                  case .accelerometer(let accel) = payloads[1],
                  case .gyroscope(let gyro) = payloads[2]
            else {
                Issue.record("unexpected payloads \(payloads)")
                return
            }
            #expect(abs(motion.gravity.magnitude - 1) < 1e-9)
            #expect(abs(accel.x - (motion.gravity.x + motion.userAcceleration.x)) < 1e-12)
            #expect(abs(accel.y - (motion.gravity.y + motion.userAcceleration.y)) < 1e-12)
            #expect(abs(accel.z - (motion.gravity.z + motion.userAcceleration.z)) < 1e-12)
            #expect(gyro != motion.rotationRate)  // raw gyro carries a bias
            let q = motion.attitude
            #expect(abs((q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w) - 1) < 1e-9)
        }
    }

    @Test("stop() is idempotent, and nothing arrives after it returns")
    func stopIsFinal() async throws {
        let sink = LogSink()
        let source = SimulatedMotionSource(rateHz: 100)
        source.stop()  // before start: harmless
        try source.start(clock: SessionClock(), sink: sink)
        try await Task.sleep(for: .milliseconds(50))
        source.stop()
        let countAtStop = sink.totalEnqueued
        source.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(sink.totalEnqueued == countAtStop)
        #expect(countAtStop > 0)
    }

    @Test("Starting again restarts cleanly from the new clock")
    func restart() async throws {
        let sink = LogSink()
        let source = SimulatedMotionSource(rateHz: 100)
        try source.start(clock: SessionClock(), sink: sink)
        try await Task.sleep(for: .milliseconds(30))
        try source.start(clock: SessionClock(), sink: sink)
        try await Task.sleep(for: .milliseconds(30))
        source.stop()
        let count = sink.totalEnqueued
        try await Task.sleep(for: .milliseconds(60))
        #expect(sink.totalEnqueued == count)
    }

    @Test("Name and availability")
    func identity() {
        let source = SimulatedMotionSource()
        #expect(source.name == "simulatedMotion")
        #expect(source.availability == .available)
        #expect(source.rateHz == 100)
    }
}

@Suite("Simulated location")
@MainActor
struct SimulatedLocationSourceTests {
    @Test("Fixes are flagged simulated, stamped on the session clock, with receivedT = t")
    func flaggedAndStamped() async throws {
        let clock = SessionClock()
        let sink = LogSink()
        let source = SimulatedLocationSource(interval: .milliseconds(20))
        try source.start(clock: clock, sink: sink)
        try await Task.sleep(for: .milliseconds(150))
        source.stop()

        let events = await drain(sink)
        #expect(events.count >= 2)
        for event in events {
            guard case .location(let fix) = event.payload else {
                Issue.record("expected location, got \(event.payload.kind)")
                continue
            }
            #expect(fix.simulated == true)
            #expect(fix.receivedT == event.timestamp)
            #expect(fix.ageS == 0)
            #expect(fix.hasValidPosition && fix.hasValidSpeed && fix.hasValidCourse)
            #expect(fix.fixTime != nil)
        }
        let times = events.map(\.timestamp.nanoseconds)
        for (earlier, later) in zip(times, times.dropFirst()) {
            #expect(later - earlier == 20_000_000)
        }
    }

    @Test("The loop is deterministic and moves at a constant speed along a circle")
    func loop() {
        let a = SimulatedLocationModel.fix(index: 0, intervalS: 1)
        let b = SimulatedLocationModel.fix(index: 1, intervalS: 1)
        #expect(a == SimulatedLocationModel.fix(index: 0, intervalS: 1))
        // One second at the model speed, as a chord of the circle.
        let dLat = (b.latitude - a.latitude) * 111_320
        let dLon = (b.longitude - a.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        let distance = (dLat * dLat + dLon * dLon).squareRoot()
        #expect(abs(distance - SimulatedLocationModel.speed) < 0.1)
        #expect((0..<360).contains(a.course))
    }

    @Test("stop() is idempotent, and nothing arrives after it returns")
    func stopIsFinal() async throws {
        let sink = LogSink()
        let source = SimulatedLocationSource(interval: .milliseconds(10))
        source.stop()
        try source.start(clock: SessionClock(), sink: sink)
        try await Task.sleep(for: .milliseconds(50))
        source.stop()
        let count = sink.totalEnqueued
        source.stop()
        try await Task.sleep(for: .milliseconds(60))
        #expect(sink.totalEnqueued == count)
        #expect(count > 0)
    }

    @Test("Default is 1 Hz")
    func defaults() {
        let source = SimulatedLocationSource()
        #expect(source.interval == .seconds(1))
        #expect(source.name == "simulatedLocation")
    }
}
