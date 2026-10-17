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

## From "Acceptance runs": N3.0–N3.2e runs and the N3-SLC candidate (moved 2026-10-17)

Moved from `docs/NAVIGATION.md` on 2026-10-17. Text unchanged, headings unchanged.

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

### N3 candidate: speedless course (2026-10-15): measured, rejected

**Not adopted; the code is dropped** (user decision 2026-10-15, backlog
N3-SLC REJECTED). The measured implementation is commit **0b3a1f7** (config
keys `speedlessCourse`, `speedlessCourseMaxAccDeg`, counter
`speedlessCourseUpdates`, 14 tests); it was reverted in d55e23c, so the
engine, its config JSON and hash and every sidecar are as before. This
section is kept as a measured negative result. To revive it, start from
0b3a1f7 and from "Why a gate cannot rescue it" below.

**What was tried.** Under jamming iOS delivers network (tower and Wi-Fi)
fixes with speed −1, which the engine uses for position only: the course
rule needs a GNSS speed ≥ 3 m/s. On drive-7, drive-8 and drive-9 (iPhone 16
Pro Max) some of those fixes still report a valid course with a
courseAccuracy of 16–45° (87, 28 and 37 fixes); none of the six older
drives has one. How iOS derives that course is not documented. The rule:
use such a course when
- the fix has no valid speed;
- the **fresh** OBD speed at the fix time is ≥ `courseMinSpeedMps` (3 m/s),
  not the held one (a stale moving speed after a dropout at a stop must not
  admit courses while parked); the existing OBD veto and Doppler gate kept;
- courseAccuracy ≤ 45° (cuts nothing on the acceptance set).

σ = max(courseAccuracy, 2°); only the course likelihood term was added
(position σ and tempering unchanged), and such a fix was never clean (no
initial heading, no reseed). Correlation: the course term was tempered by
the network-fix function and constant (`networkFixCorrelationS` 60 s),
measured from the last accepted speedless course in its own timestamp (not
`lastNetworkFixNs`, which courseless fixes advance too). With the key off
every replay output on the acceptance set matched main (90 runs; GeoJSON
byte-identical).

**Measurement** (release, Mac, seeds 1–5; roads = national + region-A, the
N3.2 default; key 0 columns = the baseline on main, which equals
logs/n32dec on the old drives; key 1 = commit 0b3a1f7 with
`--set speedlessCourse=1`). Gated value: metres for clean-long, clean,
manual; % of distance for the rest; consistency includes the truth's σ.
The six older drives have no speedless course: every value is identical in
both key columns (they are left out of the table; all pass).

| drive | roads | gated mean, key 0 → 1 (Δ, allowed) | consistency + σ, key 0 → 1 | first converged, key 0 → 1 | pins inside 95 % + truth σ, sum of 5 seeds, key 0 → 1 | speedless updates per seed (w < 0.1) | verdict |
|---|---|---|---|---|---|---|---|
| drive-7 | no | 1.128 → 0.698 % (−0.430, ≤ +0.1) | 99.6 → 98.9 % | 88 s, 0.58 km → same | 30 → 20 of 35 | 79 (30) | FAIL (consistency) |
| drive-8 | no | 1.482 → 1.506 % (+0.025) | 100 → 100 % | 665 s, 6.62 km → 329 s, 2.66 km | – | 24 (11) | PASS |
| drive-9 (1) | no | 10.21 → 10.26 % (+0.045) | 75 → 50 % | 318 s, 3.36 km → same | 15 → 10 of 15 | 15 (4) | FAIL (consistency) |
| drive-9 (2) | no | 8.38 → 8.59 % (+0.214) | 75 → 50 % | 318 s, 3.36 km → same | 15 → 10 of 15 | 36 (9) | FAIL (mean, consistency) |
| drive-7 | yes | 0.130 → 0.162 % (+0.033) | 96.3 → 94.1 % | 26 s, 0.14 km → 23–88 s, 0.12–0.58 km | 30 → 30 of 35 | 79 (30) | FAIL (consistency) |
| drive-8 | yes | 0.186 → 0.186 % (+0.000) | 100 → 100 % | 96–97 s, 0.66–0.68 km → 42–43 s, 0.22–0.24 km | – | 24 (11) | PASS |
| drive-9 (1) | yes | 0.042 → 0.048 % (+0.007) | 100 → 100 % | 242 s, 2.51 km → 234–236 s, 2.43–2.45 km | 15 → 15 of 15 | 15 (4) | PASS |
| drive-9 (2) | yes | 0.043 → 0.046 % (+0.002) | 100 → 100 % | 242 s, 2.51 km → 234–236 s, 2.43–2.45 km | 15 → 15 of 15 | 36 (9) | PASS |

