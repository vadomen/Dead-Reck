import Foundation

/// Causal, deterministic dead-reckoning estimator: a particle filter over
/// heading and OBD speed scale, with a Gaussian position per particle
/// (Rao-Blackwellised: each particle's position is a mean and a 2×2
/// covariance updated by a Kalman step, not a sample).
///
/// Why positions are not sampled: a position-only update (a fix while
/// stopped, a manual pin) would then reweight particles by their random
/// position offsets, and resampling would discard heading hypotheses nothing
/// had measured — on the replay set the heading std collapsed to 1° with no
/// heading information at all. With a Gaussian per particle those updates
/// reweight only by what the heading and scale actually predict.
///
/// Feed it `NavigationInput`s in arrival order with `ingest(_:)`; read the
/// belief with `estimate(at:)`. It never looks ahead: every decision uses
/// only inputs already ingested, so the state after a prefix of the input is
/// the same whatever follows (the causality tests check this). All
/// randomness comes from one `NavigationRandom` seeded by `config.seed`.
///
/// **Prediction** runs on a 10 Hz grid on the session clock. Yaw is
/// `rotationRate · ĝ` (ĝ = normalised gravity), integrated over the real
/// motion-sample intervals; positive is clockwise from above, like a compass
/// bearing. CoreMotion's rate is already bias-corrected; no bias is
/// estimated here. Speed is OBD 0x0D from ECU `7E8` (or none, v1) held
/// between replies, `v + 0.5` km/h when `v > 0`, times each particle's scale.
/// A *fresh* OBD zero (≤ `obdMaxAgeS` old) freezes heading and position
/// (zero-velocity update). A stale reading after an OBD 0, with no IMU sign
/// of motion since, is parked: frozen the same way. Any other stale reading
/// is unknown speed: each particle's speed error follows a mean-reverting
/// Ornstein–Uhlenbeck process and heading noise grows.
///
/// **Catch-up**: an `ingest` after a long silence of every input (the app
/// suspended, a gap in a file) runs fresh-OBD steps one by one, as always;
/// beyond `maxCatchUpSteps` stale grid steps it folds a parked stretch in
/// O(1) (bit-identical to stepping it) and splits an unknown-speed stretch
/// into at most `maxCatchUpSteps` macro steps with the exact OU
/// discretisation (R13.1-6).
///
/// **Updates**: location fixes (per-axis σ = accuracy / 1.51, floored;
/// network fixes — any fix without a valid speed — tempered for their
/// minutes-long correlated errors), GNSS
/// course and speed when valid and consistent with OBD speed, and manual
/// "I'm here" fixes, which also reset positions when the cloud has no
/// support at the pin. A clean fix reseeds part of the cloud around its
/// course while heading is unknown or when no particle agrees with it.
///
/// Fix latency: a v2/v3 fix's `t` is earlier than its arrival. The fix is
/// compared after shifting it by the engine's own mean displacement since
/// `t`, from a short history of cumulative mean motion — causal and without
/// per-particle history.
///
/// **Held stale fix** (N4B-1): a stale fix (older than `maxFixAgeS`) is
/// used only while the car is stopped. When it arrives before OBD can say
/// so — no OBD reply yet, or only a stale one — it is held, not dropped,
/// and the first OBD reply that is fresh at its arrival decides: 0 applies
/// it as if it had arrived then, moving drops it, and no such reply within
/// `heldFixTimeoutS` drops it. At most one fix is held; a newer one
/// replaces it. Live, the pre-session fix is written before the first OBD
/// 0, whose row lands up to 0.27 s after its own `t`; holding makes file
/// order and arrival order agree.
public struct NavigationEngine: Sendable {
    public let config: NavigationConfig

    private var rng: NavigationRandom

    // Particle state, structure of arrays. Position mean and covariance
    // (east/north, metres, m²), heading in radians [0, 2π).
    var east: [Double] = []
    var north: [Double] = []
    var covEE: [Double] = []
    var covEN: [Double] = []
    var covNN: [Double] = []
    var heading: [Double] = []
    var scale: [Double] = []
    /// Speed error while OBD is stale and the car is not parked, m/s
    /// (Ornstein–Uhlenbeck, `staleSpeedDecayS`); 0 otherwise.
    var speedOffset: [Double] = []
    /// Normalised: logsumexp(logWeight) == 0.
    var logWeight: [Double] = []
    /// exp(logWeight), sums to 1.
    var weight: [Double] = []
    private(set) var effectiveSampleSize = 0.0

    /// The local plane, set at initialisation from the first accepted
    /// position.
    public private(set) var tangentPlane: LocalTangentPlane?
    public var isInitialized: Bool { tangentPlane != nil }
    public private(set) var counters = NavigationCounters()

    // Clock: the last grid instant stepped to, in session nanoseconds.
    private let stepNs: Int64
    private var lastStepNs: Int64?

    // Gyro accumulation between steps.
    private var lastMotionNs: Int64?
    private var pendingYaw = 0.0
    private var lastYawRate = 0.0

    // OBD vehicle speed, held between replies.
    private var obdSpeedKmh: Double?
    private var obdNs: Int64?
    private var speedOffsetsActive = false
    /// Armed by every OBD 0 reply; cleared by IMU motion evidence. A stale
    /// step while armed is parked (R13.1-2).
    private var parkedSinceZero = false
    private var motionEMA = Vector3.zero
    private var lastMotionEMANs: Int64?

    // Last step, for extrapolation in `estimate(at:)`.
    private var lastStepStationary = true
    private var lastMeanSpeed = 0.0

    // Cumulative mean motion, for shifting late fixes to the present.
    private var cumulativeEast = 0.0
    private var cumulativeNorth = 0.0
    private var cumulativeYaw = 0.0
    private var history: MotionHistory

    private var lastNetworkFixNs: Int64?

    /// A stale fix waiting for OBD to say whether the car is stopped
    /// (N4B-1). At most one: see `holdStaleFix`.
    private struct HeldFix: Sendable {
        var sample: LocationSample
        var fixNs: Int64
        var arrivalNs: Int64
    }
    private var heldFix: HeldFix?
    /// Whether a stale fix is held, waiting for a fresh OBD reply.
    public var hasHeldFix: Bool { heldFix != nil }

    // Implausible forward time jumps (B0-1): the latest accepted arrival,
    // and the arrival of the last input rejected as a jump.
    private var lastInputNs: Int64?
    private var jumpCandidateNs: Int64?

    /// A rejected forward jump is confirmed as a real resume (the app
    /// suspended for longer than `maxForwardJumpS`) when the next input
    /// beyond the limit arrives within this many seconds of it.
    public static let forwardJumpConfirmS = 10.0

    /// The primary ECU whose vehicle speed is used.
    public static let primaryECU = "7E8"

