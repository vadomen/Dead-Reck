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

    // MARK: OBD zero against moving fixes (N4B1-1)

    /// Fix gate on OBD zeros (N4B1-1): 1 vetoes a step that an OBD 0 would
    /// freeze (a fresh 0: zero-velocity update; a stale one: parked) while
    /// recent good fixes show the car moving; 0: off. "Good": a valid
    /// Doppler speed (not a network fix) and accuracy ≤ `cleanFixAccM`.
    /// Evidence counts only from fixes whose own `t` is after the OBD 0
    /// run began (the first 0 after a moving reply or none), so the GNSS
    /// tail of a real stop, measured before OBD reached 0, never counts.
    /// The veto holds while at least `zuptFixGateMinFixes` such fixes in a
    /// row read ≥ `zuptFixGateMinSpeedMps` and the newest is at most
    /// `zuptFixGateMaxAgeS` old at the step. A good fix under the speed
    /// resets the run; a moving OBD reply ends it. A vetoed step moves like
    /// a stale one (unknown-speed noise) at the newest such fix's Doppler
    /// speed, not scaled (it is already a true speed). Causal: only fixes
    /// already ingested count. Any value other than 0 or 1 is invalid
    /// (`invalidReason`). On by default since 2026-10-18: on the acceptance
    /// set (seeds 1–5, with and without roads) it never fires and every
    /// output is byte-identical to off (docs/NAVIGATION.md "N4B1-1: OBD
    /// zero against moving fixes").
    public var zuptFixGate = 1
    /// Doppler speed at or above which a good fix says "moving", m/s.
    /// Valid: finite, > 0.
    public var zuptFixGateMinSpeedMps = 5.0
    /// Moving good fixes in a row, after the OBD 0 began, before the veto
    /// holds. Valid: ≥ 1.
    public var zuptFixGateMinFixes = 2
    /// The newest moving fix's `t` at most this before the step, s.
    /// Valid: finite, ≥ 0.
    public var zuptFixGateMaxAgeS = 3.0

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
    /// An input arriving more than this many seconds after the latest input
    /// the engine accepted is implausible (a corrupt `t`) and is rejected,
    /// counted in `NavigationCounters.inputsRejectedTimeJump` (B0-1).
    /// Without the guard one corrupt huge `t` moves the engine clock there,
    /// and every later, normal input is in the past: the engine stops
    /// stepping for the rest of the recording. A real resume after a longer
    /// silence is accepted on its second input (see
    /// `NavigationEngine.accepts(_:)`). 1 h.
    public var maxForwardJumpS = 3_600.0

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
    /// its σ grown by max(this, the fix's own valid speed) × its age, m/s:
    /// the car may have moved while nothing observed it, at about the speed
    /// it had when the fix was taken (NAV-INITSTALE). Applies to
    /// initialisation and to updates. 1.0 m/s (about walking speed, or a car
    /// repositioned unobserved); adopted in N2.3 under the mean-based rule
    /// (docs/NAVIGATION.md). 0 disables (the fix speed too).
    public var staleFixSigmaGrowthMps = 1.0
    /// Age at ingest beyond which a fix is stale, s.
    public var staleFixAgeS = 5.0
    /// A fix older than this at arrival is ignored unless the car is stopped.
    public var maxFixAgeS = 10.0
    /// Such a stale fix arriving before OBD can say whether the car is
    /// stopped (no reply yet, or only a stale one) is held, not dropped,
    /// for at most this long, s; the first OBD reply fresh at its arrival
    /// decides (0: used, moving: dropped). One fix is held, the newest
    /// (N4B-1). Live, the pre-session fix is written before the first OBD
    /// 0, whose row lands up to 0.27 s after its own `t`; on the replay set
    /// that reply's `t` is 31–48 ms before the fix's arrival. 5 s covers a
    /// few OBD poll cycles and a slow first reply while leaving the stale
    /// σ growth (1 m/s × the wait) small. 0 (or less) disables holding:
    /// the fix is dropped on arrival, as before N4-B1.
    public var heldFixTimeoutS = 5.0
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
    /// A pin marks a spot the car passed about a human reaction time before
    /// the tap: its σ grows by v × (this + max(0, t − pressedT)), s, in
    /// quadrature (N4MF-1). t − pressedT is the confirm delay of the old
    /// long-press flow, 0 for a double tap. 0 restores the span-only σ for
    /// double-tap pins.
    public var manualFixReactionS = 1.0
    /// v for that allowance when the pin's `speedSource` is not `obd` or
    /// `gps` (or its speed is missing), m/s.
    public var manualFixUnknownSpeedMps = 10.0
    /// The prior has no support at a pin when every particle puts it
    /// further than this squared Mahalanobis distance (χ², 2 dof; 25 is a
    /// tail probability of about 4e-6): positions then restart at the pin,
    /// heading and scale hypotheses kept. A low ESS alone is not a reason
    /// to reset — that is the pin carrying information (R13.1-1).
    public var manualFixResetChi2 = 25.0
    /// A manual fix whose `t` is before the engine's last grid step (the
    /// app writes a double-tap pin when its 3 s undo window closes, `t` =
    /// the tap) is applied to each particle as of `t`: the pin plus that
    /// particle's own motion since, from a ring of per-particle positions
    /// this many seconds long (R14.3-1). Older than the ring, the pin falls
    /// back to the cloud's mean motion since `t`. Also sizes the record of
    /// pre-initialisation steps a late initialising pin is predicted
    /// forward over. Memory: 3 × (window × stepHz + 1) × particleCount
    /// Doubles, two rings and the resample remap's scratch (2.4 MB at 5 s,
    /// 10 Hz, 2000 particles). 5 s covers the 3 s
    /// window plus write and scheduling delay. 0 disables (every pin
    /// shifted by the mean motion, as before R14.3-1); clamped to
    /// 0…`maxLateManualFixWindowS`.
    public var lateManualFixWindowS = 5.0

    // MARK: Pin against a GNSS source (N3-FIXPIN)

    /// Pin-vs-fix arbitration (N3-FIXPIN, docs/NAVIGATION.md "Pin against a
    /// GNSS source"). Per GNSS source (fixes with a valid speed, split by
    /// `LocationSample.accessory`: true = accessory, false or nil = phone)
    /// the engine keeps the fixes of the last this many seconds; a manual
    /// fix that disagrees significantly with the prior is judged against the
    /// source that supplied at least one of them. Only read while
    /// `roadFixPinCheck` or `fixPinTwoPinCheck` is on. Valid: finite, in
    /// (0, `maxFixPinWindowS`].
    public var fixPinWindowS = 90.0
    /// Two-pin arbiter (works with and without roads): 1 down-weights a
    /// source when two independent pins agree on its offset (χ² of their
    /// difference ≤ 5.99 against the summed covariances) after at least
    /// `fixPinTwoPinMinPathM` of OBD distance and `fixPinTwoPinMinTurnDeg` of
    /// net gyro heading change between them. 0: off (the default). Any
    /// other value is invalid (`invalidReason`).
    public var fixPinTwoPinCheck = 0
    /// Least OBD distance between the two pins, metres. Valid: finite, ≥ 0.
    public var fixPinTwoPinMinPathM = 300.0
    /// Least |net heading change| (integrated gyro yaw) between the two
    /// pins, degrees. Valid: finite, in [0, 360].
    public var fixPinTwoPinMinTurnDeg = 45.0
    /// While a source is down-weighted its position update uses
    /// σ = max(σ_claimed, |offset|) × this, tempered like a network fix.
    /// Valid: finite, > 0.
    public var fixPinInflation = 1.0
    /// Win-back by agreement: a down-weighted source is restored once its
    /// fixes agree with the estimate (Mahalanobis² < 9 against its claimed
    /// σ plus the estimate's covariance) for at least this many seconds
    /// and 15 consecutive fixes. Valid: finite, ≥ 0.
    public var fixPinRestoreS = 30.0

    // MARK: Resampling

    /// Systematic resampling when ESS falls under this fraction of N.
    public var resampleESSFraction = 0.5
    /// Heading jitter after resampling, degrees.
    public var resampleHeadingJitterDeg = 0.2
    /// Speed-scale jitter after resampling, so the scale does not
    /// collapse to a few copied values.
    public var resampleScaleJitter = 0.000_5

    // MARK: Roads (N3.2, docs/N3_PLAN.md "Road model in the filter")

    /// Grid time between road updates, s, at the end of a moving step. 0
    /// disables road updates even with a pack loaded. Clamped to 0 or
    /// into one grid step…`maxRoadUpdateIntervalS`.
    public var roadUpdateIntervalS = 1.0
    /// Cross-track σ of the car about the OSM centreline, metres: lane
    /// offset plus OSM error.
    public var roadSigmaM = 7.0
    /// σ of the agreement between particle heading and road bearing, degrees.
    public var roadHeadingSigmaDeg = 10.0
    /// A road is a candidate only within this heading difference, degrees
    /// (a oneway: its forward bearing only).
    public var roadHeadingGateDeg = 45.0
    /// Candidate radius, metres; clamped to the pack's guaranteed radius.
    /// Also R of the off-road density 1/(2R) · 1/(2π).
    public var roadSearchRadiusM = 50.0
    /// Cross-track gate d² / (hᵀPh + σr²) (1 dof).
    public var roadInnovationGateChi2 = 9.0
    /// ε: the probability that the car is not on a mapped road.
    public var roadOffRoadProbability = 0.1
    /// Distance tempering: a road update weighs min(1, Δs / this), Δs the
    /// mean distance driven since the last one, metres. 100 (was 30): an
    /// explicit trade-off, see docs/NAVIGATION.md "N3.2 decision
    /// (2026-10-14)".
    public var roadCorrelationM = 100.0
    /// A particle Gaussian wider than this σ, metres, is split before
    /// matching.
    public var roadSplitSigmaM = 15.0
    /// No road update while the cloud's 95 % semi-major axis is above
    /// this, metres.
    public var roadEngageMaxEllipseM = 1_000.0
    /// 0: Schmidt update, along-track unchanged; 1: exact Kalman. Values
    /// between scale the along-track gain. Outside 0…1 the config is
    /// invalid (`invalidReason`), not clamped.
    public var roadAlongTrackCoupling = 0.0
    /// A candidate on another level than the particle's is eligible within
    /// this many adjacency hops of the particle's edge.
    public var roadLevelHops = 2
    /// Off-road distance, metres, after which a particle's level is unknown.
    public var roadLevelForgetM = 100.0
    /// GNSS fix gate radius max(`roadFixGateMinM`, this × σ_fix); 0
    /// disables the gate.
    public var roadFixGateSigma = 3.0
    public var roadFixGateMinM = 50.0
    /// The gate applies only at a fresh OBD speed of at least this, km/h…
    public var roadFixGateMinKmh = 20.0
    /// …and while the last road update's on-road share is at least this.
    public var roadFixGateOnRoadShare = 0.8
    /// A pin at or above this `gateSpeedKmh` triggers an immediate road
    /// update (the car was on a road); 0 disables. Weight 1 when the pin
    /// initialised the engine or reset it; otherwise tempered by the
    /// distance since the last road update, as a regular one.
    public var roadPinAnchorMinKmh = 3.0
    /// Road arbiter of a pin against a GNSS source (N3-FIXPIN): 1 compares,
    /// over the source's recent fixes inside pack coverage, the mean capped
    /// distance to a heading-compatible road of the fixes as given (A) and
    /// shifted by the pin's offset (B). A > `roadFixPinOffRoadM`, B ≤ it
    /// and A − B ≥ `roadFixPinMarginM`: the pin is right and the source is
    /// down-weighted. 0: off (the default). Inert without roads. Any other
    /// value is invalid (`invalidReason`).
    public var roadFixPinCheck = 0
    /// On/off-road threshold of that comparison, metres (the constant-offset
    /// check's 15 m). Valid: finite, ≥ 0.
    public var roadFixPinOffRoadM = 15.0
    /// Least difference between A and B for a verdict, metres. Valid:
    /// finite, ≥ 0.
    public var roadFixPinMarginM = 10.0

    // MARK: Reporting

    /// `converged` once the circular heading std is under this, degrees.
    public var convergedHeadingStdDeg = 10.0

    public init() {}

    /// The default configuration with `seed` (the live app: one seed per
    /// recording, `NavigationSeed.derive(header:)`).
    public init(seed: UInt64) {
        self.init()
        self.seed = seed
    }
}

