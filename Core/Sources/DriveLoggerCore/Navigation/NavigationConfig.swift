import Foundation

/// Every tunable value of `NavigationEngine`, in one place so a replay can
/// print exactly what produced its numbers.
///
/// Defaults are the values tuned on the replay set (docs/NAVIGATION.md); a
/// change here is judged by `replay_nav` on every drive, not on one.
public struct NavigationConfig: Hashable, Sendable, Codable {
    // MARK: Filter

    public var particleCount = 2000
    /// RNG seed. Same seed + same input + same config = bit-identical output.
    public var seed: UInt64 = 1
    /// Prediction rate on the session clock's 10 Hz grid.
    public var stepHz = 10.0

    // MARK: Process noise

    /// Heading random walk, degrees per √s, while moving.
    public var headingNoiseDegPerSqrtS = 0.05
    /// Heading noise from turning, degrees per √(degree turned): variance
    /// grows with the angle turned, so it does not depend on the step
    /// rate. 0.1 is about 1° of spread per 90° turn (gyro turns match GNSS
    /// course changes within 1–1.5 % on the replay set).
    public var turnHeadingNoiseDegPerSqrtDeg = 0.1
    /// Along-track position noise, metres per √metre travelled. Added to
    /// each particle's position covariance (positions are Gaussian per
    /// particle, see `NavigationEngine`).
    public var alongTrackNoisePerSqrtM = 0.6
    /// Cross-track position noise, metres per √metre travelled.
    public var crossTrackNoisePerSqrtM = 0.6
    /// Speed-scale random walk, per √s, while moving.
    public var scaleNoisePerSqrtS = 0.000_1

    // MARK: Vehicle

    /// Per-vehicle prior on the OBD speed scale factor (true speed / OBD
    /// speed with the truncation offset): mean and standard deviation.
    /// Measured on this car's clean drives as the GNSS/OBD speed ratio
    /// above 30 km/h: 1.017 on clean-long, 1.015 on clean's dead-reckoned
    /// part. Another car needs its own measurement (or std back to ~0.03).
    public var scalePriorMean = 1.016
    public var scalePriorStd = 0.01

    // MARK: Speed

    /// OBD vehicle speed is truncated to whole km/h; `v + offset` when `v > 0`.
    public var obdSpeedOffsetKmh = 0.5
    /// OBD speed older than this is stale: unknown speed, not a stop.
    public var obdMaxAgeS = 2.0
    /// While OBD is stale, each particle's speed error random-walks with
    /// this intensity, m/s per √s.
    public var staleSpeedNoiseMpsPerSqrtS = 2.5
    /// The stale speed error is mean-reverting (Ornstein–Uhlenbeck) with
    /// this time constant, s: its spread levels off at
    /// noise × √(τ/2) (≈ 7.9 m/s) instead of growing without bound, so the
    /// position ellipse grows like √t, not t^1.5. 0 = plain random walk.
    public var staleSpeedDecayS = 20.0
    /// After a fresh OBD 0, a stale period is "parked" — frozen like a
    /// zero-velocity update — until the IMU shows the car moving: the
    /// EMA of horizontal userAcceleration (gravity removed, device frame)
    /// above this, g. On the replay set parked/idling peaks reach 0.082 g
    /// (phone handled after ignition-off) and most drive-offs exceed it
    /// within seconds; a gentle drive-off can take longer.
    public var staleParkedMotionG = 0.09
    /// Time constant of that EMA, s.
    public var staleParkedMotionTauS = 1.0
    /// While OBD is stale, heading noise is multiplied by this.
    public var staleHeadingNoiseFactor = 3.0

    // MARK: Catch-up and extrapolation

    /// One `ingest` runs at most this many stale grid steps one by one. A
    /// longer stale stretch (every input silent: the app suspended, a gap in
    /// a file, a corrupt huge `t`) is caught up in bounded work: parked, it
    /// is folded in O(1), bit-identical; at unknown speed, it is split into
    /// at most this many macro steps with the exact Ornstein–Uhlenbeck
    /// transition. Steps with fresh OBD always run one by one. 100 = 10 s
    /// at 10 Hz.
    public var maxCatchUpSteps = 100
    /// `estimate(at:)` extrapolates past the last step with the last speed
    /// and yaw rate for at most this long, s (the age up to which the engine
    /// itself treats a held OBD speed as known). Beyond it the position is
    /// held and, unless the last step was stationary, the ellipse grows.
    public var extrapolationHorizonS = 2.0

    // MARK: Local plane

    /// The local plane is re-anchored at the cloud's mean once that is
    /// further than this from the anchor, m. Far from its anchor the plane's
    /// north tilts against true north by about Δλ·sin φ (1.3° at 100 km east,
    /// latitude 55°), which would bias heading against GNSS course and
    /// distort turns; within 10 km the tilt stays under ~0.13°.
    public var reanchorDistanceM = 10_000.0

    // MARK: Gyro

    /// A gap between motion samples longer than this contributes no yaw.
    public var maxMotionGapS = 0.5

    // MARK: Location fixes