    /// `config` is validated first (`NavigationConfig.validated()`); the
    /// engine's `config` is the validated value.
    public init(config: NavigationConfig = NavigationConfig()) {
        let config = config.validated()
        precondition(config.particleCount > 0, "particleCount must be positive")
        precondition(config.stepHz > 0, "stepHz must be positive")
        self.config = config
        rng = NavigationRandom(seed: config.seed)
        stepNs = Int64((1_000_000_000 / config.stepHz).rounded())
        history = MotionHistory(capacity: Int((config.maxFixAgeS * config.stepHz).rounded(.up)) + 2)
    }

    // MARK: Ingest

    /// Ingests one input, in arrival order. An implausible forward time jump
    /// is rejected and counted instead (`accepts(_:)`).
    public mutating func ingest(_ input: NavigationInput) {
        let arrival = input.arrival.nanoseconds
        guard accepts(input) else {
            counters.inputsRejectedTimeJump += 1
            jumpCandidateNs = arrival
            return
        }
        jumpCandidateNs = nil
        lastInputNs = max(lastInputNs ?? arrival, arrival)
        expireHeldFix(at: arrival)
        switch input {
        case .motion(let sample, let t):
            ingestMotion(sample, at: t.nanoseconds)
        case .obd(let sample, let t):
            advance(to: t.nanoseconds)
            if ingestOBD(sample, at: t.nanoseconds) {
                resolveHeldFix(obdNs: t.nanoseconds)
            }
        case .location(let sample, let t):
            let arrival = input.arrival.nanoseconds
            advance(to: arrival)
            ingestLocation(sample, fixNs: t.nanoseconds, arrivalNs: arrival)
        case .manualFix(let sample, let t):
            advance(to: t.nanoseconds)
            ingestManualFix(sample, at: t.nanoseconds)
        }
    }

    /// Whether `ingest` would take `input` rather than reject it as an
    /// implausible forward time jump (B0-1). Rejected: an input arriving
    /// more than `maxForwardJumpS` after the latest accepted arrival — a
    /// corrupt `t` would otherwise move the engine clock there, and every
    /// later input would be in the past. Accepted anyway: the second of two
    /// such inputs within `forwardJumpConfirmS` of each other, which is a
    /// real resume after a long silence, not one corrupt value. The first
    /// input of all is always accepted (nothing to compare it with). Does
    /// not change the engine.
    public func accepts(_ input: NavigationInput) -> Bool {
        let arrival = input.arrival.nanoseconds
        guard let last = lastInputNs else { return true }
        let limitNs = config.maxForwardJumpS * 1e9
        // In Double: a corrupt `t` must not overflow the subtraction.
        guard Double(arrival) - Double(last) > limitNs else { return true }
        if let candidate = jumpCandidateNs,
           abs(Double(arrival) - Double(candidate)) <= Self.forwardJumpConfirmS * 1e9 {
            return true
        }
        return false
    }

    /// Runs every grid step at or before `ns`. Steps with fresh OBD speed
    /// always run one by one. Once OBD is stale and more than
    /// `maxCatchUpSteps` grid steps remain, the rest is caught up in bounded
    /// work (`catchUp`), so a long silence of every input — the app
    /// suspended, a gap in a file, a corrupt huge `t` — cannot block the
    /// caller (R13.1-6). Ordinary 10 Hz input never takes that path: motion
    /// samples alone step the grid every few milliseconds.
    private mutating func advance(to ns: Int64) {
        guard let last = lastStepNs else {
            lastStepNs = Self.floorToGrid(ns, stepNs)
            return
        }
        let target = Self.floorToGrid(ns, stepNs)
        guard target > last else { return }
        guard isInitialized else {
            // Before initialisation a step only moves the clock and drops
            // the pending yaw: jump straight to the target.
            lastStepNs = target
            pendingYaw = 0
            return
        }
        var next = last + stepNs
        while next <= target {
            // Both on the grid: divide first, so a huge `t` cannot overflow.
            let remaining = Int(target / stepNs - next / stepNs) + 1
            if remaining > max(1, config.maxCatchUpSteps) && !isFresh(at: next) {
                catchUp(from: next, steps: remaining)
                return
            }
            step(at: next)
            next += stepNs
        }
    }

    /// OBD speed at most `obdMaxAgeS` old at `ns` (the same test as `step`).
    private func isFresh(at ns: Int64) -> Bool {
        guard obdSpeedKmh != nil, let t = obdNs else { return false }
        return Double(ns - t) / 1e9 <= config.obdMaxAgeS
    }

    /// Catches up `count` stale grid steps, the first at `first`, without
    /// running them one by one. Nothing that `step` reads changes between
    /// inputs, and OBD stays stale, so every step would take the same branch:
    /// - parked: each step only counts and records history, so the stretch
    ///   is folded in O(1) plus the last `history.capacity` entries —
    ///   bit-identical to stepping it;
    /// - unknown speed: split into at most `maxCatchUpSteps` macro steps of
    ///   equal whole grid steps (`macroStep`).
    private mutating func catchUp(from first: Int64, steps count: Int) {
        if parkedSinceZero {
            counters.steps += count
            counters.staleParkedSteps += count
            counters.coalescedSteps += count
            lastStepStationary = true
            lastMeanSpeed = 0
            for k in max(0, count - history.capacity)..<count {
                history.append(first + Int64(k) * stepNs, cumulativeEast, cumulativeNorth, cumulativeYaw, speed: nil)
            }
            lastStepNs = first + Int64(count - 1) * stepNs
            pendingYaw = 0
            return
        }
        let macroCount = max(1, config.maxCatchUpSteps)
        let perMacro = (count + macroCount - 1) / macroCount
        var done = 0
        while done < count {
            let length = min(perMacro, count - done)
            macroStep(at: first + Int64(done + length - 1) * stepNs, gridSteps: length)
            done += length
        }
    }

    static func floorToGrid(_ ns: Int64, _ step: Int64) -> Int64 {
        let q = ns / step
        let r = ns % step
        return (r < 0 ? q - 1 : q) * step
    }

    private mutating func ingestMotion(_ sample: MotionSample, at ns: Int64) {
        observeAcceleration(sample, at: ns)
        let rate = Self.yawRate(sample)
        defer {
            lastMotionNs = max(lastMotionNs ?? ns, ns)
            lastYawRate = rate ?? 0
        }
        guard let rate, let previous = lastMotionNs, ns > previous,
              Double(ns - previous) / 1e9 <= config.maxMotionGapS else {
            advance(to: ns)
            return
        }
        guard let last = lastStepNs else {
            advance(to: ns)
            return
        }
        // Split the sample's interval at grid instants so each step gets the
        // yaw of its own interval.
        var from = previous
        var next = last + stepNs
        while next <= ns {
            if next > from {
                pendingYaw += rate * Double(next - from) / 1e9
                from = next
            }
            step(at: next)
            next += stepNs
        }
        pendingYaw += rate * Double(ns - from) / 1e9
    }

