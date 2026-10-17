# Navigation engine (N2, engine updates N2.1–N2.3, N4-B0/B1, N3.0)

Live dead reckoning without roads: a causal, deterministic estimator of
position, heading and OBD speed scale, in `Core/Sources/DriveLoggerCore/Navigation/`
(Foundation only), plus the Mac replay tool `replay_nav` that proves it on
recorded drives. N4 runs the same engine live in the app (`NavigationService`,
see "Live in the app"); nothing here touches the logger or the log format.

Recordings, truth and replay output are private: they live outside the
repository or in the git-ignored `logs/`. This document refers to drives only by
alias.

## Model

### State

A particle filter with N = 2000 particles. Each particle samples

- heading of travel (radians, clockwise from north),
- OBD speed scale factor. The prior 1.016 ± 0.01 is a per-vehicle value,
  measured on this car's clean drives as the GNSS/OBD speed ratio above
  30 km/h: 1.017 on clean-long, 1.015 on the dead-reckoned part of clean.
  Another car needs its own measurement, or the std back at about 0.03.
- a speed error, zero while OBD speed is fresh and while the car is parked
  after a stop; otherwise, while OBD speed is stale, a mean-reverting
  Ornstein–Uhlenbeck process (see Predict),

and carries its position as a Gaussian, a mean and a 2×2 covariance updated by a
Kalman step (Rao-Blackwellised). Weights are kept as normalised log-weights.

Why positions are Gaussian rather than sampled: with sampled positions, a
position-only update (fixes while parked, a manual pin) reweights particles by
their random position offsets, and resampling then throws away heading
hypotheses that nothing measured. On the replay set this collapsed the heading
std to 1° with no heading information at all (clean drive), and to 0.2° right
after the manual pin, about 1.6 km off. With a Gaussian per particle those
updates reweight only by what heading and scale actually predict.

### Predict (10 Hz grid on the session clock)

- **Yaw** = `rotationRate · ĝ` (ĝ = normalised gravity), integrated over the real
  motion-sample intervals, split at grid instants. Positive = clockwise from
  above, like a compass bearing. CoreMotion's rate is already bias-corrected; no
  bias is estimated.
- **Speed** = OBD 0x0D from ECU `7E8` (or no ECU, v1), held between replies,
  `v + 0.5` km/h when `v > 0`, times the particle's scale.
- **ZUPT only on a fresh zero**: OBD 0 at most 2 s old freezes heading and
  position; no noise, bit-identical estimates.
- **Unless moving fixes contradict the zero** (N4B1-1, `zuptFixGate`, on
  by default): a step an OBD 0 would freeze (a fresh 0, or a parked stale
  one) is vetoed while at least 2 good fixes in a row (valid Doppler speed,
  accuracy ≤ `cleanFixAccM`), each with its own `t` after the run of zeros
  began, read ≥ 5 m/s, and the newest is at most 3 s old at the step. A
  good fix under 5 m/s resets the run; a moving OBD reply ends it. A vetoed
  step moves like a stale one (unknown-speed noise) at the newest such
  fix's Doppler speed, not scaled. Fixes measured before the zeros began
  (the GNSS tail of a real stop) never count, so a real stop is a ZUPT as
  before; on the acceptance set the gate never fires (see "N4B1-1: OBD
  zero against moving fixes").
- **Stale OBD** (> 2 s) means unknown speed, with two cases (R13.1-2):
  - **After an OBD 0 with no sign of motion since, the car is parked.** The
    step is frozen like a zero-velocity update. The latch is armed by every OBD
    0 reply and cleared when the 1 s EMA of horizontal `userAcceleration`
    (gravity removed, device frame) exceeds 0.09 g.
    - Every OBD 0 reply also zeroes the EMA (R13.2-2). A 0 says the car is
      stopped now, so braking deceleration still in the EMA is not motion
      since. Without the reset, OBD falling silent within about 1 s of a
      0.25 g stop cleared the latch on the next sample, and the ellipse grew
      to about 2 km in 5 min.
    - The EMA's timestamp never goes backwards (R13.2-3). An out-of-order
      motion sample would otherwise give the next one a dt of up to 0.5 s and
      a gain of about 0.39 instead of 0.01, and one jolt could clear the latch.
    - On the replay set, parked and idling peaks reach 0.082 g (the phone being
      handled after ignition-off), and most drive-offs exceed 0.09 g within
      0–12 s; a gentle one can take 20–30 s.
    - Yaw is not used as evidence: handling the parked phone gives
      0.4–3.4 rad/s.
    - Every stale period in the replay set is ignition-off after a stop.
  - **Otherwise, unknown speed.** Each particle's speed error follows an
    Ornstein–Uhlenbeck process (2.5 m/s per √s, decaying with τ = 20 s, so its
    spread levels off at about 7.9 m/s), and heading noise is ×3. The
    noise *increments* are antithetic in pairs (R11.1-7, R20.1-1):
    particles 2k and 2k + 1 share one noise draw per step with opposite
    signs (in a macro step, both normals of the exact OU
    transition), so the increments sum to 0 and add no Monte Carlo drift.
    The offsets themselves are each particle's own: a resample keeps the
    ones the fixes favoured, so fixes during a stale stretch still teach
    the cloud its speed. With independent draws the *realised* mean
    drifted, about √(Var I(t) / N): measured on a synthetic 10 min stretch
    at 15 m/s with no fixes (N = 2000, seeds 1–10), 3.8–48.8 m, RMS 28.7 m.
    Antithetic increments: RMS 9.1 m (max 14.1 m); the rest is heading
    spread, since a pair cancels along each particle's own heading. The
    ellipse is unchanged (95 % semi-major 2.8–3.1 km). R11.1-7 first
    re-paired the offsets themselves after every resample (the odd particle
    took the negative of the even one's). That holds the prior's marginal
    but throws away the posterior: with clean fixes every second while
    the car accelerated 15 → 25 m/s on stale OBD, half the learned offsets
    were flipped each time, the mean speed stayed at the stale 15.2 m/s,
    and the error 6 s after the last fix was 60 m instead of 16 m
    (R20.1-1; N = 1000).
    The ellipse then grows like √t: about
    0.6 / 2.2 / 3.0 km after 1 / 5 / 10 min of OBD silence while driving. An
    unbounded random walk reached 1.5 / 19 / 55 km.
- **Catch-up after a long silence** (R13.1-6): when every input stops (the app
  suspended, a gap in a file, a corrupt huge `t`), the next `ingest` must
  catch up the grid. Work per `ingest` is bounded:
  - Steps with fresh OBD always run one by one. There are at most
    `obdMaxAgeS` × 10 Hz of them, since OBD goes stale within the gap.
  - Once OBD is stale and more than `maxCatchUpSteps` (100) grid steps
    remain:
    - **Parked:** the stretch is folded in O(1), plus the last
      `history.capacity` history entries. This is bit-identical to stepping
      it.
    - **Unknown speed:** the stretch runs as at most `maxCatchUpSteps` macro
      steps of equal whole grid steps. Each draws the OU speed error and its
      integral over the step jointly from the exact transition, so the
      distance carries the integrated error, not the end value × dt. Heading
      and scale random walks are exact for any dt.
    - **Before initialisation:** the clock jumps.
  - **Implausible forward jumps** (B0-1): an input arriving more than
    `maxForwardJumpS` (1 h) after the latest input the engine accepted is
    rejected and counted (`inputsRejectedTimeJump`). Without that, one corrupt
    huge `t` moved the engine clock there and every later input was in the
    past, so the engine never stepped again. A real resume after a longer
    silence is taken from its second input: two inputs beyond the limit
    within 10 s of each other (`forwardJumpConfirmS`). The first input of a
    recording is always accepted. `accepts(_:)` tells a caller in advance.
    Config validation (`NavigationConfig.validated()`, applied by the engine)
    clamps `extrapolationHorizonS` to 0–3600 s, so an absurd `--set` cannot
    overflow the nanosecond arithmetic in `estimate(at:)`. The counter is 0
    on every acceptance drive.
  - Ordinary input never takes this path: motion samples step the grid every
    few milliseconds. The counters `coalescedSteps` and `macroSteps` are 0 on
    every acceptance drive.
  - Measured on a synthetic 600 s silence at unknown speed (2000 particles,
    seeds 1–4): 95 % semi-major 2868–2952 m caught up against 2883–2959 m
    stepped one by one.
- **Process noise**: heading random walk 0.05°/√s plus 0.1°/√(degree turned)
  (about 1° per 90° turn; measured gyro turns match GNSS course within
  1–1.5 %). Position covariance grows by 0.6 m/√m along and across track. Scale
  random walk 1e-4/√s.

### Updates

- **Location fix**: per-axis σ = `horizontalAccuracy` / 1.51, floored at 5 m.
  CoreLocation reports a 68 % radius, which for a circular Gaussian is 1.51 σ,
  so this takes the fix at face value. Kalman update of each particle's
  position; log-weight += log N(z; μ, P + R).
  - **Network fix** = any fix without a valid speed (speed or speedAccuracy
    negative), whatever accuracy iOS claims: a cell-tower or Wi-Fi position, not
    GNSS. Its likelihood is tempered by `min(1, Δt since the last network
    fix / 60 s)`, because the errors are correlated over minutes (equivalent to
    R / w). On the manual drive tower residuals had a per-axis RMS of about
    160 m against a reported 1414 m, in same-sign runs lasting 1–2 minutes.
    Until N2.1 only fixes above 200 m counted. Since then 24–190 m Wi-Fi fixes
    count too: untempered, they collapsed manual-3's heading in its first
    300 m. An overconfident ellipse is worse for N4 than 10–30 m of accuracy,
    because the camera frames the ellipse and the driver trusts it.
  - **Latency**: a v2/v3 fix's `t` is the fix time, before its arrival. The fix
    is shifted by the engine's own mean displacement and yaw since `t`, taken
    from a ring of cumulative mean motion (max(`maxFixAgeS`,
    `lateManualFixWindowS`), 10 s). Between two 10 Hz entries the cumulative
    motion is interpolated linearly (R11.2-2), so a fix 0.07 s after a grid
    step is not pushed forward by the 0.07 s × v that happened before it
    (about 1.5 m on average at 30 m/s, always forward). This is causal and
    needs no per-particle history. It is right for a converged cloud. It is not right while heading
    is unknown (see late manual fix below).
  - **Stale fixes** (age > 10 s at arrival) are ignored unless OBD says the car
    is stopped. Stopped is not enough when the car moved after the fix
    (R11.1-5): the motion history holds about 10 s, so a fix from before
    the stop could reach past it and the motion it misses would stay
    unshifted (a 16 s old fix at a light: tens of metres at σ 5 m). A stale
    fix is therefore used only if its time is at or after the end of the
    last moving step since initialisation; every step since was then a ZUPT
    or parked step, and its shift is exactly 0. Otherwise it is ignored
    (`staleFixesIgnoredMoved`, also in `fixesIgnoredStale`). A stale fix
    that initialises the engine has no motion to miss and is used as
    before.
  - **Held stale fix** (N4-B1, backlog N4B-1): a stale fix that arrives
    before OBD can say whether the car is stopped (no reply yet, or only a
    stale one) is held, not dropped. The first OBD reply that is fresh at the
    fix's arrival (its `t` at most `obdMaxAgeS` before it) decides:
    - 0: the fix is applied as if it had arrived at max(its arrival, the
      reply's `t`). Live, the reply's `t` is before the arrival (the row is
      written late), so the fix keeps its own arrival, and its age, stale σ
      and latency shift are bit-identical to an arrival-order replay. A
      later reply makes the wait part of the fix's age.
    - moving: the fix is dropped, as it would have been on arrival.
    - no such reply within `heldFixTimeoutS` (5 s) of the arrival: dropped.

    One fix is held, the newest by fix time. A newer stale fix carries the
    same kind of information with less age, so a smaller σ; the
    pre-session case delivers exactly one; one slot keeps the decision O(1).
    Counters: `fixesHeld`, `heldFixesUsed`, `heldFixesDroppedMoving`,
    `heldFixesDroppedTimeout`, `heldFixesReplaced`; every drop also counts
    in `fixesIgnoredStale`. `heldFixTimeoutS` 0 restores the drop on
    arrival.
  - **Course** is used when valid, GNSS speed ≥ 3 m/s, the OBD speed last
    reported at the fix time ≥ 3 m/s (GNSS reports a few m/s of noise while
    parked), and GNSS speed agrees with fresh OBD within max(2 m/s, 15 %).
    The OBD speed is the held one, fresh or stale (R11.1-4): a stale 0 (the
    link dropped while parked) and no OBD reply at all (parked before the
    adapter connects, or a pre-session fix that arrives before the first
    reply) veto the course; a stale moving speed (a dropout while driving)
    does not. That last gate rejects glitch fixes (the clean
    drive has one reporting 25 m/s at 10 m/s with a "good" course) and slow
    manoeuvres. Wrapped Gaussian with σ = max(courseAccuracy, 2°).
  - The course of a fix **without a valid speed** (a network fix that
    reports a course) is not used. Using it was measured and rejected: see
    "N3 candidate: speedless course" below.
  - **Speed** updates the scale under the same gates, when OBD speed is above
    10.8 km/h and speedAccuracy is valid, with σ = max(speedAccuracy, 1 m/s).
    GNSS and OBD speeds differ by about 1 m/s RMS on the clean drive.
  - **Clean fix** (≤ 15 m with a usable course) **reseeds** half the particles
    around the fix and its course when the heading std is above 30° *or* no
    particle lies within 4 σ of the course. The second case recovers a heading
    that converged wrongly. On the clean drive, reversing out of a parking space
    with unsigned OBD speed drove heading to "nose + 180°".
- **Manual fix** ("I'm here"): σ = max(30 m, mapSpanM / 12), 30 m when the
  span is missing or not usable. A fingertip covers roughly 1/12 of the map, so
  a pin on a 1.2 km-wide map is good to about 100 m. Since N3.0 (N4MF-1) σ
  also grows with the speed at the tap: σ² = max(30, span / 12)² +
  (v · (τ + max(0, t − pressedT)))², τ = `manualFixReactionS` (1 s), because
  the finger marks a spot the car passed about a reaction time ago.
  v = `gateSpeedKmh` / 3.6 when `speedSource` is `obd` or `gps`, else
  `manualFixUnknownSpeedMps` (10 m/s). t − pressedT is the confirm delay of
  the old long-press flow (0 for a double tap). On the replay set: manual
  unchanged (0 km/h), manual-3 104 → 105.4 / 30.3 → 30.4 / 30.7 → 31.0 m,
  drive-7 30 → 30.0–32.7 m (pins at 0–47 km/h). That is too small to judge
  the rule here; it needs pins at 30–60 km/h (device item D3). Caveat (M10.1-3):
  in heading-up the logged span can be up to about 2.2× too large, which errs
  toward a larger σ, so it is safe. The replay scores the pin checkpoint with
  the frozen truth σ max(30 m, span / 12) (`manualFixTruthSigmaM`, R19.1-1),
  not with this engine σ. Kalman position update. If the prior has no support at the pin (every
  particle further than χ² = 25), positions restart at the pin while heading
  and scale hypotheses and their weights are kept. A low ESS alone does not
  reset (R13.1-1): that is the pin carrying the most information. For example,
  a ring-shaped cloud after km of unknown heading is cut down to the headings
  that lead to the pin, and resampling keeps that posterior.
  - **Late manual fix** (R14.3-1). The double-tap flow writes the row when its
    3 s undo window closes, with `t` = the tap, so the live engine (and
    `--as-live`) ingests it about 3 s late. A pin is *late* when grid steps have
    already run past floor(`t`). In arrival order this never happens: the
    engine steps to floor(`t`) and then ingests. On a late pin each particle is
    updated as of `t`: its target is the pin plus *that particle's own*
    prediction displacement since `t`.
    - Why not the mean shift: while heading is unknown the cloud is a ring, so
      its mean displacement is about 0 although every particle moved
      v × 3 s along its own heading. With the mean shift the live dot stayed
      14 / 29 / 52 m from the arrival-order result at 8 / 15 / 25 m/s
      (synthetic, 2000 particles). With the per-particle shift it stays
      0.0 / 0.1 / 0.1 m away.
    - Ring: each particle's cumulative prediction-only displacement
      (`motionEast/North`, no update corrections) is snapshotted at every grid
      step for `lateManualFixWindowS` (5 s: the 3 s window plus write and
      scheduling delay). It follows the cloud:
      - resampling remaps it by the same index map;
      - re-anchoring maps it by the Jacobian, as the mean history;
      - the parked catch-up fold records the last snapshots, bit-identical to
        stepping;
      - a reseeded particle gets the past it would have had with its new
        heading and scale, from each step's yaw and OBD distance (not the
        cloud's mean motion, which is about 0 exactly when reseeds happen).
    - Covariance: the update uses each particle's covariance now, not at `t`.
      The along/cross-track noise grown since `t` is at most
      0.36 m²/m × v × 3 s ≈ 27 m² at 25 m/s, against R ≥ 900 m² (σ ≥ 30 m).
      Leaving it in widens the likelihood by under 1.5 % in σ, which is
      conservative. The posterior is then at most that Q too tight (σ about
      0.4 m at 30 m). Removing it would need the per-particle Q since `t` too.
    - Older than the ring: own motion over the ring plus the cloud's mean
      motion from `t` to the ring's oldest snapshot (counter
      `lateManualFixesMeanShift`).
    - **Late initialising pin** (no cloud yet, so no per-particle history): the
      cloud starts at the tap and is predicted forward over the grid steps run
      since, from a small record of pre-initialisation steps (yaw, OBD speed,
      and fresh / stale / frozen as `step` would decide). Each particle moves
      with its own heading and scale, and its covariance grows by the
      along/cross-track noise of that distance. Stale steps add the OU integral
      variance along the heading. No random numbers are drawn; the heading and
      scale random walks over those seconds (about 0.1°) are left out. Time the
      record does not cover adds an isotropic (v × gap)². The result has the
      same ellipse as a pin that arrived at the tap (within 5 %). At 25 m/s the
      truth is 87.5 m away, inside a 171.9 m semi-major. Without it the cloud
      sat at the tap with a 76.9 m semi-major, and the truth was outside. This
      was chosen over inflating σ by `vObd` × age, because with heading unknown
      the motion is a ring of radius v × age, not a disc, and the forward
      prediction reproduces exactly that.
      The motion record is backfilled over the same steps (R14.4-1): the
      per-particle ring, `motionEast/North`, the mean history and the
      cumulative motion start at the tap's grid step and advance step by
      step. Before, they started at the initialisation, so a second late pin
      tapped between the first tap and the late initialisation (two pins
      1.5 s apart, no GPS) lost that motion: 7.5 / 20.6 m off arrival order
      at 15 / 25 m/s, its ellipse 10–21 % smaller. Now within 1.5 m and 5 %.
    - `lateManualFixWindowS` 0 disables all of this (every pin gets the mean
      shift, as before). Counters: `lateManualFixes`,
      `lateManualFixesMeanShift`. Memory: two rings of
      (window × stepHz + 1) × N Doubles plus one scratch buffer for the
      resample remap (51 × 2000 × 24 B ≈ 2.4 MB at the defaults). Cost on the
      replay set (Mac, release, 2000 particles): +0.007 ms/step, from
      snapshotting 2 × N Doubles per step. Max ingest went from 0.13–0.36 ms to
      0.25–0.66 ms (the resample remap; a reseed's reconstruction).
- **Pin against a GNSS source** (N3-FIXPIN, both keys default off, not
  adopted; nothing below runs while `roadFixPinCheck` and
  `fixPinTwoPinCheck` are 0). A fix with a small claimed accuracy outweighs
  a pin: drive-10's accessory fixes, a constant-offset copy of the track
  ("Constant-offset GNSS check" below), pulled the cloud back after every
  pin reset. This decides, at a pin, whether the pin or a GNSS source is
  wrong, and down-weights the source when it is the source.
  - **Sources.** Fixes with a valid speed, split by `accessory` (true:
    accessory; false or nil: phone). Network fixes are never judged and are
    untouched. Each source keeps its fixes of the last `fixPinWindowS`
    (90 s): fix time, position as given (not latency-shifted) in the engine
    plane, course when the engine would use it, claimed σ.
  - **At a pin** that is not a refinement (engine-side, causal: the
    previous pin's `t` within 3 s, mirroring the replay's scoring pair
    rule), for each source with a fix in the window: d = pin − prior mean
    (before the pin is ingested), significant when χ² of d against the
    prior covariance + pin σ² is above 9. A not-significant d judges
    nothing.
  - **Road arbiter** (`roadFixPinCheck`, inert without roads): over the
    source's ring fixes inside pack coverage (at least 20 fixes and 200 m
    of fix path), the mean of min(distance to a heading-compatible road,
    100 m) as given (A) and shifted by d (B), through the matcher's cell
    cache (`RoadMatcher.nearestCompatibleDistance`; each fix's A and B are
    cached, exact for a fixed shift and plane, so a recheck queries only
    the fixes added since). Verdict pin when
    A > `roadFixPinOffRoadM` (15), B ≤ 15 and A − B ≥ `roadFixPinMarginM`
    (10); fixes in the mirror case; otherwise none.
  - **Two-pin arbiter** (`fixPinTwoPinCheck`, with or without roads): per
    source the last independent pin's d, covariance, OBD distance and gyro
    yaw. A new significant pin: verdict pin when the χ² of d₁ − d₂ against
    the summed covariances is ≤ 5.99, the OBD path between them is at least
    `fixPinTwoPinMinPathM` (300 m) and |net heading change| at least
    `fixPinTwoPinMinTurnDeg` (45°). One pin alone gives no verdict.
  - **Down-weighted** (verdict pin from either): the source's position
    update uses σ = max(σ_claimed, |d|) × `fixPinInflation` (1.0), tempered
    like a network fix by its own time since its last fix (min(1, Δt /
    60 s)). Course and speed stay at full weight. It never reseeds the
    cloud (counted, `fixPinReseedsBlocked`). The road fix gate is unchanged
    (it can only reject); once the cloud is back on the roads it may reject
    a down-weighted source's off-road fixes whole, course and speed
    included (counted, `fixPinRejectedOffRoadDownweighted…`). The pin's own
    update (or reset) is kept: the following fixes are weak.
  - **Verdict fixes:** counters only (a hook for N3MF-1).
  - **Win-back** (offset cleared, never a permanent discard): (1) roads,
    every 10 s while down-weighted, A vs B on the ring says "fixes"; (2)
    agreement: Mahalanobis² < 9 against the source's *claimed* σ (σ²·I +
    the estimate's covariance, not the inflated σ) for at least
    `fixPinRestoreS` (30 s) and 15 consecutive fixes, a disagreeing fix
    restarts the run; (3) a new independent pin within χ² 9 of the source's
    newest fix (claimed σ² + pin σ²).
  - **Output:** `NavigationEngine.lastFixPinDecision` per pin; replay
    summary and `metrics.md` lines and the `metrics.json` key
    `fixPinDecisions` only while a key is on (or a counter is not 0), so
    key-off outputs are byte-identical. No sidecar or log-format change.
    Relative metres and bearings only.
  - **5-seed acceptance** (seeds 1–5, all acceptance drives, roads on and
    off). Key off = main, byte-identical on every run; 0 false triggers
    outside drive-10. drive-10, road key: gated error 21.35 % → 1.41 %,
    pin-2 prior 327 → 22 m (inside its ellipse, 5 of 5 seeds). Margin: pin 1
    road B = 14.86 m against the 15 m limit, 0.14 m (A = 33.09 m). Two-pin
    key on drive-10: FAIL criterion, pin 2 stays out of its ellipse (327 m).
    By construction: the two-pin verdict only decides AT pin 2, so pin 2's
    own prior is never helped; it helps pins 3+ (priors 167 / 76 / 68 / 86 /
    170 m against 191 / 135 / 193 / 39 / 212 keys off, no roads; the 436 s
    pin got worse, see below). With the road key the road fix gate rejects
    39 of the down-weighted source's fixes per seed (195 over 5 seeds),
    course and speed included (BACKLOG N3-FIXPIN-GATE).
  - **Injection study** (2026-10-17; replay only, `replay_nav
    --fixpin-inject`, no engine or log change). Per case an engine snapshot,
    the decisions come from the engine itself (a post-hoc recomputation of
    the road verdict agrees in 4032 of 4032 cases). Sensitivity: every
    accessory/phone fix in a window is shifted by d ∈ {100, 200, 335, 500} m
    × 8 bearings, a genuine pin 90 s in. Specificity: genuine fixes, the
    pin displaced by {30, 75, 150, 300} m × 8 bearings (a mis-tapped pin).
    Applicable drives: clean-long, clean, drive-8 only, 21 pin times (8 / 5 /
    8) over straight, junction and parallel roads. manual, manual-3, drive-9
    and drive-10 after its spoofed span have no fix with a valid speed
    (or none that is accurate), which the arbiter never judges. Seeds 1–3
    are nearly identical (the verdict category differs in 2 of 2688 cases),
    so the numbers are per seed.
  - **Road key results** (roads on, one pin, offRoad 15 / margin 10).
    Sensitivity, pin verdicts, all drives:

    | d (m) | 100 | 200 | 335 | 500 | ≥ 200 |
    |---|---|---|---|---|---|
    | pin | 50 % | 80 % | 89 % | 86 % | 85 % (428/504) |

    Per drive at d ≥ 200: clean-long 92 %, drive-8 93 %, clean 60 %.
    Specificity: 2 false pins of 672 per seed, both at clean 415 s, where
    the genuine ring itself is 52 m from mapped roads (likely unmapped, not
    proven) and a displacement of 150 m @ 0° or 300 m @ 135° lands it near a
    road. The other displaced pins give "fixes" or "none" (at 150 and 300 m
    "fixes" in 79 % and 88 % of cases). Grid, d ≥ 200 sensitivity / false pins of
    672 per seed: offRoad 12 / margin 5 89 % / 1; 12 / 10 87 % / 1; 15 / 5
    and 15 / 10 85 % / 2; 20 / 5 and 20 / 10 78 % / 5. No cell reaches 90 %
    with 0 false pins. Misses at d ≥ 200 (76 of 504): 43 shifted ring still
    within 15 m of a mapped road (dense grid), 22 ring unmapped even
    unshifted, 10 not significant, 1 margin. A / B against the limits: the
    genuine ring's A is ≤ 10 m at every mapped pin time (a gap on that side
    of 15 m), but the shifted ring's A is a continuum (12–15 m: 27 cases,
    15–20 m: 57, 20–30 m: 122 of 613), so the 15 m line sits in a crowd
    (a shift of 100–500 m often lands the ring within 15 m of some other
    road). B of the shifted-back ring is ≤ 10 m in 581 of 613. When it
    fires it works: end-of-window error median 4–6 m (clean-long, drive-8)
    and 49–50 m (clean) against 200–500 m keys off.
  - **Verdict, `roadFixPinCheck`: measured, not adopted.** Sensitivity 85 %
    < 90 % at d ≥ 200, 2 false pins, and it fails at offRoad 12 and 20 too.
    Default stays 0.
  - **Two-pin results** (`fixPinTwoPinCheck`, roads off; with roads the
    road key decides first). The one-pin cases cannot trigger it (it decides
    at a second pin ≥ 300 m and ≥ 45° after the first), so it has its own
    cases: pin 1 genuine, pin 2 genuine after the first turn meeting the
    minimums, a genuine pin 3 60 s later. 5 of 21 pin times never meet the
    minimums (clean-long 2 of 8, clean 3 of 5, drive-8 0 of 8): verdict
    impossible, no case. Sensitivity (pin at pin 2): 100 % at d ≥ 200
    (384 of 384 per seed), 92 % at d = 100 (not significant otherwise). Pin
    3 prior median 8 m against 200–500 m keys off, better by > 5 m in every
    case; at d = 100 no change (pin-2 χ² 8–11 is below the 25 reset, a tight
    cloud takes a partial update). Specificity (pin 1 displaced, pin 2 as
    named): genuine pin 2 0 false of 1536; car-frame variant (extra) 0 of
    1536; same displacement on the map 0 false at 30 and 75 m and 100 %
    false at 150 and 300 m (χ² 0.00 between the two pins): two pins
    displaced alike are indistinguishable from a shifted source. At 300 m
    the estimate is then held ~298 m off (keys off: 1 m). The key stays
    off. Removal is not proposed: it adds something over no key (the
    sensitivity above). Keep-or-drop is the user's call.
  - **drive-10 436 s** (two-pin, no roads: the 436 s pin's prior is 39 m keys
    off, 87 m key on). Both runs dead-reckon the same motion from 392 to 436 s (paths
    234 / 236 m, separation constant at 47 m), and no GNSS-source fix exists
    after 251 s, so the source is inert there. The 47 m is set by the 391 s
    pin: keys off, the prior (191 m) lies beyond χ² 25 and resets the cloud
    onto the pin; key on, the prior (68 m) is closer but overconfident, not
    significant, and only updates (53 m of the error survives). The keys-off
    reset has a χ² between 25 and 40: with `manualFixResetChi2` 40 or 60 it
    disappears and the 435.5 s prior is 194 m (87 m key on). So the
    regression is the luck of that reset, not an effect of the key; the
    mechanism is the pin update / reset rule.
  - **Timing.** The road verdict step on the Mac (drive-10 pin 1, release)
    was 4.84 ms (key off 0.09 ms), 78 % of it in the coverage
    point-in-polygon of the ring fixes against the national pack's single
    ~80 k-vertex ring. `RoadNetwork.covers` now tests the cheapest pack first
    (an OR over packs, so byte-identical: proof in commit 3e43317): 1.14 ms.
    On the phone, with no new event kind: a one-off local Release build with
    `roadFixPinCheck` 1 (never committed), a drive with at least one pin
    while roads are attached. The sidecar's `configHash` identifies the
    build; `msPerStep` / `maxStepMs` on the `estimate` lines after the pin give the
    verdict step cost (`maxStepMs` is the largest step so far, so it jumps at the
    pin when the verdict step is the largest). Not the pin's `prior.maxStepMs`: the
    prior is written before the engine ingests the pin.
