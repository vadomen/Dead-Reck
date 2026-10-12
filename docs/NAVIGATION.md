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
    offsets are antithetic in pairs (R11.1-7): particles 2k and 2k + 1 share
    one noise draw with opposite signs, so the offsets sum to 0. With
    independent draws the *realised* mean drifted, about √(Var I(t) / N):
    measured on a synthetic 10 min stretch at 15 m/s (N = 2000, seeds 1–10),
    3.8–48.8 m, RMS 28.7 m. Antithetic: RMS 9.1 m (max 14.1 m); the rest is
    heading spread, since a pair cancels along each particle's own heading.
    The ellipse is unchanged (95 % semi-major 2.8–3.1 km). A resample or
    reseed that breaks a pair is repaired at the next stale step (the odd
    particle takes the negative of the even one; the marginal is the same,
    no random numbers are drawn). The ellipse then grows like √t: about
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

Tried and rejected (worse on the replay set):
- Tempering GNSS position fixes for correlation (5–15 s): heading after the
  slow start went wrong (clean mask-after 74 s: 1 km).
- Tempering GNSS courses (5–15 s): clean mask-after 230 s worse (55–78 m).
- (N2) Treating 50–200 m Wi-Fi fixes as tower-like: manual truth point 1 at
  86–108 m instead of 52–81 m. Superseded in N2.1, where every fix without
  speed is a network fix, for the ellipse's sake (see the baseline).
- `networkFixCorrelationS` 120 (seeds 1–3): jammed-B 2.13–2.64 %, one seed over the
  limit.
- `networkFixCorrelationS` 30 (seeds 1–3) is as good or slightly better on every
  run (manual 57–86 m, jammed-A 1.27–1.77 %, jammed-B 1.98–2.22 %) and
  converges on the manual drive at 5.1–5.3 km. It is not the default: the
  measured tower residuals stay correlated for 1–2 minutes, so 30 s counts
  tower information twice as often as the evidence supports. It still misses
  the 2 km target.

## Configuration (defaults)

Every value is in `NavigationConfig`; `replay_nav` prints the full config with
every result.

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
  [--write-sidecar <out.nav.jsonl>] [--pin-pair-window <s>] [--strict]
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
    "note": "unknown keys are ignored" } }
