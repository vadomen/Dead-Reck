import Foundation
import Testing

@testable import DriveLoggerCore

enum StatsFixtures {
    static let motion = LogFixtures.motion

    static func ms(_ value: Double) -> MonotonicTimestamp {
        MonotonicTimestamp(nanoseconds: Int64((value * 1_000_000).rounded()))
    }

    static func motion(at milliseconds: Double) -> LogEvent {
        .motion(motion, at: ms(milliseconds))
    }

    static func accel(at milliseconds: Double) -> LogEvent {
        LogEvent(timestamp: ms(milliseconds), payload: .accelerometer(.zero))
    }

    static func gyro(at milliseconds: Double) -> LogEvent {
        LogEvent(timestamp: ms(milliseconds), payload: .gyroscope(.zero))
    }

    static func elm(_ outcome: ELMOutcome, phase: ELMPhase = .poll, at milliseconds: Double) -> LogEvent {
        LogEvent(
            timestamp: ms(milliseconds),
            payload: .elm(ELMTrafficSample(
                seq: 1, phase: phase.rawValue, tx: "010D", requestT: ms(milliseconds - 30),
                rx: outcome == .timeout ? nil : "7E803410D32", outcome: outcome.rawValue
            ))
        )
    }
}

@Suite("StatsAccumulator")
struct StatsAccumulatorTests {
    typealias F = StatsFixtures

    @Test("Counts every kind observed in the window, unknown kinds included")
    func countsPerKind() {
        var stats = StatsAccumulator()
        stats.observe(F.motion(at: 0))
        stats.observe(F.motion(at: 10))
        stats.observe(F.accel(at: 5))
        stats.observe(.marker("tunnel", at: F.ms(7)))
        stats.observe(LogEvent(timestamp: F.ms(8), payload: .unrecognized(kind: "future", data: nil)))
        let row = stats.closeWindow(at: F.ms(10_000), queueDepthMax: 0, dropped: 0, bytesWritten: 0)
        #expect(row.counts == ["motion": 2, "accel": 1, "marker": 1, "future": 1])
    }

    @Test("Rates over a 10 s window: 100 Hz motion, poll-ok exchanges for OBD Hz")
    func rates() {
        var stats = StatsAccumulator()
        for index in 0..<1_000 {
            stats.observe(F.motion(at: Double(index) * 10))
        }
        for index in 0..<80 {
            stats.observe(F.elm(.ok, at: Double(index) * 125))
        }
        // Not successful polls: manual, init, noData, timeout.
        stats.observe(F.elm(.ok, phase: .manual, at: 500))
        stats.observe(F.elm(.ok, phase: .initialisation, at: 600))
        stats.observe(F.elm(.noData, at: 700))
        stats.observe(F.elm(.timeout, at: 800))
        stats.observe(F.elm(.timeout, phase: .initialisation, at: 900))

        let row = stats.closeWindow(at: F.ms(10_000), queueDepthMax: 12, dropped: 3, bytesWritten: 4_096)
        #expect(row.windowS == 10)
        #expect(row.motionHz == 100)
        #expect(row.obdHz == 8)
        #expect(row.timeouts == 2)
        #expect(row.queueDepthMax == 12)
        #expect(row.dropped == 3)
        #expect(row.bytesWritten == 4_096)
    }

    @Test("An interval over 50 ms is a gap; exactly 50 ms is not")
    func gapThreshold() {
        var stats = StatsAccumulator()
        for t in [0.0, 10, 20, 100, 110, 160, 170] {   // 80 ms and exactly 50 ms
            stats.observe(F.motion(at: t))
        }
        let row = stats.closeWindow(at: F.ms(1_000), queueDepthMax: 0, dropped: 0, bytesWritten: 0)
        #expect(row.gaps["motion"] == 1)
        #expect(row.maxGapMs["motion"] == 80)
    }

    @Test("Gaps are tracked per stream: motion, accel and gyro, each against itself")
    func gapsPerKind() {
        var stats = StatsAccumulator()
        for t in stride(from: 0.0, to: 300, by: 10) {
            stats.observe(F.motion(at: t))
            if t < 100 || t > 200 { stats.observe(F.accel(at: t + 1)) }  // 91 → 211: 120 ms hole
        }
        stats.observe(F.gyro(at: 0))
        stats.observe(F.gyro(at: 60))
        stats.observe(F.gyro(at: 200))
        let row = stats.closeWindow(at: F.ms(300), queueDepthMax: 0, dropped: 0, bytesWritten: 0)
        #expect(row.gaps == ["motion": 0, "accel": 1, "gyro": 2])
        #expect(row.maxGapMs["motion"] == 10)
        #expect(row.maxGapMs["accel"] == 120)
        #expect(row.maxGapMs["gyro"] == 140)
    }

