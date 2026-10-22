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
/// **Late manual fix** (R14.3-1): the app writes a double-tap pin when its
/// undo window closes, about 3 s after the tap, with `t` = the tap. A pin
/// whose `t` is before the last grid step is applied to each particle as of
/// `t`: the pin plus that particle's own motion since `t`, from a short
/// per-particle ring (`lateManualFixWindowS`). The mean shift would be
/// wrong while heading is unknown: a ring-shaped cloud's mean barely moves
/// although every particle moved v × 3 s along its own heading. A late pin
/// that initialises the engine starts the cloud at the tap and predicts it
/// forward over the steps since, from a pre-initialisation record of yaw
/// and OBD speed. In arrival order a pin is never late, so neither path
/// runs there.
///
/// **OBD zero against moving fixes** (N4B1-1, `zuptFixGate`): an OBD 0
/// that would freeze a step is vetoed while good fixes taken after the
/// zeros began show the car moving; the step then moves like a stale one
/// at the newest such fix's Doppler speed. Its history still holds OBD's
/// 0, so fixes taken then keep the OBD-0 course veto (R53.1-2): a car
/// parked across a ferry keeps its gyro heading, not the ferry's course.
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
///
/// **GPS off switch** (UX-9 a, log v4 `gpsSwitch`): the driver's switch,
/// on at the start. While it is off, a location fix with a valid speed
/// (`LocationSample.hasValidSpeed`: GNSS, the complement of the network
/// rule below) never reaches the filter: `ingest` counts it
/// (`fixesWithheldByGPSSwitch`) and returns before anything else, the
/// time-jump check, the grid, the held fix and the OBD-zero evidence
/// included, so the state is the one a run without those fixes would
/// have. Network fixes, manual fixes, OBD, motion and roads are used as
/// before. The switch input itself is always taken, moves no clock and
/// runs no step: it sets `gpsOn` and, when it turns GPS off, drops a held
/// stale fix that has a valid speed (counted as withheld), so a fix from
/// before the tap is never applied after it. Without a switch input
/// nothing changes.
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
    /// (Ornstein–Uhlenbeck, `staleSpeedDecayS`); 0 otherwise. The noise
    /// increments are antithetic in pairs (2k, 2k + 1): one draw per pair,
    /// opposite signs, so they sum to 0 and add no Monte Carlo drift to the
    /// realised mean (R11.1-7). The offsets themselves are whatever the
    /// filter made them: a resample keeps the ones the fixes favoured
    /// (R20.1-1).
    var speedOffset: [Double] = []
    /// Cumulative own motion (prediction displacement only, no update
    /// corrections), metres, for late manual fixes (R14.3-1). Only
    /// differences against `motionRing` are used.
    var motionEast: [Double] = []
    var motionNorth: [Double] = []
    /// Normalised: logsumexp(logWeight) == 0.
    var logWeight: [Double] = []
    /// exp(logWeight), sums to 1.
    var weight: [Double] = []
    private(set) var effectiveSampleSize = 0.0
    /// Road state per particle (N3.2), allocated only with roads: the
    /// global edge the particle was last matched to (`RoadMatcher.noEdge`
    /// for none), that edge's level (`RoadGeometry.unknownLevel`), and the
    /// distance driven since it was last on a road. Resampling copies them;
    /// a reseed and a manual reset clear them.
    var roadEdge: [UInt32] = []
    var roadLevel: [Int8] = []
    var offRoadM: [Double] = []

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
    /// Moving fixes against the current run of OBD zeros (N4B1-1).
    private(set) var zeroFix = ZeroFixEvidence()

    // Last step, for extrapolation in `estimate(at:)`.
    private var lastStepStationary = true
    private var lastMeanSpeed = 0.0

    // Cumulative mean motion, for shifting late fixes to the present.
    private var cumulativeEast = 0.0
    private var cumulativeNorth = 0.0
    private var cumulativeYaw = 0.0
    private var history: MotionHistory
    /// Each particle's `motionEast/North` at recent grid steps (R14.3-1).
    private(set) var motionRing: ParticleMotionRing
    /// Grid steps before initialisation, for a late initialising pin.
    private var preInitSteps: PreInitSteps

    private var lastNetworkFixNs: Int64?

    /// The driver's GPS switch (UX-9 a): false from an off `gpsSwitch`
    /// input until an on one. Starts on.
    public private(set) var gpsOn = true
    /// Fixes with a valid speed not used because GPS was switched off:
    /// withheld on arrival, and a held stale fix dropped at the switch.
    /// Kept outside `counters` so a run without a switch codes exactly as
    /// before.
    public private(set) var fixesWithheldByGPSSwitch = 0
    /// Arrival of the latest fix with a valid speed the filter used (it
    /// initialised the engine or updated it), ns; nil if none
    /// (`gnssInUse(at:)`).
    private var lastGNSSFixUsedNs: Int64?

    // Restored prior (UX-20). Outside `counters`, so a run without a prior
    // codes exactly as before; with `prior` nil none of it runs.
    /// The prior given at init; applied at the first input.
    private let prior: NavigationPrior?
    private var priorApplied = false
    /// A stopped-class prior waits for the first OBD vehicle-speed reply:
    /// moving regrows it as moving (`resolvePriorAtFirstOBD`).
    private var priorAwaitingOBD = false
    /// The restore's status (`NavigationRestore`): `.none` without a prior.
    public private(set) var restore = NavigationRestore()
    /// End of the latest grid step since initialisation in which the cloud
    /// moved (not a ZUPT or parked step); nil if none (R11.1-5). A stale
    /// fix accepted while stopped must be no older than this: then every
    /// step since its time was frozen and its shift is exactly 0.
    private var lastMovingStepNs: Int64?

    /// A stale fix waiting for OBD to say whether the car is stopped
    /// (N4B-1). At most one: see `holdStaleFix`.
    private struct HeldFix: Sendable {
        var sample: LocationSample
        var fixNs: Int64
        var arrivalNs: Int64
    }
    private var heldFix: HeldFix?

    /// Good fixes against the current run of OBD zeros (N4B1-1,
    /// `NavigationConfig.zuptFixGate`).
    struct ZeroFixEvidence: Sendable, Equatable {
        /// `t` of the run's first OBD 0; nil after a moving reply, and
        /// before any reply.
        var zeroSinceNs: Int64?
        /// Good fixes in a row after `zeroSinceNs` reading at least
        /// `zuptFixGateMinSpeedMps`.
        var movingFixes = 0
        /// The newest of them: its `t` and Doppler speed, m/s.
        var newestFixNs: Int64?
        var speedMps = 0.0
    }
    /// Whether a stale fix is held, waiting for a fresh OBD reply.
    public var hasHeldFix: Bool { heldFix != nil }

    // Roads (N3.2). nil without a road network.
    private(set) var roads: RoadMatcher?
    /// The matcher's cell cache size, kept for `attachRoads`.
    private let roadCacheCapacity: Int
    /// Mean distance driven since the last road update (Δs), metres.
    private(set) var roadDistanceM = 0.0
    /// Grid time of the last road update attempt (skips included).
    private var lastRoadAttemptNs: Int64?
    private let roadIntervalNs: Int64
    /// From the last road update attempt: `NavigationEstimate.onRoadShare`
    /// and `matchedEdge`.
    private var roadShare: Double?
    private var roadMatchedEdge: MatchedRoadEdge?
    /// Road updates run: a road network is loaded and
    /// `roadUpdateIntervalS` > 0. Otherwise no road code runs at all.
    var roadsActive: Bool { roads != nil && config.roadUpdateIntervalS > 0 }

    // Pin against a GNSS source (N3-FIXPIN). `fixPin` holds one entry per
    // `FixPinSource.Kind` (by raw value) while `roadFixPinCheck` or
    // `fixPinTwoPinCheck` is on, and is empty otherwise: then none of it runs.
    private(set) var fixPin: [FixPinSource] = []
    /// `t` of the last manual fix, for the engine-side refinement rule.
    private var lastManualFixNs: Int64?
    /// Cumulative OBD distance (with the truncation offset, before scale)
    /// over moving steps since initialisation, metres: the two-pin
    /// arbiter's path between pins. Read only by it.
    private var cumulativeOBDM = 0.0
    /// What the last manual fix decided about each GNSS source; nil when
    /// both checks are off, and for a pin that initialised the engine.
    public private(set) var lastFixPinDecision: FixPinDecision?

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

    /// `config` is validated first (`NavigationConfig.validated(roads:)`);
    /// the engine's `config` is the validated value. A config with an
    /// `invalidReason` traps. `roads`: the road network the road update
    /// matches against (N3.2); nil runs no road code at all.
    /// `prior` (UX-20): a restored estimate to seed the cloud from at the
    /// first input instead of waiting for a fix or pin ("Restored prior"
    /// below); nil runs exactly as before it existed.
    public init(config: NavigationConfig = NavigationConfig(), roads: RoadNetwork? = nil,
                prior: NavigationPrior? = nil) {
        self.init(config: config, roads: roads, roadCacheCapacity: RoadMatcher.defaultCacheCapacity, prior: prior)
    }

    /// `roadCacheCapacity`: the matcher's cell cache size (tests run 1
    /// against the default: it must not change a result).
    init(config: NavigationConfig, roads: RoadNetwork?, roadCacheCapacity: Int, prior: NavigationPrior? = nil) {
        self.prior = prior
        let config = config.validated(roads: roads)
        precondition(config.particleCount > 0, "particleCount must be positive")
        precondition(config.stepHz > 0, "stepHz must be positive")
        if let reason = config.invalidReason { preconditionFailure(reason) }
        self.config = config
        self.roads = roads.map { RoadMatcher(network: $0, cacheCapacity: roadCacheCapacity) }
        self.roadCacheCapacity = roadCacheCapacity
        roadIntervalNs = Int64((config.roadUpdateIntervalS * 1e9).rounded())
        rng = NavigationRandom(seed: config.seed)
        stepNs = Int64((1_000_000_000 / config.stepHz).rounded())
        // At least the per-particle window, so a late pin older than the
        // ring still finds its mean shift (R14.3-5).
        history = MotionHistory(capacity: Int((max(config.maxFixAgeS, config.lateManualFixWindowS)
                                               * config.stepHz).rounded(.up)) + 2)
        let ringSlots = config.lateManualFixWindowS > 0
            ? Int((config.lateManualFixWindowS * config.stepHz).rounded(.up)) + 1 : 0
        motionRing = ParticleMotionRing(capacity: ringSlots)
        preInitSteps = PreInitSteps(capacity: ringSlots)
        if config.roadFixPinCheck == 1 || config.fixPinTwoPinCheck == 1 {
            fixPin = FixPinSource.Kind.allCases.map { _ in FixPinSource() }
        }
    }

    // MARK: Roads attached to a running engine (N3.3)

    /// The road network the engine matches against; nil without roads.
    public var roadNetwork: RoadNetwork? { roads?.network }

    /// The latest accepted arrival (an input `accepts(_:)` took); nil before
    /// the first input. A rejected forward jump does not move it.
    public var latestArrival: MonotonicTimestamp? { lastInputNs.map { MonotonicTimestamp(nanoseconds: $0) } }

    /// Attaches `network` to an engine that has none, between two inputs,
    /// before or after initialisation (N3.3, docs/N3_PLAN.md amendment).
    ///
    /// The road state starts as a reseed leaves it: every particle on no
    /// edge, level unknown, 0 m off-road; the distance since the last road
    /// update, the last attempt and the on-road share start fresh. Nothing
    /// else changes, and no random number is drawn, so the engine's state
    /// up to the attach is the no-roads state, and attaching before the
    /// first input equals `init(config:roads:)` with the same network.
    ///
    /// Refused, engine unchanged: when the engine already has roads, or
    /// when `config.validated(roads: network)` differs from `config` in any
    /// key (a pack whose guaranteed radius is under `roadSearchRadiusM`).
    /// The config never changes mid-run.
    public mutating func attachRoads(_ network: RoadNetwork) throws(RoadAttachRefusal) {
        guard roads == nil else { throw .alreadyAttached }
        let keys = config.differingKeys(config.validated(roads: network))
        guard keys.isEmpty else { throw .configWouldChange(keys: keys) }
        roads = RoadMatcher(network: network, cacheCapacity: roadCacheCapacity)
        if isInitialized {
            let n = east.count
            roadEdge = [UInt32](repeating: RoadMatcher.noEdge, count: n)
            roadLevel = [Int8](repeating: RoadGeometry.unknownLevel, count: n)
            offRoadM = [Double](repeating: 0, count: n)
        }
        roadDistanceM = 0
        lastRoadAttemptNs = nil
        roadShare = nil
        roadMatchedEdge = nil
    }

    /// Replaces the attached network with a larger one, between two inputs
    /// (prompt 38: a covering pack installed during a run). `network` must
    /// hold every pack of the attached network and at least one more (by
    /// content hash: a strict superset); the caller builds it from the same
    /// open `RoadPack` instances, so nothing already mapped is mapped twice.
    ///
    /// Edge numbers are per network (canonical pack order), so the road
    /// state starts as `attachRoads(_:)` leaves it: every particle on no
    /// edge, level unknown, 0 m off-road; the distance since the last road
    /// update, the last attempt, the on-road share and the matched edge
    /// start fresh, and the fix-pin road caches (coverage and road
    /// distances per fix, which depend on the packs) are cleared. Nothing
    /// else changes and no random number is drawn: particles, weights,
    /// headings and every other state are untouched.
    ///
    /// Refused, engine unchanged: with no network attached (`notAttached`:
    /// use `attachRoads`), when `network` is not a strict superset
    /// (`notSuperset`), and when `config.validated(roads: network)` would
    /// change any key (`configWouldChange`).
    public mutating func extendRoads(_ network: RoadNetwork) throws(RoadAttachRefusal) {
        guard let attached = roads?.network else { throw .notAttached }
        let old = Set(attached.packs.map(\.contentHash))
        let new = Set(network.packs.map(\.contentHash))
        guard old.isStrictSubset(of: new) else {
            throw .notSuperset(missing: old.subtracting(new).sorted().map(NavigationSeed.hex))
        }
        let keys = config.differingKeys(config.validated(roads: network))
        guard keys.isEmpty else { throw .configWouldChange(keys: keys) }
        roads = RoadMatcher(network: network, cacheCapacity: roadCacheCapacity)
        if isInitialized {
            let n = east.count
            roadEdge = [UInt32](repeating: RoadMatcher.noEdge, count: n)
            roadLevel = [Int8](repeating: RoadGeometry.unknownLevel, count: n)
            offRoadM = [Double](repeating: 0, count: n)
        }
        roadDistanceM = 0
        lastRoadAttemptNs = nil
        roadShare = nil
        roadMatchedEdge = nil
        clearFixPinRoadCache()
        for k in fixPin.indices {
            for j in fixPin[k].ring.indices { fixPin[k].clearCovered(j) }
        }
    }

    // MARK: Ingest

    /// Ingests one input, in arrival order. An implausible forward time jump
    /// is rejected and counted instead (`accepts(_:)`). A GPS switch and a
    /// fix it withholds are handled first ("GPS off switch" above).
    public mutating func ingest(_ input: NavigationInput) {
        switch input {
        case .gpsSwitch(let sample, _):
            setGPSSwitch(on: sample.on)
            return
        case .location(let sample, _) where !gpsOn && sample.hasValidSpeed:
            fixesWithheldByGPSSwitch += 1
            return
        default:
            break
        }
        let arrival = input.arrival.nanoseconds
        guard accepts(input) else {
            counters.inputsRejectedTimeJump += 1
            jumpCandidateNs = arrival
            return
        }
        jumpCandidateNs = nil
        lastInputNs = max(lastInputNs ?? arrival, arrival)
        expireHeldFix(at: arrival)
        if prior != nil && !priorApplied { applyPrior(at: arrival) }
        switch input {
        case .motion(let sample, let t):
            ingestMotion(sample, at: t.nanoseconds)
        case .obd(let sample, let t):
            advance(to: t.nanoseconds)
            if ingestOBD(sample, at: t.nanoseconds) {
                if priorAwaitingOBD { resolvePriorAtFirstOBD(at: t.nanoseconds) }
                resolveHeldFix(obdNs: t.nanoseconds)
            }
        case .location(let sample, let t):
            let arrival = input.arrival.nanoseconds
            advance(to: arrival)
            ingestLocation(sample, fixNs: t.nanoseconds, arrivalNs: arrival)
        case .manualFix(let sample, let t):
            advance(to: t.nanoseconds)
            ingestManualFix(sample, at: t.nanoseconds)
        case .gpsSwitch:
            break
        }
    }

    /// The driver's GPS switch (UX-9 a). Only the flag, and at off the held
    /// stale fix if it has a valid speed: no step, no clock, no time-jump
    /// bookkeeping, so a switch between two inputs changes nothing else. A
    /// repeat of the current state does nothing.
    private mutating func setGPSSwitch(on: Bool) {
        guard on != gpsOn else { return }
        gpsOn = on
        if !on, let held = heldFix, held.sample.hasValidSpeed {
            heldFix = nil
            fixesWithheldByGPSSwitch += 1
        }
    }

    /// Seconds a used GNSS fix keeps `gnssInUse(at:)` true: five 1 Hz fixes.
    public static let gnssInUseWindowS = 5.0

    /// Whether GNSS is in use at `t` (UX-22, the map's GPS state): GPS is
    /// switched on and a fix with a valid speed that arrived no more than
    /// `gnssInUseWindowS` before `t` was used (it initialised or updated
    /// the filter). Withheld, stale, invalid and off-road-rejected fixes do
    /// not count; network fixes are not GNSS.
    public func gnssInUse(at t: MonotonicTimestamp) -> Bool {
        guard gpsOn, let last = lastGNSSFixUsedNs else { return false }
        return Double(t.nanoseconds) - Double(last) <= Self.gnssInUseWindowS * 1e9
    }

    /// Whether `ingest` would take `input` rather than reject it as an
    /// implausible forward time jump (B0-1). Rejected: an input arriving
    /// more than `maxForwardJumpS` after the latest accepted arrival — a
    /// corrupt `t` would otherwise move the engine clock there, and every
    /// later input would be in the past. Accepted anyway: the second of two
    /// such inputs within `forwardJumpConfirmS` of each other, which is a
    /// real resume after a long silence, not one corrupt value. The first
    /// input of all is always accepted (nothing to compare it with), and
    /// so is a GPS switch, which moves no clock. Does not change the engine.
    /// A fix the GPS switch withholds is judged like any fix here; `ingest`
    /// withholds it either way, before this check.
    public func accepts(_ input: NavigationInput) -> Bool {
        // The GPS switch moves no clock: always taken (a lost switch would
        // leave GPS in use against the driver's choice).
        if case .gpsSwitch = input { return true }
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
            // the pending yaw: jump straight to the target (recorded for a
            // late initialising pin).
            recordPreInitStep(at: target, dt: Double(target - last) / 1e9, yaw: pendingYaw)
            lastStepNs = target
            pendingYaw = 0
            return
        }
        var next = last + stepNs
        while next <= target {
            // Both on the grid: divide first, so a huge `t` cannot overflow.
            let remaining = Int(target / stepNs - next / stepNs) + 1
            // A parked stretch is folded only once no moving fix vetoes it
            // (N4B1-1): at most `zuptFixGateMaxAgeS` of steps run first.
            if remaining > max(1, config.maxCatchUpSteps) && !isFresh(at: next)
                && !(parkedSinceZero && zeroVetoed(at: next)) {
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
                history.append(first + Int64(k) * stepNs, cumulativeEast, cumulativeNorth, cumulativeYaw, speed: nil,
                               held: heldOBDSpeed)
            }
            for k in max(0, count - motionRing.capacity)..<count {
                recordMotion(at: first + Int64(k) * stepNs)
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
        if sample.value > 0 {
            zeroFix = ZeroFixEvidence()
        } else if obdSpeedKmh != 0 {
            // The first 0 after a moving reply (or the first reply): a new
            // run of zeros; only fixes after it are evidence against it.
            zeroFix = ZeroFixEvidence(zeroSinceNs: ns)
        }
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

    /// The last OBD vehicle speed, fresh or stale, in m/s with the
    /// truncation offset (0 for a 0 reply); nil before the first reply.
    private var heldOBDSpeed: Double? {
        obdSpeedKmh.map { $0 > 0 ? ($0 + config.obdSpeedOffsetKmh) / 3.6 : 0 }
    }

    /// Fresh OBD zero at `ns`, not vetoed by moving fixes (`zuptFixGate`):
    /// the car is known to be stopped.
    private func isStopped(at ns: Int64) -> Bool {
        guard let v = obdSpeedKmh, let t = obdNs else { return false }
        return v == 0 && Double(ns - t) / 1e9 <= config.obdMaxAgeS && !zeroVetoed(at: ns)
    }

    /// Whether moving fixes veto the OBD 0 at `ns` (N4B1-1): the gate is
    /// on, at least `zuptFixGateMinFixes` good fixes in a row since the run
    /// of zeros began read moving, and the newest is at most
    /// `zuptFixGateMaxAgeS` before `ns`. Only meaningful while the last
    /// OBD reply is 0 (a moving reply clears the evidence).
    private func zeroVetoed(at ns: Int64) -> Bool {
        guard config.zuptFixGate == 1, zeroFix.movingFixes >= config.zuptFixGateMinFixes,
              let newest = zeroFix.newestFixNs else { return false }
        return Double(ns - newest) / 1e9 <= config.zuptFixGateMaxAgeS
    }

    /// Counts `sample` (fix time `fixNs`) as evidence for or against the
    /// current run of OBD zeros (N4B1-1). Only good fixes — a valid Doppler
    /// speed, accuracy ≤ `cleanFixAccM` — whose own `t` is after the run
    /// began: a moving one extends the run of moving fixes, a slower one
    /// ends it. Others change nothing. Kept whatever `zuptFixGate` says,
    /// which only `zeroVetoed` reads.
    private mutating func noteZeroFixEvidence(_ sample: LocationSample, fixNs: Int64) {
        guard let since = zeroFix.zeroSinceNs, fixNs > since, sample.hasValidSpeed, sample.speed.isFinite,
              sample.horizontalAccuracy <= config.cleanFixAccM else { return }
        guard sample.speed >= config.zuptFixGateMinSpeedMps else {
            zeroFix.movingFixes = 0
            zeroFix.newestFixNs = nil
            return
        }
        zeroFix.movingFixes += 1
        if fixNs >= zeroFix.newestFixNs ?? fixNs {
            zeroFix.newestFixNs = fixNs
            zeroFix.speedMps = sample.speed
        }
    }

    // MARK: Predict

    private mutating func step(at ns: Int64) {
        let dt = Double(ns - (lastStepNs ?? ns)) / 1e9
        lastStepNs = ns
        let yaw = pendingYaw
        pendingYaw = 0
        guard isInitialized else {
            recordPreInitStep(at: ns, dt: dt, yaw: yaw)
            return
        }
        // While a restored prior is unconfirmed, a rejecting late pin
        // initialises as a fresh engine's would: it needs this record.
        if restore.status == .unconfirmed { recordPreInitStep(at: ns, dt: dt, yaw: yaw) }
        counters.steps += 1

        var fresh = false
        var vObd = 0.0
        if let v = obdSpeedKmh, let t = obdNs {
            fresh = Double(ns - t) / 1e9 <= config.obdMaxAgeS
            vObd = v > 0 ? (v + config.obdSpeedOffsetKmh) / 3.6 : 0
        }
        // An OBD 0 that would freeze this step (fresh: ZUPT; stale: parked)
        // while moving fixes contradict it (N4B1-1): the step moves like a
        // stale one at the newest moving fix's Doppler speed.
        let vetoed = ((fresh && vObd == 0) || (!fresh && parkedSinceZero)) && zeroVetoed(at: ns)
        if fresh && vObd == 0 && !vetoed {
            // Zero-velocity update: nothing moves, no noise. Speed is known
            // again, so a past dropout's speed errors end here too (only
            // touched when set: the steady stop stays loop-free).
            if speedOffsetsActive { resetSpeedOffsets() }
            counters.zuptSteps += 1
            lastStepStationary = true
            lastMeanSpeed = 0
            history.append(ns, cumulativeEast, cumulativeNorth, cumulativeYaw, speed: 0, held: 0)
            recordMotion(at: ns)
            return
        }
        let stale = !fresh || vetoed
        if stale && parkedSinceZero && !vetoed {
            // Stale after a stop with no sign of motion since: parked.
            counters.staleParkedSteps += 1
            lastStepStationary = true
            lastMeanSpeed = 0
            history.append(ns, cumulativeEast, cumulativeNorth, cumulativeYaw, speed: nil, held: heldOBDSpeed)
            recordMotion(at: ns)
            return
        }
        if vetoed {
            counters.zuptVetoedSteps += 1
            speedOffsetsActive = true
            vObd = zeroFix.speedMps
        } else if stale {
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
        var pairNoise = 0.0
        for i in 0..<east.count {
            let (n1, n2) = rng.nextGaussianPair()
            let dHeading = yaw + sigmaHeading * n1
            // A vetoed step's speed is a GNSS Doppler speed: already true.
            var speed = vetoed ? vObd : vObd * scale[i]
            if stale {
                // Antithetic increments: the even particle of a pair draws,
                // the odd one takes the opposite (an unpaired last one
                // draws). Each keeps its own offset (R20.1-1).
                let noise: Double
                if i % 2 == 0 {
                    pairNoise = rng.nextGaussian()
                    noise = pairNoise
                } else {
                    noise = -pairNoise
                }
                speedOffset[i] = decay * speedOffset[i] + sigmaOffset * noise
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
        lastMovingStepNs = ns
        // A vetoed step's held speed is what OBD says (0), not the Doppler
        // speed it moved at: the course veto of fixes taken then reads it
        // (R53.1-2), so a car parked on a ferry keeps its gyro heading.
        history.append(ns, cumulativeEast, cumulativeNorth, cumulativeYaw, speed: stale ? nil : vObd,
                       held: vetoed ? heldOBDSpeed : vObd)
        recordMotion(at: ns, obdDistance: vObd * dt)
        cumulativeOBDM += vObd * dt
        if counters.steps % reanchorCheckSteps == 0 {
            reanchorIfNeeded()
        }
        if roadsActive {
            roadDistanceM += meanSpeed * dt
            roadUpdateIfDue(at: ns)
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
        motionEast[i] += dEast
        motionNorth[i] += dNorth
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
        var pairNoise = (0.0, 0.0)
        for i in 0..<east.count {
            let (n1, n2) = rng.nextGaussianPair()
            // Antithetic increments, as in `step`: the pair shares
            // (n3, n4), negated; x0 is each particle's own.
            if i % 2 == 0 { pairNoise = rng.nextGaussianPair() }
            let (n3, n4) = i % 2 == 0 ? pairNoise : (-pairNoise.0, -pairNoise.1)
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
        lastMovingStepNs = ns
        history.append(ns, cumulativeEast, cumulativeNorth, cumulativeYaw, speed: nil, held: heldOBDSpeed)
        recordMotion(at: ns, obdDistance: vObd * dt)
        cumulativeOBDM += vObd * dt
        if counters.steps / reanchorCheckSteps != checkBefore {
            reanchorIfNeeded()
        }
        // Never a road update inside a catch-up; its distance counts
        // towards the next one.
        if roadsActive { roadDistanceM += meanSpeed * dt }
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
    mutating func reanchorIfNeeded() {
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
        for i in 0..<east.count {
            (motionEast[i], motionNorth[i]) = linear(motionEast[i], motionNorth[i])
        }
        motionRing.transform(linear)
        for k in fixPin.indices {
            fixPin[k].transform(map: map, jee: jee, jen: jen, jne: jne, jnn: jnn)
        }
        tangentPlane = new
        roads?.clearCache()
        counters.reanchors += 1
    }

    /// Speed is known again: every particle's stale-speed error is 0.
    private mutating func resetSpeedOffsets() {
        for i in speedOffset.indices { speedOffset[i] = 0 }
        speedOffsetsActive = false
    }

    // MARK: Initialisation

    /// `covariance`: the position covariance (a restored prior) instead
    /// of `sigma`² on each axis.
    private mutating func initialize(
        latitude: Double, longitude: Double, sigma: Double,
        heading course: (radians: Double, sigma: Double)?, at ns: Int64,
        covariance: (ee: Double, en: Double, nn: Double)? = nil
    ) {
        let plane = LocalTangentPlane(latitude: latitude, longitude: longitude)
        tangentPlane = plane
        let n = config.particleCount
        east = [Double](repeating: 0, count: n)
        north = east
        covEE = [Double](repeating: sigma * sigma, count: n)
        covEN = east
        covNN = covEE
        if let covariance {
            covEE = [Double](repeating: covariance.ee, count: n)
            covEN = [Double](repeating: covariance.en, count: n)
            covNN = [Double](repeating: covariance.nn, count: n)
        }
        heading = east
        scale = east
        speedOffset = east
        motionEast = east
        motionNorth = east
        logWeight = [Double](repeating: -log(Double(n)), count: n)
        weight = [Double](repeating: 1 / Double(n), count: n)
        effectiveSampleSize = Double(n)
        if roads != nil {
            roadEdge = [UInt32](repeating: RoadMatcher.noEdge, count: n)
            roadLevel = [Int8](repeating: RoadGeometry.unknownLevel, count: n)
            offRoadM = east
        }
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
        lastMovingStepNs = nil
        history.removeAll()
        history.append(lastStepNs ?? ns, 0, 0, 0, speed: nil, held: heldOBDSpeed)
        motionRing.removeAll(particles: n)
        recordMotion(at: lastStepNs ?? ns)
        lastStepStationary = isStopped(at: ns)
        lastMeanSpeed = 0
    }

    // MARK: Restored prior (UX-20)

    /// The first input has arrived: seed the cloud from `prior` grown for
    /// the gap since it was saved (`NavigationPrior.seed`), through
    /// `initialize` with the same random draws as a first fix (one heading
    /// draw, Gaussian or stratified uniform, and one scale draw per
    /// particle). Too uncertain: nothing is seeded (`.none`,
    /// `.tooUncertain`) and the run starts as without a prior. A stopped
    /// class holds the cloud parked until OBD or the IMU says otherwise,
    /// and its first OBD reply decides (`resolvePriorAtFirstOBD`).
    private mutating func applyPrior(at arrival: Int64) {
        guard let prior else { return }
        priorApplied = true
        restore.savedT = prior.savedT
        // The first input sets the grid exactly so (`advance`).
        if lastStepNs == nil { lastStepNs = Self.floorToGrid(arrival, stepNs) }
        let gap = (Double(arrival) - Double(prior.savedT.nanoseconds)) / 1e9
        guard let seed = prior.seed(gapS: gap) else {
            restore.status = .none
            restore.reason = .tooUncertain
            return
        }
        seedFromPrior(prior, seed, at: arrival)
        restore.status = .unconfirmed
        if prior.restoreClass != .moving {
            priorAwaitingOBD = true
            if obdSpeedKmh == nil {
                parkedSinceZero = true
                lastStepStationary = true
            }
        }
    }

    /// The cloud at the grown prior: every particle at the (carried
    /// forward) mean with the grown covariance. Gaussian headings are then
    /// rescaled about the mean so the cloud's circular std is the grown σ
    /// (no extra random draw): `converged` (std under the threshold) then
    /// follows the grown σ, not the sampling noise of N draws, so a tight
    /// hand-over keeps it.
    private mutating func seedFromPrior(_ prior: NavigationPrior, _ seed: NavigationPrior.Seed, at ns: Int64) {
        let heading: (radians: Double, sigma: Double)? = seed.headingRadians.map { ($0, seed.headingSigmaRadians ?? 0) }
        var latitude = prior.latitude, longitude = prior.longitude
        if seed.shiftEastM != 0 || seed.shiftNorthM != 0 {
            let p = LocalTangentPlane(latitude: latitude, longitude: longitude)
                .geodetic(east: seed.shiftEastM, north: seed.shiftNorthM)
            latitude = p.latitude
            longitude = p.longitude
        }
        initialize(latitude: latitude, longitude: longitude, sigma: 0, heading: heading, at: ns,
                   covariance: (seed.covEE, seed.covEN, seed.covNN))
        guard let heading, heading.sigma > 0 else { return }
        // Small-angle rescale, iterated: exact to well under 1e-6 rad for
        // σ ≤ 30°.
        for _ in 0..<3 {
            let actual = headingStdRadians()
            guard actual > 0, actual.isFinite else { return }
            let k = heading.sigma / actual
            if abs(k - 1) < 1e-9 { return }
            for i in self.heading.indices {
                self.heading[i] = Self.wrap2Pi(heading.radians + k * Self.wrapPi(self.heading[i] - heading.radians))
            }
        }
    }

    /// The first OBD vehicle-speed reply after a stopped-class prior was
    /// seeded: 0 keeps it; moving (the car was driving when the run
    /// started) regrows it as moving for the gap up to this reply, or, too
    /// wide, rejects it (`.movingAtStart`) and the engine waits for a fix
    /// or pin as without a prior. Only while unconfirmed.
    private mutating func resolvePriorAtFirstOBD(at ns: Int64) {
        priorAwaitingOBD = false
        guard restore.status == .unconfirmed, let prior, let v = obdSpeedKmh, v > 0 else { return }
        restore.regrownAsMoving = true
        discardPrior()
        let gap = (Double(ns) - Double(prior.savedT.nanoseconds)) / 1e9
        if let seed = prior.seed(gapS: gap, movingAtStart: true) {
            seedFromPrior(prior, seed, at: ns)
        } else {
            restore.status = .rejected
            restore.reason = .movingAtStart
            restore.decidedT = MonotonicTimestamp(nanoseconds: ns)
        }
    }

    /// An unconfirmed prior against a fix (σ `sigma`, today's per-axis σ
    /// with any stale growth): d² = rᵀ (Σ_cloud + σ² I)⁻¹ r, untempered,
    /// with r the fix shifted to now minus the cloud's mean. Over
    /// `rejectChi2`: rejected, and the engine is uninitialised so the fix
    /// initialises it as a first fix. Agreeing: confirmed when the fix is
    /// not a tower fix and σ ≤ max(the cloud's major-axis σ,
    /// `confirmMinSigmaM`); otherwise still unconfirmed. Either way the fix
    /// is then used as usual.
    private mutating func judgeRestore(_ sample: LocationSample, fixNs: Int64, arrivalNs: Int64, sigma: Double,
                                       network: Bool) {
        guard let plane = tangentPlane else { return }
        let fix = plane.enu(latitude: sample.latitude, longitude: sample.longitude)
        let since = shiftSince(fixNs)
        let tower = network && sample.horizontalAccuracy > NavigationRestoreModel.towerAccuracyM
        judgeRestore(east: fix.east + since.east, north: fix.north + since.north, sigma: sigma, reason: .fix,
                     canConfirm: { major in !tower && sigma <= max(major, NavigationRestoreModel.confirmMinSigmaM) },
                     at: arrivalNs)
    }

    /// The same for a pin (σ from `manualFixSigma`, shifted by the cloud's
    /// mean motion since its `t`): an agreeing pin always confirms; a
    /// disagreeing one rejects, and the pin then initialises the engine
    /// (uniform heading) as a first pin.
    private mutating func judgeRestore(pin sample: ManualFixSample, at ns: Int64, sigma: Double) {
        guard let plane = tangentPlane else { return }
        let pin = plane.enu(latitude: sample.latitude, longitude: sample.longitude)
        let since = shiftSince(ns)
        judgeRestore(east: pin.east + since.east, north: pin.north + since.north, sigma: sigma, reason: .pin,
                     canConfirm: { _ in true }, at: ns)
    }

    private mutating func judgeRestore(east e: Double, north n: Double, sigma: Double, reason: NavigationRestore.Reason,
                                       canConfirm: (Double) -> Bool, at ns: Int64) {
        let m = cloudMoments()
        let s2 = sigma * sigma
        let d2 = Self.chi2(e - m.east, n - m.north, ee: m.ee + s2, en: m.en, nn: m.nn + s2)
        if d2 > NavigationRestoreModel.rejectChi2 {
            discardPrior()
            restore.status = .rejected
        } else if canConfirm(NavigationPrior.majorVariance(m.ee, m.en, m.nn).squareRoot()) {
            restore.status = .confirmed
        } else {
            return
        }
        restore.reason = reason
        restore.decidedT = MonotonicTimestamp(nanoseconds: ns)
    }

    /// Back to the state before initialisation, the clock, OBD, motion and
    /// counters kept: what a run without a prior has before its first fix
    /// or pin. The pre-initialisation record kept while unconfirmed lets
    /// a late pin initialise as it would there.
    private mutating func discardPrior() {
        tangentPlane = nil
        east = []
        north = []
        covEE = []
        covEN = []
        covNN = []
        heading = []
        scale = []
        speedOffset = []
        motionEast = []
        motionNorth = []
        logWeight = []
        weight = []
        effectiveSampleSize = 0
        roadEdge = []
        roadLevel = []
        offRoadM = []
        speedOffsetsActive = false
        lastStepStationary = true
        lastMeanSpeed = 0
        cumulativeEast = 0
        cumulativeNorth = 0
        cumulativeYaw = 0
        history.removeAll()
        motionRing.removeAll(particles: config.particleCount)
        lastNetworkFixNs = nil
        lastMovingStepNs = nil
        roadDistanceM = 0
        lastRoadAttemptNs = nil
        roadShare = nil
        roadMatchedEdge = nil
        if !fixPin.isEmpty { fixPin = FixPinSource.Kind.allCases.map { _ in FixPinSource() } }
        lastManualFixNs = nil
        cumulativeOBDM = 0
        lastFixPinDecision = nil
        // The prior's parked hold, not an OBD 0.
        if obdSpeedKmh == nil { parkedSinceZero = false }
        priorAwaitingOBD = false
    }

    /// The last OBD vehicle speed from the primary ECU (raw km/h) and its
    /// `t`; nil before the first reply.
    public var lastOBDSpeed: (kmh: Double, t: MonotonicTimestamp)? {
        guard let v = obdSpeedKmh, let t = obdNs else { return nil }
        return (v, MonotonicTimestamp(nanoseconds: t))
    }

    /// How the car is left at `t`, for a saved state (UX-20):
    /// - `.parked`: the last OBD reply is 0, not vetoed by moving fixes,
    ///   and either `engineOff` (the app knows: ignition off, Navigate's
    ///   auto-stop) or the engine's parked state (stale after the 0, no IMU
    ///   sign of motion since);
    /// - `.standingStop`: a fresh, unvetoed OBD 0 whose run of zeros began
    ///   at least `standingStopMinZeroS` before `t`;
    /// - `.moving`: anything else, no OBD reply included. `engineOff` with
    ///   a moving last reply is moving: a link lost mid-drive is not a
    ///   parked car.
    public func restoreClass(at t: MonotonicTimestamp, engineOff: Bool) -> NavigationRestoreClass {
        let ns = t.nanoseconds
        guard let v = obdSpeedKmh, let tObd = obdNs, v == 0, !zeroVetoed(at: ns) else { return .moving }
        let fresh = (Double(ns) - Double(tObd)) / 1e9 <= config.obdMaxAgeS
        if engineOff || (!fresh && parkedSinceZero) { return .parked }
        if fresh, let since = zeroFix.zeroSinceNs,
           (Double(ns) - Double(since)) / 1e9 >= NavigationRestoreModel.standingStopMinZeroS {
            return .standingStop
        }
        return .moving
    }

    // MARK: Location fixes

    private mutating func ingestLocation(_ sample: LocationSample, fixNs: Int64, arrivalNs: Int64) {
        let accuracy = sample.horizontalAccuracy
        guard accuracy >= 0, accuracy.isFinite, sample.latitude.isFinite, sample.longitude.isFinite,
              abs(sample.latitude) <= 90, abs(sample.longitude) <= 180 else {
            counters.fixesIgnoredInvalid += 1
            return
        }
        if let saved = restore.savedT, restore.status == .unconfirmed || restore.status == .confirmed,
           fixNs < saved.nanoseconds {
            // A cached fix older than the restored state: the state is newer
            // information (UX-20).
            restore.fixesOlderThanSave += 1
            return
        }
        noteZeroFixEvidence(sample, fixNs: fixNs)
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
        if age > config.maxFixAgeS, let moved = lastMovingStepNs, fixNs < moved {
            // Stopped now, but the car moved after the fix: the motion
            // history (~`maxFixAgeS`) may not reach back to the fix, and
            // what it misses would be left unshifted (R11.1-5). Since the
            // last moving step every step was a ZUPT or parked step, so a
            // fix at or after it needs no shift at all.
            counters.staleFixesIgnoredMoved += 1
            counters.fixesIgnoredStale += 1
            return
        }
        // No Doppler speed: a cell-tower or Wi-Fi position, whatever its
        // claimed accuracy.
        let network = !sample.hasValidSpeed
        let sigma = max(accuracy * config.fixSigmaPerAccuracy, config.fixSigmaFloorM)
            * (network ? config.networkFixInflation : 1)
            + Self.staleGrowth(fixNs: fixNs, age: age, config: config, sample: sample)
        if restore.status == .unconfirmed {
            // May reject the prior: the engine is then uninitialised and
            // this fix initialises it below, as a fresh engine's first fix.
            judgeRestore(sample, fixNs: fixNs, arrivalNs: arrivalNs, sigma: sigma, network: network)
        }
        // Course needs real motion: GNSS reports a few m/s of speed noise
        // while parked, so an OBD speed under the threshold vetoes it. The
        // speed checked is the one OBD last reported at the fix time, fresh
        // or stale (R11.1-4): a stale 0 (the link dropped while parked) and
        // no OBD reply at all (parked before the adapter connects) veto; a
        // stale moving speed (a dropout while driving) does not.
        let since = shiftSince(fixNs)
        let obdAtFix: Double? = tangentPlane == nil ? (isStopped(at: arrivalNs) ? 0 : nil) : since.obdSpeed
        let heldAtFix: Double? = tangentPlane == nil ? heldOBDSpeed : since.heldOBDSpeed
        var dopplerConsistent = true
        if sample.speed >= 0, let v = obdAtFix {
            dopplerConsistent = abs(sample.speed - v) <= max(config.gnssSpeedGateMps, config.gnssSpeedGateFraction * v)
        }
        let courseValid = sample.hasValidCourse && sample.speed >= config.courseMinSpeedMps
            && (heldAtFix ?? 0) >= config.courseMinSpeedMps && dopplerConsistent
        let courseSigma = max(sample.courseAccuracy, config.courseSigmaFloorDeg) * .pi / 180
        let clean = accuracy <= config.cleanFixAccM && courseValid

        guard let plane = tangentPlane else {
            // The cloud starts at the fix, but the car has moved for the
            // fix's age since (R11.2-3): no motion history exists yet to
            // shift it. Its σ grows by that distance, in quadrature.
            let travelled = Self.initialisationSpeed(fresh: isFresh(at: arrivalNs) ? heldOBDSpeed : nil,
                                                     sample: sample) * age
            initialize(
                latitude: sample.latitude, longitude: sample.longitude,
                sigma: (sigma * sigma + travelled * travelled).squareRoot(),
                heading: clean ? (sample.course * .pi / 180, courseSigma) : nil, at: fixNs
            )
            counters.fixesUsed += 1
            if !network { lastGNSSFixUsedNs = max(lastGNSSFixUsedNs ?? arrivalNs, arrivalNs) }
            if network {
                counters.networkFixesUsed += 1
                lastNetworkFixNs = fixNs
            } else if !fixPin.isEmpty, let plane = tangentPlane {
                let kind = FixPinSource.Kind(accessory: sample.accessory)
                let p = plane.enu(latitude: sample.latitude, longitude: sample.longitude)
                fixPin[kind.rawValue].append(
                    .init(ns: fixNs, east: p.east, north: p.north, course: courseValid ? sample.course * .pi / 180 : nil,
                          sigma: sigma), windowNs: fixPinWindowNs)
                fixPin[kind.rawValue].lastPositionNs = fixNs
            }
            return
        }

        let fix = plane.enu(latitude: sample.latitude, longitude: sample.longitude)
        let targetEast = fix.east + since.east
        let targetNorth = fix.north + since.north
        let targetCourse = sample.course * .pi / 180 + since.yaw

        // N3-FIXPIN: a GNSS fix joins its source's ring (as given, before
        // the road gate: an off-road fix is road evidence too).
        let source: FixPinSource.Kind? = network || fixPin.isEmpty ? nil : FixPinSource.Kind(accessory: sample.accessory)
        if let source {
            fixPin[source.rawValue].append(
                .init(ns: fixNs, east: fix.east, north: fix.north, course: courseValid ? sample.course * .pi / 180 : nil,
                      sigma: sigma), windowNs: fixPinWindowNs)
        }

        if !network, rejectsOffRoad(east: targetEast, north: targetNorth, sigma: sigma,
                                    course: courseValid ? targetCourse : nil, arrivalNs: arrivalNs, plane: plane) {
            counters.fixesRejectedOffRoad += 1
            if let source, fixPin[source.rawValue].isDownweighted {
                counters.addFixPin(\.fixPinRejectedOffRoadDownweightedAccessory,
                                   \.fixPinRejectedOffRoadDownweightedPhone, source)
            }
            return
        }

        // A down-weighted source may win back first (agreement, roads); if
        // it stays down-weighted it never reseeds the cloud.
        if let source, fixPin[source.rawValue].isDownweighted {
            fixPinWinBack(source, east: targetEast, north: targetNorth, sigma: sigma, fixNs: fixNs, plane: plane)
        }
        let downweighted = source.map { fixPin[$0.rawValue].isDownweighted } ?? false

        if clean && (headingStdRadians() > config.reseedHeadingStdDeg * .pi / 180
                     || !courseHasSupport(targetCourse, sigma: courseSigma)) {
            if downweighted {
                counters.fixPinReseedsBlocked += 1
            } else {
                reseed(east: targetEast, north: targetNorth, sigma: sigma, course: targetCourse, courseSigma: courseSigma)
            }
        }

        var temper = 1.0
        var positionSigma = sigma
        if network {
            temper = Self.networkTemper(
                sinceLastS: lastNetworkFixNs.map { Double(fixNs - $0) / 1e9 }, correlationS: config.networkFixCorrelationS
            )
            lastNetworkFixNs = max(lastNetworkFixNs ?? fixNs, fixNs)
            counters.networkFixesUsed += 1
        } else if let source {
            let k = source.rawValue
            if let offset = fixPin[k].offset {
                // Down-weighted: σ at least the offset, tempered like a
                // network fix by the time since this source's last fix.
                positionSigma = max(sigma, (offset.east * offset.east + offset.north * offset.north).squareRoot())
                    * config.fixPinInflation
                temper = Self.networkTemper(sinceLastS: fixPin[k].lastPositionNs.map { Double(fixNs - $0) / 1e9 },
                                            correlationS: config.networkFixCorrelationS)
                counters.addFixPin(\.fixPinDownweightedFixesAccessory, \.fixPinDownweightedFixesPhone, source)
            }
            fixPin[k].lastPositionNs = max(fixPin[k].lastPositionNs ?? fixNs, fixNs)
        }
        counters.fixesUsed += 1
        if !network { lastGNSSFixUsedNs = max(lastGNSSFixUsedNs ?? arrivalNs, arrivalNs) }

        // Tempering a Gaussian likelihood by w is the same as dividing its
        // precision by w: R = σ² / w.
        let positionVariance = temper > 0 ? positionSigma * positionSigma / temper : .infinity
        let useSpeed = sample.hasValidSpeed && (since.obdSpeed ?? 0) * 3.6 > config.speedUpdateMinKmh && dopplerConsistent
        let obdSpeed = since.obdSpeed ?? 0
        let speedSigma = max(sample.speedAccuracy, config.speedSigmaFloorMps)
        if courseValid { counters.courseUpdates += 1 }
        if useSpeed { counters.speedUpdates += 1 }
        if let source, downweighted {
            if courseValid {
                counters.addFixPin(\.fixPinCourseUpdatesDownweightedAccessory, \.fixPinCourseUpdatesDownweightedPhone, source)
            }
            if useSpeed {
                counters.addFixPin(\.fixPinSpeedUpdatesDownweightedAccessory, \.fixPinSpeedUpdatesDownweightedPhone, source)
            }
        }
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

    /// Extra σ of a stale fix: max(`staleFixSigmaGrowthMps`, the fix's own
    /// valid Doppler speed) × age when the fix is older than `staleFixAgeS`
    /// at ingest (a pre-session fix from minutes ago, or a relaunch
    /// mid-drive); 0 otherwise, and 0 while `staleFixSigmaGrowthMps` ≤ 0
    /// (disabled). A pre-session fix only a fraction of a second old is not
    /// stale. NAV-INITSTALE: a cached fix taken at 13 km/h 46 s before the
    /// session was 223 m off at the first pin; at 1 m/s × age its σ was a
    /// quarter of that. The car drove on at about its fix speed for an
    /// unknown part of the age, so that speed bounds the distance.
    static func staleGrowth(fixNs: Int64, age: Double, config: NavigationConfig, sample: LocationSample) -> Double {
        guard age > config.staleFixAgeS, config.staleFixSigmaGrowthMps > 0 else { return 0 }
        let fixSpeed = sample.hasValidSpeed && sample.speed.isFinite ? sample.speed : 0
        return max(config.staleFixSigmaGrowthMps, fixSpeed) * age
    }

    /// Speed for the age allowance of a fix that initialises the engine,
    /// m/s: the fresh OBD speed at its arrival (`fresh`, with the truncation
    /// offset; 0 when stopped), else the fix's own Doppler speed when
    /// valid, else 0.
    static func initialisationSpeed(fresh: Double?, sample: LocationSample) -> Double {
        if let fresh { return fresh }
        return sample.hasValidSpeed && sample.speed.isFinite ? sample.speed : 0
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
        let basis = motionRing.reconstructionBasis(cumulativeYaw: cumulativeYaw)
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
            if roads != nil { clearRoadState(i) }
            // A new particle has no past of its own: reconstruct it as if
            // it had always had this heading and scale (not the cloud's
            // mean motion, about 0 while heading is unknown, which is when
            // reseeds happen).
            motionRing.reconstructHistory(particle: i, heading: heading[i], scale: scale[i],
                                          motionEast: motionEast[i], motionNorth: motionNorth[i], basis: basis)
        }
        normalizeWeights()
    }

    // MARK: Manual fixes

    private mutating func ingestManualFix(_ sample: ManualFixSample, at ns: Int64) {
        if !fixPin.isEmpty { lastFixPinDecision = nil }
        guard sample.latitude.isFinite, sample.longitude.isFinite,
              abs(sample.latitude) <= 90, abs(sample.longitude) <= 180 else { return }
        counters.manualFixes += 1
        let sigma = config.manualFixSigma(sample, at: MonotonicTimestamp(nanoseconds: ns))
        if restore.status == .unconfirmed {
            // May reject the prior: the pin then initialises the engine
            // below (uniform heading), as a fresh engine's first pin.
            judgeRestore(pin: sample, at: ns, sigma: sigma)
        }
        // N3-FIXPIN refinement rule, causal: the previous manual fix's `t` is
        // at most `fixPinRefinementWindowS` before this one (the replay's
        // pair rule, which is scoring only, on the pins ingested so far).
        var refinement = false
        if !fixPin.isEmpty {
            refinement = lastManualFixNs.map { Double(ns) - Double($0) <= Self.fixPinRefinementWindowS * 1e9 } ?? false
            lastManualFixNs = ns
        }
        // Late: grid steps already ran after the pin's own instant (the app
        // writes a double-tap pin when its undo window closes). In arrival
        // order the engine has just stepped to floor(t): never late.
        // `lateManualFixWindowS` 0 restores the mean shift for every pin.
        let tapStepNs = Self.floorToGrid(ns, stepNs)
        let late = config.lateManualFixWindowS > 0 && (lastStepNs.map { tapStepNs < $0 } ?? false)
        guard let plane = tangentPlane else {
            initialize(latitude: sample.latitude, longitude: sample.longitude, sigma: sigma, heading: nil, at: ns)
            if late {
                counters.lateManualFixes += 1
                predictLateInitialisation(fromStep: tapStepNs)
            }
            anchorToRoad(sample, restarted: true)
            return
        }
        let pin = plane.enu(latitude: sample.latitude, longitude: sample.longitude)
        // The pin as each particle sees it now. Not late (arrival order):
        // shifted by the cloud's mean motion since `t`, which is 0 there.
        // Late: by each particle's own motion since `t` (`lateMotion`).
        let since = shiftSince(ns)
        var targetEast = [Double](repeating: pin.east + since.east, count: east.count)
        var targetNorth = [Double](repeating: pin.north + since.north, count: east.count)
        if late {
            counters.lateManualFixes += 1
            if motionRing.slot(atOrBefore: ns) == nil { counters.lateManualFixesMeanShift += 1 }
            if let motion = lateMotion(since: ns, meanShift: (since.east, since.north)) {
                for i in 0..<east.count {
                    targetEast[i] = pin.east + motion.east[i]
                    targetNorth[i] = pin.north + motion.north[i]
                }
            }
        }
        // Covariance: compared with each particle's Gaussian now, not at
        // `t`; the along/cross-track noise grown since `t` (≤ 0.36 m²/m ×
        // v × 3 s ≈ 27 m² at 25 m/s, against R ≥ 900 m²) is left in, which
        // widens the likelihood by < 1.5 % in σ (conservative) and leaves
        // the posterior at most that Q too tight (σ ≈ 0.4 m at 30 m).
        if !fixPin.isEmpty {
            judgeFixPin(ns: ns, sigma: sigma, targetEast: targetEast, targetNorth: targetNorth, refinement: refinement,
                        plane: plane)
        }
        let prior = (logWeight, east, north, covEE, covEN, covNN)
        var nearest = Double.infinity
        for i in 0..<east.count {
            let update = positionUpdate(i, east: targetEast[i], north: targetNorth[i], variance: sigma * sigma)
            logWeight[i] += update.logLikelihood
            nearest = min(nearest, update.mahalanobis2)
        }
        normalizeWeights()
        // Reset only when no particle is statistically compatible with the
        // pin. A low ESS with a compatible particle is the pin being most
        // informative (a ring-shaped cloud after km of unknown heading): keep
        // that posterior and resample (R13.1-1).
        let reset = nearest > config.manualFixResetChi2
        if reset {
            // The prior has practically no support at the pin: the driver's
            // "I'm here" wins. Positions restart at it (a late pin: at it
            // plus each particle's own motion since); heading and scale
            // hypotheses and their weights are kept.
            counters.manualResets += 1
            (logWeight, east, north, covEE, covEN, covNN) = prior
            for i in 0..<east.count {
                east[i] = targetEast[i]
                north[i] = targetNorth[i]
                covEE[i] = sigma * sigma
                covEN[i] = 0
                covNN[i] = sigma * sigma
                speedOffset[i] = 0
                if roads != nil { clearRoadState(i) }
            }
            normalizeWeights()
        }
        resampleIfNeeded()
        anchorToRoad(sample, restarted: reset)
    }

    /// Each particle's own motion since `ns`, for a late manual fix
    /// (R14.3-1): its prediction displacement since the latest ring
    /// snapshot at or before `ns`. When `ns` is older than the ring, the
    /// displacement since the oldest snapshot plus the cloud's mean motion
    /// from `ns` to it: `meanShift` (the mean motion since `ns`) minus the
    /// mean motion since the oldest snapshot (counted in
    /// `lateManualFixesMeanShift`). nil when the ring is empty
    /// (`lateManualFixWindowS` 0).
    func lateMotion(since ns: Int64, meanShift: (east: Double, north: Double))
        -> (east: [Double], north: [Double])? {
        guard let oldest = motionRing.oldestSlot else { return nil }
        let inRing = motionRing.slot(atOrBefore: ns)
        let slot = inRing ?? oldest
        var extraEast = 0.0, extraNorth = 0.0
        if inRing == nil {
            let ringShift = shiftSince(motionRing.time(oldest))
            extraEast = meanShift.east - ringShift.east
            extraNorth = meanShift.north - ringShift.north
        }
        var e = [Double](repeating: 0, count: east.count), n = e
        for i in 0..<east.count {
            e[i] = (motionEast[i] - motionRing.east(slot, i)) + extraEast
            n[i] = (motionNorth[i] - motionRing.north(slot, i)) + extraNorth
        }
        return (e, n)
    }

    /// A late pin has just initialised the cloud at the tap (R14.3-1): move
    /// it forward over the grid steps run since `start` (the tap's grid
    /// step), as `step` would have moved it had the pin arrived at the tap.
    /// Deterministic, no random numbers: each particle moves along its own
    /// heading with the recorded yaw and OBD speed times its scale, and its
    /// covariance grows with the along/cross-track noise of that distance.
    /// The heading and scale random walks over these few seconds (≈ 0.1°,
    /// 2e-4) are left out. Stale steps add the unknown-speed (OU) integral
    /// variance along each particle's heading instead of drawing offsets.
    /// Time the record no longer covers (a pin later than
    /// `lateManualFixWindowS`) adds an isotropic (v × gap)² with the fastest
    /// speed seen, or the OU variance when no OBD speed is known.
    private mutating func predictLateInitialisation(fromStep start: Int64) {
        guard let now = lastStepNs, now > start else { return }
        let records = preInitSteps.records(endingAfter: start)
        let coveredFrom = records.first.map { max($0.fromNs, start) } ?? now
        let gapS = Double(coveredFrom - start) / 1e9
        let alongPerM = config.alongTrackNoisePerSqrtM * config.alongTrackNoisePerSqrtM
        let crossPerM = config.crossTrackNoisePerSqrtM * config.crossTrackNoisePerSqrtM
        var staleS = 0.0
        for r in records where r.kind == .stale {
            staleS += Double(r.toNs - max(r.fromNs, start)) / 1e9
        }
        let staleVariance = staleS > 0
            ? Self.ouIntegralVariance(dt: staleS, sigma: config.staleSpeedNoiseMpsPerSqrtS, tau: config.staleSpeedDecayS)
            : 0
        // The motion record starts at the tap's grid step, as if the pin had
        // initialised there (R14.4-1): the ring, the mean history and the
        // cumulative motion are backfilled step by step below, so a second
        // late pin tapped in this stretch finds each particle's own motion
        // since its tap, and a fix stamped in it finds its latency shift.
        history.removeAll()
        history.append(start, 0, 0, 0, speed: records.first?.historySpeed, held: records.first?.held)
        motionRing.removeAll(particles: east.count)
        recordMotion(at: start)
        var h = heading
        for r in records {
            let covered = Double(r.toNs - max(r.fromNs, start)) / 1e9
            var meanDEast = 0.0, meanDNorth = 0.0
            var dYaw = 0.0
            if r.kind != .frozen {
                let fraction = r.toNs > r.fromNs ? Double(r.toNs - max(r.fromNs, start)) / Double(r.toNs - r.fromNs) : 1
                dYaw = r.yaw * fraction
                for i in 0..<east.count {
                    let distance = r.speed * scale[i] * covered
                    let mid = h[i] + 0.5 * dYaw
                    let s = sin(mid), c = cos(mid)
                    let dEast = distance * s, dNorth = distance * c
                    east[i] += dEast
                    north[i] += dNorth
                    motionEast[i] += dEast
                    motionNorth[i] += dNorth
                    meanDEast += weight[i] * dEast
                    meanDNorth += weight[i] * dNorth
                    let qAlong = alongPerM * abs(distance), qCross = crossPerM * abs(distance)
                    covEE[i] += qAlong * s * s + qCross * c * c
                    covNN[i] += qAlong * c * c + qCross * s * s
                    covEN[i] += (qAlong - qCross) * s * c
                    h[i] += dYaw
                }
            }
            cumulativeEast += meanDEast
            cumulativeNorth += meanDNorth
            cumulativeYaw += dYaw
            history.append(r.toNs, cumulativeEast, cumulativeNorth, cumulativeYaw, speed: r.historySpeed, held: r.held)
            recordMotion(at: r.toNs, obdDistance: r.kind == .frozen ? 0 : r.speed * covered)
            cumulativeOBDM += r.kind == .frozen ? 0 : r.speed * covered
        }
        for i in 0..<east.count {
            heading[i] = Self.wrap2Pi(h[i])
            if staleVariance > 0 {
                let s = sin(heading[i]), c = cos(heading[i])
                covEE[i] += staleVariance * s * s
                covNN[i] += staleVariance * c * c
                covEN[i] += staleVariance * s * c
            }
        }
        if gapS > 0 {
            counters.lateManualFixesMeanShift += 1
            var v = isFresh(at: now) ? (obdSpeedKmh.map { $0 > 0 ? ($0 + config.obdSpeedOffsetKmh) / 3.6 : 0 } ?? 0) : 0
            for r in records { v = max(v, r.speed) }
            let extra = v > 0
                ? (v * gapS) * (v * gapS)
                : Self.ouIntegralVariance(dt: gapS, sigma: config.staleSpeedNoiseMpsPerSqrtS, tau: config.staleSpeedDecayS)
            for i in 0..<east.count {
                covEE[i] += extra
                covNN[i] += extra
            }
        }
        // The cloud moved over these steps: a stale fix from before them
        // is not shifted by the history either (R11.1-5).
        if let moved = records.last(where: { $0.kind != .frozen }) { lastMovingStepNs = moved.toNs }
        if let last = records.last {
            lastStepStationary = last.kind == .frozen
            var meanScale = 0.0
            for i in 0..<scale.count { meanScale += weight[i] * scale[i] }
            lastMeanSpeed = last.kind == .frozen ? 0 : last.speed * meanScale
        }
    }

    /// Records a grid step run before initialisation (`step` or the
    /// pre-initialisation clock jump in `advance`), with the branch `step`
    /// would take, for a late initialising pin.
    private mutating func recordPreInitStep(at ns: Int64, dt: Double, yaw: Double) {
        guard preInitSteps.capacity > 0 else { return }
        var fresh = false
        var v = 0.0
        if let kmh = obdSpeedKmh, let t = obdNs {
            fresh = Double(ns - t) / 1e9 <= config.obdMaxAgeS
            v = kmh > 0 ? (kmh + config.obdSpeedOffsetKmh) / 3.6 : 0
        }
        // No `zeroVetoed` here: a veto needs a recent moving fix, and a
        // fresh fix initialises the engine, so none holds before it.
        let kind: PreInitSteps.Kind = (fresh && v == 0) || (!fresh && parkedSinceZero) ? .frozen : fresh ? .known : .stale
        let from = ns - Int64((dt * 1e9).rounded())
        // The history entry `step` would have written: the fresh speed
        // (0 for a ZUPT), nil when stale or parked.
        preInitSteps.append(.init(fromNs: from, toNs: ns, yaw: yaw, speed: kind == .frozen ? 0 : v, kind: kind,
                                  historySpeed: fresh ? v : nil, held: heldOBDSpeed))
    }

    /// Snapshots every particle's own cumulative motion at grid step `ns`,
    /// with the step's cumulative yaw and its OBD distance before scale
    /// (`obdDistance`, m: 0 when frozen), from which a reseeded particle's
    /// past is reconstructed.
    private mutating func recordMotion(at ns: Int64, obdDistance: Double = 0) {
        guard motionRing.capacity > 0 else { return }
        motionRing.append(ns, east: motionEast, north: motionNorth, yaw: cumulativeYaw, obdDistance: obdDistance)
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

    // MARK: Roads (N3.2)

    /// A road particle's road state back to "on no road" (a reseed, a
    /// manual reset).
    private mutating func clearRoadState(_ i: Int) {
        roadEdge[i] = RoadMatcher.noEdge
        roadLevel[i] = RoadGeometry.unknownLevel
        offRoadM[i] = 0
    }

    /// At the end of a moving grid step: a road update once
    /// `roadUpdateIntervalS` of grid time has passed since the last attempt.
    private mutating func roadUpdateIfDue(at ns: Int64) {
        if let last = lastRoadAttemptNs, ns - last < roadIntervalNs { return }
        lastRoadAttemptNs = ns
        roadUpdate(evidenceDistanceM: roadDistanceM)
    }

    /// A pin with `gateSpeedKmh` ≥ `roadPinAnchorMinKmh` was taken while
    /// moving, so on a road: a road update right after it, whatever the
    /// interval. The pin gives the position along the road, the road the
    /// position across it. `restarted`: the pin initialised the engine or
    /// caused a manual reset, so every earlier road update's information
    /// is gone and the road under the pin counts in full (evidence
    /// distance at least `roadCorrelationM`, weight 1). A pin compatible
    /// with the cloud keeps that information: the anchor is an early
    /// regular update, tempered by the distance driven since the last one
    /// (R21.1-1; weight 1 there would count the same road twice and add
    /// `roadCorrelationM` off-road for ~0 m driven).
    private mutating func anchorToRoad(_ sample: ManualFixSample, restarted: Bool) {
        guard roadsActive, config.roadPinAnchorMinKmh > 0, let kmh = sample.gateSpeedKmh, kmh.isFinite,
              kmh >= config.roadPinAnchorMinKmh else { return }
        counters.roadPinAnchors += 1
        lastRoadAttemptNs = lastStepNs
        roadUpdate(evidenceDistanceM: restarted ? max(roadDistanceM, config.roadCorrelationM) : roadDistanceM)
    }

    /// The cloud's 95 % semi-major axis, metres (the mixture of every
    /// particle's Gaussian, as in `estimate(at:)`).
    private func cloudSemiMajorM() -> Double {
        var me = 0.0, mn = 0.0
        for i in 0..<east.count {
            me += weight[i] * east[i]
            mn += weight[i] * north[i]
        }
        var ee = 0.0, en = 0.0, nn = 0.0
        for i in 0..<east.count {
            let w = weight[i], de = east[i] - me, dn = north[i] - mn
            ee += w * (covEE[i] + de * de)
            en += w * (covEN[i] + de * dn)
            nn += w * (covNN[i] + dn * dn)
        }
        return ErrorEllipse(covarianceEE: ee, en: en, nn: nn).semiMajorM
    }

    /// One road update (docs/N3_PLAN.md, Steps 0–5), with evidence weight
    /// w = min(1, `evidenceDistanceM` / `roadCorrelationM`). Not engaged
    /// (cloud too wide) and no road near any particle are exact no-ops: no
    /// random number is drawn, and the distance keeps counting towards the
    /// next update.
    mutating func roadUpdate(evidenceDistanceM: Double) {
        // Moved out for the update, so its cache is not copied on write.
        guard let plane = tangentPlane, var matcher = roads.take() else { return }
        defer { roads = matcher }
        guard cloudSemiMajorM() <= config.roadEngageMaxEllipseM else {
            roadShare = nil
            roadMatchedEdge = nil
            return
        }
        let w = min(1, abs(evidenceDistanceM) / config.roadCorrelationM)
        let n = east.count
        let q = RoadMatcher.Parameters(config: config)

        // Step 0: is there any road within R of some particle's mean?
        matcher.beginUpdate()
        var cells = [(cx: Int32, cy: Int32)](repeating: (0, 0), count: n)
        for i in 0..<n { cells[i] = matcher.cell(east: east[i], north: north[i], plane: plane) }
        var slots = matcher.storeIndices(of: cells, plane: plane)
        var anyRoad = false
        for i in 0..<n where matcher.anySegment(inStoreCell: slots[i], px: east[i], py: north[i], radius: q.radius) {
            anyRoad = true
            break
        }
        guard anyRoad, w > 0 else {
            if !anyRoad {
                counters.roadUpdatesNoRoad += 1
                roadShare = 0
                roadMatchedEdge = nil
            }
            return
        }
        counters.roadUpdates += 1

        // Step 1: split Gaussians wider than σs, one Gaussian pair each. A
        // Gaussian already split to σs reads back a few ulps above it: the
        // relative margin keeps it from splitting again by nothing.
        let split2 = config.roadSplitSigmaM * config.roadSplitSigmaM
        let splitAbove = split2 * (1 + 1e-9)
        var moved = false
        for i in 0..<n {
            let a = covEE[i], b = covEN[i], c = covNN[i]
            let mean = (a + c) / 2
            let radius = (((a - c) / 2) * ((a - c) / 2) + b * b).squareRoot()
            let l1 = mean + radius, l2 = mean - radius
            guard l1 > splitAbove else { continue }
            counters.roadSplits += 1
            let (z1, z2) = rng.nextGaussianPair()
            let theta = 0.5 * atan2(2 * b, a - c)
            let v1e = cos(theta), v1n = sin(theta)
            let v2e = -v1n, v2n = v1e
            let s1 = (l1 - split2).squareRoot() * z1
            east[i] += v1e * s1
            north[i] += v1n * s1
            var k2 = l2
            if l2 > splitAbove {
                let s2 = (l2 - split2).squareRoot() * z2
                east[i] += v2e * s2
                north[i] += v2n * s2
                k2 = split2
            }
            covEE[i] = split2 * v1e * v1e + k2 * v2e * v2e
            covEN[i] = split2 * v1e * v1n + k2 * v2e * v2n
            covNN[i] = split2 * v1n * v1n + k2 * v2n * v2n
            moved = true
        }
        if moved {
            for i in 0..<n { cells[i] = matcher.cell(east: east[i], north: north[i], plane: plane) }
            slots = matcher.storeIndices(of: cells, plane: plane)
        }

        // Steps 2–4: candidate, mixture weight, cross-track update.
        let epsilon = config.roadOffRoadProbability
        let offRoad = epsilon / (2 * q.radius * 2 * .pi)
        let rw = q.sigmaRoad2 / w
        let coupling = config.roadAlongTrackCoupling
        var work = RoadMatcher.Work()
        var responsibility = [Double](repeating: 0, count: n)
        var chosen = [UInt32](repeating: RoadMatcher.noEdge, count: n)
        var chosenLevel = [Int8](repeating: RoadGeometry.unknownLevel, count: n)
        for i in 0..<n {
            let psi = heading[i]
            let candidate = matcher.best(
                inStoreCell: slots[i], px: east[i], py: north[i], sinPsi: sin(psi), cosPsi: cos(psi),
                ee: covEE[i], en: covEN[i], nn: covNN[i], level: roadLevel[i], edge: roadEdge[i],
                parameters: q, work: &work
            )
            guard let e = candidate else {
                logWeight[i] += w * log(offRoad)
                continue
            }
            let onRoad = (1 - epsilon) * exp(e.logLikelihood)
            let p = onRoad + offRoad
            let r = onRoad / p
            logWeight[i] += w * log(p)
            responsibility[i] = r
            chosen[i] = e.edge
            chosenLevel[i] = e.level
            // Road frame: h across (towards the particle), t along.
            let hx = e.hx, hy = e.hy, tx = -hy, ty = hx
            let pee = covEE[i], pen = covEN[i], pnn = covNN[i]
            let paa = tx * tx * pee + 2 * tx * ty * pen + ty * ty * pnn
            let pac = tx * hx * pee + (tx * hy + ty * hx) * pen + ty * hy * pnn
            let pcc = hx * hx * pee + 2 * hx * hy * pen + hy * hy * pnn
            let u = RoadMatcher.crossTrackUpdate(paa: paa, pac: pac, pcc: pcc, distance: e.distance, rw: rw,
                                                 coupling: coupling)
            // Moment-matched with the off-road branch, as a change to P so
            // that an unchanged road-frame entry stays bit-exact:
            // P ← P + r (P_upd − P) + r (1 − r) Δμ Δμᵀ.
            let mix = r * (1 - r)
            let dAA = r * (u.paa - paa) + mix * u.da * u.da
            let dAC = r * (u.pac - pac) + mix * u.da * u.dc
            let dCC = r * (u.pcc - pcc) + mix * u.dc * u.dc
            east[i] += r * (u.da * tx + u.dc * hx)
            north[i] += r * (u.da * ty + u.dc * hy)
            covEE[i] += tx * tx * dAA + 2 * tx * hx * dAC + hx * hx * dCC
            covEN[i] += tx * ty * dAA + (tx * hy + ty * hx) * dAC + hx * hy * dCC
            covNN[i] += ty * ty * dAA + 2 * ty * hy * dAC + hy * hy * dCC
        }
        counters.roadCandidateTests += work.tests
        counters.roadLevelBlocked += work.levelBlocked
        normalizeWeights()

        // Step 5: bookkeeping, and the share and edge for the estimate,
        // with the posterior weights.
        var share = 0.0
        var byEdge: [(edge: UInt32, mass: Double)] = []
        for i in 0..<n {
            let r = responsibility[i]
            if r >= 0.5 {
                roadEdge[i] = chosen[i]
                roadLevel[i] = chosenLevel[i]
                offRoadM[i] = 0
            } else {
                offRoadM[i] += abs(evidenceDistanceM)
                if offRoadM[i] > config.roadLevelForgetM { roadLevel[i] = RoadGeometry.unknownLevel }
            }
            if r > 0 {
                share += weight[i] * r
                byEdge.append((chosen[i], weight[i] * r))
            }
        }
        byEdge.sort { $0.edge < $1.edge }
        var best: (edge: UInt32, mass: Double)?
        var k = 0
        while k < byEdge.count {
            let edge = byEdge[k].edge
            var mass = 0.0
            while k < byEdge.count && byEdge[k].edge == edge {
                mass += byEdge[k].mass
                k += 1
            }
            if best.map({ mass > $0.mass }) ?? true { best = (edge, mass) }
        }
        roadShare = share
        roadMatchedEdge = share > 0 ? best.map { matcher.matchedEdge($0.edge) } : nil
        roadDistanceM = 0
        resampleIfNeeded()
    }

    /// The GNSS fix gate: a fix with a valid speed is ignored as a whole
    /// when roads are loaded and cover it, fresh OBD speed is at least
    /// `roadFixGateMinKmh`, the last road update put at least
    /// `roadFixGateOnRoadShare` of the cloud on a road, and no segment of
    /// any level lies within max(`roadFixGateMinM`, `roadFixGateSigma` · σ)
    /// of the (latency-shifted) fix — heading-compatible with its course
    /// when that is valid. Judged at the fix, not near the estimate: a fix
    /// on another road far from a wrong estimate is accepted, or the filter
    /// would confirm its own error (Q4).
    private mutating func rejectsOffRoad(
        east e: Double, north n: Double, sigma: Double, course: Double?, arrivalNs: Int64, plane: LocalTangentPlane
    ) -> Bool {
        guard roadsActive, config.roadFixGateSigma > 0,
              isFresh(at: arrivalNs), let kmh = obdSpeedKmh, kmh >= config.roadFixGateMinKmh,
              let share = roadShare, share >= config.roadFixGateOnRoadShare,
              var matcher = roads.take() else { return false }
        defer { roads = matcher }
        let p = plane.geodetic(east: e, north: n)
        guard matcher.network.covers(latitude: p.latitude, longitude: p.longitude) else { return false }
        let radius = max(config.roadFixGateMinM, config.roadFixGateSigma * sigma)
        let cosGate = cos(min(180, config.roadHeadingGateDeg) * .pi / 180)
        let near = matcher.anyCompatibleSegment(east: e, north: n, radius: radius, course: course,
                                                cosHeadingGate: cosGate, plane: plane)
        return !near
    }

    // MARK: Pin against a GNSS source (N3-FIXPIN)

    /// A manual fix at most this long after the previous one refines it
    /// and is not judged: the engine-side, causal form of the replay's
    /// scoring pair rule (`NavigationReplay.defaultPinPairWindowS`).
    public static let fixPinRefinementWindowS = 3.0
    /// χ² (2 dof) above which a pin's offset from the prior is significant,
    /// and under which a fix agrees with the estimate (win-back 2) or a pin
    /// with a source (win-back 3).
    static let fixPinSignificantChi2 = 9.0
    /// χ² (2 dof, 95 %) under which two pins' offsets agree.
    static let fixPinTwoPinAgreeChi2 = 5.991
    /// Road arbiter: distances capped here; at least this many fixes and
    /// this much fix path inside pack coverage.
    static let fixPinRoadCapM = 100.0
    static let fixPinRoadMinFixes = 20
    static let fixPinRoadMinPathM = 200.0
    /// Win-back by roads: re-evaluated this often while down-weighted.
    static let fixPinRoadRecheckS = 10.0
    /// Win-back by agreement: at least this many consecutive fixes.
    static let fixPinRestoreMinFixes = 15

    private var fixPinWindowNs: Int64 { Int64((config.fixPinWindowS * 1e9).rounded()) }

    /// Weighted mean and mixture covariance of the cloud.
    private func cloudMoments() -> (east: Double, north: Double, ee: Double, en: Double, nn: Double) {
        var me = 0.0, mn = 0.0
        for i in 0..<east.count {
            me += weight[i] * east[i]
            mn += weight[i] * north[i]
        }
        var ee = 0.0, en = 0.0, nn = 0.0
        for i in 0..<east.count {
            let w = weight[i], de = east[i] - me, dn = north[i] - mn
            ee += w * (covEE[i] + de * de)
            en += w * (covEN[i] + de * dn)
            nn += w * (covNN[i] + dn * dn)
        }
        return (me, mn, ee, en, nn)
    }

    /// dᵀ S⁻¹ d for a 2×2 symmetric S; +∞ when S is singular.
    static func chi2(_ de: Double, _ dn: Double, ee: Double, en: Double, nn: Double) -> Double {
        let det = ee * nn - en * en
        guard det > 0, det.isFinite else { return .infinity }
        return (de * de * nn - 2 * de * dn * en + dn * dn * ee) / det
    }

    /// The pin is about to be ingested (prior unchanged): its offset from
    /// the prior, and for each GNSS source with a fix in the window the
    /// arbiters, the action on a "pin" verdict, and win-back by a pin.
    /// Draws no random number. `targetEast/North`: the pin as each particle
    /// sees it (equal unless the pin is late).
    private mutating func judgeFixPin(ns: Int64, sigma: Double, targetEast: [Double], targetNorth: [Double],
                                      refinement: Bool, plane: LocalTangentPlane) {
        // Offset: the weighted mean innovation, and the spread of the
        // innovations (the prior's mixture covariance when not late).
        var de = 0.0, dn = 0.0
        for i in 0..<east.count {
            de += weight[i] * (targetEast[i] - east[i])
            dn += weight[i] * (targetNorth[i] - north[i])
        }
        var ee = 0.0, en = 0.0, nn = 0.0
        for i in 0..<east.count {
            let w = weight[i], ue = targetEast[i] - east[i] - de, un = targetNorth[i] - north[i] - dn
            ee += w * (covEE[i] + ue * ue)
            en += w * (covEN[i] + ue * un)
            nn += w * (covNN[i] + un * un)
        }
        let s2 = sigma * sigma
        let chi2 = Self.chi2(de, dn, ee: ee + s2, en: en, nn: nn + s2)
        let significant = chi2 > Self.fixPinSignificantChi2
        var decision = FixPinDecision(t: MonotonicTimestamp(nanoseconds: ns).seconds, refinement: refinement,
                                      offsetEastM: de, offsetNorthM: dn, chi2: chi2, significant: significant, sources: [])
        // The pin now, as the cloud sees it on average (equal to every
        // particle's target unless the pin is late).
        var pinNow = (east: 0.0, north: 0.0)
        for i in 0..<east.count {
            pinNow.east += weight[i] * targetEast[i]
            pinNow.north += weight[i] * targetNorth[i]
        }
        for kind in FixPinSource.Kind.allCases {
            let k = kind.rawValue
            fixPin[k].prune(before: ns - fixPinWindowNs)
            guard !fixPin[k].ring.isEmpty else { continue }
            var entry = FixPinDecision.Source(source: kind.name, fixesInWindow: fixPin[k].ring.count,
                                              wasDownweighted: fixPin[k].isDownweighted)
            defer { decision.sources.append(entry) }
            guard !refinement else { continue }
            if fixPin[k].isDownweighted {
                // Win-back 3: the pin agrees with the source's newest fix
                // (shifted to now; only one young enough for the motion
                // history to shift it).
                if let newest = fixPin[k].ring.last, Double(ns - newest.ns) / 1e9 <= config.maxFixAgeS {
                    let since = shiftSince(newest.ns)
                    let fe = newest.east + since.east, fn = newest.north + since.north
                    let v = newest.sigma * newest.sigma + s2
                    let c = Self.chi2(pinNow.east - fe, pinNow.north - fn, ee: v, en: 0, nn: v)
                    entry.sourceChi2 = c
                    if c <= Self.fixPinSignificantChi2 {
                        restoreFixPin(kind, reason: .pin)
                        entry.restored = true
                    }
                }
                // The prior follows the pin while down-weighted: its offset
                // says nothing about the source, so no arbiter runs and the
                // source's last independent pin stays the one that
                // down-weighted it.
                continue
            }
            var verdictPin = false
            if significant && config.roadFixPinCheck == 1 && roadsActive {
                let road = roadFixPinComparison(kind, shiftEast: de, shiftNorth: dn, plane: plane)
                var r = FixPinDecision.Road(fixes: road.fixes, pathM: road.pathM, asGivenM: road.a, shiftedM: road.b)
                if let a = road.a, let b = road.b {
                    r.verdict = fixPinRoadVerdict(a: a, b: b)
                }
                switch r.verdict {
                case .pin?: counters.addFixPin(\.fixPinRoadVerdictPinAccessory, \.fixPinRoadVerdictPinPhone, kind)
                case .fixes?: counters.addFixPin(\.fixPinRoadVerdictFixesAccessory, \.fixPinRoadVerdictFixesPhone, kind)
                case nil: counters.addFixPin(\.fixPinRoadVerdictNoneAccessory, \.fixPinRoadVerdictNonePhone, kind)
                }
                verdictPin = verdictPin || r.verdict == .pin
                entry.road = r
            }
            if significant && config.fixPinTwoPinCheck == 1, let previous = fixPin[k].lastPin {
                let c = Self.chi2(de - previous.dEast, dn - previous.dNorth,
                                  ee: ee + s2 + previous.ee, en: en + previous.en, nn: nn + s2 + previous.nn)
                let path = cumulativeOBDM - previous.obdM
                let turn = (cumulativeYaw - previous.yaw) * 180 / .pi
                var w = FixPinDecision.TwoPin(previousT: MonotonicTimestamp(nanoseconds: previous.ns).seconds, chi2: c,
                                              pathM: path, turnDeg: turn)
                if c <= Self.fixPinTwoPinAgreeChi2 && path >= config.fixPinTwoPinMinPathM
                    && abs(turn) >= config.fixPinTwoPinMinTurnDeg {
                    w.verdict = .pin
                    counters.addFixPin(\.fixPinTwoPinVerdictPinAccessory, \.fixPinTwoPinVerdictPinPhone, kind)
                } else {
                    counters.addFixPin(\.fixPinTwoPinVerdictNoneAccessory, \.fixPinTwoPinVerdictNonePhone, kind)
                }
                verdictPin = verdictPin || w.verdict == .pin
                entry.twoPin = w
            }
            fixPin[k].lastPin = .init(ns: ns, dEast: de, dNorth: dn, ee: ee + s2, en: en, nn: nn + s2,
                                      obdM: cumulativeOBDM, yaw: cumulativeYaw)
            if verdictPin {
                fixPin[k].offset = (de, dn)
                fixPin[k].agreeStartNs = nil
                fixPin[k].agreeCount = 0
                fixPin[k].lastRoadCheckNs = ns
                counters.addFixPin(\.fixPinDownweightsAccessory, \.fixPinDownweightsPhone, kind)
                entry.downweighted = true
            }
        }
        if significant && !refinement && !decision.sources.isEmpty { counters.fixPinSignificantPins += 1 }
        lastFixPinDecision = decision
    }

    /// The road arbiter's verdict on A (fixes as given) and B (shifted).
    private func fixPinRoadVerdict(a: Double, b: Double) -> FixPinDecision.Verdict? {
        let off = config.roadFixPinOffRoadM, margin = config.roadFixPinMarginM
        if a > off && b <= off && a - b >= margin { return .pin }
        if a <= off && b > off && b - a >= margin { return .fixes }
        return nil
    }

    /// Over `kind`'s ring fixes inside pack coverage: their count, path,
    /// and (with enough of both) the mean of min(distance to a
    /// heading-compatible road, cap) as given (a) and shifted (b).
    mutating func roadFixPinComparison(_ kind: FixPinSource.Kind, shiftEast: Double, shiftNorth: Double,
                                               plane: LocalTangentPlane)
        -> (fixes: Int, pathM: Double, a: Double?, b: Double?) {
        guard var matcher = roads.take() else { return (0, 0, nil, nil) }
        defer { roads = matcher }
        let k = kind.rawValue
        let cosGate = cos(min(180, config.roadHeadingGateDeg) * .pi / 180)
        var used: [Int] = []
        for j in fixPin[k].ring.indices {
            let fix = fixPin[k].ring[j]
            let covered: Bool
            if let c = fix.covered {
                covered = c
            } else {
                let g = plane.geodetic(east: fix.east, north: fix.north)
                covered = matcher.network.covers(latitude: g.latitude, longitude: g.longitude)
                fixPin[k].setCovered(j, covered)
            }
            if covered { used.append(j) }
        }
        var path = 0.0
        for (a, b) in zip(used, used.dropFirst()) {
            let p = fixPin[k].ring[a], q = fixPin[k].ring[b]
            path += ((q.east - p.east) * (q.east - p.east) + (q.north - p.north) * (q.north - p.north)).squareRoot()
        }
        guard used.count >= Self.fixPinRoadMinFixes, path >= Self.fixPinRoadMinPathM else {
            return (used.count, path, nil, nil)
        }
        // Cached per fix (exact: same fix, shift and plane give the same
        // distance), so a recheck queries only the fixes added since.
        if !(fixPin[k].roadShift.map { $0.east == shiftEast && $0.north == shiftNorth } ?? false) {
            fixPin[k].setRoadShift((shiftEast, shiftNorth))
        }
        var sumA = 0.0, sumB = 0.0
        for j in used {
            let fix = fixPin[k].ring[j]
            var a = fix.roadA, b = fix.roadB
            if a == nil {
                a = matcher.nearestCompatibleDistance(east: fix.east, north: fix.north, cap: Self.fixPinRoadCapM,
                                                      course: fix.course, cosHeadingGate: cosGate, plane: plane)
                counters.fixPinRoadDistanceQueries += 1
            }
            if b == nil {
                b = matcher.nearestCompatibleDistance(east: fix.east + shiftEast, north: fix.north + shiftNorth,
                                                      cap: Self.fixPinRoadCapM, course: fix.course,
                                                      cosHeadingGate: cosGate, plane: plane)
                counters.fixPinRoadDistanceQueries += 1
            }
            fixPin[k].setRoadDistances(j, a: a!, b: b!)
            sumA += a!
            sumB += b!
        }
        return (used.count, path, sumA / Double(used.count), sumB / Double(used.count))
    }

    /// Forgets every fix's cached road distances (tests: a cached value
    /// must equal a fresh query).
    mutating func clearFixPinRoadCache() {
        for k in fixPin.indices { fixPin[k].setRoadShift((.nan, .nan)) }
        for k in fixPin.indices {
            for j in fixPin[k].ring.indices { fixPin[k].clearRoadDistances(j) }
        }
    }

    enum FixPinRestoreReason { case roads, agreement, pin }

    private mutating func restoreFixPin(_ kind: FixPinSource.Kind, reason: FixPinRestoreReason) {
        let k = kind.rawValue
        fixPin[k].offset = nil
        fixPin[k].agreeStartNs = nil
        fixPin[k].agreeCount = 0
        fixPin[k].lastRoadCheckNs = nil
        switch reason {
        case .roads: counters.addFixPin(\.fixPinRestoresByRoadsAccessory, \.fixPinRestoresByRoadsPhone, kind)
        case .agreement: counters.addFixPin(\.fixPinRestoresByAgreementAccessory, \.fixPinRestoresByAgreementPhone, kind)
        case .pin: counters.addFixPin(\.fixPinRestoresByPinAccessory, \.fixPinRestoresByPinPhone, kind)
        }
    }

    /// A fix of a down-weighted source, before its update: win-back by
    /// roads (every `fixPinRoadRecheckS`, the road arbiter on the ring would
    /// now say "fixes") and by agreement (Mahalanobis² against the
    /// *claimed* σ plus the estimate's covariance under 9, for at least
    /// `fixPinRestoreS` and `fixPinRestoreMinFixes` consecutive fixes; a
    /// disagreeing fix restarts the run). `east/north`: the
    /// latency-shifted fix.
    private mutating func fixPinWinBack(_ kind: FixPinSource.Kind, east fe: Double, north fn: Double, sigma: Double,
                                        fixNs: Int64, plane: LocalTangentPlane) {
        let k = kind.rawValue
        guard let offset = fixPin[k].offset else { return }
        if config.roadFixPinCheck == 1, roadsActive,
           fixPin[k].lastRoadCheckNs.map({ Double(fixNs - $0) / 1e9 >= Self.fixPinRoadRecheckS }) ?? true {
            fixPin[k].lastRoadCheckNs = fixNs
            let road = roadFixPinComparison(kind, shiftEast: offset.east, shiftNorth: offset.north, plane: plane)
            counters.fixPinRoadRechecks += 1
            if let a = road.a, let b = road.b, fixPinRoadVerdict(a: a, b: b) == .fixes {
                restoreFixPin(kind, reason: .roads)
                return
            }
        }
        let m = cloudMoments()
        let s2 = sigma * sigma
        let c = Self.chi2(fe - m.east, fn - m.north, ee: m.ee + s2, en: m.en, nn: m.nn + s2)
        if c < Self.fixPinSignificantChi2 {
            if fixPin[k].agreeStartNs == nil { fixPin[k].agreeStartNs = fixNs }
            fixPin[k].agreeCount += 1
            let start = fixPin[k].agreeStartNs ?? fixNs
            if fixPin[k].agreeCount >= Self.fixPinRestoreMinFixes && Double(fixNs - start) / 1e9 >= config.fixPinRestoreS {
                restoreFixPin(kind, reason: .agreement)
            }
        } else {
            fixPin[k].agreeStartNs = nil
            fixPin[k].agreeCount = 0
        }
    }

    // MARK: Weights and resampling

    /// Internal, not private: the ring-consistency tests skew the weights
    /// and resample directly.
    mutating func normalizeWeights() {
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

    mutating func resampleIfNeeded() {
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
        var newMotionEast = motionEast, newMotionNorth = motionNorth
        let withRoads = !roadEdge.isEmpty
        var newRoadEdge = roadEdge, newRoadLevel = roadLevel, newOffRoad = offRoadM
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
            newMotionEast[i] = motionEast[k]
            newMotionNorth[i] = motionNorth[k]
            if withRoads {
                newRoadEdge[i] = roadEdge[k]
                newRoadLevel[i] = roadLevel[k]
                newOffRoad[i] = offRoadM[k]
            }
        }
        if withRoads {
            roadEdge = newRoadEdge
            roadLevel = newRoadLevel
            offRoadM = newOffRoad
        }
        motionRing.remap(indices)
        east = newEast
        north = newNorth
        covEE = newEE
        covEN = newEN
        covNN = newNN
        heading = newHeading
        scale = newScale
        speedOffset = newOffset
        motionEast = newMotionEast
        motionNorth = newMotionNorth
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
    /// Between two entries the cumulative motion is interpolated linearly
    /// (R11.2-2): the step from the entry at or before `ns` to the next one
    /// is uniform over its 0.1 s, so only the part after `ns` is motion
    /// since it. Without that, a fix 0.07 s after a grid step was pushed
    /// forward by 0.07 s × v. A time after the newest entry (the pending
    /// part of the current step) uses the newest. The OBD speeds are the
    /// entry's at or before `ns`.
    private func shiftSince(_ ns: Int64)
        -> (east: Double, north: Double, yaw: Double, obdSpeed: Double?, heldOBDSpeed: Double?) {
        guard let (entry, next) = history.entries(around: ns) else {
            return (0, 0, 0, nil, nil)
        }
        var e = entry.east, n = entry.north, y = entry.yaw
        if let next, next.t > entry.t, ns > entry.t {
            let f = Double(ns - entry.t) / Double(next.t - entry.t)
            e += f * (next.east - entry.east)
            n += f * (next.north - entry.north)
            y += f * (next.yaw - entry.yaw)
        }
        return (cumulativeEast - e, cumulativeNorth - n, cumulativeYaw - y, entry.speed, entry.held)
    }

    /// The motion-history entry a fix stamped `ns` reads (tests).
    func motionHistoryEntry(atOrBefore ns: Int64) -> MotionHistory.Entry? {
        history.entry(atOrBefore: ns)
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
            stationary: lastStepStationary,
            onRoadShare: roadShare,
            matchedEdge: roadMatchedEdge
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
        /// The OBD speed held at this step, fresh or stale (m/s); nil before
        /// the first reply (R11.1-4).
        var held: Double?
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

    mutating func append(_ t: Int64, _ east: Double, _ north: Double, _ yaw: Double, speed: Double?, held: Double?) {
        let entry = Entry(t: t, east: east, north: north, yaw: yaw, speed: speed, held: held)
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
        entries(around: t)?.atOrBefore
    }

    /// The latest entry at or before `t` (the oldest if all are later) and
    /// the one after it, nil when it is the newest.
    func entries(around t: Int64) -> (atOrBefore: Entry, next: Entry?)? {
        guard !entries.isEmpty else { return nil }
        var lo = 0, hi = entries.count - 1
        if chronological(0).t > t { return (chronological(0), nil) }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if chronological(mid).t <= t { lo = mid } else { hi = mid - 1 }
        }
        return (chronological(lo), lo + 1 < entries.count ? chronological(lo + 1) : nil)
    }
}

/// Each particle's cumulative own motion (`NavigationEngine.motionEast`,
/// `motionNorth`) at the most recent `capacity` grid steps, for late manual
/// fixes (R14.3-1). Structure of arrays: slot `k` holds particle `i` at
/// `k × particles + i`. Kept consistent with the cloud: `remap` follows a
/// resample's index map, `transform` a re-anchor's linear map, and
/// `reconstructHistory` gives a reseeded particle the past it would have
/// had with its new heading and scale.
/// Memory: 3 × capacity × particles Doubles once a resample has run (two
/// rings and `remap`'s scratch; 51 × 2000 × 24 B ≈ 2.4 MB at the
/// defaults).
struct ParticleMotionRing: Sendable {
    let capacity: Int
    private(set) var particles = 0
    private var times: [Int64] = []
    /// Per slot: the engine's cumulative yaw, and the OBD distance (before
    /// scale) of the step that ended there.
    private var yaws: [Double] = []
    private var obdDistances: [Double] = []
    private var eastSlots: [Double] = []
    private var northSlots: [Double] = []
    /// Scratch for `remap`, the size of one of the two arrays above.
    private var spare: [Double] = []
    /// Slots filled, and the physical slot the next append writes.
    private(set) var count = 0
    private var head = 0

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    /// Empties the ring and sizes it for `n` particles.
    mutating func removeAll(particles n: Int) {
        count = 0
        head = 0
        guard capacity > 0 else { return }
        if particles != n || eastSlots.count != capacity * n {
            particles = n
            times = [Int64](repeating: 0, count: capacity)
            yaws = [Double](repeating: 0, count: capacity)
            obdDistances = yaws
            eastSlots = [Double](repeating: 0, count: capacity * n)
            northSlots = eastSlots
            // Allocated now, not at the first resample: no allocation
            // inside a 10 Hz step.
            spare = eastSlots
        }
    }

    mutating func append(_ t: Int64, east: [Double], north: [Double], yaw: Double, obdDistance: Double) {
        guard capacity > 0, east.count == particles, north.count == particles else { return }
        let slot = head
        let base = slot * particles
        times[slot] = t
        yaws[slot] = yaw
        obdDistances[slot] = obdDistance
        eastSlots.withUnsafeMutableBufferPointer { dst in
            east.withUnsafeBufferPointer { src in
                for i in 0..<particles { dst[base + i] = src[i] }
            }
        }
        northSlots.withUnsafeMutableBufferPointer { dst in
            north.withUnsafeBufferPointer { src in
                for i in 0..<particles { dst[base + i] = src[i] }
            }
        }
        head = (head + 1) % capacity
        count = min(count + 1, capacity)
    }

    /// Physical slot of chronological entry `k` (0 = oldest).
    private func physical(_ k: Int) -> Int {
        (head - count + k + capacity) % capacity
    }

    /// The physical slot of the latest snapshot at or before `t`; nil when
    /// the ring is empty or every snapshot is later (`t` older than the
    /// ring).
    func slot(atOrBefore t: Int64) -> Int? {
        guard count > 0, times[physical(0)] <= t else { return nil }
        var lo = 0, hi = count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[physical(mid)] <= t { lo = mid } else { hi = mid - 1 }
        }
        return physical(lo)
    }

    /// The physical slot of the oldest snapshot; nil when empty.
    var oldestSlot: Int? { count > 0 ? physical(0) : nil }

    /// The time of a physical slot.
    func time(_ slot: Int) -> Int64 { times[slot] }

    /// Every snapshot, oldest first: time and each particle's motion (for
    /// tests: the layout of the physical slots differs between a folded and
    /// a stepped stretch, the chronological content must not).
    func chronological() -> [(t: Int64, east: [Double], north: [Double])] {
        (0..<count).map { k in
            let base = physical(k) * particles
            return (times[physical(k)], Array(eastSlots[base..<base + particles]),
                    Array(northSlots[base..<base + particles]))
        }
    }

    @inline(__always) func east(_ slot: Int, _ i: Int) -> Double { eastSlots[slot * particles + i] }
    @inline(__always) func north(_ slot: Int, _ i: Int) -> Double { northSlots[slot * particles + i] }

    /// After a resample: particle `i` is old particle `indices[i]`. One
    /// gather per filled slot into a spare buffer, then a swap.
    mutating func remap(_ indices: [Int]) {
        guard count > 0, indices.count == particles else { return }
        let n = particles
        let slots = (0..<count).map { physical($0) * n }
        var scratch = spare
        spare = []
        if scratch.count != eastSlots.count { scratch = [Double](repeating: 0, count: eastSlots.count) }
        func gather(_ source: inout [Double], into dst: inout [Double]) {
            dst.withUnsafeMutableBufferPointer { d in
                source.withUnsafeBufferPointer { s in
                    indices.withUnsafeBufferPointer { map in
                        for base in slots {
                            for i in 0..<n { d[base + i] = s[base + map[i]] }
                        }
                    }
                }
            }
            swap(&source, &dst)
        }
        gather(&eastSlots, into: &scratch)
        gather(&northSlots, into: &scratch)
        spare = scratch
    }

    /// After a re-anchor: the linear part of the old→new plane map applied
    /// to every snapshot (only differences are used).
    mutating func transform(_ map: (Double, Double) -> (Double, Double)) {
        for k in 0..<count {
            let slot = physical(k)
            let base = slot * particles
            for i in 0..<particles {
                (eastSlots[base + i], northSlots[base + i]) = map(eastSlots[base + i], northSlots[base + i])
            }
        }
    }

    /// Per-step unit displacements of the ring, newest step first, for
    /// `reconstructHistory`: step k (from snapshot k − 1 to k) moved
    /// OBD distance × (sin, cos)(heading − back), where `back` is the yaw
    /// from the step's midpoint to now. Stored as distance × (cos, sin) of
    /// `back`, so a particle's displacement is a rotation by its heading:
    /// no trigonometry per particle and slot.
    func reconstructionBasis(cumulativeYaw: Double) -> [(cosBack: Double, sinBack: Double)] {
        guard count > 1 else { return [] }
        var basis: [(cosBack: Double, sinBack: Double)] = []
        basis.reserveCapacity(count - 1)
        for k in stride(from: count - 1, to: 0, by: -1) {
            let slot = physical(k), previous = physical(k - 1)
            let d = obdDistances[slot]
            let back = cumulativeYaw - 0.5 * (yaws[slot] + yaws[previous])
            basis.append(d != 0 ? (d * cos(back), d * sin(back)) : (0, 0))
        }
        return basis
    }

    /// A reseeded particle has no motion of its own: reconstruct it as if
    /// it had always had `heading` and `scale`, walking back from the
    /// newest snapshot over each step's OBD distance × scale along the
    /// heading it had then (now minus the yaw since, at the step's
    /// midpoint; `basis` from `reconstructionBasis`). Unknown-speed steps
    /// use the held OBD speed, as `step` does for a particle with no speed
    /// error. The particle's current `motionEast/North` is kept; only its
    /// snapshots change.
    mutating func reconstructHistory(particle i: Int, heading: Double, scale: Double,
                                     motionEast e: Double, motionNorth n: Double,
                                     basis: [(cosBack: Double, sinBack: Double)]) {
        guard i < particles, count > 0 else { return }
        // sin(h − b) = sin h cos b − cos h sin b; cos(h − b) = cos h cos b + sin h sin b.
        let sh = sin(heading) * scale, ch = cos(heading) * scale
        var de = 0.0, dn = 0.0
        for k in stride(from: count - 1, through: 0, by: -1) {
            let slot = physical(k)
            eastSlots[slot * particles + i] = e - de
            northSlots[slot * particles + i] = n - dn
            guard k > 0 else { break }
            let u = basis[count - 1 - k]
            de += sh * u.cosBack - ch * u.sinBack
            dn += ch * u.cosBack + sh * u.sinBack
        }
    }
}

/// The grid steps run before initialisation, newest `capacity`: what a late
/// initialising pin is predicted forward over (R14.3-1). A few hundred
/// bytes.
struct PreInitSteps: Sendable {
    enum Kind: Sendable {
        /// Fresh OBD speed: moves at `speed` × scale.
        case known
        /// Stale OBD speed, not parked: unknown speed (held `speed`).
        case stale
        /// Fresh OBD 0 or parked: nothing moves.
        case frozen
    }

    struct Record: Sendable {
        var fromNs: Int64
        var toNs: Int64
        /// Yaw over the step, radians.
        var yaw: Double
        /// OBD speed with the truncation offset, m/s (0 when frozen).
        var speed: Double
        var kind: Kind
        /// The motion-history speeds `step` would have recorded: fresh OBD
        /// speed (nil when stale) and the held one (nil before any reply).
        var historySpeed: Double?
        var held: Double?
    }

    let capacity: Int
    private var records: [Record] = []
    private var head = 0

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        records.reserveCapacity(self.capacity)
    }

    mutating func append(_ record: Record) {
        guard capacity > 0 else { return }
        if records.count < capacity {
            records.append(record)
        } else {
            records[head] = record
            head = (head + 1) % capacity
        }
    }

    /// Records ending after `t`, oldest first.
    func records(endingAfter t: Int64) -> [Record] {
        let ordered = records.count < capacity ? records : Array(records[head...] + records[..<head])
        return ordered.filter { $0.toNs > t }
    }
}