```

`excludePins` (optional, N3.0): manual fixes of the recording that are not
scored as truth, each matched to the pin nearest its `t` (the `manualFix`
event's session-clock seconds) within 0.1 s. The engine still receives them.
Use it for a pin that is known or likely to be wrong. The reason goes into the
summary and `metrics.md`.

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

**N4 B acceptance** (release build, Mac, seeds 1–5): every acceptance replay
is bit-identical to N4-B0 in every `metrics.json` field and every existing
GeoJSON feature, except ms/step. The GeoJSON of the two drives with manual
fixes gains `pinEstimate`/`pinEllipse95` features at the end, whose values
equal the manualFix checkpoints' estimates and ellipses. On manual-3,
`--write-sidecar` followed by `--as-live --compare` matched 1317 estimates and
3 pins exactly.

**What the live app would have shown (`--as-live`, one run per drive, header
seed).** The middle column uses the same seed in the normal (arrival) order,
so the two differ only in input order.

| alias | criterion | as-live | arrival order, same seed | N4-B0 seeds 1–5 | stale fixes ignored, as-live / arrival |
|---|---|---|---|---|---|
| clean-long | max ≤ 30 m | 18.78 m | 19.06 m | 18.19–20.20 m | 0 / 0 |
| clean | max ≤ 30 m | 10.76 m | 13.88 m | 12.25–16.89 m | 0 / 0 |
| manual | truth point 1 ≤ 200 m | 53.5 m | 51.2 m | 47.43–57.42 m | 0 / 0 |
| jammed-A | end ≤ 2.5 % | 1.20 % | 1.28 % | 1.02–1.26 % | 1 / 0 |
| jammed-B | end ≤ 2.5 % | 1.54 % | 1.37 % | 0.93–1.39 % | 1 / 0 |
| manual-3 (sanity) | pin priors | 320 / 435 / 128 m [2/3] | 103 / 458 / 131 m [2/3] | 103–104 / 458–473 / 128–131 m | 1 / 0 |

Every criterion passes as live, and every run keeps its ellipse consistency.
The order matters in one systematic way. OBD rows are written up to 0.27 s
after their own `t` (the reply time), because the link's event reaches the
recorder later. At Start, the pre-session fix is therefore written before the
first OBD 0. In arrival order the engine sees the car is stopped and accepts
the stale fix with grown σ. Live it does not know that yet, ignores the fix as
stale, and initialises from a later one. On manual-3 this moves pin 1 from
103 m to 320 m. N4 B left the engine bit-identical; **N4-B1 fixes it** (backlog
N4B-1): the engine now holds such a fix until the first fresh OBD reply, and
the as-live runs use it like the arrival-order ones. Results: "N4-B1" below.

## Adoption rule for engine changes

A change to the engine or its defaults is adopted only if, on every acceptance
drive (clean-long, clean, manual, jammed-A, jammed-B, and from N3.0 drive-7),
the **mean over seeds 1–5** passes:

- **Drives scored in metres** (clean-long and clean max error, manual error at
  truth point 1): the mean may get worse by at most 2 m or 5 % of the
  previous mean, whichever is larger.
- **Drives scored in % of distance** (jammed-A, jammed-B end error; drive-7
  worst withheld clean fix): the mean may get worse by at most 0.1
  percentage points.
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
`<jammed-B>` and `<drive-7>` are the paths of the recordings known under those
aliases (kept outside the repository or in the git-ignored `logs/`).

| alias | run | criterion |
|---|---|---|
| clean-long | `--gps mask-after 380` | max ≤ 30 m |
| manual-3 | `--gps use` | each pin scored on its prior; reported, not gated |
| clean | `--gps mask-after 230` | max ≤ 30 m |
| manual | `--gps use --hold-out-acc 100` | truth point 1 ≤ 200 m; convergence reported |
| jammed-A, jammed-B | `--gps use` | end ≤ 2.5 % of distance |
| drive-7 | `--gps mask-after 1800` | every withheld clean fix after 1800 s ≤ 2.5 % of distance from the start (decided 2026-10-12, see below); scored-pin and clean-fix consistency reported |

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

```bash
cd Core
swift run -c release replay_nav <clean-long> --gps mask-after 380 --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <manual-3> --gps use --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <clean> --gps mask-after 230 --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <manual> --gps use --hold-out-acc 100 --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <jammed-A> <jammed-B> --gps use --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <drive-7> --gps mask-after 1800 --truth ../logs/truth.json --out ../logs/out
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

### Baseline (N2.1: seed 1, default config, release build, Mac)

The "N2" column is the previous baseline: scale prior 1.0 ± 0.03, pin σ 30 m,
tower = > 200 m without speed, seed 1.

| alias | run | distance | checkpoint errors | end error | max error | inside 95 % | heading converged at | ms/step | N2 | criterion | result |
|---|---|---:|---|---:|---:|---|---:|---:|---|---|---|
| clean-long | mask-after 380 | 7.75 km | 277 withheld clean fixes: median 9 m | 9 m (0.12 %)\* | 20 m (0.26 %) | 277/277 | 0.02 km | 0.061 | max 20 m | max ≤ 30 m | **PASS** |
| manual-3 | use | 12.05 km | pin priors: 1: 416 m (24.3 %, σ 104 m, ellipse 331 × 89 m); 2: 635 m (10.0 %, σ 30 m, ellipse 661 × 176 m); 3: 247 m (3.5 %, σ 31 m, ellipse 170 × 86 m) | 247 m\* | 635 m | 0/3 | 1.72 km | 0.066 | pins 322 / 1434 / 348 m | reported | see below |
| clean | mask-after 230 | 3.58 km | 216 withheld clean fixes: median 2 m | 2 m (0.06 %)\* | 13 m (0.59 %) | 216/216 | 0.03 km | 0.059 | max 26 m | max ≤ 30 m | **PASS** |
| manual | use, hold-out 100 | 8.31 km | pin prior 260 m (σ 42 m); truth point 1: 49 m (0.62 %); truth point 2: 64 m (0.77 %) | 64 m (0.77 %)\* | 260 m (17.1 %) | 3/3 | 7.27 km | 0.064 | 53 m; 6.80 km | truth point 1 ≤ 200 m; converged ≤ 2 km | **PASS** (49 m); **known FAIL** (convergence 7.27 km) |
| jammed-A | use | 11.23 km | end 114 m | 114 m (1.02 %) | 114 m (1.02 %) | 1/1 | 8.15 km | 0.067 | 1.24 % | end ≤ 2.5 % | **PASS** |
| jammed-B | use | 5.89 km | end 48 m | 48 m (0.81 %) | 48 m (0.81 %) | 1/1 | 5.31 km | 0.065 | 1.76 % | end ≤ 2.5 % | **PASS** |