extension NavigationConfig {
    /// Every stored property, in declaration order. A new property must be
    /// added here, or it is neither encoded nor decoded
    /// (`NavigationConfigCodingTests` checks the list against the type).
    enum CodingKeys: String, CodingKey, CaseIterable {
        case particleCount, seed, stepHz, headingNoiseDegPerSqrtS
        case turnHeadingNoiseDegPerSqrtDeg, alongTrackNoisePerSqrtM, crossTrackNoisePerSqrtM, scaleNoisePerSqrtS
        case scalePriorMean, scalePriorStd, obdSpeedOffsetKmh, obdMaxAgeS
        case staleSpeedNoiseMpsPerSqrtS, staleSpeedDecayS, staleParkedMotionG, staleParkedMotionTauS
        case staleHeadingNoiseFactor, zuptFixGate, zuptFixGateMinSpeedMps, zuptFixGateMinFixes, zuptFixGateMaxAgeS
        case maxCatchUpSteps, extrapolationHorizonS, maxForwardJumpS
        case reanchorDistanceM, maxMotionGapS, fixSigmaPerAccuracy, fixSigmaFloorM
        case networkFixInflation, networkFixCorrelationS, staleFixSigmaGrowthMps, staleFixAgeS
        case maxFixAgeS, heldFixTimeoutS, courseMinSpeedMps, courseSigmaFloorDeg
        case speedUpdateMinKmh, gnssSpeedGateMps, gnssSpeedGateFraction, speedSigmaFloorMps
        case cleanFixAccM, reseedHeadingStdDeg, reseedNoSupportSigma, reseedFraction
        case manualFixSigmaMinM, manualFixSpanDivisor, manualFixReactionS, manualFixUnknownSpeedMps
        case manualFixResetChi2, lateManualFixWindowS
        case fixPinWindowS, fixPinTwoPinCheck, fixPinTwoPinMinPathM, fixPinTwoPinMinTurnDeg, fixPinInflation, fixPinRestoreS
        case resampleESSFraction, resampleHeadingJitterDeg, resampleScaleJitter, convergedHeadingStdDeg
        case roadUpdateIntervalS, roadSigmaM, roadHeadingSigmaDeg, roadHeadingGateDeg, roadSearchRadiusM
        case roadInnovationGateChi2, roadOffRoadProbability, roadCorrelationM, roadSplitSigmaM
        case roadEngageMaxEllipseM, roadAlongTrackCoupling, roadLevelHops, roadLevelForgetM
        case roadFixGateSigma, roadFixGateMinM, roadFixGateMinKmh, roadFixGateOnRoadShare, roadPinAnchorMinKmh
        case roadFixPinCheck, roadFixPinOffRoadM, roadFixPinMarginM
    }

