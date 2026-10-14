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
| R26.2-1 | MINOR | Zoom-only writes skip the 4 Hz `NavWriteGate` while the zoom ramps (up to 9–10/s for ~3 s), contradicting PLAN §6 N4 check 1. | DEFERRED | BACKLOG |
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
