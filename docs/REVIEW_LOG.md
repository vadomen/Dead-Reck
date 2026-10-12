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