    /// Decodes a config written by any earlier build (R11.2-4, R12.1-1): a
    /// key it did not have takes its default, so `metrics.json` rows and
    /// sidecar headers from before a key was added still decode. Unknown
    /// keys are ignored, as before. Encoding is the synthesized one (sorted
    /// keys in every encoder this package uses), so its bytes and
    /// `hashHex` are unchanged.
    ///
    /// The defaults are today's. A row that predates a key ran with that
    /// key's behaviour as it was then, which for a key added with a new
    /// mechanism is usually "off", not today's default; read an old row's
    /// config with that in mind.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        particleCount = try c.decodeIfPresent(type(of: particleCount), forKey: .particleCount) ?? particleCount
        seed = try c.decodeIfPresent(type(of: seed), forKey: .seed) ?? seed
        stepHz = try c.decodeIfPresent(type(of: stepHz), forKey: .stepHz) ?? stepHz
        headingNoiseDegPerSqrtS = try c.decodeIfPresent(type(of: headingNoiseDegPerSqrtS), forKey: .headingNoiseDegPerSqrtS) ?? headingNoiseDegPerSqrtS
        turnHeadingNoiseDegPerSqrtDeg = try c.decodeIfPresent(type(of: turnHeadingNoiseDegPerSqrtDeg), forKey: .turnHeadingNoiseDegPerSqrtDeg) ?? turnHeadingNoiseDegPerSqrtDeg
        alongTrackNoisePerSqrtM = try c.decodeIfPresent(type(of: alongTrackNoisePerSqrtM), forKey: .alongTrackNoisePerSqrtM) ?? alongTrackNoisePerSqrtM
        crossTrackNoisePerSqrtM = try c.decodeIfPresent(type(of: crossTrackNoisePerSqrtM), forKey: .crossTrackNoisePerSqrtM) ?? crossTrackNoisePerSqrtM
        scaleNoisePerSqrtS = try c.decodeIfPresent(type(of: scaleNoisePerSqrtS), forKey: .scaleNoisePerSqrtS) ?? scaleNoisePerSqrtS
        scalePriorMean = try c.decodeIfPresent(type(of: scalePriorMean), forKey: .scalePriorMean) ?? scalePriorMean
        scalePriorStd = try c.decodeIfPresent(type(of: scalePriorStd), forKey: .scalePriorStd) ?? scalePriorStd
        obdSpeedOffsetKmh = try c.decodeIfPresent(type(of: obdSpeedOffsetKmh), forKey: .obdSpeedOffsetKmh) ?? obdSpeedOffsetKmh
        obdMaxAgeS = try c.decodeIfPresent(type(of: obdMaxAgeS), forKey: .obdMaxAgeS) ?? obdMaxAgeS
        staleSpeedNoiseMpsPerSqrtS = try c.decodeIfPresent(type(of: staleSpeedNoiseMpsPerSqrtS), forKey: .staleSpeedNoiseMpsPerSqrtS) ?? staleSpeedNoiseMpsPerSqrtS
        staleSpeedDecayS = try c.decodeIfPresent(type(of: staleSpeedDecayS), forKey: .staleSpeedDecayS) ?? staleSpeedDecayS
        staleParkedMotionG = try c.decodeIfPresent(type(of: staleParkedMotionG), forKey: .staleParkedMotionG) ?? staleParkedMotionG
        staleParkedMotionTauS = try c.decodeIfPresent(type(of: staleParkedMotionTauS), forKey: .staleParkedMotionTauS) ?? staleParkedMotionTauS
        staleHeadingNoiseFactor = try c.decodeIfPresent(type(of: staleHeadingNoiseFactor), forKey: .staleHeadingNoiseFactor) ?? staleHeadingNoiseFactor
        zuptFixGate = try c.decodeIfPresent(type(of: zuptFixGate), forKey: .zuptFixGate) ?? zuptFixGate
        zuptFixGateMinSpeedMps = try c.decodeIfPresent(type(of: zuptFixGateMinSpeedMps), forKey: .zuptFixGateMinSpeedMps) ?? zuptFixGateMinSpeedMps
        zuptFixGateMinFixes = try c.decodeIfPresent(type(of: zuptFixGateMinFixes), forKey: .zuptFixGateMinFixes) ?? zuptFixGateMinFixes
        zuptFixGateMaxAgeS = try c.decodeIfPresent(type(of: zuptFixGateMaxAgeS), forKey: .zuptFixGateMaxAgeS) ?? zuptFixGateMaxAgeS
        maxCatchUpSteps = try c.decodeIfPresent(type(of: maxCatchUpSteps), forKey: .maxCatchUpSteps) ?? maxCatchUpSteps
        extrapolationHorizonS = try c.decodeIfPresent(type(of: extrapolationHorizonS), forKey: .extrapolationHorizonS) ?? extrapolationHorizonS
        maxForwardJumpS = try c.decodeIfPresent(type(of: maxForwardJumpS), forKey: .maxForwardJumpS) ?? maxForwardJumpS
        reanchorDistanceM = try c.decodeIfPresent(type(of: reanchorDistanceM), forKey: .reanchorDistanceM) ?? reanchorDistanceM
        maxMotionGapS = try c.decodeIfPresent(type(of: maxMotionGapS), forKey: .maxMotionGapS) ?? maxMotionGapS
        fixSigmaPerAccuracy = try c.decodeIfPresent(type(of: fixSigmaPerAccuracy), forKey: .fixSigmaPerAccuracy) ?? fixSigmaPerAccuracy
        fixSigmaFloorM = try c.decodeIfPresent(type(of: fixSigmaFloorM), forKey: .fixSigmaFloorM) ?? fixSigmaFloorM
        networkFixInflation = try c.decodeIfPresent(type(of: networkFixInflation), forKey: .networkFixInflation) ?? networkFixInflation
        networkFixCorrelationS = try c.decodeIfPresent(type(of: networkFixCorrelationS), forKey: .networkFixCorrelationS) ?? networkFixCorrelationS
        staleFixSigmaGrowthMps = try c.decodeIfPresent(type(of: staleFixSigmaGrowthMps), forKey: .staleFixSigmaGrowthMps) ?? staleFixSigmaGrowthMps
        staleFixAgeS = try c.decodeIfPresent(type(of: staleFixAgeS), forKey: .staleFixAgeS) ?? staleFixAgeS
        maxFixAgeS = try c.decodeIfPresent(type(of: maxFixAgeS), forKey: .maxFixAgeS) ?? maxFixAgeS
        heldFixTimeoutS = try c.decodeIfPresent(type(of: heldFixTimeoutS), forKey: .heldFixTimeoutS) ?? heldFixTimeoutS
        courseMinSpeedMps = try c.decodeIfPresent(type(of: courseMinSpeedMps), forKey: .courseMinSpeedMps) ?? courseMinSpeedMps
        courseSigmaFloorDeg = try c.decodeIfPresent(type(of: courseSigmaFloorDeg), forKey: .courseSigmaFloorDeg) ?? courseSigmaFloorDeg
        speedUpdateMinKmh = try c.decodeIfPresent(type(of: speedUpdateMinKmh), forKey: .speedUpdateMinKmh) ?? speedUpdateMinKmh
        gnssSpeedGateMps = try c.decodeIfPresent(type(of: gnssSpeedGateMps), forKey: .gnssSpeedGateMps) ?? gnssSpeedGateMps
        gnssSpeedGateFraction = try c.decodeIfPresent(type(of: gnssSpeedGateFraction), forKey: .gnssSpeedGateFraction) ?? gnssSpeedGateFraction
        speedSigmaFloorMps = try c.decodeIfPresent(type(of: speedSigmaFloorMps), forKey: .speedSigmaFloorMps) ?? speedSigmaFloorMps
        cleanFixAccM = try c.decodeIfPresent(type(of: cleanFixAccM), forKey: .cleanFixAccM) ?? cleanFixAccM
        reseedHeadingStdDeg = try c.decodeIfPresent(type(of: reseedHeadingStdDeg), forKey: .reseedHeadingStdDeg) ?? reseedHeadingStdDeg
        reseedNoSupportSigma = try c.decodeIfPresent(type(of: reseedNoSupportSigma), forKey: .reseedNoSupportSigma) ?? reseedNoSupportSigma
        reseedFraction = try c.decodeIfPresent(type(of: reseedFraction), forKey: .reseedFraction) ?? reseedFraction
        manualFixSigmaMinM = try c.decodeIfPresent(type(of: manualFixSigmaMinM), forKey: .manualFixSigmaMinM) ?? manualFixSigmaMinM
        manualFixSpanDivisor = try c.decodeIfPresent(type(of: manualFixSpanDivisor), forKey: .manualFixSpanDivisor) ?? manualFixSpanDivisor
        manualFixReactionS = try c.decodeIfPresent(type(of: manualFixReactionS), forKey: .manualFixReactionS) ?? manualFixReactionS
        manualFixUnknownSpeedMps = try c.decodeIfPresent(type(of: manualFixUnknownSpeedMps), forKey: .manualFixUnknownSpeedMps) ?? manualFixUnknownSpeedMps
        manualFixResetChi2 = try c.decodeIfPresent(type(of: manualFixResetChi2), forKey: .manualFixResetChi2) ?? manualFixResetChi2
        lateManualFixWindowS = try c.decodeIfPresent(type(of: lateManualFixWindowS), forKey: .lateManualFixWindowS) ?? lateManualFixWindowS
        fixPinWindowS = try c.decodeIfPresent(type(of: fixPinWindowS), forKey: .fixPinWindowS) ?? fixPinWindowS
        fixPinTwoPinCheck = try c.decodeIfPresent(type(of: fixPinTwoPinCheck), forKey: .fixPinTwoPinCheck) ?? fixPinTwoPinCheck
        fixPinTwoPinMinPathM = try c.decodeIfPresent(type(of: fixPinTwoPinMinPathM), forKey: .fixPinTwoPinMinPathM) ?? fixPinTwoPinMinPathM
        fixPinTwoPinMinTurnDeg = try c.decodeIfPresent(type(of: fixPinTwoPinMinTurnDeg), forKey: .fixPinTwoPinMinTurnDeg) ?? fixPinTwoPinMinTurnDeg
        fixPinInflation = try c.decodeIfPresent(type(of: fixPinInflation), forKey: .fixPinInflation) ?? fixPinInflation
        fixPinRestoreS = try c.decodeIfPresent(type(of: fixPinRestoreS), forKey: .fixPinRestoreS) ?? fixPinRestoreS
        resampleESSFraction = try c.decodeIfPresent(type(of: resampleESSFraction), forKey: .resampleESSFraction) ?? resampleESSFraction
        resampleHeadingJitterDeg = try c.decodeIfPresent(type(of: resampleHeadingJitterDeg), forKey: .resampleHeadingJitterDeg) ?? resampleHeadingJitterDeg
        resampleScaleJitter = try c.decodeIfPresent(type(of: resampleScaleJitter), forKey: .resampleScaleJitter) ?? resampleScaleJitter
        convergedHeadingStdDeg = try c.decodeIfPresent(type(of: convergedHeadingStdDeg), forKey: .convergedHeadingStdDeg) ?? convergedHeadingStdDeg
        roadUpdateIntervalS = try c.decodeIfPresent(type(of: roadUpdateIntervalS), forKey: .roadUpdateIntervalS) ?? roadUpdateIntervalS
        roadSigmaM = try c.decodeIfPresent(type(of: roadSigmaM), forKey: .roadSigmaM) ?? roadSigmaM
        roadHeadingSigmaDeg = try c.decodeIfPresent(type(of: roadHeadingSigmaDeg), forKey: .roadHeadingSigmaDeg) ?? roadHeadingSigmaDeg
        roadHeadingGateDeg = try c.decodeIfPresent(type(of: roadHeadingGateDeg), forKey: .roadHeadingGateDeg) ?? roadHeadingGateDeg
        roadSearchRadiusM = try c.decodeIfPresent(type(of: roadSearchRadiusM), forKey: .roadSearchRadiusM) ?? roadSearchRadiusM
        roadInnovationGateChi2 = try c.decodeIfPresent(type(of: roadInnovationGateChi2), forKey: .roadInnovationGateChi2) ?? roadInnovationGateChi2
        roadOffRoadProbability = try c.decodeIfPresent(type(of: roadOffRoadProbability), forKey: .roadOffRoadProbability) ?? roadOffRoadProbability
        roadCorrelationM = try c.decodeIfPresent(type(of: roadCorrelationM), forKey: .roadCorrelationM) ?? roadCorrelationM
        roadSplitSigmaM = try c.decodeIfPresent(type(of: roadSplitSigmaM), forKey: .roadSplitSigmaM) ?? roadSplitSigmaM
        roadEngageMaxEllipseM = try c.decodeIfPresent(type(of: roadEngageMaxEllipseM), forKey: .roadEngageMaxEllipseM) ?? roadEngageMaxEllipseM
        roadAlongTrackCoupling = try c.decodeIfPresent(type(of: roadAlongTrackCoupling), forKey: .roadAlongTrackCoupling) ?? roadAlongTrackCoupling
        roadLevelHops = try c.decodeIfPresent(type(of: roadLevelHops), forKey: .roadLevelHops) ?? roadLevelHops
        roadLevelForgetM = try c.decodeIfPresent(type(of: roadLevelForgetM), forKey: .roadLevelForgetM) ?? roadLevelForgetM
        roadFixGateSigma = try c.decodeIfPresent(type(of: roadFixGateSigma), forKey: .roadFixGateSigma) ?? roadFixGateSigma
        roadFixGateMinM = try c.decodeIfPresent(type(of: roadFixGateMinM), forKey: .roadFixGateMinM) ?? roadFixGateMinM
        roadFixGateMinKmh = try c.decodeIfPresent(type(of: roadFixGateMinKmh), forKey: .roadFixGateMinKmh) ?? roadFixGateMinKmh
        roadFixGateOnRoadShare = try c.decodeIfPresent(type(of: roadFixGateOnRoadShare), forKey: .roadFixGateOnRoadShare) ?? roadFixGateOnRoadShare
        roadPinAnchorMinKmh = try c.decodeIfPresent(type(of: roadPinAnchorMinKmh), forKey: .roadPinAnchorMinKmh) ?? roadPinAnchorMinKmh
        roadFixPinCheck = try c.decodeIfPresent(type(of: roadFixPinCheck), forKey: .roadFixPinCheck) ?? roadFixPinCheck
        roadFixPinOffRoadM = try c.decodeIfPresent(type(of: roadFixPinOffRoadM), forKey: .roadFixPinOffRoadM) ?? roadFixPinOffRoadM
        roadFixPinMarginM = try c.decodeIfPresent(type(of: roadFixPinMarginM), forKey: .roadFixPinMarginM) ?? roadFixPinMarginM
    }
}

