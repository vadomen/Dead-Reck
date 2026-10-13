# N3.2a: the off-road model (test 3), measured

**Status: decided (2026-10-13): the plan's model is kept.** Test 3 stays a
recorded known FAIL (`withKnownIssue` in `NavigationRoadOffRoadTests`; Risks
R2 in docs/N3_PLAN.md; docs/NAVIGATION.md). Round 2 below: no variant passed
test 3 and kept tests 1, 4, 7 and 8, so the decision rule kept the plan.
The real-data check for capture is the wrong-road share on clean and
clean-long in N3.2b. Branch `n3.2a` has the
plan's road model as written (docs/N3_PLAN.md, "Road model in the filter")
and tests 1–2 and 4–13. Test 3 is `NavigationRoadOffRoadTests`, uncommitted.
No engine change is made until a candidate is picked. Review and merge happen
once, on the revised model.

## The case

Test 3: the car drives 1 km north on a road that is not in the pack. A mapped
road runs parallel, 40 m east. Heading is known from clean fixes up to 10 s;
after that only dead reckoning and roads. Pass condition (decided): at every
5 s check after 15 s, the estimate is not captured (< 25 m across), **or** the
truth is inside the 95 % ellipse. Keeping both hypotheses alive is fine.

This case is realistic for this car. The packs exclude `track` and
`service=parking_aisle` (Q5). Frontage roads, new roads and roads missing
from OSM come on top of that.

## What happens under the plan's model

Every seed is captured onto the mapped road: about 42 m off, with a
confident ellipse (cross-track semi-axis about 12 m), for 13 of 16 checks.

Timeline (seed 1, 1000 particles):

- **Up to t ≈ 22 s:** every particle mean stays 30–40 m from the road. They
  are not candidates (d²/S₀ > 9), and the share on the road is 0.
- **From t ≈ 23 s:** dead reckoning has grown the cross-track σ to 8 m. The
  tail of the cloud (about 0.1 % of the weight) passes the χ² gate.
- **About t = 27 s:** the share on the road reaches 0.98, 4–5 s after the
  first candidate.

Why the tail wins:

- **Weight.** A particle near and parallel to the road scores
  (1 − ε) · L_road ≈ 0.13 per metre-radian. One with no candidate scores
  ε · L_off = 0.1 / (2R · 2π) ≈ 1.6 · 10⁻⁴. That is about 800× per update,
  tempered by w ≈ 0.4 per second. Being near a road never costs weight.
- **Shift.** The moment-matched cross-track step moves each tail particle by
  r · g · d towards the road.
- **No memory.** ε is an independent "off-road" chance on every update,
  about one every 30 m. A car on the unmapped road for the whole kilometre
  must survive about 33 such votes.

Each mechanism alone is enough. With the shift kept and no weight change, the
cloud is still captured (47 m). With the weights kept and no shift, it is
still captured (36 m). Neither ε = 0.5 nor dropping the heading term changes
the outcome.

## Candidates, measured

All runs are seeds 1–5, 1000 particles, default config unless stated.
Prototype code: `logs/n32a/offroad/prototype.patch`, not committed.

- **(a) Persistent per-particle mode.** Each particle carries on/off. The
  mode switches with a per-distance hazard: 0.2, 1 or 5 per km, the same
  rate both ways, one uniform draw per particle per update.
  - *on*: scores L_road(e*) and is shifted, with r = 1.
  - *off*: scores L_off and is not shifted.
  - The initial cloud is half on, half off.
- **(b) Student-t cross-track** (ν 3, or ν 1 = Cauchy, scale √S₀) instead
  of the Gaussian in d. The ε mixture is kept.
- **(c) (a) + (b).**
- **(d) Extra, not asked for: (a) with a band off-road density.** *off*
  scores N(d; 0, P_cc + σ_off²) with σ_off 25 m, times the same heading
  term, against the nearest compatible road. That is "near a road but not
  on it" instead of uniform over ±R.

### Test 3 (failed checks out of 80, i.e. 16 per seed × 5 seeds)

| variant | roadCorrelationM 30 (default) | 100 | 300 | 1000 |
|---|---:|---:|---:|---:|
| plan | 65 | 60 | 45 | 17 |
| (a) 0.2 / 1 / 5 per km | 59 / 59 / 60 | | | |
| (b) ν 3 / ν 1 | 65 / 65 | | | |
| (c) 0.2 / 1 per km, ν 3 | 60 / 59 | | | |
| (a)+(d) 0.2 / 1 per km | 52 / 53 | — / 35 | — / 2 | — / 0 |

Worst cross-track error is 41–43 m in every cell except (a)+(d) at
roadCorrelationM 300 and 1000.

### Tests 1–13 with the same variants

Behaviour tests are 1 (cross-track convergence), 4 (fork), 7 (ring
convergence) and 8 (fix gate). The rest are probes written against the
plan's own mechanics (the Step 5 r ≥ 0.5 rule, every particle assigned), so
their failures under (a)–(d) are expected. They would be rewritten for a
revised model.