- **Local plane re-anchoring** (R13.1-3): the plane's east axis uses each
  point's own cos φ, so far from the anchor it is sheared, and true north tilts
  by about Δλ·sin φ (1.28° at 100 km east, latitude 55°). That would bias
  heading against GNSS course and distort turns.
  - Once the cloud's mean is more than 10 km from the anchor (checked every
    10 s of moving steps), the plane moves to the mean.
  - Positions convert exactly via WGS-84. Headings, covariances and the motion
    history convert via the Jacobian of the old→new map at the mean.
  - Within 10 km the tilt stays under about 0.13°.
- **Resampling**: systematic, when ESS < N/2; afterwards 0.2° heading and
  0.0005 scale jitter.

### Initialisation

From the first position information the engine accepts. A clean fix with a
usable course gives position ± σ and heading ~ N(course, σ_course). Otherwise
(any fix or a manual fix) it gives position ± σ and headings stratified
uniformly over 360°. Stratification cut the seed-to-seed spread on the jammed
drives noticeably compared with independent draws.

An initialising fix starts the cloud at the fix, but the car has moved for
the fix's age (arrival − `t`) since, and no motion history exists yet to
shift it (R11.2-3). Its σ grows in quadrature: σ² = σ_fix² + (v · age)², with
v the fresh OBD speed at arrival (truncation offset added; 0 when stopped),
else the fix's own Doppler speed when valid, else 0. A 4 s old fix at
20 m/s starts at σ ≈ 82 m instead of 5 m, so the truth 80 m ahead is inside
the ellipse. A prompt fix (0.05 s) is within 1 % of its own σ. A fix older
than `staleFixAgeS` also has the stale growth (1 m/s × age) in σ_fix.

### Estimate

`estimate(at:)` returns nil before initialisation. Otherwise it returns the
weighted mean position, circular mean and std of heading, a 95 % ellipse
(√(5.991 λ) of the mixture covariance), speed, scale mean and std, ESS and
`converged` (heading std < 10°; while false N4 shows "calibrating heading"). It
does not mutate the engine. For a time after the last step (R13.1-5):
- **Stationary last step** (fresh 0 or parked): the estimate is held
  unchanged, as the engine itself would hold it until new evidence.
- **Otherwise, up to `extrapolationHorizonS` (2 s, the age to which a held
  OBD speed counts as known):** the mean is extrapolated with the last speed
  and yaw rate, and the ellipse is the last step's.
- **Beyond the horizon:** position and heading are held where the horizon
  left them, and the covariance grows by the motion not extrapolated over the
  excess s:
  - (v·s)² along the heading, because the car may have stopped at once or
    kept its last speed v;
  - plus, in every direction, the variance of the engine's own unknown-speed
    OU error integrated over s.

  This hold has no time limit: the position stays at the horizon however
  long no input arrives, and only the ellipse keeps growing (it never
  shrinks with `t`). A non-stationary engine that hears nothing for minutes
  therefore shows a fixed dot with a widening ellipse, not a moving one.

  The ellipse grows with t and never shrinks. Before this rule, 60 s past
  the last step at 20 m/s the estimate moved 1.2 km, and mid-turn its heading
  spun 180°, with the ellipse unchanged.

`east`/`north` are relative to the local plane, which re-anchors beyond
`reanchorDistanceM`, so they jump by about 10 km at a re-anchor. Consumers
(the N4 map and sidecar) use latitude/longitude.

### Causality and determinism

The engine consumes inputs in arrival order and never looks ahead. The
causality tests check two things: an engine fed only the prefix up to T gives
the same `estimate(at: T)`, bit for bit, as the full run sampled at T; and
replacing every input after T with garbage leaves every estimate at or before T
unchanged. All randomness comes from one xoshiro256** generator seeded by
`config.seed`, so the same log, seed and config give bit-identical output on
the same platform.

### Deviations from the N2 plan, and why (measured)

| Plan | Implemented | Reason |
|---|---|---|
| Sampled positions | Gaussian position per particle | Sampled positions made the heading collapse falsely (see above) |
| σ = max(acc, floor), tower σ × inflation | σ = acc / 1.51 (68 % radius), network-fix inflation 1.0 | Inflation 1.5 on top of σ = acc put jammed-B at 4.5 %. Face value is still 2–4× the observed tower scatter; correlation is handled by tempering |
| Clean-fix reseed when heading std > 30° | also when the course has no support | Recovers a heading that converged wrongly (reversing out of parking) |
| — | GNSS speed must agree with OBD for course and speed to be used | Glitch fixes and slow manoeuvres poisoned the heading |
| — | heading noise grows with the angle turned; scale jitter after resampling | Without them the filter was overconfident (95 % ellipse missed the truth on every withheld fix) and the scale stuck at 0.97 against a measured 1.003 |
| — | `replay_nav --set key=value` | Tune any config field without a rebuild |

Tried and rejected (worse on the replay set): moved to [docs/archive/NAVIGATION-history.md](archive/NAVIGATION-history.md).

## Configuration (defaults)

Every value is in `NavigationConfig`; `replay_nav` prints the full config with
every result. The table lists the keys without roads; the 21 road keys
(`road…`, used only with `--roads`) and their defaults are in
[docs/N3_PLAN.md](N3_PLAN.md), "Config keys" (R21.4-4). `roadCorrelationM`
default 100 (was 30 until 2026-10-14; N3.2 decision, below).