- **Verdict.** The adoption rule FAILS. With roads (the gate): drive-7
  consistency (96.3 → 94.1 %); every other drive passes, and drive-9's
  criterion passes on every seed in both runs (0.03–0.07 %). Without roads:
  drive-7 and drive-9 (1) consistency, drive-9 (2) mean and consistency.
- **Gains, for the record.** drive-9's first-pin prior 446–448 → 204–207 m
  (both roads modes, every seed, σhead 63° → 16°); drive-8's convergence
  0.66 → 0.22 km with roads. drive-9's first converged moved only 6–8 s
  with roads and not at all without (318 s).

**Why it fails: the courses are not reliable.** Reference: the converged
heading of the key-0 run with roads (offline, every speedless fix while it
was converged, seeds pooled; `logs/n3sc/course-vs-ref.txt`).
- **drive-7: 80–150° off on every fix** (median 109°) while claiming
  17–44°. The offset is near-constant over minutes and drifts slowly, from
  about −80° at the start to about −150° at the end. Not explained by the
  phone's orientation (the same upright mount on drives 7–9, mean gravity
  within 0.05 g). Without roads it puts the pins at 87 s and 359 s outside
  the ellipse on every seed (prior error 63 → 434 m and 90–96 → 302–350 m);
  with roads seeds 3 and 4 lose 18 and 17 withheld clean fixes at
  2067–2103 s. drive-7's lower worst error without roads (1.13 → 0.70 %)
  comes from these wrong courses and is not evidence for the rule.
- **drive-8: a +22° bias** (median), within 2 × courseAccuracy on every
  fix, which makes heading converge fast and wrong without roads (6.62 →
  2.66 km, then 22° median off the matched road for 120 s; key 0: 1.4°).
- **Frozen values.** drive-7 and drive-8 repeat one course value for tens
  of seconds to minutes while the network positions jump
  (`logs/n3sc/frozen.txt`): on drive-7, seven fixes from 236.4 s to
  460.5 s carry a bit-identical course while the car drives 1.33 km and the
  fix positions jump 8–657 m between fixes (1414–2455 m accuracy); on
  drive-8, eight fixes from 335.8 s to 365.2 s hold one value within 0.001°
  over 361 m of driving (jumps 58–695 m), and three from 182.4 s to 331.5 s
  stay within 0.11° over 879 m. In these runs the car itself was going
  nearly straight (the reference heading moved 5° and under 1°), so a
  frozen value is not shown to have missed a turn, but it is not a fresh
  per-fix measurement either. drive-9 has only short near-repeats (two or
  three fixes over at most 23 s).
- **drive-9 is the only drive where the courses were good**: median
  |error| 12–14°, at most 22°.

**Why a gate cannot rescue it.** The drive-7 error is a systematic offset,
not noise, and it is there before the filter has a heading of its own.
- A consistency gate (reject a course far from the converged heading)
  needs a converged heading, which is exactly when the course is no longer
  needed; before convergence there is nothing to check a 90° offset against,
  and a course claiming 20° looks the same whether it is right or 90° off.
- A gyro check (course changes must follow the integrated yaw) passes a
  constant offset, because the differences of offset courses still track
  the turns. It could catch frozen values, but rejecting those leaves the
  offset.
- The claimed courseAccuracy does not flag it (17–44° on drive-7, the same
  range as drive-9's good courses).

Also: pre-convergence heading-up in the app (`GPSCourseBearingSource`)
needs a GNSS speed > 10 km/h, so it never used these courses either.
Outputs, scripts and the full table (heading error against clean GNSS
courses and matched edges, reseeds after convergence, weights, the probe's
counter cross-check): logs/n3sc/ (git-ignored; `table.md`, `dist.md`,
`course-vs-ref.txt`, `frozen.txt`, `run.sh`, `identity.py`, `table.py`,
`frozen.py`, the offline `probe/`).