| variant | corr | behaviour tests failing | ring converged at | fork, 500 m past (right) | test 1 cross-track |
|---|---:|---|---:|---:|---:|
| plan | 30 | — | 280–300 m | 1.00 | < 6 m |
| plan | 300 | 7 | 520 m | | |
| plan | 1000 | 7 | never | | |
| (a)+(d) | 30 | 1 | | | |
| (a)+(d) | 300 | 4, 7, 8 | never | 0.09 at the fork | |
| (a)+(d) | 1000 | 1, 4, 7, 8 | never | 0.78 | 8.5 m |

At roadCorrelationM 30, (b) fails only test 3. (a) and (c) also fail test 1
(cross-track convergence), test 9 (an initialising moving pin snaps the
cloud onto the road: half the cloud starts off-road) and three plan-mechanics
probes (4-Step 5, 5-level hops, 6-oneway). Neither fixes test 3.

## Reading

No candidate fixes test 3 and keeps the road benefit.

- **The real evidence against capture is the dead-reckoned position.** The
  cloud's prediction is 40 m from the road, against a cross-track σ of
  8–20 m. Only its tail reaches the road, and that tail starts with about
  0.1 % of the weight.
- **Any on-road density that is sharp enough to help** (cross-track σr
  7 m) beats any diffuse off-road density by 10²–10³ per update. Tempering
  by 30 m lets it overturn the tail's 10⁻³ prior within seconds.
- **(a) is necessary but not sufficient.** It stops the ε re-vote, but the
  on-mode tail still wins on likelihood.
- **(b) changes nothing here.** The capturing particles are near the road,
  not in the tails of d.
- **(d) narrows the per-update ratio** from about 800× to about 4–80×. Only
  with much weaker tempering (300–1000 m) does that leave the off-road
  hypothesis alive.
- **That weak tempering costs the ring and fork cases,** which need strong
  road evidence over a few hundred metres.

The conflict is in the evidence itself: one tempering length cannot both let
roads decide a ring cloud's heading in 300 m and keep a parallel road 40 m
away from deciding a confident cloud's position in 50 m.

## Recommendation (round 1; measured in round 2 as (A), rejected)

**(a) + (d), with road evidence capped by the prior's support, not by
distance alone.** Concretely, for a decision, not built:

1. **Mode (a)** at about 1 per km (0.2–5 made no difference here). An off
   particle is never shifted.
2. **Band off-road density (d),** σ_off 25 m. It stands for "beside a road":
   car parks, service roads, frontage roads, unmapped roads.
3. **A per-update cap on the on/off likelihood ratio** of an on-particle
   against the cloud's off-mode at the same place: for example at most
   e^(w·κ), with κ about 2. A road can then outvote dead reckoning only at
   a bounded rate per metre driven.
   - A ring cloud has its off and on particles at similar positions, so the
     cap rarely binds.
   - A confident cloud whose tail alone reaches a parallel road is limited
     to about e² per 30 m, roughly 1.5 · 10³ over 1 km, against a tail
     prior of 10⁻³.
   - Whether this passes test 3 together with tests 4, 7 and 8 is unmeasured.

If you prefer to keep the plan's model: test 3 stays a known, measured FAIL,
recorded under Risks R2, and N3.2's replay results carry that caveat. The
replay set has no drive known to cross such a place, so N3.2 cannot measure
it on real data.

Either way, the decision changes Steps 3–5 of docs/N3_PLAN.md. The
pre-declared N3.2 experiment grids then need the new keys: switch rate,
σ_off, κ.

## Round 2: the variants and their grids (written before running)

Same measurements as above: test 3 at seeds 1–5 (failed checks out of 80),
and behaviour tests 1, 4, 7, 8 at seeds 1–5 (the engine's seed forced per
run). The behaviour tests are judged on the plan's stated numbers: test 1
cross-track < 6 m; test 4 both branches > 0.1 at the fork and the right one
> 0.9 at 500 m past; test 7 ring heading converged within 400 m and the
symmetric grid not collapsed; test 8 as written. Default config,
`roadCorrelationM` 30, unless a cell says otherwise.

**(A) (a) + (d) + a per-update cap κ.** Mode switch 1 per km, σ_off 25 m,
as (a)+(d) above. The cap is cloud-level:

  ℓ_ref = log( Σ_off wⱼ L_off,j / Σ_off wⱼ )   (the off-mode particles' weighted mean likelihood)
  log wᵢ += w · min(ℓᵢ, ℓ_ref + κ)              (every particle, on or off)

So per update no particle gains more than e^(w·κ) over the cloud's typical
off-mode particle. The literal reading, each on-particle against its own
off-mode score at the same place, is a no-op: at d ≈ 0 that ratio is
√((P_cc + σ_off²)/(P_cc + σr²)) ≈ 2.5, below e¹. Grid: κ ∈ {1, 2, 4}.

**(E) Geometry-novelty tempering** on the plan's model (ε mixture, no modes,
Steps 2–5 unchanged except w). After the candidates, the cloud's matched-road
direction θ_k is the axial mean (doubled angle) of the matched segments'
directions, weighted by wᵢ rᵢ. Then:

