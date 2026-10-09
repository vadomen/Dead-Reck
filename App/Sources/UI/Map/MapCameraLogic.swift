import DriveLoggerCore
import Foundation

/// Pure decisions for the follow camera. No MapKit, so they are unit-testable.
enum CameraHeading {
    /// Heading the camera should have: 0 north-up; heading-up the smoothed
    /// heading, else the bearing. With no bearing it is 0 even if a stale
    /// smoothed value is left over (for example from the previous recording).
    static func choose(headingUp: Bool, bearing: Double?, smoothed: Double?) -> Double {
        guard headingUp, let bearing else { return 0 }
        return smoothed ?? bearing
    }
}

/// Limits how often the heading-up camera is written: only when the heading
/// moved by more than `minDelta` since the last write and at least
/// `minInterval` has passed. The smoother itself may still step faster.
struct HeadingWriteGate: Equatable, Sendable {
    static let minDelta = 2.0
    static let minInterval: Duration = .milliseconds(250)

    private var lastHeading: Double?
    private var lastTime: ContinuousClock.Instant?

    init() {}

    /// True when the caller should write `heading`; records the write.
    mutating func admit(_ heading: Double, at now: ContinuousClock.Instant) -> Bool {
        if let lastHeading, let lastTime {
            guard now - lastTime >= Self.minInterval else { return false }
            // Shortest way round: 359 to 1 is 2 degrees, not 358.
            guard abs(HeadingSmoother.shortestDelta(from: lastHeading, to: heading)) > Self.minDelta else { return false }
        }
        lastHeading = heading
        lastTime = now
        return true
    }

    /// Note a write made elsewhere (recentre, mode switch).
    mutating func noteWrite(_ heading: Double, at now: ContinuousClock.Instant) {
        lastHeading = heading
        lastTime = now
    }

    mutating func reset() { self = HeadingWriteGate() }
}

enum MapChange {
    /// True when `new` differs from `old` by more than `relative` (1% default).
    static func isSignificant(old: Double?, new: Double, relative: Double = 0.01) -> Bool {
        guard let old, old.isFinite, old != 0 else { return true }
        return abs(new - old) / abs(old) > relative
    }
}

/// "Stopped" for heading-up: OBD speed exactly 0 from a fresh reply, judged
/// by the manual-fix gate's own rule (`ManualFixGate.maxOBDAgeS`). A stale 0
/// is unknown, not stopped, so an ELM stall at a stop cannot freeze the
/// heading after drive-off.
enum StationaryRule {
    static func isStopped(kmh: Double?, replyUptime: Double?, now: Double) -> Bool {
        guard let kmh, let replyUptime else { return false }
        let gate = ManualFixGate.evaluate(
            now: MonotonicTimestamp(seconds: now),
            obdSpeedKmh: kmh,
            obdSpeedT: MonotonicTimestamp(seconds: replyUptime),
            referenceFix: nil
        )
        return gate.speedSource == .obd && gate.speedKmh == 0
    }
}

extension MapFraming {
    /// Camera distance for a region `spanMeters` tall. Approximate (MapKit's
    /// field of view is not documented); used only to rebuild a camera when
    /// the framing rule is applied in heading-up.
    static let distancePerSpan = 1.87

    static func cameraDistance(spanMeters: Double) -> Double { spanMeters * distancePerSpan }
}
