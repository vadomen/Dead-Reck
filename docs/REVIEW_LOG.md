# Review log

Ledger for `/review-loop` runs (`.claude/skills/review-loop/SKILL.md`).
Statuses: CONFIRMED (verified against code, fixed in the round named),
REJECTED (verified not to hold — reason given), DEFERRED (MINOR, moved to
`docs/BACKLOG.md`). Reviewers must not re-raise REJECTED or DEFERRED items
without new evidence.

## Archived runs 1–16

In [docs/archive/REVIEW_LOG-runs-01-16.md](archive/REVIEW_LOG-runs-01-16.md):

- Run 1 — range `HEAD~1..HEAD` (80e0161..7acfa9a), started 2026-10-06
- M1 reviews (2026-10-07) — not a `/review-loop` run
- Run 2 — range `HEAD~1..HEAD` (189387e..5644625), started 2026-10-07
- Run 3 — range `803db28..0c7eda5` (M2 part 1), started 2026-10-07
- Run 4 — range `129c9d9..395aeac` (M2 part 2), started 2026-10-08
- Run 5 — range `641cdbd..c6a6368` (M3: prep fixes + UI), started 2026-10-08
- Run 6 — range `1af3a48..a7a5006` (M4 bench fixes), started 2026-10-08
- Run 7 — range `f885836..21aada9` (M4 follow-up: replay scope, plan reuse), started 2026-10-08
- Run 8 — M4.2 map camera + manual fix (1d61098..99e2b39)
- Run 9 — M4.3 map follow + heading-up (df91622..4afa2eb)
- Run 10 — M4.3 incl. M9.1 fixes (df91622..a7dbd83)
- Run 11 — N2 navigation engine + replay_nav (80fb354..43ed727), started 2026-10-09
- Run 12 — N2.1 engine update, step 0 of N4 (e15b30e..4d6b48b), started 2026-10-09
- Run 13 — whole navigation engine before N4 (80fb354..9753d19), started 2026-10-10
- Run 14 — N4 live navigation (main..n4-live-nav, 174e34e..94e7a20), started 2026-10-10
- Run 15: pre-drive manual-fix fixes (e2f7d13..7148677), started 2026-10-11
- Run 16: N3.1 road pack (main..n3.1-road-pack, b703157..2064dc3), started 2026-10-12

## Run 17: N3.1 follow-ups (main..n3.1-followups, 3d6f70e..2273684), started 2026-10-12

The range fixes R16.1-4 (zero-length segments collapsed in the builder, refused by the writer and `verify()`, builder version 2), R16.1-5 (`builder.commit` scoped to the builder paths, untracked files count as dirty) and R16.2-4 (`build_packs.sh` refuses an empty pack list, C-style loops). Format stays v1, changed before any pack was distributed. Branch: `n3.1-followups`.

### Round 1

Reviewer: fresh `reviewer` agent. Result: 0 BLOCKER / 0 MAJOR / 2 MINOR.

Verified clean: stacked-node topology (a node shared by 3+ ways, way ends, a way collapsing to one point, 3-chains, cross-way chains, non-consecutive coincident nodes giving a correct closed edge); merge determinism (smallest ID per group, ascending way order); segment keys stable across extracts; writer and `verify()` refusals reject nothing the builder can produce; mutations of the ID rewrite, the `verify()` check and the writer check each fail a test; golden hash reproduces the old pin with `builderVersion` "1"; the `builder.commit` path list covers every Core file the builder uses; `git -C` and `set -u` safe; bash 3.2 C-style loops and the empty/invalid `packs` guard; Core purity; no engine, replay, log or App change; no place names, relation IDs or real coordinates; nothing under `osm/` tracked.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R17.1-1 | MINOR | The stacked-node fixture has pairs only, so dropping `representative()` inside `union()` (`RoadGraphBuilder.swift:244-252`) passes every test while splitting a 3-chain into two nodes. Shipped code is correct. | DEFERRED | BACKLOG |
| R17.1-2 | MINOR | `build_packs.sh` checks for a non-empty `packs` array but not unique, non-empty string names; a misspelt key builds `null.roadpack`, a duplicate name overwrites the first pack. | DEFERRED | BACKLOG |

Tests: Core passes 661 tests in 95 suites (2273684). No App change.

**Loop stopped: no BLOCKER or MAJOR findings.**

### Run 17 summary

- **Rounds:** 1 run.
- **Findings:** 0 fixed in the loop, 0 rejected, 2 MINOR deferred (R17.1-1..2).
- **Fixed by the range itself:** R16.1-4, R16.1-5, R16.2-4.
- **Final tests:** `cd Core && swift test`: 661 tests in 95 suites pass. No App change.

## Run 18: N3.0 part 1 (5bcfb1e..54c0a6d), started 2026-10-12

The range commits the PLAN §6 ticks from drive-7 (6d2495a), the N3MF-1 backlog row (83c6c30), the sidecar `buildConfiguration` header field (d3f909f, sidecar v1, optional) and N3.0 step 1: first-pin pair scoring and truth-file `excludePins` (54c0a6d, scoring only, engine unchanged). Branch: `n3.0`.

### Round 1

Reviewer: fresh `reviewer` agent. Result: 0 BLOCKER / 0 MAJOR / 5 MINOR.

Verified clean: no engine, config or engine-input file in the diff; scoring marks only the scoring schedule, which ingestion never reads (skipping ingestion of not-scored pins fails 6 checks); pair rule (previous manual fix, inclusive ns boundary, chains, window 0 = old result, negative refused); exclusion (nearest within 0.1 s inclusive, duplicates, on a refinement, unmatched reported); max/end error and consistency over scored checkpoints only, nil and "n/a" with nothing scored; optional `pinScoring`/`notScored` decode from older files; sidecar field optional and omitted when nil, old headers decode, `--compare` unaffected, `DEBUG` only in the Debug config; NAV_SIDECAR Versions rule consistent with N3_PLAN's v2; log format untouched; Core purity; re-score table arithmetic; PLAN B-1 correctly not verified; no coordinates, place names, relation IDs or UDIDs committed.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R18.1-1 | MINOR | The exclusion tie rule ("the earlier one on a tie") is untested; `<` → `<=` passes every test. Shipped code is correct. | DEFERRED | BACKLOG |
| R18.1-2 | MINOR | `replay_nav` claims "copy kept" even if the `try?` backup write failed, then replaces metrics.json; the copy name is keyed by PID only. | DEFERRED | BACKLOG |
| R18.1-3 | MINOR | The pair window is not in the mode label, so runs with different windows overwrite each other's row in one `--out` (as `--set` already does). | DEFERRED | BACKLOG |
| R18.1-4 | MINOR | NAVIGATION.md:840 says refinement pins are "no longer separate checkpoints"; they stay in `checkpoints` with `notScored`. | DEFERRED | BACKLOG |
| R18.1-5 | MINOR | PLAN §6 N4 A-1 is labelled "Verified" though the pre-N4 `queueDepthMax` comparison was not done (the note says so). | DEFERRED | BACKLOG |

Tests: Core passes 672 tests in 96 suites (54c0a6d). App changed only in d3f909f; the simulator build and the app tests (241 in 38 suites) passed there, and App is unchanged since.

**Loop stopped: no BLOCKER or MAJOR findings.**

### Run 18 summary

- **Rounds:** 1 run.
- **Findings:** 0 fixed, 0 rejected, 5 MINOR deferred (R18.1-1..5).
- **Final tests:** Core 672 tests in 96 suites pass; app 241 tests in 38 suites pass (d3f909f).

## Run 19: N3.0 part 2 (0b59494..n3.0-part2), started 2026-10-12

The range adds drive-7 to the acceptance set (criterion proposed, awaiting the user), tolerant metrics/config decoding with a safe backup (R11.2-4, R12.1-1, R18.1-2), the replay read report and `--strict` (R11.1-8), skip scheduling for rejected inputs (R14.2-3), one consistency denominator (R13.1-8), consistency with the truth's σ (Q3, code and the adoption-rule change in separate commits), catch-up tests and docs, and backlog row T-2. Claimed: estimates bit-identical on all 42 acceptance runs; NavigationEngine untouched; NavigationConfig defaults unchanged. Branch: `n3.0-part2`.

### Round 1

Reviewer: fresh `reviewer` agent. Result: 0 BLOCKER / 1 MAJOR / 3 MINOR.

Verified clean: the tolerant decoder takes each default from `self.init()` (mutation caught), CodingKeys match the stored properties, encoding and `NavigationConfig().hashHex` unchanged, `--set` still refuses unknown keys, sidecar `--compare` never decodes a config; the backup never overwrites, is claimed only once written, exit 1 before `metrics.json` is touched; R14.2-3 rejection decided by `engine.accepts`, every input still ingested in the same order (mutations caught); `√(a² + 5.991σ²)` equals the ellipse of P + σ²I, 1.51 matches the engine's `fixSigmaPerAccuracy`; R13.1-8 and R11.1-8 tests discriminate; the Q3 adoption-rule change is explicit and in its own commit; drive-7 threshold reused unchanged and labelled; no engine, App, Log or LOG_FORMAT diff; Core purity; privacy.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R19.1-1 | MAJOR | A pin checkpoint's truth σ in the gated `consistencyWithTruthSigma` comes from the run's own config (`NavigationReplay.swift:638`, `options.config.manualFixSigma(...)`), so a change that raises pin σ (a `manualFixSigma*` default, a sweep, or N4MF-1) passes "consistency must not drop" by widening the truth while the engine's estimate and ellipse are bit-identical. | FIXED | Verified at :638 → :689; the :786 comment covered clean fixes only, and N4MF-1 changes `manualFixSigma`. Fix: pin truth σ from frozen replay constants (`NavigationReplay.manualFixTruthSigmaM`: max(30 m, mapSpanM/12)), independent of the run's config; the engine still uses its own `manualFixSigma`. N3_PLAN N4MF-1 item 2 constrained to match. Regression test `NavigationTruthSigmaConsistencyTests/pinTruthSigmaIgnoresConfig` fails with the old line (3 issues) and passes after. 42 acceptance runs identical before and after, both consistency definitions included. |
| R19.1-2 | MINOR | No replay output gives drive-7's gated figure (worst withheld clean fix, % of distance); `maxErrorPercent` covers pins too. | DEFERRED | BACKLOG |
| R19.1-3 | MINOR | NAVIGATION.md is ambiguous on whether drive-7's pins are inside the "consistency must not drop" gate (:594-595 vs :672-675). | DEFERRED | BACKLOG |
| R19.1-4 | MINOR | Merging an old metrics row rewrites it with today's keys only, so config keys or counters removed since are dropped; the doc mentions only added keys. | DEFERRED | BACKLOG |

Tests: Core passes 703 tests in 102 suites. No App change.

### Round 2

Reviewer: fresh `reviewer` agent (a first attempt was cut off by a network error before reporting and is not counted). Result: 0 BLOCKER / 1 MAJOR / 2 MINOR.

Verified clean: R19.1-1 complete for pin σ (`manualFixSigma(` called only by the engine; frozen formula matches the engine rule at the N3.0 defaults for nil, 0, negative, NaN and ∞ spans; no config key reaches it); the regression test fails on the old line, including the gated `inside95WithTruthSigma` check; pair window, exclusion tolerance, truth points, withholding and `motionStart` do not come from the config; NAVIGATION.md :491-500 and :616-623 match the code; no engine, default, App or log-format change; Core purity; privacy.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R19.2-1 | MAJOR | Which withheld fixes are scored clean-fix truth depends on the run's `cleanFixAccM` (`NavigationReplay.swift:635`), also an engine parameter: lowering it drops the worst 10–15 m fixes from the clean / clean-long / drive-7 gates and the consistency denominators; raising it adds 15–30 m fixes as truth. Same class as R19.1-1 (different parameter; not a repeat). | FIXED | Verified at :635 vs `NavigationEngine.swift:773`. Fix: frozen `NavigationReplay.cleanFixTruthAccM` = 15 m for truth selection; the engine keeps `cleanFixAccM`. Regression test `NavigationTruthSigmaConsistencyTests/cleanFixTruthIgnoresConfig` fails with the old line (12 issues for `cleanFixAccM` 4 and 30) and passes after; on clean-long `--set cleanFixAccM=4` used to empty the gate (0 checkpoints), now 277. 42 acceptance runs identical before and after. Also found: heading-convergence distance follows the run's `convergedHeadingStdDeg`; reported, not gated, left as is (R19.2-4). |
| R19.2-2 | MINOR | The % of distance denominator is built from the run's `obdSpeedOffsetKmh` and `obdMaxAgeS` (`NavigationReplay.swift:604-605`); 0.5 → 1.5 km/h moves a 1.2 % error by ~0.02–0.03 pp, below the 0.1 pp tolerance. | DEFERRED | BACKLOG |
| R19.2-4 | MINOR | Heading-convergence distance uses the engine's `converged` flag (`headingStdDeg < config.convergedHeadingStdDeg`, `NavigationEngine.swift:1351`), so a candidate raising the threshold reports earlier convergence with the same particles. Reported, not gated. Found by the round 2 fixer. | DEFERRED | BACKLOG |
| R19.2-3 | MINOR | `docs/N3_PLAN.md:502-508` N4MF-1 item 2 says pins are "scored with the σ above" (speed-dependent), contradicting its own frozen-truth sub-bullet. | DEFERRED | BACKLOG |

Tests: Core passes 704 tests in 102 suites. No App change.

### Round 3

Reviewer: fresh `reviewer` agent. Result: 0 BLOCKER / 0 MAJOR / 1 MINOR.

Verified clean: `NavigationReplay.swift:637` is the only place clean-fix truth is chosen and uses `cleanFixTruthAccM`; nothing outside the engine and the config reads `cleanFixAccM`; restoring the old line fails `cleanFixTruthIgnoresConfig` with 12 issues; docs and doc comments say ≤ 15 m inclusive, frozen; R14.2-3 withheld fixes never ingested and `truthEnd` uses the last accepted input; `truthSigmaPerAxisM` divides only clean-fix accuracies by 1.51; old `metrics.md` rows print "n/a" for the missing variant; Core purity; no engine, App, Log or LOG_FORMAT diff; privacy.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R19.3-1 | MINOR | The `EllipseConsistency` type comment (`NavigationReplay.swift:898-899`) still says the truth's σ is not added, although the same type now holds the gated `withTruthSigma` variant (:925-929). | DEFERRED | BACKLOG |

