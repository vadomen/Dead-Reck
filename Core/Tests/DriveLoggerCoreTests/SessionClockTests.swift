import Foundation
import Testing

@testable import DriveLoggerCore

@Suite("SessionClock")
struct SessionClockTests {
    @Test("Reference uptime is captured at construction")
    func capturesReference() {
        let clock = SessionClock(source: FixedUptimeSource(uptimeSeconds: 4_321.5))
        #expect(clock.referenceUptimeSeconds == 4_321.5)
        // A sample stamped at the reference instant sits at offset zero.
        #expect(clock.now() == .zero)
    }

    @Test("Sensor uptimes become offsets from the reference")
    func convertsSensorUptime() {
        let clock = SessionClock(source: FixedUptimeSource(uptimeSeconds: 1_000))
        #expect(clock.timestamp(uptimeSeconds: 1_000.25).nanoseconds == 250_000_000)
        #expect(clock.timestamp(uptimeSeconds: 1_002).seconds == 2)
    }

    @Test("Samples buffered before the session started keep a negative offset")
    func allowsNegativeOffsets() {
        // CoreMotion can deliver a batch whose first sample predates the call
        // that started the session. Clamping it to zero would collapse two
        // distinct samples onto one timestamp.
        let clock = SessionClock(source: FixedUptimeSource(uptimeSeconds: 500))
        #expect(clock.timestamp(uptimeSeconds: 499.9).nanoseconds == -100_000_000)
    }

    @Test("now() reads the live source, not the reference")
    func nowAdvances() {
        let clock = SessionClock(
            referenceUptimeSeconds: 100,
            wallClockStart: Date(timeIntervalSince1970: 0),
            source: FixedUptimeSource(uptimeSeconds: 101.5)
        )
        #expect(clock.now().seconds == 1.5)
    }

    @Test("Timestamps from different streams are directly comparable")
    func streamsShareOneTimeBase() {
        // The whole point of the single-clock invariant: an OBD reply stamped
        // via now() and a motion sample stamped from its own uptime must be
        // orderable against each other with no conversion.
        let clock = SessionClock(
            referenceUptimeSeconds: 2_000,
            wallClockStart: Date(timeIntervalSince1970: 0),
            source: FixedUptimeSource(uptimeSeconds: 2_003)
        )
        let obd = clock.now()
        let motion = clock.timestamp(uptimeSeconds: 2_002.5)
        #expect(motion < obd)
        #expect(motion.interval(to: obd) == 0.5)
    }

    @Test("Wall clock is derived from the single start instant")
    func derivesWallClock() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = SessionClock(
            referenceUptimeSeconds: 10,
            wallClockStart: start,
            source: FixedUptimeSource(uptimeSeconds: 10)
        )
        let resolved = clock.wallClock(for: MonotonicTimestamp(seconds: 90))
        #expect(resolved.timeIntervalSince1970 == 1_700_000_090)
    }

    @Test("A clock rebuilt from a header resolves timestamps identically")
    func roundTripsThroughHeader() {
        let original = SessionClock(
            referenceUptimeSeconds: 777.25,
            wallClockStart: Date(timeIntervalSince1970: 1_600_000_000),
            source: FixedUptimeSource(uptimeSeconds: 777.25)
        )
        let header = LogHeader(
            clock: original,
            app: AppIdentity(name: "DriveLogger", version: "0.1.0", build: "1"),
            device: DeviceIdentity(model: "iPhone15,2", systemName: "iOS", systemVersion: "17.4")
        )
        let replayed = SessionClock(header: header)

        #expect(replayed.referenceUptimeSeconds == original.referenceUptimeSeconds)
        #expect(replayed.wallClockStart == original.wallClockStart)
        #expect(
            replayed.timestamp(uptimeSeconds: 800) == original.timestamp(uptimeSeconds: 800)
        )
    }
}

@Suite("MonotonicTimestamp")
struct MonotonicTimestampTests {
    @Test("Seconds and nanoseconds convert both ways")
    func convertsUnits() {
        #expect(MonotonicTimestamp(seconds: 1.5).nanoseconds == 1_500_000_000)
        #expect(MonotonicTimestamp(nanoseconds: 2_500_000_000).seconds == 2.5)
    }

    @Test("Encodes as a bare integer to keep log lines compact")
    func encodesAsScalar() throws {
        let data = try JSONEncoder().encode(MonotonicTimestamp(nanoseconds: 123_456))
        #expect(String(decoding: data, as: UTF8.self) == "123456")

        let decoded = try JSONDecoder().decode(MonotonicTimestamp.self, from: data)
        #expect(decoded.nanoseconds == 123_456)
    }

    @Test("Nanosecond precision survives a long drive")
    func keepsPrecisionOverHours() throws {
        // Six hours in nanoseconds exceeds what a Float could represent to the
        // nanosecond; Int64 must carry it exactly through a round-trip.
        let sixHours = MonotonicTimestamp(nanoseconds: 6 * 3_600 * 1_000_000_000 + 7)
        let data = try JSONEncoder().encode(sixHours)
        let decoded = try JSONDecoder().decode(MonotonicTimestamp.self, from: data)
        #expect(decoded == sixHours)
    }

    @Test("Ordering follows the offset")
    func orders() {
        #expect(MonotonicTimestamp(nanoseconds: 1) < MonotonicTimestamp(nanoseconds: 2))
        #expect(MonotonicTimestamp(nanoseconds: -1) < .zero)
    }
}