\* no truth `end` for this drive: error at the last checkpoint. The largest
single `ingest` call in these runs was 0.38 ms.

**Seed spread (seeds 1–5)**. Columns, in the order N2.1 adopted them:
- N2: scale prior 1.0 ± 0.03, pin σ 30 m.
- 1.016 ± 0.03: the first N2.1 candidate.
- 1.016 ± 0.01: tight per-vehicle prior.
- **+ no-speed = network fix: chosen.**

Ellipse consistency (inside 95 %) is in brackets where measured.

| alias | N2 | 1.016 ± 0.03 | 1.016 ± 0.01 | **+ no-speed = network (chosen)** |
|---|---|---|---|---|
| clean-long, max | 20–21 m | 19–21 m | 18–20 m [100 %] | **18–20 m [100 %]** |
| clean, max | 11–26 m | 17–35 m | 12–17 m [100 %] | **12–17 m [100 %]** |
| manual, truth point 1 | 52–81 m | 26–49 m | 34–45 m [3/3] | **47–57 m [3/3]** |
| manual, convergence | 6.80 km | 6.80 km | 6.80 km | **7.27–7.68 km** |
| manual-3, pin priors | 322–361 / 1434–1517 / 348–364 m | 324–366 / 1089–1159 / 308–329 m | 352–356 / 1147–1161 / 336–338 m [0/3] | **415–417 / 635–651 / 247–250 m [0/3]** |
| jammed-A, end | 1.24–1.84 % | 0.61–1.19 % | 0.60–0.85 % [1/1] | **1.02–1.26 % [1/1]** |
| jammed-B, end | 1.76–2.35 % | 1.01–1.48 % | 0.88–1.26 % [1/1] | **0.81–1.11 % [1/1]** |

The clean drives have no fixes without speed, so they are unchanged.

How each change contributes:
- **Pin σ rule** (seed 1): changes only manual-3, where pins 2 and 3 go from
  1434 / 348 to 1125 / 314 m.
- **Scale prior mean 1.016**: brings the gains on manual, jammed-A and
  jammed-B. With std 0.03 it made clean fail on 2 of 5 seeds (32 and 35 m).
  The fitted scale wandered between 0.993 and 1.052, because clean's GNSS
  speeds before the mask disagree with OBD (ratio 0.979 above 10 km/h) and
  scale keeps little diversity after resampling.
- **Std 0.01** holds the scale near the measured value. Clean is 12–17 m on
  every seed; jammed-A/B improve further. Two drives get slightly worse:
  - manual is 7–13 m worse than with std 0.03 on seeds 1, 4 and 5, still
    within 26–49 m against a 200 m limit;
  - manual-3's pin priors are 30–70 m worse.
- **30 km/h gate for GNSS speed: tried, not adopted.** It equals std 0.01 alone
  on clean-long (288 vs 309 updates, ratio 1.017 either way) and is worse on
  clean, at 15–20 m. Clean's only stretch above 30 km/h before the mask (about
  200–230 s, right after a GNSS outage) reads GNSS 3 % above OBD (ratio 1.0325
  on 43 fixes), so gating on it pulls the scale to 1.034. It makes no difference
  on manual, manual-3 and jammed-A/B, whose fixes carry no speed. The gate stays
  configurable (`speedUpdateMinKmh`) at the previous 10.8 km/h.
- **No-speed = network fix** (adopted by decision, for an honest ellipse):
  - manual-3: pins 2 and 3 improve (1147–1161 → 635–651 m and 336–338 →
    247–250 m), pin 1 gets worse (352–356 → 415–417 m).
  - jammed-B improves.
  - manual is 6–15 m worse (still far inside 200 m) and converges 0.5–0.9 km
    later; jammed-A is 0.4 percentage points worse.
  - Every criterion still passes on every seed.