    /// Yaw rate in rad/s, clockwise from above positive: the rotation rate
    /// projected on the downward gravity direction. nil if gravity is
    /// degenerate.
    static func yawRate(_ sample: MotionSample) -> Double? {
        let g = sample.gravity
        let magnitude = g.magnitude
        guard magnitude > 0.5, magnitude.isFinite else { return nil }
        let r = sample.rotationRate
        let value = (r.x * g.x + r.y * g.y + r.z * g.z) / magnitude
        return value.isFinite ? value : nil
    }

    /// Takes a vehicle-speed reply from the primary ECU; returns whether it
    /// was one (anything else is ignored).
    @discardableResult
    private mutating func ingestOBD(_ sample: OBDSample, at ns: Int64) -> Bool {
        guard sample.pid == .vehicleSpeed,
              sample.ecu == nil || sample.ecu == Self.primaryECU,
              sample.value.isFinite, sample.value >= 0 else { return false }
        obdSpeedKmh = sample.value
        obdNs = ns
        parkedSinceZero = sample.value == 0
        // A fresh 0 says the car is stopped now: braking deceleration still
        // in the EMA is not evidence of motion since (R13.2-2).
        if sample.value == 0 { motionEMA = .zero }
        return true
    }

    /// Updates the horizontal-acceleration EMA and clears the parked latch
    /// when it shows the car moving.
    private mutating func observeAcceleration(_ sample: MotionSample, at ns: Int64) {
        let g = sample.gravity
        let magnitude = g.magnitude
        guard magnitude > 0.5, magnitude.isFinite else { return }
        let gx = g.x / magnitude, gy = g.y / magnitude, gz = g.z / magnitude
        let u = sample.userAcceleration
        let along = u.x * gx + u.y * gy + u.z * gz
        let h = Vector3(x: u.x - along * gx, y: u.y - along * gy, z: u.z - along * gz)
        guard h.x.isFinite, h.y.isFinite, h.z.isFinite else { return }
        // Never backwards: an out-of-order sample must not give the next
        // one a long dt and a large gain (R13.2-3).
        defer { lastMotionEMANs = max(lastMotionEMANs ?? ns, ns) }
        guard let last = lastMotionEMANs, ns > last else { return }
        let dt = min(Double(ns - last) / 1e9, config.maxMotionGapS)
        let a = 1 - exp(-dt / config.staleParkedMotionTauS)
        motionEMA = Vector3(x: motionEMA.x + a * (h.x - motionEMA.x),
                            y: motionEMA.y + a * (h.y - motionEMA.y),
                            z: motionEMA.z + a * (h.z - motionEMA.z))
        if parkedSinceZero && motionEMA.magnitude > config.staleParkedMotionG {
            parkedSinceZero = false
        }
    }

    /// Fresh OBD zero at `ns`: the car is known to be stopped.
    private func isStopped(at ns: Int64) -> Bool {
        guard let v = obdSpeedKmh, let t = obdNs else { return false }
        return v == 0 && Double(ns - t) / 1e9 <= config.obdMaxAgeS
    }

    // MARK: Predict

    private mutating func step(at ns: Int64) {
        let dt = Double(ns - (lastStepNs ?? ns)) / 1e9
        lastStepNs = ns
        let yaw = pendingYaw
        pendingYaw = 0
        guard isInitialized else { return }
        counters.steps += 1

        var fresh = false
        var vObd = 0.0
        if let v = obdSpeedKmh, let t = obdNs {
            fresh = Double(ns - t) / 1e9 <= config.obdMaxAgeS
            vObd = v > 0 ? (v + config.obdSpeedOffsetKmh) / 3.6 : 0
        }
        if fresh && vObd == 0 {
            // Zero-velocity update: nothing moves, no noise. Speed is known
            // again, so a past dropout's speed errors end here too (only
            // touched when set: the steady stop stays loop-free).
            if speedOffsetsActive { resetSpeedOffsets() }
            counters.zuptSteps += 1
            lastStepStationary = true
            lastMeanSpeed = 0
            history.append(ns, cumulativeEast, cumulativeNorth, cumulativeYaw, speed: 0)
            return
        }
        let stale = !fresh
        if stale && parkedSinceZero {
            // Stale after a stop with no sign of motion since: parked.
            counters.staleParkedSteps += 1
            lastStepStationary = true
            lastMeanSpeed = 0
            history.append(ns, cumulativeEast, cumulativeNorth, cumulativeYaw, speed: nil)
            return
        }
        if stale {
            counters.staleSpeedSteps += 1
            speedOffsetsActive = true
        } else if speedOffsetsActive {
            resetSpeedOffsets()
        }

        let sqrtDt = dt.squareRoot()
        // Time-driven random walk (grown while speed is unknown) plus a
        // part proportional to √(angle turned this step).
        let timeNoise = config.headingNoiseDegPerSqrtS * sqrtDt * (stale ? config.staleHeadingNoiseFactor : 1)
        let turnVariance = config.turnHeadingNoiseDegPerSqrtDeg * config.turnHeadingNoiseDegPerSqrtDeg
            * abs(yaw) * 180 / .pi
        let sigmaHeading = (timeNoise * timeNoise + turnVariance).squareRoot() * .pi / 180
        let sigmaScale = config.scaleNoisePerSqrtS * sqrtDt
        // Ornstein–Uhlenbeck: offset ← a·offset + σ_ss·√(1 − a²)·n, which is
        // the random walk σ·√dt for dt ≪ τ.
        let decay = config.staleSpeedDecayS > 0 ? exp(-dt / config.staleSpeedDecayS) : 1
        let sigmaOffset = config.staleSpeedDecayS > 0
            ? config.staleSpeedNoiseMpsPerSqrtS * (config.staleSpeedDecayS / 2 * (1 - decay * decay)).squareRoot()
            : config.staleSpeedNoiseMpsPerSqrtS * sqrtDt
        let alongPerM = config.alongTrackNoisePerSqrtM * config.alongTrackNoisePerSqrtM
        let crossPerM = config.crossTrackNoisePerSqrtM * config.crossTrackNoisePerSqrtM

        var meanDEast = 0.0, meanDNorth = 0.0, meanSpeed = 0.0
        for i in 0..<east.count {
            let (n1, n2) = rng.nextGaussianPair()
            let dHeading = yaw + sigmaHeading * n1
            var speed = vObd * scale[i]
            if stale {
                speedOffset[i] = decay * speedOffset[i] + sigmaOffset * rng.nextGaussian()
                speed += speedOffset[i]
            }
            let (dEast, dNorth) = move(i, dHeading: dHeading, distance: speed * dt, scaleStep: sigmaScale * n2,
                                       alongPerM: alongPerM, crossPerM: crossPerM)
            let w = weight[i]
            meanDEast += w * dEast
            meanDNorth += w * dNorth
            meanSpeed += w * speed
        }
        cumulativeEast += meanDEast
        cumulativeNorth += meanDNorth
        cumulativeYaw += yaw
        lastStepStationary = false
        lastMeanSpeed = meanSpeed
        history.append(ns, cumulativeEast, cumulativeNorth, cumulativeYaw, speed: fresh ? vObd : nil)
        if counters.steps % reanchorCheckSteps == 0 {
            reanchorIfNeeded()
        }
    }

