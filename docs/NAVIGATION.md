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
- OBD speed scale factor (prior 1.016 ± 0.03; GNSS/OBD speed ratio 1.017 on
  clean-long, 1.015 on the dead-reckoned part of clean),
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
- **Manual fix** ("I'm here"): σ = max(30 m, mapSpanM / 12), 30 m when the
  span is missing or not usable. A fingertip covers roughly 1/12 of the map, so
  a pin on a 1.2 km-wide map is good to about 100 m. Caveat (M10.1-3): in
  heading-up the logged span can be up to about 2.2× too large, which errs
  toward a larger σ, so it is safe. The replay scores the pin checkpoint with the
  same σ. Kalman position update. If the prior
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
| scalePriorMean / scalePriorStd | 1.016 / 0.03 | OBD speed scale prior |
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
| manualFixSigmaMinM / manualFixSpanDivisor | 30 / 12 | manual pin σ = max(min, mapSpanM / divisor); min without a span |
| manualFixResetChi2 / manualFixResetESSFraction | 25 / 0.01 | manual reset when no support |
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

The "N2" column is the previous baseline (scale prior 1.0, pin σ 30 m), seed 1.
For the two new drives it comes from replaying with
`--set scalePriorMean=1 --set manualFixSpanDivisor=1e9`, which restores both.

| alias | run | distance | checkpoint errors | end error | max error | heading converged at | ms/step | N2 | criterion | result |
|---|---|---:|---|---:|---:|---:|---:|---|---|---|
| clean-long | mask-after 380 | 7.75 km | 277 withheld clean fixes: median 10 m, all inside the 95 % ellipse | 10 m (0.12 %)\* | 21 m (0.27 %) | 0.02 km | 0.060 | max 20 m | max ≤ 30 m | **PASS** |
| manual-3 | use | 12.05 km | pin priors: 1: 324 m (18.9 %, σ 104 m, ellipse 147 × 73 m); 2: 1089 m (17.1 %, σ 30 m, ellipse 488 × 191 m); 3: 308 m (4.4 %, σ 31 m, ellipse 144 × 89 m); none inside the 95 % ellipse | 308 m\* | 1089 m | 0.37 km | 0.067 | pins 322 / 1434 / 348 m | reported | see below |
| clean | mask-after 230 | 3.58 km | 216 withheld clean fixes: median 25 m, all inside the 95 % ellipse | 30 m (0.84 %)\* | 32 m (0.93 %) | 0.03 km | 0.058 | max 26 m | max ≤ 30 m | **FAIL** (32 m; seeds 2–4 pass, see below) |
| manual | use, hold-out 100 | 8.31 km | pin prior 169 m (σ 42 m); truth point 1: 26 m (0.33 %); truth point 2: 40 m (0.49 %) | 40 m (0.49 %)\* | 169 m (11.2 %) | 6.80 km | 0.062 | 53 m; 6.80 km | truth point 1 ≤ 200 m; converged ≤ 2 km | **PASS** (26 m); **known FAIL** (convergence 6.80 km) |
| jammed-A | use | 11.23 km | end 68 m | 68 m (0.61 %) | 68 m (0.61 %) | 7.13 km | 0.066 | 1.24 % | end ≤ 2.5 % | **PASS** |
| jammed-B | use | 5.89 km | end 59 m | 59 m (1.01 %) | 59 m (1.01 %) | 5.18 km | 0.065 | 1.76 % | end ≤ 2.5 % | **PASS** |

\* no truth `end` for this drive: error at the last checkpoint. The largest
single `ingest` call in these runs was 0.35 ms.

**Seed spread (seeds 1–5)**

| alias | N2.1 | N2 config |
|---|---|---|
| clean-long, max | 19–21 m | 20–21 m |
| clean, max | 32 / 18 / 29 / 17 / 35 m (seeds 1 and 5 over 30 m) | 26 / 11 / 23 / 13 / 23 m |
| manual, truth point 1 | 26–49 m | 52–81 m |
| manual, convergence | 6.80 km on every seed | 6.80 km |
| manual-3, pin priors | 324–366 / 1089–1159 / 308–329 m | 322–361 / 1434–1517 / 348–364 m |
| jammed-A, end | 0.61–1.19 % | 1.24–1.84 % |
| jammed-B, end | 1.01–1.48 % | 1.76–2.35 % |

The two changes separate cleanly (seed 1):
- **The σ rule** changes only manual-3: pins 2 and 3 go from 1434 / 348 to
  1125 / 314 m. Pin 1, on a 1.2 km-wide map, no longer pulls as hard as a 30 m
  pin would.
