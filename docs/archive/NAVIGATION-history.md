# Navigation history

Moved from `docs/NAVIGATION.md` on 2026-10-12. Text unchanged; read only on demand. Current model, config, adoption rule and acceptance: [docs/NAVIGATION.md](../NAVIGATION.md).

## From "Model": tried and rejected

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

## From "Live in the app (N4 B)": N4 B acceptance

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

## From "Acceptance runs": N2.1 – N4-B1

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

## From "Acceptance runs": N2.2 experiment, informational runs

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