    /// Moving steps between re-anchor checks (10 s).
    private var reanchorCheckSteps: Int { Int(max(1, (config.stepHz * 10).rounded())) }

    /// Moves particle `i` by `distance` metres along its heading at the
    /// step's midpoint, turns it by `dHeading`, grows its position
    /// covariance with the distance and steps its scale. Returns the
    /// displacement (east, north).
    @inline(__always)
    private mutating func move(
        _ i: Int, dHeading: Double, distance: Double, scaleStep: Double, alongPerM: Double, crossPerM: Double
    ) -> (Double, Double) {
        let twoPi = 2 * Double.pi
        let midHeading = heading[i] + 0.5 * dHeading
        let s = sin(midHeading), c = cos(midHeading)
        let dEast = distance * s
        let dNorth = distance * c
        east[i] += dEast
        north[i] += dNorth
        // Along- and cross-track noise grow the position covariance in
        // proportion to the distance travelled.
        let qAlong = alongPerM * abs(distance)
        let qCross = crossPerM * abs(distance)
        covEE[i] += qAlong * s * s + qCross * c * c
        covNN[i] += qAlong * c * c + qCross * s * s
        covEN[i] += (qAlong - qCross) * s * c
        var h = heading[i] + dHeading
        if h >= twoPi { h -= twoPi } else if h < 0 { h += twoPi }
        if !(h >= 0 && h < twoPi) { h = Self.wrap2Pi(h) }  // only after a huge step
        heading[i] = h
        scale[i] += scaleStep
        return (dEast, dNorth)
    }

    /// One unknown-speed step over `gridSteps` grid steps ending at `ns`
    /// (catch-up after a long silence of every input). Same model as a
    /// stale `step`, discretised exactly for a long dt: the speed error
    /// and its integral over the step are drawn jointly from the
    /// Ornstein–Uhlenbeck transition, so the distance carries the
    /// integrated error, not the end value × dt (which would overstate the
    /// spread by ≈ √(dt/τ) for dt ≫ τ). Heading and scale random walks are
    /// exact for any dt.
    private mutating func macroStep(at ns: Int64, gridSteps: Int) {
        let dt = Double(ns - (lastStepNs ?? ns)) / 1e9
        lastStepNs = ns
        let yaw = pendingYaw
        pendingYaw = 0
        let checkBefore = counters.steps / reanchorCheckSteps
        counters.steps += gridSteps
        counters.staleSpeedSteps += gridSteps
        counters.coalescedSteps += gridSteps
        counters.macroSteps += 1
        speedOffsetsActive = true
        var vObd = 0.0
        if let v = obdSpeedKmh { vObd = v > 0 ? (v + config.obdSpeedOffsetKmh) / 3.6 : 0 }

        let timeNoise = config.headingNoiseDegPerSqrtS * dt.squareRoot() * config.staleHeadingNoiseFactor
        let turnVariance = config.turnHeadingNoiseDegPerSqrtDeg * config.turnHeadingNoiseDegPerSqrtDeg
            * abs(yaw) * 180 / .pi
        let sigmaHeading = (timeNoise * timeNoise + turnVariance).squareRoot() * .pi / 180
        let sigmaScale = config.scaleNoisePerSqrtS * dt.squareRoot()
        let ou = Self.ouTransition(dt: dt, sigma: config.staleSpeedNoiseMpsPerSqrtS, tau: config.staleSpeedDecayS)
        let alongPerM = config.alongTrackNoisePerSqrtM * config.alongTrackNoisePerSqrtM
        let crossPerM = config.crossTrackNoisePerSqrtM * config.crossTrackNoisePerSqrtM

        var meanDEast = 0.0, meanDNorth = 0.0, meanSpeed = 0.0
        for i in 0..<east.count {
            let (n1, n2) = rng.nextGaussianPair()
            let (n3, n4) = rng.nextGaussianPair()
            let x0 = speedOffset[i]
            speedOffset[i] = ou.decay * x0 + ou.sigmaEnd * n3
            let integral = ou.integralGain * x0 + ou.integralOnEnd * n3 + ou.integralOwn * n4
            let distance = vObd * scale[i] * dt + integral
            let (dEast, dNorth) = move(i, dHeading: yaw + sigmaHeading * n1, distance: distance,
                                       scaleStep: sigmaScale * n2, alongPerM: alongPerM, crossPerM: crossPerM)
            let w = weight[i]
            meanDEast += w * dEast
            meanDNorth += w * dNorth
            meanSpeed += w * (dt > 0 ? distance / dt : 0)
        }
        cumulativeEast += meanDEast
        cumulativeNorth += meanDNorth
        cumulativeYaw += yaw
        lastStepStationary = false
        lastMeanSpeed = meanSpeed
        history.append(ns, cumulativeEast, cumulativeNorth, cumulativeYaw, speed: nil)
        if counters.steps / reanchorCheckSteps != checkBefore {
            reanchorIfNeeded()
        }
    }

    /// Exact transition over `dt` of the OU speed error dX = −X/τ dt + σ dW
    /// and its integral I = ∫X: X' = decay·X + sigmaEnd·n₁,
    /// I = integralGain·X + integralOnEnd·n₁ + integralOwn·n₂ (n₁, n₂
    /// independent standard normals). τ ≤ 0 is the plain random walk.
    static func ouTransition(dt: Double, sigma: Double, tau: Double)
        -> (decay: Double, sigmaEnd: Double, integralGain: Double, integralOnEnd: Double, integralOwn: Double) {
        let s2 = sigma * sigma
        let decay: Double, varEnd: Double, covariance: Double, varIntegral: Double, gain: Double
        if tau > 0 {
            let oneMinusA = -expm1(-dt / tau)
            decay = 1 - oneMinusA
            let oneMinusA2 = oneMinusA * (1 + decay)
            varEnd = s2 * tau / 2 * oneMinusA2
            covariance = s2 * tau * tau / 2 * oneMinusA * oneMinusA
            varIntegral = s2 * tau * tau * (dt - 2 * tau * oneMinusA + tau / 2 * oneMinusA2)
            gain = tau * oneMinusA
        } else {
            decay = 1
            varEnd = s2 * dt
            covariance = s2 * dt * dt / 2
            varIntegral = s2 * dt * dt * dt / 3
            gain = dt
        }
        let sigmaEnd = max(0, varEnd).squareRoot()
        let onEnd = sigmaEnd > 0 ? covariance / sigmaEnd : 0
        let own = max(0, varIntegral - onEnd * onEnd).squareRoot()
        return (decay, sigmaEnd, gain, onEnd, own)
    }

