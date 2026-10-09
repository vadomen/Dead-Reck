import DriveLoggerCore
import Foundation

/// Direction of travel for heading-up. Display only; never feeds the recorder.
@MainActor protocol MapBearingSource: AnyObject {
    /// Degrees clockwise from true north in [0, 360); nil until a good one.
    var bearingDegrees: Double? { get }
    func ingest(_ fix: LocationSample)
    /// Forget the bearing (a new recording starts).
    func reset()
}

/// Bearing from GPS course. Never the compass: a magnet mount ruins it.
@MainActor
final class GPSCourseBearingSource: MapBearingSource {
    static let minSpeedKmh = 10.0
    static let maxCourseAccuracy = 20.0

    private(set) var bearingDegrees: Double?

    init() {}

    /// Course is noise when slow or when the system is unsure of it.
    static func isGood(_ fix: LocationSample) -> Bool {
        guard fix.speed.isFinite, fix.speed >= 0, fix.speed * 3.6 > minSpeedKmh else { return false }
        guard fix.course.isFinite, fix.course >= 0, fix.course < 360 else { return false }
        guard fix.courseAccuracy.isFinite, (0...maxCourseAccuracy).contains(fix.courseAccuracy) else { return false }
        return true
    }

    func ingest(_ fix: LocationSample) {
        if Self.isGood(fix) { bearingDegrees = fix.course }
    }

    func reset() { bearingDegrees = nil }
}

/// Low-pass filter for the camera heading. Takes the short way round 0/360,
/// is rate-limited, and holds when there is no target or the car is stopped.
struct HeadingSmoother: Equatable, Sendable {
    static let timeConstant = 0.4
    static let maxRateDegPerSec = 90.0

    /// Last output, [0, 360).
    private(set) var heading: Double?

    init() {}

    /// Advances by `dt` seconds. The first target snaps. Returns the new heading.
    @discardableResult
    mutating func step(target: Double?, frozen: Bool, dt: Double) -> Double? {
        guard let target, target.isFinite else { return heading }
        guard let current = heading else {
            heading = Self.normalized(target)
            return heading
        }
        guard !frozen, dt.isFinite, dt > 0 else { return heading }
        let diff = Self.shortestDelta(from: current, to: target)
        let alpha = 1 - exp(-dt / Self.timeConstant)
        let limit = Self.maxRateDegPerSec * dt
        let delta = min(max(diff * alpha, -limit), limit)
        heading = Self.normalized(current + delta)
        return heading
    }

    /// Restarts from `bearing` (the last good one), or from nothing when nil.
    /// Used when heading-up becomes active again: the smoother only steps
    /// while active, so its value may be stale, and a frozen smoother would
    /// hold that stale value.
    mutating func reseed(to bearing: Double?) {
        heading = bearing.flatMap { $0.isFinite ? Self.normalized($0) : nil }
    }

    static func normalized(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        let n = r < 0 ? r + 360 : r
        return n >= 360 ? 0 : n
    }

    /// Signed angle in (-180, 180].
    static func shortestDelta(from: Double, to: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return d
    }
}
