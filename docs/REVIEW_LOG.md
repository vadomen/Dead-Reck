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

## Archived runs 17–34

In [docs/archive/REVIEW_LOG-runs-17-34.md](archive/REVIEW_LOG-runs-17-34.md). Look up one run by number or range; never read the file whole:

- Run 17: N3.1 follow-ups (main..n3.1-followups, 3d6f70e..2273684), started 2026-10-12
- Run 18: N3.0 part 1 (5bcfb1e..54c0a6d), started 2026-10-12
- Run 19: N3.0 part 2 (0b59494..n3.0-part2), started 2026-10-12
- Run 20: N3.0 part 3 (main..n3.0-part3, 211d93f..38a8103), started 2026-10-12
- Run 21: N3.2a road model in the engine (main..n3.2a, 027cedb..fec31dd), started 2026-10-13
- Run 22: N3.2b replay_nav roads and first road measurement (main..n3.2b, 10b2551..5efbb20), started 2026-10-13
- Run 23: N3.2c items 7, 2, 6 and the N3.2d grids (main..n3.2c, a1055f2..740d3b9), started 2026-10-13
- Run 24: UX-2 and UX-5, map tab first and speed/source block (main..ux-map, f9629f1..b57ff2c), started 2026-10-13
- Run 25: UX-3 and UX-4, Settings tab and map recording control (main..ux-map, 5076fc9..d61121c), started 2026-10-13
- Run 26: UX-6 speed-dependent zoom, R24.1-1, R25.1-1..2 (main..ux-map, 7f3066b..09a505a), started 2026-10-13
- Run 27: drive-8 acceptance, scoreUntilT, PLAN B-2 note (main..drive8-acceptance, b61fa86..6c99826), started 2026-10-14
- Run 28: N3.2e level rule across packs, candidates re-run, trade-off table, CLAUDE.md perf command, WORKFLOW roadmap (main..n3.2e, ecf4f31..c6912c5), started 2026-10-14
- Run 29: N3.2 decision, default roadCorrelationM 100, decision docs (main..n3.2-decision, 4e87038..acd2979), started 2026-10-14
- Run 30: R26.2-1 follow-loop camera writes gated to 4 Hz (main..fix/r26.2-1-zoom-gate, 1454ae3), started 2026-10-14
- Run 31: N3-SLC speedless course, measured and rejected; drive-9 acceptance definition (main..n3-speedless-course, 6f9c235), started 2026-10-15
- Run 32: N3.3 roads in the live engine, developer pack bridge (main..n3.3, 4e29b3e), started 2026-10-15
- Run 33: roads selection diagnostics — roadsSelection sidecar line and roadPacks lifecycle row (main..roads-selection-log, 8e74eff..1f2d912), started 2026-10-16
- Run 34: road-pack warning, push_packs.sh, Release scheme, roadsSelection repeats (main..road-packs-ux, d0b6817..1fe35c5), started 2026-10-16

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
| R37.1-3 | MAJOR | `Replay/FixPinInjection.swift:222-249, 292-319` road-context classifier and second/third pin selection untested (backs the measured-not-adopted tables). | CONFIRMED | FIXED 52ab3db: `contextOnAnLDrive`, `secondAndThirdPinSelection`; the two named mutations killed; three further ones survived in round 2 (R37.2-2, R37.2-3). |
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

### Round 2