    /// Variance of the OU speed error's integral over `dt` from a zero start:
    /// the along-track spread of a car whose speed is unknown for `dt`.
    static func ouIntegralVariance(dt: Double, sigma: Double, tau: Double) -> Double {
        let ou = ouTransition(dt: dt, sigma: sigma, tau: tau)
        return ou.integralOnEnd * ou.integralOnEnd + ou.integralOwn * ou.integralOwn
    }

    // MARK: Re-anchoring

    /// Moves the local plane's anchor to the cloud's mean once that is more
    /// than `reanchorDistanceM` away (checked every 10 s of moving steps).
    /// Positions convert exactly through WGS-84; headings, covariances and the
    /// motion history through the Jacobian of the old→new plane map at the
    /// mean. Deterministic: no random numbers are drawn.
    private mutating func reanchorIfNeeded() {
        guard let old = tangentPlane else { return }
        var me = 0.0, mn = 0.0
        for i in 0..<east.count {
            me += weight[i] * east[i]
            mn += weight[i] * north[i]
        }
        guard (me * me + mn * mn).squareRoot() > config.reanchorDistanceM else { return }
        let centre = old.geodetic(east: me, north: mn)
        let new = LocalTangentPlane(latitude: centre.latitude, longitude: centre.longitude)
        func map(_ e: Double, _ n: Double) -> (Double, Double) {
            let p = old.geodetic(east: e, north: n)
            let q = new.enu(latitude: p.latitude, longitude: p.longitude)
            return (q.east, q.north)
        }
        // Jacobian at the mean, central differences over ±1 m.
        let ep = map(me + 1, mn), em = map(me - 1, mn), np = map(me, mn + 1), nm = map(me, mn - 1)
        let jee = (ep.0 - em.0) / 2, jne = (ep.1 - em.1) / 2  // ∂(e', n')/∂e
        let jen = (np.0 - nm.0) / 2, jnn = (np.1 - nm.1) / 2  // ∂(e', n')/∂n
        for i in 0..<east.count {
            (east[i], north[i]) = map(east[i], north[i])
            let s = sin(heading[i]), c = cos(heading[i])
            heading[i] = Self.wrap2Pi(atan2(jee * s + jen * c, jne * s + jnn * c))
            let pee = covEE[i], pen = covEN[i], pnn = covNN[i]
            // P' = J P Jᵀ, J = [[jee, jen], [jne, jnn]].
            let aee = jee * pee + jen * pen, aen = jee * pen + jen * pnn
            let ane = jne * pee + jnn * pen, ann = jne * pen + jnn * pnn
            covEE[i] = aee * jee + aen * jen
            covEN[i] = aee * jne + aen * jnn
            covNN[i] = ane * jne + ann * jnn
        }
        // Cumulative mean motion: only differences are used, so the linear
        // part of the map is enough.
        let linear = { (e: Double, n: Double) in (jee * e + jen * n, jne * e + jnn * n) }
        (cumulativeEast, cumulativeNorth) = linear(cumulativeEast, cumulativeNorth)
        history.transformDisplacements(linear)
        tangentPlane = new
        counters.reanchors += 1
    }

    /// Speed is known again: every particle's stale-speed error is 0.
    private mutating func resetSpeedOffsets() {
        for i in speedOffset.indices { speedOffset[i] = 0 }
        speedOffsetsActive = false
    }

    // MARK: Initialisation

    private mutating func initialize(
        latitude: Double, longitude: Double, sigma: Double,
        heading course: (radians: Double, sigma: Double)?, at ns: Int64
    ) {
        let plane = LocalTangentPlane(latitude: latitude, longitude: longitude)
        tangentPlane = plane
        let n = config.particleCount
        east = [Double](repeating: 0, count: n)
        north = east
        covEE = [Double](repeating: sigma * sigma, count: n)
        covEN = east
        covNN = covEE
        heading = east
        scale = east
        speedOffset = east
        logWeight = [Double](repeating: -log(Double(n)), count: n)
        weight = [Double](repeating: 1 / Double(n), count: n)
        effectiveSampleSize = Double(n)
        let twoPi = 2 * Double.pi
        for i in 0..<n {
            if let course {
                heading[i] = Self.wrap2Pi(course.radians + course.sigma * rng.nextGaussian())
            } else {
                // Stratified over the circle: one heading per 360°/N slot,
                // which cuts Monte Carlo noise against independent draws.
                heading[i] = (Double(i) + rng.nextUniform()) / Double(n) * twoPi
            }
            scale[i] = config.scalePriorMean + config.scalePriorStd * rng.nextGaussian()
        }
        cumulativeEast = 0
        cumulativeNorth = 0
        cumulativeYaw = 0
        history.removeAll()
        history.append(lastStepNs ?? ns, 0, 0, 0, speed: nil)
        lastStepStationary = isStopped(at: ns)
        lastMeanSpeed = 0
    }

    // MARK: Location fixes

