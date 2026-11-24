import Foundation

/// "No speed source" (prompt 53d): the position cannot be trusted to move because nothing tells the
/// engine how fast the car goes, and the car is not shown to be standing.
///
/// Pure value with an injected clock (`now`, seconds on the session's uptime clock), so it is
/// testable with no sensors. It reuses, and adds no detector to:
/// - the map's speed rule (`MapSpeedRule`, through `RouteInputs.sessionSpeed`): a source is a fresh
///   OBD reply or a fresh fix with a valid speed; network fixes and GPS off give none;
/// - the engine's own `NavigationEstimate.stationary` (a fresh OBD 0, or a parked stale step the
///   IMU has not contradicted), carried by `NavDisplay.stationary`.
///
/// The state is on when a Navigate or Record run is active with an initialised engine, there has
/// been no speed source for more than `thresholdS` in a row, and the estimate is not stationary.
/// It clears at once when a source returns. With no run, or no estimate yet, it is off and the
/// timer is not running.
struct NoSpeedSourceRule: Equatable, Sendable {
    /// No speed source for longer than this, seconds, makes the state.
    static let thresholdS = 5.0

    /// What one evaluation reads.
    struct Probe: Equatable, Sendable {
        /// Session uptime clock, seconds.
        var now: Double
        /// A Navigate or Record run is active (`RecordingSession.hasActiveRun`).
        var runActive: Bool
        /// `MapSpeedRule` resolves a source other than none.
        var hasSpeedSource: Bool
    }

    private var noSourceSince: Double?

    init() {}

    /// The state now. `hasEstimate`: the engine has an estimate (it is initialised);
    /// `stationary`: that estimate's `stationary`.
    mutating func evaluate(_ probe: Probe, hasEstimate: Bool, stationary: Bool) -> Bool {
        guard probe.runActive, hasEstimate, probe.now.isFinite else {
            noSourceSince = nil
            return false
        }
        if probe.hasSpeedSource {
            noSourceSince = nil
            return false
        }
        // A clock that went backwards restarts the count.
        if let since = noSourceSince, probe.now >= since {} else { noSourceSince = probe.now }
        guard let since = noSourceSince else { return false }
        return probe.now - since > Self.thresholdS && !stationary
    }

    mutating func reset() { noSourceSince = nil }
}

/// Wording of the state, shown on the HUD status line and in the manoeuvre bar.
enum NoSpeedSourceText {
    static let text = String(localized: "No speed source — position not updating")
    /// Not a motion symbol: the status line's usual "finding" glass says "wait", which is wrong here.
    static let symbol = "speedometer"
}