extension NavigationConfig {
    /// Largest `extrapolationHorizonS` the engine uses, s. A larger value
    /// (an absurd `--set`) would overflow the nanosecond arithmetic in
    /// `estimate(at:)` (B0-1); an hour is far beyond any sensible horizon.
    public static let maxExtrapolationHorizonS = 3_600.0
    /// Largest `lateManualFixWindowS`, s: the ring's memory grows with it
    /// (60 s at 10 Hz and 2000 particles is about 29 MB).
    public static let maxLateManualFixWindowS = 60.0
    /// Largest `roadUpdateIntervalS`, s (R21.1-7). A larger value (an
    /// absurd `--set`) would overflow the nanosecond interval the engine
    /// keeps; an hour is far beyond any sensible interval.
    public static let maxRoadUpdateIntervalS = 3_600.0
    /// Largest `fixPinWindowS`, s: the per-source fix rings hold this much
    /// of each GNSS stream (about 1 fix/s).
    public static let maxFixPinWindowS = 3_600.0

    /// This configuration with values the engine cannot use safely clamped
    /// (B0-1). `NavigationEngine.init` applies it, so `engine.config` is the
    /// validated value. Every default is already valid: `validated()` of a
    /// default config is the same config.
    /// - `extrapolationHorizonS`: into 0…`maxExtrapolationHorizonS`; a
    ///   non-finite value becomes the default.
    /// - `maxForwardJumpS`: a non-finite or non-positive value becomes the
    ///   default (there is no "off": an infinite jump is never plausible).
    /// - `lateManualFixWindowS`: into 0…`maxLateManualFixWindowS`; a
    ///   non-finite value becomes the default.
    public func validated(roads: RoadNetwork? = nil) -> NavigationConfig {
        var config = self
        let defaults = NavigationConfig()
        if !config.extrapolationHorizonS.isFinite {
            config.extrapolationHorizonS = defaults.extrapolationHorizonS
        }
        config.extrapolationHorizonS = min(max(config.extrapolationHorizonS, 0), Self.maxExtrapolationHorizonS)
        if !(config.maxForwardJumpS.isFinite && config.maxForwardJumpS > 0) {
            config.maxForwardJumpS = defaults.maxForwardJumpS
        }
        if !config.lateManualFixWindowS.isFinite {
            config.lateManualFixWindowS = defaults.lateManualFixWindowS
        }
        config.lateManualFixWindowS = min(max(config.lateManualFixWindowS, 0), Self.maxLateManualFixWindowS)
        config.validateRoads(defaults: defaults, roads: roads)
        return config
    }