    @Test("Out-of-order timestamps never produce a negative interval or a phantom gap")
    func outOfOrder() {
        var stats = StatsAccumulator()
        // A late sample fills a hole: in write order the hole looks like
        // 100 ms; in time order every interval is at most 40 ms.
        for t in [0.0, 40, 120, 80, 160, 150, 155, 155] {
            stats.observe(F.motion(at: t))
        }
        let row = stats.closeWindow(at: F.ms(1_000), queueDepthMax: 0, dropped: 0, bytesWritten: 0)
        #expect(row.gaps["motion"] == 0)
        #expect(row.maxGapMs["motion"] == 40)
        #expect(row.maxGapMs.values.allSatisfy { $0 >= 0 })
    }

    @Test("Negative timestamps (CoreMotion samples from before the session) are ordinary")
    func negativeTimestamps() {
        var stats = StatsAccumulator()
        for t in [-30.0, -20, -10, 0, 10, 90] {
            stats.observe(F.motion(at: t))
        }
        let row = stats.closeWindow(at: F.ms(1_000), queueDepthMax: 0, dropped: 0, bytesWritten: 0)
        #expect(row.gaps["motion"] == 1)
        #expect(row.maxGapMs["motion"] == 80)
        #expect(row.counts["motion"] == 6)
    }

    @Test("The first window starts at the first event; later windows at the previous end")
    func windowBounds() {
        var stats = StatsAccumulator()
        stats.observe(F.motion(at: 2_000))
        let first = stats.closeWindow(at: F.ms(10_000), queueDepthMax: 0, dropped: 0, bytesWritten: 0)
        #expect(first.windowS == 8)
        stats.observe(F.motion(at: 12_000))
        let second = stats.closeWindow(at: F.ms(20_000), queueDepthMax: 0, dropped: 0, bytesWritten: 0)
        #expect(second.windowS == 10)
        #expect(second.counts == ["motion": 1])
    }

    @Test("An interval spanning two windows is counted in the window of its second sample")
    func gapAcrossWindows() {
        var stats = StatsAccumulator()
        stats.observe(F.motion(at: 9_990))
        _ = stats.closeWindow(at: F.ms(10_000), queueDepthMax: 0, dropped: 0, bytesWritten: 0)
        stats.observe(F.motion(at: 10_200))
        let row = stats.closeWindow(at: F.ms(20_000), queueDepthMax: 0, dropped: 0, bytesWritten: 0)
        #expect(row.gaps["motion"] == 1)
        #expect(row.maxGapMs["motion"] == 210)
    }

    @Test("A silent stream reports zero gaps and no max-gap value; counts make the silence visible")
    func silentStream() {
        var stats = StatsAccumulator()
        stats.observe(F.motion(at: 0))
        let row = stats.closeWindow(at: F.ms(10_000), queueDepthMax: 0, dropped: 0, bytesWritten: 0)
        #expect(row.gaps == ["motion": 0, "accel": 0, "gyro": 0])
        #expect(row.maxGapMs.isEmpty)
        #expect(row.counts["accel"] == nil)
    }

    @Test("Closing a window resets counts, rates and gaps")
    func resets() {
        var stats = StatsAccumulator()
        for t in [0.0, 100, 200] { stats.observe(F.motion(at: t)) }
        stats.observe(F.elm(.timeout, at: 50))
        _ = stats.closeWindow(at: F.ms(10_000), queueDepthMax: 0, dropped: 0, bytesWritten: 0)
        let empty = stats.closeWindow(at: F.ms(20_000), queueDepthMax: 0, dropped: 0, bytesWritten: 0)
        #expect(empty.counts.isEmpty)
        #expect(empty.motionHz == 0)
        #expect(empty.obdHz == 0)
        #expect(empty.timeouts == 0)
        #expect(empty.gaps == ["motion": 0, "accel": 0, "gyro": 0])
    }

    @Test("A window with no events and no previous end has zero length and zero rates")
    func emptyFirstWindow() {
        var stats = StatsAccumulator()
        let row = stats.closeWindow(at: F.ms(10_000), queueDepthMax: 0, dropped: 0, bytesWritten: 0)
        #expect(row.windowS == 0)
        #expect(row.motionHz == 0)
        #expect(row.obdHz == 0)
    }

    @Test("The row round-trips through the codec")
    func encodes() throws {
        var stats = StatsAccumulator()
        for t in [0.0, 10, 90] { stats.observe(F.motion(at: t)) }
        let row = stats.closeWindow(at: F.ms(10_000), queueDepthMax: 1, dropped: 0, bytesWritten: 10)
        let event = LogEvent(timestamp: F.ms(10_000), payload: .stats(row))
        let codec = LogCodec()
        #expect(try codec.event(from: codec.line(for: event)) == event)
    }
}