| key | default | meaning |
|---|---:|---|
| particleCount | 2000 | particles |
| seed | 1 | RNG seed |
| stepHz | 10 | predict rate |
| headingNoiseDegPerSqrtS | 0.05 | heading random walk while moving |
| turnHeadingNoiseDegPerSqrtDeg | 0.1 | heading noise per √(degree turned) |
| alongTrackNoisePerSqrtM / crossTrackNoisePerSqrtM | 0.6 | position covariance growth, m/√m |
| scaleNoisePerSqrtS | 0.0001 | scale random walk |
| scalePriorMean / scalePriorStd | 1.016 / 0.01 | per-vehicle OBD speed scale prior (measured on this car) |
| obdSpeedOffsetKmh | 0.5 | truncation offset when v > 0 |
| obdMaxAgeS | 2 | fresher = known speed; a fresh 0 is a ZUPT |
| zuptFixGate | 1 | N4B1-1: moving good fixes veto an OBD 0's ZUPT or parked step; 0 off, 1 on, other values refused |
| zuptFixGateMinSpeedMps / zuptFixGateMinFixes / zuptFixGateMaxAgeS | 5 / 2 / 3 | "moving" Doppler speed, m/s; moving good fixes in a row after the zeros began; how old the newest may be at the step, s (> 0, ≥ 1, ≥ 0, else refused) |
| staleSpeedNoiseMpsPerSqrtS | 2.5 | speed error noise while stale |
| staleSpeedDecayS | 20 | stale speed error decays (Ornstein–Uhlenbeck) with this time constant |
| staleParkedMotionG / staleParkedMotionTauS | 0.09 / 1 | after an OBD 0, stale = parked until the 1 s EMA of horizontal userAcceleration exceeds this |
| reanchorDistanceM | 10 000 | re-anchor the local plane at the cloud's mean beyond this |
| maxCatchUpSteps | 100 | most stale grid steps one `ingest` runs one by one; a longer stale stretch is folded (parked) or split into at most this many exact-OU macro steps (unknown speed) |
| extrapolationHorizonS | 2 | `estimate(at:)` extrapolates at most this far past the last step; beyond it, it holds the position and grows the ellipse. Clamped to 0–3600 by validation |
| maxForwardJumpS | 3600 | an input arriving more than this after the latest accepted one is rejected as a corrupt time (B0-1), unless a second one confirms a resume |
| staleHeadingNoiseFactor | 3 | heading noise multiplier while stale |
| maxMotionGapS | 0.5 | longer motion gaps contribute no yaw |
| fixSigmaPerAccuracy | 1/1.51 | per-axis σ per metre of accuracy |
| fixSigmaFloorM | 5 | σ floor |
| networkFixInflation | 1.0 | extra σ factor for network fixes (any fix without a valid speed) |
| networkFixCorrelationS | 60 | network-fix tempering window |
| maxFixAgeS | 10 | older fixes ignored unless stopped |
| heldFixTimeoutS | 5 | a stale fix arriving before OBD can say "stopped" is held this long for the first fresh OBD reply (0: used, moving: dropped); 0 disables holding (N4-B1) |
| staleFixSigmaGrowthMps / staleFixAgeS | 1.0 / 5 | a fix older than staleFixAgeS at ingest gets σ += k × age (adopted in N2.3) |
| courseMinSpeedMps | 3 | course needs this GNSS and OBD speed |
| courseSigmaFloorDeg | 2 | course σ floor |
| speedUpdateMinKmh | 10.8 | GNSS speed updates the scale only above this OBD speed (and with valid speedAccuracy) |
| gnssSpeedGateMps / gnssSpeedGateFraction | 2 / 0.15 | GNSS vs OBD speed agreement gate |
| speedSigmaFloorMps | 1.0 | GNSS speed σ floor |
| cleanFixAccM | 15 | clean fix threshold |
| reseedHeadingStdDeg / reseedNoSupportSigma / reseedFraction | 30 / 4 / 0.5 | clean-fix reseed |
| manualFixSigmaMinM / manualFixSpanDivisor | 30 / 12 | manual pin σ = max(min, mapSpanM / divisor); min without a span |
| manualFixReactionS / manualFixUnknownSpeedMps | 1 / 10 | pin σ grows in quadrature by v × (τ + max(0, t − pressedT)) (N4MF-1); v for an `unknown` speed source |
| manualFixResetChi2 | 25 | manual reset when every particle is further than this from the pin (χ², 2 dof) |
| lateManualFixWindowS | 5 | per-particle motion ring for late manual fixes (R14.3-1); also the minimum length of the mean-motion history. 0 disables (mean shift for every pin). Clamped to 0–60 |
| fixPinTwoPinCheck | 0 | N3-FIXPIN two-pin arbiter: 1 on, 0 off; other values refused |
| fixPinWindowS | 90 | per-source fix ring for the pin checks, s; (0, 3600], else refused |
| fixPinTwoPinMinPathM / fixPinTwoPinMinTurnDeg | 300 / 45 | two-pin verdict needs this OBD path and net gyro turn between the pins |
| fixPinInflation | 1.0 | down-weighted σ = max(σ_claimed, \|offset\|) × this; > 0, else refused |
| fixPinRestoreS | 30 | win-back by agreement after this long (and 15 consecutive fixes) |
| resampleESSFraction | 0.5 | resampling threshold |
| resampleHeadingJitterDeg / resampleScaleJitter | 0.2 / 0.0005 | jitter after resampling |
| convergedHeadingStdDeg | 10 | `converged` threshold |

## replay_nav

```bash
cd Core && swift run -c release replay_nav <log.jsonl.gz>... [--gps use|mask-after <s>|mask-after-motion <s>|none] \
  [--hold-out-acc <m>] [--truth ../logs/truth.json] [--seed N|header] [--particles N] \
  [--set <configKey>=<number>] [--out ../logs/out] \
  [--as-live | --file-order] [--compare <log.nav.jsonl> [--tolerance <m>] [--heading-tolerance <deg>]] \
  [--write-sidecar <out.nav.jsonl>] [--pin-pair-window <s>] [--strict] \
  [--roads <pack.roadpack>]... [--wrong-road-tolerance <m>] \
  [--fix-offset <from>:<to>|auto[:<len>:<step>]]... [--fix-source any|accessory|phone] [--fix-max-acc <m>] \
  [--fix-offset-max <m>] [--fix-offset-step <m>] [--fix-offset-stat mean|median] \
  [--fix-offset-course <deg>|off] [--fix-offset-test <m>@<deg>]... [--fix-offset-trace]
```

- **Constant-offset check** (`--fix-offset`, needs `--roads`; analysis
  only: no engine, no metrics files, nothing but relative metres and
  bearings printed). `FixOffsetScan` scores each window of clean fixes
  (session seconds; `auto` = 60 s windows every 30 s) by the mean
  distance to the nearest road, capped at 100 m. A moving fix (≥ 2 m/s,
  with a course) counts only roads within 30° of its course. It scores
  the recorded track and every constant shift on a ±400 m grid (10 m,
  then 1 m around the best). It prints the best shift and a runner-up at
  least 100 m from it, the 5th percentile and median of all shift scores,
  and the recorded track's rank (the share of shifts that do as well).
  The verdict: **off roads** when the recorded mean is ≥ 15 m and its
  rank ≥ 20 %; **shift fits** when, in addition, the best shift is
  ≥ 50 m and halves the mean; **unique** when the runner-up scores at
  least twice the best and 10 m more. `--fix-offset-test` scores a
  hypothesis (a pin's vector) in every window with its rank among the
  grid shifts. Explicit windows also get the fixes' dynamics (path
  against the OBD distance, |GNSS − OBD speed|, net course change
  against gyro yaw about gravity), and every pin is set against the
  time-nearest scanned fix within 5 s. `--fix-source` picks
  `isProducedByAccessory` fixes or the rest. `--fix-max-acc` widens the
  15 m clean limit; the header then says the run is not the clean-fix
  rule. `--fix-offset-trace` lists each fix's distance to the road.
  A tested shift longer than the grid's reach is scored against the roads
  it lands on (the road field reaches the longest tested shift, R35.1-3).
  The engine run's flags (`--gps`, `--hold-out-acc`, `--truth`, `--seed`,
  `--particles`, `--set`, `--out`, `--as-live`, `--file-order`,
  `--compare` and its tolerances, `--write-sidecar`, `--pin-pair-window`,
  `--wrong-road-tolerance`, `--fixpin-*`; `FixOffsetScan.engineOnlyFlags`)
  are refused with `--fix-offset` (status 2, R35.2-3): it would ignore them.
  Results: "Constant-offset GNSS check" below.

- Inputs: motion, OBD, location and manualFix from any v1–v3 recording, fed in
  arrival order: by `t`, a location fix by `max(receivedT, t)`, ties in file
  order.
- **Rejected inputs** (N3.0, R14.2-3): an input the engine rejects as an
  implausible forward time jump (`maxForwardJumpS`, B0-1) is off the
  replay's timeline. Nothing is scored or sampled up to its arrival. Its fix,
  pin and OBD distance are not recorded, and a checkpoint it would have
  given is dropped. The run (and a truth `end`) ends at the last input the
  engine accepted. A real resume, two inputs within 10 s of each other, is
  accepted from the second one on. No acceptance drive has one
  (`inputsRejectedTimeJump` 0).