    /// The road keys (N3.2): `roadUpdateIntervalS` to 0 or into one grid
    /// step…`maxRoadUpdateIntervalS` (R21.1-7); probabilities into (0, 1);
    /// σ, gates and radii that are not finite and positive become the
    /// default (as `maxForwardJumpS`); the "0 disables" keys and the other
    /// limits to ≥ 0, a non-finite one to the default; `roadSearchRadiusM`
    /// to the packs' guaranteed radius. `roadAlongTrackCoupling` is not
    /// clamped: see `invalidReason`.
    private mutating func validateRoads(defaults: NavigationConfig, roads: RoadNetwork?) {
        if !roadUpdateIntervalS.isFinite { roadUpdateIntervalS = defaults.roadUpdateIntervalS }
        if roadUpdateIntervalS <= 0 {
            roadUpdateIntervalS = 0
        } else {
            if stepHz > 0 { roadUpdateIntervalS = max(roadUpdateIntervalS, 1 / stepHz) }
            roadUpdateIntervalS = min(roadUpdateIntervalS, Self.maxRoadUpdateIntervalS)
        }
        let probability = 1e-9
        for key in [\NavigationConfig.roadOffRoadProbability, \.roadFixGateOnRoadShare] {
            if !self[keyPath: key].isFinite { self[keyPath: key] = defaults[keyPath: key] }
            self[keyPath: key] = min(max(self[keyPath: key], probability), 1 - probability)
        }
        for key in [\NavigationConfig.roadSigmaM, \.roadHeadingSigmaDeg, \.roadHeadingGateDeg, \.roadSearchRadiusM,
                    \.roadInnovationGateChi2, \.roadCorrelationM, \.roadSplitSigmaM, \.roadEngageMaxEllipseM,
                    \.roadFixGateMinM] where !(self[keyPath: key].isFinite && self[keyPath: key] > 0) {
            self[keyPath: key] = defaults[keyPath: key]
        }
        for key in [\NavigationConfig.roadLevelForgetM, \.roadFixGateSigma, \.roadFixGateMinKmh, \.roadPinAnchorMinKmh] {
            if !self[keyPath: key].isFinite { self[keyPath: key] = defaults[keyPath: key] }
            self[keyPath: key] = max(self[keyPath: key], 0)
        }
        roadLevelHops = max(roadLevelHops, 0)
        if let roads { roadSearchRadiusM = min(roadSearchRadiusM, roads.grid.searchRadiusM) }
    }