- Δθ = axial difference (0–90°) between θ_k and the θ of the last road update
  that had a match; 0 for the first match (meeting a road is not a turn).
- S, the straight-road evidence spent since the last turn, is refunded by
  the turn: S ← S · max(0, 1 − Δθ/θ₀).
- Distance term: w_d = min(Δs / `roadCorrelationM`, max(0, W_max − S)); S += w_d.
- w = min(1, Δθ/θ₀ + w_d), used for the weight and the shift as the plan's w.

Until W_max is spent this is the plan's model exactly. On a straight road
the cumulative evidence is at most W_max; a turn of θ₀ or more buys a full
update and refunds the budget. Grid: θ₀ ∈ {15°, 45°} × W_max ∈ {0.5, 1, 2, 4}
(8 cells).

Expected before running: (E) at small W_max passes test 3 and is slowest on
test 7's ring (one straight road, no turn); (A) depends on how often the cap
binds.

## Round 2: results

Prototype: `logs/n32a/offroad/prototype-r2.patch`, harness
`ZZProto-r2.swift`, raw output `r2-results/`; not committed. The prototype
reproduces round 1: plan 65, (a)+(d) at 1 per km 53, ring 280–300 m.

### Test 3 (failed checks out of 80)

| variant | failed | worst cross-track error (m), seeds 1–5 |
|---|---:|---|
| plan | 65 | 43 / 43 / 43 / 43 / 43 |
| (A) κ 1 / 2 / 4 | 50 / 53 / 53 | 41–42 in every cell |
| (E) θ₀ 15° or 45°, W_max 0.5 / 1 / 2 | 0 / 0 / 0 | 0–2 |
| (E) θ₀ 15° or 45°, W_max 4 | 52 | 50–71 |

θ₀ made no difference: no update in test 3 or test 7 sees a turn.

### Behaviour tests 1, 4, 7, 8 (seeds 1–5)

| variant | behaviour tests failing | ring converged at | fork, 500 m past (right) | test 1 cross-track |
|---|---|---:|---:|---:|
| plan | — | 280–300 m | > 0.9 (pass) | 0.0 m |
| (A) κ 1 / 2 / 4 | 1 (every seed) | 290–320 m | > 0.9 (pass) | 0.0 m |
| (E) W_max 0.5 | 7 ring (every seed) | never | > 0.9 (pass) | 1.7–1.9 m |
| (E) W_max 1 | 7 ring (every seed) | never | > 0.9 (pass) | 0.8–1.0 m |
| (E) W_max 2 | 7 ring (every seed) | never | > 0.9 (pass) | 0.4–0.5 m |
| (E) W_max 4 | 7 ring (every seed) | never | > 0.9 (pass) | 0.1–0.2 m |

Test 1 fails under (A) on its bit-exact along-track probe (along-track
and P_aa change by more than 1e-9). Its cross-track criterion passes. The
symmetric-grid half of test 7 and both test 8 cases pass in every cell.

### Reading

- **(A) does not help.** Even at κ 1 the tail beats the off-mode mean by
  e^(0.4 κ) per update. Over about 70 updates that overturns a 10⁻³ prior
  long before 1 km. (The round-1 recommendation's "about e² per 30 m,
  1.5 · 10³ over 1 km" was an arithmetic slip: e² per 30 m is e⁶⁶ per km.)
- **(E) fixes test 3 outright** (0 of 80, error ≤ 2 m) at W_max ≤ 2, and it
  keeps the fork, the gate and test 1. It fails only the ring, which has the
  same blind spot: one straight exit road, no turn. With W_max 2 the ring's
  total evidence is 2 tempered updates. Convergence there needs about 9.
- **The thresholds overlap.** The ring needs a total likelihood ratio of a
  few hundred to put its heading sector at 99 %. Test 3 needs the parallel
  road's ratio to stay below about 10³ against a 10⁻³ tail. With cloud-level
  heading novelty, no W_max does both: 2 passes 3 and fails 7, and 4 fails
  both.

### Not measured: the next candidate

What sets the ring apart is not the road's geometry but the particles'.
On the ring, wrong-heading particles move *away* from the road every update,
so each update is new evidence. In test 3, the tail and the bulk both run
parallel to the road, so each update repeats the last. A novelty term from
the change in the particles' distances to the road since the last update
(for example the weighted spread of Δd) would separate the two cases.
Heading novelty of the matched edge cannot. This is a follow-up option, not
part of N3.2a.