**manual-3 is still overconfident: 0/3 pins inside the 95 % ellipse on every
seed.** Heading std falls from 125° at 60 s to 11° by 120 s:
- The engine initialises from a stale pre-session fix (25 m claimed accuracy,
  accepted because the car was parked).
- Wi-Fi fixes of 24–59 m follow at 95–117 s. Tempered, they add up to about one
  fix's worth of evidence, which still fixes heading to about 10° over ~300 m
  of travel.
- If those network positions are biased, as they appear to be, heading is
  wrong with a narrow ellipse. At the pins the error is 1.3–3× the ellipse's
  semi-axis in its direction.

Part of the gap is the metric: it does not add the pin's own σ, and pin 1 has
σ 104 m. With it, pin 1 (416 m against a 331 m semi-major axis) sits on the
boundary.

Options, measured on seed 1 and **not adopted**:
- `networkFixInflation` 1.5: manual-3 pins 416 / 504 / 153 m with 1/3 inside;
  manual 61 m; jammed-A 1.18 %; jammed-B 1.56 %.
- `networkFixInflation` 2: manual-3 1/3 inside, but **jammed-B fails at
  2.75 %**.
- Not measured: an age-inflated σ for stale pre-session fixes used for
  initialisation; adding the truth σ to the consistency metric.

**Manual drive, convergence: known FAIL, accepted.** Heading converges
(σ < 10° held for 30 s) after 7.27 km (7.27–7.68 km over seeds 1–5), against a
2 km target. The more important number is the position error at truth point 1:
49 m (0.62 % of distance; 47–57 m over seeds 1–5), well inside 200 m. Convergence is not tuned towards the target:
with towers and one pin as the only absolute information, the honest heading
std falls under 10° late. Options are listed under known limitations.

### N2.3: review run 13 fixes (seeds 1–5, mean and range, against N2.2)

These are correctness fixes, judged for regressions rather than by the
adoption rule:
- the manual-fix reset now fires only without χ² support (R13.1-1);
- stale speed is parked after a stop and mean-reverting otherwise (R13.1-2);
- the local plane re-anchors beyond 10 km (R13.1-3).

| alias | criterion | N2.2 mean (range) [inside 95 %] | N2.3 mean (range) [inside 95 %] | change and why |
|---|---|---|---|---|
| clean-long | max ≤ 30 m | 18.90 m (18.19–20.20) [100 %] | 18.90 m (18.19–20.20) [100 %] | identical: no stale period, pin or re-anchor |
| clean | max ≤ 30 m | 13.94 m (12.25–16.89) [100 %] | 13.94 m (12.25–16.89) [100 %] | identical |
| manual | truth point 1 ≤ 200 m | 50.57 m (47.43–57.42) [100 %] | 50.57 m (47.43–57.42) [100 %] | identical: its pin is χ²-compatible and never reset |
| manual, convergence | (reported) | 7.27–7.68 km | 7.27–7.68 km | identical |
| jammed-A | end ≤ 2.5 % | 1.158 % (1.02–1.26) [100 %] | 1.156 % (1.02–1.25) [100 %] | ignition-off ending (211 stale steps) now parked instead of a symmetric random walk; Monte Carlo-sized change |
| jammed-B | end ≤ 2.5 % | 0.984 % (0.81–1.11) [100 %] | 1.010 % (0.88–1.31) [100 %] | same, 291 stale steps; up to 12 m per seed, the size of the old walk's Monte Carlo noise in the mean |
| manual-3 (sanity) | reported | 415–417 / 635–651 / 247–250 m [0/3] | 415–417 / 635–651 / 147–158 m [0/3] | pin 3 improves: the ESS-only reset that discarded pin information no longer fires |

All criteria pass on every seed. No drive re-anchors: none goes more than
10 km from its first position.

### N2.3: stale-fix σ by age, threshold only (adopted)

**Rule:** a fix older than 5 s at ingest gets σ += 1.0 m/s × age. This covers a
pre-session fix from minutes ago and a relaunch mid-drive. The N2.2 clause
"any fix with t < 0" is dropped, so pre-session fixes under a second old are
not touched.

It is judged with the mean-based adoption rule against this branch after the
run 13 fixes with k = 0 (seeds 1–5):