    /// Why the engine cannot run this configuration, or nil. Unlike the
    /// values `validated()` clamps, these are refused: `NavigationEngine`
    /// traps on them (as on a non-positive `particleCount`), and a replay
    /// reports them before it starts.
    /// - `roadAlongTrackCoupling` outside 0…1 (or not a number): the Joseph
    ///   form stays consistent for any gain, but a coupling outside the
    ///   Schmidt…Kalman range is a mistake, not a setting.
    /// - The OBD-zero fix gate's keys (N4B1-1): `zuptFixGate` other than 0
    ///   or 1, `zuptFixGateMinSpeedMps` not > 0, `zuptFixGateMinFixes`
    ///   under 1, `zuptFixGateMaxAgeS` negative; any not finite.
    /// - The pin-vs-source keys (N3-FIXPIN): `roadFixPinCheck` and
    ///   `fixPinTwoPinCheck` other than 0 or 1 (switches, not weights);
    ///   `fixPinWindowS` outside (0, `maxFixPinWindowS`]; `fixPinInflation`
    ///   not > 0; `fixPinTwoPinMinTurnDeg` outside 0…360; the other
    ///   distances and times negative; any of them not finite. Refused,
    ///   not clamped: a mistyped `--set` must not run as something else.
    public var invalidReason: String? {
        if !(roadAlongTrackCoupling >= 0 && roadAlongTrackCoupling <= 1) {
            return "roadAlongTrackCoupling must be in 0…1, got \(roadAlongTrackCoupling)"
        }
        return fixPinInvalidReason ?? zuptFixGateInvalidReason
    }