    private mutating func ingestLocation(_ sample: LocationSample, fixNs: Int64, arrivalNs: Int64) {
        let accuracy = sample.horizontalAccuracy
        guard accuracy >= 0, accuracy.isFinite, sample.latitude.isFinite, sample.longitude.isFinite,
              abs(sample.latitude) <= 90, abs(sample.longitude) <= 180 else {
            counters.fixesIgnoredInvalid += 1
            return
        }
        let age = max(0, Double(arrivalNs - fixNs) / 1e9)
        if age > config.maxFixAgeS && !isStopped(at: arrivalNs) {
            if isFresh(at: arrivalNs) || !(config.heldFixTimeoutS > 0) {
                // OBD says the car is moving (or holding is off).
                counters.fixesIgnoredStale += 1
            } else {
                // OBD cannot say yet whether the car is stopped (N4B-1).
                holdStaleFix(HeldFix(sample: sample, fixNs: fixNs, arrivalNs: arrivalNs))
            }
            return
        }
        // No Doppler speed: a cell-tower or Wi-Fi position, whatever its
        // claimed accuracy.
        let network = !sample.hasValidSpeed
        let sigma = max(accuracy * config.fixSigmaPerAccuracy, config.fixSigmaFloorM)
            * (network ? config.networkFixInflation : 1)
            + Self.staleGrowth(fixNs: fixNs, age: age, config: config)
        // Course needs real motion: GNSS reports a few m/s of speed noise
        // while parked, so a fresh OBD speed under the threshold vetoes it.
        let since = shiftSince(fixNs)
        let obdAtFix: Double? = tangentPlane == nil ? (isStopped(at: arrivalNs) ? 0 : nil) : since.obdSpeed
        var dopplerConsistent = true
        if sample.speed >= 0, let v = obdAtFix {
            dopplerConsistent = abs(sample.speed - v) <= max(config.gnssSpeedGateMps, config.gnssSpeedGateFraction * v)
        }
        let courseValid = sample.hasValidCourse && sample.speed >= config.courseMinSpeedMps
            && (obdAtFix ?? .infinity) >= config.courseMinSpeedMps && dopplerConsistent
        let courseSigma = max(sample.courseAccuracy, config.courseSigmaFloorDeg) * .pi / 180
        let clean = accuracy <= config.cleanFixAccM && courseValid

        guard let plane = tangentPlane else {
            initialize(
                latitude: sample.latitude, longitude: sample.longitude, sigma: sigma,
                heading: clean ? (sample.course * .pi / 180, courseSigma) : nil, at: fixNs
            )
            counters.fixesUsed += 1
            if network {
                counters.networkFixesUsed += 1
                lastNetworkFixNs = fixNs
            }
            return
        }

        let fix = plane.enu(latitude: sample.latitude, longitude: sample.longitude)
        let targetEast = fix.east + since.east
        let targetNorth = fix.north + since.north
        let targetCourse = sample.course * .pi / 180 + since.yaw

        if clean && (headingStdRadians() > config.reseedHeadingStdDeg * .pi / 180
                     || !courseHasSupport(targetCourse, sigma: courseSigma)) {
            reseed(east: targetEast, north: targetNorth, sigma: sigma, course: targetCourse, courseSigma: courseSigma)
        }

        var temper = 1.0
        if network {
            temper = Self.networkTemper(
                sinceLastS: lastNetworkFixNs.map { Double(fixNs - $0) / 1e9 }, correlationS: config.networkFixCorrelationS
            )
            lastNetworkFixNs = max(lastNetworkFixNs ?? fixNs, fixNs)
            counters.networkFixesUsed += 1
        }
        counters.fixesUsed += 1

        // Tempering a Gaussian likelihood by w is the same as dividing its
        // precision by w: R = σ² / w.
        let positionVariance = temper > 0 ? sigma * sigma / temper : .infinity
        let useSpeed = sample.hasValidSpeed && (since.obdSpeed ?? 0) * 3.6 > config.speedUpdateMinKmh && dopplerConsistent
        let obdSpeed = since.obdSpeed ?? 0
        let speedSigma = max(sample.speedAccuracy, config.speedSigmaFloorMps)
        if courseValid { counters.courseUpdates += 1 }
        if useSpeed { counters.speedUpdates += 1 }
        for i in 0..<east.count {
            var l = positionVariance.isFinite
                ? positionUpdate(i, east: targetEast, north: targetNorth, variance: positionVariance).logLikelihood
                : 0
            if courseValid {
                let r = Self.wrapPi(heading[i] - targetCourse) / courseSigma
                l -= 0.5 * r * r
            }
            if useSpeed {
                let r = (obdSpeed * scale[i] - sample.speed) / speedSigma
                l -= 0.5 * r * r
            }
            logWeight[i] += l
        }
        normalizeWeights()
        resampleIfNeeded()
    }

    // MARK: Held stale fix (N4B-1)

    /// Holds `fix`, a stale fix that arrived while OBD could not say whether
    /// the car is stopped. One fix at most, the newest by fix time: a newer
    /// stale fix carries the same kind of information with less age, so its
    /// σ is smaller and keeping both would only add a second, older copy of
    /// a cached position (the pre-session case delivers exactly one). One
    /// slot also keeps the decision O(1) and the memory fixed. The fix not
    /// kept is dropped and counted.
    private mutating func holdStaleFix(_ fix: HeldFix) {
        if let held = heldFix {
            counters.heldFixesReplaced += 1
            counters.fixesIgnoredStale += 1
            guard fix.fixNs >= held.fixNs else { return }
        }
        counters.fixesHeld += 1
        heldFix = fix
    }

    /// Drops the held fix once `ns` is more than `heldFixTimeoutS` after its
    /// arrival with no OBD reply having decided it. Checked at every input,
    /// before the input itself, so an OBD reply exactly at the limit still
    /// decides.
    private mutating func expireHeldFix(at ns: Int64) {
        guard let held = heldFix,
              Double(ns) - Double(held.arrivalNs) > config.heldFixTimeoutS * 1e9 else { return }
        heldFix = nil
        counters.heldFixesDroppedTimeout += 1
        counters.fixesIgnoredStale += 1
    }

    /// A vehicle-speed reply at `obdNs` has just been ingested: if it is
    /// fresh at the held fix's arrival (no more than `obdMaxAgeS` before
    /// it; any later reply is too), it decides. 0: the fix is applied as if
    /// it had arrived at max(its arrival, the reply) — the same instant
    /// arrival order gives it: when the reply's `t` is before the fix's
    /// arrival (the live pre-session case: the row is written late), the
    /// fix keeps its own arrival, so its age, stale σ and latency shift are
    /// bit-identical to an arrival-order replay; when the reply comes later,
    /// the fix counts as arriving with it, and its age includes the wait.
    /// Moving: the fix is dropped, as it would have been on arrival. An
    /// older reply leaves it held.
    private mutating func resolveHeldFix(obdNs: Int64) {
        guard let held = heldFix,
              Double(obdNs) >= Double(held.arrivalNs) - config.obdMaxAgeS * 1e9 else { return }
        heldFix = nil
        if obdSpeedKmh == 0 {
            counters.heldFixesUsed += 1
            ingestLocation(held.sample, fixNs: held.fixNs, arrivalNs: max(held.arrivalNs, obdNs))
        } else {
            counters.heldFixesDroppedMoving += 1
            counters.fixesIgnoredStale += 1
        }
    }

    /// Extra σ of a stale fix: `staleFixSigmaGrowthMps × age` when the fix
    /// is older than `staleFixAgeS` at ingest (a pre-session fix from minutes
    /// ago, or a relaunch mid-drive); 0 otherwise. A pre-session fix only a
    /// fraction of a second old is not stale.
    static func staleGrowth(fixNs: Int64, age: Double, config: NavigationConfig) -> Double {
        guard age > config.staleFixAgeS else { return 0 }
        return max(0, config.staleFixSigmaGrowthMps) * age
    }

    /// Likelihood exponent for a network fix `sinceLastS` seconds after the
    /// previous one (nil: the first): `min(1, Δt / correlationS)`, clamped
    /// at 0 for a fix not after the previous one.
    static func networkTemper(sinceLastS: Double?, correlationS: Double) -> Double {
        guard let dt = sinceLastS else { return 1 }
        return min(1, max(0, dt / correlationS))
    }

    /// Whether any particle's heading is within `reseedNoSupportSigma`
    /// course σ of `course`.
    private func courseHasSupport(_ course: Double, sigma: Double) -> Bool {
        let limit = config.reseedNoSupportSigma * sigma
        for h in heading where abs(Self.wrapPi(h - course)) <= limit { return true }
        return false
    }