| alias | k = 0 mean (range) [inside 95 %] | k = 1.0 mean (range) [inside 95 %] | Δ mean | allowed |
|---|---|---|---|---|
| clean-long | 18.90 m (18.19–20.20) [100 %] | 18.90 m, bit-identical | 0 | ≤ +2 m |
| clean | 13.94 m (12.25–16.89) [100 %] | 13.94 m, bit-identical | 0 | ≤ +2 m |
| manual, truth point 1 | 50.57 m (47.43–57.42) [100 %] | 50.57 m (its stale fix is held out) | 0 | ≤ +2.5 m |
| jammed-A | 1.156 % (1.02–1.25) [100 %] | 1.147 % (1.02–1.26) [100 %] | −0.008 pp | ≤ +0.1 pp |
| jammed-B | 1.010 % (0.88–1.31) [100 %] | 1.068 % (0.93–1.39) [100 %] | +0.058 pp | ≤ +0.1 pp |
| manual-3 (sanity) | 415–417 / 635–651 / 147–158 m [0/3] | 103–104 / 458–473 / 128–131 m [2/3] | | reported |

Every drive passes and consistency does not drop, so **k = 1.0 is the
default**. manual-3's stale initialising fix (165 s old) was the main cause of
its overconfidence.

### N4-B0: engine fixes before N4 (seeds 1–5, mean and range, against N2.3)

These are correctness fixes, judged with the mean-based adoption rule:
- R13.2-2: an OBD 0 zeroes the motion EMA.
- R13.2-3: the EMA timestamp never goes backwards.
- R13.1-6: long gaps are caught up in bounded work.
- R13.1-5: `estimate(at:)` extrapolates for at most 2 s, then holds the
  position and grows the ellipse.

Reference: the branch before B0, which is identical to N2.3. Release build,
Mac, default config. **This is the baseline the rest of N4 must reproduce bit
for bit.**

| alias | run | distance | criterion | N2.3 mean (range) [inside 95 %] | N4-B0 mean (range) [inside 95 %] | Δ mean | allowed | end error | max error | converged at | ms/step |
|---|---|---:|---|---|---|---:|---|---|---|---|---|
| clean-long | mask-after 380 | 7.75 km | max ≤ 30 m | 18.90 m (18.19–20.20) [100 %] | 18.90 m (18.19–20.20) [100 %] | 0 | ≤ +2 m | 10.01 m (9.47–10.82)\* | 18.90 m | 0.02 km | 0.061–0.063 |
| clean | mask-after 230 | 3.58 km | max ≤ 30 m | 13.94 m (12.25–16.89) [100 %] | 13.94 m (12.25–16.89) [100 %] | 0 | ≤ +2 m | 6.45 m (2.18–11.56)\* | 13.94 m | 0.03–0.04 km | 0.058–0.060 |
| manual | use, hold-out 100 | 8.31 km | truth point 1 ≤ 200 m | 50.57 m (47.43–57.42) [100 %] | 50.57 m (47.43–57.42) [100 %] | 0 | ≤ +2.5 m | 67.29 m (63.79–76.10)\* | 259.78 m (pin prior) | 7.27–7.68 km (reported) | 0.065–0.066 |
| jammed-A | use | 11.23 km | end ≤ 2.5 % | 1.147 % (1.02–1.26) [100 %] | 1.147 % (1.02–1.26) [100 %] | 0 | ≤ +0.1 pp | 128.82 m (114.97–141.80) | = end | 8.15 km | 0.065–0.067 |
| jammed-B | use | 5.89 km | end ≤ 2.5 % | 1.068 % (0.93–1.39) [100 %] | 1.068 % (0.93–1.39) [100 %] | 0 | ≤ +0.1 pp | 62.91 m (55.06–82.11) | = end | 5.18–5.31 km | 0.062–0.063 |
| manual-3 (sanity) | use | 12.05 km | reported | pins 103–104 / 458–473 / 128–131 m [2/3] | pins 103–104 / 458–473 / 128–131 m [2/3] | 0 | not gated | 129.87 m (128.32–131.28)\* | 463.46 m (458.14–472.96) | 1.72 km | 0.067–0.068 |

\* no truth `end` for this drive: error at the last checkpoint.