    /// Per-axis position σ per metre of `horizontalAccuracy`. CoreLocation
    /// reports a 68 % radius; for a circular Gaussian that radius is 1.51 σ,
    /// so σ = accuracy / 1.51 takes the fix at face value.
    public var fixSigmaPerAccuracy = 1 / 1.51
    /// Lower bound on a fix's per-axis position σ, metres.
    public var fixSigmaFloorM = 5.0
    /// A fix without a valid speed (speed or speedAccuracy negative) is a
    /// network fix (cell tower, Wi-Fi), whatever accuracy it reports: its
    /// σ is multiplied by this, on top of `fixSigmaPerAccuracy`.
    public var networkFixInflation = 1.0
    /// Network-fix errors are correlated over minutes: such a fix's
    /// log-likelihood is tempered by `min(1, Δt since the last network
    /// fix / this)`. Applies to small claimed accuracies too: a 24 m Wi-Fi
    /// fix repeated at 1 Hz is not 1 Hz of independent evidence.
    public var networkFixCorrelationS = 60.0
    /// A stale fix — older than `staleFixAgeS` at ingest: a pre-session fix
    /// from minutes ago, or a fix delivered after a relaunch mid-drive — has
    /// its σ grown by this speed × its age, m/s: the car may have moved while
    /// nothing observed it. Applies to initialisation and to updates.
    /// 1.0 m/s (about walking speed, or a car repositioned unobserved);
    /// adopted in N2.3 under the mean-based rule (docs/NAVIGATION.md). 0
    /// disables.
    public var staleFixSigmaGrowthMps = 1.0
    /// Age at ingest beyond which a fix is stale, s.
    public var staleFixAgeS = 5.0
    /// A fix older than this at arrival is ignored unless the car is stopped.
    public var maxFixAgeS = 10.0
    /// GNSS course is used only above this OBD/GNSS speed, m/s.
    public var courseMinSpeedMps = 3.0
    /// Lower bound on the course σ, degrees.
    public var courseSigmaFloorDeg = 2.0
    /// GNSS speed updates the scale only when OBD speed is above this,
    /// km/h (and speedAccuracy is valid). 10.8 km/h (3 m/s). A 30 km/h gate
    /// (how the scale prior was measured) was tried: equal on clean-long,
    /// worse on clean, whose only fast pre-mask stretch reads GNSS 3 %
    /// above OBD (docs/NAVIGATION.md).
    public var speedUpdateMinKmh = 10.8
    /// GNSS course and speed come from one Doppler solution. They are
    /// used only if GNSS speed agrees with fresh OBD speed within
    /// max(this, `gnssSpeedGateFraction` × OBD speed): a glitch fix
    /// reporting 25 m/s at 10 m/s, or slow manoeuvring, is rejected.
    public var gnssSpeedGateMps = 2.0
    public var gnssSpeedGateFraction = 0.15
    /// Lower bound on the GNSS-vs-OBD speed σ, m/s.
    public var speedSigmaFloorMps = 1.0
    /// A fix at or under this accuracy, with a valid course, is "clean".
    public var cleanFixAccM = 15.0
    /// A clean fix reseeds part of the cloud around its course while the
    /// heading std is above this.
    public var reseedHeadingStdDeg = 30.0
    /// A clean fix also reseeds when its course has no support in the
    /// cloud: every particle's heading is further than this many course σ
    /// away (a heading that converged wrongly, e.g. while reversing out of
    /// a parking space with unsigned OBD speed).
    public var reseedNoSupportSigma = 4.0
    /// Fraction of particles a clean fix reseeds.
    public var reseedFraction = 0.5

    // MARK: Manual fixes

    /// Smallest σ of a manual "I'm here" pin, metres; also the σ when the
    /// fix has no usable `mapSpanM`.
    public var manualFixSigmaMinM = 30.0
    /// A pin placed on a map showing `mapSpanM` metres is good to about
    /// span / this (a fingertip is roughly 1/12 of the screen).
    public var manualFixSpanDivisor = 12.0
    /// The prior has no support at a pin when every particle puts it
    /// further than this squared Mahalanobis distance (χ², 2 dof; 25 is a
    /// tail probability of about 4e-6): positions then restart at the pin,
    /// heading and scale hypotheses kept. A low ESS alone is not a reason
    /// to reset — that is the pin carrying information (R13.1-1).
    public var manualFixResetChi2 = 25.0

    // MARK: Resampling

    /// Systematic resampling when ESS falls under this fraction of N.
    public var resampleESSFraction = 0.5
    /// Heading jitter after resampling, degrees.
    public var resampleHeadingJitterDeg = 0.2
    /// Speed-scale jitter after resampling, so the scale does not
    /// collapse to a few copied values.
    public var resampleScaleJitter = 0.000_5

    // MARK: Reporting

    /// `converged` once the circular heading std is under this, degrees.
    public var convergedHeadingStdDeg = 10.0

    public init() {}
}

extension NavigationConfig {
    /// σ of a manual fix, metres: max(`manualFixSigmaMinM`,
    /// mapSpanM / `manualFixSpanDivisor`), or `manualFixSigmaMinM` when the
    /// span is missing, not finite or not positive. In heading-up the
    /// logged span can be up to ~2.2× too large (M10.1-3), which errs
    /// toward a larger σ: safe.
    public func manualFixSigma(mapSpanM: Double?) -> Double {
        guard let span = mapSpanM, span.isFinite, span > 0, manualFixSpanDivisor > 0 else {
            return manualFixSigmaMinM
        }
        return max(manualFixSigmaMinM, span / manualFixSpanDivisor)
    }
}
