# Navigation engine (N2)

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
- OBD speed scale factor (prior 1 ± 0.03),
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
- **Stale OBD** (> 2 s, including a stale zero) means unknown speed. Each
  particle's speed error random-walks (2.5 m/s per √s, either sign, so the mean
  does not drift while parked with the adapter off), and heading noise is ×3.
- **Process noise**: heading random walk 0.05°/√s plus 0.1°/√(degree turned)
  (about 1° per 90° turn; measured gyro turns match GNSS course within
  1–1.5 %). Position covariance grows by 0.6 m/√m along and across track. Scale
  random walk 1e-4/√s.

### Updates

- **Location fix**: per-axis σ = `horizontalAccuracy` / 1.51, floored at 5 m.
  CoreLocation reports a 68 % radius, which for a circular Gaussian is 1.51 σ,
  so this takes the fix at face value. Kalman update of each particle's
  position; log-weight += log N(z; μ, P + R).
  - **Tower-like** (accuracy > 200 m and no speed): likelihood tempered by
    `min(1, Δt since the last tower fix / 60 s)`, because the errors are
    correlated over minutes (equivalent to R / w). On the manual drive the
    residuals had a per-axis RMS of about 160 m against a reported 1414 m, in
    same-sign runs lasting 1–2 minutes.
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
  - **Speed** updates the scale under the same gates, with σ = max(speedAccuracy, 1 m/s).
    GNSS and OBD speeds differ by about 1 m/s RMS on the clean drive.
  - **Clean fix** (≤ 15 m with a usable course) **reseeds** half the particles
    around the fix and its course when the heading std is above 30° *or* no
    particle lies within 4 σ of the course. The second case recovers a heading
    that converged wrongly. On the clean drive, reversing out of a parking space
    with unsigned OBD speed drove heading to "nose + 180°".
- **Manual fix** ("I'm here", σ = 30 m): Kalman position update. If the prior
  has no support at the pin (every particle further than χ² = 25, or ESS < 1 %),
  positions restart at the pin while heading and scale hypotheses and their
  weights are kept.
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
| σ = max(acc, floor), tower σ × inflation | σ = acc / 1.51 (68 % radius), tower inflation 1.0 | Inflation 1.5 on top of σ = acc put jammed-B at 4.5 %. Face value is still 2–4× the observed tower scatter; correlation is handled by tempering |
| Clean-fix reseed when heading std > 30° | also when the course has no support | Recovers a heading that converged wrongly (reversing out of parking) |
| — | GNSS speed must agree with OBD for course and speed to be used | Glitch fixes and slow manoeuvres poisoned the heading |
| — | heading noise grows with the angle turned; scale jitter after resampling | Without them the filter was overconfident (95 % ellipse missed the truth on every withheld fix) and the scale stuck at 0.97 against a measured 1.003 |
| — | `replay_nav --set key=value` | Tune any config field without a rebuild |

Tried and rejected (worse on the replay set):
- Tempering GNSS position fixes for correlation (5–15 s): heading after the
  slow start went wrong (clean mask-after 74 s: 1 km).
- Tempering GNSS courses (5–15 s): clean mask-after 230 s worse (55–78 m).
- Treating 50–200 m Wi-Fi fixes as tower-like (`towerMinAccuracyM` 50, seeds
  1–3): manual truth point 1 at 86–108 m instead of 52–81 m; jammed-A
  1.45–2.09 % instead of 1.24–1.84 %.
- `towerCorrelationS` 120 (seeds 1–3): jammed-B 2.13–2.64 %, one seed over the
  limit.
- `towerCorrelationS` 30 (seeds 1–3) is as good or slightly better on every
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
| scalePriorMean / scalePriorStd | 1.0 / 0.03 | OBD speed scale prior |
| obdSpeedOffsetKmh | 0.5 | truncation offset when v > 0 |
| obdMaxAgeS | 2 | fresher = known speed; a fresh 0 is a ZUPT |
| staleSpeedNoiseMpsPerSqrtS | 2.5 | speed error random walk while stale |
| staleHeadingNoiseFactor | 3 | heading noise multiplier while stale |
| maxMotionGapS | 0.5 | longer motion gaps contribute no yaw |
| fixSigmaPerAccuracy | 1/1.51 | per-axis σ per metre of accuracy |
| fixSigmaFloorM | 5 | σ floor |
| towerMinAccuracyM | 200 | tower-like: accuracy above this and no speed |
| towerInflation | 1.0 | extra σ factor for tower-like fixes |
| towerCorrelationS | 60 | tower tempering window |
| maxFixAgeS | 10 | older fixes ignored unless stopped |
| courseMinSpeedMps | 3 | course needs this GNSS and OBD speed |
| courseSigmaFloorDeg | 2 | course σ floor |
| speedUpdateMinMps | 3 | scale update needs this OBD speed |
| gnssSpeedGateMps / gnssSpeedGateFraction | 2 / 0.15 | GNSS vs OBD speed agreement gate |
| speedSigmaFloorMps | 1.0 | GNSS speed σ floor |
| cleanFixAccM | 15 | clean fix threshold |
| reseedHeadingStdDeg / reseedNoSupportSigma / reseedFraction | 30 / 4 / 0.5 | clean-fix reseed |
| manualFixSigmaM | 30 | manual pin σ |
| manualFixResetChi2 / manualFixResetESSFraction | 25 / 0.01 | manual reset when no support |
| resampleESSFraction | 0.5 | resampling threshold |
| resampleHeadingJitterDeg / resampleScaleJitter | 0.2 / 0.0005 | jitter after resampling |
| convergedHeadingStdDeg | 10 | `converged` threshold |

## replay_nav