Tests: Core passes 704 tests in 102 suites (a5e76af). No App change.

**Loop stopped: no BLOCKER or MAJOR findings.**

### Run 19 summary

- **Rounds:** 3 run (plus one round 2 attempt cut off by a network error before reporting).
- **Findings:** 2 MAJOR fixed (R19.1-1 frozen pin truth σ, R19.2-1 frozen clean-fix truth selection), 0 rejected, 7 MINOR deferred (R19.1-2..4, R19.2-2..4, R19.3-1).
- **Final tests:** `cd Core && swift test`: 704 tests in 102 suites pass. No App change in the range.

## Run 20: N3.0 part 3 (main..n3.0-part3, 211d93f..38a8103), started 2026-10-12

First run under the new review setup (aadfc1e). The range: drive-7 criterion decided and the N3.2 drive-7 reported target, R19.2-3 and R19.3-1 (docs), then engine fixes R11.1-4, R11.1-5, R11.2-2, R11.2-3, R14.4-1, N4MF-1 and R11.1-7, one commit each with a regression test, and the N3.0 exit table. R11.1-6 failed the adoption rule on clean (+4.64 m mean) and is not in the range. Branch: `n3.0-part3`.

### Round 1

Reviewer: fresh `reviewer` agent (opus, new setup). Result: 0 BLOCKER / 2 MAJOR / 1 MINOR. Mutations: 3 run, 3 survived (M1 disable `pairSpeedOffsets`, M2 drop the macro-step moving marker, M3 independent draw for the odd particle in `macroStep`).

Verified clean: the exit table reproduces from `logs/n30/p3` (`judge.py`); clean seed 1 at HEAD and at 4dd5a10 byte-identical GeoJSON (R11.1-7 claim); N4MF-1 leaves the frozen truth σ untouched; the two new config keys decode tolerantly; the R14.4-1 backfill draws no random numbers; R11.2-3 inflates σ in quadrature only; the R11.1-5 marker is reset in `initialize`; odd particle counts handled; privacy.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R20.1-1 | MAJOR | R11.1-7's `pairSpeedOffsets` (`NavigationEngine.swift:733-741`, armed after every resample at :1345) overwrites each odd particle's stale speed offset with the negative of the even one's, so the speed error the GPS fixes taught the cloud is flipped back to ~0. OBD silent while accelerating with clean fixes: 1.5 / 10 / 29 m before R11.1-7, 9.9 / 50 / 98 m at HEAD, speed stuck at the stale OBD value, resamples 17 → 60. The acceptance set has no moving unknown-speed steps. | FIXED | Verified: the re-pair ran after resampling regardless of measurement updates. Fix: re-pairing removed; only the noise increments are antithetic, each particle keeps its own offset. Regression test `NavigationRun20Tests/resampleKeepsLearnedSpeedOffsets` fails at 38a8103 (59.87 m at 95 s, speed 15.2 m/s) and passes (seeds 1–40: 2.20 / 15.98 / 37.43 m vs 2.14 / 15.66 / 36.71 m before R11.1-7). 10-min drift unchanged (RMS 9.13 m). Acceptance 42/42 GeoJSON byte-identical (no stale moving or macro steps in the set). |
| R20.1-2 | MAJOR | Missing tests for new core logic: removing the macro-step "last moving step" marker (`:626`, R11.1-5) and drawing the odd particle independently in `macroStep` (`:604-605`, R11.1-7) each pass every test. | FIXED | New tests `NavigationRun20Tests/staleFixFromMacroStretchIgnored` (fails without the macro-step marker) and `macroStaleMeanDoesNotDrift` (fails with an independent odd draw: 28.32 m RMS). |
| R20.1-3 | MINOR | `docs/BACKLOG.md:116`: R11.2-3's status still begins "DEFERRED (remaining part)" with "DONE (N3.0 part 3)" appended; the fix covers the row. | FIXED | Status cell made DONE in this round's commit. |

Tests: Core passes 722 tests in 104 suites. No App change.

### Round 2

Reviewer: fresh `reviewer` agent (opus, new setup). Result: 0 BLOCKER / 0 MAJOR / 1 MINOR. Mutations: M1' (odd offset negated in `step`) killed by `resampleKeepsLearnedSpeedOffsets`; M3 (independent odd draw in `macroStep`) killed by `macroStaleMeanDoesNotDrift`; M4 (re-pairing restored at the start of `macroStep` only) survived → R20.2-1.

Verified clean: clean seed 1, HEAD vs 38a8103, byte-identical GeoJSON; `pairSpeedOffsets` and its arming gone; pairs 2k/2k+1 share one negated draw in `step` and (n3, n4) in `macroStep`, odd last particle draws alone; draw count and order unchanged; each increment keeps its marginal variance and posterior offsets are carried, so no variance is removed without information; R20.1-1..3 fixed; NAVIGATION.md R11.1-7 paragraph and exit-table row match the code and numbers; privacy.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R20.2-1 | MINOR | No test checks that a macro step keeps each particle's learned stale speed offset: re-pairing restored in `macroStep` alone (`NavigationEngine.swift:601-610`) passes every Navigation test (fixes until 89 s, inputs lost until 200 s: 923–937 m at HEAD vs 1064–1084 m with the mutation). Code is correct. | DEFERRED | BACKLOG |

Tests: Core passes 722 tests in 104 suites (5a3e69a). No App change.

**Loop stopped: no BLOCKER or MAJOR findings.**

### Run 20 summary

- **Rounds:** 2 run.
- **Findings:** 2 MAJOR fixed (R20.1-1 learned stale offsets erased after resampling, R20.1-2 missing macro-step tests), 1 MINOR fixed in the round (R20.1-3), 0 rejected, 1 MINOR deferred (R20.2-1).
- **Final tests:** `cd Core && swift test`: 722 tests in 104 suites pass. No App change.

## Run 21: N3.2a road model in the engine (main..n3.2a, 027cedb..fec31dd), started 2026-10-13

The range adds the road config keys, counters and estimate fields, `RoadMatcher` and the road update in `NavigationEngine(config:roads:)` with tests 1–2 and 4–13, test 3 (unmapped road next to a mapped parallel one) as a known issue (`withKnownIssue`), and `docs/N3_ROAD_OFFROAD.md` with two prototype rounds and the decision to keep the plan's model (test 3 a known FAIL). About 2200 changed lines, so three reviewers in parallel on disjoint sets: engine (NavigationEngine/Config/Estimate), matcher and tests (RoadMatcher, NavigationRoadTests, NavigationRoadOffRoadTests), docs (N3_ROAD_OFFROAD, N3_PLAN, NAVIGATION). Branch: `n3.2a`.

### Round 1

Reviewers: three fresh `reviewer` agents (opus for engine and matcher/tests, sonnet for docs). Result: 0 BLOCKER / 7 MAJOR (6 distinct; the reseed-clear finding was raised by both code reviewers and is one row) / 5 MINOR. Mutations: 6 run, 6 survived (Step 5 `r >= 0.5` → `r > 0`; end-vertex h as the segment normal; reseed `clearRoadState` removed; moment-matching `mix = 0`; fix gate `course: nil`).

Verified clean: matcher Step 2 eligibility and the Step 4 algebra (coupling 0, 1, Joseph); cell cache and store lookup-only; `withKnownIssue` wraps only the capture checks; round-2 tables match the raw results; no-roads replay of clean seed 1 byte-identical to N3.0; privacy.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R21.1-1 | MAJOR | `anchorToRoad` (`NavigationEngine.swift:1342-1348`) used evidence max(roadDistanceM, roadCorrelationM), so a moving pin compatible with the cloud (no reset) applied the road again at weight 1 right after a regular road update: the same cross-track measurement counted twice (P_cc too small by about R/(P+R)), and Step 5 added 30 m off-road for ~0 m driven. | FIXED | Verified. Fix: weight 1 only when the pin initialised the engine or caused a manual reset; otherwise tempered by roadDistanceM. Regression test `NavigationRoadTests/compatiblePinAnchorIsTempered` fails at fec31dd (4 issues) and passes; `initialisingPinAnchors` kills the init-path mutation. |
| R21.1-2 | MAJOR | `bookkeepingThreshold` (`NavigationRoadTests.swift:505-531`) never produced 0 < r < 0.5: its odd particles failed the χ² gate (625 > 9·53), so `r >= 0.5` → `r > 0` survived. | FIXED | Rewritten with ε 0.9 and odd particles inside the gate (0.05 < r < 0.5, read back from the cross-track move); the mutation fails. |
| R21.1-3 | MAJOR | The Step 2 end-vertex case of `RoadMatcher.nearest` (`RoadMatcher.swift:185-201`) was untested: h as the segment normal survived. | FIXED | New tests `nearestPointAndDirection` (interior both sides, before start, past end on and off the axis, on each vertex) and `deadEndPullsAlongAxis`; the mutation fails both. |
| R21.1-4 | MAJOR | Test 13's reseed check (`NavigationRoadTests.swift:956-965`, `cleared.count > 50 \|\| resamples increased`) passed with the reseed's `clearRoadState` removed; reseeded particles' edge and level were never checked. Raised by both code reviewers. | FIXED | Rewritten with resampling off, non-default road state on every particle, reseeded particles identified by heading: they are cleared, the rest keep theirs. Mutation fails (80 issues). |
| R21.1-5 | MAJOR | Step 4 moment matching's r(1−r)ΔμΔμᵀ term (`NavigationEngine.swift:1481`) untested: `mix = 0` passed every test. | FIXED | New test `momentMatching` (r ≈ 0.5, μ and P checked against the formula, 1e-6); the mutation fails. |
| R21.1-6 | MAJOR | The fix gate's heading check was untested: passing `course: nil` to the gate survived. | FIXED | New test `fixGateHeading`: perpendicular cross street and a oneway against the course (rejected), matching courses and a two-way street (accepted); `course: nil` and "ignore oneway" mutations fail. |
| R21.1-7 | MINOR | `roadUpdateIntervalS` has no upper clamp (`NavigationConfig.swift` road validation; `NavigationEngine.swift:216`): `--set roadUpdateIntervalS=1e10` traps in `Int64(...)` at engine init. | DEFERRED | BACKLOG |
| R21.1-8 | MINOR | `docs/N3_ROAD_OFFROAD.md:3-12`: stale text under the status line ("Test 3 … uncommitted"; "No engine change is made until a candidate is picked. Review and merge happen once, on the revised model."). | DEFERRED | BACKLOG |
| R21.1-9 | MINOR | `docs/N3_ROAD_OFFROAD.md:156-163`: the round-1 "If you prefer to keep the plan's model… Either way, the decision changes Steps 3–5…" paragraph reads as open after the decision. | DEFERRED | BACKLOG |
| R21.1-10 | MINOR | `docs/N3_ROAD_OFFROAD.md:245-253`: "no W_max does both" goes beyond the measured grid (0.5–4); "(E) fixes test 3 outright" works by switching straight-road evidence off; the W_max 4 row hides that seed 2 passes (0 failed, worst 50 m). | DEFERRED | BACKLOG |
| R21.1-11 | MINOR | `docs/N3_PLAN.md:828-830`, `docs/NAVIGATION.md:970-972`: wrong-road share is called the real-data check for capture, but it scores only fixes whose truth is on a mapped edge, so capture while the car is on an unmapped road is invisible to it; it checks capture onto a wrong mapped road only. | DEFERRED | BACKLOG |

Tests: Core passes 753 tests in 106 suites, 39 known issues (all test 3). No App change. No-roads acceptance set (seeds 1–5 + as-live, 7 drives) 42/42 GeoJSON byte-identical and no metrics field differs vs N3.0 (`logs/n32a/r21-1`).

### Round 2