    /// Replaces a random fraction of particles with ones drawn around a
    /// clean fix and its course, so heading collapses within a fix or two
    /// instead of waiting for particles that happen to agree.
    private mutating func reseed(east e: Double, north n: Double, sigma: Double, course: Double, courseSigma: Double) {
        counters.reseeds += 1
        let count = east.count
        let k = Int((config.reseedFraction * Double(count)).rounded())
        let averageLogWeight = -log(Double(count))
        for _ in 0..<k {
            let i = min(count - 1, Int(rng.nextUniform() * Double(count)))
            east[i] = e
            north[i] = n
            covEE[i] = sigma * sigma
            covEN[i] = 0
            covNN[i] = sigma * sigma
            heading[i] = Self.wrap2Pi(course + courseSigma * rng.nextGaussian())
            speedOffset[i] = 0
            logWeight[i] = averageLogWeight
        }
        normalizeWeights()
    }

    // MARK: Manual fixes

    private mutating func ingestManualFix(_ sample: ManualFixSample, at ns: Int64) {
        guard sample.latitude.isFinite, sample.longitude.isFinite,
              abs(sample.latitude) <= 90, abs(sample.longitude) <= 180 else { return }
        counters.manualFixes += 1
        let sigma = config.manualFixSigma(mapSpanM: sample.mapSpanM)
        guard let plane = tangentPlane else {
            initialize(latitude: sample.latitude, longitude: sample.longitude, sigma: sigma, heading: nil, at: ns)
            return
        }
        let since = shiftSince(ns)
        let pin = plane.enu(latitude: sample.latitude, longitude: sample.longitude)
        let targetEast = pin.east + since.east
        let targetNorth = pin.north + since.north
        let prior = (logWeight, east, north, covEE, covEN, covNN)
        var nearest = Double.infinity
        for i in 0..<east.count {
            let update = positionUpdate(i, east: targetEast, north: targetNorth, variance: sigma * sigma)
            logWeight[i] += update.logLikelihood
            nearest = min(nearest, update.mahalanobis2)
        }
        normalizeWeights()
        // Reset only when no particle is statistically compatible with the
        // pin. A low ESS with a compatible particle is the pin being most
        // informative (a ring-shaped cloud after km of unknown heading): keep
        // that posterior and resample (R13.1-1).
        if nearest > config.manualFixResetChi2 {
            // The prior has practically no support at the pin: the driver's
            // "I'm here" wins. Positions restart at it; heading and scale
            // hypotheses and their weights are kept.
            counters.manualResets += 1
            (logWeight, east, north, covEE, covEN, covNN) = prior
            for i in 0..<east.count {
                east[i] = targetEast
                north[i] = targetNorth
                covEE[i] = sigma * sigma
                covEN[i] = 0
                covNN[i] = sigma * sigma
                speedOffset[i] = 0
            }
            normalizeWeights()
        }
        resampleIfNeeded()
    }

    /// Kalman update of particle `i`'s position with an isotropic position
    /// measurement of variance `variance` (m²). Returns the log of the
    /// predictive likelihood N(z; μ, P + R) (without the 2π constant) and
    /// the squared Mahalanobis distance of the measurement.
    private mutating func positionUpdate(
        _ i: Int, east z0: Double, north z1: Double, variance r: Double
    ) -> (logLikelihood: Double, mahalanobis2: Double) {
        let pee = covEE[i], pen = covEN[i], pnn = covNN[i]
        let see = pee + r, snn = pnn + r
        let det = see * snn - pen * pen
        let iee = snn / det, inn = see / det, ien = -pen / det
        let de = z0 - east[i], dn = z1 - north[i]
        let m2 = de * (iee * de + ien * dn) + dn * (ien * de + inn * dn)
        // K = P S⁻¹; μ += K r; P = (I − K) P.
        let kee = pee * iee + pen * ien, ken = pee * ien + pen * inn
        let kne = pen * iee + pnn * ien, knn = pen * ien + pnn * inn
        east[i] += kee * de + ken * dn
        north[i] += kne * de + knn * dn
        covEE[i] = pee - (kee * pee + ken * pen)
        covEN[i] = pen - (kee * pen + ken * pnn)
        covNN[i] = pnn - (kne * pen + knn * pnn)
        return (-0.5 * m2 - 0.5 * log(det), m2)
    }

    // MARK: Weights and resampling

    private mutating func normalizeWeights() {
        var maxLog = -Double.infinity
        for l in logWeight where l > maxLog { maxLog = l }
        guard maxLog.isFinite else {
            // Every particle impossible (should not happen with Gaussian
            // likelihoods): restart from uniform weights.
            let u = -log(Double(logWeight.count))
            for i in logWeight.indices { logWeight[i] = u; weight[i] = 1 / Double(logWeight.count) }
            effectiveSampleSize = Double(logWeight.count)
            return
        }
        var sum = 0.0
        for i in logWeight.indices { sum += exp(logWeight[i] - maxLog) }
        let lse = maxLog + log(sum)
        var sumSquares = 0.0
        for i in logWeight.indices {
            let l = logWeight[i] - lse
            logWeight[i] = l
            let w = exp(l)
            weight[i] = w
            sumSquares += w * w
        }
        effectiveSampleSize = 1 / sumSquares
    }

    private mutating func resampleIfNeeded() {
        let n = east.count
        guard effectiveSampleSize < config.resampleESSFraction * Double(n) else { return }
        counters.resamples += 1
        // Systematic resampling.
        var indices = [Int](repeating: 0, count: n)
        let stride = 1 / Double(n)
        var u = rng.nextUniform() * stride
        var cumulative = weight[0]
        var j = 0
        for i in 0..<n {
            while u > cumulative && j < n - 1 {
                j += 1
                cumulative += weight[j]
            }
            indices[i] = j
            u += stride
        }
        let jitterHeading = config.resampleHeadingJitterDeg * .pi / 180
        var newEast = east, newNorth = north, newEE = covEE, newEN = covEN, newNN = covNN
        var newHeading = heading, newScale = scale, newOffset = speedOffset
        for i in 0..<n {
            let k = indices[i]
            newEast[i] = east[k]
            newNorth[i] = north[k]
            newEE[i] = covEE[k]
            newEN[i] = covEN[k]
            newNN[i] = covNN[k]
            newHeading[i] = Self.wrap2Pi(heading[k] + jitterHeading * rng.nextGaussian())
            newScale[i] = scale[k] + config.resampleScaleJitter * rng.nextGaussian()
            newOffset[i] = speedOffset[k]
        }
        east = newEast
        north = newNorth
        covEE = newEE
        covEN = newEN
        covNN = newNN
        heading = newHeading
        scale = newScale
        speedOffset = newOffset
        let u0 = -log(Double(n))
        for i in 0..<n {
            logWeight[i] = u0
            weight[i] = stride
        }
        effectiveSampleSize = Double(n)
    }

    // MARK: History

