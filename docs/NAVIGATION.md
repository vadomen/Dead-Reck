# Navigation engine (N2, engine update N2.1)

Live dead reckoning without roads: a causal, deterministic estimator of
position, heading and OBD speed scale, in `Core/Sources/DriveLoggerCore/Navigation/`
(Foundation only), plus the Mac replay tool `replay_nav` that proves it on
recorded drives. N4 runs the same engine in the app; nothing here touches the
logger, the log format or `App/`.

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
- a speed error that random-walks only while OBD speed is stale,

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
    - On the replay set, parked and idling peaks reach 0.082 g (the phone being
      handled after ignition-off), and most drive-offs exceed 0.09 g within
      0–12 s; a gentle one can take 20–30 s.
    - Yaw is not used as evidence: handling the parked phone gives
      0.4–3.4 rad/s.
    - Every stale period in the replay set is ignition-off after a stop.
  - **Otherwise, unknown speed.** Each particle's speed error follows an
    Ornstein–Uhlenbeck process (2.5 m/s per √s, decaying with τ = 20 s, so its
    spread levels off at about 7.9 m/s; either sign, so the mean does not
    drift), and heading noise is ×3. The ellipse then grows like √t: about
    0.6 / 2.2 / 3.0 km after 1 / 5 / 10 min of OBD silence while driving. An
    unbounded random walk reached 1.5 / 19 / 55 km.
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
    from a ring of cumulative mean motion (10 s). This is causal and needs no
    per-particle history.
  - **Stale fixes** (age > 10 s at arrival) are ignored unless OBD says the car
    is stopped.
  - **Course** is used when valid, GNSS speed ≥ 3 m/s, fresh OBD speed ≥ 3 m/s
    (GNSS reports a few m/s of noise while parked), and GNSS speed agrees with
    OBD within max(2 m/s, 15 %). That last gate rejects glitch fixes (the clean
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
  a pin on a 1.2 km-wide map is good to about 100 m. Caveat (M10.1-3): in
  heading-up the logged span can be up to about 2.2× too large, which errs
  toward a larger σ, so it is safe. The replay scores the pin checkpoint with the
  same σ. Kalman position update. If the prior has no support at the pin (every
  particle further than χ² = 25), positions restart at the pin while heading
  and scale hypotheses and their weights are kept. A low ESS alone does not
  reset (R13.1-1): that is the pin carrying the most information. For example,
  a ring-shaped cloud after km of unknown heading is cut down to the headings
  that lead to the pin, and resampling keeps that posterior.
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

### Estimate

`estimate(at:)` returns nil before initialisation. Otherwise it returns the
weighted mean position, circular mean and std of heading, a 95 % ellipse
(√(5.991 λ) of the mixture covariance), speed, scale mean and std, ESS and
`converged` (heading std < 10°; while false N4 shows "calibrating heading"). For
a time after the last step it extrapolates with the last speed and yaw rate. It
does not mutate the engine.

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
| staleHeadingNoiseFactor | 3 | heading noise multiplier while stale |
| maxMotionGapS | 0.5 | longer motion gaps contribute no yaw |
| fixSigmaPerAccuracy | 1/1.51 | per-axis σ per metre of accuracy |
| fixSigmaFloorM | 5 | σ floor |
| networkFixInflation | 1.0 | extra σ factor for network fixes (any fix without a valid speed) |
| networkFixCorrelationS | 60 | network-fix tempering window |
| maxFixAgeS | 10 | older fixes ignored unless stopped |
| staleFixSigmaGrowthMps / staleFixAgeS | 0 (off) / 5 | a pre-session fix (t < 0) or one older than staleFixAgeS gets σ += k × age; off by default (N2.2) |
| courseMinSpeedMps | 3 | course needs this GNSS and OBD speed |
| courseSigmaFloorDeg | 2 | course σ floor |
| speedUpdateMinKmh | 10.8 | GNSS speed updates the scale only above this OBD speed (and with valid speedAccuracy) |
| gnssSpeedGateMps / gnssSpeedGateFraction | 2 / 0.15 | GNSS vs OBD speed agreement gate |
| speedSigmaFloorMps | 1.0 | GNSS speed σ floor |
| cleanFixAccM | 15 | clean fix threshold |
| reseedHeadingStdDeg / reseedNoSupportSigma / reseedFraction | 30 / 4 / 0.5 | clean-fix reseed |
| manualFixSigmaMinM / manualFixSpanDivisor | 30 / 12 | manual pin σ = max(min, mapSpanM / divisor); min without a span |
| manualFixResetChi2 | 25 | manual reset when every particle is further than this from the pin (χ², 2 dof) |
| resampleESSFraction | 0.5 | resampling threshold |
| resampleHeadingJitterDeg / resampleScaleJitter | 0.2 / 0.0005 | jitter after resampling |
| convergedHeadingStdDeg | 10 | `converged` threshold |

## replay_nav

```bash
cd Core && swift run -c release replay_nav <log.jsonl.gz>... [--gps use|mask-after <s>|mask-after-motion <s>|none] \
  [--hold-out-acc <m>] [--truth ../logs/truth.json] [--seed N] [--particles N] \
  [--set <configKey>=<number>] [--out ../logs/out]
```

- Inputs: motion, OBD, location and manualFix from any v1–v3 recording, fed in
  arrival order (location by `receivedT ?? t`).
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
  a percentage of the distance travelled so far (∫ OBD speed).
- **Ellipse consistency**: the share of scored checkpoints (withheld clean
  fixes, manual-fix priors, truth points and end) whose truth lies inside the
  engine's 95 % ellipse at their time, overall and per kind. Shown in the
  summary, `metrics.md` and `metrics.json`. A calibrated filter scores about
  95 %; much lower means the ellipse is overconfident. The truth's own σ (a
  pin's σ, for example) is not added to the ellipse.
- Per log: distance, checkpoints, max and end error (end = truth `end`, else the
  last checkpoint), heading-convergence distance (first time `converged` then
  holds for 30 s), steps, ms/step (engine `ingest` wall time only), seed and
  config.
- Output in `--out`: `metrics.md` and `metrics.json` (merged across invocations,
  one row per log and mode), and `<log>-<mode>.geojson` (1 Hz DR track, 95 %
  ellipses every 10 s, fixes used and withheld, truth points with error lines).

Truth file (git-ignored `logs/truth.json`, read at runtime), keyed by recording
file name. The values here are illustrative:

```json
{ "<recording file name>": {
    "end":    { "latitude": 0.0, "longitude": 0.0, "sigmaM": 30, "source": "…" },
    "points": [ { "t": 100.0, "latitude": 0.0, "longitude": 0.0, "sigmaM": 30, "source": "…" } ],
    "note": "unknown keys are ignored" } }
```

## Adoption rule for engine changes

A change to the engine or its defaults is adopted only if, on every acceptance
drive (clean-long, clean, manual, jammed-A, jammed-B), the **mean over seeds
1–5** passes:

- **Drives scored in metres** (clean-long and clean max error, manual error at
  truth point 1): the mean may get worse by at most 2 m or 5 % of the
  previous mean, whichever is larger.
- **Drives scored in % of distance** (jammed-A, jammed-B end error): the mean
  may get worse by at most 0.1 percentage points.
- **Ellipse consistency** (share of checkpoints inside the 95 % ellipse, mean
  over seeds) must not drop on any drive.

The acceptance criteria themselves must still pass on every seed. manual-3 and
manual's convergence distance are reported, not gated. This replaces the
strict per-seed rule used for N2.2. Correctness fixes, such as the review
run 13 findings, are reported against the previous values, with every change
explained.

## Acceptance runs

`<clean>`, `<clean-long>`, `<manual>`, `<manual-3>`, `<jammed-A>` and
`<jammed-B>` are the paths of the recordings known under those aliases (kept
outside the repository).

| alias | run | criterion |
|---|---|---|
| clean-long | `--gps mask-after 380` | max ≤ 30 m |
| manual-3 | `--gps use` | each pin scored on its prior; reported, not gated |
| clean | `--gps mask-after 230` | max ≤ 30 m |
| manual | `--gps use --hold-out-acc 100` | truth point 1 ≤ 200 m; convergence reported |
| jammed-A, jammed-B | `--gps use` | end ≤ 2.5 % of distance |

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

```bash
cd Core
swift run -c release replay_nav <clean-long> --gps mask-after 380 --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <manual-3> --gps use --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <clean> --gps mask-after 230 --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <manual> --gps use --hold-out-acc 100 --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <jammed-A> <jammed-B> --gps use --truth ../logs/truth.json --out ../logs/out
```

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

### N2.2 experiment: stale-fix σ grown by age (default off)

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

- ≤ 2 ms per 10 Hz step with 2000 particles on an iPhone. The Mac release
  replay gives 0.05–0.06 ms/step (largest single ingest 0.31 ms).
- Arrival order in the live app: CoreMotion batches can arrive late; the engine
  accumulates late yaw into the next step, but this is untested on hardware.
- `estimate(at:)` extrapolation between steps at UI rates.
- Behaviour across an OBD dropout while driving (stale-speed growth) and after
  ignition off at the end of a drive.