    /// The OBD-zero fix gate's keys (N4B1-1): refused, not clamped, like the
    /// pin-vs-source keys.
    private var zuptFixGateInvalidReason: String? {
        if zuptFixGate != 0 && zuptFixGate != 1 {
            return "zuptFixGate must be 0 or 1, got \(zuptFixGate)"
        }
        if !(zuptFixGateMinSpeedMps > 0 && zuptFixGateMinSpeedMps.isFinite) {
            return "zuptFixGateMinSpeedMps must be finite and > 0, got \(zuptFixGateMinSpeedMps)"
        }
        if zuptFixGateMinFixes < 1 {
            return "zuptFixGateMinFixes must be ≥ 1, got \(zuptFixGateMinFixes)"
        }
        if !(zuptFixGateMaxAgeS >= 0 && zuptFixGateMaxAgeS.isFinite) {
            return "zuptFixGateMaxAgeS must be finite and ≥ 0, got \(zuptFixGateMaxAgeS)"
        }
        return nil
    }

    private var fixPinInvalidReason: String? {
        if roadFixPinCheck != 0 && roadFixPinCheck != 1 {
            return "roadFixPinCheck must be 0 or 1, got \(roadFixPinCheck)"
        }
        if fixPinTwoPinCheck != 0 && fixPinTwoPinCheck != 1 {
            return "fixPinTwoPinCheck must be 0 or 1, got \(fixPinTwoPinCheck)"
        }
        if !(fixPinWindowS > 0 && fixPinWindowS <= Self.maxFixPinWindowS) {
            return "fixPinWindowS must be in (0, \(Self.maxFixPinWindowS)], got \(fixPinWindowS)"
        }
        if !(fixPinInflation > 0 && fixPinInflation.isFinite) {
            return "fixPinInflation must be finite and > 0, got \(fixPinInflation)"
        }
        if !(fixPinTwoPinMinTurnDeg >= 0 && fixPinTwoPinMinTurnDeg <= 360) {
            return "fixPinTwoPinMinTurnDeg must be in 0…360, got \(fixPinTwoPinMinTurnDeg)"
        }
        for (name, value) in [("fixPinTwoPinMinPathM", fixPinTwoPinMinPathM), ("fixPinRestoreS", fixPinRestoreS),
                              ("roadFixPinOffRoadM", roadFixPinOffRoadM), ("roadFixPinMarginM", roadFixPinMarginM)]
            where !(value >= 0 && value.isFinite) {
            return "\(name) must be finite and ≥ 0, got \(value)"
        }
        return nil
    }