- **Read report** (N3.0, R11.1-8): each log's `Read` line gives what the
  reader found (gzip members, truncated tail, damaged members, skipped
  lines, `inspect_log`'s "Integrity" wording). A damaged read, which shortens
  the drive or leaves a hole in it (so the distance and the truth `end` are
  scored on what was read), is a `Warning`. `--strict` reads with
  `LogRecovery.strict` and stops with status 3 on any damage, a truncated
  tail included, before `metrics.json` and `metrics.md` are updated. Every
  acceptance drive reads clean.
- **Roads** (N3.2b): `--roads` (repeatable, each pack fully verified) gives
  the engine `NavigationEngine(config:roads:)`, from the first input. With
  `--as-live`, `--compare` or `--write-sidecar` the packs are attached the
  way the app attaches them (N3.3, `ReplayRoadAttach`, next bullets). **Pack order does not matter**
  (N3.2c item 7): `RoadNetwork` sorts the packs by ascending content hash, so
  the same set in any order gives bit-identical results, one `roadSetHash`
  (FNV-1a 64 over the sorted content hashes), one label and one `roads` list.
  Pack indices in outputs (`matchedEdge.pack`) are into that order. The same
  pack twice is refused (status 2). The mode label
  gets `-roads-<first 8 hex of roadSetHash>`. `roads` (per pack: content
  hash, format, OSM timestamp, grid) and `roadSetHash` are in the summary,
  `metrics.json`, `metrics.md` and the GeoJSON track, with "© OpenStreetMap
  contributors". The road metrics (docs/N3_PLAN.md, "Metrics added to
  replay_nav"; `ReplayRoadMetrics`, `NavigationReplay.RoadTruth`):
  - road truth (offline) per withheld clean fix: matched, ambiguous, no road
    (no heading-compatible edge within 15 m), no usable course (GNSS speed
    under 3 m/s);
  - wrong-road share by fixes and by OBD distance (right / wrong / off /
    not engaged, `--wrong-road-tolerance`, default 20 m). It checks capture
    onto a wrong *mapped* road only;
  - unmapped / captured (R21.1-11, widened in N3.2c item 2): withheld clean
    fixes with no heading-compatible road within 15 m, as the sum of two
    reported parts: > 15 m from every edge (`noRoadWithin15`, the R21.1-11
    figure) + an edge within 15 m but none heading-compatible with a usable
    course (`noCompatibleRoadWithin15`; road truth "no road"). A fix with no
    usable course keeps the distance-only rule. Captured, with the same
    split: the estimate on a mapped edge, < 25 m across, truth outside the
    95 % ellipse;
  - residuals per highway class (p50/p95, censored at 15 m), on-road share at
    1 Hz, candidate tests per road update and particle, rejected fixes.

  The GeoJSON adds `matchedEdge` (the engine's matched OSM edge every 10 s)
  and `fixRejectedOffRoad` (fixes the road fix gate ignored). Without
  `--roads`, the road code changes no output (byte-identical to N3.0 when
  it was added).
- `--seed header`: each log's seed is derived from its header's `sessionID`
  (`NavigationSeed`), the seed the live app used.
- `--as-live`: replay as the app ran live: file order, `--seed header` and the
  default config (`--seed N`, `--particles` and `--set` are refused). File
  order is the order the sink's tap delivered inputs to the live engine: a
  location fix where it was written (on arrival, so close to arrival order),
  but a CoreMotion batch where it was delivered, after OBD replies and fixes
  that arrived in the meantime, not at its samples' own `t`. The normal replay
  sorts by arrival, `max(receivedT, t)`, so the two differ in a few late
  samples per batch, which changes the bits (not the accuracy). The mode label
  gets `-as-live`. With `--roads` (N3.3) the engine starts without roads and
  attaches them by the live rule with the packs ready: at each selection
  request (`RoadSelectionRule`) the given packs covering the estimate's 95 %
  circle are selected (`RoadPackSelector`) and attached at that input
  boundary. The summary's `Roads attach` line and `metrics.json`
  (`roadsAttachedAfterInputs`, `attachedRoadSetHash`) record when and which
  set; `roads`/`roadSetHash` stay the given set (the road truth's). The
  written sidecar (`--write-sidecar`, always this rule) attaches at the same
  input.
- `--file-order`: inputs in file order, as `--as-live`, but with any
  `--seed`, `--particles` and `--set`: a seed sweep of the live order. The
  mode label gets `-file-order`.
- `--compare <sidecar>` (one log): runs the app's per-recording loop
  (`LiveNavigationRun`) over the inputs this replay gives its engine, then
  compares its 1 Hz estimates and pins with the sidecar by `t`. It prints the
  largest position, heading and ellipse differences, the sidecar's
  `droppedInputs` and any navigation rows that failed to encode. It passes
  when the result is exact, or within `--tolerance` (default 1 m) and
  `--heading-tolerance` (default 0.1°). Exit status 4 on a failure. A seed or
  config-hash mismatch is a warning; without roads on either side, keys that
  differ only in road-only keys are named inert, not blamed (N3-CMPHASH).
  With `--roads`: a sidecar `roads` line attaches the given set at its
  `afterInputs` (the metrics replay too); a sidecar without one gets the live
  rule. Replay-only estimates after the sidecar's last estimate are counted
  as "the sidecar ends early" (R14.1-4: lines since the last flush lost to a
  kill), named as a cause, not as "no known cause". The mode label then gets `-attach-sidecar` (attached at the
  sidecar's `afterInputs`) or, without `--as-live`, `-attach-live`, so the
  row and GeoJSON do not overwrite the from-start or `--as-live` run's
  (R32.1-5). A `roadSetHash` that differs, or packs on one side only, is a warning
  naming the hashes, and the verdict is never PASS (exact). Format and
  verdicts:
  [NAV_SIDECAR.md](NAV_SIDECAR.md).
- `--write-sidecar <path>` (one log): writes the sidecar the app would have
  written for the recording with no drops (same loop, file order, header seed,
  default config).
- **Pins**: the estimate just before each manual fix (its prior, the sidecar's
  `pin`) is in `metrics.json` (`pins`), `metrics.md`, the summary ("Pin
  estimate") and the GeoJSON (`pinEstimate` point and `pinEllipse95` polygon,
  after every other feature).
- `--gps use`: every fix. `mask-after s`: no fix with `t` > s.
  `mask-after-motion s`: no fix with `t` more than s seconds after motion
  starts (nothing is masked if the car never moves). `none`: no fixes
  (initialisation from a manual fix, if any).
- **Motion start** (`NavigationReplay.motionStart`): the first OBD reply of
  the first run in which every vehicle-speed reply from the primary ECU (`7E8`,
  or no ECU in v1) is at least 3 km/h, consecutive replies are at most 2 s
  apart, and the run lasts at least 3 s. 3 km/h ignores the 1–2 km/h creep in
  a queue or a parking space. This is a replay-side definition: it looks 3 s
  ahead to decide the mask, and the engine never sees it. The summary prints it.
- `--hold-out-acc m`: every fix with accuracy < m is withheld, including for
  initialisation. Each one is printed as (t, acc).
- Scored only against information the engine did not receive: withheld clean
  fixes (≤ 15 m), each manual fix (on the prior, just before it is ingested),
  and truth-file points and `end` (the last input). Errors are in metres and as
  a percentage of the distance travelled so far (∫ OBD speed). The 15 m is a
  frozen replay constant (`NavigationReplay.cleanFixTruthAccM`, R19.2-1), not
  the run's `cleanFixAccM`: the engine still uses its own `cleanFixAccM` to
  decide which fixes it treats as clean, but a `--set cleanFixAccM=…`, a sweep
  or a new default does not change which withheld fixes are scored.
- **Refinement pairs** (`--pin-pair-window s`, default 3, 0 disables; N3.0):
  a manual fix whose `t` is at most s seconds after the previous manual fix's
  `t` is a refinement and is not scored, because the previous pin has just
  moved the estimate and makes it an easy hit. "Previous" means any manual
  fix, scored or not, so a chain (each pin within s of the one before) folds
  onto its first pin. Pins 0, 2 and 4 s apart with s = 3 score only the first.
  Times are compared in whole nanoseconds and the boundary is inclusive. This
  is a replay-side rule that looks at the whole recording (not causal); the
  engine still ingests every pin. Why 3 s: the refinement pairs recorded so
  far are 0.95–1.60 s apart, and the closest pins that are not a pair are
  27.5 s apart. 3 s is about twice the widest pair and the length of the app's
  Undo toast, during which the user is still looking at the pin just placed.
  A window other than 3 s adds `-pair-window-<s>` to the mode label (R18.1-3),
  so runs with different windows keep their own rows in one `--out`. Seed,
  `--particles` and `--set` are not in the label: a sweep over them needs
  one `--out` per value.
- **Excluded pins**: a truth-file `excludePins` entry marks the manual fix
  nearest its `t` within 0.1 s as not scored. The engine still ingests it, and
  it still opens a pair window. An entry that matches no pin is printed.
- A pin that is not scored is still measured and listed: the summary, the
  `metrics.md` table and the pin list mark it "refinement of t … s, not
  scored" or "excluded by truth (…), not scored". `metrics.json` keeps it in
  `checkpoints` with `notScored` set. It is left out of max error, end error
  (the last *scored* checkpoint when there is no truth `end`) and ellipse
  consistency. The summary's "Pins scored" line and `metrics.json`'s
  `pinScoring` give the window and the counts: manual fixes, scored,
  refinements, excluded, and unmatched `excludePins`.
- **Ellipse consistency**: the share of scored checkpoints (withheld clean
  fixes, manual-fix priors, truth points and end) whose truth lies inside the
  engine's 95 % ellipse at their time, overall and per kind. Shown in the
  summary, `metrics.md` and `metrics.json`. A calibrated filter scores about
  95 %; much lower means the ellipse is overconfident. The truth's own σ (a
  pin's σ, for example) is not added to this ellipse. One denominator (N3.0,
  R13.1-8): a checkpoint counts when it is scored and the engine had an
  estimate at its time. One before initialisation is in neither count, and
  the clean-fix "inside 95 %" figure of the summary and `metrics.md` uses the
  same counts, with "(n before initialisation)" when there are any. On every
  acceptance drive every checkpoint has an estimate, so the numbers do not
  change.
- **Ellipse consistency with the truth's σ** (N3.0, Q3; `consistencyWithTruthSigma`
  in `metrics.json`, `inside95WithTruthSigma` per checkpoint, the
  "+ truth σ" line of the summary and column of `metrics.md`): the same
  share, counted on the 95 % ellipse of P + σ_truth² I. P is the engine's
  position covariance, the moment-matched particle mixture (each particle's
  Gaussian plus the spread of the means), whose 95 % ellipse is the one
  above. σ_truth per axis is: for a withheld clean fix, its
  `horizontalAccuracy` / 1.51 (a fixed constant, not the config's
  `fixSigmaPerAccuracy`); for a pin, a frozen max(30 m, mapSpanM / 12)
  (30 m without a usable span; `NavigationReplay.manualFixTruthSigmaM`,
  R19.1-1); for a truth point or `end`, its `sigmaM` (0 if absent). The pin
  formula is the engine's `manualFixSigma` rule with its N3.0 defaults,
  written as constants in the replay code and not read from the config:
  the engine still weights the pin with the run's own `manualFixSigma`, but
  a `--set manualFixSigmaMinM=…`, a sweep or a later change of the engine's
  pin σ (a new default, the N4MF-1 speed term) does not move the truth it is
  scored against. A pin's `truthSigmaM` in `metrics.json` and the summary is
  this frozen σ; on a default-config run it equals the engine's pin σ, as
  before. P + σ² I has P's axes, so each
  semi-axis a becomes √(a² + 5.991 σ²). Same denominator as above. It is
  computed in the replay only; the engine and its ellipse are unchanged.
- Per log: distance, checkpoints, max and end error (end = truth `end`, else the
  last checkpoint; max over every scored checkpoint, pins and truth points
  included, with the % of distance at that checkpoint), the max per kind
  (R19.1-2: `maxErrorByKind` in `metrics.json`, the summary's "Max by kind"
  line; per kind the largest error with its `t`, and the largest error as %
  of the distance from the start at its time with its `t`, which need not be
  the same checkpoint; `metrics.md` shows the clean fixes' two as "clean-fix
  max err m" and "clean-fix max %"), heading-convergence distance (first time `converged` then
  holds for 30 s, inclusive; a shorter run does not count), steps, ms/step
  (engine `ingest` wall time only), seed and config. Distance holds the last
  OBD speed for at most `obdMaxAgeS` (2 s) across a reply gap, so a dropout
  adds no unobserved distance beyond that.
- Output in `--out`: `metrics.md` and `metrics.json` (merged across invocations,
  one row per log and mode), and `<log>-<mode>.geojson` (1 Hz DR track, 95 %
  ellipses every 10 s, fixes used and withheld, truth points with error lines).
  - Rows written by earlier builds still merge (N3.0): a config key, counter
    or metrics field added after the row was written takes its default (a
    counter 0, a later metrics field absent). The default is today's, which
    is not necessarily what that older build ran with.
  - An existing `metrics.json` that does not decode at all (damaged, or not
    a metrics file) is reported with a warning and copied to a new
    `metrics.undecodable-<UTC time>-<pid>.json` (with `-1`, `-2`, … if the
    name exists; an older copy is never overwritten) before it is replaced.
    If the copy cannot be written, or the existing file cannot be read,
    `replay_nav` stops with status 1 and leaves `metrics.json` unchanged.

Truth file (git-ignored `logs/truth.json`, read at runtime), keyed by recording
file name. The values here are illustrative:

```json
{ "<recording file name>": {
    "end":    { "latitude": 0.0, "longitude": 0.0, "sigmaM": 30, "source": "…" },
    "points": [ { "t": 100.0, "latitude": 0.0, "longitude": 0.0, "sigmaM": 30, "source": "…" } ],
    "excludePins": [ { "t": 250.125, "reason": "doubtful tap" } ],
    "excludeFixes": [ { "fromT": 0.0, "toT": 251.0, "reason": "shifted fixes" } ],
    "scoreUntilT": 1500.0,
    "note": "unknown keys are ignored" } }
```

`excludePins` (optional, N3.0): manual fixes of the recording that are not
scored as truth, each matched to the pin nearest its `t` (the `manualFix`
event's session-clock seconds) within 0.1 s. The engine still receives them.
Use it for a pin that is known or likely to be wrong. The reason goes into the
summary and `metrics.md`.

`scoreUntilT` (optional, N3 drive-8; session-clock seconds): the scoring
cutoff, for a recording that runs on after the drive it is scored on (the
driver left the car before the recording stopped). It is scoring only: the
engine ingests every input after it exactly as without it. A checkpoint of
any kind (withheld clean fix, manual fix, truth point, truth `end`) with
`t` > `scoreUntilT` is still measured and listed, marked "after
scoreUntilT, not scored" (`afterScoreUntilT` in `metrics.json`), and counts
in no aggregate: not in max or end error, ellipse consistency (either
variant), heading convergence (judged on the track up to the cutoff), the
road metrics (wrong road, unmapped, residuals, 1 Hz on-road samples) or
`pinScoring.scored` (`pinScoring.afterScoreUntil` counts those pins). One
exactly at `scoreUntilT` is scored. The truth `end` sits at the last input,
so with a cutoff before it the end error falls back to the last scored
checkpoint, as without a truth `end`. Distance is still to the last input.
The summary ("Scored until"), `metrics.md` and `metrics.json`
(`scoreUntilT`, `checkpointsAfterScoreUntil`) record the cutoff and the
count; a run without it writes none of these keys, so its outputs are
byte-identical to the build before it.

`excludeFixes` (optional, N3-FIXPIN; session-clock seconds): location fixes
that are never truth, for a recording whose GNSS fixes are known to be wrong
while they claim to be clean (drive-10's constant-offset accessory fixes). A
fix whose event `t` satisfies `fromT` ≤ `t` ≤ `toT` (inclusive, compared in
whole nanoseconds) is, in every GPS mode, not a clean-fix checkpoint, and not
a clean fix of the offline road truth (road fixes and their wrong / off /
unmapped verdicts, and the residuals, which count used and withheld fixes
alike). It is scoring only: whether the engine receives the fix still
follows `--gps` and `--hold-out-acc` exactly as without it, so with
`--gps use` the engine still ingests those fixes. Manual fixes in the range
are not affected (`excludePins` is for them); the 1 Hz on-road samples are
the engine's, not fix truth, and are not affected either. Several ranges may
overlap. A range with `fromT` > `toT`, a missing bound or a non-numeric one
fails the whole truth file (`replay_nav` stops with status 1, as for any
malformed truth file); JSON cannot hold a non-finite bound. The summary
("Fixes excl."), `metrics.md` and `metrics.json` (`fixesExcludedByTruth`:
the ranges, the location fixes in them, how many of those are clean, and
how many withheld clean-fix checkpoints they removed) record it; a run
without it (absent or empty) writes none of these keys, so its outputs are
byte-identical to the build before it.

## Live in the app (N4 B)

`App/Sources/Navigation/NavigationService.swift` is an actor, off the main
thread, wired in `AppServices` through `RecordingSession.onNavigationFeed`.
For every recording it:
- builds a fresh engine with `NavigationConfig(seed: NavigationSeed.derive(header:))`
  and the default config, so a relaunch mid-drive is a new recording with a
  new engine;
- consumes the recording's tap stream (file order) through Core's
  `LiveNavigationRun`, the loop `replay_nav --compare` also runs;
- writes the sidecar `<recording>.nav.jsonl` ([NAV_SIDECAR.md](NAV_SIDECAR.md)):
  the header, an estimate every session second, and a pin at each manual fix;
  flushed every 10 s and, with the log, on `.background` and on a memory
  warning (`RecordingSession.onFlush` → `NavigationService.flush()`,
  R14.1-4);
- measures engine time per 10 Hz step with `ContinuousClock` (EMA and
  maximum);
- answers `snapshot(at:)` with a `NavigationSnapshot` (estimate, ellipse,
  heading, `converged`, `initialized`, ms/step, ESS, heading std, speed scale,
  `droppedInputs`) on the recording's session clock.

**Roads attached mid-run (N3.3).** `LiveNavigationRun` starts without roads
unless a network is given at init. `NavigationEngine.attachRoads(_:)`
attaches one between two inputs, once, before or after initialisation: the
road state starts cleared (as a reseed leaves it), and nothing else changes,
so every line before the attach is the no-roads run's, and an attach before
the first input equals `init(config:roads:)`. It is refused, engine
unchanged, when a network is already attached or when
`config.validated(roads:)` would change any key: the config never changes
mid-run. The selection rule (`RoadSelectionRule`): the run raises a
`RoadSelectionRequest` (the estimate's centre and 95 % semi-major axis)
after the ingest at which the engine first initialises and, while no
network is attached, after every ingest in which it used a position (a fix,
a released held fix, a manual fix). Once a network is attached no request
is raised again, a manual reset of the cloud included. The attach's
`afterInputs` is the run's `inputs` then; its `t` is the engine's latest
accepted arrival (`NavigationEngine.latestArrival`), nil for an attach
before the first input.

**Pack catalog and selection (N3.3, Core).**
`RoadPackCatalog(urls:cache:)` takes the pack files a caller offers (it
chooses the directory) and a `RoadPackVerificationCache`, keyed by file
identity (name, size, modification date), not by content hash. A cache hit
is not verified again; a miss is opened with full verification
(`RoadPack(contentsOf:verify: true)`) and timed. A truncated, corrupt or
structurally bad pack is refused with its reason (cached too, until the
file changes); a file that cannot be read is listed and not cached. The
value holds the content hash, verified yes/no and the reason, the verify
time, OSM timestamp, format version, bounds (E7) and grid ID; the caller
persists it as JSON (`encoded()`, `init(data:)`). `RoadPackSelection`
opens the usable packs memory-mapped without full verification, refusing a
pack whose identity changed or whose header's content hash is not the
verified one, then selects every pack whose coverage (`COVR`, else the
bounding box) intersects the request's circle and builds their
`RoadNetwork`; packs that cannot be used together (different grids, the
same pack twice) are refused as a set. `RoadPackSelection.attempt` does
the same and also records the attempt: each pack file's state and
coverage, and the outcome. That record becomes the sidecar's
`roadsSelection` line. `RoadPackSelector` is the synchronous form over
fixed packs (`replay_nav --as-live --roads`).
Everything is Sendable values and pure functions, callable off the main
actor. Data: © OpenStreetMap contributors, ODbL 1.0.

**Live roads in the app (N3.3).** The path from a pack file to a road
update in a recording:
- **Library.** `App/Sources/Navigation/RoadPackLibrary.swift`, an actor,
  lists the `*.roadpack` files of `Documents/RoadPacks/` (the developer
  bridge: Finder → iPhone → Files; N3.4 replaces only this source) and
  verifies each once through `RoadPackCatalog`. The verification cache is
  `Application Support/RoadPackVerification.json`, keyed by file identity.
  Listing, verification and opening run in a detached `.utility` task, at
  launch, when a recording starts and when Diagnostics appears; a cache hit
  costs one `stat`. No pack is bundled or downloaded.
- **Selection and attach.** `NavigationService` hands each
  `RoadSelectionRequest` of the recording's `LiveNavigationRun` to a
  detached task. The task takes the library's candidates (and the files
  refused at scan) and calls `RoadPackSelection.attempt`, which also builds
  the `RoadNetwork`. Back on the actor, between two inputs, the service calls
  `LiveNavigationRun.finishSelection`, which attaches a selected network and
  records the attempt for the `roadsSelection` lines (then writes `roads`
  after a successful attach).
  The selection is asynchronous, so the live attach can come some inputs
  after the request; `replay_nav --as-live` attaches at the request itself.
  A request that arrives during a selection replaces the pending one (it is
  not an attempt and writes no line). A refused set is remembered with its
  reason and not built again; a repeat is `refused` again. At the end the
  repeats still pending are written, then a selection still in flight as
  `unfinished`, before the sidecar closes. Recording and the sensor streams never wait for
  any of it; until the attach the run is the no-roads run.
- **Sidecar.** The app writes sidecar v2. The attach writes its `roads`
  line (`t`, `afterInputs`, each pack's content hash, format, OSM timestamp
  and grid, and `roadSetHash`), and estimates carry `onRoadShare`.
  `replay_nav --as-live --roads <same packs> --compare <sidecar>` attaches
  at that `afterInputs` ([NAV_SIDECAR.md](NAV_SIDECAR.md)). The selection
  attempts are recorded as `roadsSelection` lines, diagnostic only, with
  the outcome, the pack files seen and why none attached. A line is written
  when the outcome or the candidates change. Identical repeats are counted
  and written as one line with `repeats` and `firstT`: at the next change,
  at an attach, or at the end. Core does this
  (`NavSidecar.RoadsSelectionLog`, through `LiveNavigationRun.finishSelection`
  and `closingLines(inFlight:)`), and `replay_nav --write-sidecar` writes
  the same lines.
- **Diagnostics** (Settings): a Road packs section lists each pack
  (verified, or the refusal reason; size, OSM date, hash prefix, and
  "cached" or "verified in x s"). Below it: "Recording uses" (the pack
  names and the session time roads became active; else none, a refusal
  reason, or "looking for a pack"), the on-road share, and "© OpenStreetMap
  contributors" while a pack is in use. The Memory row is the app's
  `phys_footprint`, for D1.

The as-live replays with roads, the Mac memory numbers and the late-attach
check are in "N3.3: roads live (2026-10-15)" below.

N4 B acceptance and the as-live table: moved to [docs/archive/NAVIGATION-history.md](archive/NAVIGATION-history.md).

## Adoption rule for engine changes

A change to the engine or its defaults is adopted only if, on every acceptance
drive (clean-long, clean, manual, jammed-A, jammed-B, from N3.0 drive-7,
from N3.2e drive-8, added 2026-10-14, and from N3 drive-9's two runs, added
2026-10-15), the **mean over seeds 1–5** passes:

- **Drives scored in metres** (clean-long and clean max error, manual error at
  truth point 1): the mean may get worse by at most 2 m or 5 % of the
  previous mean, whichever is larger.
- **Drives scored in % of distance** (jammed-A, jammed-B end error; drive-7
  and drive-8 worst withheld clean fix; drive-9 error at its truth point,
  both runs, with and without roads): the mean may get worse by at most
  0.1 percentage points.
- **Ellipse consistency** (share of scored checkpoints inside the 95 %
  ellipse, mean over seeds) must not drop on any drive. **Since N3.0 (Q3,
  decided by the user 2026-10-11) the gated consistency is the one with the
  truth's own σ added**: the ellipse of P + σ_truth² I (`consistencyWithTruthSigma`,
  see "replay_nav"). Before N3.0 it was the engine's ellipse alone
  (`consistency`). Both are reported for every run, and the engine-only one
  stays visible, but only the variant gates.
  - Why: roads (N3.2) will shrink the ellipse across the road to a few
    metres, while the truth has its own error (pins σ 30–104 m, clean fixes
    3–5 m). Against the engine's ellipse alone a correct estimate would count
    as outside because of the truth's error, not the engine's.
  - What it cannot hide: adding σ_truth only widens the ellipse. An
    overconfident engine still fails against an accurate truth, and an
    inaccurate truth cannot make a miss count against the engine.
  - The truth is never the candidate's to set, neither its σ nor which
    checkpoints it holds. A clean fix's σ comes from its `horizontalAccuracy`
    over a fixed 1.51, and a pin's from a frozen max(30 m, mapSpanM / 12)
    (R19.1-1), not from the run's config. If the pin's truth σ followed the
    config, a change that raised the engine's pin σ would pass "must not
    drop" by widening the truth, while the engine's estimate and ellipse at
    the pin (scored on the prior, before the pin is ingested) stayed
    bit-identical. Which withheld fixes are clean-fix truth is frozen the
    same way: accuracy ≤ 15 m (`NavigationReplay.cleanFixTruthAccM`,
    R19.2-1), not the run's `cleanFixAccM`. If it followed the config, a
    change that lowered `cleanFixAccM` would drop its worst 10–15 m
    checkpoints from clean and clean-long max error, from drive-7's worst
    withheld clean fix and from the consistency denominators, and one that
    raised it would add 15–30 m fixes as truth. Changing these constants is
    a change to the metric, and needs its own decision and re-baseline.
  - Baseline: on the N3.0 baseline (engine as N4-B1) the two agree on every
    acceptance drive and seed; see "N3.0 baseline: both consistency
    definitions" below. So the switch moves no previous adoption decision.

The acceptance criteria themselves must still pass on every seed. manual-3 and
manual's convergence distance are reported, not gated. This replaces the
strict per-seed rule used for N2.2. Correctness fixes, such as the review
run 13 findings, are reported against the previous values, with every change
explained.

## Acceptance runs

`<clean>`, `<clean-long>`, `<manual>`, `<manual-3>`, `<jammed-A>`,
`<jammed-B>`, `<drive-7>`, `<drive-8>` and `<drive-9>` are the paths of the recordings known
under those aliases (kept outside the repository or in the git-ignored `logs/`).

| alias | run | criterion |
|---|---|---|
| clean-long | `--gps mask-after 380` | max ≤ 30 m |
| manual-3 | `--gps use` | each pin scored on its prior; reported, not gated |
| clean | `--gps mask-after 230` | max ≤ 30 m |
| manual | `--gps use --hold-out-acc 100` | truth point 1 ≤ 200 m; convergence reported |
| jammed-A, jammed-B | `--gps use` | end ≤ 2.5 % of distance |
| drive-7 | `--gps mask-after 1800` | every withheld clean fix after 1800 s ≤ 2.5 % of distance from the start (decided 2026-10-12, see below); scored-pin and clean-fix consistency reported |
| drive-8 | `--gps mask-after 785` | every withheld clean fix up to 1988 s (truth `scoreUntilT`) ≤ 2.5 % of distance from the start (decided 2026-10-14, see below); clean-fix consistency reported |
| drive-9 (1) | `--gps mask-after 1229` | error at the truth point (1937.7 s) ≤ 2.5 % of distance from the start, gated with roads only (decided 2026-10-15, see below) |
| drive-9 (2) | `--gps use --hold-out-acc 100` | the same point and threshold, gated with roads only |

- **clean**: the criterion is `mask-after 230`, i.e. 30 s of clean GNSS at
  speed (from about 200 s), then 1.8 km of pure dead reckoning. That is what
  the original "30 s" meant, and what the earlier offline 24 m baseline used.
  An earlier reading, `mask-after 30`, masks before the car has moved at all
  (motion starts at 49.5 s), so heading is unobservable and it fails at about
  2.6 km whatever the engine does.
- **clean-long**: T = 380 s. Rule, fixed before any run: the latest whole 10 s
  that leaves at least 1.8 km of OBD distance after it, i.e. the most GNSS that
  still leaves the required dead reckoning. 380 s leaves 1.95 km; 390 s would
  leave 1.79 km. The recording starts mid-drive, so motion starts at 0 s. Up to
  T the car is at highway speed with 5 m fixes and 1° courses.
- **drive-7** (added in N3.0, 2026-10-12): 19.9 km, iPhone 16 Pro Max. GNSS is
  jammed (tower and Wi-Fi fixes only) until about 1869 s, then clean. Twelve
  pins, three of them refinement pairs.
  - **Truth.** The first pin of each refinement pair (pair scoring, default
    3 s window), plus the clean fixes after 1800 s, withheld from the engine
    by `--gps mask-after 1800` and scored. That is 266 clean fixes from
    1870 s to the end, 16.8–19.9 km into the drive. Between the mask and the
    first clean fix the engine gets nothing at all (the masked tower fixes
    included). The last pin it receives is the 1764.6/1766.2 s pair, at
    14.9 km. So the clean fixes measure about 1.9–5.0 km of pure dead
    reckoning from a pin, after 30 min of jamming.
  - **Excluded pins.** The pins at t ≈ 599 s and ≈ 626 s are excluded from
    truth with `excludePins` in the truth file; the engine still ingests
    them. They are likely about 200 m off along-track, **likely, not
    proven**: the user does not remember the taps. Backlog N3MF-1 uses them
    as its regression case. This leaves 7 scored pins (12 manual fixes, 3
    refinements, 2 excluded).
  - **Criterion (decided 2026-10-12 by the user).**
    Every withheld clean fix after 1800 s is within 2.5 % of the distance
    travelled at its time (∫ OBD speed from the start, as for jammed-A/B):
    `replay_nav`'s "clean-fix max %" (`maxErrorByKind.cleanFix.maxPercent`,
    R19.1-2), not "max %", which covers the pins too. Rule: drive-7 is a
    jammed drive, so it takes the jammed drives' existing threshold
    unchanged, set in N2 before drive-7 existed; nothing about the
    threshold was chosen from this drive's numbers. It applies to the worst
    withheld clean fix rather than only the last one, because the drive has
    266 truth points, not one end. The baseline (1.08–1.23 %) passes with a
    wide margin, so the criterion only catches a gross regression; the
    adoption rule (mean worse by at most 0.1 pp) is the tighter check. For
    that rule drive-7 is a drive scored in % of distance.
  - **Reported, not gated:** the max error in metres, the error as a share
    of the distance since the last pin, and the per-kind consistency over the
    clean fixes and over the 7 scored pins. The pins' own error is not gated
    because two were likely placed wrong and the truth for the rest is a
    finger on a map.
  - **Consistency gate:** the gated figure (`consistencyWithTruthSigma`, mean
    over seeds) is taken over all scored checkpoints, the clean fixes and the
    7 scored pin priors together, not over the clean fixes alone
    (`EllipseConsistency` counts every checkpoint with `isScored`,
    in `NavigationReplay.swift`; the two excluded pins and the 3
    refinements are not scored).
  - **Timing.** The live build that recorded drive-7 was **Debug**
    (`-Onone`). Its sidecar's `msPerStep` (median 2.8 ms) and `maxStepMs`
    (45 ms) are not a device performance number. The sidecar predates the
    `buildConfiguration` header field, so it does not say so itself.
- **drive-8** (added 2026-10-14, before N3.2e): about 2092 s and 19.1 km,
  iPhone 16 Pro Max, **Debug** build. Network (tower and Wi-Fi) fixes only
  until the first clean fix at 664 s, clean after it. The screen was locked
  from 10 s to 581 s. No pins.
  - **Mask.** T = 785 s. Rule, pre-declared and not swept: the first clean
    fix (≤ 15 m, 664.2 s) plus 120 s, i.e. 784.2 s, rounded up to the whole
    second. The engine gets network fixes, then two minutes of clean GNSS;
    the last fix it receives is at 784.1 s (7.90 km), and after that nothing.
  - **Truth.** The withheld clean fixes up to 1988 s, the truth file's
    `scoreUntilT` (see "replay_nav"): 1199 fixes from 785 s to 1987 s,
    7.91–19.14 km into the drive, so up to 11.25 km of pure dead reckoning.
    The driver left the car at about 1988 s; the OBD loss after that is
    ignition off. The 83 clean fixes after 1988 s are listed as "after
    scoreUntilT" and not scored. The truth file has no `end` and no points
    for this drive.
  - **Criterion (decided 2026-10-14 by the user).** Every scored withheld
    clean fix is within 2.5 % of the distance travelled at its time (∫ OBD
    speed from the start, as for drive-7; "clean-fix max %"). Rule: drive-8 takes the jammed
    drives' 2.5 % threshold unchanged, chosen before any run, like drive-7.
    For the adoption rule drive-8 is a drive scored in % of distance.
  - **Reported, not gated:** the max error in metres, the error as a share
    of the distance since the last fix the engine received (784.1 s), the
    consistency over the scored clean fixes (engine ellipse and with the
    truth's σ), and heading convergence.
  - **Timing.** The live build that recorded drive-8 was Debug (the sidecar
    header says `buildConfiguration` debug). Its sidecar timing is not a
    device performance number.
- **drive-9** (added 2026-10-15, decided by the user): about 2024 s and
  14.2 km, iPhone 16 Pro Max, the first **Release** build drive. GNSS is
  jammed for the whole drive: 170 of 171 fixes are speedless network fixes (speed −1), and
  there is no clean fix at all, so a worst-withheld-clean-fix criterion is
  impossible. 37 speedless fixes carry a valid course (courseAccuracy
  22–45°). Three pins (228.7, 317.5, 580.3 s), all scored, none excluded.
  The car is parked about 604–1229 s, with OBD down for most of it (the
  replies stop at 683 s at a stop); leg 2 runs 1230–1985 s, after which the
  car is parked again.
  - **Truth.** One truth point: the speedless 61 m fix at 1937.7 s, taken
    while moving, with σ = 61 / 1.51 = 40.4 m (the clean-fix rule's
    accuracy / 1.51). Both runs withhold it from the engine. No `end` (there
    is no position for the parked car after the drive), no `excludePins`, no
    `scoreUntilT`.
  - **Run (1), `--gps mask-after 1229`.** The engine gets nothing after the
    park: leg 2 is about 7.9 km of pure dead reckoning (the truth point is
    at 13.71 km, the last fix the engine receives at 5.78 km). This run
    hides every leg-2 fix and course from the engine.
  - **Run (2), `--gps use --hold-out-acc 100`** (manual-style): every fix
    under 100 m is withheld, so the ~1414 m network fixes, and their
    courses, reach the engine as they did live. It also withholds the 49
    park fixes under 100 m (604–1229 s, while OBD was down), five 72–85 m
    fixes at 1418–1437 s and the pre-session fix. Sanity check, done on the
    baseline before adopting the run: the estimate at 1229 s is 34–35 m
    (with roads) and 21 m (without) from the two 16.5 m stop fixes of the
    park (1040.8 and 1053.5 s), which lie 12 m from the median of the park
    fixes; run (1), which receives the park fixes, is 18 m and 3–4 m from
    them. That is within the park fixes' own scatter and a pin's σ, so the
    run is sane and is gated with the same rules.
  - **Criterion (both runs).** The error at the truth point is within 2.5 %
    of the distance travelled at its time (∫ OBD speed from the start), the
    jammed drives' threshold, unchanged. The absolute gate applies **with
    roads only**: without roads the baseline misses it by about 4× (run (1)
    10.0–10.4 %, run (2) 8.3–8.5 %), which is reported, not gated. The
    adoption rule (mean ≤ 0.1 pp worse, consistency with the truth's σ must
    not drop) applies to both runs with and without roads. For it drive-9
    is a drive scored in % of distance.
  - **Reported, not gated:** the pin priors (scored checkpoints, they count
    in consistency), and the time and distance to first converged.
  - **Timing.** Release build: see docs/PLAN.md §6 B-1.

```bash
cd Core
swift run -c release replay_nav <clean-long> --gps mask-after 380 --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <manual-3> --gps use --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <clean> --gps mask-after 230 --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <manual> --gps use --hold-out-acc 100 --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <jammed-A> <jammed-B> --gps use --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <drive-7> --gps mask-after 1800 --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <drive-8> --gps mask-after 785 --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <drive-9> --gps mask-after 1229 --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <drive-9> --gps use --hold-out-acc 100 --truth ../logs/truth.json --out ../logs/out
```

**drive-7 baseline (N3.0, seeds 1–5 arrival order and `--as-live`, release,
Mac, default config, engine as N4-B1).** Truth is likely, not proven, at the
two excluded pins; the scored truth is described above.

| run | max over withheld clean fixes | at | % of distance | % of distance since the last pin | clean fixes inside 95 % | scored pins (error m; * outside 95 %) | pins inside 95 % | converged at | ms/step | criterion |
|---|---:|---|---:|---:|---|---|---|---:|---:|---|
| seed 1 | 218.07 m | last fix (2144 s, 19.86 km) | 1.098 % | 4.39 % | 266/266 | 61 / 96 / 210\* / 99 / 27 / 89 / 25 | 6/7 | 0.58 km | 0.075 | **PASS** |
| seed 2 | 214.30 m | last fix | 1.079 % | 4.32 % | 266/266 | 61 / 95 / 210\* / 93 / 24 / 89 / 19 | 6/7 | 0.58 km | 0.075 | **PASS** |
| seed 3 | 243.74 m | last fix | 1.227 % | 4.91 % | 266/266 | 62 / 94 / 210\* / 47 / 9 / 89 / 13 | 6/7 | 0.58 km | 0.075 | **PASS** |
| seed 4 | 222.61 m | last fix | 1.121 % | 4.49 % | 266/266 | 61 / 97 / 211\* / 109 / 33 / 86 / 29 | 6/7 | 0.58 km | 0.075 | **PASS** |
| seed 5 | 231.13 m | last fix | 1.163 % | 4.66 % | 266/266 | 61 / 92 / 210\* / 106 / 30 / 89 / 27 | 6/7 | 0.58 km | 0.074 | **PASS** |
| mean (seeds 1–5) | 225.97 m | | 1.138 % | 4.55 % | 100 % | | 85.7 % | | | **PASS** |
| `--as-live` | 228.69 m | last fix | 1.151 % | 4.61 % | 266/266 | 62 / 92 / 210\* / 61 / 30 / 87 / 35 | 6/7 | 0.60 km | 0.080 | **PASS** |

- The error grows through the masked stretch, from 95–106 m at the first
  clean fix (1.9 km after the last pin) to the maximum at the last one
  (5.0 km after it). The heading std at the last pins is 2.0–2.8°, and one
  such σ over 5 km is 175–245 m sideways: the error is the size that heading
  uncertainty alone allows, and the ellipse covers every clean fix on every
  seed.
- The pin outside the ellipse is the first pin of the 706 s pair (210 m on
  every seed). That is the error the two excluded pins left behind (N3MF-1).
- Against its distance since the last pin (4.3–4.9 %), drive-7 is worse
  than the jammed drives are against their whole distance. That is reported,
  not gated: the jammed rule is defined on the distance from the start.

**drive-8 baseline (2026-10-14, seeds 1–5 arrival order, release, Mac,
default config, build 598d2f6, `--gps mask-after 785`, truth `scoreUntilT`
1988).** Without roads and with roads (`--roads` national + region-A packs, as
N3.2b/N3.2d). Scored truth: 1199 withheld clean fixes from 785.1 s to
1987.1 s (7.91–19.14 km); 83 clean fixes after scoreUntilT, listed, not
scored. The engine's last received fix is at 784.1 s (7.90 km), so the scored
fixes cover up to 11.25 km of pure dead reckoning. No `--as-live` row was run.

No roads:

| run | max over scored withheld clean fixes | at | % of distance | % since last fix received | clean fixes inside 95 % | + truth σ | after scoreUntilT | converged at | ms/step | criterion |
|---|---:|---|---:|---:|---|---|---:|---:|---:|---|
| seed 1 | 275.22 m | 1944.1 s, 18.90 km | 1.456 % | 2.50 % | 1199/1199 | 1199/1199 | 83 | 6.62 km (665 s) | 0.070 | **PASS** |
| seed 2 | 270.91 m | 1944.1 s, 18.90 km | 1.433 % | 2.46 % | 1199/1199 | 1199/1199 | 83 | 6.62 km | 0.070 | **PASS** |
| seed 3 | 293.34 m | 1944.1 s, 18.90 km | 1.552 % | 2.67 % | 1199/1199 | 1199/1199 | 83 | 6.62 km | 0.070 | **PASS** |
| seed 4 | 259.16 m | 1944.1 s, 18.90 km | 1.371 % | 2.35 % | 1199/1199 | 1199/1199 | 83 | 6.62 km | 0.069 | **PASS** |
| seed 5 | 301.66 m | 1944.1 s, 18.90 km | 1.596 % | 2.74 % | 1199/1199 | 1199/1199 | 83 | 6.62 km | 0.069 | **PASS** |
| mean | 280.06 m | | 1.482 % | 2.54 % | 100 % | 100 % | | | 0.070 | **PASS** |

With roads:

| run | max over scored withheld clean fixes | at | % of distance | % since last fix received | clean fixes inside 95 % | + truth σ | after scoreUntilT | converged at | ms/step | criterion |
|---|---:|---|---:|---:|---|---|---:|---:|---:|---|
| seed 1 | 15.87 m | 904.2 s, 8.88 km | 0.179 % | 1.61 % | 1176/1199 | 1194/1199 | 83 | 0.41 km | 0.111 | **PASS** |
| seed 2 | 15.74 m | 904.2 s, 8.88 km | 0.177 % | 1.59 % | 1176/1199 | 1195/1199 | 83 | 0.40 km | 0.113 | **PASS** |
| seed 3 | 15.84 m | 904.2 s, 8.88 km | 0.178 % | 1.60 % | 1176/1199 | 1194/1199 | 83 | 0.40 km | 0.113 | **PASS** |
| seed 4 | 15.75 m | 904.2 s, 8.88 km | 0.177 % | 1.59 % | 1176/1199 | 1194/1199 | 83 | 0.41 km | 0.114 | **PASS** |
| seed 5 | 15.77 m | 904.2 s, 8.88 km | 0.178 % | 1.60 % | 1176/1199 | 1194/1199 | 83 | 0.39 km | 0.109 | **PASS** |
| mean | 15.79 m | | 0.178 % | 1.60 % | 98.1 % | 99.6 % | | | 0.112 | **PASS** |

- Column changes from drive-7's table: "since the last pin" becomes "since
  last fix received" (drive-8 has no pins); the two pin columns are replaced
  by "+ truth σ" and "after scoreUntilT"; separate no-roads and roads tables,
  because drive-7's baseline predates roads.
- Without roads the error over the dead-reckoned distance, taken at the
  max-%-from-start fix (the "at" column; not the maximum of that ratio over all
  scored fixes, which this table does not give), is 2.35–2.74 %, above 2.5 %
  on seeds 3 and 5. Reported, not gated, like drive-7's "since the
  last pin". The gate (distance from the start) passes with about 0.9 pp
  margin.
- Seed 4's max in metres is 259.16 m at 1946.1 s; its max in % is at
  1944.1 s.
- Without roads the heading converges only at 6.62 km (665 s), the first
  clean fix; before that the drive has network fixes only.
- The first scored fixes are trivial (about 1.3 m, 1 s after the last
  received fix); the test is the 11 km after.
- With roads: end error (last scored fix) 4.3–4.4 m, wrong-road share 0 on
  every seed; the max is early (904 s, 8.88 km) rather than near the end.
- OBD vs GPS speed on the clean stretch (664–1988 s, GPS > 30 km/h, 659
  pairs, OBD interpolated within 0.5 s): GPS/(OBD + 0.5 km/h) median 1.015
  (bootstrap SE 0.001), flat across 30–50 / 50–70 / 70+ km/h bands (1.013 /
  1.015 / 1.016); without the +0.5 offset 1.023. Consistent with the
  speedScale prior 1.016 ± 0.01; the engine's final scale is 1.016–1.018 (no
  roads), 1.015–1.017 (roads). Serially correlated pairs, so the SE is
  optimistic; the band spread (about ±0.002) is the better guide. (For
  context, drive-7's shorter, noisier clean stretch gives 1.030, 174 pairs.)
- Timing: the recording build was Debug; ms/step here is the Mac release
  replay.
- Outputs (git-ignored): logs/drive8/acc/.

Superseded result tables (N2.1 baseline, N2.3, N4-B0, N4-B1): moved to [docs/archive/NAVIGATION-history.md](archive/NAVIGATION-history.md).

### N3.0–N3.2e runs (moved)

Moved unchanged on 2026-10-17 to [docs/archive/NAVIGATION-history.md](archive/NAVIGATION-history.md), same headings: "N3.0 step 1: scoring rule", "N3.0 baseline: both consistency definitions", "N3.0 exit" (engine fixes, the baseline N3.2 was judged against), "N3.2b: first measurement with roads", "N3.2c item 7", "N3.2c item 2", "N3.2d: pre-declared grids", "N3.2e item 1: level rule across packs", "N3.2e: candidates on the cross-pack level rule". Open one only when a task needs that run's numbers; the current default and why is "N3.2 decision" below, the live re-check is "N3.3: roads live".

### N3.2 decision (2026-10-14)

**roadCorrelationM 100 is the N3.2 default.** It is an explicit trade-off
accepted by the user against a failing gated check (drive-7 consistency). The
adoption rule is unchanged: against N3.0 this config still FAILs it. The
default config is now N3.2e item 1 plus `roadCorrelationM` 100.

Means over seeds 1–5, from the N3.2e tables above. Gated value: metres for
clean-long, clean, manual; % of distance for the rest. Consistency includes
the truth's σ.

| drive | gated value, mean (range) | Δ mean vs N3.0 (allowed) | consistency + truth σ (N3.0 → now) | verdict vs N3.0 |
|---|---|---|---|---|
| clean-long | 19.38 (19.22–19.50) m | -0.04 (≤ +2.00) | 100.0 → 100.0 % | PASS |
| clean | 14.39 (11.81–18.82) m | +1.40 (≤ +2.00) | 100.0 → 100.0 % | PASS |
| manual | 7.23 (5.81–10.02) m | -43.27 (≤ +2.52) | 100.0 → 100.0 % | PASS |
| jammed-A | 0.177 (0.170–0.182) % | -0.960 (≤ +0.1) | 100.0 → 100.0 % | PASS |
| jammed-B | 0.201 (0.171–0.245) % | -0.866 (≤ +0.1) | 100.0 → 100.0 % | PASS |
| drive-7 | 0.130 (0.123–0.148) % | -0.998 (≤ +0.1) | 99.6 → 96.3 % | FAIL (consistency) |
| drive-8 | 0.186 (0.184–0.188) % | -1.295 (≤ +0.1) | 100.0 → 100.0 % | PASS |
| manual-3 (sanity, not gated) | 68.37 (66.50–70.20) m | -163.66 (not gated) | 66.7 → 66.7 % | not gated |

- **Passes every gated drive except drive-7's consistency:** 6 of the 7 gated
  drives. manual-3 is sanity only and is not counted.
- **Fails only drive-7 consistency:** 99.6 → 96.3 %, per seed 266 / 265 / 267 /
  252 / 265 of 273 (N3.0: 272 every seed). All the extra misses are in its
  last 0.3 km, on service roads (2068–2087 s). The error there is about 23 m
  against an ellipse of about 25 × 21 m.
- **Gains:**
  - manual truth point 1 50.5 → 7.2 m, and heading converged at 1.52–1.58 km:
    the known FAIL (≤ 2 km) is closed;
  - jammed-A error down 84 %, jammed-B 81 %, drive-8 1.482 → 0.186 % (87 %);
  - drive-7 worst withheld clean fix 213–245 m → 24–28 m.
- **Costs besides drive-7:**
  - slower heading convergence than the old default: jammed-A 0.74–0.92 km
    (was 0.30–0.31), jammed-B 0.43–0.44 (was 0.19–0.22), drive-8 0.66–0.68
    (was 0.39–0.41);
  - clean +1.40 m, within the allowance (seed 4 reaches 18.82 m).
- **Regression cases kept for the off-road and ellipse work** (see
  docs/N3_ROAD_OFFROAD.md, "Regression cases"): drive-7 at 2068–2087 s (the
  service-road end) and N3.2 test 3 (an unmapped road beside a mapped one,
  a known FAIL).
- The default change is a separate commit (4e87038). Exactness check
  (release build of that commit, no `--set`): with roads (national +
  region-A), seeds 1–5, every acceptance drive, all 35 runs match the N3.2e
  `roadCorrelationM` 100 column exactly: every GeoJSON byte-identical, and
  `metrics.json` differs only in `msPerStep` and `maxIngestMs`. Without
  roads (seed 1, every drive) every GeoJSON is byte-identical to N3.2e;
  `metrics.json` differs only in `config.roadCorrelationM` (the recorded
  config) and the timing fields. Outputs: logs/n32dec/ (git-ignored).
- **Tests.** Eight synthetic tests built on 30 by construction now set
  `roadCorrelationM` 30 in their config (closed-form tempering checks and
  road-scoring scenarios measured at 30); no assertion was loosened. Test 3
  (known FAIL) records 36 known issues at 100 instead of 39.
- **Live path.** No packs are loaded live, so live estimates are unchanged.
  The sidecar header's config, and so its `configHash`, changes: `replay_nav
  --as-live --compare` on a sidecar written before this change warns about a
  config-hash difference in `roadCorrelationM` (backlog N3-CMPHASH).

### N3 candidate: speedless course (moved)

Measured and rejected (2026-10-15). Moved unchanged on 2026-10-17 to [docs/archive/NAVIGATION-history.md](archive/NAVIGATION-history.md), same heading.

### N3.3: roads live (2026-10-15)

**The adoption replays repeated as live** (N3.3 exit). Release build of
89ba3ee (items 0–5) on the Mac. Every acceptance run with its acceptance
flags, run as `--as-live` (file order, the header's seed, the default
config, which is the N3.2 decision's) with `--roads` national + region-A and
the live attach rule, and again without `--roads`. One seed per drive: the
header's. The N3.2 columns are seeds 1–5 in arrival order: logs/n32dec for
the seven older drives, and the N3-SLC baseline (logs/n3sc, key 0 after the
revert, equal to logs/n32dec on the older drives) for drive-9. Gated value
and consistency as in "N3.2 decision": metres for clean-long, clean and
manual, % of distance for the rest, consistency with the truth's σ. Each
cell is one as-live run, so the adoption rule (a mean over seeds 1–5) does
not apply to it; the criteria do.

With roads:

| drive | N3.2, seeds 1–5: mean (range) | as live | inside the N3.2 range | consistency + σ, N3.2 mean → as live | criterion, as live | converged, as live | attach: afterInputs, t | ms/step, max ingest |
|---|---|---|---|---|---|---|---|---|
| clean-long | 19.38 (19.22–19.50) m | 19.31 m | yes | 100.0 → 100.0 % | PASS | 0.02 km | 3, 0.04 s | 0.095, 1.00 ms |
| clean | 14.39 (11.81–18.82) m | 16.17 m | yes | 100.0 → 100.0 % | PASS | 0.03 km | 3, 0.04 s | 0.093, 1.02 ms |
| manual | 7.23 (5.81–10.02) m | 6.92 m | yes | 100.0 → 100.0 % | PASS | 1.70 km (N3.2: 1.52–1.58) | 11756, 86.61 s | 0.110, 4.49 ms |
| jammed-A | 0.177 (0.170–0.182) % | 0.178 % | yes | 100.0 → 100.0 % | PASS | 0.84 km | 4, 0.04 s | 0.119, 1.25 ms |
| jammed-B | 0.201 (0.171–0.245) % | 0.178 % | yes | 100.0 → 100.0 % | PASS | 0.43 km | 7, 0.06 s | 0.115, 1.23 ms |
| drive-7 | 0.130 (0.123–0.148) % | 0.151 % | **no** | 96.3 → 92.7 % | PASS | 0.14 km | 2, 0.05 s | 0.115, 1.05 ms |
| drive-8 | 0.186 (0.184–0.188) % | 0.185 % | yes | 100.0 → 100.0 % | PASS | 0.66 km | 4, 0.06 s | 0.112, 1.09 ms |
| drive-9 (1) | 0.042 (0.033–0.051) % | 0.067 % | **no** | 100.0 → 100.0 % | PASS | 2.51 km | 20, 0.17 s | 0.079, 1.11 ms |
| drive-9 (2) | 0.043 (0.033–0.054) % | 0.077 % | **no** | 100.0 → 100.0 % | PASS | 2.51 km | 19, 0.17 s | 0.079, 1.37 ms |
| manual-3 (sanity) | 68.37 (66.50–70.20) m | 68.26 m | yes | 66.7 → 66.7 % | not gated | 0.80 km (N3.2: 0.41–0.48) | 7, 0.09 s | 0.112, 1.44 ms |

Without roads (no attach; ms/step measured with two replays running in
parallel):

| drive | N3.2, seeds 1–5: mean (range) | as live | inside the N3.2 range | consistency + σ, N3.2 mean → as live | criterion, as live | converged, as live | ms/step, max ingest |
|---|---|---|---|---|---|---|---|
| clean-long | 19.42 (18.09–20.29) m | 19.19 m | yes | 100.0 → 100.0 % | PASS | 0.02 km | 0.069, 0.30 ms |
| clean | 12.98 (10.67–16.46) m | 13.59 m | yes | 100.0 → 100.0 % | PASS | 0.03 km | 0.068, 0.48 ms |
| manual | 50.50 (47.39–57.51) m | 53.66 m | yes | 100.0 → 100.0 % | PASS | 7.27 km | 0.073, 0.31 ms |
| jammed-A | 1.137 (1.012–1.259) % | 1.290 % | **no** | 100.0 → 100.0 % | PASS | 8.15 km | 0.075, 0.29 ms |
| jammed-B | 1.068 (0.940–1.374) % | 1.389 % | **no** | 100.0 → 100.0 % | PASS | 5.18 km | 0.069, 0.24 ms |
| drive-7 | 1.128 (1.073–1.231) % | 1.141 % | yes | 99.6 → 99.6 % | PASS | 0.60 km | 0.072, 0.25 ms |
| drive-8 | 1.482 (1.371–1.596) % | 1.422 % | yes | 100.0 → 100.0 % | PASS | 6.62 km | 0.072, 0.26 ms |
| drive-9 (1) | 10.212 (10.022–10.373) % | 10.050 % | yes | 75.0 → 75.0 % | not gated without roads | 3.37 km | 0.053, 0.25 ms |
| drive-9 (2) | 8.380 (8.278–8.513) % | 8.357 % | yes | 75.0 → 75.0 % | not gated without roads | 3.37 km | 0.051, 0.25 ms |
| manual-3 (sanity) | 232.03 (229.41–234.69) m | 230.52 m | yes | 66.7 → 66.7 % | not gated | 1.72 km | 0.075, 0.27 ms |

- **Every criterion passes as live**, with and without roads. With roads:
  clean-long 19.31 m and clean 16.17 m (≤ 30 m), manual's truth point
  6.92 m (≤ 200 m) and convergence 1.70 km (≤ 2 km), jammed-A and
  jammed-B 0.178 %, drive-7 0.151 %, drive-8 0.185 %, drive-9 0.067 % and
  0.077 % (≤ 2.5 %).
- **The attach point changed nothing.** On every run the live rule attaches
  both packs at the engine's first initialisation: after 2–20 inputs, at
  0.04–0.17 s. manual's attach comes after 11756 inputs, at 86.61 s, but
  that is its first initialisation too: the first fix the hold-out lets
  through arrives then. Before initialisation the engine has no particles, so the
  attach equals roads from the first input. Checked: `--file-order --seed
  header --roads` (roads from the start) gives byte-identical GeoJSON on all
  ten runs, after the mode label. Its `metrics.json` differs only in the
  attach fields and timing. Without roads, as live equals `--file-order
  --seed header` in the same way.
- **So the difference from N3.2 is the seed and the input order.** A
  single seed outside a five-seed range is not unusual: a sixth draw falls
  outside the range of five with probability 2/6. To separate the two,
  the same release build also ran file order with seeds 1–5 and arrival
  order with the header's seed. Rows where as live is outside the range:

  | drive | roads | arrival order, seeds 1–5 (N3.2) | file order, seeds 1–5 | arrival order, header seed | file order, header seed (as live) |
  |---|---|---|---|---|---|
  | drive-7 | yes | 0.130 (0.123–0.148) %; 96.3 % | 0.195 (0.149–0.285) %; 91.3 % | 0.255 %; 85.7 % | 0.151 %; 92.7 % |
  | drive-9 (1) | yes | 0.042 (0.033–0.051) % | 0.046 (0.039–0.055) % | 0.032 % | 0.067 % |
  | drive-9 (2) | yes | 0.043 (0.033–0.054) % | 0.044 (0.038–0.052) % | 0.034 % | 0.077 % |
  | jammed-A | no | 1.137 (1.012–1.259) % | 1.133 (1.003–1.272) % | 1.284 % | 1.290 % |
  | jammed-B | no | 1.068 (0.940–1.374) % | 1.076 (0.927–1.387) % | 1.383 % | 1.389 % |

  (drive-7 cells: gated value; consistency with the truth's σ. Every other
  cell's consistency is the same in all columns: 100 %.)
  - **drive-7 with roads:** its spread is wider than the five N3.2 seeds
    showed. Over twelve runs (N3.2's five, file order's five and the two
    header-seed runs) the worst
    withheld clean fix is 0.123–0.285 % and consistency 85.7–97.8 %, all
    under the 2.5 % criterion by more than 2 pp. As live, it has 253 of
    273 checkpoints inside, the same as N3.2's seed 4 (252) and inside its
    per-seed range (252–267). Its 20 misses are the known 706 s pin (210 m)
    and 19 clean fixes at 2068–2086 s: the service-road end that is the
    N3.2 decision's regression case. Its worst fix is 28.4 m at 1980 s
    (18.79 km). File order looks worse than arrival order on this drive
    (means 0.195 against 0.130 %, consistency 91.3 against 96.3 %). With
    five seeds each that is not shown to be systematic.
  - **drive-9 with roads:** 9.2 m and 10.6 m at the truth point (13.71 km),
    against 4.5–7.4 m on the N3.2 seeds. File order with seeds 1–5
    (0.038–0.055 %) and the header's seed in arrival order (0.032 and
    0.034 %) both stay close to the N3.2 range, so this is the draw of
    this seed with this order. The truth point's
    own σ is 40.4 m.
  - **jammed-A and jammed-B without roads:** the header's seed in arrival
    order gives nearly the same (1.284 and 1.383 %), so it is the seed, not
    the order.
- **A later attach** (the app selects asynchronously, see "Live in the app"):
  the same as-live runs with the roads attached after the first input
  arriving 1, 10 or 60 s after the first initialisation (a throwaway tool
  over `ReplayRoadAttach.afterInputs`; at 0 s it reproduces as live
  exactly). Gated value; consistency with the truth's σ:

  | drive | as live (attach at first initialisation) | + 1 s | + 10 s | + 60 s |
  |---|---|---|---|---|
  | clean-long | 19.31 m; 100 % | 19.26 m; 100 % | 19.29 m; 100 % | 19.32 m; 100 % |
  | clean | 16.17 m; 100 % | 16.17 m; 100 % | 16.17 m; 100 % | 10.65 m; 100 % |
  | manual | 6.92 m; 100 % | 6.92 m; 100 % | 6.92 m; 100 % | 6.92 m; 100 % |
  | jammed-A | 0.178 %; 100 % | 0.178 %; 100 % | 0.175 %; 100 % | 0.173 %; 100 % |
  | jammed-B | 0.178 %; 100 % | 0.178 %; 100 % | 0.178 %; 100 % | 0.209 %; 100 % |
  | drive-7 | 0.151 %; 92.7 % | 0.135 %; 93.0 % | 0.144 %; 92.3 % | 0.163 %; 92.3 % |
  | drive-8 | 0.185 %; 100 % | 0.185 %; 100 % | 0.185 %; 100 % | 0.184 %; 100 % |
  | drive-9 (1) | 0.067 %; 100 % | 0.067 %; 100 % | 0.067 %; 100 % | 0.067 %; 100 % |
  | drive-9 (2) | 0.077 %; 100 % | 0.077 %; 100 % | 0.077 %; 100 % | 0.077 %; 100 % |
  | manual-3 (sanity) | 68.26 m; 66.7 % | 68.26 m; 66.7 % | 68.26 m; 66.7 % | 67.42 m; 66.7 % |

  An attach up to a minute late stays within the seed spread above, or
  better (clean at + 60 s: 10.65 m), and changes no verdict.
- **Timing** (with roads, the as-live set run alone): 0.079–0.119 ms/step,
  as on N3.2's seed 1 (0.078–0.119), under the 0.15 ms target. The largest
  single ingest is 1.00–1.44 ms, except manual's 4.49 ms. Arrival order
  with seed 1 has it too (4.70 ms), so it does not come from the live
  attach.
- **Build check.** The same binary in arrival order, seed 1, with roads
  gives byte-identical GeoJSON to the N3-SLC baseline on all nine runs. Its
  `metrics.json` differs only in timing and in the pins' new
  `prior.onRoadShare` (sidecar v2, N3.3 item 2).

**Memory and verify time on the Mac** (N3.3 exit addition; M1 Pro, release,
warm file cache). A throwaway probe in logs/n33/tools, not committed,
measured `phys_footprint` and `resident_size` (`task_info`), heap in use
(`malloc_zone_statistics`) and `vmmap --summary`, before and after each
step:

| | national | region-A | both |
|---|---:|---:|---:|
| file size | 41.28 MB | 17.27 MB | 58.55 MB |
| shape points / edges / grid cells | 425,413 / 56,163 / 1,342,432 | 318,061 / 86,671 / 106,345 | |
| `COVR` ring points | 81,653 | 2,078 | 83,731 |
| open: memory-map and structure check | 0.4 ms | 0.3 ms | 0.6–1.3 ms |
| `RoadNetwork(packs:)` build | 1.4 ms | 0.8 ms | 2.0–4.0 ms |
| heap after the build (malloc in use) | +0.63 MB | +0.02 MB | +0.65 MB |
| `phys_footprint` after open and build | +0.70 MB | +0.06 MB | +0.73 MB |
| mapped, virtual / resident (vmmap "mapped file") | 39.5 / 4.0 MiB | 16.5 / 2.6 MiB | 55.9 / 6.6 MiB |
| full verify (`RoadPack(contentsOf:verify: true)`), median of 5 | 70.5 ms | 29.3 ms | |

- **What is copied to the heap (from the code).** `RoadPack` maps the file
  (`NSData`, `.alwaysMapped`) and reads every record in place. It keeps
  only the header fields, the section table (a few entries) and section
  offsets. `RoadNetwork` copies two things:
  - each pack's `COVR` rings into `[[RoadPoint]]`, 8 B per point: 0.67 MB
    for these two packs, almost all of it national's 81,653-point ring.
    That is the +0.65 MB measured.
  - each pack's bounding box (16 B).

  Computing the bounding box (`pointBounds()`) reads every shape point
  once, so after the build the `PNTS` sections are resident (6.6 MiB). They
  are clean file-backed pages that the system can drop, and they are not
  in `phys_footprint`. Everything else stays mapped and is paged in on
  demand.
- **In the app** the selection candidates (`RoadPackSelection.Candidate`)
  hold a second copy of the rings (`RoadPackCoverage`, measured +0.66 MB),
  so the rings cost about 1.3 MB with these packs.
- **While driving**, the engine's road state adds heap: the matcher's cell
  cache (at most 4096 cells of segments converted to the local plane), the
  per-update store and the per-particle road fields. At the end of
  drive-8 (as live, `--gps mask-after 785`) the engine held 4.94 MB with
  roads against 2.54 MB without; drive-7 (mask-after 1800): 4.47 against
  2.54 MB. These are the heap freed when the engine is released.
- **The phone's numbers stay open for D1** (memory from the Diagnostics
  Memory row) and D2 (verify time, the "verified in x s" row) in
  docs/PLAN.md §6. These Mac times use a warm file cache; a cold read was
  not measured.

**`convergedHeadingStdDeg` (N2-2): report only, no change.** The key and
the backlog status are unchanged.
- **What the key does.** `converged` is heading std <
  `convergedHeadingStdDeg` (10°). It sets only the estimate's flag, which
  drives the app's display ("calibrating heading", heading-up, the ellipse
  rule) and the replay's convergence distance. No engine state reads it.
  So every threshold can be evaluated exactly from a run's 1 Hz track
  (heading and heading std). Checked: at 10° the offline rule reproduces
  every run's `convergedT`.
- **Convergence distance by threshold** (the replay's rule: std under the
  threshold for 30 s; as live, km of OBD distance). clean and clean-long
  converge at 0.01–0.10 km at every threshold, with or without roads,
  from the GNSS courses they receive before the mask.

  | drive | roads 3° | 5° | **10°** | 15° | 20° | no roads 5° | **10°** | 15° |
  |---|---:|---:|---:|---:|---:|---:|---:|---:|
  | manual | 1.94 | 1.87 | **1.70** | 1.55 | 1.52 | 7.86 | **7.27** | 5.32 |
  | jammed-A | 0.98 | 0.94 | **0.84** | 0.73 | 0.69 | never | **8.15** | 6.29 |
  | jammed-B | 0.82 | 0.55 | **0.43** | 0.38 | 0.29 | never | **5.18** | 4.79 |
  | drive-7 | 0.46 | 0.28 | **0.14** | 0.14 | 0.14 | 2.68 | **0.60** | 0.60 |
  | drive-8 | 0.73 | 0.70 | **0.66** | 0.65 | 0.64 | 6.62 | **6.62** | 5.62 |
  | drive-9 (1), (2) | 2.87 | 2.84 | **2.51** | 2.45 | 2.43 | 3.37 | **3.37** | 3.37 |
  | manual-3 | 1.32 | 0.84 | **0.80** | 0.79 | 0.77 | 6.35 | **1.72** | 1.72 |

  N3.2's seeds 1–5 show the same pattern: with roads, each threshold's
  distance stays within about 0.2 km across seeds from 5° up, and within
  0.3 km at 3° except on manual (1.52–2.41 km).
- **With roads the std falls steeply.** It goes from 20° to 3° within
  0.1–0.6 km on every drive in the table. So 5° or 15° instead of 10°
  moves the convergence distance by at most 0.33 km (drive-9 at 5°) and
  0.15 km (manual at 15°). manual's ≤ 2 km criterion passes at 5°, 10°
  and 15°. Without roads the threshold matters: 15° would call convergence
  1.0–2.0 km earlier on manual, jammed-A and drive-8, and 5° never
  converges on jammed-A or jammed-B.
- **Heading against truth.** The truth is the withheld clean GNSS courses:
  accuracy ≤ 15 m, speed ≥ 5 m/s, courseAccuracy ≤ 10°. They exist on
  clean and clean-long after the mask, drive-7 after 1869 s and drive-8
  after 785 s.
  - With roads, as live: the std there is 0–5°. |error| has a median of
    0.4–0.9°, p95 1.3–2.2° and a maximum of 3.4°, and 96–100 % of errors
    are within 2 std. On N3.2's seeds clean has 82 % within 2 std at
    std < 2° (median 0.6°, maximum 2.8°).
  - Without roads: on drive-7 the std is 2–5°, the median error 2.4° and
    the maximum 4.6° (4.8° over N3.2's seeds). On drive-8 the std is
    0–10° (mostly 2–10°), the median 1.9–2.3° per std bin and the maximum
    5.0° (5.1°).
- **No truth at the moment `converged` first goes true.** With roads, no
  jammed drive has a heading truth there. jammed-A, jammed-B, manual,
  manual-3 and drive-9 have no clean course at all. drive-7's clean fixes
  begin 30 min after it converges. drive-8's first withheld course comes
  689 s after it converges, with an error of 1.6° at a std of 1.1°. clean
  and clean-long converge on the GNSS course they receive, not on roads.
  The evidence is indirect: a wrong converged heading could not leave
  manual's truth point 6.9 m off (converged at 1.70 km) or the jammed ends
  at 0.18 %.
- **Diagnostic, roads with no position after the start** (not an
  acceptance mode): clean with every fix after motion start withheld
  (`--gps mask-after-motion 0`), with roads, as live and seeds 1–5.
  - Heading std stays above 30° to the end and `converged` never goes
    true.
  - The mean heading is 179° off: the cloud runs both ways along the road
    and the estimate goes the wrong way (3.3–3.4 km at the end).
  - Roads alone do not give the direction of travel, and the std says so.
  - The same run on clean-long is not usable: its one pre-session fix is
    at speed and carries a course.
- **Reading, for the user's decision:** nothing here argues for changing
  10°. With roads any value from 5° to 15° gives about the same convergence
  distance, and the converged heading is accurate wherever truth exists.
  The threshold matters only without roads, where these runs add no
  heading truth at the moment of convergence.

Outputs, scripts and tables (git-ignored): logs/n33/ (`acc/` the replays,
`table.md`, `decomp.md`, `late.md`, `attach_info.txt`; `mem.txt`,
`mem-engine.txt`; `n22/` the N2-2 analysis and diagnostic runs; `tools/` the
probes; `bin/` the binary).

### Constant-offset GNSS check (2026-10-16): drive-10's CarPlay fixes

drive-10 (recorded 2026-10-16, in the git-ignored `logs/drives/`) has
149 clean fixes, all `accessory: true` (CarPlay) at an accuracy of exactly
10.0 m, 0–148 s. Then come 103 accessory fixes at 20–50 m (149–251 s:
the accuracy jumps to 25 m and grows by about 1.2 m/s, as if the source
were dead-reckoning), then phone fixes at ≥ 205 m. It has 7 pins: 1 at
58.5 s (moving), 2 at 211.4 s (stopped), the rest after the accessory
fixes end. The user's numpy check outside the repo reported a constant
offset of ~330 m at ~65°. Everything below is from `replay_nav
--fix-offset` with national + region-A (roadSetHash fecadb9b75a85f3b).
Outputs and the runner are in the git-ignored `logs/fixoffset/` (`run.sh`,
`<drive>-accessory.txt`, `<drive>-phone.txt`, `drive10-*.txt`).

**drive-10, clean fixes** (mean/p50/p90 in metres, capped at 100):

| window s | fixes | recorded mean/p50/p90 | rank | best shift | best mean | shifts p5 | runner-up (mean) | pin 1 vector 298 m @64° rank | pin 2 vector 326 m @70° rank |
|---|---|---|---|---|---|---|---|---|---|
| 0–148 | 148 | 56.3/46.9/100 | 84 % | 335 m @65° | 13.9 | 23.2 | 406 m @10° (15.7) | 0.70 % | 0.41 % |
| 0–50 | 50 | 45.1/39.6/99.8 | 87 % | 264 m @65° | 5.2 | 17.8 | 447 m @40° (12.9) | 2.8 % | 6.6 % |
| 50–88 | 38 | 39.3/36.4/74.0 | 56 % | 394 m @21° | 5.6 | 12.6 | 436 m @53° (6.7) | 9.9 % | 2.0 % |
| 88–140 (lake) | 52 | 82.9/100/100 | 82 % | 413 m @7° | 6.9 | 18.9 | 344 m @64° (9.7) | 9.1 % | 12.9 % |
| 140–148 | 8 | 34.0/12.2/100 | 31 % | 409 m @40° | 1.1 | 10.5 | 149 m @290° (1.6) | 22 % | 1.3 % |
| 148–181 (≤ 50 m fixes) | 33 | 20.3/15.8/31.9 | 34 % | 306 m @281° | 2.5 | 6.9 | 469 m @214° (2.6) | 9.9 % | 11 % |
| 180–251 stop (≤ 50 m fixes) | 71 | 12.7 (one point) | 32 % | any | 0.0 | 1.6 | any (0.0) | 33 % | 15 % |

- **The track as recorded is off the roads.** It sits at 46.9 m median
  (98–100 m over 88–140 s), and 84 % of all shifts within ±400 m lay it
  closer to roads than it is. In every other drive, every window where the
  car is on a mapped road is at most 14.2 m (mean) from roads, and 10.7 m
  outside clean's car park (below).
- **The best shift is ~335 m at ~65°** over the whole 0–148 s, with and
  without the course gate (`--fix-offset-course off`: 335 m @65°, mean
  8.2 m). 60 s sliding windows from 61 to 148 s give 328–335 m at 64–69°.
- **Road fit alone does not single the shift out.** The runner-up
  (406 m @10°) scores 15.7 against 13.9. In 30–60 s windows the best
  shift wanders (264 m @65°, 394 m @21°, 413 m @7°, even 336 m @282°
  over 31–90 s) because a few hundred metres of track fit many places in
  a street grid. The user's "5 m after the shift, p90 17 m against a
  5th-percentile shift of 30 m" was not reproduced as a clean
  separation: here p5 is 23.2 m (14.2 m without the course gate).
- **The pins identify it.** They are independent of the fixes, and each
  pin's vector from the time-nearest fix (+0.4 s and +0.5 s) is 298 m
  @64° and 326 m @70°. Those vectors are 43 m apart, inside the pins'
  30 m σ each, and lie 40 m and 30 m from the best shift. Scored on the
  0–148 s track they rank 0.70 % and 0.41 % among the 6561 grid shifts.
  Two independent pins falling in the best ~0.5 % of the shift plane, on
  a track that ranks 84 % unshifted, is the evidence for a constant
  offset. It is not the road fit on its own.
- **The dynamics are genuine** (explicit windows, every 30 s from 0 to
  181 s). Fix path against OBD distance is +2.2 to +4.6 % per window, the
  same +2–4 % as genuine drives (the OBD scale, `scalePriorMean` 1.016).
  The median |GNSS − OBD speed| is 0.5–1.3 km/h. The net course change
  equals gyro yaw within 2°: 42/42, −57/−58, 6/6, 210/210, −60/−62 and
  6/6°. A shifted copy of the true track is what a spoofer, or a source
  with a shifted position, produces.
- **When it starts and ends.** It starts at or before the first fix
  (−0.1 s): no window is on roads and there is no jump, so the shift was
  already there when the recording began. While moving at 10 m
  accuracy it lasts to 148 s. At 148.9–181 s (20–48 m fixes) the track
  is still off roads (34 %) but too short to identify a vector. The stop
  at 180–251 s is one point, which no road test can place; pin 2
  (211.4 s, 326 m @70°) says the offset was still there. After 251 s
  there are no accessory fixes, and the phone fixes (≥ 205 m) cannot show
  a 330 m offset. Its end is unknown.

**Every other drive** (60 s windows every 30 s; recordings without clean
fixes: the 2026-10-08 16:48 drive, jammed-A, jammed-B, manual and manual-3
have none, drive-9 has one):

| drive | source | windows | on roads | recorded mean (on-road windows) | rank | off-road windows |
|---|---|---|---|---|---|---|
| clean | accessory | 8 | 4 | 2.0–3.1 m | 0 % | 322–445 s (below) |
| clean | phone | 4 | 2 | 5.6–14.2 m | 6–9 % | 66–119 s (below) |
| clean-long | accessory | 21 | 21 | 0.2–7.8 m | 0–15 % | none |
| clean-long | phone | 3 | 3 | 3.2–5.9 m | 0–1 % | none |
| drive-7 | accessory | 8 | 8 | 1.1–7.5 m | 0–23 % | none |
| drive-7 | phone | 5 | 5 | 3.6–4.9 m | 0–4 % | none |
| drive-8 | accessory | 44 | 44 | 0.6–10.7 m | 0–8 % | none |
| drive-8 | phone | 3 | 3 | 5.9–7.2 m | 8–11 % | none |
| drive-10 | accessory | 5 | 0 | — | — | all (43.5–75.5 m, 51–91 %) |

The phone-GNSS rows are the control: the phone's own clean fixes are on
the roads wherever the car is on a mapped road, and so are the
accessory fixes of every earlier drive. The off-road thresholds (15 m,
20 %) were set after seeing these numbers, just above their maxima.
The mean reaches 14.2 m once (clean, phone, 36–95 s, slow, leaving the
car park), so 15 m has little margin. The rank alone reaches 23 % on a
short stationary window (drive-7, 6 fixes), which is why the gate needs
both.

- **clean, 322–445 s (accessory), likely unmapped, not proven.** The
  fixes are on roads to 359 s (0.6–2 m). The car then slows from 14 to
  3 m/s, and the distance grows smoothly 9 → 100 m over 20 s as it drives
  away and parks (410–445 s at 0 m/s). There is no jump. The dynamics
  match: 355–385 s path 161 m against OBD 155 m (+4.0 %), course change
  179° against gyro 178°. A drag-off of ~100 m over that path would show
  about +19 % and a course/gyro mismatch. The best shift per window is
  inconsistent (323 m @171°, 382 m @215°, 275 m @147°, 375 m @99°). The
  packs include `service`, so the car stopped more than 100 m from any
  mapped way.
- **clean, 66–119 s (phone), unmapped manoeuvring.** At 0–10 m/s the
  distances jump between 0 and 100 m fix to fix, and the best shift is
  not unique. Again no constant vector.

**Answers.**

1. **drive-10's pins 1 and 2 should be scored, and the CarPlay fixes
   0–251 s are the wrong truth there.** The pins agree with each other
   and with the roads, and the fixes agree with neither. Any replay mode
   is affected today. With `--gps use` the engine follows the fixes: at
   pin 1 its prior is 298 m off with a 4 × 4 m 95 % ellipse, at pin 2
   327 m off with 5 × 5 m (3 pin resets, 0 fixes rejected off-road). That
   is the engine's real behaviour and the right thing to score. Any mask
   mode would instead score the withheld CarPlay fixes as clean-fix
   truth. The truth file has no way to exclude fixes, so a drive-10
   acceptance run needs one (BACKLOG N3-FIXPIN) before it can be defined.
   No truth entry was written.
2. **No acceptance drive's clean-fix truth shows this offset.** clean-long,
   drive-7 (from 1870 s) and drive-8 (664–1988 s) are on roads in every
   window, accessory and phone. clean's withheld fixes after 230 s include
   the 362–445 s stretch, which is off the mapped roads but moves with the
   car (above): likely unmapped, not proven. drive-9's truth is a network
   fix and the other truth-file drives have no clean fixes, so this check
   does not apply to them.
3. **What the check cannot see:** an offset below ~15 m mean; one that
   lays the track onto an equally road-like place, e.g. along a straight
   road, or a whole block in a regular grid (the runner-ups above show
   how close that comes); and any offset while stationary. On its own a
   60 s window identifies the vector only sometimes. A long window, or a
   vector from an independent pin, is what pins it down.

### N4B1-1: OBD zero against moving fixes (2026-10-18)

**`zuptFixGate` is on by default.** It passes the adoption rule against the
current default (the N3.2 decision's config, the "N3.2 decision" and "N3.3:
roads live" baselines) with every gated value unchanged, because on the
acceptance set it never fires.

- **The case.** Backlog N4B1-1: in the simulator `SimulatedOBDLink` answers
  0 km/h on every poll while the simulated motion and fixes drive at
  50 km/h. The engine trusted the fresh 0 (896 of 900 steps were ZUPT, no
  course or speed update), so the dot sat at the mean of the fixes, 519 m
  behind at 90 s, with a 1.3 m ellipse. More generally: OBD stuck at 0
  while GNSS moves gave an overconfident frozen estimate.
- **The rule** (pre-declared, not swept; "Model", "Predict"): a step an OBD 0
  would freeze is vetoed while ≥ 2 good fixes in a row, each taken after
  the run of zeros began, read ≥ 5 m/s and the newest is ≤ 3 s old. Causal
  (only fixes already ingested count) and deterministic (no random draw;
  the evidence is a few integers and one speed). "After the zeros began" is
  what keeps real stops: a fix measured while the car was still braking
  (GNSS Doppler lags) predates the first 0 and does not count, and fixes
  after it read under 5 m/s at a stop. 5 m/s is above the few m/s of
  parked GNSS speed noise the course veto exists for; 2 fixes keep one
  glitch fix or one OBD 0 glitch at speed from deciding.
- **Runs.** Release build of the change on the Mac, every acceptance run
  with its acceptance flags, seeds 1–5 in arrival order, with roads
  (national + region-A) and without: `--set zuptFixGate=0` (the current
  default's behaviour) against `--set zuptFixGate=1`, 100 runs each.
  Outputs: logs/out-sweep-nav2/acc/ (git-ignored).
- **Result: identical.** All 100 GeoJSON pairs are byte-identical; the gate
  vetoed 0 steps in every run (`zuptVetoedSteps`). `metrics.json` differs
  only in the config's `zuptFixGate` and the timing fields. The gate-off
  means equal the N3.2 decision's and N3.3's N3.2 columns to the last digit
  shown, so the baseline is the current default's.

Means over seeds 1–5 (range); gated value as in "N3.2 decision" (metres for
clean-long, clean and manual's truth point 1, % of distance for the rest);
consistency with the truth's σ. The off and on columns are the same runs'
values, so one column each.

| drive | with roads, off = on | Δ | consistency + σ | without roads, off = on | Δ | consistency + σ | verdict |
|---|---|---:|---|---|---:|---|---|
| clean-long | 19.38 (19.22–19.50) m | 0 | 100.0 % | 19.42 (18.09–20.29) m | 0 | 100.0 % | PASS |
| clean | 14.39 (11.81–18.82) m | 0 | 100.0 % | 12.98 (10.67–16.46) m | 0 | 100.0 % | PASS |
| manual | 7.23 (5.81–10.02) m | 0 | 100.0 % | 50.50 (47.39–57.51) m | 0 | 100.0 % | PASS |
| jammed-A | 0.177 (0.170–0.182) % | 0 | 100.0 % | 1.137 (1.012–1.259) % | 0 | 100.0 % | PASS |
| jammed-B | 0.201 (0.171–0.245) % | 0 | 100.0 % | 1.068 (0.940–1.374) % | 0 | 100.0 % | PASS |
| drive-7 | 0.130 (0.123–0.148) % | 0 | 96.3 % | 1.128 (1.073–1.231) % | 0 | 99.6 % | PASS (consistency unchanged; the N3.2 decision's accepted 96.3 %) |
| drive-8 | 0.186 (0.184–0.188) % | 0 | 100.0 % | 1.482 (1.371–1.596) % | 0 | 100.0 % | PASS |
| drive-9 (1) | 0.042 (0.033–0.051) % | 0 | 100.0 % | 10.212 (10.022–10.373) % | 0 | 75.0 % | PASS |
| drive-9 (2) | 0.043 (0.033–0.054) % | 0 | 100.0 % | 8.380 (8.278–8.513) % | 0 | 75.0 % | PASS |

- **Why it never fires, and the margin.** Over each whole recording (every
  fix, masked or not), the good fixes whose `t` is after a run of OBD
  zeros began, by arrival order (a throwaway script,
  logs/out-sweep-nav2/margin.py):

  | drive | good fixes after a 0 began | max Doppler | longest run ≥ 2 / 3 / 4 / 5 m/s |
  |---|---:|---:|---|
  | clean-long | 125 | 0.62 m/s | 0 / 0 / 0 / 0 |
  | clean | 82 | 4.00 m/s | 4 / 2 / 1 / 0 |
  | drive-7 | 5 | 0.62 m/s | 0 / 0 / 0 / 0 |
  | drive-8 | 283 | 1.53 m/s | 0 / 0 / 0 / 0 |
  | drive-10 (report only) | 7 | 0.62 m/s | 0 / 0 / 0 / 0 |
  | manual, manual-3, jammed-A, jammed-B, drive-9, drive-11 | 0 | | |

  The jammed drives, manual, manual-3 and drive-9 have no good fix (network
  fixes carry no Doppler speed). clean is the closest: parked before motion
  start and at its stops (26–29 s, 80–92 s) GNSS reads 2.6–4.0 m/s with
  4–8 m accuracy while OBD says 0. That is the parked speed noise the 5 m/s
  threshold is above. A looser diagnostic (1 fix at ≥ 2 m/s, not a
  candidate; seed 1, no roads) fires there for 87 steps and moves clean's
  max error from 12.24 to 17.10 m: the noise is real and a looser gate
  would cost. The acceptance set cannot show the gate's benefit; it shows
  that at 5 m/s × 2 it costs nothing.
- **Where it acts** (not an acceptance drive): the simulator recording of
  backlog N4B1-1 (90 s, `--gps use --file-order --seed header`, logs/out-sweep-nav2/sim/).
  Off: 896 ZUPT steps, 0 course updates, the estimate 203–210 m from the
  fixes at 30 s, 386–391 m at 60 s, 523 m at the end. On: 880 steps vetoed,
  16 ZUPT (before the evidence), 88 course updates, 0.1–0.5 m from the fixes
  after 10 s. These are the fixes the engine received, so this is
  consistency with them, not error against independent truth.
- **Tests** (`NavigationZeroFixGateTests`): OBD stuck at 0 with moving clean
  fixes (vetoed, follows the drive; off: frozen > 300 m behind); a real stop
  with 1 s GNSS Doppler lag (never vetoed, estimates equal to gate off); the
  evidence rules (one fix, network and coarse fixes, the speed threshold,
  fixes measured before the zeros); resets; expiry after
  `zuptFixGateMaxAgeS`; a parked stale 0; catch-up while vetoed equals
  stepping one by one; the keys' defaults, decoding and refusals.
- **Live.** The sidecar header's config, and so its `configHash`, gains the
  four keys: `--as-live --compare` on an older sidecar names them as config
  differences (not road-only, so not inert). Live estimates are unchanged
  wherever the gate does not fire, which on this car's drives is
  everywhere measured. To verify on the device: see "To verify on the
  device (N4)".

### N2-3: magnetometer heading prior (2026-10-18)

**Measured, not adopted: it fails the adoption rule on 4 of the 18 gated
cells.** The experiment code is not merged (no engine change without
passing the adoption rule). It is kept on the unmerged branch `exp-mag`
(commit 10f84ee): key `magHeading`, default 0, bit-identical when off,
replay only (the live tap does not deliver `mag` rows).

- **Input.** `motion.magneticField` is absent on every sample of the
  acceptance drives: they record `xArbitraryZVertical`, and
  `magneticAccuracy` is −1 throughout. Only the raw `mag` rows (10 Hz,
  device frame, uncalibrated) remain. Their magnitude is 510–670 µT, about
  ten times the Earth's field: that is the magnetic mount. The offset
  differs between drives (whole-drive fit |b| 532 and 606 µT on drive-10
  and drive-11).
- **Plumbing.** On `exp-mag`: a new input, `NavigationInput.magnetometer`.
  Only the replay creates it: `NavigationReplay.inputs(from:magnetometer:)`,
  and `replay_nav` adds the rows when `--set magHeading=1`. The live tap
  (`LogFile.isTapped`, the logger's) passes only motion, location, OBD and
  manual fixes. Live use would need a logger change.
- **Method** (as implemented on `exp-mag`). Causal and deterministic; the
  learner draws no random numbers.
  - **Hard iron** (`MagnetometerCalibration`). Recursive least squares on
    R m = R b + e, where R is CoreMotion's attitude (device to reference
    frame), b the offset in the device frame and e the Earth's field in
    the reference frame.
    - It forgets over 600 s of learning time.
    - It learns only while fresh OBD speed is above 0, because a parked
      phone may be handled.
    - It is ready when the heading axis has pointed into at least 5 of 8
      azimuth sectors, the north angle's σ is at most 2° and the
      horizontal field is 5–60 µT.
    - Without tilt, the vertical part of b and the vertical field are not
      separable; the heading uses the horizontal part.
  - **Compass.** The heading of the most horizontal device axis,
    clockwise from magnetic north. A sample is dropped when its residual
    exceeds half the horizontal field. The 1 s circular mean is taken
    against the gyro yaw integrated to each sample, so a turn adds no lag.
  - **Mount offset, learned per particle.** Each particle has its own
    offset (its heading minus the compass heading) in a Kalman filter with
    one shared variance P.
    - The first update after an initialisation sets the offsets and
      changes no weight.
    - Each later update weights by N(ν; 0, P + R), with R = σ² ×
      max(1, τ / Δt), and P grows by q² Δt.
    - So the compass constrains heading *changes* against the gyro, never
      the absolute heading.
    - Offsets are copied by resampling and turned by re-anchoring. A
      reseeded particle takes the offset its new heading implies.
- **Parameters, fixed before any acceptance replay.** Chosen on drive-10
  and drive-11, which are not acceptance drives, with an offline script
  run on those two drives only (logs/out-exp-mag/tools/).
  - σ = 5°: the std of 1 s means of compass minus gyro yaw is 4.6° and
    5.0°.
  - τ = 60 s: the autocorrelation of that difference is 0.7 at 1 s,
    0.35–0.40 at 10 s and 0.05–0.26 at 30–120 s. Its change over 300 s is
    about its change over 60 s, so it is stationary, not drifting. 60 s is
    also `networkFixCorrelationS`.
  - q = 0.05°/√s, the gyro's own time noise.
  - Forgetting 600 s, and the readiness and gate constants above. The
    3 µT noise scale comes from the whole-drive residual median of
    2.3–2.7 µT.
  - On those drives the learner was ready at 55 and 106 s. Against
    drive-10's CarPlay courses the causal compass is within 4.1° (median)
    and 9.8° (p90).
- **Runs.** Release build on the Mac, every acceptance run with its
  acceptance flags, seeds 1–5, arrival order, with roads (national +
  region-A) and without, on the `exp-mag` build. The key off (nothing set,
  its default) against `--set magHeading=1`: 200 runs. Outputs: logs/out-exp-mag/acc/
  (git-ignored).
- **Off is the baseline, exactly.** All 100 off GeoJSONs are
  byte-identical to the N4B1-1 runs (logs/out-sweep-nav2/acc/on).
  `metrics.json` differs only in the five config keys and the two
  counters (0) that `exp-mag` adds, and timing. The baseline columns therefore equal "N3.2
  decision" and "N4B1-1".

Means over seeds 1–5 (range). Gated value as in "N3.2 decision" (metres for
clean-long, clean and manual's truth point 1; % of distance for the rest);
consistency with the truth's σ.

With roads:

| drive | off | on | Δ mean (allowed) | consistency + σ off → on | criterion, on | verdict |
|---|---|---|---|---|---|---|
| clean-long | 19.38 (19.22–19.50) m | 19.38 (19.23–19.49) m | +0.00 (≤ +2.00) | 100.0 → 100.0 % | pass | PASS |
| clean | 14.39 (11.81–18.82) m | 10.37 (7.24–12.64) m | −4.02 (≤ +2.00) | 100.0 → 100.0 % | pass | PASS |
| manual | 7.23 (5.81–10.02) m | 8.92 (5.95–16.54) m | +1.69 (≤ +2.00) | 100.0 → 100.0 % | pass | PASS |
| jammed-A | 0.177 (0.170–0.182) % | 0.187 (0.179–0.192) % | +0.010 (≤ +0.1) | 100.0 → 100.0 % | pass | PASS |
| jammed-B | 0.201 (0.171–0.245) % | 0.185 (0.156–0.231) % | −0.016 (≤ +0.1) | 100.0 → 100.0 % | pass | PASS |
| drive-7 | 0.130 (0.123–0.148) % | 0.173 (0.121–0.246) % | +0.043 (≤ +0.1) | 96.3 → 92.1 % | pass | **FAIL** (consistency) |
| drive-8 | 0.186 (0.184–0.188) % | 0.184 (0.182–0.186) % | −0.002 (≤ +0.1) | 100.0 → 100.0 % | pass | PASS |
| drive-9 (1) | 0.042 (0.033–0.051) % | 0.043 (0.035–0.057) % | +0.001 (≤ +0.1) | 100.0 → 100.0 % | pass | PASS |
| drive-9 (2) | 0.043 (0.033–0.054) % | 0.044 (0.035–0.056) % | +0.001 (≤ +0.1) | 100.0 → 100.0 % | pass | PASS |
| manual-3 (sanity) | 97.30 (93.91–102.32) m | 97.17 (92.32–101.80) m | −0.13 | 66.7 → 66.7 % | not gated | not gated |

Without roads:

| drive | off | on | Δ mean (allowed) | consistency + σ off → on | criterion, on | verdict |
|---|---|---|---|---|---|---|
| clean-long | 19.42 (18.09–20.29) m | 19.65 (18.36–20.45) m | +0.23 (≤ +2.00) | 100.0 → 100.0 % | pass | PASS |
| clean | 12.98 (10.67–16.46) m | 18.59 (8.45–33.53) m | +5.60 (≤ +2.00) | 100.0 → 100.0 % | **seed 1 33.53 m > 30 m** | **FAIL** (value, criterion) |
| manual | 50.50 (47.39–57.51) m | 48.34 (44.53–55.58) m | −2.16 (≤ +2.52) | 100.0 → 100.0 % | pass | PASS |
| jammed-A | 1.137 (1.012–1.259) % | 1.413 (1.159–1.587) % | +0.277 (≤ +0.1) | 100.0 → 100.0 % | pass | **FAIL** (value) |
| jammed-B | 1.068 (0.940–1.374) % | 1.046 (0.824–1.498) % | −0.022 (≤ +0.1) | 100.0 → 100.0 % | pass | PASS |
| drive-7 | 1.128 (1.073–1.231) % | 0.849 (0.823–0.873) % | −0.279 (≤ +0.1) | 99.6 → 99.6 % | pass | PASS |
| drive-8 | 1.482 (1.371–1.596) % | 1.866 (1.834–1.946) % | +0.385 (≤ +0.1) | 100.0 → 100.0 % | pass | **FAIL** (value) |
| drive-9 (1) | 10.212 (10.022–10.373) % | 2.112 (1.907–2.337) % | −8.100 (≤ +0.1) | 75.0 → 100.0 % | not gated without roads | PASS |
| drive-9 (2) | 8.380 (8.278–8.513) % | 2.330 (2.144–2.556) % | −6.050 (≤ +0.1) | 75.0 → 100.0 % | not gated without roads | PASS |
| manual-3 (sanity) | 462.39 (456.91–470.88) m | 431.45 (418.11–452.22) m | −30.94 | 66.7 → 66.7 % | not gated | not gated |

- **The failures.**
  - Without roads: clean is +5.60 m, and seed 1 reaches 33.53 m against
    12.24 m off, failing the 30 m criterion. jammed-A is +0.277 pp and
    drive-8 +0.385 pp; every on seed of drive-8 (1.83–1.95 %) is above
    every off seed (1.37–1.60 %).
  - With roads: drive-7's consistency drops from 96.3 to 92.1 %. Per
    seed, 267 / 252 / 249 / 236 / 253 of 273 checkpoints are inside,
    against 266 / 265 / 267 / 252 / 265 off.
- **The gains.**
  - Without roads: drive-9 goes from 10.2 to 2.1 % and from 8.4 to 2.3 %,
    under the 2.5 % threshold the roads-on runs are gated by, and its
    consistency rises from 75 to 100 %. drive-7 goes from 1.13 to 0.85 %,
    manual improves by 2.2 m and manual-3 (not gated) by 31 m.
  - With roads: clean improves by 4.0 m.
- **Why it is mixed** (offline, after the runs; it explains the result and
  set nothing). The compass error depends on the heading: soft iron in
  the car body and the mount. Withheld clean courses minus the causal
  compass, as a mean per 45° course bin:
  - drive-8: from +3.9° to −8.8°, 13° peak to peak (866 courses), while
    the mean over the stretch before its mask and the mean after differ
    by only 1.7°;
  - clean: from −6.5° to +9.5°, most bins with 3–8 courses; its fit
    residual median is 5.2 µT, against 2.4–2.8 µT on drive-7, drive-8,
    drive-10 and drive-11;
  - drive-7 after 1869 s: within ±3°.

  Each particle's offset is an average over the headings driven so far.
  On a leg in another direction the compass then pulls heading by the
  difference in deviation, a few degrees for km of dead reckoning, more
  than the gyro error it corrects (1–1.5 % of the angle turned). The
  compass wins where the deviation over the dead-reckoned leg is small
  (drive-7) or the gyro's error is larger. drive-9 is likely the second
  case, not proven: like jammed-A, it has no clean course to show the
  deviation.
- **Not tried** (each needs its own pre-declared run): learning the
  deviation as a function of heading (a two-harmonic curve per drive,
  causal), soft iron in the fit, or a per-vehicle mount-offset prior.
  Seen across drives, the offset would need the same reference axis and
  a stable mount.
- **Timing.** On the Mac, +0.002 to +0.008 ms per step (seed 1), with
  the learner running at 10 Hz and the update at 1 Hz.
- **Code** (on `exp-mag`, commit 10f84ee, not on main; kept for the
  follow-up of learning the compass error as a function of heading;
  `magHeading` and four parameters).
  - Files: `MagnetometerCalibration.swift` and the engine's "Magnetometer
    heading" section.
  - Tests: `NavigationMagHeadingTests`. The learner converges on a
    synthetic hard-iron field, needs turns, gates disturbances and
    ignores degenerate input. With the key off, `mag` rows change
    nothing. There is no look-ahead (garbage rows after t leave the
    estimate at t unchanged), runs are deterministic, the particle
    offsets learn the mount offset, and the compass bounds a 1 % gyro
    scale error. The config keys are tested too.
  - The cost when off, had it been merged: the sidecar header's config, and
    so its `configHash`, gains the five keys. `--as-live --compare` on an older
    sidecar names them as config differences.

## Known limitations and options

- **Heading convergence with tower fixes only** (manual: 6.8 km against a
  2 km target). Before the pin, and between the pin and the end, heading
  information comes only from minutes-correlated, roughly 1 km tower fixes.
  The honest heading std drops under 10° only after several km. Options: a
  second manual fix a few hundred metres after the first (two pins fix
  heading); road matching (N3); a magnetometer heading with a learned mount
  offset (measured in N2-3 and not adopted: it constrains heading changes, not
  the initial heading, and its heading-dependent error costs elsewhere);
  trusting towers more (`networkFixCorrelationS` 30 → 5.1 km; not the default,
  see "Tried and rejected").
  ("Tried and rejected" and the measurements cited in this section: [docs/archive/NAVIGATION-history.md](archive/NAVIGATION-history.md).)
- **Reversing** (backlog N2-1, closed 2026-10-17: known limitation): OBD speed
  has no sign and mode 01 has no gear signal, so reversing is integrated as
  driving forward at the OBD speed. Regression case:
  `--gps mask-after-motion 30` on the clean drive (324 m today). Ideas
  considered, not planned: reverse from the sign of longitudinal acceleration
  against d(speed)/dt, or a reverse hypothesis per particle at low speed after
  a stop.
- **Wide heading posterior → shrunken mean**: while heading std is large, the
  mean of the arc-shaped cloud lies inside the arc, shortening the
  start-to-estimate distance by about exp(−σ²/2). On jammed-B this was most of
  the error before face-value fix σ.
- **Network fixes with small claimed accuracy** (Wi-Fi, 24–60 m) are tempered
  since N2.1 but still taken at their claimed σ. On manual-3 they, together
  with a stale initialising fix, still make heading converge too early, and
  0/3 pins fall inside the ellipse. Options measured above:
  `networkFixInflation` 1.5 or 2.
- **Scale learning from GNSS speed** is fragile when GNSS speed disagrees with
  OBD (clean drive before 230 s). The tight per-vehicle prior (± 0.01) holds
  it; a new car needs its prior measured, or a wider std.

- **A fix with a small claimed accuracy outweighs a pin** (drive-10,
  2026-10-16; BACKLOG N3-FIXPIN). CarPlay fixes ~330 m off at a claimed
  10 m keep the estimate on them through pins 1 and 2 (298 and 327 m
  error, 95 % ellipses of 4–5 m). The engine checks neither whether a
  run of fixes is road-consistent nor whether fixes agree with a pin.
  See "Constant-offset GNSS check".
- **Capture by a parallel mapped road** (N3.2, roads only; known FAIL,
  measured 2026-10-13). A car on a road missing from the pack, 40 m from a
  mapped parallel road, is captured onto the mapped road with a confident
  ellipse (N3.2 test 3, `NavigationRoadOffRoadTests`, run as a known issue).
  The candidates measured and the option not yet measured are in
  [docs/N3_ROAD_OFFROAD.md](N3_ROAD_OFFROAD.md). The wrong-road share on
  clean and clean-long (N3.2b) checks capture onto a wrong *mapped* road
  only; capture while the car is on an unmapped road is the separate
  unmapped/captured count (R21.1-11).

## To verify on the device (N4)

- drive-7 (2026-10-12) was recorded with a **Debug** build, so its sidecar's
  `msPerStep` (median 2.8 ms) and `maxStepMs` (45 ms) say nothing about
  Release performance on the phone. The ≤ 2 ms check needs a Release drive.

- ≤ 2 ms per 10 Hz step with 2000 particles on an iPhone. The Mac release
  replay gives 0.06–0.08 ms/step on the acceptance set (N3.0 baseline;
  0.05–0.06 at N2.1 before later features). The largest single ingest is
  0.2–1.5 ms, with one 4.5 ms outlier (`logs/r144`, N3 plan). Earlier
  tables in this document give the figures of their own time.
- Arrival order in the live app: CoreMotion batches can arrive late; the engine
  accumulates late yaw into the next step, but this is untested on hardware.
- `estimate(at:)` extrapolation between steps at UI rates: the first frame
  after a resume holds at the 2 s horizon with a grown ellipse (R13.1-5),
  with no jump.
- Catch-up after the app was suspended (R13.1-6): the time of the first
  `ingest` after a long silence, with 2000 particles. On the Mac a 600 s
  silence costs at most about 20 single steps plus 100 macro steps.
- Behaviour across an OBD dropout while driving (stale-speed growth) and after
  ignition off at the end of a drive.
- N4 B, live: ms/step with 2000 particles on the iPhone (overlay and the
  sidecar's `msPerStep`/`maxStepMs`); the time of the first ingest after a
  long suspension; at Start, how long after the pre-session fix the first
  OBD speed reply comes (it must stay well inside `heldFixTimeoutS` 5 s;
  the sidecar's first estimate should be within a second or two of Start
  when the adapter is already connected); and whether `replay_nav --as-live --compare` on a phone's
  sidecar is exact on an arm64 Mac (R13.1-7). If not, it must pass within the
  default tolerance with no unexplained cause.
- N4B1-1 (`zuptFixGate` on): on a real drive `zuptVetoedSteps` stays 0 at
  every stop (replay the drive; the sidecar cannot show it), and in the
  simulator with `SimulatedOBDLink` (OBD 0 at 50 km/h) the dot follows the
  green GNSS track after the first 2–3 s instead of freezing.
- R14.1-4: background the app mid-recording, then kill it from the app
  switcher; `--as-live --compare` of that recording shows estimates up to
  about the moment it went to the background, and any replay-only tail as
  "the sidecar ends early", not "no known cause".