Reviewer: two fresh reviewers (opus) in parallel: engine set and replay/tooling set (docs unchanged since round 1 apart from the ledger). Engine: R37.1-1 and R37.1-2 confirmed fixed (mutations: drop `!refinement` from `fixPinSignificantPins` and a chain anchored on its first pin both killed; swapping jen/jne at the transform call site survived, R37.2-1). Replay: three mutations survived (drop `interior`, drop the nearest-road margin in the parallel rule, drop the second pin's own-ring rule), R37.2-2, R37.2-3.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R37.2-1 | MINOR | `Core/Tests/DriveLoggerCoreTests/NavigationFixPinTests.swift:466` (`reanchorWhileDownweighted`): the synthetic drive is near latitude 0, so the re-anchor Jacobian is the identity and the engine-level test cannot see the linear part (swapped/dropped J arguments at `NavigationEngine.swift:820` survive); `FixPinSource.transform` itself is unit-tested. | DEFERRED | backlog. |
| R37.2-2 | MAJOR | `Core/Sources/DriveLoggerCore/Navigation/Replay/FixPinInjection.swift:302,316`: the parallel-road `interior` rule is untested (R37.1-3 only partly fixed): without it, the next segment of the car's own multi-node street counts as parallel, reshuffling the context strata of the injection results. | CONFIRMED | FIXED 454ea01: lMap's first street gets a node every 100 m; first-leg pin times, 130 s and direct `context()` cases asserted straight; the mutation now fails 16 expectations. |
| R37.2-3 | MINOR | `FixPinInjection.swift:316, :232`: the parallel rule's nearest-road margin (pin offset from its own road) and the second pin's own-ring minimum (a fix gap before pin 2) are not exercised; mutations survive. | DEFERRED | backlog. |

Tests: Core 907 tests in 119 suites passed, 36 known issues (test 3); App/ unchanged.

### Round 3

Reviewer: one fresh reviewer (opus): 454ea01 plus a whole-range pass (key-off identity, covers reorder, nearestCompatibleDistance, injection driver, excludeFixes, privacy, imports). Mutation "drop `interior`" now killed (16 issues). Re-runs: drive-8 roads seed 1 keys off, HEAD vs main: GeoJSON byte-identical, metrics.json identical minus the new keys/counters at off values and timing (as R37.1-4 records); injection clean seed 1 (road, two-pin roads off) JSONL and stdout byte-identical to the study's r1 outputs. No findings.

Tests: Core 907 tests in 119 suites passed, 36 known issues (test 3); App/ unchanged.

### Run 37 summary

3 rounds; 4 MAJOR fixed with tests (R37.1-1, R37.1-2, R37.1-3, R37.2-2; no production code changed by the loop), 0 rejected, 11 MINOR deferred (R37.1-4..12, R37.2-1, R37.2-3). Final: Core 907 tests passed, 36 known issues.

## Run 38: agent instructions — current scope, nav ownership, acceptance file, model rule, in-project worktrees (e9a353d..8b294a5), started 2026-10-17

Commits: 8b294a5 CLAUDE.md scope (logger + live DR navigator), WORKFLOW roadmap/model/worktree rules, navigation-engineer app ownership and baseline pointer, reviewer triage rows, acceptance drives in git-ignored logs/ACCEPTANCE.md, settings worktree rules for .claude/worktrees/*.

### Round 1

Reviewer: one fresh reviewer (sonnet) on the whole range, checks 10 and 11: privacy (diff and commit message), referenced NAVIGATION.md sections, files, config keys, flags, review runs 32/37 and backlog N3-FIXPIN-GATE, .gitignore, settings allow/ask/deny precedence for the worktree rules, ownership and model-rule consistency across WORKFLOW, agents and review-loop. Before the commit the orchestrator ran a probe worktree at .claude/worktrees/probe: RepositoryInvariantTests 4/4 passed, Core import grep clean, `xcodegen generate` left no project diff; probe and branch removed. Result: 0 BLOCKER / 0 MAJOR / 1 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R38.1-1 | MINOR | `.claude/agents/reviewer.md` check 13 and `.claude/settings.json` use the cwd-relative `../dead-reck-mutants`; nothing says the mutation and bit-identical commands run from the main tree. A reviewer started in `.claude/worktrees/<task>` would resolve it to `.claude/worktrees/dead-reck-mutants` (the old sibling `../dead-reck-<task>` worktrees shared its parent). The git-ignored acceptance file's "or the worktree under review" has the same ambiguity. | FIXED | fixed after the run; backlog row closed. |

Tests: Core not re-run: no file outside docs/, .claude/ and CLAUDE.md changed (code equals e9a353d); App/ unchanged.

### Run 38 summary

1 round; 0 fixed, 0 rejected, 1 MINOR deferred (R38.1-1).

## Run 39: R38.1-1 fix and release plan (879ef28..0c1d19e), started 2026-10-17

Commits: 1e7df00 reviewer.md check 13: mutation and bit-identical commands from the main tree root, `--package-path` instead of `cd` (R38.1-1 closed); 0c1d19e docs/RELEASE_PLAN.md (English, scrubbed release plan) and WORKFLOW App Store line pointing at it.

### Round 1

Reviewer: one fresh reviewer (sonnet), lite review, checks 10 and 11 plus the check-13 commands against the settings allow/ask/deny rules and RELEASE_PLAN.md against the repo (site/ pages, icon and privacy-page status, UX-1/UX-8, N3.4, project.yml and Info.plist keys, required-reason APIs). Privacy clean; no contradictions found. Result: 0 BLOCKER / 0 MAJOR / 2 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R39.1-1 | MINOR | `.claude/agents/reviewer.md:81` says "`cd <root>` once"; the shell resets its cwd after a `cd` outside the session's project directory, so a reviewer started in `.claude/worktrees/<task>` falls back to the worktree and `../dead-reck-mutants` resolves wrongly again. Fix: start each mutation/bit-identical call with `cd <root> && `, or check `pwd` first. | FIXED | fixed after the run; backlog row closed. |
| R39.1-2 | MINOR | `docs/RELEASE_PLAN.md:148`: "`site/publish_packs.sh` ... it asks before running"; the script has no prompt of its own (only `--dry-run`); the ask is the `.claude/settings.json` permission rule. | FIXED | fixed after the run; backlog row closed. |

Tests: Core not run: no file outside docs/ and .claude/ changed; App/ unchanged.

### Run 39 summary

1 round; 0 fixed, 0 rejected, 2 MINOR deferred (R39.1-1, R39.1-2).

## Run 40 (lite): review process — lite path, author-side mutations, MINOR bar (4862d33..7211493), started 2026-10-17

Commits: 7211493 review-loop "Lite path" (no code in the range: one sonnet reviewer, checks 10 and 11, one-line wording MINORs fixed in the run), engineers' author-side mutations (check-13 procedure, uncommitted change brought into `../dead-reck-mutants` via a staged patch; reviewer re-checks one and covers the rest), reviewer MINOR bar (concrete failure scenario required); WORKFLOW.md lines to match.

### Round 1

Reviewer: one fresh reviewer (sonnet), lite run, checks 10 and 11, including the new command forms against the settings allow/ask/deny rules. Privacy clean. Result: 0 BLOCKER / 1 MAJOR / 2 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R40.1-1 | MAJOR | Engineer agents' author-side mutation step 2, `git -C ../dead-reck-mutants apply --index <patch>`, matches no allow rule in `.claude/settings.json`: every engineer run that changes logic stops at a permission prompt and may skip or mis-target its mutations. | CONFIRMED, FIXED | Allow rule `Bash(git -C ../dead-reck-mutants apply --index *)` added (user approved the settings edit). |
| R40.1-2 | MINOR | `.claude/agents/ios-ui-engineer.md`: `-only-testing:AppTests/<Suite>`; the test target is `DriveLoggerAppTests` (`project.yml`), so the command finds no target. | FIXED | One-line fix in the round commit (lite rule). |
| R40.1-3 | MINOR | `.claude/skills/review-loop/SKILL.md` lite trigger omits `Config/` and `DriveLogger.xcodeproj`: a signing/build-setting-only range would get a lite review with no build. | FIXED | Both added to the trigger list in the round commit (lite rule). |

Tests: Core not run: no file outside docs/ and .claude/ changed; App/ unchanged.

### Round 2

Reviewer: one fresh reviewer (sonnet), full path (the round-1 fix touched `.claude/settings.json`), re-review of 7211493..0f2105d: checks 10 and 11 and the new allow rule's scope (no deny/ask conflict; `git apply` refuses paths leaving the worktree without `--unsafe-paths`). R40.1-1..3 verified fixed. Result: 0 BLOCKER / 0 MAJOR / 0 MINOR.

Tests: Core not run: no file outside docs/ and .claude/ changed; App/ unchanged.

### Run 40 summary

2 rounds; 3 fixed (R40.1-1..3), 0 rejected, 0 deferred.

## Run 41 (lite): backlog triage sweep phase A (fb6c108..18bd76d), started 2026-10-17

Commits: 18bd76d 60 DEFERRED rows closed under the reviewer's MINOR bar (52 BELOW-BAR, 6 FIXED, 2 OBSOLETE) and 3 already-closed rows moved to `docs/archive/BACKLOG-closed.md`; KI-1 added for the `NavigationRoadOffRoadTests` known issue.

### Round 1

Reviewer: one fresh reviewer (sonnet), lite run, checks 10 and 11: all 6 FIXED rows hold at HEAD, both OBSOLETE texts gone, KI-1 facts match (12 checks per seed not re-run), all 52 BELOW-BAR rows read and the recording/link/release ones spot-checked: none hides a concrete failure. Privacy clean. Result: 0 BLOCKER / 0 MAJOR / 0 MINOR.

Tests: Core not run: no file outside docs/ changed.

### Run 41 summary

1 round; 0 fixed, 0 rejected, 0 deferred.

## Run 42 (lite): backlog triage decisions and Opus re-check (a8b2ea1..d92e300), started 2026-10-17

Commits: d92e300 user decisions on the DECIDE rows (4 to PLAN §6 device checks, 4 closed with UX-11, a NAVIGATION reversing note and a NAV_SIDECAR pin.prior note); Opus re-check of the 60 phase-A closures, 58 hold, R26.2-3 and R27.1-2 reopened.

### Round 1

Reviewer: one fresh reviewer (sonnet), lite run, checks 10 and 11: PLAN §6 code facts, the NAV_SIDECAR pin.prior sentence, UX-11 columns, moved and reopened rows byte-identical apart from Status. Privacy clean. Result: 0 BLOCKER / 0 MAJOR / 1 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R42.1-1 | MINOR | `docs/NAVIGATION.md` "Reversing" bullet still headed "(backlog N2-1, N3 candidate)" and offering a mode 01 gear PID, while its new last sentence says closed and that mode 01 has no gear signal: someone planning N3 picks it up as open. | FIXED | One-line wording fix in the ledger commit (lite rule): header says closed, gear-PID idea dropped, ideas marked "considered, not planned". |

Tests: Core not run: no file outside docs/ changed.

### Run 42 summary

1 round; 1 fixed (R42.1-1), 0 rejected, 0 deferred.

## Run 43 (lite): backlog sweep docs batch (d92e300..cccfb03, branch sweep-docs), started 2026-10-17

Commits: cccfb03 R4.1-7, R19.1-3, R22.3-4, R26.1-2, R27.1-2, R29.1-2, R29.1-3, R37.1-7 fixed in the docs (each statement re-derived from the code), R26.2-3 doc half fixed, PLAN §6 UX-2 tab order corrected.

### Round 1

Reviewer: one fresh reviewer (sonnet), lite run, checks 10 and 11: every changed statement checked against the code it cites; moved rows byte-identical apart from Status; no stale "80 km/h", "2.45", "second-best" or old tab order left. Privacy clean. Result: 0 BLOCKER / 0 MAJOR / 0 MINOR.

Tests: Core not run: no file outside docs/ changed.

### Run 43 summary

1 round; 0 fixed, 0 rejected, 0 deferred.

## Run 44: backlog sweep elm batch 1 (1cd8d50..68959b3, branch sweep-elm), started 2026-10-17

Commits: 68959b3 M1-E1 per-ECU tolerant replies, B1-1 one retry on a first-sample timeout in start-up selection, M7.1-1 plan remembered only when selection kept every PID, M7.1-2 remembered plan cleared on poll-failure escalation, M7.1-3 plan keyed on ATDPN + 7E8 0100 bitmask, M7.1-5 init capture replays post-init adapter re-announcements, M7.1-6 tests.

### Round 1

Reviewer: one fresh reviewer (opus), checks 1, 3, 4, 6–11, 13. Author mutations: 3 listed, 1 re-run (killed); reviewer's 2 own mutations survived. Result: 0 BLOCKER / 2 MAJOR / 0 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R44.1-1 | MAJOR | `ELMSession.swift:830`: the handshake `0100` rule (with a fault, only 7E8's `41 00` counts) is untested; `(scan.faults.isEmpty \|\| $0.isFromPrimaryECU)` → `true` survives every ELM suite. A regression would accept a reply with 7E8's line cut short and init with no 7E8 answer. | CONFIRMED, FIXED | `ELMSessionMultiECUToleranceTests.supportedPIDsFaultWithoutPrimaryFails` (4 replies: 7E8 cut short either order, no 7E8 with a cut-short 7EA, no 7E8 with `NO DATA`). |
| R44.1-2 | MAJOR | `ELMSession.swift:1173`: B1-1's "selection only, not the ATAT comparison" limit is untested; default `retriesFirstTimeout` → `true` passes all ELMSession tests, so ATAT2 could be kept after a timed-out reply. | CONFIRMED, FIXED | `ELMSessionAdaptiveTimingTests.atat2FirstSampleTimeoutNotRetried`. |

Tests: `cd Core && swift test` 940 tests in 124 suites passed, 36 known issues (KI-1). The fixer's mutation runs were blocked by the permission classifier; round 2 checks them.

### Round 2

Reviewer: one fresh reviewer (sonnet), re-review of 2a8f935..abb00d7: both fixer mutations run (no permission denial for the reviewer) and killed (`supportedPIDsFaultWithoutPrimaryFails` on all 4 cases; `atat2FirstSampleTimeoutNotRetried` with 7 issues); both tests assert what their names claim. Result: 0 BLOCKER / 0 MAJOR / 0 MINOR.

Tests: unchanged since round 1 (940 passed, 36 known issues).

### Run 44 summary

2 rounds; 2 fixed (R44.1-1, R44.1-2), 0 rejected, 0 deferred.

## Run 45: backlog sweep elm batch 2 (ec77c62..da19774, branch sweep-elm2), started 2026-10-17

Commits: da19774 R3.1-3 requested cancel reported as `.cancelled`, R3.1-5 backoff reset on the first reading, R3.1-6 write failures as `ble` notes, R3.1-7 10 s GATT discovery/notify watchdog, R3.2-2 one connect path, R32.2-4 shutdown drains a closed transport (link loss ends `failed / transport closed`).

### Round 1

Reviewer: one fresh reviewer (opus), checks 1–11, 13. Author mutations: 4 listed (3 App, run in the author's worktree), the Core one re-run and killed; the reviewer's own mutation survived. Result: 0 BLOCKER / 1 MAJOR / 0 MINOR. The fixer found a second, pre-existing data loss while writing the test (R45.1-2), verified by the orchestrator against the code.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R45.1-1 | MAJOR | `ELMSessionTests.swift:719`: `shutdownAfterTransportLost` checks only the end state; nothing tests that bytes buffered at the link loss are recorded. `await reader.value` → `_ = reader; transportDidClose()` survives every ELMSession suite while dropping a buffered reply. | CONFIRMED, FIXED | `shutdownAfterTransportLostDrainsBufferedBytes` with a gated transport that proves the bytes are still buffered when shutdown runs. |
| R45.1-2 | MAJOR | `ELMSession.swift` (since cad8c53): a reply resolved by the reader but not yet emitted by `run()` is lost when the stream ends in the same step: `abandonInFlight` skips a resolved flight and `transportDidClose()` finishes `events` first, so the exchange row, its `rx` and readings vanish (probe: 50 of 50). `shutdown()` had the same window for manual commands and replies before `send` returned. | CONFIRMED, FIXED | Recording moved into the flight (`record` closure, `UnrecordedReply`); `recordUnrecordedReply()` before `failed`/`idle` and `finish()`; no duplicate when `run()` resumes. Tests `replyThenStreamEnd(phase:)`, `replyThenStreamEndBeforeSendReturns`, `shutdownRecordsResolvedReply` fail on HEAD's ELMSession. |

Tests: `cd Core && swift test` 945 tests in 124 suites passed, 36 known issues (KI-1); AppTests OBDLinkServiceTests + StartupInitRecordingTests 27 passed (fixer). Fixer mutations not run (shared mutants worktree held another run's patch; one fixer earlier denied by the permission classifier); round 2 runs them.

### Round 2

Reviewer: one fresh reviewer (opus), re-review of da19774..9b5c122: R45.1-1 and R45.1-2 fixed; the refactor keeps the normal-path order, writes no duplicate rows, keeps `nextSeq` and stamps, and every caller handles `run()` throwing after its row without a stray state change (also removes an old window where a resumed handshake could change state after `failed`). Its mutation reset was denied by the permission classifier (stale staged patch in `../dead-reck-mutants`); after the user cleared the worktree, the orchestrator ran the 3 mutations with the check-13 procedure: `recordUnrecordedReply()` removed in `transportDidClose` → `replyThenStreamEnd` (both phases) and `replyThenStreamEndBeforeSendReturns` fail; removed in `shutdown` → `shutdownRecordsResolvedReply` fails; `await reader.value` → `_ = reader; transportDidClose()` → `shutdownAfterTransportLostDrainsBufferedBytes` fails. Result: 0 BLOCKER / 0 MAJOR / 0 MINOR.

Tests: unchanged since round 1 (945 passed, 36 known issues).

### Run 45 summary

2 rounds; 2 fixed (R45.1-1, R45.1-2), 0 rejected, 0 deferred.

## Run 46: backlog sweep sensors batch 1 (06435c6..cac994d, branch sweep-sensors), started 2026-10-17

Commits: cac994d M2-S4 link/elm reordering not warned, M2-S5 weighted stats means and short final window skipped, M6.1-2 duration from the start row, R4.1-8 writer-queue alarm in Core with tests, M6.1-5 proof test (no fix), M8.1-3 live OBD speed cleared at Start, R4.1-4 bounded blocking flush on willTerminate.

### Round 1

Reviewer: one fresh reviewer (opus), checks 2, 3, 6–11, 13; inspect_log run on a real drive and the init replay measured on five (46 rows, first-window queue peak 43–47, under the 200 floor). willTerminate wait bounded (3 s), no main-actor hop on the flush path, throw still signals. Mutations: author's floor mutation re-run and killed; no-stats check from `firstT` killed; Pre-Start `<` → `<=` survived. Result: 0 BLOCKER / 0 MAJOR / 1 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R46.1-1 | MINOR | `RecordingAnalysis.swift:418`: Pre-Start boundary untested (`<` → `<=` survives); a regression prints "Pre-Start 0.000 s" for every file whose start row is first. | DEFERRED | docs/BACKLOG.md |

Tests: `cd Core && swift test` 955 passed, 36 known issues (KI-1); simulator build OK; App suites 42/42 (author).

### Run 46 summary

1 round; 0 fixed, 0 rejected, 1 MINOR deferred (R46.1-1).

## Run 47: backlog sweep sensors batch 2 (89c3619..5ab430c, branch sweep-sensors2), started 2026-10-17

Commits: 5ab430c R32.3-2 no `calibrationEnd` after a write failure during calibration, R4.1-3 stop and write-failure end paths hold a background task until the file is finished; tests for R14.3-6, R15.1-3 (skip branch reachable; the generation conditions argued unreachable and commented), R32.3-3, T-1, R5.1-5, R46.1-1.

### Round 1

Reviewer: one fresh reviewer (opus), checks 2, 5–11. The background task begins after every early return, ends once by `defer`, expiry makes the later end a no-op; concurrency clean; the R15.1-3 unreachability argument holds; forced orderings deterministic (FIFO main-actor executor, serialized suites); T-1 bounded and sharp. Mutations: none this round (the mutants worktree was assigned to another agent; no Core logic changed); author killed the Core `<` → `<=` mutation in `../dead-reck-mutants` and showed the App tests fail with each guarded line removed in its own worktree. Result: 0 BLOCKER / 0 MAJOR / 0 MINOR.

Tests: `cd Core && swift test` 956 passed, 36 known issues (KI-1); simulator build OK; full AppTests 333 passed (author); RecordingSessionTests 6/6 runs (author).

### Run 47 summary

1 round; 0 fixed, 0 rejected, 0 deferred.
## Run 48: backlog sweep ios-ui batch 1 (89c3619..273eaf9, branch sweep-ui), started 2026-10-17

Commits: 273eaf9 M10.1-3 `mapSpanM` is the viewport height in heading-up too, M10.1-2 locked-screen courses feed the bearing, R14.1-3 frame after a fresh poll, R5.1-2 record-without-OBD toggle stays visible, R5.1-3 Start state reset before awaiting, R5.1-6 no "Marked" when not recording (partial), R5.1-7 / R5.2-1 / R5.2-3 console gating, R5.2-2 Start always stops a pending scan (view-model half).

### Round 1

Reviewer: one fresh reviewer (opus), checks 6, 7, 9–11 and UI safety while recording, by reading (the mutants worktree was assigned to another agent). Every row's test would fail on 89c3619 (compile or assertion); M10.1-3 leaves the engine σ at 30 m for every new row under the 300 m gate. The author's mutation step was denied by the permission classifier; the orchestrator ran its 3 App mutations in `../dead-reck-mutants` with xcodebuild: rotated span branch dropped → "Visible span means the viewport height in both modes" fails; `.failed` case removed from `canScan` → `scanRefused` fails; checklist reset moved after the await → `restartDuringCalibration` fails. Result: 0 BLOCKER / 0 MAJOR / 3 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R48.1-1 | MINOR | `docs/LOG_FORMAT.md:575`, `MapFraming.swift:35`, `NavigationConfig.swift:631-633`, PLAN §6 item 12: old heading-up `mapSpanM` is said to be "up to ~2.2×" the viewport height (so "errs toward a larger σ"); on a portrait screen it is ~0.5×–1.15× (smallest near east/west), so old values can understate. | DEFERRED | docs/BACKLOG.md (ios-ui batch 2) |
| R48.1-2 | MINOR | `AppTests/UIPresentationTests.swift:571,579`: unbounded `while session.state != .calibrating` loops: a regression hangs the AppTests run instead of failing. | DEFERRED | docs/BACKLOG.md (ios-ui batch 2) |
| R48.1-3 | MINOR | `ConsoleViewModel.swift:183` / `ConsoleView.swift:89-93`: after R5.2-1, tapping an adapter row while recording with no adapter held shows "Drop the OBD connection?"; "Keep connection" cancels the connect a user wanted. | DEFERRED | docs/BACKLOG.md (ios-ui batch 2) |

Tests: `cd Core && swift test` 955 passed, 36 known issues; simulator build OK; full AppTests 340 passed (author).

### Run 48 summary

1 round; 0 fixed, 0 rejected, 3 MINOR deferred (R48.1-1..3).

## Run 49: backlog sweep nav batch 1 (cbeb19e..80aaaf7, branch sweep-nav1), started 2026-10-17

Commits: 80aaaf7 R16.1-2 / R16.2-1 `build_roads` argument checks and bench-after-verify, R17.1-2 `build_packs.sh` name checks, R18.1-3 / R32.1-5 replay labels (pair window, sidecar/live attach), R19.1-2 max error by checkpoint kind (clean-fix max columns), R35.1-3 fix-offset field margin, R35.2-3 `--fix-offset` refuses engine-run flags.

### Round 1

Reviewer: one fresh reviewer (opus), checks 6, 8–13 and compatibility with older runs and scripts. Bit-identical re-run on the clean drive (release, seed 1, roads): GeoJSON `cmp`-identical, metrics differ only in timing and the new key. build_packs.sh name check run on 8 configs. Mutations: author's `maxErrorByKind` one re-run and killed; `maxErrorByKind` decode dropped killed; five `--fixpin-*` members dropped from `engineOnlyFlags` survived. Result: 0 BLOCKER / 0 MAJOR / 2 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R49.1-1 | MINOR | `FixOffsetScanTests.swift:160`: only `--fixpin-inject` of the six `--fixpin-*` members of `engineOnlyFlags` is tested; dropping the other five survives, so R35.2-3's silent ignore could return for them. | DEFERRED | docs/BACKLOG.md (nav TEST-ONLY batch) |
| R49.1-2 | MINOR | `NavigationReplay.swift:1404`: `KindMaxError` sits between `EllipseConsistency`'s doc comment and its struct, so the R13.1-8 "one denominator" rule documents the wrong type and `EllipseConsistency` has none. | DEFERRED | docs/BACKLOG.md (nav TEST-ONLY batch) |

Tests: `cd Core && swift test` 965 passed, 36 known issues; release `NavigationRoadPerfTests|NavigationB0Tests` 9 passed.

### Run 49 summary

1 round; 0 fixed, 0 rejected, 2 MINOR deferred (R49.1-1, R49.1-2).

## Run 50: backlog sweep ios-ui batch 2 (64d4a0c..2b1586b, branch sweep-ui2), started 2026-10-17

Commits: 2b1586b R48.1-3 connect wording when no connection is held while recording, R26.2-3 dead `followDistance` removed, M10.1-6 follow-resume loop and heading resets extracted and tested, M10.1-5 / R34.1-5 write counters, R26.2-2 and R5.2-4 tests, R48.1-1 heading-up `mapSpanM` range corrected, R48.1-2 bounded test loops.

### Round 1

Reviewer: one fresh reviewer (sonnet), checks 6, 8–11 by reading (the mutants worktree was assigned to another review). Every ELM `.failed` path stops polling first, so "Connect" in `.failed` replaces a dead session; the M10.1-6 extraction matches the old code line for line; the R48.1-1 range checks out (peak √(1+r²)·H at atan r). The orchestrator ran the author's 3 App mutations in `../dead-reck-mutants`: stationary guard removed → "Stationary is assigned only when it flips" fails; `abs(log(…))` → `log(…)` → "A falling wanted distance also wants a write" fails; `!holdsConnection` dropped → "The confirmation says connect when no adapter is held" fails. Result: 0 BLOCKER / 0 MAJOR / 2 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R50.1-1 | MINOR | `docs/NAVIGATION.md:220` still says the heading-up logged span "can be up to about 2.2× too large … so it is safe"; R48.1-1 corrected that elsewhere (0.5×–1.15×, can understate). | DEFERRED | docs/BACKLOG.md |
| R50.1-2 | MINOR | `ConsoleViewModel.swift:149`: the connect message says "Earlier parts of it stay without."; false when the recording had OBD before the link was lost. | DEFERRED | docs/BACKLOG.md |

Tests: `cd Core && swift test` 956 passed, 36 known issues; simulator build OK; full AppTests 355 passed (author).

### Run 50 summary

1 round; 0 fixed, 0 rejected, 2 MINOR deferred (R50.1-1, R50.1-2).

## Run 51: backlog sweep nav batch 3, roads/packs tests (1e1be23..a9c1749, branch sweep-nav3), started 2026-10-18

Commits: a9c1749 tests for R16.1-6 (golden hash with COVR and timestamp), R17.1-1, R28.1-4, R32.4-2, R32.4-3, R32.4-4, R32.4-9 (App), R33.1-1, R34.1-1; tests only. R32.1-6 left (needs a production seam).

### Round 1

Reviewer: one fresh reviewer (sonnet), checks 9–11 by reading (the mutants worktree was assigned to another agent): each listed mutation would fail its test; the R32.4-9 test fails rather than passes on a late arrival; fixtures synthetic. The orchestrator ran 3 of the author's mutations in `../dead-reck-mutants`: `cache.store` removed → `cacheHitIsStoredAgain` fails; `outcome ==` dropped from `isRepeat` → `outcomeAloneSeparatesAttempts` fails; `a == b` early return removed → `multiPackBFSEqualsPackAdjacency` fails. Result: 0 BLOCKER / 0 MAJOR / 0 MINOR.

Tests: `cd Core && swift test` 970 passed, 36 known issues; AppTests RoadPackLibraryTests 4 passed ×6 (author).

### Run 51 summary

1 round; 0 fixed, 0 rejected, 0 deferred.
## Run 52: backlog sweep nav batch 4 (6605dc5..f5fce9e, branch sweep-nav4), started 2026-10-18

Commits: f5fce9e replay, scoring, fix-offset and FixPin tests (R18.1-1, R20.2-1, R22.3-3, R27.3-2, R35.1-2, R37.1-11, R37.2-1, R37.2-3, R49.1-1); `KindMaxError` moved off `EllipseConsistency`'s doc comment (R49.1-2); internal `identityOf` seam in `RoadPackCatalog`, public API unchanged (R32.1-6).

### Round 1

Reviewer: one fresh reviewer (opus), checks 9–13. Mutations (orchestrator): `excludePins` tie `<` → `<=`, `--fixpin-separation` dropped from `engineOnlyFlags`, file-changed guard forced true: all killed. Mutations (reviewer, own scratch worktree): odd/even speed offsets re-paired in `macroStep` (1075.7 m vs < 1000 m bound), `jen`/`jne` swapped in the re-anchor transform (60° case fails, 0° passes), FixPin prefix `<` → `<=`: all killed. `engineOnlyFlags` matches NAVIGATION.md "replay_nav" and the six `--fixpin-*` flags. Privacy clean (latitude-60 plane synthetic). Result: 0 BLOCKER / 0 MAJOR / 0 MINOR.

Tests: `cd Core && swift test` 989 passed, 36 known issues (after merge); release timing suites passed; no App change.

### Run 52 summary

1 round; 0 fixed, 0 rejected, 0 deferred; 11 backlog rows closed.

## Run 53: backlog sweep nav batch 2 (1e1be23..d130298, branch sweep-nav2), started 2026-10-18

Commits: d130298 N4B1-1 `zuptFixGate` (default on: an OBD 0 does not freeze the cloud while ≥ 2 consecutive good fixes after the zeros began read ≥ 5 m/s; adoption rule: seeds 1–5 identical on every acceptance drive with and without roads, 0 vetoed steps; simulator drift 523 m → < 1 m), R14.1-4 sidecar flushed on background through an `onFlush` hook and `--compare` names an early end, R34.1-3 "No road packs" waits for this recording's own rescan.

### Round 1

Reviewer: one fresh reviewer (opus), checks 2, 6–13. Bit-identical re-run (clean, seed 1, roads, release, base vs head): GeoJSON `cmp`-identical. Gate causal and deterministic, no double counting; `onFlush` adds no rows and runs after the log flush. Mutations: author's `fixNs > since` killed; `if stale {` → `if stale && !vetoed {` survived all 29 Navigation suites; `!zeroVetoed` dropped from `isStopped` survived but is practically equivalent. Result: 0 BLOCKER / 1 MAJOR / 1 MINOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R53.1-1 | MAJOR | `NavigationEngine.swift:668`: no test covers the unknown-speed noise on vetoed steps; without it the cloud moves at exactly the held Doppler speed with no spread (overconfident ellipse). | CONFIRMED, FIXED | `NavigationZeroFixGateTests.vetoedStepTakesStaleSpeedNoise` (offset std 3.99 m/s vs 0 in a no-noise reference, along-track shift rms 6.86 m). The fixer's mutants reset was denied by the classifier (its patch apply ran); the orchestrator ran the mutation on that staged state: `if stale && !vetoed` → the new test fails. |
| R53.1-2 | MINOR | `NavigationEngine.swift:695` (read at :1001/:1007, reseed :1068): a vetoed step records `held` as the Doppler speed, so the OBD-0 course veto no longer protects fixes taken then: on a ferry with the car parked across the travel direction, a course reseed sets the heading to the ferry's course; with GNSS lost on landing, DR runs off at the parking angle. | DEFERRED | docs/BACKLOG.md; raised to the user with the default-on question |

Tests: `cd Core && swift test` 976 passed, 36 known issues; release perf filter 9 passed; simulator build OK; App suites 56 passed (author).

### Round 2

Reviewer: one fresh reviewer (sonnet), re-review of d130298..24fc38b by reading: the test asserts what its name claims, is seeded, its bounds match the OU theory (std ≈ 3.97 m/s, shift rms ≈ 7.1 m) with wide margins, and cannot pass for the wrong reason (exact 29 vetoed steps, `staleSpeedSteps == 0`, no resampling in the window). Result: 0 BLOCKER / 0 MAJOR / 0 MINOR.

Tests: 976 passed, 36 known issues.

### Run 53 summary

2 rounds; 1 fixed (R53.1-1), 0 rejected, 1 MINOR deferred (R53.1-2).

## Run 55 (lite): N2-3 magnetometer heading prior, result only (7b1f833..7d67794, branch sweep-n23doc), started 2026-10-18

Commits: 7d67794 NAVIGATION.md "N2-3: magnetometer heading prior": measured, fails the adoption rule on 4 of 18 gated cells; experiment code kept on the unmerged branch `exp-mag` (10f84ee), not on main (user rule: no engine merge unless it passes).

### Round 1

Reviewer: one fresh reviewer (sonnet), lite run, checks 10 and 11: no mag keys or types on main and none in the config table; every reference points to `exp-mag`; Δs, allowances and PASS/FAIL verdicts match the adoption rule (drive-7 roads consistency 1257/1365 = 92.1 % vs 96.3 %); off baselines equal "N3.2 decision". Privacy clean. Result: 0 BLOCKER / 0 MAJOR / 0 MINOR.

Tests: Core not run: no file outside docs/ changed.

### Run 55 summary

1 round; 0 fixed, 0 rejected, 0 deferred.