    /// Mean displacement, yaw and OBD speed since `ns`, from the motion
    /// history. A time older than the history uses its oldest entry.
    private func shiftSince(_ ns: Int64) -> (east: Double, north: Double, yaw: Double, obdSpeed: Double?) {
        guard let entry = history.entry(atOrBefore: ns) else {
            return (0, 0, 0, nil)
        }
        return (cumulativeEast - entry.east, cumulativeNorth - entry.north, cumulativeYaw - entry.yaw, entry.speed)
    }

    // MARK: Estimate

    private func headingStdRadians() -> Double {
        var s = 0.0, c = 0.0
        for i in 0..<heading.count {
            s += weight[i] * sin(heading[i])
            c += weight[i] * cos(heading[i])
        }
        let r = (s * s + c * c).squareRoot()
        return (-2 * log(max(r, 1e-12))).squareRoot()
    }

    /// The belief at `t`, or nil before initialisation. Does not change the
    /// engine. For an earlier `t` the current belief is returned as is.
    ///
    /// For a `t` after the last 10 Hz step, unless that step was stationary,
    /// the mean is extrapolated with the last speed and yaw rate for at most
    /// `extrapolationHorizonS` (R13.1-5); the ellipse is the last step's.
    /// Beyond the horizon the position and heading are held at the horizon,
    /// and the covariance grows by the motion not extrapolated, over the
    /// excess time s: (v·s)² along the heading (the car may have stopped at
    /// once or kept its last speed v) plus, in every direction, the variance
    /// of the engine's own unknown-speed (OU) error integrated over s. It
    /// grows with `t` and never shrinks. A stationary last step (fresh 0 or
    /// parked) is held unchanged, as the engine itself would hold it until
    /// new evidence.
    public func estimate(at t: MonotonicTimestamp) -> NavigationEstimate? {
        guard let plane = tangentPlane else { return nil }
        let n = east.count
        var me = 0.0, mn = 0.0, s = 0.0, c = 0.0, ms = 0.0, ms2 = 0.0
        for i in 0..<n {
            let w = weight[i]
            me += w * east[i]
            mn += w * north[i]
            s += w * sin(heading[i])
            c += w * cos(heading[i])
            ms += w * scale[i]
        }
        var ee = 0.0, en = 0.0, nn = 0.0
        for i in 0..<n {
            let w = weight[i]
            let de = east[i] - me
            let dn = north[i] - mn
            ee += w * (covEE[i] + de * de)
            en += w * (covEN[i] + de * dn)
            nn += w * (covNN[i] + dn * dn)
            let ds = scale[i] - ms
            ms2 += w * ds * ds
        }
        let r = (s * s + c * c).squareRoot()
        let headingStd = (-2 * log(max(r, 1e-12))).squareRoot()
        var meanHeading = atan2(s, c)

        let last = lastStepNs ?? t.nanoseconds
        if t.nanoseconds > last && !lastStepStationary {
            let horizon = max(0, config.extrapolationHorizonS)
            // In Double, so a huge `t` cannot overflow.
            let elapsed = (Double(t.nanoseconds) - Double(last)) / 1e9
            let end = elapsed <= horizon ? t.nanoseconds : last + Int64((horizon * 1e9).rounded())
            let dt = Double(end - last) / 1e9
            let sinceMotion = max(0, Double(end - (lastMotionNs ?? last)) / 1e9)
            let dYaw = pendingYaw + lastYawRate * sinceMotion
            let mid = meanHeading + 0.5 * dYaw
            me += lastMeanSpeed * dt * sin(mid)
            mn += lastMeanSpeed * dt * cos(mid)
            meanHeading += dYaw
            if elapsed > horizon {
                let excess = elapsed - horizon
                let travelled = abs(lastMeanSpeed) * excess
                let along = travelled * travelled
                let any = Self.ouIntegralVariance(dt: excess, sigma: config.staleSpeedNoiseMpsPerSqrtS,
                                                  tau: config.staleSpeedDecayS)
                let ue = sin(meanHeading), un = cos(meanHeading)
                ee += along * ue * ue + any
                en += along * ue * un
                nn += along * un * un + any
            }
        }
        let geodetic = plane.geodetic(east: me, north: mn)
        let headingStdDeg = headingStd * 180 / .pi
        return NavigationEstimate(
            t: t,
            east: me,
            north: mn,
            latitude: geodetic.latitude,
            longitude: geodetic.longitude,
            headingDeg: Self.wrap2Pi(meanHeading) * 180 / .pi,
            headingStdDeg: headingStdDeg,
            ellipse: ErrorEllipse(covarianceEE: ee, en: en, nn: nn),
            speedMps: lastStepStationary ? 0 : lastMeanSpeed,
            speedScaleMean: ms,
            speedScaleStd: ms2.squareRoot(),
            effectiveSampleSize: effectiveSampleSize,
            converged: headingStdDeg < config.convergedHeadingStdDeg,
            stationary: lastStepStationary
        )
    }

    // MARK: Angles

    static func wrap2Pi(_ x: Double) -> Double {
        let twoPi = 2 * Double.pi
        var r = x.truncatingRemainder(dividingBy: twoPi)
        if r < 0 { r += twoPi }
        return r >= twoPi ? 0 : r
    }

    static func wrapPi(_ x: Double) -> Double {
        var r = wrap2Pi(x)
        if r > .pi { r -= 2 * .pi }
        return r
    }
}

/// Fixed-capacity ring of cumulative mean motion per step.
struct MotionHistory: Sendable {
    struct Entry: Sendable {
        var t: Int64
        var east: Double
        var north: Double
        var yaw: Double
        /// OBD speed used at this step when fresh (m/s), nil when stale.
        var speed: Double?
    }

    private var entries: [Entry] = []
    private var head = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(2, capacity)
        entries.reserveCapacity(self.capacity)
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        head = 0
    }

    /// Applies a linear map to every entry's cumulative east/north.
    mutating func transformDisplacements(_ map: (Double, Double) -> (Double, Double)) {
        for k in entries.indices {
            (entries[k].east, entries[k].north) = map(entries[k].east, entries[k].north)
        }
    }

    mutating func append(_ t: Int64, _ east: Double, _ north: Double, _ yaw: Double, speed: Double?) {
        let entry = Entry(t: t, east: east, north: north, yaw: yaw, speed: speed)
        if entries.count < capacity {
            entries.append(entry)
        } else {
            entries[head] = entry
            head = (head + 1) % capacity
        }
    }

    /// Entry `k` in chronological order.
    private func chronological(_ k: Int) -> Entry {
        entries[(head + k) % entries.count]
    }

    /// The latest entry at or before `t`; the oldest if all are later.
    func entry(atOrBefore t: Int64) -> Entry? {
        guard !entries.isEmpty else { return nil }
        var lo = 0, hi = entries.count - 1
        if chronological(0).t > t { return chronological(0) }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if chronological(mid).t <= t { lo = mid } else { hi = mid - 1 }
        }
        return chronological(lo)
    }
}
