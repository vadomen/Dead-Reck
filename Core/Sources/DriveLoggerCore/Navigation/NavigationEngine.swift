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
/// (zero-velocity update). A stale reading is unknown speed: each particle's
/// speed error random-walks and heading noise grows.
///
/// **Updates**: location fixes (per-axis σ = accuracy / 1.51, floored;
/// tower-like fixes tempered for their minutes-long correlated errors), GNSS
/// course and speed when valid and consistent with OBD speed, and manual
/// "I'm here" fixes, which also reset positions when the cloud has no
/// support at the pin. A clean fix reseeds part of the cloud around its
/// course while heading is unknown or when no particle agrees with it.
///
/// Fix latency: a v2/v3 fix's `t` is earlier than its arrival. The fix is
/// compared after shifting it by the engine's own mean displacement since
/// `t`, from a short history of cumulative mean motion — causal and without
/// per-particle history.
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
    /// Speed error random walk while OBD is stale, m/s; 0 otherwise.
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

    // Last step, for extrapolation in `estimate(at:)`.
    private var lastStepStationary = true
    private var lastMeanSpeed = 0.0

    // Cumulative mean motion, for shifting late fixes to the present.
    private var cumulativeEast = 0.0
    private var cumulativeNorth = 0.0
    private var cumulativeYaw = 0.0
    private var history: MotionHistory

    private var lastTowerFixNs: Int64?

    /// The primary ECU whose vehicle speed is used.
    public static let primaryECU = "7E8"

    public init(config: NavigationConfig = NavigationConfig()) {
        precondition(config.particleCount > 0, "particleCount must be positive")
        precondition(config.stepHz > 0, "stepHz must be positive")
        self.config = config
        rng = NavigationRandom(seed: config.seed)
        stepNs = Int64((1_000_000_000 / config.stepHz).rounded())
        history = MotionHistory(capacity: Int((config.maxFixAgeS * config.stepHz).rounded(.up)) + 2)
    }

    // MARK: Ingest

    public mutating func ingest(_ input: NavigationInput) {
        switch input {
        case .motion(let sample, let t):
            ingestMotion(sample, at: t.nanoseconds)
        case .obd(let sample, let t):
            advance(to: t.nanoseconds)
            ingestOBD(sample, at: t.nanoseconds)
        case .location(let sample, let t):
            let arrival = input.arrival.nanoseconds
            advance(to: arrival)
            ingestLocation(sample, fixNs: t.nanoseconds, arrivalNs: arrival)
        case .manualFix(let sample, let t):
            advance(to: t.nanoseconds)
            ingestManualFix(sample, at: t.nanoseconds)
        }
    }

    /// Runs every grid step at or before `ns`.
    private mutating func advance(to ns: Int64) {
        guard let last = lastStepNs else {
            lastStepNs = Self.floorToGrid(ns, stepNs)
            return
        }
        var next = last + stepNs
        while next <= ns {
            step(at: next)
            next += stepNs
        }
    }

    static func floorToGrid(_ ns: Int64, _ step: Int64) -> Int64 {
        let q = ns / step
        let r = ns % step
        return (r < 0 ? q - 1 : q) * step
    }

    private mutating func ingestMotion(_ sample: MotionSample, at ns: Int64) {
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

    private mutating func ingestOBD(_ sample: OBDSample, at ns: Int64) {
        guard sample.pid == .vehicleSpeed,
              sample.ecu == nil || sample.ecu == Self.primaryECU,
              sample.value.isFinite, sample.value >= 0 else { return }
        obdSpeedKmh = sample.value
        obdNs = ns
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
        let sigmaOffset = config.staleSpeedNoiseMpsPerSqrtS * sqrtDt
        let twoPi = 2 * Double.pi
        let alongPerM = config.alongTrackNoisePerSqrtM * config.alongTrackNoisePerSqrtM
        let crossPerM = config.crossTrackNoisePerSqrtM * config.crossTrackNoisePerSqrtM

        var meanDEast = 0.0, meanDNorth = 0.0, meanSpeed = 0.0
        for i in 0..<east.count {
            let (n1, n2) = rng.nextGaussianPair()
            let dHeading = yaw + sigmaHeading * n1
            let midHeading = heading[i] + 0.5 * dHeading
            var speed = vObd * scale[i]
            if stale {
                speedOffset[i] += sigmaOffset * rng.nextGaussian()
                speed += speedOffset[i]
            }
            let distance = speed * dt
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
            scale[i] += sigmaScale * n2
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
            counters.fixesIgnoredStale += 1
            return
        }
        let tower = accuracy > config.towerMinAccuracyM && sample.speed < 0
        let sigma = max(accuracy * config.fixSigmaPerAccuracy, config.fixSigmaFloorM)
            * (tower ? config.towerInflation : 1)
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
            if tower {
                counters.towerFixesUsed += 1
                lastTowerFixNs = fixNs
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
        if tower {
            temper = Self.towerTemper(
                sinceLastS: lastTowerFixNs.map { Double(fixNs - $0) / 1e9 }, correlationS: config.towerCorrelationS
            )
            lastTowerFixNs = max(lastTowerFixNs ?? fixNs, fixNs)
            counters.towerFixesUsed += 1
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

    /// Likelihood exponent for a tower-like fix `sinceLastS` seconds after
    /// the previous one (nil: the first): `min(1, Δt / correlationS)`,
    /// clamped at 0 for a fix not after the previous one.
    static func towerTemper(sinceLastS: Double?, correlationS: Double) -> Double {
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
        if nearest > config.manualFixResetChi2
            || effectiveSampleSize < config.manualFixResetESSFraction * Double(east.count) {
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
    /// engine. For a `t` after the last 10 Hz step the mean is extrapolated
    /// with the last speed and yaw rate (not while stopped); for an earlier
    /// `t` the current belief is returned as is.
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
            let dt = Double(t.nanoseconds - last) / 1e9
            let sinceMotion = max(0, Double(t.nanoseconds - (lastMotionNs ?? last)) / 1e9)
            let dYaw = pendingYaw + lastYawRate * sinceMotion
            let mid = meanHeading + 0.5 * dYaw
            me += lastMeanSpeed * dt * sin(mid)
            mn += lastMeanSpeed * dt * cos(mid)
            meanHeading += dYaw
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
