# N3.2a: the off-road model (test 3), measured

**Status: open, waiting for a decision (2026-10-13).** Branch `n3.2a` has the
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

## Recommendation

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
