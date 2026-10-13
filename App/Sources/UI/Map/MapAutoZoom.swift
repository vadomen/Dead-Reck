import Foundation

/// Speed-dependent camera distance while following (UX-6). Pure: time comes
/// in as `dt`, the speed from `MapSpeedRule` (UX-5), so it is unit-testable.
///
/// Precedence of the follow camera's distance (see `FollowZoom`):
/// 1. A driver zoom (a camera report that is not our own write) is the
///    distance until the next re-centre (Follow tap, auto-resume, a frame):
///    speed is ignored meanwhile.
/// 2. Otherwise this automatic distance.
/// 3. In heading-up with an estimate, the ellipse fit (`FollowSpan`) widens
///    whichever of the two applies when it needs a wider view, and never
///    narrows it. North-up never widens, as before.
/// Pitch stays 0: pins and the 300 m span rule assume a top-down map.
struct AutoZoom: Equatable, Sendable {
    /// All tuning in one place.
    enum Config {
        /// (speed km/h, camera distance m). Below the first speed the first
        /// distance; at and above the last speed the last; linear between.
        static let table: [(kmh: Double, distance: Double)] = [
            (20, 250), (50, 500), (80, 900), (110, 1500),
        ]
        /// Cold start, and the slowest step.
        static let slowestDistance = 250.0
        /// Low-pass time constant of the camera distance, seconds.
        static let timeConstantS = 3.0
        /// Zooming out follows the speed at once; zooming in waits until the
        /// target has stayed lower for this long, so stop-and-go does not pump.
        static let zoomInDwellS = 6.0
        /// A target within this fraction of the held one is no change.
        static let deadband = 0.03
    }

    /// The smoothed distance the camera should have.
    private(set) var distance = Config.slowestDistance
    /// The target the smoother is heading for; held while there is no speed.
    private(set) var latchedTarget = Config.slowestDistance
    private var lowerFor = 0.0

    init() {}

    /// The table's distance for a speed.
    static func target(kmh: Double) -> Double {
        let table = Config.table
        guard kmh.isFinite, let first = table.first, let last = table.last else { return Config.slowestDistance }
        if kmh <= first.kmh { return first.distance }
        if kmh >= last.kmh { return last.distance }
        for (a, b) in zip(table, table.dropFirst()) where kmh <= b.kmh {
            let f = (kmh - a.kmh) / (b.kmh - a.kmh)
            return a.distance + f * (b.distance - a.distance)
        }
        return last.distance
    }

    /// Advances by `dt` seconds with the current speed (nil: no source, the
    /// last distance is held) and returns the distance.
    @discardableResult
    mutating func step(speedKmh: Double?, dt: Double) -> Double {
        guard dt.isFinite, dt > 0 else { return distance }
        if let speedKmh, speedKmh.isFinite {
            let target = Self.target(kmh: speedKmh)
            if target > latchedTarget * (1 + Config.deadband) {
                latchedTarget = target
                lowerFor = 0
            } else if target < latchedTarget * (1 - Config.deadband) {
                lowerFor += dt
                if lowerFor >= Config.zoomInDwellS {
                    latchedTarget = target
                    lowerFor = 0
                }
            } else {
                lowerFor = 0
            }
        }
        // Low-pass in log distance: zooming is perceived as a ratio.
        let alpha = 1 - exp(-dt / Config.timeConstantS)
        distance = exp(log(distance) + (log(latchedTarget) - log(distance)) * alpha)
        return distance
    }
}
