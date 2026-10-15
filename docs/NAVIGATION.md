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
every result. The table lists the keys without roads; the 18 road keys
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
  [--roads <pack.roadpack>]... [--wrong-road-tolerance <m>]
```

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
- **Roads** (N3.2b; replay only, refused with `--compare` and
  `--write-sidecar`): `--roads` (repeatable, each pack fully verified) gives
  the engine `NavigationEngine(config:roads:)`. **Pack order does not matter**
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
  `--roads`, every output is byte-identical to N3.0.
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
  gets `-as-live`.
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
  config-hash mismatch is a warning. Format and verdicts:
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
  last checkpoint), heading-convergence distance (first time `converged` then
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
- measures engine time per 10 Hz step with `ContinuousClock` (EMA and
  maximum);
- answers `snapshot(at:)` with a `NavigationSnapshot` (estimate, ellipse,
  heading, `converged`, `initialized`, ms/step, ESS, heading std, speed scale,
  `droppedInputs`) on the recording's session clock.

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
    travelled at its time (∫ OBD speed from the start, as for jammed-A/B). Rule: drive-7 is a
    jammed drive, so it takes the jammed drives' existing threshold
    unchanged, set in N2 before drive-7 existed; nothing about the
    threshold was chosen from this drive's numbers. It applies to the worst
    withheld clean fix rather than only the last one, because the drive has
    266 truth points, not one end. The baseline (1.08–1.23 %) passes with a
    wide margin, so the criterion only catches a gross regression; the
    adoption rule (mean worse by at most 0.1 pp) is the tighter check. For
    that rule drive-7 is a drive scored in % of distance.
  - **Reported, not gated:** the max error in metres, the error as a share
    of the distance since the last pin, the consistency over the clean fixes
    and over the 7 scored pins. The pins are not gated because two were
    likely placed wrong and the truth for the rest is a finger on a map.
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
    speed from the start, as for drive-7). Rule: drive-8 takes the jammed
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
  14.2 km, iPhone 16 Pro Max, the first **Release** build drive. GNSS is jammed for the
  whole drive: 170 of 171 fixes are speedless network fixes (speed −1), and
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
- Without roads the error over the dead-reckoned distance is 2.35–2.74 %,
  above 2.5 % on seeds 3 and 5. Reported, not gated, like drive-7's "since the
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

### N3.0 step 1: scoring rule (2026-10-12): refinement pairs and truth pin exclusion

**This changes scoring only, not the engine.** The engine and its config are
untouched, and it ingests every pin as before. The changes: refinement pins
(within `--pin-pair-window`, default 3 s, of the previous pin) are not
scored (they stay in `checkpoints`, marked `notScored`), and the truth file
can exclude pins (`excludePins`).
See "replay_nav" above for the exact rule.

Re-scored with one build: the six acceptance runs plus drive-7 (`--gps use`,
informational), seeds 1–5, arrival order, release, default config. "Old" is
`--pin-pair-window 0`. "New" is the default (3 s). "New + excl." adds the
drive-7 `excludePins` for its pins at t ≈ 599 s and ≈ 626 s, which the user
decided to exclude: they are likely, not proven, about 200 m off. Values are
mean (range) over seeds. Consistency is all scored checkpoints [manualFix
kind].

| alias | run | manual fixes | scored old → new (refinements, excluded) | consistency old | consistency new | max error old → new | end error old → new | criterion |
|---|---|---:|---|---|---|---|---|---|
| clean-long | mask-after 380 | 0 | 0 → 0 | 100 % [277/277] | identical | 18.90 m (18.19–20.20), identical | 10.01 m\*, identical | unchanged |
| clean | mask-after 230 | 0 | 0 → 0 | 100 % [216/216] | identical | 13.94 m (12.25–16.89), identical | 6.45 m\*, identical | unchanged |
| manual | use, hold-out 100 | 1 | 1 → 1 | 100 % [3/3; pin 1/1] | identical | 259.78 m (pin prior), identical | 67.29 m\*, identical | unchanged |
| jammed-A | use | 0 | 0 → 0 | 100 % [1/1] | identical | = end | 1.147 % (1.02–1.26), identical | unchanged |
| jammed-B | use | 0 | 0 → 0 | 100 % [1/1] | identical | = end | 1.068 % (0.93–1.39), identical | unchanged |
| manual-3 (sanity) | use | 3 | 3 → 3 | 66.7 % [2/3; pins 2/3] | identical | 463.46 m (458.14–472.96), identical | 129.87 m\*, identical | unchanged |
| drive-7 (info), new | use | 12 | 12 → 9 (3, 0) | 75.0 % [9/12] | 77.8 % [7/9] | 210.23 m (209.51–211.45), identical | 10.59 m (8.53–15.74)\* → 22.50 m (12.67–29.09)\* | not gated |
| drive-7 (info), new + excl. | use | 12 | 12 → 7 (3, 2) | 75.0 % [9/12] | 85.7 % [6/7] | 210.23 m, identical | → 22.50 m\* | not gated |

\* no truth `end`: error at the last scored checkpoint.

- **The six acceptance drives are unchanged.** None has two pins within 3 s:
  their closest pins are minutes apart, and manual has a single pin. Every
  criterion, consistency and pin number is the same under both rules.
- **drive-7** has three refinement pairs, 1.27 s, 0.95 s and 1.60 s apart. The
  folded second pins scored 111 m (outside the ellipse on all 5 seeds),
  19.5 m and 10.6 m (inside). The first pins of those pairs (210 m, 24.7 m,
  22.5 m) stay scored.
  - Its max error (210 m, at the first pin of the 706 s pair) does not change.
  - Its end error moves from the last pin (the 1766 s refinement) to the first
    pin of that pair, 1.6 s earlier.
  - Excluding 599 s (189 m, outside on every seed) and 626 s (56 m, inside on
    every seed) removes one miss and one hit. Consistency goes 7/9 → 6/7.
- **Identity evidence.** With the same build, every one of the 35 GeoJSON
  files (6 acceptance runs + drive-7, × 5 seeds) is byte-identical under old,
  new and new + excl. They are also byte-identical to the previous commit's
  build: track, ellipses, fixes, checkpoint estimates and errors, and pin
  estimates. In `metrics.json`, the only field that differs from the previous
  commit's build under the old rule is the new `pinScoring`. Timing is not
  compared. Under the new rule, `endErrorM`/`endErrorPercent` and
  `consistency` also differ, on the 5 drive-7 rows only, plus each
  checkpoint's new `notScored` marker.

### N3.0 baseline: both consistency definitions (2026-10-12)

Engine as N4-B1, default config, release build, Mac. Seeds 1–5 in arrival
order and `--as-live` (header seed); every run gives the same counts, so one
value stands for all six. "Engine" is `consistency` (the engine's 95 %
ellipse). "+ truth σ" is `consistencyWithTruthSigma` (P + σ_truth² I), which
the adoption rule gates on from N3.0. drive-7's truth is likely, not proven,
at its two excluded pins (see "Acceptance runs").

| alias | run | scored checkpoints | engine | + truth σ (gated) |
|---|---|---|---|---|
| clean-long | mask-after 380 | 277 clean fixes | 100 % [277/277] | 100 % [277/277] |
| clean | mask-after 230 | 216 clean fixes | 100 % [216/216] | 100 % [216/216] |
| manual | use, hold-out 100 | 1 pin, 2 truth points | 100 % [3/3] | 100 % [3/3] |
| jammed-A | use | truth end | 100 % [1/1] | 100 % [1/1] |
| jammed-B | use | truth end | 100 % [1/1] | 100 % [1/1] |
| manual-3 (sanity) | use | 3 pins | 66.7 % [2/3] | 66.7 % [2/3] |
| drive-7 | mask-after 1800 | 266 clean fixes, 7 pins | 99.6 % [272/273; clean 266/266, pins 6/7] | 99.6 % [272/273; clean 266/266, pins 6/7] |

- The definitions differ only where the truth's σ is comparable to the
  engine's ellipse. Here every clean-fix σ (≤ 10 m) is small against
  ellipses of tens to hundreds of metres, and every pin or truth point that
  was inside stays inside.
- The two misses are far enough outside to stay outside:
  - manual-3, pin at ≈ 897 s: 130 m error against a 106 × 82 m ellipse,
    130 m semi-major axis with σ 31 m added (seed 1). Borderline.
  - drive-7, first pin of the 706 s pair: 209 m against 84 × 64 m, 111 m
    with σ 30 m added. That is the error the two excluded pins left behind
    (backlog N3MF-1).

### N3.0 exit: engine fixes, the baseline N3.2 is judged against (2026-10-12)

The N3.0 engine fixes (docs/N3_PLAN.md, "N3.0"), each in its own commit
with a regression test that failed before it, judged one by one with the
mean-based adoption rule against the item before. Release build, Mac,
default config (two new keys: `manualFixReactionS` 1, `manualFixUnknownSpeedMps`
10), seeds 1–5 in arrival order plus `--as-live` (header seed), all seven
acceptance drives. "N4-B1" is the engine as in the N3.0 baseline above.
drive-7's truth is likely, not proven, at its two excluded pins.

| item | change | acceptance against the item before |
|---|---|---|
| R11.1-4 | course gate: the OBD speed held at the fix time, fresh or stale; a stale 0 or no reply vetoes | arrival order bit-identical; as-live clean-long's pre-session clean fix arrives before the first OBD reply and loses its course (one reseed later), max 18.78 → 19.24 m |
| R11.1-5 | a stale fix accepted while stopped must be no older than the last moving step | bit-identical (`staleFixesIgnoredMoved` 0 on every run) |
| R11.1-6 | **not adopted** (see below) | — |
| R11.2-2 | latency shift interpolated between the history entries around the fix time | changed on every drive, adoption rule PASS |
| R11.2-3 | an initialising fix's σ grows by age × speed | clean-long, manual (10⁻⁵ m) and drive-7 changed, PASS |
| R14.4-1 | a late initialising pin backfills ring, history and cumulative motion | bit-identical (no late initialising pin in the set) |
| N4MF-1 | pin σ grows with speed at the tap | manual identical (0 km/h); manual-3 and drive-7 changed (σ +0.0–2.7 m), PASS |
| R11.1-7 | measured, then antithetic stale speed-noise increments (R20.1-1: the offsets a resample chose are kept, not re-paired) | bit-identical (no unknown-speed steps; every stale stretch is parked); R20.1-1 also bit-identical, 42/42 |

**Arrival order, seeds 1–5 (the baseline).** Values per seed are seeds 1 / 2 / 3 / 4 / 5.

| alias | run | distance | criterion | N4-B1 mean (range) | N3.0 mean (range) | per seed, N3.0 | Δ mean | allowed | inside 95 %, engine / + truth σ (gated) | converged at | ms/step |
|---|---|---:|---|---|---|---|---:|---|---|---:|---:|
| clean-long | mask-after 380 | 7.75 km | max ≤ 30 m | 18.90 m (18.19–20.20) | 19.42 m (18.09–20.29) | 20.29 / 18.09 / 20.01 / 19.08 / 19.62 | +0.52 m | ≤ +2 m | 100 % [277/277] / 100 % | 0.02 km | 0.065 |
| clean | mask-after 230 | 3.58 km | max ≤ 30 m | 13.94 m (12.25–16.89) | 12.98 m (10.67–16.46) | 12.24 / 10.67 / 16.46 / 12.33 / 13.21 | −0.96 m | ≤ +2 m | 100 % [216/216] / 100 % | 0.03–0.04 km | 0.063 |
| manual | use, hold-out 100 | 8.31 km | truth point 1 ≤ 200 m | 50.57 m (47.43–57.42) | 50.50 m (47.39–57.52) | 48.83 / 57.52 / 47.39 / 49.34 / 49.41 | −0.08 m | ≤ +2.5 m | 100 % [3/3] / 100 % | 7.27–7.68 km (known FAIL, reported) | 0.068 |
| jammed-A | use | 11.23 km | end ≤ 2.5 % | 1.147 % (1.02–1.26) | 1.137 % (1.01–1.26) | 1.012 / 1.019 / 1.185 / 1.259 / 1.210 | −0.011 pp | ≤ +0.1 pp | 100 % [1/1] / 100 % | 8.15 km | 0.070 |
| jammed-B | use | 5.89 km | end ≤ 2.5 % | 1.068 % (0.93–1.39) | 1.068 % (0.94–1.37) | 0.971 / 0.940 / 1.009 / 1.374 / 1.046 | −0.000 pp | ≤ +0.1 pp | 100 % [1/1] / 100 % | 5.18–5.31 km | 0.066 |
| drive-7 | mask-after 1800 | 19.87 km | every withheld clean fix after 1800 s ≤ 2.5 % | 1.138 % (1.08–1.23) | 1.128 % (1.07–1.23) | 1.073 / 1.074 / 1.164 / 1.097 / 1.231 | −0.010 pp | ≤ +0.1 pp | 99.6 % [272/273; clean 266/266, pins 6/7] / same | 0.58 km | 0.073 |
| manual-3 (sanity) | use | 12.05 km | reported | pins 103–104 / 458–473 / 128–131 m | pins 103–104 / 457–471 / 128–131 m | | | not gated | 66.7 % [2/3] / 66.7 % | 1.72 km | 0.071 |

Every criterion passes on every seed, and the consistency with the truth's
σ (the gated one) is unchanged on every drive: the adoption rule passes
against N4-B1. The engine-only consistency is identical to it on every
drive and seed. ms/step from a sequential seed-1 run (N4-B1 on the same
Mac: 0.064–0.071); the largest single `ingest` was 0.24–0.44 ms.

**drive-7, reported, not gated.** Max over the withheld clean fixes 224.0 m
mean (213.2–244.5), at the last fix (2144 s, 19.86 km), against 226.0 m for
N4-B1; as % of the distance since the last pin 4.52 % mean (4.30–4.93; N4-B1
4.55 %). The scored pins (m; \* outside 95 %), seed 1: 63 / 94 / 210\* / 101 /
29 / 86 / 24. The 706 s pair's first pin is still the one miss on every
seed (N3MF-1).

**As live (`--as-live`, header seed).**

| alias | criterion | N4-B1 | N3.0 | stale fixes ignored / held and used | consistency + truth σ |
|---|---|---|---|---|---|
| clean-long | max ≤ 30 m | 18.78 m | 19.19 m | 0 / 0 | 100 % |
| clean | max ≤ 30 m | 10.76 m | 13.59 m | 0 / 0 | 100 % |
| manual | truth point 1 ≤ 200 m | 53.50 m | 53.66 m | 0 / 0 | 100 % |
| jammed-A | end ≤ 2.5 % | 1.302 % | 1.290 % | 0 / 1 | 100 % |
| jammed-B | end ≤ 2.5 % | 1.370 % | 1.389 % | 0 / 1 | 100 % |
| drive-7 | every withheld clean fix ≤ 2.5 % | 1.151 % | 1.141 % | 0 / 0 | 99.6 % [272/273] |
| manual-3 (sanity) | pin priors | 103 / 458 / 131 m | 103 / 456 / 133 m | 0 / 1 | 66.7 % [2/3] |

As live, clean-long changes first with R11.1-4 (its pre-session fix loses
its course: 18.78 → 19.24 m). Clean as live moves with R11.2-2 (10.76 →
13.59 m), within its arrival-order seed range (10.67–16.46 m): it is one
seed. Every criterion passes.

**Every change against N4-B1, explained.**
- clean, clean-long, manual, jammed-A/B and drive-7 moved in arrival order
  only through R11.2-2 (every fix's latency shift changes slightly) and, on
  clean-long, manual and drive-7, R11.2-3 (the first fix's σ grows by its
  age × speed). manual-3 and drive-7 also moved with N4MF-1 (pins at
  4–47 km/h: σ +0.0–2.7 m). Every move is within seed noise; none changes a
  criterion's verdict or a consistency count.
- R11.1-4 changes only as-live clean-long, as above. R11.1-5, R14.4-1 and
  R11.1-7 are bit-identical on all 42 runs: the set has no stale fix
  before a stop, no late initialising pin and no unknown-speed step.

**R11.1-6, not adopted.** Excluding the reseeded particles from their own
fix's update (each fix counted once; the posterior after one clean fix on
an unknown heading becomes the fix's σ and course σ, not √2 tighter) fails
the adoption rule on clean: mean 13.94 → 18.58 m (Δ +4.64 m, allowed +2 m),
per seed 13.01 → 20.00, 16.89 → 11.15, 12.25 → 27.57, 14.49 → 16.78,
13.06 → 17.40 m. Convergence moves 0.03 → 0.04 km on every seed, as
expected. On seeds 6–25 (clean only, diagnosis, not tuning) the mean is
unchanged (16.04 → 16.01 m), but the spread grows (sd 3.51 → 5.43 m) and
one seed reaches 32.56 m, above the 30 m criterion. The other drives have
no reseed in arrival order. The patch and its regression test are kept
in the git-ignored `logs/`; backlog R11.1-6 stays open.

N2.2 experiment and informational runs: moved to [docs/archive/NAVIGATION-history.md](archive/NAVIGATION-history.md).

### N3.2b: first measurement with roads (2026-10-13)

Default road config (no tuning), packs national + region-A (`roadSetHash`
prefix `fecadb9b`), release build on the Mac, seeds 1–5 in arrival order,
each drive in its acceptance mode. Outputs: `logs/n32b/roads/` (git-ignored);
the table script is `logs/n32b/table.py`. Against the N3.0 exit baseline
above. A measurement, not an adoption: no config or engine change was made.

| alias | criterion | N3.0 mean | N3.2 mean (range) | inside 95 % + truth σ (gated), N3.0 → N3.2 | engine ellipse | wrong road, fixes / distance | off, fixes / distance | unmapped / captured (per seed) | ms/step (seed 1, sequential) |
|---|---|---:|---|---|---|---|---|---|---|
| clean-long | max ≤ 30 m | 19.42 m | 22.51 m (22.48–22.53) | 100 → 96.4 % [267/277] | 100 → 96.0 % | 1.3 % / 0.5 % | 0.7 % / 0.3 % | 0 / 0 | 0.065 → 0.095 |
| clean | max ≤ 30 m | 12.98 m | 19.44 m (16.21–21.75) | 100 → 100 % | 100 → 98.5 % | 2.5 % / 2.4 % (1.9–2.8) | 4.2 % / 4.4 % | 83 / 0 | 0.064 → 0.090 |
| manual | truth point 1 ≤ 200 m | 50.50 m | 8.11 m (7.20–9.60) | 100 → 100 % | 100 → 100 % | n/a (no clean GNSS) | n/a | 0 / 0 | 0.069 → 0.107 |
| jammed-A | end ≤ 2.5 % | 1.137 % | 0.171 % (0.166–0.178) | 100 → 100 % | 100 → 0 % [0/1] | n/a | n/a | 0 / 0 | 0.071 → 0.114 |
| jammed-B | end ≤ 2.5 % | 1.068 % | 0.297 % (0.251–0.336) | 100 → 100 % | 100 → 100 % | n/a | n/a | 0 / 0 | 0.072 → 0.112 |
| manual-3 (sanity) | reported | pins 232.0 m mean | pins 68.7 m mean (83 / 20–31 / 93–99 m) | 66.7 → 66.7 % | 66.7 → 33.3 % | n/a | n/a | 0 / 0 | 0.071 → 0.110 |
| drive-7 | every withheld clean fix after 1800 s ≤ 2.5 % | 1.128 % (224.0 m) | 0.167 % (32.8 m; 31.9–34.1) | 99.6 → 87.4 % [237–240/273] | 99.6 → 86.0 % | 5.7 % / 3.6 % (5.4–6.2 / 3.5–3.7) | 0.8 % / 0.2 % | 0 / 0 | 0.072 → 0.114 |

- **Heading convergence, manual:** 7.27–7.68 km (N3.0, known FAIL) →
  1.52 km on every seed: the N3 target (≤ 2 km every seed) passes. Other
  drives: jammed-A 8.15 → 0.31 km, jammed-B 5.26 → 0.20 km, manual-3
  1.72 → 0.37 km, drive-7 0.58 → 0.14 km.
- **drive-7's reported target** (max withheld clean fix after 1800 s; N3.0
  224.0 m mean, N4-B1 226 m): 32.8 m mean, 0.167 % of distance, on every
  seed at the drive's last minute (≈ 2083 s).
- **Adoption rule (judge.py): FAIL** on clean (+6.46 m, allowed +2 m),
  clean-long (+3.09 m, allowed +2 m; consistency 100 → 96.4 %) and drive-7
  (consistency 99.6 → 87.4 %). Every per-seed criterion passes (max ≤ 30 m,
  ≤ 2.5 %, truth point ≤ 200 m). manual, jammed-A/B pass with large gains.
- **Wrong-road share** (checks capture onto a wrong *mapped* road only):
  clean 2.5 % by fixes, 2.4 % by distance; clean-long 1.3 % / 0.5 %; both
  under the 5 % starting target (Q8), but clean's figure is provisional.
  drive-7 (informational) 5.7 % / 3.6 %. Ambiguous share of the road truth:
  clean-long 7.4 %, clean 20.3 % (every seed), drive-7 33.2 %. Clean and
  drive-7 are both over the plan's 20 % trigger for a Viterbi match
  (N3_PLAN.md: "If more than 20 % are ambiguous, upgrade to a Viterbi
  match"); the Viterbi match is not implemented, so clean's wrong-road share,
  a gated N3 criterion, stays provisional until the user decides.
- **No usable course:** clean-long 115 of 277 withheld clean fixes (63 with
  OBD speed 0, 52 creeping under 3 m/s GNSS: two stops and the final slow
  section), clean 62 of 216, drive-7 29 of 266. They are not scored for
  wrong road; they do count for unmapped/captured and consistency.
- **Unmapped/captured (R21.1-11):** only clean has unmapped truth fixes (83
  per seed, > 15 m from every edge); none captured on any seed.
- **Where the misses are** (seed 1; the other seeds alike):
  - clean-long: the last 11 s (≈ 647–657 s), creeping (no usable course):
    the estimate held on an edge 31 m from the truth, 15.6 m across, error
    22.5 m, so the ellipse misses.
  - drive-7: 2058–2090 s at the end, on service roads or off any
    heading-compatible edge (truth: no road 19, ambiguous 7, matched 7 of
    33): the estimate on an edge up to 56 m from the truth, 15–37 m across.
  - clean: 242–248 s, just after the mask, at about 12 m/s through a
    junction where the truth passes from a secondary to a primary way on
    the same course: the estimate stays on another edge (wrong, 21–46 m
    from the truth) for 3 s, then `onRoadShare` falls to 0 (off) for 4 s,
    then it rejoins; error 15–22 m, the max on this seed.

  The end-of-drive cases are not "unmapped" by the R21.1-11 definition: a
  mapped edge of another heading lies within 15 m. So the capture risk R2
  (test 3) shows on real data at car parks and service roads, where the
  unmapped metric does not count it; the consistency drop is its measure.
  N3.2c item 2 widens the metric to count them (below).
- **ms/step** (seed 1, sequential, release): 0.064–0.072 without roads,
  0.090–0.114 with, so mean ≤ 0.15 passes. Road cost by differencing:
  0.35–0.51 ms per road update (manual 0.51, just over the 0.5 ms Mac
  proxy). Candidate tests 15–33 per particle and update (≤ 64). Largest
  single `ingest` 1.1–4.5 ms with roads (0.24–0.46 without).
- **Without `--roads`:** 42/42 GeoJSON byte-identical and every
  `metrics.json` field equal to the N3.0 exit runs (compare.py).

### N3.2c item 7: results independent of pack order (2026-10-13)

- **Root cause:** a segment in both packs was kept from the pack loaded
  first, so the order decided which pack's edge a particle sat on. The
  level rule finds adjacency within one pack only. With national first, a
  particle could not pass between a region-A-only road and national's
  copy of a connected road on another level (a bridge or an underpass), in
  either direction. That changed particles, not only the edge reported. Clean, seed 1, before the fix: national
  first 21.75 m max, level blocked 23 818, wrong road 2.8 %; region-A
  first 15.6 m, level blocked 0, wrong road 0 %.
- **Fix:** `RoadNetwork` sorts its packs by ascending content hash, and
  `roadSetHash` hashes the sorted content hashes. National has the lower
  hash, so the canonical order is the one N3.2b used. Every N3.2b figure
  above stands.
- **Check** (`logs/n32c/order/`, seed 1, every acceptance drive): region-A
  then national gives GeoJSON byte-identical and `metrics.json` equal
  (timing fields aside) to the N3.2b runs, label `-roads-fecadb9b`. Without
  roads, every output is unchanged.
- **Open (item 7):** which copy wins is now canonical but arbitrary. A rebuilt pack
  gets a new hash and can flip the order. Clean shows the choice is worth
  about 6 m. Adjacency across packs (shared OSM node IDs) or a deliberate
  precedence rule would be an engine change under the adoption rule.
  Adjacency across packs: N3.2e item 1 below.

### N3.2c item 2: unmapped counts fixes with no heading-compatible road within 15 m (2026-10-13)

Metric only: the engine, every other metric and the GeoJSON are unchanged
(seed 1, every acceptance drive, against `logs/n32b/roads/seed1`; outputs
and `compare.py` in `logs/n32c/unmapped/`). Unmapped = (> 15 m from every
edge) + (only incompatible edges within 15 m); a fix with no usable course
counts by distance only.

| alias | withheld clean fixes | N3.2b unmapped / captured | N3.2c unmapped (far + incompatible) / captured (far + incompatible) |
|---|---:|---|---|
| clean | 216 | 83 / 0 | 83 (83 + 0) / 0 (0 + 0) |
| clean-long | 277 | 0 / 0 | 0 (0 + 0) / 0 (0 + 0) |
| drive-7 | 266 | 0 / 0 | 44 (0 + 44) / 10 (0 + 10) |
| manual, manual-3, jammed-A/B | 0 | n/a | n/a (no clean GNSS) |

- drive-7: the 44 are one stretch at 2027–2076 s, the service-road end of
  the drive (nearest edge of another heading, median 3.9 m). 10 are
  captured, all at 2058–2068 s.
- clean: its 21 "no road" fixes are all > 15 m from every edge, so they
  were already counted.

### N3.2d: pre-declared grids (2026-10-13)

The N3.2 experiment grids exactly as pre-declared in docs/N3_PLAN.md
("Experiments"): nothing added, nothing tuned, never toward manual-3.
**A measurement, not an adoption: no config was chosen and no default was
changed. The choice is open for the user.**

- **Setup.** One factor at a time from the default config, each through
  `replay_nav --set key=value`. Packs national + region-A (`roadSetHash`
  prefix `fecadb9b`). Release build of the N3.2c engine on the Mac. Seeds
  1–5 in arrival order, the seven acceptance runs in their acceptance
  modes. Seed 1 ran alone (the timing run: every ms/step below is from it),
  then seeds 2 + 3 and 4 + 5, never more than two at a time. Outputs,
  scripts and the judge.py output per value are in `logs/n32d/`
  (git-ignored).
- **Keys.** Every grid key exists in `NavigationConfig`. The fix gate has
  no on/off key of its own: "off" is `--set roadFixGateSigma=0`, which the
  engine already treats as disabled (`roadFixGateSigma > 0` guards the
  gate). No engine, config or plumbing code changed.
- **Default column** = the N3.2b runs (`logs/n32b/roads`), not rerun. Two
  small runs with the grid binary, both identical to N3.2b (every
  `metrics.json` field except timing and the item-2 unmapped fields, and
  every GeoJSON byte): seed 1 sequential, for ms/step from the same binary
  and session as the grid; and drive-7 seeds 2–5, for the N3.2c item-2
  unmapped split, which the N3.2b files predate (seed 1's is in
  `logs/n32c/unmapped`). Clean and clean-long need no rerun: their road
  truth is seed-independent and has no "incompatible" fix.
- **Run time:** 16 values × 30 runs in 25.4 min, plus 52 s for the two
  default runs.

**roadSigmaM from the residuals.** The rule was written down before any
number was looked at:
- Fixes: the withheld clean fixes (≤ 15 m) of clean (mask-after 230) and
  clean-long (mask-after 380) whose offline road truth is `matched`
  (usable course, heading-compatible edge within 15 m, margin ≥ 2 over every
  other way).
- Residual d: the distance from the fix to that truth edge (`crossTrackM`).
  The truth rule censors it at 15 m; the largest is 8.75 m, so the
  censoring does not bite. The truth edge is chosen with the frozen
  `RoadTruth.roadSigmaM` (7 m), never the run's value. The residuals are
  seed-independent (seeds 1 and 4 identical).
- The fix's own error was to be removed:
  σ_r = √(mean d² − mean σ_fix²), with σ_fix = accuracy / 1.51.

| drives | matched withheld clean fixes | p50 m | p95 m | max m | RMS m | RMS σ_fix m | σ_r = √(mean d² − mean σ_fix²) | p50/0.6745 m | > 10 m |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| clean | 106 | 2.03 | 6.24 | 8.75 | 3.01 | 5.80 | none: -24.5 m² < 0 | 3.01 | 0 |
| clean-long | 150 | 2.68 | 4.92 | 6.51 | 3.07 | 3.31 | none: -1.5 m² < 0 | 3.97 | 0 |
| pooled | 256 | 2.49 | 5.56 | 8.75 | 3.05 | 4.51 | none: -11.0 m² < 0 | 3.70 | 0 |

- **The declared rule gives no value.** accuracy / 1.51 (3.3 m for
  clean-long's 5 m fixes, 3.3–6.6 m for clean's 5–10 m) is larger than the
  residuals themselves. The reported accuracy overstates these fixes'
  cross-track error, so the subtraction goes negative.
- **The value run is RMS(d) pooled: 3.05 → 3.0 m.** It is an upper bound on
  σ_r, because it still holds the fix's error. The robust half-normal
  estimate p50 / 0.6745 is 3.7 m. This fallback was chosen after the
  subtraction failed and before any grid run, not from a replay result.

**Reading the tables.**
- A cell is the gated criterion's mean (range) over seeds 1–5, followed by
  the adoption-rule verdict (judge.py: the mean rule, the criterion on every
  seed, and consistency + truth σ not dropping): **against N3.0 / against
  the N3.2b default**. P = pass, F = fail.
- "all gated" covers the six gated aliases. manual-3 is a sanity check and
  is never gated.
- drive-7's gated value is the worst withheld clean fix after 1800 s, in %
  of distance. The second table also gives it in metres (reported, not
  gated).
- Consistency is `consistencyWithTruthSigma`, the mean over seeds.
- Wrong road counts capture onto a wrong *mapped* road only. Clean's
  figure is provisional: its road truth is 20.3 % ambiguous (N3.2b).
- Unmapped / captured use the N3.2c item-2 split, far (> 15 m from every
  edge) + incompatible (only edges of another heading within 15 m).
  Captured is per seed. clean-long has no unmapped fix, and manual,
  manual-3 and jammed-A/B have no clean GNSS.

#### roadSigmaM {3.0 (from the residuals), 5, 7, 10}

**roadSigmaM: gated criterion, mean (range) over seeds 1–5; adoption rule (judge.py) vs N3.0 / vs N3.2b default**

| value | clean-long max m | clean max m | manual pt 1 m | jammed-A end % | jammed-B end % | drive-7 worst fix > 1800 s % | manual-3 pins m (sanity) | all gated |
|---|---|---|---|---|---|---|---|---|
| N3.0 | 19.42 | 12.98 | 50.50 | 1.137 | 1.068 | 1.128 | 232.0 | |
| 3.0 (residuals) | 25.88 (25.85–25.91) F/F | 14.17 (13.72–15.67) P/P | 8.52 (8.10–9.33) P/P | 0.152 (0.138–0.160) P/P | 0.411 (0.354–0.454) P/F | 0.712 (0.702–0.717) F/F | 68.8 (67.6–70.4) | FAIL / FAIL |
| 5 | 23.79 (23.74–23.88) F/F | 17.03 (16.00–19.85) F/P | 8.54 (7.67–10.12) P/P | 0.163 (0.152–0.170) P/P | 0.360 (0.293–0.405) P/P | 0.157 (0.154–0.163) F/P | 68.9 (67.3–70.3) | FAIL / FAIL |
| 7 (default) | 22.51 (22.48–22.53) F/P | 19.44 (16.21–21.75) F/P | 8.11 (7.20–9.60) P/P | 0.171 (0.166–0.178) P/P | 0.297 (0.251–0.336) P/P | 0.167 (0.162–0.173) F/P | 68.7 (67.4–69.7) | FAIL / PASS |
| 10 | 21.09 (21.07–21.13) P/P | 25.98 (23.10–28.80) F/F | 7.64 (6.37–9.90) P/P | 0.173 (0.166–0.180) P/P | 0.235 (0.203–0.270) P/P | 0.151 (0.146–0.157) F/P | 68.8 (67.1–70.6) | FAIL / FAIL |

**roadSigmaM: consistency (+ truth σ, gated; mean over seeds, %), roads, convergence, timing**

| value | cons cl / c / m / jA / jB / d7 / m3 | wrong road fixes / distance: clean-long; clean; drive-7 (info) | unmapped (far + incompatible) / captured (far + incompatible), per seed: clean; drive-7 | manual conv km | drive-7 worst fix > 1800 s m (range) | ms/step seed 1 (min–max over drives; max ingest ms) |
|---|---|---|---|---|---|---|
| N3.0 | 100.0 / 100.0 / 100.0 / 100.0 / 100.0 / 99.6 / 66.7 | n/a | n/a | 7.59 | 224.0 | 0.065–0.073 (not sequential) |
| 3.0 (residuals) | 96.0 / 100.0 / 100.0 / 100.0 / 100.0 / 86.3 / 66.7 | 0.0 / 0.0 %; 1.1 / 1.2 % (0.9–2.1); 0.0 / 0.0 % | 83 + 0 / 1+0, 1+0, 1+0, 0+0, 1+0; 0 + 44 / 0+11, 0+10, 0+10, 0+10, 0+10 | 1.52 | 138.9 (137.0–139.8) | 0.088–0.112 (4.4) |
| 5 | 96.0 / 100.0 / 100.0 / 100.0 / 100.0 / 88.2 / 66.7 | 0.0 / 0.0 %; 1.9 / 1.9 %; 4.7 / 2.0 % | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+13, 0+13, 0+13, 0+13, 0+13 | 1.52–1.69 | 31.0 (30.2–32.2) | 0.089–0.117 (4.7) |
| 7 (default) | 96.4 / 100.0 / 100.0 / 100.0 / 100.0 / 87.4 / 66.7 | 1.3 / 0.5 %; 2.5 / 2.4 % (1.9–2.8); 5.7 / 3.6 % (3.5–3.7) | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+10, 0+10, 0+10, 0+10, 0+10 | 1.52 | 32.8 (31.9–34.1) | 0.090–0.115 (4.4) |
| 10 | 100.0 / 99.4 / 100.0 / 100.0 / 100.0 / 89.2 / 66.7 | 1.3 / 0.5 %; 3.4 / 3.4 % (2.8–3.8); 4.8 / 3.2 % (3.1–3.5) | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+7, 0+7, 0+7, 0+7, 0+7 | 1.52 | 29.8 (28.8–30.9) | 0.093–0.117 (4.4) |

#### roadOffRoadProbability {0.02, 0.1, 0.3}

**roadOffRoadProbability: gated criterion, mean (range) over seeds 1–5; adoption rule (judge.py) vs N3.0 / vs N3.2b default**

| value | clean-long max m | clean max m | manual pt 1 m | jammed-A end % | jammed-B end % | drive-7 worst fix > 1800 s % | manual-3 pins m (sanity) | all gated |
|---|---|---|---|---|---|---|---|---|
| N3.0 | 19.42 | 12.98 | 50.50 | 1.137 | 1.068 | 1.128 | 232.0 | |
| 0.02 | 22.63 (22.59–22.65) F/P | 22.27 (19.60–23.33) F/F | 8.24 (7.16–10.34) P/P | 0.170 (0.166–0.175) P/P | 0.301 (0.258–0.350) P/P | 0.194 (0.189–0.197) F/F | 68.9 (67.2–70.3) | FAIL / FAIL |
| 0.1 (default) | 22.51 (22.48–22.53) F/P | 19.44 (16.21–21.75) F/P | 8.11 (7.20–9.60) P/P | 0.171 (0.166–0.178) P/P | 0.297 (0.251–0.336) P/P | 0.167 (0.162–0.173) F/P | 68.7 (67.4–69.7) | FAIL / PASS |
| 0.3 | 22.23 (22.13–22.27) F/P | 16.24 (13.09–18.46) F/P | 8.25 (7.23–10.38) P/P | 0.170 (0.162–0.176) P/P | 0.313 (0.272–0.351) P/P | 0.138 (0.136–0.139) F/P | 68.6 (67.1–70.3) | FAIL / PASS |

**roadOffRoadProbability: consistency (+ truth σ, gated; mean over seeds, %), roads, convergence, timing**

| value | cons cl / c / m / jA / jB / d7 / m3 | wrong road fixes / distance: clean-long; clean; drive-7 (info) | unmapped (far + incompatible) / captured (far + incompatible), per seed: clean; drive-7 | manual conv km | drive-7 worst fix > 1800 s m (range) | ms/step seed 1 (min–max over drives; max ingest ms) |
|---|---|---|---|---|---|---|
| N3.0 | 100.0 / 100.0 / 100.0 / 100.0 / 100.0 / 99.6 / 66.7 | n/a | n/a | 7.59 | 224.0 | 0.065–0.073 (not sequential) |
| 0.02 | 96.4 / 99.8 / 100.0 / 100.0 / 100.0 / 80.6 / 66.7 | 1.3 / 0.5 %; 2.5 / 2.4 % (1.9–2.8); 7.9 / 4.2 % (3.9–4.3) | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+10, 0+9, 0+10, 0+9, 0+9 | 1.52 | 38.1 (37.2–38.9) | 0.092–0.114 (4.4) |
| 0.1 (default) | 96.4 / 100.0 / 100.0 / 100.0 / 100.0 / 87.4 / 66.7 | 1.3 / 0.5 %; 2.5 / 2.4 % (1.9–2.8); 5.7 / 3.6 % (3.5–3.7) | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+10, 0+10, 0+10, 0+10, 0+10 | 1.52 | 32.8 (31.9–34.1) | 0.090–0.115 (4.4) |
| 0.3 | 96.4 / 100.0 / 100.0 / 100.0 / 100.0 / 89.4 / 66.7 | 1.3 / 0.5 %; 1.9 / 1.9 %; 3.9 / 1.6 % | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+10, 0+10, 0+10, 0+10, 0+10 | 1.52–1.69 | 26.9 (26.7–27.1) | 0.088–0.118 (4.5) |

#### roadUpdateIntervalS {1, 0.5, 0.2, 0.1}

**roadUpdateIntervalS: gated criterion, mean (range) over seeds 1–5; adoption rule (judge.py) vs N3.0 / vs N3.2b default**

| value | clean-long max m | clean max m | manual pt 1 m | jammed-A end % | jammed-B end % | drive-7 worst fix > 1800 s % | manual-3 pins m (sanity) | all gated |
|---|---|---|---|---|---|---|---|---|
| N3.0 | 19.42 | 12.98 | 50.50 | 1.137 | 1.068 | 1.128 | 232.0 | |
| 1 (default) | 22.51 (22.48–22.53) F/P | 19.44 (16.21–21.75) F/P | 8.11 (7.20–9.60) P/P | 0.171 (0.166–0.178) P/P | 0.297 (0.251–0.336) P/P | 0.167 (0.162–0.173) F/P | 68.7 (67.4–69.7) | FAIL / PASS |
| 0.5 | 22.10 (22.05–22.15) F/P | 20.76 (15.61–26.93) F/F | 9.00 (7.15–12.03) P/P | 0.169 (0.162–0.174) P/P | 0.280 (0.224–0.336) P/P | 0.177 (0.170–0.188) F/P | 67.9 (66.7–69.3) | FAIL / FAIL |
| 0.2 | 22.00 (21.98–22.05) F/P | 20.29 (17.11–24.06) F/F | 9.95 (7.48–12.92) P/P | 0.168 (0.163–0.171) P/P | 0.272 (0.221–0.334) P/P | 0.186 (0.182–0.191) F/F | 67.9 (67.3–68.9) | FAIL / FAIL |
| 0.1 | 21.95 (21.87–21.99) F/P | 21.60 (17.33–25.20) F/F | 9.51 (7.31–12.71) P/P | 0.170 (0.169–0.173) P/P | 0.286 (0.250–0.316) P/P | 0.186 (0.183–0.191) F/F | 67.7 (67.1–68.2) | FAIL / FAIL |

**roadUpdateIntervalS: consistency (+ truth σ, gated; mean over seeds, %), roads, convergence, timing**

| value | cons cl / c / m / jA / jB / d7 / m3 | wrong road fixes / distance: clean-long; clean; drive-7 (info) | unmapped (far + incompatible) / captured (far + incompatible), per seed: clean; drive-7 | manual conv km | drive-7 worst fix > 1800 s m (range) | ms/step seed 1 (min–max over drives; max ingest ms) |
|---|---|---|---|---|---|---|
| N3.0 | 100.0 / 100.0 / 100.0 / 100.0 / 100.0 / 99.6 / 66.7 | n/a | n/a | 7.59 | 224.0 | 0.065–0.073 (not sequential) |
| 1 (default) | 96.4 / 100.0 / 100.0 / 100.0 / 100.0 / 87.4 / 66.7 | 1.3 / 0.5 %; 2.5 / 2.4 % (1.9–2.8); 5.7 / 3.6 % (3.5–3.7) | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+10, 0+10, 0+10, 0+10, 0+10 | 1.52 | 32.8 (31.9–34.1) | 0.090–0.115 (4.4) |
| 0.5 | 96.4 / 99.4 / 100.0 / 100.0 / 100.0 / 87.9 / 66.7 | 1.3 / 0.5 %; 2.6 / 2.6 % (1.9–2.8); 5.4 / 2.2 % | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+10, 0+10, 0+10, 0+10, 0+10 | 1.52 | 34.8 (33.4–37.1) | 0.112–0.156 (4.4) |
| 0.2 | 96.4 / 99.9 / 100.0 / 100.0 / 100.0 / 86.7 / 66.7 | 1.3 / 0.5 %; 2.5 / 2.4 % (1.9–2.8); 5.4 / 2.2 % | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+9, 0+9, 0+10, 0+9, 0+9 | 1.52–2.00 | 36.6 (35.9–37.6) | 0.186–0.295 (4.5) |
| 0.1 | 96.4 / 99.3 / 100.0 / 100.0 / 100.0 / 86.7 / 66.7 | 1.3 / 0.5 %; 2.6 / 2.6 % (1.9–2.8); 5.4 / 2.2 % | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+10, 0+9, 0+10, 0+9, 0+10 | 1.52–2.07 | 36.7 (36.1–37.6) | 0.310–0.509 (4.6) |

ms/step per drive (seed 1, sequential, release, Mac) and the cost of the extra road updates, by differencing against the default:

| value | clean-long | clean | manual | jammed-A | jammed-B | manual-3 | drive-7 | mean | max single ingest ms | road updates (all drives) | extra ms per extra road update vs default |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 (default) | 0.096 | 0.090 | 0.110 | 0.114 | 0.113 | 0.111 | 0.115 | 0.107 | 4.43 | 6219 |  |
| 0.5 | 0.121 | 0.112 | 0.146 | 0.156 | 0.156 | 0.150 | 0.156 | 0.142 | 4.42 | 12324 | 0.436 |
| 0.2 | 0.198 | 0.186 | 0.249 | 0.283 | 0.295 | 0.267 | 0.283 | 0.252 | 4.45 | 30722 | 0.444 |
| 0.1 | 0.329 | 0.310 | 0.430 | 0.495 | 0.509 | 0.472 | 0.487 | 0.433 | 4.61 | 61608 | 0.442 |

#### roadCorrelationM {10, 30, 100}

**roadCorrelationM: gated criterion, mean (range) over seeds 1–5; adoption rule (judge.py) vs N3.0 / vs N3.2b default**

| value | clean-long max m | clean max m | manual pt 1 m | jammed-A end % | jammed-B end % | drive-7 worst fix > 1800 s % | manual-3 pins m (sanity) | all gated |
|---|---|---|---|---|---|---|---|---|
| N3.0 | 19.42 | 12.98 | 50.50 | 1.137 | 1.068 | 1.128 | 232.0 | |
| 10 | 24.95 (24.86–25.02) F/F | 72.53 (72.46–72.66) F/F | 8.64 (8.00–9.81) P/P | 0.152 (0.139–0.162) P/P | 0.298 (0.021–0.493) P/P | 0.978 (0.790–1.538) F/F | 68.7 (67.4–69.9) | FAIL / FAIL |
| 30 (default) | 22.51 (22.48–22.53) F/P | 19.44 (16.21–21.75) F/P | 8.11 (7.20–9.60) P/P | 0.171 (0.166–0.178) P/P | 0.297 (0.251–0.336) P/P | 0.167 (0.162–0.173) F/P | 68.7 (67.4–69.7) | FAIL / PASS |
| 100 | 19.38 (19.22–19.50) P/P | 15.00 (11.74–19.22) F/P | 7.23 (5.81–10.02) P/P | 0.176 (0.170–0.181) P/P | 0.201 (0.171–0.245) P/P | 0.166 (0.116–0.281) F/P | 68.5 (66.8–70.2) | FAIL / PASS |

**roadCorrelationM: consistency (+ truth σ, gated; mean over seeds, %), roads, convergence, timing**

| value | cons cl / c / m / jA / jB / d7 / m3 | wrong road fixes / distance: clean-long; clean; drive-7 (info) | unmapped (far + incompatible) / captured (far + incompatible), per seed: clean; drive-7 | manual conv km | drive-7 worst fix > 1800 s m (range) | ms/step seed 1 (min–max over drives; max ingest ms) |
|---|---|---|---|---|---|---|
| N3.0 | 100.0 / 100.0 / 100.0 / 100.0 / 100.0 / 99.6 / 66.7 | n/a | n/a | 7.59 | 224.0 | 0.065–0.073 (not sequential) |
| 10 | 94.9 / 63.0 / 100.0 / 100.0 / 100.0 / 65.7 / 66.7 | 0.7 / 0.2 %; 1.9 / 1.9 %; 5.7 / 2.9 % (0.2–4.5) | 83 + 0 / 3+0, 3+0, 3+0, 3+0, 3+0; 0 + 44 / 0+20, 0+21, 0+14, 0+20, 0+12 | 1.52 | 192.6 (154.3–305.4) | 0.095–0.114 (4.5) |
| 30 (default) | 96.4 / 100.0 / 100.0 / 100.0 / 100.0 / 87.4 / 66.7 | 1.3 / 0.5 %; 2.5 / 2.4 % (1.9–2.8); 5.7 / 3.6 % (3.5–3.7) | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+10, 0+10, 0+10, 0+10, 0+10 | 1.52 | 32.8 (31.9–34.1) | 0.090–0.115 (4.4) |
| 100 | 100.0 / 100.0 / 100.0 / 100.0 / 100.0 / 92.7 / 66.7 | 1.3 / 0.5 %; 2.8 / 2.9 % (2.8–2.9); 4.8 / 3.4 % (0.5–6.8) | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+2, 0+2, 0+2, 0+1, 0+2 | 1.52–1.58 | 31.8 (22.8–52.8) | 0.093–0.119 (4.5) |

#### roadSplitSigmaM {10, 15, 25}

**roadSplitSigmaM: gated criterion, mean (range) over seeds 1–5; adoption rule (judge.py) vs N3.0 / vs N3.2b default**

| value | clean-long max m | clean max m | manual pt 1 m | jammed-A end % | jammed-B end % | drive-7 worst fix > 1800 s % | manual-3 pins m (sanity) | all gated |
|---|---|---|---|---|---|---|---|---|
| N3.0 | 19.42 | 12.98 | 50.50 | 1.137 | 1.068 | 1.128 | 232.0 | |
| 10 | 22.66 (22.55–22.78) F/F | 21.22 (16.16–23.68) F/F | 8.85 (7.33–10.18) P/P | 0.167 (0.154–0.177) P/P | 0.159 (0.102–0.265) P/P | 0.173 (0.171–0.175) F/F | 68.7 (67.6–70.0) | FAIL / FAIL |
| 15 (default) | 22.51 (22.48–22.53) F/P | 19.44 (16.21–21.75) F/P | 8.11 (7.20–9.60) P/P | 0.171 (0.166–0.178) P/P | 0.297 (0.251–0.336) P/P | 0.167 (0.162–0.173) F/P | 68.7 (67.4–69.7) | FAIL / PASS |
| 25 | 22.58 (22.55–22.62) F/P | 21.53 (19.70–22.46) F/F | 8.74 (7.14–11.56) P/P | 0.172 (0.165–0.176) P/P | 0.394 (0.381–0.406) P/P | 0.164 (0.160–0.170) F/P | 69.0 (67.2–70.4) | FAIL / FAIL |

**roadSplitSigmaM: consistency (+ truth σ, gated; mean over seeds, %), roads, convergence, timing**

| value | cons cl / c / m / jA / jB / d7 / m3 | wrong road fixes / distance: clean-long; clean; drive-7 (info) | unmapped (far + incompatible) / captured (far + incompatible), per seed: clean; drive-7 | manual conv km | drive-7 worst fix > 1800 s m (range) | ms/step seed 1 (min–max over drives; max ingest ms) |
|---|---|---|---|---|---|---|
| N3.0 | 100.0 / 100.0 / 100.0 / 100.0 / 100.0 / 99.6 / 66.7 | n/a | n/a | 7.59 | 224.0 | 0.065–0.073 (not sequential) |
| 10 | 96.0 / 99.9 / 100.0 / 100.0 / 100.0 / 86.2 / 66.7 | 0.7 / 0.2 %; 2.6 / 2.6 % (1.9–2.8); 5.4 / 3.5 % | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+10, 0+10, 0+10, 0+11, 0+10 | 1.52 | 34.1 (33.7–34.4) | 0.094–0.117 (4.4) |
| 15 (default) | 96.4 / 100.0 / 100.0 / 100.0 / 100.0 / 87.4 / 66.7 | 1.3 / 0.5 %; 2.5 / 2.4 % (1.9–2.8); 5.7 / 3.6 % (3.5–3.7) | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+10, 0+10, 0+10, 0+10, 0+10 | 1.52 | 32.8 (31.9–34.1) | 0.090–0.115 (4.4) |
| 25 | 96.4 / 100.0 / 100.0 / 100.0 / 100.0 / 87.8 / 66.7 | 1.3 / 0.5 %; 2.5 / 2.4 % (1.9–2.8); 5.6 / 3.6 % (3.5–3.7) | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+10, 0+10, 0+10, 0+10, 0+10 | 1.52–1.66 | 32.3 (31.6–33.4) | 0.088–0.111 (4.5) |

#### roadEngageMaxEllipseM {500, 1000, 2000}

**roadEngageMaxEllipseM: gated criterion, mean (range) over seeds 1–5; adoption rule (judge.py) vs N3.0 / vs N3.2b default**

| value | clean-long max m | clean max m | manual pt 1 m | jammed-A end % | jammed-B end % | drive-7 worst fix > 1800 s % | manual-3 pins m (sanity) | all gated |
|---|---|---|---|---|---|---|---|---|
| N3.0 | 19.42 | 12.98 | 50.50 | 1.137 | 1.068 | 1.128 | 232.0 | |
| 500 | 22.51 (22.48–22.53) F/P | 19.44 (16.21–21.75) F/P | 8.49 (8.13–8.83) P/P | 0.171 (0.166–0.178) P/P | 0.297 (0.251–0.336) P/P | 0.167 (0.162–0.173) F/P | 347.3 (67.2–1463.4) | FAIL / PASS |
| 1000 (default) | 22.51 (22.48–22.53) F/P | 19.44 (16.21–21.75) F/P | 8.11 (7.20–9.60) P/P | 0.171 (0.166–0.178) P/P | 0.297 (0.251–0.336) P/P | 0.167 (0.162–0.173) F/P | 68.7 (67.4–69.7) | FAIL / PASS |
| 2000 | 22.51 (22.48–22.53) F/P | 19.44 (16.21–21.75) F/P | 4024.39 (8.49–7962.08) F/F | 0.171 (0.166–0.178) P/P | 0.297 (0.251–0.336) P/P | 0.167 (0.162–0.173) F/P | 68.7 (67.4–69.7) | FAIL / FAIL |

**roadEngageMaxEllipseM: consistency (+ truth σ, gated; mean over seeds, %), roads, convergence, timing**

| value | cons cl / c / m / jA / jB / d7 / m3 | wrong road fixes / distance: clean-long; clean; drive-7 (info) | unmapped (far + incompatible) / captured (far + incompatible), per seed: clean; drive-7 | manual conv km | drive-7 worst fix > 1800 s m (range) | ms/step seed 1 (min–max over drives; max ingest ms) |
|---|---|---|---|---|---|---|
| N3.0 | 100.0 / 100.0 / 100.0 / 100.0 / 100.0 / 99.6 / 66.7 | n/a | n/a | 7.59 | 224.0 | 0.065–0.073 (not sequential) |
| 500 | 96.4 / 100.0 / 100.0 / 100.0 / 100.0 / 87.4 / 53.3 | 1.3 / 0.5 %; 2.5 / 2.4 % (1.9–2.8); 5.7 / 3.6 % (3.5–3.7) | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+10, 0+10, 0+10, 0+10, 0+10 | 1.65 | 32.8 (31.9–34.1) | 0.090–0.114 (2.6) |
| 1000 (default) | 96.4 / 100.0 / 100.0 / 100.0 / 100.0 / 87.4 / 66.7 | 1.3 / 0.5 %; 2.5 / 2.4 % (1.9–2.8); 5.7 / 3.6 % (3.5–3.7) | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+10, 0+10, 0+10, 0+10, 0+10 | 1.52 | 32.8 (31.9–34.1) | 0.090–0.115 (4.4) |
| 2000 | 96.4 / 100.0 / 26.7 / 100.0 / 100.0 / 87.4 / 66.7 | 1.3 / 0.5 %; 2.5 / 2.4 % (1.9–2.8); 5.7 / 3.6 % (3.5–3.7) | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+10, 0+10, 0+10, 0+10, 0+10 | 1.44–1.68 | 32.8 (31.9–34.1) | 0.090–0.114 (8.0) |

#### roadAlongTrackCoupling {0, 1}

**roadAlongTrackCoupling: gated criterion, mean (range) over seeds 1–5; adoption rule (judge.py) vs N3.0 / vs N3.2b default**

| value | clean-long max m | clean max m | manual pt 1 m | jammed-A end % | jammed-B end % | drive-7 worst fix > 1800 s % | manual-3 pins m (sanity) | all gated |
|---|---|---|---|---|---|---|---|---|
| N3.0 | 19.42 | 12.98 | 50.50 | 1.137 | 1.068 | 1.128 | 232.0 | |
| 0 (default) | 22.51 (22.48–22.53) F/P | 19.44 (16.21–21.75) F/P | 8.11 (7.20–9.60) P/P | 0.171 (0.166–0.178) P/P | 0.297 (0.251–0.336) P/P | 0.167 (0.162–0.173) F/P | 68.7 (67.4–69.7) | FAIL / PASS |
| 1 | 25.09 (25.06–25.12) F/F | 22.74 (20.49–26.15) F/F | 8.60 (7.27–10.22) P/P | 0.170 (0.165–0.180) P/P | 0.309 (0.245–0.375) P/P | 0.181 (0.179–0.183) F/F | 68.2 (67.3–69.5) | FAIL / FAIL |

**roadAlongTrackCoupling: consistency (+ truth σ, gated; mean over seeds, %), roads, convergence, timing**

| value | cons cl / c / m / jA / jB / d7 / m3 | wrong road fixes / distance: clean-long; clean; drive-7 (info) | unmapped (far + incompatible) / captured (far + incompatible), per seed: clean; drive-7 | manual conv km | drive-7 worst fix > 1800 s m (range) | ms/step seed 1 (min–max over drives; max ingest ms) |
|---|---|---|---|---|---|---|
| N3.0 | 100.0 / 100.0 / 100.0 / 100.0 / 100.0 / 99.6 / 66.7 | n/a | n/a | 7.59 | 224.0 | 0.065–0.073 (not sequential) |
| 0 (default) | 96.4 / 100.0 / 100.0 / 100.0 / 100.0 / 87.4 / 66.7 | 1.3 / 0.5 %; 2.5 / 2.4 % (1.9–2.8); 5.7 / 3.6 % (3.5–3.7) | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+10, 0+10, 0+10, 0+10, 0+10 | 1.52 | 32.8 (31.9–34.1) | 0.090–0.115 (4.4) |
| 1 | 95.2 / 99.7 / 100.0 / 100.0 / 100.0 / 81.5 / 66.7 | 0.7 / 0.2 %; 2.8 / 2.8 %; 6.5 / 3.8 % (3.7–3.9) | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+11, 0+11, 0+11, 0+11, 0+11 | 1.52 | 35.6 (35.2–36.0) | 0.090–0.113 (4.6) |

#### Fix gate on and off

**Fix gate: gated criterion, mean (range) over seeds 1–5; adoption rule (judge.py) vs N3.0 / vs N3.2b default**

| value | clean-long max m | clean max m | manual pt 1 m | jammed-A end % | jammed-B end % | drive-7 worst fix > 1800 s % | manual-3 pins m (sanity) | all gated |
|---|---|---|---|---|---|---|---|---|
| N3.0 | 19.42 | 12.98 | 50.50 | 1.137 | 1.068 | 1.128 | 232.0 | |
| on (default, roadFixGateSigma 3) | 22.51 (22.48–22.53) F/P | 19.44 (16.21–21.75) F/P | 8.11 (7.20–9.60) P/P | 0.171 (0.166–0.178) P/P | 0.297 (0.251–0.336) P/P | 0.167 (0.162–0.173) F/P | 68.7 (67.4–69.7) | FAIL / PASS |
| off (roadFixGateSigma 0) | 22.51 (22.48–22.53) F/P | 19.44 (16.21–21.75) F/P | 8.11 (7.20–9.60) P/P | 0.171 (0.166–0.178) P/P | 0.297 (0.251–0.336) P/P | 0.167 (0.162–0.173) F/P | 68.7 (67.4–69.7) | FAIL / PASS |

**Fix gate: consistency (+ truth σ, gated; mean over seeds, %), roads, convergence, timing**

| value | cons cl / c / m / jA / jB / d7 / m3 | wrong road fixes / distance: clean-long; clean; drive-7 (info) | unmapped (far + incompatible) / captured (far + incompatible), per seed: clean; drive-7 | manual conv km | drive-7 worst fix > 1800 s m (range) | ms/step seed 1 (min–max over drives; max ingest ms) |
|---|---|---|---|---|---|---|
| N3.0 | 100.0 / 100.0 / 100.0 / 100.0 / 100.0 / 99.6 / 66.7 | n/a | n/a | 7.59 | 224.0 | 0.065–0.073 (not sequential) |
| on (default, roadFixGateSigma 3) | 96.4 / 100.0 / 100.0 / 100.0 / 100.0 / 87.4 / 66.7 | 1.3 / 0.5 %; 2.5 / 2.4 % (1.9–2.8); 5.7 / 3.6 % (3.5–3.7) | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+10, 0+10, 0+10, 0+10, 0+10 | 1.52 | 32.8 (31.9–34.1) | 0.090–0.115 (4.4) |
| off (roadFixGateSigma 0) | 96.4 / 100.0 / 100.0 / 100.0 / 100.0 / 87.4 / 66.7 | 1.3 / 0.5 %; 2.5 / 2.4 % (1.9–2.8); 5.7 / 3.6 % (3.5–3.7) | 83 + 0 / 0+0, 0+0, 0+0, 0+0, 0+0; 0 + 44 / 0+10, 0+10, 0+10, 0+10, 0+10 | 1.52 | 32.8 (31.9–34.1) | 0.090–0.114 (4.7) |

#### Does any value pass clean and clean-long and keep the gains?

**No single value does.** Against N3.0 the adoption rule needs clean-long
≤ 21.42 m and clean ≤ 14.98 m (mean; +2 m allowed on 19.42 / 12.98 m), both
at 100 % consistency:
- **Three values pass one of the two clean drives, and none passes both.**
  - roadSigmaM 10 passes clean-long (21.09 m, 100 %) and fails clean
    (25.98 m, 99.4 %).
  - roadSigmaM 3.0 passes clean (14.17 m, 100 %) and fails clean-long
    (25.88 m, 96.0 %).
  - roadCorrelationM 100 passes clean-long (19.38 m, 100 %) and fails clean
    by 0.02 m (15.00 m, 100 %).

  σ moves the two clean drives in opposite directions, monotonically
  (clean-long 25.88 → 21.09 m and clean 14.17 → 25.98 m from 3 to 10).
- **roadCorrelationM 100 is the nearest miss.**
  - Clean per seed: 14.61 / 14.57 / 11.74 / 19.22 / 14.85 m, against N3.0's
    12.24 / 10.67 / 16.46 / 12.33 / 13.21 m.
  - It keeps every gain: manual 7.23 m, jammed-A 0.176 %, jammed-B
    0.201 %, drive-7 0.166 %.
  - Against the N3.2b default it improves every gated mean except
    jammed-A (+0.005 pp), and it lifts drive-7's consistency from 87.4 to
    92.7 %.
- **drive-7's consistency fails against N3.0 for every value of every
  grid:** 65.7–92.7 % against 99.6 %, 80.6–92.7 % without
  roadCorrelationM 10. So no value in the grids passes the adoption rule
  against N3.0 on all gated drives. It is the N3.2b FAIL, made smaller or
  larger.
- **Against the N3.2b default** these pass every gated drive:
  roadOffRoadProbability 0.3, roadCorrelationM 100, roadEngageMaxEllipseM
  500 (identical except manual and manual-3), and the fix gate off
  (identical).

**Trade-off of the best candidates against N3.0** (means over seeds 1–5;
"error cut" = the share of N3.0's error removed):

| candidate | clean-long Δ m (allowed +2) | clean Δ m (allowed +2) | consistency + σ clean-long / clean / drive-7 (N3.0 100 / 100 / 99.6) | manual pt 1 Δ m | jammed-A Δ pp (error cut) | jammed-B Δ pp (error cut) | drive-7 Δ pp (error cut) |
|---|---:|---:|---|---:|---:|---:|---:|
| default (N3.2b) | +3.09 | +6.46 | 96.4 / 100.0 / 87.4 | -42.38 | -0.966 (85 %) | -0.771 (72 %) | -0.961 (85 %) |
| roadCorrelationM 100 | -0.04 | +2.02 | 100.0 / 100.0 / 92.7 | -43.27 | -0.960 (84 %) | -0.866 (81 %) | -0.962 (85 %) |
| roadSigmaM 10 | +1.68 | +13.00 | 100.0 / 99.4 / 89.2 | -42.85 | -0.964 (85 %) | -0.833 (78 %) | -0.976 (87 %) |
| roadSigmaM 3.0 | +6.47 | +1.19 | 96.0 / 100.0 / 86.3 | -41.98 | -0.984 (87 %) | -0.657 (62 %) | -0.416 (37 %) |
| roadOffRoadProbability 0.3 | +2.81 | +3.26 | 96.4 / 100.0 / 89.4 | -42.25 | -0.966 (85 %) | -0.755 (71 %) | -0.990 (88 %) |

- **default:** costs +3.1 m on clean-long and +6.5 m on clean. In return
  it cuts 85 % of the error on jammed-A, 72 % on jammed-B and 85 % on
  drive-7.
- **roadCorrelationM 100:** costs −0.04 m on clean-long and +2.02 m on
  clean (0.02 m over the allowance). It cuts 84 % / 81 % / 85 %, and
  drive-7's consistency is 92.7 % against 99.6 %.
- **roadSigmaM 10:** costs +1.7 m / +13.0 m for 85 % / 78 % / 87 %.
- **roadSigmaM 3.0:** costs +6.5 m / +1.2 m, and gives up most of drive-7's
  gain (37 %): it is captured at the service-road end, below.
- **Passing one clean drive costs the other.** σ 10 passes clean-long and
  loses 13.0 m on clean. σ 3.0 passes clean and loses 6.5 m on clean-long,
  plus most of drive-7's gain. Only roadCorrelationM 100 comes within
  0.02 m on both.
- The jammed-A/B cuts stay at 62–87 % across these candidates, and
  drive-7's at 85–88 % (except σ 3.0, 37 %).
- The grids are one factor at a time, so no combination was run.

#### Anomalies and observations

- **Fix gate:** it never fires on this set. `fixesRejectedOffRoad` is 0 on
  every default run, and "off" is identical on all 30 runs (35 GeoJSON
  byte-identical, every checkpoint and counter equal). The set cannot
  measure the gate.
- **roadEngageMaxEllipseM:** only manual changes (and manual-3 at 500).
  Clean, clean-long, jammed-A/B and drive-7 are GeoJSON byte-identical to
  the default: their clouds are under 500 m whenever a road update would
  run.
  - **2000: the seeds disagree, catastrophically.** On manual, seeds 1 and 5
    reach truth point 1 at 10.9 m and 8.5 m. Seeds 2–4 reach it at
    7.87 / 7.96 / 4.27 km, so the criterion (≤ 200 m) fails on three
    seeds, and manual consistency falls to 26.7 %. Each of seeds 2–5 has
    a manual reset at the pin, whose prior is 0.45–1.03 km off (default:
    0.19–0.35 km, no reset). Road updates now run on a cloud up to 2 km
    wide. Why seeds 2–4 stay kilometres off after the reset was not
    investigated (measure, don't tune).
  - **500, manual-3 (sanity) seed 4:** three manual resets, pins 870 /
    2906 / 614 m. The other seeds score 19–100 m, so the mean is 347 m.
    Not gated, and not investigated further (never tuned toward manual-3).
- **roadCorrelationM 10 fails a criterion on every seed.** Clean reaches
  72.5 m (≤ 30 m allowed), with consistency 63 %. At ≈ 369 s the truth
  leaves every heading-compatible road (the end of the drive), and the
  estimate is captured on a mapped edge and carried 73 m away. It then
  parks there (ZUPT) until the end, so 72 m holds on every seed. Its seeds
  also disagree: jammed-B 0.021–0.493 %, drive-7 0.79–1.54 %.
- **roadSigmaM 3.0, drive-7:** the worst fix is 137–140 m, at 2054 s on
  seed 1, against 32.8 m for the default. It falls in the 2027–2076 s
  service-road stretch: the truth is `noRoad`/incompatible, the estimate
  sits on a mapped edge up to 157 m from the truth, and `onRoadShare`
  reaches 0.9. This is the capture risk R2 on real data. Clean also shows
  one captured far fix on 4 of 5 seeds.
- **roadUpdateIntervalS, "does a higher rate help":** no.
  - Clean-long improves by 0.4–0.6 m and still fails against N3.0.
  - Manual worsens (8.1 → 9.0–10.0 m), and so does drive-7 (0.167 →
    0.177–0.186 %). Its consistency is 87.9 / 86.7 / 86.7 % against
    87.4 %.
  - Clean moves within seed noise and not monotonically (20.76 / 20.29 /
    21.60 m, seed ranges overlapping 15.6–26.9 m).
  - At 0.1 s manual's convergence reaches 2.07 km on seed 4, over the
    2 km N3 target.
  - Cost: 0.44 ms per extra road update. The Mac proxy is ≤ 0.15 ms/step
    per drive: 0.5 s exceeds it on jammed-A, jammed-B and drive-7 (0.156),
    and 0.2 s and 0.1 s on every drive.
  - The largest single `ingest` is 4.4–4.6 ms in every configuration, the
    default included, as in N3.2b.
- **roadAlongTrackCoupling 1** is worse than 0 on clean-long (+2.6 m),
  clean (+3.3 m) and drive-7 (consistency 81.5 %).
- **Not monotone, within seed noise:** clean against roadSplitSigmaM
  (21.22 / 19.44 / 21.53 m, the default best, ranges overlapping). drive-7
  against roadSigmaM: a cliff at 3.0, then flat (0.157 / 0.167 /
  0.151 %).
- **Seeds disagree on drive-7 under roadCorrelationM 100:** the worst fix is
  22.8–52.8 m and consistency 233–268 of 273. Seeds 1 and 5 peak at 1980 s;
  seeds 2–4 at the end (2082–2098 s).
- **clean-long** is almost seed-independent in every configuration (range
  ≤ 0.3 m). Its maximum is the creeping last 11 s (N3.2b).
- **Every per-seed N3 criterion passes** except roadCorrelationM 10 (clean,
  every seed), roadEngageMaxEllipseM 2000 (manual, seeds 2–4) and the
  manual convergence at roadUpdateIntervalS 0.1 (seed 4). Clean's
  wrong-road share stays ≤ 3.4 % by distance everywhere (target ≤ 5 %,
  provisional).

### N3.2e item 1: level rule across packs (2026-10-14)

**Change (engine).** The level rule's adjacency (rule 3, docs/N3_PLAN.md
"Layer, bridge and tunnel rule") now spans packs: `RoadNetwork.adjacentEdges`.
Within a pack it is the pack's own adjacency, unchanged. Two edges in
different packs are adjacent (one hop) when they share an OSM node:
- **same way node:** the same `osmWayID`, and their way-node index ranges
  (`wayPointOffset` … `wayPointOffset + pointCount − 1`) intersect. A pack
  stores no OSM node IDs (`NODE` holds coordinates only; the builder's
  node IDs are not written), so this is the pack-independent node identity
  the format does carry, the one segment keys use;
- **equal coordinate:** a point with equal E7 coordinates on both edges that
  is an end (a topological node) of at least one of them. Equal means equal:
  a point 1 E7 unit (about 1 cm) away does not link.

The adjacency is a function of the pack set only, so results stay
independent of pack order. With one pack the network asks the pack directly,
as before. The hop answers are memoised within one road update (lookup only,
a pure function, so no result can change). No config key changed.

**Tests** (`RoadLevelAcrossPacksTests`, synthetic packs near (0, 0)): a street
in one pack ending on another pack's bridge (equal E7, different node IDs),
in both directions; the same way node in two packs whose coordinates all
differ by 1 E7 unit (admitted at 2 hops, blocked at 1); a bridge 1 E7 unit
from the street's end (still blocked, at any hop count); `adjacentEdges`
itself (expected links, symmetric, independent of order, one pack equal to
`RoadPack.isEdge` for hops 0–3); and a drive from the street onto the bridge
(never level-blocked, on the bridge 50 m past the junction, both pack orders).
Run against the engine before the change (tests first, engine change
after), the coordinate, way-node and drive tests fail with 10 issues: every
particle blocked, bridge share 0.0 at 50 m. The non-match test passes
before and after, as a negative test should. The stacked-bridge test 5,
the hop-boundary test and the two-pack test still pass.

**Replay.** Default config, packs national + region-A (`roadSetHash` prefix
`fecadb9b`), release build on the Mac, seeds 1–5 in arrival order, the eight
acceptance runs in their acceptance modes. "N3.2b default" was re-run with the
build before this change (4a4d697): it reproduces `logs/n32b/roads` and the
drive-8 roads baseline exactly (every GeoJSON byte; `metrics.json` equal
except the N3.2c item-2 unmapped fields the N3.2b files predate). Outputs and
scripts: `logs/n32e/` (git-ignored). Values are the gated criterion (clean-long,
clean, manual in metres; the rest in % of distance); manual-3 is the mean of
its three pin errors, sanity only.

| alias | criterion | N3.2b default, mean (range) | item 1, mean (range) | Δ mean | allowed | + truth σ (gated), N3.2b → item 1 | engine ellipse | verdict vs N3.2b default | verdict vs N3.0 | levelBlocked, seed 1 (range 1–5), N3.2b → item 1 | wrong road by distance | ms/step seed 1 |
|---|---|---|---|---:|---|---|---|---|---|---|---|---|
| clean-long | max ≤ 30 m | 22.51 (22.48–22.53) m | 22.51 (22.48–22.53) m | +0.00 | +2.00 m | 96.4 → 96.4 % | 96.0 → 96.0 % | PASS | FAIL (mean, consistency) | 0 (0–0) → 0 (0–0) | 0.5 → 0.5 % | 0.097 → 0.098 |
| clean | max ≤ 30 m | 19.44 (16.21–21.75) m | 15.34 (13.69–16.00) m | -4.10 | +2.00 m | 100.0 → 100.0 % | 98.5 → 100.0 % | PASS | FAIL (mean) | 23818 (22000–23818) → 0 (0–0) | 2.4 → 0.0 % | 0.090 → 0.089 |
| manual | truth point 1 ≤ 200 m | 8.11 (7.20–9.60) m | 8.11 (7.20–9.60) m | +0.00 | +2.00 m | 100.0 → 100.0 % | 100.0 → 100.0 % | PASS | PASS | 237 (97–411) → 236 (97–411) | n/a | 0.109 → 0.108 |
| manual-3 | pins, mean (sanity) | 68.73 (67.38–69.72) m | 68.26 (66.89–69.23) m | -0.48 | +3.44 m | 66.7 → 66.7 % | 33.3 → 33.3 % | not gated | not gated | 8596 (8061–9399) → 964 (337–2075) | n/a | 0.110 → 0.109 |
| jammed-A | end ≤ 2.5 % | 0.171 (0.166–0.178) % | 0.171 (0.164–0.178) % | -0.000 | +0.1 pp | 100.0 → 100.0 % | 0.0 → 0.0 % | PASS | PASS | 8871 (8271–10015) → 2917 (2382–4054) | n/a | 0.114 → 0.113 |
| jammed-B | end ≤ 2.5 % | 0.297 (0.251–0.336) % | 0.297 (0.251–0.336) % | +0.000 | +0.1 pp | 100.0 → 100.0 % | 100.0 → 100.0 % | PASS | PASS | 0 (0–1) → 0 (0–1) | n/a | 0.112 → 0.114 |
| drive-7 | worst withheld clean fix ≤ 2.5 % | 0.167 (0.162–0.173) % | 0.168 (0.162–0.178) % | +0.002 | +0.1 pp | 87.4 → 87.2 % | 86.0 → 85.7 % | FAIL (consistency) | FAIL (consistency) | 12859 (12859–13683) → 5453 (5453–6049) | 3.6 → 3.6 % | 0.115 → 0.114 |
| drive-8 | worst scored withheld clean fix ≤ 2.5 % | 0.178 (0.177–0.179) % | 0.178 (0.177–0.179) % | -0.000 | +0.1 pp | 99.6 → 99.6 % | 98.1 → 98.1 % | PASS | FAIL (consistency) | 10723 (10524–11057) → 4083 (3810–4220) | 0.0 → 0.0 % | 0.109 → 0.110 |

- **Adoption rule against the N3.2b default: FAIL, on drive-7's consistency
  only** (87.4 → 87.2 %, mean over seeds; must not drop). Its gated mean
  passes (+0.002 pp, allowed +0.1), and every per-seed criterion passes on
  every drive.
  - The drop is one clean fix on each of seeds 1, 4 and 5 (seeds 2 and 3
    unchanged), at 2090.0 / 2093.0 / 2091.0 s, 19.76–19.78 km: the
    service-road end of the drive, where N3.2b already misses 33–36 of 273.
    Each is on the ellipse's edge: error 26.1 → 26.3, 27.0 → 27.5,
    26.4 → 26.8 m against a semi-major axis of 26.0, 27.0, 26.4 m.
  - Mechanism: from the first pin (706 s) a level decision changes, the
    resampling draws a different realisation, and every later checkpoint
    moves a little (271 of 273 differ). The three flips are that noise
    at boundary checkpoints, not a new miss region. Measured, not explained
    away: under the rule it is a FAIL, and adopting it is the user's call.
  - **Accepted by the user as a correctness fix on 2026-10-14.** It stays in
    the engine despite the drive-7 consistency FAIL: `roadLevelBlocked` on
    clean 23 818 → 0, clean wrong road 2.4 → 0 %, clean max 19.44 → 15.34 m.
    The rule is unchanged.
- **Against N3.0** the verdicts are those of the N3.2b default except clean,
  which improves but still fails by 0.36 m: clean-long (+3.09 m; 96.4 %),
  clean (+2.36 m, allowed +2), drive-7 (87.2 % against 99.6 %) and drive-8
  (99.6 % against 100 %, as in its with-roads baseline) fail; manual,
  jammed-A and jammed-B pass.
- **Every change, explained.**
  - clean: `roadLevelBlocked` 23 818 → 0 on seed 1 (0 on every seed), wrong
    road 2.4 → 0.0 % by distance, max 19.44 → 15.34 m mean. Seed 1 gives
    15.63 m, the region-A-first value N3.2c item 7 measured (15.6 m): the
    block that pack order caused is gone.
  - manual-3, jammed-A, drive-7 and drive-8 change: their `roadLevelBlocked`
    falls by 56–96 % per seed (drive-7 56–58 %, jammed-A 60–71 %, drive-8
    62–64 %, manual-3 78–96 %), and their criteria move within seed noise.
  - clean-long and jammed-B are bit-identical (every GeoJSON byte). manual's
    GeoJSON is byte-identical; only its `roadLevelBlocked` counter changes, on
    seeds 1 and 5 (237 → 236, 191 → 189): a candidate now admitted was not
    the best one.
  - What still blocks (jammed-A 2382–4054, drive-7 5453–6049, drive-8
    3810–4220 per seed) is a level change more than 2 hops away in the
    joined graph. Not investigated further.
- **Pack order:** region-A first against national first, seed 1, all eight
  drives: `metrics.json` equal (timing aside) and every GeoJSON byte
  identical (`logs/n32e/order-check.txt`).
- **Without roads:** 35 of 35 runs (seeds 1–5, all eight drives) equal to the
  build before the change (`metrics.json` timing aside, every GeoJSON byte),
  and every GeoJSON byte-identical to the N3.0 references (`logs/n30/p3/r2011`,
  and drive-8's no-roads baseline).
- **Timing:** ms/step (seed 1, sequential) 0.089–0.114, unchanged within
  ±0.002 per drive. Largest single `ingest` 0.85–4.52 ms (before 1.11–4.64).
  `NavigationRoadPerfTests` (release, one pack, 3 runs): mean
  0.366–0.368 ms, max 0.646–0.682 ms (N3.2c: 0.366–0.369 / 0.650–0.765).

### N3.2e: candidates on the cross-pack level rule (2026-10-14)

The four declared candidates, re-run on the item-1 engine, and nothing else:
the default, `roadCorrelationM` 100, `roadSigmaM` 10 and `roadSigmaM` 3.0 (the
residual value). **A measurement, not an adoption: no config was chosen and no
default was changed. The choice is open for the user.**

- **Setup.** Packs national + region-A (`roadSetHash` prefix `fecadb9b`),
  release build of the item-1 engine (ecf4f31) on the Mac, seeds 1–5 in
  arrival order, all eight acceptance runs in their acceptance modes (drive-8
  `--gps mask-after 785`, scored to its `scoreUntilT`). Seed 1 ran alone (the
  ms/step below), then seeds 2 + 3 and 4 + 5. Outputs and scripts:
  `logs/n32e/` (git-ignored; `tradeoff.py`, `misses.py`, `lib.py`).
- **References.** N3.0 is the N3.0 exit runs, and for drive-8 its no-roads
  baseline (1.482 %, 100 %). Without roads this build reproduces both byte for
  byte (item 1). "N3.2b default" is the default config on the build before item
  1 (re-run, identical to N3.2b; drive-8 0.178 %, 99.6 %).
- **Reading the table.** "Δ mean vs N3.0" is the mean rule alone (+2 m or 5 %
  for metre drives, +0.1 pp for % drives); "adoption" adds the criterion on
  every seed and the gated consistency (with the truth's σ) not dropping.
  Wrong road is for the clean drives only and stays provisional (clean's road
  truth is 20.3 % ambiguous). Unmapped is far + incompatible (N3.2c item 2),
  captured per seed. "converged" is the heading convergence distance; manual's
  N3 target is ≤ 2 km on every seed. manual-3 is the mean of its three pin
  errors, sanity only, never gated.

**(A) short DR stretches, engine already accurate**

| drive | candidate | gated value, mean (range) | Δ mean vs N3.0 (allowed) | consistency + truth σ, mean % (gated) | engine ellipse % | adoption vs N3.0 | adoption vs N3.2b default | wrong road, fixes / distance | unmapped far+incompatible / captured per seed | converged km (seeds) | ms/step seed 1 |
|---|---|---|---|---|---:|---|---|---|---|---|---:|
| clean | default | 15.34 (13.69–16.00) m | +2.36 (≤ +2.00) FAIL | 100.0 (N3.0 100.0) PASS | 100.0 | FAIL | PASS | 0.0 / 0.0 % (prov.) | 83+0 / 0,0,0,0,0 | 0.04 | 0.089 |
| clean | roadCorrelationM 100 | 14.39 (11.81–18.82) m | +1.40 (≤ +2.00) PASS | 100.0 (N3.0 100.0) PASS | 100.0 | PASS | PASS | 0.0 / 0.0 % (prov.) | 83+0 / 0,0,0,0,0 | 0.03 | 0.091 |
| clean | roadSigmaM 10 | 24.18 (23.34–25.54) m | +11.20 (≤ +2.00) FAIL | 100.0 (N3.0 100.0) PASS | 100.0 | FAIL | FAIL | 0.0 / 0.0 % (prov.) | 83+0 / 0,0,0,0,0 | 0.04 | 0.090 |
| clean | roadSigmaM 3.0 | 14.08 (13.38–15.51) m | +1.10 (≤ +2.00) PASS | 100.0 (N3.0 100.0) PASS | 99.6 | PASS | PASS | 0.0 / 0.0 % (prov.) | 83+0 / 1,1,1,0,1 | 0.04 | 0.087 |
| clean-long | default | 22.51 (22.48–22.53) m | +3.09 (≤ +2.00) FAIL | 96.4 (N3.0 100.0) FAIL | 96.0 | FAIL | PASS | 1.3 / 0.5 % (prov.) | 0+0 / 0,0,0,0,0 | 0.02 | 0.098 |
| clean-long | roadCorrelationM 100 | 19.38 (19.22–19.50) m | -0.04 (≤ +2.00) PASS | 100.0 (N3.0 100.0) PASS | 100.0 | PASS | PASS | 1.3 / 0.5 % (prov.) | 0+0 / 0,0,0,0,0 | 0.02 | 0.095 |
| clean-long | roadSigmaM 10 | 21.09 (21.07–21.13) m | +1.68 (≤ +2.00) PASS | 100.0 (N3.0 100.0) PASS | 100.0 | PASS | PASS | 1.3 / 0.5 % (prov.) | 0+0 / 0,0,0,0,0 | 0.02 | 0.095 |
| clean-long | roadSigmaM 3.0 | 25.88 (25.85–25.91) m | +6.47 (≤ +2.00) FAIL | 96.0 (N3.0 100.0) FAIL | 95.7 | FAIL | FAIL | 0.0 / 0.0 % (prov.) | 0+0 / 0,0,0,0,0 | 0.02 | 0.092 |

**(B) long DR stretches or jamming**

| drive | candidate | gated value, mean (range) | Δ mean vs N3.0 (allowed) | consistency + truth σ, mean % (gated) | engine ellipse % | adoption vs N3.0 | adoption vs N3.2b default | wrong road, fixes / distance | unmapped far+incompatible / captured per seed | converged km (seeds) | ms/step seed 1 |
|---|---|---|---|---|---:|---|---|---|---|---|---:|
| manual | default | 8.11 (7.20–9.60) m | -42.38 (≤ +2.52) PASS | 100.0 (N3.0 100.0) PASS | 100.0 | PASS | PASS | – | – | 1.52 | 0.108 |
| manual | roadCorrelationM 100 | 7.23 (5.81–10.02) m | -43.27 (≤ +2.52) PASS | 100.0 (N3.0 100.0) PASS | 100.0 | PASS | PASS | – | – | 1.52–1.58 | 0.109 |
| manual | roadSigmaM 10 | 7.64 (6.37–9.90) m | -42.85 (≤ +2.52) PASS | 100.0 (N3.0 100.0) PASS | 100.0 | PASS | PASS | – | – | 1.52 | 0.111 |
| manual | roadSigmaM 3.0 | 8.52 (8.10–9.33) m | -41.98 (≤ +2.52) PASS | 100.0 (N3.0 100.0) PASS | 86.7 | PASS | PASS | – | – | 1.52 | 0.106 |
| manual-3 | default | 68.26 (66.89–69.23) m | -163.78 (not gated) | 66.7 (N3.0 66.7) | 33.3 | – | – | – | – | 0.37 | 0.109 |
| manual-3 | roadCorrelationM 100 | 68.37 (66.50–70.20) m | -163.66 (not gated) | 66.7 (N3.0 66.7) | 26.7 | – | – | – | – | 0.41–0.48 | 0.113 |
| manual-3 | roadSigmaM 10 | 68.57 (66.94–70.55) m | -163.46 (not gated) | 66.7 (N3.0 66.7) | 26.7 | – | – | – | – | 0.37 | 0.114 |
| manual-3 | roadSigmaM 3.0 | 68.23 (66.82–69.93) m | -163.80 (not gated) | 66.7 (N3.0 66.7) | 26.7 | – | – | – | – | 0.27–0.37 | 0.108 |
| jammed-A | default | 0.171 (0.164–0.178) % | -0.966 (≤ +0.1) PASS | 100.0 (N3.0 100.0) PASS | 0.0 | PASS | PASS | – | – | 0.30–0.31 | 0.113 |
| jammed-A | roadCorrelationM 100 | 0.177 (0.170–0.182) % | -0.960 (≤ +0.1) PASS | 100.0 (N3.0 100.0) PASS | 100.0 | PASS | PASS | – | – | 0.74–0.92 | 0.117 |
| jammed-A | roadSigmaM 10 | 0.172 (0.166–0.179) % | -0.964 (≤ +0.1) PASS | 100.0 (N3.0 100.0) PASS | 100.0 | PASS | PASS | – | – | 0.31–0.33 | 0.115 |
| jammed-A | roadSigmaM 3.0 | 0.152 (0.138–0.159) % | -0.985 (≤ +0.1) PASS | 100.0 (N3.0 100.0) PASS | 0.0 | PASS | PASS | – | – | 0.29–0.31 | 0.111 |
| jammed-B | default | 0.297 (0.251–0.336) % | -0.771 (≤ +0.1) PASS | 100.0 (N3.0 100.0) PASS | 100.0 | PASS | PASS | – | – | 0.19–0.22 | 0.114 |
| jammed-B | roadCorrelationM 100 | 0.201 (0.171–0.245) % | -0.866 (≤ +0.1) PASS | 100.0 (N3.0 100.0) PASS | 100.0 | PASS | PASS | – | – | 0.43–0.44 | 0.116 |
| jammed-B | roadSigmaM 10 | 0.235 (0.203–0.270) % | -0.833 (≤ +0.1) PASS | 100.0 (N3.0 100.0) PASS | 100.0 | PASS | PASS | – | – | 0.22–0.22 | 0.113 |
| jammed-B | roadSigmaM 3.0 | 0.411 (0.354–0.454) % | -0.657 (≤ +0.1) PASS | 100.0 (N3.0 100.0) PASS | 100.0 | PASS | FAIL | – | – | 0.19 | 0.110 |
| drive-7 | default | 0.168 (0.162–0.178) % | -0.960 (≤ +0.1) PASS | 87.2 (N3.0 99.6) FAIL | 85.7 | FAIL | FAIL | – | 0+44 / 10,10,10,10,10 | 0.14 | 0.114 |
| drive-7 | roadCorrelationM 100 | 0.130 (0.123–0.148) % | -0.998 (≤ +0.1) PASS | 96.3 (N3.0 99.6) FAIL | 95.2 | FAIL | PASS | – | 0+44 / 1,1,1,2,1 | 0.14 | 0.117 |
| drive-7 | roadSigmaM 10 | 0.154 (0.147–0.164) % | -0.974 (≤ +0.1) PASS | 88.9 (N3.0 99.6) FAIL | 87.5 | FAIL | PASS | – | 0+44 / 7,7,7,7,7 | 0.14 | 0.117 |
| drive-7 | roadSigmaM 3.0 | 0.714 (0.707–0.721) % | -0.414 (≤ +0.1) PASS | 86.3 (N3.0 99.6) FAIL | 84.5 | FAIL | FAIL | – | 0+44 / 11,10,9,10,10 | 0.14 | 0.111 |
| drive-8 | default | 0.178 (0.177–0.179) % | -1.304 (≤ +0.1) PASS | 99.6 (N3.0 100.0) FAIL | 98.1 | FAIL | PASS | – | 0+0 / 0,0,0,0,0 | 0.39–0.41 | 0.110 |
| drive-8 | roadCorrelationM 100 | 0.186 (0.184–0.188) % | -1.295 (≤ +0.1) PASS | 100.0 (N3.0 100.0) PASS | 100.0 | PASS | PASS | – | 0+0 / 0,0,0,0,0 | 0.66–0.68 | 0.115 |
| drive-8 | roadSigmaM 10 | 0.179 (0.178–0.181) % | -1.303 (≤ +0.1) PASS | 100.0 (N3.0 100.0) PASS | 99.5 | PASS | PASS | – | 0+0 / 0,0,0,0,0 | 0.52 | 0.114 |
| drive-8 | roadSigmaM 3.0 | 0.201 (0.199–0.203) % | -1.281 (≤ +0.1) PASS | 97.8 (N3.0 100.0) FAIL | 90.7 | FAIL | FAIL | – | 0+0 / 0,0,0,0,0 | 0.29–0.38 | 0.107 |

**Overall: adoption rule over the seven gated drives**

| candidate | vs N3.0 | failing drives vs N3.0 | vs N3.2b default | failing drives vs N3.2b default | ms/step seed 1 (min–max) | max single ingest ms |
|---|---|---|---|---|---|---:|
| default | FAIL | clean-long, clean, drive-7, drive-8 | FAIL | drive-7 | 0.089–0.114 | 4.52 |
| roadCorrelationM 100 | FAIL | drive-7 | PASS | – | 0.091–0.117 | 4.55 |
| roadSigmaM 10 | FAIL | clean, drive-7 | FAIL | clean | 0.090–0.117 | 4.88 |
| roadSigmaM 3.0 | FAIL | clean-long, drive-7, drive-8 | FAIL | clean-long, jammed-B, drive-7, drive-8 | 0.087–0.111 | 4.53 |

**No candidate passes the adoption rule against N3.0 on every gated drive.**
roadCorrelationM 100 is the only one that passes against the N3.2b default on
every gated drive, and it fails against N3.0 on one: drive-7's consistency.

**(a) The best candidate, as an explicit trade-off: roadCorrelationM 100.**
Means over seeds 1–5, against N3.0:
- **Costs:** drive-7's consistency, 99.6 → 96.3 % (inside per seed 266 / 265 /
  267 / 252 / 265 of 273, against 272 every seed). That is 5–20 more misses
  per seed, all at 2068–2087 s (19.60–19.73 km, the last 0.3 km). Also
  slower heading convergence than the default on jammed-A (0.74–0.92 km
  against 0.30–0.31), jammed-B (0.43–0.44 against 0.19–0.22) and drive-8
  (0.66–0.68 against 0.39–0.41), still far below N3.0's. ms/step
  0.091–0.117 (default 0.089–0.114).
- **Within the allowance, still a cost:** clean +1.40 m (14.39 m against
  12.98; allowed +2), with seed 4 at 18.82 m.
- **Gains:** clean-long −0.04 m (19.38 m, 100 %); manual truth point 1
  −43.27 m (7.23 m), converged at 1.52–1.58 km (N3 target met, N3.0 7.27–7.68
  km); jammed-A −0.960 pp (84 % of N3.0's error removed); jammed-B −0.866 pp
  (81 %); drive-7 worst clean fix −0.998 pp (1.128 → 0.130 %, 24.2–27.8 m
  against 213–245 m, 88 % removed); drive-8 −1.295 pp (1.482 → 0.186 %,
  16.4–16.8 m against 259–302 m, 87 % removed) at 100 % consistency.
  Against the N3.2b default it passes every gated drive (drive-7 consistency
  87.4 → 96.3 %).
- Item 1 is what moved it. On the N3.2c engine (N3.2d) the same value failed
  clean by 0.02 m (15.00 m) and had drive-7 at 92.7 %; now clean is 14.39 m and
  drive-7 96.3 %.

**(b) What would be needed to pass cleanly.**
- **roadCorrelationM 100, drive-7 consistency.** N3.0 is 272/273 on every seed;
  the one miss is the first pin of the 706 s pair (209 m off; N3MF-1, likely,
  not proven), which every candidate also misses (about 250 m with roads). To
  keep the mean at 99.6 % a run may miss nothing else on any seed. It misses
  6 / 7 / 5 / 20 / 7 clean fixes, at 2068–2073 s on every seed (seed 4 to
  2087 s, seeds 2 and 5 also at 2082 s). Measured on seed 1: the truth is on a
  road the pack does not have in that direction (`noCompatibleRoadWithin15`,
  nearest edge 2–3 m away and of another heading), `onRoadShare` falls
  0.93 → 0, and the error is 22.1–23.7 m against a 95 % ellipse of
  25.3–28.6 × 20.9–22.6 m. The error itself is about 23 m from 2068 s to the
  end, i.e. along-track dead-reckoning error after about 5 km (0.12 %); the
  misses are where the ellipse is smallest, as the road evidence ends. What
  could address it (unmeasured): an ellipse that keeps the along-track
  uncertainty the road cannot reduce (the road update is Schmidt along the
  road, so this would be in how the estimate's ellipse is formed, not in the
  road update), or an off-road model that lets the cloud leave a mapped road
  sooner (the N3.2a question; test 3 is a known FAIL, and its follow-up,
  novelty from the particles' distance-to-road change, is unmeasured).
- **Default** fails against N3.0 on four drives:
  - clean-long +3.09 m and 96.4 %: the creeping last 11 s (648–657 s, no
    usable course; N3.2b). The estimate is held on an edge, 21.3–22.5 m off
    against a 18.6 m semi-major axis, 10 misses per seed. roadCorrelationM 100
    removes it, consistent with its tempering: an update's road weight is the
    distance driven since the last one over 100 m, so creeping adds little
    road evidence (the mechanism is not isolated).
  - clean +2.36 m (0.36 m over): the maximum is now at 374–376 s, 3.50 km,
    where the car leaves mapped roads (truth `noRoad` from 363 s, 17 m from
    the nearest edge, then no edge near). The estimate stays on the road for about 3 s
    (`onRoadShare` ≥ 0.93 to 365 s), then parks off-road 15.6 m off (seed 1).
    N3.0's maximum was earlier (259 s on seeds 1–4, 357 s on seed 5;
    10.7–16.5 m). Like drive-7's misses, it is where the car leaves the
    mapped roads, but here the road holds the estimate while the error grows.
  - drive-7 consistency 87.2 %: 33–36 misses at 2058–2093 s, the stretch above
    with the smaller ellipse of roadCorrelationM 30.
  - drive-8 99.6 %: 3–5 misses at 897–901 s, on the right road (secondary):
    the 5 m GNSS fixes are 14.3–14.7 m from its OSM centreline, the estimate
    is on the centreline, and the 95 % semi-minor axis is 12.4 m. Either the
    centreline or the fixes are off there; which is not measured.
    roadCorrelationM 100 and roadSigmaM 10 both cover it (100 %).
- **roadSigmaM 10** fails clean: 24.18 m (+11.20 m), its maximum also at the
  drive's end (374–376 s); why a wider σ costs more there was not
  investigated. drive-7 88.9 %.
- **roadSigmaM 3.0** fails clean-long (+6.47 m: the creep, against a 15 m
  ellipse), drive-7 (0.714 %: captured on the service-road end up to 141 m off,
  as in N3.2d) and drive-8 (97.8 %: 890–901 s as above, and 1286–1301 s on
  right and wrong roads); against the N3.2b default also jammed-B
  (0.411 %, +0.114 pp).
- No combination was run (none was declared).

**Anomalies.**
- Seeds disagree on drive-7 under roadCorrelationM 100: seed 4 misses 21
  (2068–2087 s), the others 6–8.
- jammed-A's engine-only consistency is 0 % for the default and roadSigmaM 3.0
  (its single truth end outside the engine's ellipse, inside with the truth's
  σ), 100 % for the other two.
- drive-7's worst checkpoint overall is the 706 s pin (250 m) under every
  candidate; its gated value counts clean fixes only.
- manual-3 (sanity): pins 68.2–68.6 m mean under every candidate, 66.7 %
  consistency; engine-only 26.7–33.3 %.

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

## Known limitations and options

- **Heading convergence with tower fixes only** (manual: 6.8 km against a
  2 km target). Before the pin, and between the pin and the end, heading
  information comes only from minutes-correlated, roughly 1 km tower fixes.
  The honest heading std drops under 10° only after several km. Options: a
  second manual fix a few hundred metres after the first (two pins fix
  heading); road matching (N3); a magnetometer heading with a learned mount
  offset; trusting towers more (`networkFixCorrelationS` 30 → 5.1 km; not the default,
  see "Tried and rejected").
  ("Tried and rejected" and the measurements cited in this section: [docs/archive/NAVIGATION-history.md](archive/NAVIGATION-history.md).)
- **Reversing** (backlog N2-1, N3 candidate): OBD speed has no sign, so
  reversing is integrated as forward motion. Regression case:
  `--gps mask-after-motion 30` on the clean drive (324 m today). Ideas: reverse
  from the sign of longitudinal acceleration against d(speed)/dt, a reverse
  hypothesis per particle at low speed after a stop, or a gear/reverse PID in
  mode 01 if the car exposes one.
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