Reviewers: two fresh `reviewer` agents (opus): engine sources and docs; matcher and tests. Result: 0 BLOCKER / 4 MAJOR / 0 new MINOR. Mutations: the 7 round-1 mutations are all killed by the round-1 tests. New: 6 run, 5 survived (macro-step Δs accumulation removed; Δs zeroed in the not-engaged and no-road branches; level forgetting removed; χ² gate removed, only test 3's known issues rose 39 → 45; `pack(ofEdge:)` always 0), 1 killed (S₀ from P_ee instead of hᵀPh).

Verified clean: the R21.1-1 fix on every pin path (initialising, late, reset, compatible; reset clears road state before any resample); Steps 0–5 numerics; fix gate order before reseed; determinism; causality; config validation; R21.1-2..6 tests robust (closed forms at 1e-6, wide margins, fixed seeds); no-roads replay of clean seed 2 byte-identical to N3.0.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R21.2-1 | MAJOR | No test checks that driven distance carries over a road update that did not run: the macro step's `roadDistanceM += meanSpeed * dt` (`NavigationEngine.swift:671`) and the not-engaged and no-road branches (`:1383-1408`). Removing either passes every test; after an OBD dropout or a car park the first road update would be weighted by about one step of distance. | FIXED | Code correct. Extended `noRoadUpdateInMacroStep` and `carParkIsNoOp`, new `notEngagedKeepsDistance`: Δs equals the distance driven (bit-identical to a 1e6 s-interval run), and the next update equals `roadUpdate(evidenceDistanceM: Δs)` bit for bit. All three mutations fail. |
| R21.2-2 | MAJOR | Level forgetting (`offRoadM > roadLevelForgetM` → unknown level, `NavigationEngine.swift:1513`) untested; removing it passes every test. | FIXED | Code correct. New test `levelForgetting` (bridge fixture: 101 m forgets, exactly 100 m keeps; forgotten particles then take the bridge, the rest stay blocked). Removal and `>` → `>=` both fail. |
| R21.2-3 | MAJOR | The Step 2 χ² gate (`RoadMatcher.swift:278`) is pinned only inside test 3's known-issue block; deleting it passes every other test. | FIXED | Code correct. New test `innovationGate` (P = 25·I: 24 m inside the gate moves r·g·d, 28 m outside unchanged; closed form shows r ≈ 0.75 without the gate). Deleting the gate fails. |
| R21.2-4 | MAJOR | Multi-pack edge indexing in `RoadMatcher` (`edgeBase`, `pack(ofEdge:)`, `matchedEdge`, `isEdge` across packs; `:40-46`, `:303-321`) untested: every road test loads one pack. | FIXED | Code correct. New test `twoPacks` (7 + 6 edges, `edgeBase` [0, 7, 13]; matchedEdge per pack; level rule blocked across packs). `pack(ofEdge:)` always 0, dropped `edgeBase` offset and a pack-blind `isEdge` fail; removing only `guard pa == pb` survives because a foreign index is out of the other pack's range (redundant guard, kept). |

Tests: Core passes 757 tests in 106 suites, 39 known issues (all test 3). No App change. No engine code changed this round (tests only), so replay outputs equal round 1's.

### Round 3

Reviewers: two fresh `reviewer` agents (opus): engine sources and docs; matcher and tests. Result: 0 BLOCKER / 5 MAJOR / 1 MINOR. Mutations: every ledger mutation from rounds 1–2 is killed. New: 6 run, 5 survived (fix gate without `isFresh`; fix gate with the on-road share forced to 1; Step 2 gate ignoring oneway; `levelHops = roadLevelHops − 1`; a `fatalError` probe in the `storeIndices` dictionary fallback, never reached), 1 killed (`roadUpdateIfDue` ignoring the interval).

Verified clean: Steps 0–5 against the plan (update timing, Δs, split, L_off, pᵢ/rᵢ, Step 4 algebra and rotation, Step 5, matchedEdge argmax); the fix gate's order before reseed; every pin-anchor path (R21.1-1 holds); re-anchor cache clearing; determinism; causality and the late-pin ring with roads; the round-2 tests; privacy; no-roads replay of manual seed 3 byte-identical to N3.0.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R21.3-1 | MAJOR | The fix gate's on-road-share condition (`NavigationEngine.swift:1552`) is untested: forcing the share to 1 (nil included) passes every test; `fixGateConditions` claimed an off-road-cloud case it did not have. Without it, a car on an unmapped road would have every GNSS fix rejected. | FIXED | Code correct. New test `fixGateOnRoadShare` (share 0 with no road near, share 0 with a wrong-way oneway near, share nil when not engaged: 0 rejected; on-road control: 1). `fixGateConditions` display name corrected. Mutation fails. |
| R21.3-2 | MAJOR | The fix gate's fresh-OBD condition (`isFresh(at:)`, `NavigationEngine.swift:1551`) is untested: removing it passes every test. During an OBD dropout the held speed would keep the gate armed. | FIXED | Code correct. New test `fixGateStaleOBD` (OBD stops 4 s before the fix, share ≥ 0.8: 0 rejected; fresh: 1). Mutation fails. |
| R21.3-3 | MAJOR | The Step 2 oneway direction gate (`RoadMatcher.swift:272`) is untested: test 6's dψ = π likelihood decides on its own, so "ignore oneway" passes; at `roadHeadingSigmaDeg` 60 a wrong-way particle would be captured (r ≈ 0.53). | FIXED | Code correct. New test `onewayDirectionGate` (σψ 10° and 60°: no edge, no move, share 0, matchedEdge nil; closed form shows r ≥ 0.5 without the gate at 60°). Test 6's comment corrected. Mutation fails. |
| R21.3-4 | MAJOR | The level-rule hop boundary is untested: no candidate exactly `roadLevelHops` away and the key never varied, so `levelHops = roadLevelHops − 1` passes. | FIXED | Code correct. New test `levelRuleHopBoundary` (an edge exactly 2 hops and one 3 hops from the bridge; hops 1/2/3 block 100/50/0). `− 1` and `+ 1` mutations fail. |
| R21.3-5 | MAJOR | The `storeIndices` dictionary fallback (`RoadMatcher.swift:151-163`, cells spanning more than 128 × 128) is never executed by any test. | FIXED | Code correct. New test `storeIndicesBothPaths` (151 × 151 box: fallback; 78-cell box: window; indices [0, 1, 0, 2], every store slice equal to `planeCell` field by field). The reviewer's example box (301 × 2) would have stayed on the window path. The `fatalError` probe is reached by this test only; a wrong repeated-cell index fails. |
| R21.3-6 | MINOR | `invalidReason`'s doc (`NavigationConfig.swift:472-476`) says a replay reports invalid keys first, but `replay_nav` never checks it: `--set roadAlongTrackCoupling=2` traps at engine init. | DEFERRED | BACKLOG |

Tests: Core passes 762 tests in 106 suites, 39 known issues (all test 3). No App change. Tests only this round (plus two test comments and one display name); replay outputs equal round 1's.

### Round 4

Reviewers: two fresh `reviewer` agents (opus): engine sources and docs; matcher and tests. Result: 0 BLOCKER / 1 MAJOR / 3 MINOR. Mutations: 6 run. Engine: split eigenvector angle mirrored, minor axis never split, `cloudSemiMajorM` without the spread of means: all survived. Matcher: signed dot for two-way roads in the heading likelihood and two-way heading gate removed: killed (by `twoPacks` and `levelForgetting`, not by targeted tests); Step 2 radius guard removed: survived.

Verified clean: the round-3 tests catch their mutations (read against the code); engine, config and estimate against the plan; road state through reseed, reset and resample; validation; Swift 6 (no `@unchecked`, no `Date()`); Core imports; privacy; no-roads replay of jammed seed 4 byte-identical to N3.0.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R21.4-1 | MAJOR | The Step 1 split's geometry (`NavigationEngine.swift:1415-1436`) is untested: every numeric road test sets `roadSplitSigmaM` 1000, and tests 4, 7, 12 check only outcomes; a mirrored eigenvector angle and a never-split minor axis both pass every test, and either would corrupt the mixture on every road update of a correlated cloud. | FIXED | Verified (no test checks split moments or P). Round 4 was the last round: loop stopped, user chose "add the test, then merge". New test `NavigationRoadTests/splitGeometry` (4ec83a3): rotated anisotropic P at +30° and −60°, major-only / both / no split; mean shift v·√(λ − σs²)·z from the engine's own RNG stream, σs² along each split eigenvector, one pair drawn per split. Code unchanged. A fresh `reviewer` (sonnet) on 7a42014..4ec83a3 found nothing; both mutations and a z₂ → z₁ swap are killed. |
| R21.4-2 | MINOR | `cloudSemiMajorM`'s spread-of-means term untested. | DEFERRED | BACKLOG |
| R21.4-3 | MINOR | Step 2 radius guard untested (matters only with `roadSplitSigmaM` above about 15). | DEFERRED | BACKLOG |
| R21.4-4 | MINOR | NAVIGATION.md configuration table lacks the road keys. | DEFERRED | BACKLOG |

Tests: Core passes 762 tests in 106 suites, 39 known issues (all test 3). No App change.

**Loop stopped after round 4 with one MAJOR (R21.4-1, a missing test of correct code). The user chose to add the test and merge; a fresh review of the test found nothing.**

### Run 21 summary

- **Rounds:** 4 run, plus a follow-up review of the R21.4-1 test.
- **Findings:** 1 MAJOR bug fixed (R21.1-1 pin anchor counted the road twice); 15 MAJOR missing tests added (R21.1-2..6, R21.2-1..4, R21.3-1..5, R21.4-1), none exposed a bug; 0 rejected; 9 MINOR deferred (R21.1-7..11, R21.3-6, R21.4-2..4).
- **Final tests:** `cd Core && swift test`: 763 tests in 106 suites pass, 39 known issues (all test 3, the decided known FAIL). No App change. Without roads, the 42 acceptance runs are byte-identical to N3.0.

## Run 22: N3.2b replay_nav roads and first road measurement (main..n3.2b, 10b2551..5efbb20), started 2026-10-13

The range adds `replay_nav --roads` (repeatable) and `--wrong-road-tolerance`, the offline road truth and road metrics, `roads`/`roadSetHash` in every output and the `-roads-<hash>` label, GeoJSON matched edges and rejected fixes, the unmapped/captured metric (R21.1-11), R21 MINOR fixes, and the first measurement with roads (no tuning). About 1380 changed lines, one reviewer. Branch: `n3.2b`.

### Round 1

Reviewer: one fresh `reviewer` (opus). Result: 0 BLOCKER / 4 MAJOR / 2 MINOR. Mutations: 3 run, 3 survived (off verdict `share < 0`; captured without the inside-95 clause; truth heading gate ignoring oneway).

Verified clean: verdict/tolerance/ambiguity/15 m truth-edge/course/captured rules against the spec; ellipse-across-edge maths; rejectedOffRoad attribution in the normal path; Codable back-compat; ReplayRoadSet hash; label; GeoJSON; CLI; Core imports; privacy; doc numbers against logs/n32b/roads seeds 1–5; no-roads clean seed 1 byte-identical to N3.0 and the roads run reproduced exactly.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R22.1-1 | MAJOR | `docs/NAVIGATION.md:991-995`: clean's road truth is 20.3 % ambiguous on every seed, over the plan's 20 % Viterbi trigger (`N3_PLAN.md:536`), yet the doc attached the trigger only to drive-7 and reported clean's wrong-road share (a gated N3 criterion) as passing. | FIXED | Verified. Docs state both clean and drive-7 are over the trigger and clean's wrong-road figure is provisional; Viterbi match is the user's decision. |
| R22.1-2 | MAJOR | The `off` verdict (`NavigationReplay.swift:799`) is untested: `share < T.onRoadShare` → `share < 0` survives; every test has offShare 0. | FIXED | Verified. Test added in cf732b3; mutation killed. |
| R22.1-3 | MAJOR | Captured's "truth outside the 95 % ellipse" clause (`NavigationReplay.swift:812-814`) is untested: dropping it survives; the unmapped test re-derives the count from the fixes' own fields and never yields captured. | FIXED | Verified. Test added in cf732b3; mutation killed. |
| R22.1-4 | MAJOR | The offline road truth's oneway rule (`ReplayRoads.swift:350`) is untested: ignoring oneway survives; on a dual carriageway the opposite way could compete or win, inflating ambiguity and mis-scoring wrong road. | FIXED | Verified. Test added in cf732b3; mutation killed. |
| R22.1-5 | MINOR | `docs/NAVIGATION.md:997-998`: "drive-7 29 of 273" withheld clean fixes; withheldCleanFixes is 266 (273 includes pins). | FIXED | One-word docs fix, made in the round. |
| R22.1-6 | MINOR | `NavigationReplay.swift:658-663`: `rejectedOffRoad` is marked only when the counter moves during a `.location` ingest; a held stale fix applied inside an OBD ingest and rejected by the gate is counted in `fixesRejectedOffRoad` but missing from `rejectedFixes` and the GeoJSON. Reachable only with `--set roadFixGateMinKmh=0`. | DEFERRED | BACKLOG |

Tests: Core passes 782 tests in 107 suites, 39 known issues (all test 3). No App change. Each new test kills its mutation (25, 2, 4 issues).

### Round 2

Reviewer: one fresh `reviewer` (opus). Result: 0 BLOCKER / 3 MAJOR / 0 MINOR. Mutations: 3 run, 3 survived (off threshold `share <= 0`; captured without the cross-track clause; distance weights from any previous fix).

Verified clean: the four round-1 tests test real behaviour; summary, markdown and GeoJSON road output (matched edge with the ellipses every 10 s plus one at the end); `configChanges` and the R21.1-7 clamp; `ReplayRoadSet` `==`/`hash`, label and `roadSetHash` change with pack order; ms/step and road-counter figures against `logs/n32b/timing-*`; moved backlog rows unchanged apart from status; privacy; jammed-A/B seed 1 without roads byte-identical to N3.0, clean seed 1 with roads reproduced. Noted, not a finding: pack order changes engine results (clean seed 1 reversed: 15.6 m vs 21.75 m max), an N3.2a engine property; the runs get different labels.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R22.2-1 | MAJOR | The off verdict's 0.5 threshold (`NavigationReplay.swift:799`) is untested: `offVerdict` only produces share exactly 0, so `share <= 0` survives, though real off fixes on clean-long and drive-7 have 0 < share < 0.5. A narrower follow-up to R22.1-2, not the same finding. | FIXED | Verified. Test `offThreshold` in 6192f6d (share 0.36–0.44 → off, 0.55–0.61 → right); mutation killed (51 issues). |
| R22.2-2 | MAJOR | Captured's cross-track clause (`NavigationReplay.swift:813`) is untested: `unmapped()` re-derived the formula and both round-1 fixes were already < 25 m across. | FIXED | Verified. Test `capturedNeedsNarrowCrossTrack` (≈ 12 m across: captured; ≈ 31 m: not) in 6192f6d; `unmapped()` rewritten with literals; mutation killed. |
| R22.2-3 | MAJOR | The distance-weight rule (`NavigationReplay.swift:825`, since the previous fix with a usable course) is untested; dropping the `where` moves drive-7 seed 1 wrong-by-distance 3.54 % → 2.14 %. | FIXED | Verified. Test `weightsSkipNoCourseFixes` in 6192f6d; mutation killed (3 issues). |

Tests: Core passes 785 tests in 107 suites, 39 known issues (all test 3). No App change.

### Round 3

Reviewer: one fresh `reviewer` (opus). Result: 0 BLOCKER / 2 MAJOR / 2 MINOR. Mutations: 3 run, 3 survived (margin threshold `log(1.01)`; heading term dropped from the truth likelihood; margin competitors from within 15 m only).

Verified clean: all of `ReplayRoads.swift` (match/margin/ambiguity, 15 m vs 50 m radii, nearby/nearestSegment, semiAxisAcross/support against `ErrorEllipse`'s bearing convention, `ReplayRoadSet` ==/hash/`roadSetHash`, `DistanceStats` nearest rank exact for n ≤ 5000); `scoreRoad`/`finishRoadMetrics`; `ReplayReport`; CLI checks for `--roads`/`--wrong-road-tolerance`; the round-2 tests are not tautological; doc figures against `logs/n32b/roads` seeds 1–5; drive-7 and manual seed 1 without roads byte-identical to N3.0; privacy.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R22.3-1 | MAJOR | The matched/ambiguous margin threshold (`ReplayRoads.swift:365`, `marginRatio` 2 at :100) is untested: only a tie and ln ratio > 1 are exercised, so `log(1.01)` survives; on clean seed 1 it moves ambiguity 20.3 % → 2.3 %, under the Viterbi trigger, silently removing the premise of R22.1-1. | FIXED | Verified. Test `truthMarginThreshold` in d1c4114 (ln ratio 0.675 → ambiguous, 0.713 → matched); `log(1.01)` and `log(4)` killed. |
| R22.3-2 | MAJOR | The truth likelihood's heading term (`ReplayRoads.swift:353`) is untested: every test road is N–S, so dropping it survives; on clean seed 1 ambiguity goes 20.3 % → 31.6 %. | FIXED | Verified. Test `truthHeadingTerm` in d1c4114 (way along the course vs a nearer way at 30°; course accuracy 2°, 60°, 90°); the drop and a σ_course-floor-only mutation killed. |
| R22.3-3 | MINOR | The margin's competitor set (every heading-compatible edge within 50 m, not only within 15 m; `ReplayRoads.swift:363`) is untested; on real data no threshold moves (drive-7 33.2 % → 32.6 %). | DEFERRED | BACKLOG |
| R22.3-4 | MINOR | `docs/N3_PLAN.md:527, 534-535` as-built text: σ_fix = accuracy / 2.45, but the code divides by `NavigationReplay.accuracyPerSigma` 1.51; the margin is over the best edge of any other *way*, not "the second-best edge". | DEFERRED | BACKLOG |

Tests: Core passes 787 tests in 107 suites, 39 known issues (all test 3). No App change.

### Round 4

Reviewer: one fresh `reviewer` (opus). Result: 0 BLOCKER / 3 MAJOR / 0 MINOR, all untested code whose mutation moves a published figure; no bug found. Mutations: 3 run, 3 survived (`ambiguousShare` over all withheld clean fixes; `candidateTestsPerParticle` without `/ particleCount`; truth heading gate 45° → 89°). Verified: the round-3 tests cover R22.3-1/2 with expected values matching `RoadTruthMatcher.match`; `Core/Sources` unchanged since 5efbb20, so `logs/n32b/roads` still describes the code.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R22.4-1 | MAJOR | `ambiguousShare` (`NavigationReplay.swift:846`, over matched + ambiguous) is tested only at 0 and 1, never with mixed statuses: over all withheld clean fixes it survives and moves clean 20.3 % → 12.5 % (under the Viterbi trigger, flipping the summary line and R22.1-1) and drive-7 33.2 % → 24.1 %. | FIXED | Verified. User chose "add the tests, then merge". Test in aa35d7b; mutation killed. |
| R22.4-2 | MAJOR | `candidateTestsPerParticle` (`NavigationReplay.swift:861-862`) is untested (only `candidateTestsPerUpdate != nil`): dropping `/ particleCount` survives, turning the published 15–33 (≤ 64) into ~22 800. | FIXED | Verified. User chose "add the tests, then merge". Test in aa35d7b; mutation killed. |
| R22.4-3 | MAJOR | The truth's 45° heading gate (`ReplayRoads.swift:91`, used at :350) is untested for a two-way way outside it (tests cover 30° and a reverse oneway only): 89° survives; drive-7 seed 1 off share 0.8 % → ~4.5 %, noRoad 44 → 35, matched 129 → 134. | FIXED | Verified. User chose "add the tests, then merge". Test in aa35d7b; mutation killed. |

**Loop stopped after round 4 with three MAJORs (missing tests of correct code). The user chose to add the tests and merge.** Tests in aa35d7b: `ambiguousShareMixed` (1/7 and 1/4, both sides of the Viterbi line), `rightRoad` (300 candidate tests per update, 1.0 per particle), `truthHeadingGate` (60° alone noRoad, 60° beside an aligned way not a competitor, 40° matched). A fresh `reviewer` (sonnet) on 55c19ff..aa35d7b found nothing; denominator, `/ particleCount`, gate 45 → 89 and 45 → 30 mutations all killed.

Tests: Core passes 789 tests in 107 suites, 39 known issues (all test 3). No App change.

### Run 22 summary

- **Rounds:** 4 run, plus a follow-up review of the round-4 tests.
- **Findings:** 1 MAJOR docs fix (R22.1-1: clean's road truth over the Viterbi trigger, wrong-road share provisional); 11 MAJOR missing tests added (R22.1-2..4, R22.2-1..3, R22.3-1..2, R22.4-1..3), none exposed a bug; 1 MINOR fixed (R22.1-5); 0 rejected; 3 MINOR deferred (R22.1-6, R22.3-3, R22.3-4).
- **Final tests:** `cd Core && swift test`: 789 tests in 107 suites pass, 39 known issues (all test 3, the decided known FAIL). No App change. `Core/Sources` unchanged since 5efbb20, so the N3.2b measurement in `logs/n32b/roads` stands; without roads the acceptance runs are byte-identical to N3.0.

## Run 23: N3.2c items 7, 2, 6 and the N3.2d grids (main..n3.2c, a1055f2..740d3b9), started 2026-10-13

The range makes results independent of pack order (76ad76e), splits the unmapped count into far and incompatible-course fixes (af7a406), adds `NavigationRoadPerfTests` (511c28a), and records the pre-declared N3.2d road grids as docs only, with no config chosen (740d3b9). Branch: `n3.2c`.

### Round 1

Reviewer: one fresh `reviewer` (opus). An earlier attempt was stopped by the user before it produced findings and is not counted. Result: 0 BLOCKER / 1 MAJOR / 3 MINOR. Mutations: 3 run. M1 (sort removed in `RoadNetwork.init`) was killed. M2 (far/incompatible swapped in the captured split) and M3 (`noRoad` checked before the distance rule in `UnmappedReason.of`) survived.

Verified clean: every pack index after the sort (matcher `edgeBase`, `matchedEdge`, the level rule, `isShadowed`/`forEachSegment`, `covers`, road-truth `nearby`, GeoJSON `pack`, `ReplayRoadSet` ==/hash, `build_roads --network` naming); duplicate refusal (`replay_nav` exit 2); old metrics.json rows decode; no default config changed; privacy; clean seed 1 with packs reversed byte-identical to `logs/n32b/roads`; `roadFixGateSigma=0` disables the gate (35 GeoJSON byte-identical); N3.2d tables match `judge-vs-n30`/`judge-vs-n32b` (16 values × 6 drives) and `residuals.txt`; the perf test re-run (mean 0.365 ms, max 0.647 ms).

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R23.1-1 | MAJOR | The unmapped split's far branch for a fix with a usable course, and any non-zero captured split, are untested (`NavigationReplay.swift:845,850`, `ReplayRoads.swift:164`). M2 and M3 survive. Under M3, clean's 83 (83 + 0) would read 62 + 21. Under M2, drive-7's captured 10 (0 + 10) would read 10 + 0. These are figures in docs/NAVIGATION.md. | FIXED | Verified. Tests in this round's commit: `unmapped` asserts the far split (110 + 0, captured 91 + 0, every reason `.noRoadWithin15`); new `capturedSplitByReason` (unmapped 3 (1 + 2), captured 3 (1 + 2)). M2 killed (3 issues), M3 killed (7 issues). |
| R23.1-2 | MINOR | docs/NAVIGATION.md N3.2d "nearest miss" bullet says jammed-A +0.005 pp; `logs/n32d/corr100/judge-vs-n32b.txt` and the doc's trade-off table give +0.006. | DEFERRED | BACKLOG |
| R23.1-3 | MINOR | `build_roads --network` exits 4 on every failure (duplicate pack, grid mismatch, unreadable pack) (`Core/Sources/build_roads/main.swift:35-36,168`), but the header documents 4 only as "--info verification failed". | DEFERRED | BACKLOG |
| R23.1-4 | MINOR | The metrics.md Roads header (`ReplayReport.swift:372-375`) describes the widened unmapped rule for every row. A merged row written before N3.2c item 2 (distance-only) appears under it unmarked; only the missing "(a + b)" split hints at it. | DEFERRED | BACKLOG |

Tests: Core passes 799 tests in 109 suites, 39 known issues (all test 3). No App change.

### Round 2

Reviewer: one fresh `reviewer` (opus). Result: 0 BLOCKER / 0 MAJOR / 1 MINOR. Mutations: 3 run, 3 killed (sort removed in `RoadNetwork.init`, now killed by `engineIndependentOfOrder` alone; round 1's M2 and M3, now killed by `unmapped` and `capturedSplitByReason`).

Verified clean: the R23.1-1 tests; `RoadPackOrderTests` against partial fixes (hash-only or reversed sort fail `networkIsCanonical`); the `NavigationRoadTests.twoPacks` rewrite and the `RoadPackTests` edits; `build_roads --network` naming; comment-only edits in `RoadMatcher`, `NavigationEstimate`, `RoadNetwork`; item 2's definitions in NAVIGATION.md and N3_PLAN.md against `UnmappedReason.of`, and its table against `logs/n32c/unmapped`; the N3.2d anomaly and trade-off bullets against `logs/n32d`; no unrelated code edits; drive-7 seed 1 with packs reversed byte-identical to `logs/n32b/roads` and `logs/n32c/unmapped`.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R23.2-1 | MINOR | `ReplayReport.swift:429-438`: `unmappedSplit` was inserted inside `roadsText`'s doc comment, so both Quick Help texts are wrong. | DEFERRED | BACKLOG |

Tests: Core passes 799 tests in 109 suites, 39 known issues (all test 3). No App change.

### Run 23 summary

- **Rounds:** 2. Round 2 found no BLOCKER or MAJOR; loop stopped.
- **Findings:** 1 MAJOR missing test added (R23.1-1), no bug exposed; 0 rejected; 4 MINOR deferred (R23.1-2..4, R23.2-1).
- **Final tests:** `cd Core && swift test`: 799 tests in 109 suites pass, 39 known issues (all test 3, the decided known FAIL). No App change. The review rounds changed only tests and docs, so the N3.2d measurement in `logs/n32d` stands.

## Run 24: UX-2 and UX-5, map tab first and speed/source block (main..ux-map, f9629f1..b57ff2c), started 2026-10-13

UX-2 (68848a3, 335d2b8): Map first and default tab, `-uiTab` renumbered in tab order. UX-5 (68a0d59, b57ff2c): the map info block shows speed and source only (`MapSpeedRule`, OBD ≤ 2 s, else GPS ≤ 2 s rounded, else none; chip colour by GPS quality). App/ and AppTests/ only. Branch: `ux-map`.

### Round 1

Reviewer: one fresh `reviewer` (opus). Result: 0 BLOCKER / 0 MAJOR / 3 MINOR. No mutations (no Core logic; the reviewer does not run the simulator).

Verified clean: the source rule's edges (exactly 2.0 s fresh in integer ns, negative age fresh, OBD 0 and GPS 0 shown, speed −1 and NaN give `— km/h`); primary-ECU filtering upstream (`RecordingSession.swift:1111`, tested at `RecordingSessionTests.swift:548`); clock bases (uptime − uptime for OBD, ContinuousClock − ContinuousClock for the fix); no stale value after Stop, file change, inactive scene or BLE disconnect; `-uiTab` out of range falls back to Map; no behaviour lost (long-press, thermal under stats, calibrating icon); project.pbxproj adds only the two new files, no team ID; PLAN §6 entries marked not verified; privacy. The flaky `RecordingSessionTests.swift:241` is the pre-existing R5.1-4 (DEFERRED), not from this range.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R24.1-1 | MINOR | The 1 s live-timer relay of `referenceFix` can push a clean 1 Hz fix just past the 2 s freshness (`MapViewModel.swift:107`): 1–2 blinks per 10 min, ≤ 0.1 s, on clean-long's timing. | DEFERRED | BACKLOG; changes a user decision, asked |
| R24.1-2 | MINOR | `MapSpeedTests.swift:162` does not actually test that 7E9 is ignored. | DEFERRED | BACKLOG |
| R24.1-3 | MINOR | `docs/PLAN.md:751` `-- km/h` and a garbled sentence; `:745` still says the "Calibrating heading" label. | DEFERRED | BACKLOG |

Tests: Core passes 799 tests in 109 suites, 39 known issues (all test 3). App: 255 tests in 40 suites pass on the iPhone 15 Pro simulator.

### Run 24 summary

- **Rounds:** 1; no BLOCKER or MAJOR, loop stopped.
- **Findings:** 0 fixed, 0 rejected, 3 MINOR deferred (R24.1-1..3).
- **Final tests:** Core 799 tests / 109 suites pass, 39 known issues; App 255 tests / 40 suites pass.

## Run 25: UX-3 and UX-4, Settings tab and map recording control (main..ux-map, 5076fc9..d61121c), started 2026-10-13

UX-3 (8d19af1): tabs Map · Sessions · Settings, Settings → Recording / Diagnostics, map recording indicator with confirmed Stop and a Start that opens Settings → Recording. UX-4 (471dd02): Console as a pushed Settings row. bb06883: backlog DONE. d61121c: R24.1-2 test fix. App/ and AppTests/ only. Branch: `ux-map`.

### Round 1

Reviewer: one fresh `reviewer` (opus). Result: 0 BLOCKER / 0 MAJOR / 2 MINOR. No mutations (App logic needs the simulator; d61121c verified by reading the ordered link-event stream).

Verified clean: no lost behaviour (RecordingScreen onAppear and scene-phase refresh on push, DebugAutoRecord independent of tabs, view-model state owned by RootView survives push/pop, Console feed and scroll); navigation state (Start with Console pushed replaces the path, Start hidden while the indicator shows); Stop reachable only via the dialog; elapsed from the session clock; the 16 Hz read limited to the button; ConsoleView title in Settings' stack; `xcodegen generate` byte-identical, no team ID; PLAN §6 entries not verified; privacy. The `LinkPlanReuseTests.swift:76` flake is a pre-existing link-side reconnect race (`OBDLinkService.swift:494-513`), not from this range.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R25.1-1 | MINOR | The map Stop dialog relies on SwiftUI running the button action before resetting `isPresented` (`MapRecordingControl.swift:259-270`); untested wiring. | DEFERRED | BACKLOG; fixed with UX-6 |
| R25.1-2 | MINOR | PLAN §6 UX-3 item 1 lists a Console tab and `-uiTab 3`; the control's placement is described wrongly in PLAN and BACKLOG_UX. | DEFERRED | BACKLOG; fixed with UX-6 |

Tests: Core passes 799 tests in 109 suites, 39 known issues (all test 3). App: 262 tests in 41 suites pass on the iPhone 15 Pro simulator.

### Run 25 summary

- **Rounds:** 1; no BLOCKER or MAJOR, loop stopped.
- **Findings:** 0 fixed, 0 rejected, 2 MINOR deferred (R25.1-1, R25.1-2), both scheduled with UX-6.
- **Final tests:** Core 799 / 109 pass, 39 known issues; App 262 / 41 pass.

## Run 26: UX-6 speed-dependent zoom, R24.1-1, R25.1-1..2 (main..ux-map, 7f3066b..09a505a), started 2026-10-13

R24.1-1 (4e297ba): GPS speed freshness 3 s, OBD 2 s (user decision). R25.1-1/R25.1-2 (173ecac): map Stop and Console Drop OBD dialogs independent of dismiss order; PLAN §6 wording. UX-6 (e522e97, 09a505a): `AutoZoom` (table 250/500/900/1500 m, 3 s log-distance low-pass, zoom-in after 6 s with a 3 % deadband, hold without speed, pitch 0) wired into `FollowZoom` and the map loop. App/ and AppTests/ only. Branch: `ux-map`.

### Round 1

Reviewer: one fresh `reviewer` (opus). Result: 0 BLOCKER / 1 MAJOR / 2 MINOR. No mutations (no Core logic); the reviewer compiled the real `FollowZoom`, `FollowSpan`, `AutoZoom` and `MapFraming` sources into a Mac harness.

Verified clean: no auto-zoom fight with the driver (every gesture pauses Following, every resume path recentres); north-up GPS-only writes do not loop; region frames disable zoom writes until the next follow write; `FollowSpan` only widens; AutoZoom smoothing and dwell independent of step size, dt 0/NaN no-ops, NaN or negative speed → 250 m, edges at 20 and 110 km/h, monotonic `ContinuousClock`; the 8 s auto-resume limit on a pinch is described accurately in BACKLOG_UX and PLAN §6; map Stop safe in any dismiss order; Console's captured `LinkChange` harmless after the recording ends; R24.1-1 changes only GPS freshness; pbxproj adds only file refs; PLAN §6 UX-6 marked not verified; privacy.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R26.1-1 | MAJOR | `FollowZoom.autoWantsWrite` (`MapNavigation.swift:322-325`) compares `auto.distance` with the ellipse-widened `writtenDistance` (`:341`): in heading-up with an ellipse wider than the auto distance, a camera write with a 0.25 s animation fires every 100 ms (harness: 100/100 ticks), bypassing the 4 Hz `NavWriteGate`, for as long as the ellipse is grown. | FIXED | Verified against `MapNavigation.swift:322-341` and `MapView.swift:645-668`. `autoWantsWrite(headingUp:semiMajorM:)` compares the widened auto distance with `writtenDistance`; test "A constant widened write is not drift…" in `FollowZoomPrecedenceTests` fails on the old comparison (100 issues, one per tick) and passes after; a growing ellipse still writes. |
| R26.1-2 | MINOR | Docs say the auto zoom passes a 300 m span from about 80 km/h; it is about 55 km/h, and the 6 s dwell keeps it after slowing. | DEFERRED | BACKLOG |
| R26.1-3 | MINOR | BACKLOG_UX UX-5 row still says the chip goes grey after 2 s; it is 3 s. | DEFERRED | BACKLOG |

Tests: Core passes 799 tests in 109 suites, 39 known issues (all test 3). App: 276 tests in 43 suites pass on the iPhone 15 Pro simulator.

### Round 2

Reviewer: one fresh `reviewer` (opus). Result: 0 BLOCKER / 0 MAJOR / 3 MINOR. No mutations (no Core logic); a Mac harness built from the real `FollowSpan`, `FollowZoom`, `AutoZoom` and `MapFraming` sources measured write rates per mode.

Verified clean: the R26.1-1 fix is complete (`cameraReported`, `writtenDistance` and `recentWrites` all hold the widened distance; north-up unwidened on both sides; a shrinking ellipse, heading-up off and a lost estimate still write; NaN semi-major falls back to the speed distance); steady-state zoom writes are 0 in every mode, so the steady rate is bounded by the published writes (≤ 4/s); R24.1-1 and R25.1-1/2 unchanged; privacy.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R26.2-1 | MINOR | Zoom-only writes skip the 4 Hz `NavWriteGate` while the zoom ramps (up to 9–10/s for ~3 s), contradicting PLAN §6 N4 check 1. | FIXED | Fixed after the run (branch `fix/r26.2-1-zoom-gate`): every follow-loop camera write, zoom-only or published, now waits for `HeadingWriteGate.isDue` (0.25 s since the last camera write), in `FollowCameraTick`; a held publish is kept pending, a held zoom write stays wanted. `FollowCameraRateTests` fail on the ungated logic and pass after. |
| R26.2-2 | MINOR | No test expects `autoWantsWrite` true when the wanted distance falls; dropping `abs` survives. | DEFERRED | BACKLOG |
| R26.2-3 | MINOR | `FollowZoom.followDistance` is unused by the app but still tested; PLAN §6 N4 item 3 describes its old behaviour. | DEFERRED | BACKLOG |

Tests: Core passes 799 tests in 109 suites, 39 known issues (all test 3). App: 276 tests in 43 suites pass on the iPhone 15 Pro simulator.

### Run 26 summary

- **Rounds:** 2. Round 2 found no BLOCKER or MAJOR; loop stopped.
- **Findings:** 1 MAJOR fixed with a regression test (R26.1-1: 10 Hz camera writes in heading-up with a wide ellipse); 0 rejected; 5 MINOR deferred (R26.1-2..3, R26.2-1..3).
- **Final tests:** Core 799 / 109 pass, 39 known issues; App 276 / 43 pass.

## Run 27: drive-8 acceptance, scoreUntilT, PLAN B-2 note (main..drive8-acceptance, b61fa86..6c99826), started 2026-10-14

### Round 1

Reviewer: one fresh `reviewer` (opus). Result: 0 BLOCKER / 1 MAJOR / 1 MINOR.

Verified clean: bit-identity re-run by the reviewer (clean seed 1 no roads, drive-7 seed 2 with roads: identical); drive-8 table values match `metrics.json`; PLAN B-2 numbers match the sidecar; mutations M2 and M3 killed.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R27.1-1 | MAJOR | `NavigationReplay.swift:1015-1017`: heading convergence judged on the track up to `scoreUntilT` (`scoredTrack`) has no test; mutation `convergence(track, …)` passes every test. | CONFIRMED | fixed in round 1: tests for a cutoff before convergence, inside the hold window, and after the hold (fail under the mutation). |
| R27.1-2 | MINOR | `docs/NAVIGATION.md:883-886` (drive-8 baseline): "% since last fix received" 2.35–2.74 %, "above 2.5 % on seeds 3 and 5" is only the value at each seed's max-%-from-start fix (1944.1 s); seed 1 is 2.501 %, also above; the max over scored fixes > 500 m into dead reckoning is 2.72–2.84 % on every seed. Reported, not gated. | DEFERRED | backlog. |

Tests: Core passes 808 tests in 109 suites, 39 known issues (all test 3). App unchanged.

### Round 2

Reviewer: one fresh `reviewer` (opus). Result: 0 BLOCKER / 1 MAJOR / 0 MINOR.

Verified clean: R27.1-1 tests kill the cutoff-boundary mutation in the convergence track (`< scoreUntilNs`); dropping the cutoff from the 1 Hz road samples is killed by `scoreUntilTRoads`; Core imports and privacy unchanged. Bit-identity not re-run (`Core/Sources` unchanged since round 1).

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R27.2-1 | MAJOR | `ReplayReport.swift:277-283`: the summary's `cleanFix` line under a cutoff has no test; scoring every clean fix (no `cleanFixes(...)`) passes every test, and on drive-8 would print 1282 fixes with median and max over the fixes after the driver left the car. | CONFIRMED | fixed in round 2: `cutoffBeforeCheckpoint` checks the count, median and max over scored clean fixes only, the "more after scoreUntilT" suffix and the metrics.md scored row (fails under the mutation). |

Tests: Core passes 808 tests in 109 suites, 39 known issues (all test 3). App unchanged.

### Round 3

Reviewer: one fresh `reviewer` (opus). Result: 0 BLOCKER / 1 MAJOR / 1 MINOR.

Verified clean: scoreUntilT paths in TruthFile, NavigationReplay (schedule, pinScoring, score, road residuals, 1 Hz samples, end fallback, convergence) and ReplayReport (summary, metrics.md, metrics.json keys and decoding) against NAVIGATION.md; privacy of the diff and commit messages. R19.1-2 not re-raised (drive-8's gated max % is still computed outside `replay_nav`, as for drive-7).

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R27.3-1 | MAJOR | `NavigationReplay.swift:750-751`: the `$0.1 == nil` clause of the pin cutoff count has no test; without it a refinement pair after the cutoff gives `pinScoring.scored` -1. | CONFIRMED | fixed in round 3: `cutoffPinScoringCounts` (refinement and excluded pins after the cutoff; every count and metrics.json checked; fails under the mutation). |
| R27.3-2 | MINOR | Report text under a cutoff partly untested (joined `notScoredText`, metrics.md "Scored until" line and footnote). | DEFERRED | backlog. |

Tests: Core passes 809 tests in 109 suites, 39 known issues (all test 3). App unchanged.

### Round 4

Reviewer: one fresh `reviewer` (opus). Result: 0 BLOCKER / 0 MAJOR / 0 MINOR.

Verified clean: R27.3-1 fix (dropping the `$0.1 == nil` clause and `>` → `>=` in the cutoff count are both killed); ledger and backlog rows match the code; privacy of the round-3 diff and every commit message in the range.

Tests: Core passes 809 tests in 109 suites, 39 known issues (all test 3). App unchanged.

### Run 27 summary

4 rounds. Findings: 3 MAJOR fixed (R27.1-1, R27.2-1, R27.3-1, all missing tests; no code change), 0 rejected, 2 MINOR deferred (R27.1-2, R27.3-2). Final: Core 809 tests in 109 suites pass, 39 known issues (as main); App unchanged.

## Run 28: N3.2e level rule across packs, candidates re-run, trade-off table, CLAUDE.md perf command, WORKFLOW roadmap (main..n3.2e, ecf4f31..c6912c5), started 2026-10-14

### Round 1

Reviewer: one fresh `reviewer` (opus). Result: 0 BLOCKER / 2 MAJOR / 3 MINOR.

Verified clean: bit-identity (clean, mask-after 230, seed 1: no roads main vs HEAD GeoJSON byte-identical, metrics.json equal apart from timing; with national + region-A packs HEAD matches the N3.2e default output; the pre-change default reproduces N3.2b); cross-pack adjacency symmetric and order-independent; memo bounded per update and deterministic; ms/step and largest ingest unchanged; N3.2e tables in NAVIGATION.md match the outputs (spot checks of clean, drive-7, drive-8 values and levelBlocked); honest wording (no adoption claimed, "likely, not proven" kept); Core imports and privacy.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R28.1-1 | MAJOR | `RoadNetwork.swift:229-230`: the condition that an equal E7 point must be an end of one of the two edges (keeps two interior points at one coordinate, e.g. a bridge over a road, from linking) is untested; mutation to `true` passes every test. | CONFIRMED | fixed in round 1: `equalInteriorPointIsNotANode` (no adjacency, the level rule still blocks both ways, both pack orders; fails under the mutation). |
| R28.1-2 | MAJOR | `RoadMatcher.swift:314-321`: the per-update hop memo is untested; a key without `b` (or without `a`) reuses one candidate's answer for others and passes every test. | CONFIRMED | fixed in round 1: `memoKeysBothEdges` (three questions in four orders through one memo; fails under both key mutations). The key omits `hops`; one memo only sees one `hops` (comment added at the memo, no code change). |
| R28.1-3 | MINOR | `RoadNetwork.swift:217`: way-node ranges that touch at one index are untested (`<=` → `<` passes). | FIXED | covered in round 1 by `touchingWayNodeRanges` (fails under the mutation). |
| R28.1-4 | MINOR | `RoadLevelAcrossPacksTests.swift:221-231`: the "one pack equals RoadPack.isEdge hop for hop" check compares the function with itself (`RoadNetwork.isEdge` returns `packs[0].isEdge` for one pack); the multi-pack BFS is never compared with a pack's own adjacency. | DEFERRED | backlog. |
| R28.1-5 | MINOR | `NavigationRoadTests.swift:851-853`: the `twoPacks` doc comment and test name still say the level rule finds adjacency within a pack only; false after N3.2e item 1 (passes only because its streets are far from the bridge). | DEFERRED | backlog. |

Tests: Core passes 817 tests in 110 suites, 39 known issues (the existing `withKnownIssue` tests). App unchanged.

### Round 2

Reviewer: one fresh `reviewer` (opus). Result: 0 BLOCKER / 1 MAJOR / 0 MINOR.

Verified clean: the round-1 tests kill their mutations (end condition → `true`; `<=` → `<`; memo key without `b`; without `a`); the cell scan and its dedupe cannot lose a link (segments listed within the effective radius); adjacency through a third pack via the BFS; duplicates removed; symmetry and pack-order independence; `edgeRange(ofWay:)` relies on the enforced sort order; memo key cannot collide and is built once per update; ms/step and largest ingest unchanged or lower on the two-pack replays; docs and ledger match the code; privacy. Bit-identity not re-run (`Core/Sources` changed only by a comment since round 1).

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R28.2-1 | MAJOR | `RoadNetwork.swift:230-231`: the start-of-edge half of the equal-coordinate rule (`k == ends.0`, `k == node(r.from)`) is untested: every cross-pack coordinate fixture meets at the street's last point, and dropping both passes every test. A street whose way starts at a bridge's interior node would again be blocked. | CONFIRMED | fixed in round 2: `coordinateBothDirectionsReversedStreet` (street way reversed; adjacency both ways, up and down updates, both pack orders); dropping either half alone or both fails it. |

Tests: Core passes 818 tests in 110 suites, 39 known issues (the existing `withKnownIssue` tests). App unchanged.

### Round 3

Reviewer: one fresh `reviewer` (opus); a first attempt was cut off by an API limit and not counted, the second resumed from its notes. Result: 0 BLOCKER / 0 MAJOR / 2 MINOR.

Verified clean: the N3.2e tables in NAVIGATION.md match `logs/n32e/tradeoff.md`, which `tradeoff.py` reproduces; every adoption verdict and allowed Δ recomputed (max(2 m, 5 %), manual 2.52 m; 0.1 pp), N3.0 references incl. drive-8 1.482 % / 100 %; item 1 stated as a FAIL against the N3.2b default on drive-7 consistency (seeds 1, 4, 5 one miss each), not presented as adopted, no config chosen; 40 no-roads GeoJSON byte-identical to N3.0; three more mutations on item-1 code (within-pack adjacency `[from]` only, `[to]` only, `edgeRange` upper bound) all killed; WORKFLOW.md references and CLAUDE.md perf command accurate; privacy.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R28.3-1 | MINOR | `docs/N3_PLAN.md:767-771` (also :215-219, :897-898): the N3.2e status does not say that item 1 itself fails the adoption rule against the N3.2b default (drive-7 consistency 87.4 → 87.2 %) and that adopting it is the user's call; the design text describes cross-pack adjacency as the current rule. NAVIGATION.md is explicit. | DEFERRED | backlog. |
| R28.3-2 | MINOR | `docs/NAVIGATION.md:1821-1822`: "seed 4 misses 21 (2068–2087 s), the others 6–8" counts the 706 s pin, which is outside that window; section (b) gives 6 / 7 / 5 / 20 / 7 without it. | DEFERRED | backlog. |

Tests: Core passes 818 tests in 110 suites, 39 known issues (the existing `withKnownIssue` tests). App unchanged.

### Run 28 summary

3 rounds. Findings: 3 MAJOR fixed (R28.1-1, R28.1-2, R28.2-1, all missing tests of the cross-pack adjacency and its memo; no code change), 1 MINOR fixed in passing (R28.1-3), 0 rejected, 4 MINOR deferred (R28.1-4, R28.1-5, R28.3-1, R28.3-2). Final: Core 818 tests in 110 suites pass, 39 known issues; App unchanged.

## Run 29: N3.2 decision, default roadCorrelationM 100, decision docs (main..n3.2-decision, 4e87038..acd2979), started 2026-10-14

### Round 1

Reviewer: one fresh `reviewer` (opus). Result: 0 BLOCKER / 1 MAJOR / 2 MINOR.

Verified clean: exactness re-run by the reviewer with its own release build at HEAD (drive-7 seed 4, clean seed 2, manual seed 3, drive-8 seed 5, with roads, no `--set`): every GeoJSON byte-identical to the N3.2e `roadCorrelationM` 100 outputs, `metrics.json` differs only in timing; the eight pinned tests loosen no assertion and fail without their pins; `compatiblePinAnchorIsTempered` reads the config (mutation to a literal 30 is killed); live path loads no roads; old configs decode; the config-hash warning is N3-CMPHASH; decision table numbers match the N3.2e tables; wording consistent across docs; archive row format; privacy.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R29.1-1 | MAJOR | `NavigationEngine.swift:1388`: the distance tempering weight w = min(1, \|Δs\| / roadCorrelationM) is never checked below 1; replacing `config.roadCorrelationM` with 30 passes every test. With the new default and 1 s updates, w < 1 on nearly every road update. | CONFIRMED | fixed in round 1: `evidenceWeightBelowOne` at the default config (asserts 100; Δs 30, −30, 100, 250: closed-form mean and P with rw = σr²/w, log-weight ratio scaled by w); fails under the literal 30, without the clamp, without `abs`, and without either w on the log-weight terms. |
| R29.1-2 | MINOR | `docs/N3_ROAD_OFFROAD.md:279`: the test-3 regression pass condition says "no capture, and the truth inside the 95 % ellipse"; the test and the decided condition (lines 18–19) use "or". | DEFERRED | backlog. |
| R29.1-3 | MINOR | `docs/N3_ROAD_OFFROAD.md:78`: table header "roadCorrelationM 30 (default)" is stale now that the default is 100. | DEFERRED | backlog. |

Tests: Core passes 819 tests in 110 suites, 36 known issues (test 3 known FAIL; 36 at roadCorrelationM 100). App unchanged.

### Round 2

Reviewer: one fresh `reviewer` (opus). Result: 0 BLOCKER / 0 MAJOR / 0 MINOR.

Verified clean: `evidenceWeightBelowOne` computes every expectation itself (r from S₀ = P_cc + σr², Kalman step with σr²/w, moment matching, weight ratio ((L_on + L_off)/L_off)^w), its preconditions hold (no split, no resampling, inside the innovation gate, odd particles outside the heading gate), and tolerances are tight against the w = 0.3 / 1 difference; mutations killed: literal 30 at the weight, `rw` without w (caught only by this test), off-road log-weight without w; the pin anchor's use of the default is covered by `compatiblePinAnchorIsTempered`; nothing else reads `roadCorrelationM`; ledger and backlog rows match the docs; privacy.

Tests: Core passes 819 tests in 110 suites, 36 known issues. App unchanged.

### Run 29 summary

2 rounds. Findings: 1 MAJOR fixed (R29.1-1, missing test of the tempering weight below 1; no code change), 0 rejected, 2 MINOR deferred (R29.1-2, R29.1-3). Final: Core 819 tests in 110 suites pass, 36 known issues (test 3 known FAIL at roadCorrelationM 100); App unchanged, simulator build green at 4e87038.

## Run 30: R26.2-1 follow-loop camera writes gated to 4 Hz (main..fix/r26.2-1-zoom-gate, 1454ae3), started 2026-10-14

### Round 1

Reviewer: one fresh `reviewer` (opus). Result: 0 BLOCKER / 0 MAJOR / 1 MINOR.

Verified clean: `FollowCameraTick.decide` matches the old `runLoop` body apart from the gating (the distance now uses `inputs.headingUp`, as `autoWantsWrite` already did); loop writes at most 4/s (about every 0.3 s at 100 ms ticks); held zoom, heading and publish writes land on the next open tick; no caller of `noteWrite` runs faster than 0.25 s, so no unbounded delay; `publishPending` cleared on recording change, no center, no estimate (left set across a follow-off or tab leave, giving one write after the next recentre, as the old next publish did); activation still snaps; mutations by reading (no `guard due`, wrong `publishPending` updates) are caught by `FollowCameraRateTests`; privacy.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R30.1-1 | MINOR | `MapCameraLogic.swift:81-83` and `docs/PLAN.md:740` say every non-loop write calls `noteWrite`; `frame()` does not (and resets the gate in heading-up), so a tab return can give 5 writes in 1 s, by design for activation. | DEFERRED | backlog. |

Tests: Core passes 819 tests in 110 suites, 36 known issues (Core unchanged). App: simulator build succeeded; 281 tests in 44 suites pass on the iPhone 15 Pro simulator.

### Run 30 summary

1 round. Findings: 0 fixed, 0 rejected, 1 MINOR deferred (R30.1-1). R26.2-1 closed and moved to `docs/archive/BACKLOG-closed.md`. Final: Core 819 tests in 110 suites pass, 36 known issues; App 281 tests in 44 suites pass, simulator build green at 1454ae3.

## Run 31: N3-SLC speedless course, measured and rejected; drive-9 acceptance definition (main..n3-speedless-course, 6f9c235), started 2026-10-15

### Round 1

Reviewer: one fresh `reviewer` (sonnet). Net diff is docs only: Core and App are identical to main after the d55e23c revert of 0b3a1f7. Result: 0 BLOCKER / 0 MAJOR / 4 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R31.1-1 | MINOR | `docs/NAVIGATION.md:821-822` says drive-9 has "no clean fix at all"; the pre-session fix at −456.6 s is 5 m with a valid speed, but 457 s stale and ignored (fixesIgnoredStale 1). | DEFERRED | backlog. |
| R31.1-2 | MINOR | `docs/NAVIGATION.md:839-841` run (2) (`--hold-out-acc 100`) withheld list omits the 97 m fix at 603.8 s (57 withheld: 49 park fixes 604–1229 s, 5 fixes of 72–85 m, the pre-session fix, the 603.8 s fix, the truth point). | DEFERRED | backlog. |
| R31.1-3 | MINOR | `docs/NAVIGATION.md:851` "misses it by about 4×": it is 4.1× for run (1) (10.2 %) and 3.4× for run (2) (8.4 %). | DEFERRED | backlog. |
| R31.1-4 | MINOR | `docs/BACKLOG.md` line references of R27.1-2 (`docs/NAVIGATION.md:883-886`) and R28.3-2 (`:1821-1822`) drifted by about 50 lines from this range's insertions (R28.3-2 text now at about 1875). | DEFERRED | backlog. |

Tests: Core passes 819 tests in 110 suites, 36 known issues (test 3 known FAIL at roadCorrelationM 100). App unchanged.

### Run 31 summary

1 round, round 1 clean. Findings: 0 fixed, 0 rejected, 4 MINOR deferred (R31.1-1 to R31.1-4). Final: Core 819 tests in 110 suites pass, 36 known issues (test 3); App unchanged.

## Run 32: N3.3 roads in the live engine, developer pack bridge (main..n3.3, 4e29b3e), started 2026-10-15

### Round 1

Reviewers: three fresh `reviewer` (opus) on disjoint sets: A engine, live loop and sidecar; B replay, compare, pack catalog and selection, docs; C app. Result: 0 BLOCKER / 2 MAJOR / 7 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R32.1-1 | MAJOR | `RoadAttach.swift:88-91`: no test pins a `RoadSelectionRequest`'s contents (centre and radius = the estimate at `latestArrival` and its 95 % semi-major axis); test (a) checks only finiteness. Mutation semiMajorM → semiMinorM survives every suite; an elongated cloud would then miss a pack and roads never attach. | CONFIRMED | regression test added (round 1 commit). |
| R32.1-2 | MAJOR | `NavigationReplay.swift:729-733`: the input count for an input the engine rejects as a time jump is untested; removing `givenInputs += 1` survives, and the metrics replay would attach one input later than `LiveNavigationRun` after such an input. | CONFIRMED | regression test added (round 1 commit). |
| R32.1-3 | MINOR | `docs/NAV_SIDECAR.md:64` and `RoadAttachment.t` doc (`RoadAttach.swift:118-121`) say `t` is the arrival of the last input before the attach; it is the latest (largest) accepted arrival (`NavigationEngine.swift:285`). Informational: replay attaches by `afterInputs`. | DEFERRED | backlog. |
| R32.1-4 | MINOR | `docs/NAV_SIDECAR.md:52` and `Estimate.onRoadShare` doc (`NavSidecar.swift:88-91`): the key is also omitted with roads attached when the cloud was too wide to engage at the last attempt (drive-8: 10 of 2092 seconds). Readers should rely on the `roads` line. | DEFERRED | backlog. |
| R32.1-5 | MINOR | `replay_nav --compare` attaches the metrics replay at the sidecar's `afterInputs` but keeps the from-start (or live-rule) mode label, so it overwrites that row in metrics.json and its GeoJSON (`main.swift:262`, `NavigationReplay.swift:98-104`, `ReplayReport.swift:95`). | DEFERRED | backlog. |
| R32.1-6 | MINOR | `RoadPackCatalog.swift:218-223`: the "file changed during verification" branch is untested (needs an injectable identity reader). | DEFERRED | backlog. |
| R32.1-7 | MINOR | `App/Sources/Navigation/MemoryFootprint.swift:12`: `task_self_trap()` leaks a send right per call (Diagnostics polls every 2 s; saturates after about 36 h). Use `mach_task_self_`. | DEFERRED | backlog. |
| R32.1-8 | MINOR | Packs are memory-mapped directly from `Documents/RoadPacks` and held for the drive (`RoadPack.swift:64`, `RoadPackLibrary.swift:132-133`); a pack overwritten or truncated in place during a recording could SIGBUS. Not verified whether Finder/Files overwrite in place. Fix: clone into a private directory before mapping (N3.4 import into Application Support is the natural place). | DEFERRED | backlog; test-drive instructions say not to copy packs during a recording. |
| R32.1-9 | MINOR | `RoadsDiagnostics.swift:34-41`: with no recording running, "Recording uses" shows the last finished recording's packs unlabelled. Label it "Last recording used". | DEFERRED | backlog. |

Tests: Core passes 839 tests in 114 suites at 4e29b3e, 36 known issues (test 3). App: 292 tests; `RecordingSessionTests` "A write failure: error row, finish, failed; no stop row (rule 4)" failed in 2 of 4 runs at 4e29b3e (RecordingSession is not in the range; baseline on main pending).

Round 1 commit: 4482802.

### Round 2

Reviewers: two fresh `reviewer` (opus): A2 Core (engine, live loop, sidecar, replay, compare, catalog, selection, replay_nav); C2 app, with the `RecordingSessionTests` failure as its primary question. Result: 0 BLOCKER / 1 MAJOR / 3 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R32.2-1 | MAJOR | `App/Sources/Recording/RecordingSession.swift` `handleWriteFailure`: the rule-4 `error` row was written before the sources were quiesced and before `stopRowQueued` was set (both only in `performFail`, after a main-actor hop), so sample or `stats` rows could land after it; `writeFailureEntersFailed` failed 2 of 8 app-test runs (pre-existing, same as R5.1-4; the range's main-actor test replays widened the gap). | CONFIRMED | Fixed (user decision 2026-10-15: fix in this branch): quiesce, then the error row, then `stopRowQueued`, before the first suspension; rule 4 in docs/LOG_FORMAT.md and docs/PLAN.md now reads "stop every source, then the error row". Regression test `writeFailureQuiescesBeforeErrorRow` fails before, passes after. `NavigationServiceRoadsTests.comparison` moved off the main actor. Closes R5.1-4. |
| R32.2-2 | MINOR | `AppTests/NavigationServiceRoadsTests.swift:191` `lateResultDropped`: one `gate.signal()` can leave a second scan blocked 20 s. | FIXED | in the round 2 commit (the gate passes the signal on). |
| R32.2-3 | MINOR | `Core/Sources/replay_nav/main.swift:248, 358-361`: when the live attach is refused because the config would change (only `--compare --set <road key>`), replay_nav prints a clamp note that does not apply and "Roads attach none (no selection request met a covering pack set)"; the same fallback text is printed for a set refused at build time; each used fix rebuilds the network (selector caches only build refusals). | DEFERRED | backlog. |
| R32.2-4 | MINOR | Link-loss tests flaky: `OBDLinkServiceTests.swift:283` ("Link loss: disconnected → reconnecting → connected…") and `StartupInitRecordingTests.swift:348` ("Real link dropped before Start (reconnecting)…"): after `central.loseLink()` the dropped session's "→ failed (transport closed)" event sometimes never arrives; 2 of 4 full runs, and once in 15 iterations of the two tests alone. Outside the range; reproduced on main: `StartupInitRecordingTests.swift:348` failed 1 of 15 iterations on main (0 of 15 on n3.3). | DEFERRED | backlog. |

Tests: Core passes 841 tests in 114 suites, 36 known issues (test 3). App: 293 tests; 4 full runs: 2 pass, 2 fail on one link-loss test each (R32.2-4); `writeFailureEntersFailed` and the new `writeFailureQuiescesBeforeErrorRow` pass in all 4. Simulator build succeeds.

Round 2 commit: 2d05d59.

### Round 3

Reviewers: two fresh `reviewer` (opus): A3 Core (late-attach sidecars on real drives compared exactly, metrics merge, doc numbers); C3 app and the round-2 logger change. Result: 0 BLOCKER / 1 MAJOR / 2 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R32.3-1 | MAJOR | `Core/Sources/DriveLoggerCore/Navigation/Replay/SidecarComparison.swift:104` (and the `onRoadShare` difference at :75-79): no test covers `onRoadShare` in the exact verdict; deleting the term leaves every test green, so a sidecar differing only in `onRoadShare` would be reported "PASS (exact)". | CONFIRMED | regression test added (round 3 commit). |
| R32.3-2 | MINOR | `App/Sources/Recording/RecordingSession.swift:548-550`: the `calibrationEnd` row in `start()` is guarded by `state == .calibrating` but not `rec.isWritable`; a write failure during calibration whose sleep continuation is already queued can write `calibrationEnd` after the rule-4 error row (one main-actor turn; pre-existing window, but contradicts the new "no row of any kind follows the error row" in docs/LOG_FORMAT.md). | DEFERRED | backlog. |
| R32.3-3 | MINOR | `AppTests/RecordingSessionTests.swift:272-273`: the "second report writes nothing" step runs after `await failing.value`, when `recording` is nil, so it never reaches the `stopRowQueued` check; deleting `rec.stopRowQueued = true` (`RecordingSession.swift:1091`) keeps the test green. | DEFERRED | backlog. |

Tests: Core passes 842 tests in 114 suites, 36 known issues (test 3). App unchanged since round 2 (2d05d59); its link-loss tests ran 15 iterations clean on n3.3.

Round 3 commit: 6e02554.

### Round 4

Reviewers: two fresh `reviewer` (opus), both told to hunt untested new branches by mutation: A4 Core (mutations run in a scratch copy of Core because an app-test run was using the worktree); C4 app and logger (static). Result: 0 BLOCKER / 1 MAJOR / 9 MINOR. Round 4 is the loop's last; the user decided (2026-10-16): add the test for R32.4-1, defer the MINORs, merge without a round 5.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R32.4-1 | MAJOR | `NavigationReplay.swift:912`: road scoring of withheld clean fixes under `--as-live --roads` maps the matched edge into the given set's numbering (`estimate.map(inTruthFrame)`); untested (the mapping test has no withheld fix). Removing it moved scored fixes onto the far pack's edge (≈ 8 km) with every test green; it would silently corrupt wrong-road verdicts in metrics.json. | CONFIRMED | regression test added (round 4 commit). |
| R32.4-2 | MINOR | `RoadPackCatalog.swift:213`: re-storing a cache hit is untested; without it every other launch fully re-verifies every pack. | DEFERRED | backlog. |
| R32.4-3 | MINOR | `RoadPackSelection.swift:205`: `RoadPackSelector`'s refused-set cache is untested (cost only: a network build per request). | DEFERRED | backlog. |
| R32.4-4 | MINOR | `RoadPackCatalog.swift:136`: the cache-version check is untested (matters after a future cache version bump). | DEFERRED | backlog. |
| R32.4-5 | MINOR | `LiveNavigationRun.swift:137`: resetting `newSelectionRequest` before the time-jump guard is untested; without it the app re-requests the previous circle after a rejected input (duplicate selection only). | DEFERRED | backlog. |
| R32.4-6 | MINOR | `SidecarComparison` `configBlamed`: the "hash differs but no keys parsed" branch is untested (explanation text only). | DEFERRED | backlog. |
| R32.4-7 | MINOR | `NavigationService.swift:222, 241`: no app test reaches the attach-refusal catch or the refused-set memo (a `configWouldChange` set would be rebuilt every fix, or Diagnostics would show "looking for a pack" instead of the reason). | DEFERRED | backlog. |
| R32.4-8 | MINOR | `NavigationService.swift:176, 246`: keeping the latest request during a selection and starting it afterwards is untested; a regression loses that request until the next fix. | DEFERRED | backlog. |
| R32.4-9 | MINOR | `RoadPackLibrary.swift:96`: a rescan requested during a scan (`rescanQueued`) is untested. | DEFERRED | backlog. |
| R32.4-10 | MINOR | `RoadsDiagnostics.swift:28`: "verified in %.1f s" shows 0.0 s for a 30–49 ms verify, too coarse for the D2 comparison with the Mac's 70.5 / 29.3 ms; show ms below 1 s. | DEFERRED | backlog. |

Tests: Core passes 843 tests in 114 suites, 36 known issues (test 3); one of five full runs during the fix failed once in "Navigation N4 B0" (wall-clock assert, known T-2). App unchanged since round 2; two full runs at 6e02554: one pass, one failure in the known link-loss test (R32.2-4, reproduced on main).

### Run 32 summary

4 rounds; round 4 still had a MAJOR (a missing test), resolved by the user's decision above. Findings: 5 MAJOR confirmed and fixed (R32.1-1, R32.1-2, R32.3-1, R32.4-1: regression tests for new logic; R32.2-1: pre-existing rule-4 race, fixed by the user's decision, closes R5.1-4), 0 rejected, 1 MINOR fixed (R32.2-2), 20 MINOR deferred (R32.1-3..9, R32.2-3, R32.2-4, R32.3-2, R32.3-3, R32.4-2..10). Final: Core 843 tests in 114 suites pass (36 known issues, test 3); app 293 tests pass apart from the pre-existing link-loss flake R32.2-4; simulator build succeeds.

## Run 33: roads selection diagnostics — roadsSelection sidecar line and roadPacks lifecycle row (main..roads-selection-log, 8e74eff..1f2d912), started 2026-10-16

### Round 1

Reviewer: one fresh `reviewer` (opus) on the whole range. Checks: Core imports Foundation only; frozen fixtures untouched, `roadPacks` pinned in the v3 suite; no coordinates in the new line; drive-8 `--write-sidecar` base vs HEAD identical apart from timing fields, with and without roads, after removing the `roadsSelection` lines; a never-covering pack vs no roads identical after removing them; `--compare` verdict unchanged. Result: 0 BLOCKER / 0 MAJOR / 4 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R33.1-1 | MINOR | `Core/Sources/DriveLoggerCore/Navigation/Roads/RoadPackSelection.swift:211-212`: the documented outcome order (unusableRequest before noPacks) is untested; moving the noPacks guard first survives. An unusable request with an empty library would be labelled noPacks (diagnostic label only). Fix: `attempt([], request: bad)` expects `.unusableRequest`. | DEFERRED | backlog. |
| R33.1-2 | MINOR | `Core/Sources/DriveLoggerCore/Navigation/Replay/SidecarComparison.swift:292-294`: the `--compare` fold rule's candidates equality is untested; dropping it survives, so a pack refused mid-drive could be folded into "(and N more like it)" (printout only). | FIXED | Fixed after the run (branch `road-packs-ux`, with the `roadsSelection` repeat folding): the fold rule is `RoadsSelection.isRepeat(of:)`, shared with the writer; `refusalsWithDifferentCandidatesNotFolded` checks two refusals with different candidates are neither folded on write nor by `--compare`. |
| R33.1-3 | MINOR | `AppTests/NavigationServiceRoadsTests.swift:279-301`: `refusedLines` ("written again, not rebuilt") cannot tell a remembered refused set from a rebuilt one (same reason text); removing `state.knownRefusals.append` (`NavigationService.swift:226-228`) would survive. R32.4-7's app-level attach-refusal path is still unreached (Core covers it in `finishSelectionAttachAndRefusal`). | DEFERRED | backlog. |
| R33.1-4 | MINOR | `App/Sources/Navigation/NavigationService.swift:104, 220, 272`: the test-only `attemptOutcomes` array lives in the production actor and is never cleared: with no covering pack about one entry per second, ~58 KB per recorded hour for the process lifetime. Fix: cap, reset at begin, or keep a counter plus last outcome. | FIXED | Fixed after the run (branch `road-packs-ux`, with the `roadsSelection` repeat folding): a count (`selectionAttempts`) and the last outcome (`lastAttemptOutcome`); per-recording counts in `Finished`; `NavigationServiceRoadsTests` wait on the count. |

Tests: Core passes 850 tests in 115 suites, 36 known issues (test 3). App: 304 tests in 48 suites pass. Simulator build succeeds.

### Run 33 summary

1 round; 0 BLOCKER / MAJOR. Findings: 0 fixed, 0 rejected, 4 MINOR deferred (R33.1-1 to R33.1-4). Final: Core 850 tests in 115 suites pass (36 known issues, test 3); app 304 tests in 48 suites pass; simulator build succeeds.

## Run 34: road-pack warning, push_packs.sh, Release scheme, roadsSelection repeats (main..road-packs-ux, d0b6817..1fe35c5), started 2026-10-16

Commits: d0b6817 DriveLogger-Release scheme, e7ade4f UX-8 backlog row, 2b5d039 `scripts/push_packs.sh`, 0289279 roadsSelection repeats folding, 1fe35c5 map road-pack warning.

### Round 1

Reviewers: two fresh parallel reviewers on the range, part A on the Core sidecar dedupe (`roadsSelection` repeats folding), part B on the app warning, the script, the scheme and the docs. Result: 0 BLOCKER / 0 MAJOR / 6 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R34.1-1 | MINOR | `Core/Sources/DriveLoggerCore/Navigation/NavSidecar.swift:328`: the `outcome` clause of `RoadsSelection.isRepeat(of:)` is untested; dropping it survives (mutation run). An `unusableRequest` attempt has the same candidates as a `noneCovering` one (all `covering: false`, no packs/reason), so without the clause it would be folded into the `noneCovering` repeats and its outcome lost from the sidecar and `--compare` rows (diagnostic only). Fix: test noneCovering, then unusableRequest (same candidates), then noneCovering gives 3 lines and 3 compare rows. | DEFERRED | backlog. |
| R34.1-2 | MINOR | `docs/NAV_SIDECAR.md:100-102`: "its `recordedAfterInputs` (the last repeat's) can be smaller than that of the line before it" is false: the roadsSelection line before a repeats line is the one it repeats, recorded earlier (drive-8: 4 then 277623). Fix: "can be smaller than the inputs handed to the run where it sits in the file (it is written later, at the next written line or at stop)". | DEFERRED | backlog. |
| R34.1-3 | MINOR | `App/Sources/Navigation/NavigationService.swift:171-176` with `App/Sources/RootView.swift:29-36`: a false "No road packs — roads off" can flash ~1 s at Start: `begin()` reports recording at once but the rescan runs in a `.utility` Task, so a poll before the rescan sets `scanTask` sees the previous (0 verified) scan as finished and idle, e.g. launch scan found nothing, packs pushed while the app is open, then Start. Fix: count the library as scanned only after this recording's own rescan returned (a per-recording flag in RoadsState/RoadsStatus); test with a slow library source. | DEFERRED | backlog. |
| R34.1-4 | MINOR | `App/Sources/Navigation/NavigationService.swift:243, 270`: per-recording `RoadsStatus.lastOutcome` is untested; returning the service-wide `lastAttemptOutcome` would show the previous drive's warning at the next Start and all tests pass. Fix: `NavigationServiceRoadsTests` case: recording 1 ends noneCovering, recording 2's `lastOutcome` is nil before its first attempt. | DEFERRED | backlog. |
| R34.1-5 | MINOR | `AppTests/RoadsWarningTests.swift:71-76`: `modelWritesOnlyChanges` runs one refresh from nil and never checks that an unchanged value causes no write. Fix: count observation changes across two equal refreshes (withObservationTracking), or rename. | DEFERRED | backlog. |
| R34.1-6 | MINOR | `scripts/push_packs.sh:68-70`: a `PRODUCT_BUNDLE_IDENTIFIER` containing `$(…)` is passed to devicectl literally: the listing fails with the misleading "app never launched, phone locked" warning, recording detection is off, every copy fails (nothing unsafe). Fix: die when the value contains `$(`. | DEFERRED | backlog. |

Tests: Core passes 862 tests in 116 suites, 36 known issues (test 3). App: 317 tests in 49 suites pass. Simulator build succeeds.

### Run 34 summary

1 round; 0 BLOCKER / MAJOR. Findings: 0 fixed, 0 rejected, 6 MINOR deferred (R34.1-1 to R34.1-6). Final: Core 862 tests in 116 suites pass (36 known issues, test 3); app 317 tests in 49 suites pass; simulator build succeeds. Not verified: whether `devicectl copy to --destination Documents/RoadPacks/<name>` with a file source writes exactly that path (needs a real copy to the phone).

## Run 35: constant-offset GNSS check — replay_nav --fix-offset, drive-10 report, N3-FIXPIN (main..fix-offset-check, 3e2374b), started 2026-10-16

Commits: 3e2374b `FixOffsetScan`, `replay_nav --fix-offset`, tests, docs/NAVIGATION.md "Constant-offset GNSS check", BACKLOG N3-FIXPIN.

### Round 1

Reviewer: one fresh reviewer on the whole range; mutation runs M1–M3 on `FixOffsetScanTests`; bit-identical check of clean `--gps mask-after 230 --seed 1` main against branch (GeoJSON byte-identical, metrics differ only in timings). Result: 0 BLOCKER / 1 MAJOR / 4 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R35.1-1 | MAJOR | `Core/Sources/DriveLoggerCore/Navigation/Replay/FixOffsetScan.swift:491-492`: `RoadField`'s neighbour-cell search is untested; querying only the point's own cell survives all 9 tests (the course-gate expectation `> 80 && <= 100` is met by the cap itself). A regression would inflate every recorded distance and rank silently. | CONFIRMED, FIXED | Test-only (no bug): `distancesSearchTheNeighbouringCells` (side neighbours incl. negative cells, diagonal); gated case now expects 60.2 m. Own-cell-only mutant: 4 failures; no-diagonal mutant: 1. |
| R35.1-2 | MINOR | `FixOffsetScan.swift:345-353`: the 2 s OBD hold cap in `dynamics` is untested (mutant survives; the test feeds OBD every 0.5 s). Fix: a case with a > 2 s reply gap. | DEFERRED | backlog. |
| R35.1-3 | MINOR | `FixOffsetScan.swift:216`: the `RoadField` margin ignores `options.tested`; a hypothesis longer than `maxShiftM + coarseStepM` is scored against a field missing roads (drive-10, `--fix-offset-test 326@70`: 17.4 / 17.6 / 21.7 m mean at `--fix-offset-max` 400 / 100 / 50). Fix: include the largest tested shift in the margin, or refuse it. | DEFERRED | backlog. |
| R35.1-4 | MINOR | `docs/NAVIGATION.md` "Constant-offset GNSS check": pin 2's vector (326 m @70°) is measured against a stationary 20–50 m fix (`--fix-max-acc 50`), not a clean one; the doc does not say so. | DEFERRED | backlog. |
| R35.1-5 | MINOR | `FixOffsetScan.swift:39, 129, 309`: "runner-up's median" (it is `statistic`); `Tested.rank` doc inverted (it counts shifts scoring at least as well); unused public `fixes(_:from:to:)` uses `t <= to`, the CLI `t < to`. | DEFERRED | backlog. |

Tests: Core passes 872 tests in 117 suites, 36 known issues (test 3). App/ unchanged.

### Round 2

Reviewer: one fresh reviewer on the whole range; R35.1-1 verified fixed (own-cell mutant killed); mutations on the verdict rules. Result: 0 BLOCKER / 1 MAJOR / 2 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R35.2-1 | MAJOR | `Core/Sources/DriveLoggerCore/Navigation/Replay/FixOffsetScan.swift:271-276`: the verdict rules are untested beyond "on roads" and "shift fits, unique": dropping the rank condition from `offRoad` and forcing `unique = true` both survive; "no shift fits" and "not unique" are never produced. | CONFIRMED, FIXED | Test-only (no bug): `aSmallOffsetWithALowRankIsOnRoads`, `aTrackOfAnotherShapeIsOffRoadsWithNoShiftFitting`, `aShiftFittingTwoPlacesIsNotUnique`; rank-gate, unique and found mutants killed. The scan tests now run on a 20 m / 2 m grid with default thresholds (`fast`): at the default grid the extra scans made the wall-clock check of NavigationB0Tests R13.1-6c fail under the parallel debug run (2 of 2 full runs). |
| R35.2-2 | MINOR | `FixOffsetScan.swift:297-305` with `replay_nav/main.swift` `--fix-offset auto`: the step is only checked > 0; `auto:60:1e-15` never advances `from` (infinite loop, memory grows), a tiny step gives millions of windows. Fix: a minimum step, or `first + k·step` with a cap. | DEFERRED | backlog. |
| R35.2-3 | MINOR | `Core/Sources/replay_nav/main.swift` `--fix-offset` block: exits 0 before engine-only flags (`--compare`, `--write-sidecar`, `--out`, `--truth`, `--gps`, `--set`) are used, silently; a script would read `--compare` as passed. Fix: refuse them with `--fix-offset` (status 2). | DEFERRED | backlog. |

Tests: Core passes 875 tests in 117 suites, 36 known issues (test 3), two full runs. App/ unchanged.

### Round 3

Reviewer: one fresh reviewer; round 2's `fast` grid checked sound (the suite also passes at the default 10 m / 1 m grid, and the 20 m grid makes the fine refinement find the true shift); mutations M1–M3. Result: 0 BLOCKER / 1 MAJOR / 0 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R35.3-1 | MAJOR | `Core/Sources/DriveLoggerCore/Navigation/Replay/FixOffsetScan.swift:272`: the `best.shift.lengthM >= foundMinShiftM` clause of `found` is untested (dropping it survives); a short shift that halves the mean (an ordinary bias) would be reported as an offset. | CONFIRMED, FIXED | Test-only: `aShiftShorterThanTheMinimumIsNotFound` (266 m shift, minimum raised to 300 m); the mutant fails it (2 issues). Fixed inline (a five-line test). |

Tests: Core passes 876 tests in 117 suites, 36 known issues (test 3). App/ unchanged.

### Round 4

Reviewer: one fresh reviewer on round 3's change (13c35b1..29ca7ab); the minimum-shift mutant is killed by `aShiftShorterThanTheMinimumIsNotFound`. Result: 0 BLOCKER / 0 MAJOR / 0 MINOR.

Tests: Core passes 876 tests in 117 suites, 36 known issues (test 3). App/ unchanged.

### Run 35 summary

4 rounds; 3 MAJOR fixed (R35.1-1, R35.2-1, R35.3-1, all test gaps, no production change), 0 rejected, 6 MINOR deferred (R35.1-2 to R35.1-5, R35.2-2, R35.2-3). Final: Core 876 tests in 117 suites pass (36 known issues, test 3); app unchanged. Engine untouched: clean `--gps mask-after 230 --seed 1` GeoJSON byte-identical between main and the branch (round 1).

## Run 36: app icon, UX-9/UX-10, D1 drive-11 record (main..docs-ux9-d1, ab4ec07..9fd454b), started 2026-10-16

Commits: ab4ec07 app icon (1024 px universal, no alpha); 8c8a21f docs/BACKLOG_UX.md UX-9, UX-10 (OPEN); 9fd454b docs/PLAN.md §6 D1 drive-11 (NOT claimed).

### Round 1

Reviewer: one fresh reviewer (sonnet) on the whole range. Checked the icon asset, the 7-column table rows, the code/doc references (FollowSpan cap 1000 m and heading-up only, PinPrecision.maxSpanM 300 m, FixOffsetScan, NAVIGATION.md "Constant-offset GNSS check", N3-FIXPIN, the "no new event kinds" constraint) and privacy (no coordinates or place names). It re-checked every drive-11 figure against the log and sidecar. Result: 0 BLOCKER / 0 MAJOR / 2 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R36.1-1 | MINOR | `docs/BACKLOG_UX.md:42` (UX-10): "on drive-10 the semi-major reached ~480 m"; the drive-10 sidecar peaks at 500.5 m (the FollowSpan cut-off is 455 m, so the argument still holds). | DEFERRED | backlog. |
| R36.1-2 | MINOR | `docs/PLAN.md:779` (D1, drive-11): only `maxStepMs` is called over the 2 ms limit, but the sidecar `msPerStep` (an EMA) is also 12.0 ms at 34 s and 4.4 ms at 35 s right after roads attach, then below 1.8 ms. | DEFERRED | backlog. |

Tests: Core passes 876 tests in 117 suites, 36 known issues (test 3). The simulator app build succeeded (icon).

### Run 36 summary

1 round; 0 fixed, 0 rejected, 2 MINOR deferred (R36.1-1, R36.1-2).

## Run 37: N3-FIXPIN close (main..n3-fixpin, 4de80cd..52ab3db), started 2026-10-17

Commits: 4de80cd truth excludeFixes; 9b6e008 N3-FIXPIN engine (keys default off); 8d8b47d replay_nav --fixpin-inject (injection study, replay only); 3e43317 RoadNetwork.covers cheapest coverage test first (byte-identical); 417f719 docs (measured, not adopted); 52ab3db review round 1 tests.

### Round 1

Reviewer: three fresh reviewers (opus) in parallel on disjoint sets: engine (FixPin, NavigationConfig/Engine/Estimate, RoadMatcher, RoadNetwork + tests), replay/tooling (Replay/*, replay_nav, injection + tests), docs. Key-off bit-identity re-run: drive-8 roads seed 1 main vs HEAD (identical incl. metrics/stdout via identity.py); clean + drive-8 seed 2 GeoJSON identical vs logs/fixpin/acc/main; injection clean seed 1 jsonl byte-identical. Mutations: engine M1 (re-anchor transform no-op) and M2 (refinement never true) survived, M3 (win-back against inflated σ) killed; replay M1 (junction angle), M2 (second-pin path min 0), M3 (t0 prefix bound) survived.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R37.1-1 | MAJOR | `NavigationEngine.swift:819-821` / `FixPin.swift:108-128` re-anchor `FixPinSource.transform` untested (mutation survives; no test sets reanchorDistanceM). | CONFIRMED | FIXED 52ab3db: `reanchorWhileDownweighted`, `sourceTransform`; all transform mutations killed. |
| R37.1-2 | MAJOR | `NavigationEngine.swift:1191-1193` engine refinement rule untested. | CONFIRMED | FIXED 52ab3db: `refinementWithinWindow`, `refinementOutsideWindow`, `refinementChain` (engine and pinScoring both rolling: each pin vs the one before). |
| R37.1-3 | MAJOR | `Replay/FixPinInjection.swift:222-249, 292-319` road-context classifier and second/third pin selection untested (backs the measured-not-adopted tables). | CONFIRMED | FIXED 52ab3db: `contextOnAnLDrive`, `secondAndThirdPinSelection`; mutations killed. |
| R37.1-4 | MINOR | `docs/NAVIGATION.md:345, 348`: "Key off = main, byte-identical on every run"; only GeoJSON is byte-identical, metrics.json/md/stdout gain the 9 config keys and the fix-pin counters at 0; key-off vs main compared at seeds 1–2 only. | DEFERRED | backlog. |
| R37.1-5 | MINOR | `docs/NAVIGATION.md:400-401` "with roads the road key decides first": both arbiters run and are OR-ed (`NavigationEngine.swift:1806-1838`); with both keys on and two pins displaced alike, the two-pin "pin" wins over road "fixes"; that both-keys case was never measured. | DEFERRED | backlog. |
| R37.1-6 | MINOR | `docs/NAVIGATION.md:371` vs `:411`: "0 of 1536" is pooled over 3 seeds while the text says per seed (512 per seed). | DEFERRED | backlog. |
| R37.1-7 | MINOR | `docs/NAVIGATION.md:434-438`: phone timing proposal; `pin.prior` is written before the ingest (`LiveNavigationRun.swift:240-246`), so `prior.maxStepMs` cannot hold the verdict step; `maxStepMs` is a session running max (`:291-308`), so the verdict shows only as a new maximum. | DEFERRED | backlog. |
| R37.1-8 | MINOR | `docs/NAVIGATION.md:580-592`: replay_nav synopsis omits `--fixpin-inject` and its sub-flags. | DEFERRED | backlog. |
| R37.1-9 | MINOR | `FixPinInjection.swift:464-469`: injected pins always record speedSource obd with the last OBD speed however old; the app's ManualFixGate falls back to GPS/unknown when OBD is stale, changing σ and χ². | DEFERRED | backlog. |
| R37.1-10 | MINOR | `FixPinInjection.swift:32-33`: `preS` (90 s) is not tied to `config.fixPinWindowS`; `--set fixPinWindowS=120` silently mixes unshifted fixes into the ring. | DEFERRED | backlog. |
| R37.1-11 | MINOR | `FixPinInjection.swift:404`: the t0 prefix boundary (a fix exactly at t0) is untested (mutation survives); negligible on real drives. | DEFERRED | backlog. |
| R37.1-12 | MINOR | (found while fixing R37.1-2) `NavigationEngine.swift:1183-1184` vs `NavigationReplay.swift:903-915`: the engine skips a manual fix with impossible coordinates before updating lastManualFixNs, pinScoring counts every manual fix, so a valid pin < 3 s after an invalid one is a refinement in scoring but judged by the engine. Recorded pins never carry such coordinates. | DEFERRED | backlog. |

Tests: Core 907 tests in 119 suites passed, 36 known issues (test 3); App/ unchanged (build-for-testing succeeded at 3e43317).
