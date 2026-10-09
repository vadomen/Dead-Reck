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
    /// While OBD is stale, heading noise is multiplied by this.
    public var staleHeadingNoiseFactor = 3.0

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
    /// Tower/Wi-Fi-like fix: horizontal accuracy above this and no speed.
    public var towerMinAccuracyM = 200.0
    /// σ multiplier for tower-like fixes, on top of `fixSigmaPerAccuracy`.
    public var towerInflation = 1.0
    /// Tower-like errors are correlated over minutes: a tower fix's
    /// log-likelihood is tempered by `min(1, Δt since the last one / this)`.
    public var towerCorrelationS = 60.0
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
    /// If a manual fix leaves fewer than this fraction of effective
    /// particles, the prior had no support there: positions are reset
    /// around the pin, headings and scales kept.
    public var manualFixResetESSFraction = 0.01
    /// The pin also counts as unsupported when every particle puts it
    /// further than this squared Mahalanobis distance (χ², 2 dof; 25 is a
    /// tail probability of about 4e-6) — a confident cloud far from the pin.
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