**Every acceptance replay is bit-identical to N2.3.** That covers every seed,
every criterion, checkpoint and counter, and every GeoJSON file byte for byte;
only ms/step differs. Why each fix changes nothing here:
- **R13.2-2, R13.2-3:** the only stale periods in the replay set are the
  ignition-off endings (jammed-A 211, jammed-B 291 and manual-3 15 parked
  steps). There the last OBD 0 comes well after the stop, when the EMA has
  already decayed, and no motion sample arrives out of order. The parked step
  counts are unchanged.
- **R13.1-6:** motion samples arrive every 10 ms on every drive, so no
  `ingest` ever has more than a few grid steps to catch up.
  `coalescedSteps` = `macroSteps` = 0 on all 30 runs.
- **R13.1-5:** every scored checkpoint and every 1 Hz GeoJSON sample lies
  within 2 s of the engine's last step, so it is extrapolated exactly as
  before.

The largest single `ingest` was 0.18 ms (0.94 ms in one reference run;
timing only).

### N4-B1: hold a stale fix until OBD is known (seeds 1–5, against N4 B)

The engine change described under "Held stale fix" (backlog N4B-1). Judged
with the mean-based adoption rule against N4 B (`logs/n4b/after`, identical
to N4-B0). Release build, Mac, default config, `heldFixTimeoutS` 5.