- **The scale prior 1.016** gives the gains on manual, jammed-A and jammed-B,
  and the loss on clean.

**Clean drive under the new prior: FAIL on 2 of 5 seeds, explained, not tuned
away.** The error after the mask is mostly along-track: the estimate trails the
truth. The scale fitted before the mask varies strongly between seeds (0.993 to
1.052 at the end of the run), while the true ratio after the mask is 1.015.
- GNSS speed before 230 s on this drive is about 2 % below OBD (ratio 0.978:
  city driving, a GNSS outage, slow sections), so its ~50 speed updates pull
  the scale the wrong way.
- Scale has little diversity after resampling, so which particles survive is
  largely chance. The new prior changes which ones do: seeds 1 and 5 end
  further from 1.015 than before (0.993 and 1.052).
- On clean-long, where the GNSS speed agrees with OBD (1.017), the fitted scale
  is 1.016–1.017 on every seed.

Options, measured on seeds 1–5 and **not adopted**:
- Prior std 0.01 (`scalePriorStd`): clean 12–17 m on every seed; manual 34–41 m
  and jammed-A/B 0.60–0.85 % / 0.99–1.26 % (seeds 1, 3, 5).
- More scale jitter after resampling (`resampleScaleJitter` 0.002): clean
  15–49 m. Worse.

**manual-3 is overconfident.** All three pins fall outside the 95 % ellipse,
heading "converges" at 0.37 km, and the scale drifts to 0.91. The cause is
initialisation from a stale pre-session fix (parked), then ten no-Doppler
network fixes of 24–190 m between 71 and 117 s. They are below the 200 m tower
threshold, so they are untempered at face value (σ about 16 m for the 24 m
ones), and they collapse heading within about 300 m of travel. This predates
N2.1: the N2 config scores the pins 322 / 1434 / 348 m. Option, measured on
seed 1 and **not adopted**: temper every no-Doppler fix
(`towerMinAccuracyM` 0). manual-3 pins become 413 / 642 / 242 m, pin 2 lands
inside its ellipse, and the scale stays at 1.018. But manual worsens to 43 m
and jammed-A to 1.01 %, while jammed-B improves to 0.87 %.

**Manual drive, convergence: known FAIL, accepted.** Heading converges
(σ < 10° held for 30 s) after 6.80 km, against a 2 km target. The more
important number is the position error at truth point 1: 26 m (0.33 % of
distance), well inside 200 m. Convergence is not tuned towards the target:
with towers and one pin as the only absolute information, the honest heading
std falls under 10° late. Options are listed under known limitations.

### Informational runs (not acceptance)

These rows were measured with the N2 config (scale prior 1.0), except
mask-after-motion 30. That one, re-run on N2.1, gives 309–329 m on seeds 1–5,
with at most 1 of 283 withheld fixes inside the 95 % ellipse.

| alias | run | result | what it shows |
|---|---|---|---|
| clean | mask-after 30 (the superseded reading of the criterion) | max 2601 m, heading never converges | masks before the car moves: no heading information |
| clean | mask-after-motion 30 (motion starts 49.5 s, mask at 79.5 s) | max 324 m (seeds 2–5: 311–316 m); 0/283 withheld fixes inside the 95 % ellipse | **regression case for reverse handling.** The masked part starts with a slow manoeuvre including reversing, which unsigned OBD speed integrates as forward motion, and the filter is overconfident about it |
| clean | mask-after 74 / 76 / 78 | max 170 / 207 / 300 m | the same manoeuvre. The error depends steeply on how many slow GNSS fixes from its start are used (they pull the scale up to 1.02); mask-after 79.5 equals mask-after-motion 30 exactly |
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
- **No-Doppler network fixes under 200 m** are trusted at face value and
  untempered. They help a lot when right (manual truth point 1) and hurt when
  biased: manual-3 converges falsely on them. Option measured above:
  `towerMinAccuracyM` 0.
- **Scale learning from GNSS speed** is fragile when GNSS speed disagrees with
  OBD (clean drive before 230 s). Option measured above: prior std 0.01.

## To verify on the device (N4)

- ≤ 2 ms per 10 Hz step with 2000 particles on an iPhone. The Mac release
  replay gives 0.05–0.06 ms/step (largest single ingest 0.31 ms).
- Arrival order in the live app: CoreMotion batches can arrive late; the engine
  accumulates late yaw into the next step, but this is untested on hardware.
- `estimate(at:)` extrapolation between steps at UI rates.
- Behaviour across an OBD dropout while driving (stale-speed growth) and after
  ignition off at the end of a drive.