```bash
cd Core && swift run -c release replay_nav <log.jsonl.gz>... [--gps use|mask-after <s>|none] \
  [--hold-out-acc <m>] [--truth ../logs/truth.json] [--seed N] [--particles N] \
  [--set <configKey>=<number>] [--out ../logs/out]
```

- Inputs: motion, OBD, location and manualFix from any v1–v3 recording, fed in
  arrival order (location by `receivedT ?? t`).
- `--gps use`: every fix. `mask-after s`: no fix with `t` > s. `none`: no fixes
  (initialisation from a manual fix, if any).
- `--hold-out-acc m`: every fix with accuracy < m is withheld, including for
  initialisation. Each one is printed as (t, acc).
- Scored only against information the engine did not receive: withheld clean
  fixes (≤ 15 m), each manual fix (on the prior, just before it is ingested),
  and truth-file points and `end` (the last input). Errors are in metres and as
  a percentage of the distance travelled so far (∫ OBD speed).
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

## Acceptance runs

`<clean>`, `<manual>`, `<jammed-A>` and `<jammed-B>` are the paths of the
recordings known under those aliases (kept outside the repository).

```bash
cd Core
swift run -c release replay_nav <clean> --gps mask-after 30 --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <manual> --gps use --hold-out-acc 100 --truth ../logs/truth.json --out ../logs/out
swift run -c release replay_nav <jammed-A> <jammed-B> --gps use --truth ../logs/truth.json --out ../logs/out
```

### Baseline (seed 1, default config, release build, Mac)

| alias | run | distance | checkpoint errors | end error | max error | heading converged at | ms/step | criterion | result |
|---|---|---:|---|---:|---:|---:|---:|---|---|
| clean | mask-after 30 | 3.58 km | 333 withheld clean fixes: median 2172 m | 2601 m (72.6 %)\* | 2601 m (72.6 %) | never | 0.050 | max ≤ 30 m | **FAIL** — the car does not move before about 44 s, so there is no heading information in the first 30 s |
| manual | use, hold-out 100 | 8.31 km | pin prior 174 m (11.5 %, at 1.52 km); truth point 1: 53 m (0.67 %); truth point 2: 48 m (0.59 %) | 48 m (0.59 %)\* | 174 m (11.5 %) | 6.80 km | 0.055 | converged ≤ 2 km; truth point 1 ≤ 200 m | **FAIL** (convergence) / **PASS** (53 m) |
| jammed-A | use | 11.23 km | end 139 m | 139 m (1.24 %) | 139 m (1.24 %) | 7.13 km | 0.058 | end ≤ 2.5 % | **PASS** |
| jammed-B | use | 5.89 km | end 104 m | 104 m (1.76 %) | 104 m (1.76 %) | 5.18 km | 0.056 | end ≤ 2.5 % | **PASS** |

\* no truth `end` for this drive: error at the last checkpoint.

Largest single `ingest` call: 0.31 ms. Seed spread (seeds 1–5, same config):
manual truth point 1: 52–81 m; jammed-A: 1.24–1.84 %; jammed-B: 1.76–2.35 %;
clean mask-after 230: 11–26 m.

### Informational runs (not acceptance)

| alias | run | result | what it shows |
|---|---|---|---|
| clean | mask-after 230 | max 26 m, end 24 m over the last 1.8 km of DR; 216/216 withheld fixes inside the 95 % ellipse | reproduces the earlier offline baseline (30 s of GNSS at speed, then about 24 m over 1.8 km) |
| clean | mask-after 74 (30 s after the car starts moving) | max 170 m | the masked part starts with a slow manoeuvre including reversing, which unsigned OBD speed cannot represent |
| manual | use, hold-out 200 | truth point 1: 189 m, converged 7.68 km | without the 100–200 m Wi-Fi fixes, the last of which arrives 0.5 s before truth point 1, the error is 189 m |
| manual | use, hold-out 100, towerCorrelationS 30 | truth point 1: 63 m, converged 5.10 km | trusting towers more converges sooner, still not within 2 km |
| manual | none | never converges; about 4.2 km at truth point 1 | one pin alone does not give heading |

## Known limitations and options

- **Heading convergence with tower fixes only** (manual: 6.8 km against a
  2 km target). Before the pin, and between the pin and the end, heading
  information comes only from minutes-correlated, roughly 1 km tower fixes.
  The honest heading std drops under 10° only after several km. Options: a
  second manual fix a few hundred metres after the first (two pins fix
  heading); road matching (N3); a magnetometer heading with a learned mount
  offset; trusting towers more (`towerCorrelationS` 30 → 5.1 km; not the default,
  see "Tried and rejected").
- **Reversing**: OBD speed has no sign. Reversing moves the DR forwards (clean
  drive start). A reverse hypothesis per particle at low speed after a stop, or
  reverse detection from the accelerometer, would address it.
- **Wide heading posterior → shrunken mean**: while heading std is large, the
  mean of the arc-shaped cloud lies inside the arc, shortening the
  start-to-estimate distance by about exp(−σ²/2). On jammed-B this was most of
  the error before face-value fix σ.
- **Mid-accuracy Wi-Fi fixes (100–200 m)** are trusted at face value and
  untempered. They help a lot when right (manual truth point 1) and would hurt
  if biased.

## To verify on the device (N4)

- ≤ 2 ms per 10 Hz step with 2000 particles on an iPhone. The Mac release
  replay gives 0.05–0.06 ms/step (largest single ingest 0.31 ms).
- Arrival order in the live app: CoreMotion batches can arrive late; the engine
  accumulates late yaw into the next step, but this is untested on hardware.
- `estimate(at:)` extrapolation between steps at UI rates.
- Behaviour across an OBD dropout while driving (stale-speed growth) and after
  ignition off at the end of a drive.