**Arrival order (the adoption runs).** Every acceptance replay is
bit-identical to N4 B: all 30 runs, every `metrics.json` field except
ms/step and the config (one new key), and every GeoJSON byte. In arrival
order the first OBD 0 (its `t` 31–48 ms before the stale fix's arrival)
always comes first, so no fix is ever held (`fixesHeld` 0 on all 30 runs).

| alias | run | distance | criterion | N4 B mean (range) [inside 95 %] | N4-B1 mean (range) [inside 95 %] | Δ mean | allowed | end error | max error | converged at | ms/step |
|---|---|---:|---|---|---|---:|---|---|---|---|---|
| clean-long | mask-after 380 | 7.75 km | max ≤ 30 m | 18.90 m (18.19–20.20) [100 %] | 18.90 m (18.19–20.20) [100 %] | 0 | ≤ +2 m | 10.01 m (9.47–10.82)\* | 18.90 m | 0.02 km | 0.060 |
| clean | mask-after 230 | 3.58 km | max ≤ 30 m | 13.94 m (12.25–16.89) [100 %] | 13.94 m (12.25–16.89) [100 %] | 0 | ≤ +2 m | 6.45 m (2.18–11.56)\* | 13.94 m | 0.03–0.04 km | 0.058 |
| manual | use, hold-out 100 | 8.31 km | truth point 1 ≤ 200 m | 50.57 m (47.43–57.42) [100 %] | 50.57 m (47.43–57.42) [100 %] | 0 | ≤ +2.5 m | 67.29 m (63.79–76.10)\* | 259.78 m (pin prior) | 7.27–7.68 km (reported) | 0.063 |
| jammed-A | use | 11.23 km | end ≤ 2.5 % | 1.147 % (1.02–1.26) [100 %] | 1.147 % (1.02–1.26) [100 %] | 0 | ≤ +0.1 pp | 128.82 m (114.97–141.80) | = end | 8.15 km | 0.065 |
| jammed-B | use | 5.89 km | end ≤ 2.5 % | 1.068 % (0.93–1.39) [100 %] | 1.068 % (0.93–1.39) [100 %] | 0 | ≤ +0.1 pp | 62.91 m (55.06–82.11) | = end | 5.18–5.31 km | 0.061 |
| manual-3 (sanity) | use | 12.05 km | reported | pins 103–104 / 458–473 / 128–131 m [2/3] | pins 103–104 / 458–473 / 128–131 m [2/3] | 0 | not gated | 129.87 m (128.32–131.28)\* | 463.46 m (458.14–472.96) | 1.72 km | 0.065 |

\* no truth `end` for this drive: error at the last checkpoint. ms/step from
a sequential seed-1 run; the largest single `ingest` was 0.18 ms.

**File order, as live (`--file-order --seed 1…5`).** "Before" is the same
build with `--set heldFixTimeoutS=0`, the old code path: with the header seed
it reproduces the N4 B `--as-live` runs bit for bit (five drives checked,
metrics and GeoJSON). Ignored / held-and-used stale fixes per seed in the
last column.

| alias | criterion | arrival order, seeds 1–5 | file order before | file order after (N4-B1) | stale fixes, before → after |
|---|---|---|---|---|---|
| clean-long | max ≤ 30 m | 18.90 m (18.19–20.20) [100 %] | 19.43 m (19.13–19.75) [100 %] | 19.43 m, identical | none |
| clean | max ≤ 30 m | 13.94 m (12.25–16.89) [100 %] | 18.60 m (12.12–27.10) [100 %] | 18.60 m, identical | none |
| manual | truth point 1 ≤ 200 m | 50.57 m (47.43–57.42) [100 %] | 49.81 m (45.84–55.54) [100 %] | 49.81 m, identical | none (held out) |
| jammed-A | end ≤ 2.5 % | 1.147 % (1.02–1.26) [100 %] | 1.110 % (0.90–1.35) [100 %] | 1.140 % (1.01–1.25) [100 %] | 1 ignored → 1 used |
| jammed-B | end ≤ 2.5 % | 1.068 % (0.93–1.39) [100 %] | 1.505 % (1.23–1.72) [100 %] | 1.075 % (0.93–1.38) [100 %] | 1 ignored → 1 used |
| manual-3 (sanity) | pin priors | 103–104 / 458–473 / 128–131 m [2/3] | 318–320 / 442–450 / 127–133 m [2/3] | 103–104 / 458–472 / 129–131 m [2/3] | 1 ignored → 1 used |

With the hold, file order and arrival order agree on every drive with a
stale pre-session fix: jammed-A, jammed-B and manual-3 now initialise from
the same fix with the same σ in both orders. What still differs is the order
of late CoreMotion batches and OBD rows, which moves results within seed
noise. That is visible on clean (file order 12–27 m against 12–17 m), with or
without the hold: clean has no stale fix. Every criterion passes on every
seed in both orders, and consistency is 100 % throughout.

**Header seed (`--as-live`, what the app would have shown).** The middle
column uses the same seed in arrival order.

| alias | criterion | as-live, N4 B | as-live, N4-B1 | arrival order, same seed | stale fixes ignored / held and used, as-live N4-B1 |
|---|---|---|---|---|---|
| clean-long | max ≤ 30 m | 18.78 m | 18.78 m | 19.06 m | 0 / 0 |
| clean | max ≤ 30 m | 10.76 m | 10.76 m | 13.88 m | 0 / 0 |
| manual | truth point 1 ≤ 200 m | 53.5 m | 53.5 m | 51.2 m | 0 / 0 |
| jammed-A | end ≤ 2.5 % | 1.20 % | 1.30 % | 1.28 % | 0 / 1 |
| jammed-B | end ≤ 2.5 % | 1.54 % | 1.37 % | 1.37 % | 0 / 1 |
| manual-3 (sanity) | pin priors | 320 / 435 / 128 m [2/3] | 103 / 458 / 131 m [2/3] | 103 / 458 / 131 m [2/3] | 0 / 1 |

jammed-A gets 0.10 pp worse as live with this one seed (1.20 → 1.30 %),
now 0.02 pp from its arrival-order value; over seeds 1–5 in file order its
mean moves +0.03 pp (1.110 → 1.140 %), within seed noise. On manual-3 the
held fix makes heading converge at 1.72 km instead of 4.52 km as live.
`--write-sidecar` followed by `--as-live --compare` is exact on jammed-A
(1005 estimates) and manual-3 (1376 estimates, 3 pins; 1317 before, because
the engine now initialises at Start).

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
| R11.1-7 | measured, then antithetic stale speed offsets | bit-identical (no unknown-speed steps; every stale stretch is parked) |

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

### N2.2 experiment: stale-fix σ grown by age (default off; superseded by N2.3)

**Rule:** a fix from before the session (`t < 0`), or older than 5 s at ingest
(a relaunch mid-drive), gets σ += k × age. It applies to initialisation and to
updates; the stale-while-moving rejection (`maxFixAgeS`) is unchanged.

**Adoption test (strict):** for every acceptance drive and seed 1–5, the
criterion value must be ≤ N2.1 and the ellipse consistency ≥ N2.1. Two values
were tried, k = 1.0 m/s (about walking speed, or a car repositioning while
nothing observed it) and 0.5 m/s, then the search stopped. **Neither passes, so
the default is k = 0.** The code and tests stay.

| alias | N2.1 (k = 0) | k = 1.0 m/s | k = 0.5 m/s |
|---|---|---|---|
| clean-long, max | 18.2–20.2 m [100 %] | 18.7–19.9 m [100 %]; worse on seeds 2, 4, 5 | 19.0–20.2 m [100 %]; worse on all 5 |
| clean, max | 12.2–16.9 m [100 %] | 15.3–22.9 m [100 %]; worse on 4 seeds | 12.2–19.7 m [100 %]; worse on 3 seeds |
| manual, truth point 1 | 47.4–57.4 m [100 %] | identical (the stale fix is held out) | identical |
| manual, convergence | 7.27–7.68 km | identical | identical |
| jammed-A, end | 1.02–1.26 % [100 %] | 1.02–1.26 % [100 %]; worse on 3 seeds by ≤ 0.04 pp | 0.97–1.29 % [100 %]; worse on 2 seeds |
| jammed-B, end | 0.81–1.11 % [100 %] | 0.86–1.22 % [100 %]; worse on all 5 | 0.84–1.17 % [100 %]; worse on 3 seeds |
| manual-3 pins (sanity check only) | 415–417 / 635–651 / 247–250 m [0/3] | 103–104 / 458–473 / 128–131 m [2/3] | 230–232 / 493–510 / 130–135 m [2/3] |

**Reading.**
- **clean and clean-long:** their first fix is pre-session by only 0.7–0.9 s,
  so σ grows by under 1 m. That small change at initialisation alters later
  resampling, and the result moves within the seed noise (clean's own spread is
  12–17 m), not through a real effect. A strict per-seed test cannot tell the
  two apart.
- **jammed-A/B:** they initialise from fixes 99 s and 19 s old. Inflating those
  costs up to 0.1 pp.
- **manual-3:** its stale initialising fix (165 s old) is the main source of
  its overconfidence, and the rule fixes most of it. Its pins 2–3 were placed
  while moving and may be about 100 m off themselves, so it is not used for
  adoption.
- **Options:**
  - apply the rule only above an age threshold that excludes sub-second
    pre-session fixes;
  - judge adoption on seed-averaged values instead of per seed.

  Both are the user's call.

### Informational runs (not acceptance)

These rows were measured with the N2 config (scale prior 1.0), except
mask-after-motion 30. That one, re-run on N2.1, gives 317 m (seed 1; 309–329 m
on seeds 1–5 with std 0.03), with at most 1 of 283 withheld fixes inside the
95 % ellipse.

| alias | run | result | what it shows |
|---|---|---|---|
| clean | mask-after 30 (the superseded reading of the criterion) | max 2601 m, heading never converges | masks before the car moves: no heading information |
| clean | mask-after-motion 30 (motion starts 49.5 s, mask at 79.5 s) | max 324 m (seeds 2–5: 311–316 m); 0/283 withheld fixes inside the 95 % ellipse | **regression case for reverse handling.** The masked part starts with a slow manoeuvre including reversing, which unsigned OBD speed integrates as forward motion, and the filter is overconfident about it |
| clean | mask-after 74 / 76 / 78 | max 170 / 207 / 300 m | the same manoeuvre. The error depends steeply on how many slow GNSS fixes from its start are used (they pull the scale up to 1.02); mask-after 79.5 equals mask-after-motion 30 exactly |
| manual | use, hold-out 200 | truth point 1: 189 m, converged 7.68 km | without the 100–200 m Wi-Fi fixes, the last of which arrives 0.5 s before truth point 1, the error is 189 m |
| manual | use, hold-out 100, networkFixCorrelationS 30 (N2 name towerCorrelationS) | truth point 1: 63 m, converged 5.10 km | trusting towers more converges sooner, still not within 2 km |
| manual | none | never converges; about 4.2 km at truth point 1 | one pin alone does not give heading |

## Known limitations and options

- **Heading convergence with tower fixes only** (manual: 6.8 km against a
  2 km target). Before the pin, and between the pin and the end, heading
  information comes only from minutes-correlated, roughly 1 km tower fixes.
  The honest heading std drops under 10° only after several km. Options: a
  second manual fix a few hundred metres after the first (two pins fix
  heading); road matching (N3); a magnetometer heading with a learned mount
  offset; trusting towers more (`networkFixCorrelationS` 30 → 5.1 km; not the default,
  see "Tried and rejected").
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