    /// The keys whose values differ between `self` and `other`, sorted
    /// (values compared as their canonical JSON). Empty when equal.
    public func differingKeys(_ other: NavigationConfig) -> [String] {
        func object(_ config: NavigationConfig) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: config.canonicalJSON())) as? [String: Any] ?? [:]
        }
        let a = object(self), b = object(other)
        // Iterates the declared key list (an array), never the dictionaries.
        return CodingKeys.allCases.map(\.rawValue).filter { key in
            switch (a[key] as? NSObject, b[key] as? NSObject) {
            case let (x?, y?): return !x.isEqual(y)
            case (nil, nil): return false
            default: return true
            }
        }.sorted()
    }

    /// The road keys (N3.2): without a road network the engine runs no road
    /// code, so these change nothing (`replay_nav --compare` names them as
    /// inert when no roads are in use, N3-CMPHASH).
    public static let roadOnlyKeys: [String] = CodingKeys.allCases.map(\.rawValue).filter { $0.hasPrefix("road") }

    /// Compact JSON with sorted keys: byte-stable for the same values, so
    /// it can be hashed (`hashHex`). Non-finite numbers are written as the
    /// strings "inf", "-inf" and "nan".
    public func canonicalJSON() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        // Encoding a struct of numbers cannot fail with that strategy.
        return (try? encoder.encode(self)) ?? Data()
    }

    /// 64-bit FNV-1a of `canonicalJSON()`, as 16 lowercase hex digits: the
    /// navigation sidecar's config hash.
    public var hashHex: String {
        NavigationSeed.hex(NavigationSeed.fnv1a64(canonicalJSON()))
    }
}

extension NavigationConfig {
    /// σ of a manual fix, metres: max(`manualFixSigmaMinM`,
    /// mapSpanM / `manualFixSpanDivisor`), or `manualFixSigmaMinM` when the
    /// span is missing, not finite or not positive. In heading-up
    /// a span logged before M10.1-3 is the rotated viewport's bounding box,
    /// between ~0.5× and ~1.15× the viewport height (smallest near east/west
    /// headings), so it can understate the span and give too small a σ.
    public func manualFixSigma(mapSpanM: Double?) -> Double {
        guard let span = mapSpanM, span.isFinite, span > 0, manualFixSpanDivisor > 0 else {
            return manualFixSigmaMinM
        }
        return max(manualFixSigmaMinM, span / manualFixSpanDivisor)
    }

    /// σ of a manual fix ingested at `t`, metres (N4MF-1):
    /// √(manualFixSigma(mapSpanM:)² + (v · (τ + max(0, t − pressedT)))²),
    /// τ = `manualFixReactionS`. v = `gateSpeedKmh` / 3.6 when
    /// `speedSource` is `obd` or `gps` and the speed is usable, else
    /// `manualFixUnknownSpeedMps`. Old long-press rows keep their confirm
    /// delay t − pressedT in the allowance. This is the σ the engine
    /// ingests; the replay scores pins with its own frozen truth σ
    /// (`NavigationReplay.manualFixTruthSigmaM`), which this does not move.
    public func manualFixSigma(_ sample: ManualFixSample, at t: MonotonicTimestamp) -> Double {
        let base = manualFixSigma(mapSpanM: sample.mapSpanM)
        let source = ManualFixSample.SpeedSource(rawValue: sample.speedSource)
        var v = manualFixUnknownSpeedMps
        if source == .obd || source == .gps, let kmh = sample.gateSpeedKmh, kmh.isFinite, kmh >= 0 {
            v = kmh / 3.6
        }
        let delay = max(0, (Double(t.nanoseconds) - Double(sample.pressedT.nanoseconds)) / 1e9)
        let travelled = max(0, v) * (max(0, manualFixReactionS) + (delay.isFinite ? delay : 0))
        guard travelled.isFinite, travelled > 0 else { return base }
        return (base * base + travelled * travelled).squareRoot()
    }
}
