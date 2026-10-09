import Foundation

/// What `NavigationEngine` believes at one instant.
public struct NavigationEstimate: Hashable, Sendable {
    /// The time the estimate is for (session clock).
    public var t: MonotonicTimestamp
    /// Weighted mean position in the engine's local plane, metres.
    /// Plane-relative: the plane re-anchors at the cloud's mean once that is
    /// more than `NavigationConfig.reanchorDistanceM` from the anchor, and
    /// these values then jump by about that much while the position does
    /// not move. Consumers (map, sidecar) should use `latitude`/`longitude`.
    public var east: Double
    public var north: Double
    /// The same position in WGS-84 degrees.
    public var latitude: Double
    public var longitude: Double
    /// Circular mean heading of travel, degrees clockwise from north, [0, 360).
    public var headingDeg: Double
    /// Circular standard deviation of the heading, degrees.
    public var headingStdDeg: Double
    /// 95 % position ellipse. Past the extrapolation horizon it grows
    /// (see `NavigationEngine.estimate(at:)`); it never shrinks with `t`.
    public var ellipse: ErrorEllipse
    /// Mean speed over the last prediction step, m/s (0 when stopped).
    public var speedMps: Double
    /// OBD speed scale factor: mean and standard deviation.
    public var speedScaleMean: Double
    public var speedScaleStd: Double
    /// Effective sample size of the particle cloud, 1…N.
    public var effectiveSampleSize: Double
    /// Heading std under `NavigationConfig.convergedHeadingStdDeg`. While
    /// false the app shows "calibrating heading".
    public var converged: Bool
    /// The last prediction step was frozen: a zero-velocity update (fresh
    /// OBD 0) or a parked stale step (OBD stale after an OBD 0, with no IMU
    /// sign of motion since).
    public var stationary: Bool
}

/// A 95 % confidence ellipse: semi-axes `√(5.991 λ)` of the position
/// covariance's eigenvalues.
public struct ErrorEllipse: Hashable, Sendable {
    public var semiMajorM: Double
    public var semiMinorM: Double
    /// Bearing of the major axis, degrees clockwise from north, [0, 180).
    public var orientationDeg: Double

    /// χ² with 2 degrees of freedom at 95 %.
    public static let chiSquare95 = 5.991

    public init(semiMajorM: Double, semiMinorM: Double, orientationDeg: Double) {
        self.semiMajorM = semiMajorM
        self.semiMinorM = semiMinorM
        self.orientationDeg = orientationDeg
    }

    /// The ellipse of a 2×2 covariance [[ee, en], [en, nn]] (east/north, m²).
    public init(covarianceEE ee: Double, en: Double, nn: Double) {
        let mean = (ee + nn) / 2
        let radius = (((ee - nn) / 2) * ((ee - nn) / 2) + en * en).squareRoot()
        let major = max(mean + radius, 0)
        let minor = max(mean - radius, 0)
        // Angle of the major axis from east, counter-clockwise.
        let theta = 0.5 * atan2(2 * en, ee - nn)
        var bearing = 90 - theta * 180 / .pi
        bearing = bearing.truncatingRemainder(dividingBy: 180)
        if bearing < 0 { bearing += 180 }
        self.init(
            semiMajorM: (Self.chiSquare95 * major).squareRoot(),
            semiMinorM: (Self.chiSquare95 * minor).squareRoot(),
            orientationDeg: bearing
        )
    }

    /// Whether a point (east/north offset from the ellipse centre, metres)
    /// lies inside.
    public func contains(dEast: Double, dNorth: Double) -> Bool {
        let b = orientationDeg * .pi / 180
        // Unit vector of the major axis in east/north.
        let ue = sin(b), un = cos(b)
        let along = dEast * ue + dNorth * un
        let across = -dEast * un + dNorth * ue
        guard semiMajorM > 0 else { return along == 0 && across == 0 }
        let minor = max(semiMinorM, 1e-9)
        return (along / semiMajorM) * (along / semiMajorM) + (across / minor) * (across / minor) <= 1
    }
}

/// Running counts of what the engine did with its input, for replay reports.
public struct NavigationCounters: Hashable, Sendable, Codable {
    /// 10 Hz prediction steps since initialisation.
    public var steps = 0
    /// Steps frozen by a zero-velocity update.
    public var zuptSteps = 0
    /// Steps with stale OBD speed (unknown speed).
    public var staleSpeedSteps = 0
    /// Stale steps frozen as parked: after an OBD 0, no motion since.
    public var staleParkedSteps = 0
    public var fixesUsed = 0
    /// Fixes without a valid speed (cell tower, Wi-Fi).
    public var networkFixesUsed = 0
    public var fixesIgnoredStale = 0
    public var fixesIgnoredInvalid = 0
    public var courseUpdates = 0
    public var speedUpdates = 0
    public var reseeds = 0
    public var manualFixes = 0
    public var manualResets = 0
    public var resamples = 0
    /// Times the local plane moved to the cloud's mean (R13.1-3).
    public var reanchors = 0
    /// Grid steps caught up in bulk after a long silence of every input,
    /// not one by one (R13.1-6): parked stretches folded, and unknown-speed
    /// stretches run as macro steps. Included in `steps`. 0 on ordinary
    /// input.
    public var coalescedSteps = 0
    /// Macro prediction steps (each one pass over the particles) run for
    /// the unknown-speed part of `coalescedSteps`.
    public var macroSteps = 0

    public init() {}
}
