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

## Run 54: backlog sweep nav batch 5 (7b1f833..18b662c, branch sweep-nav5), started 2026-10-18

Commits: 18b662c live-run, sidecar and service tests (R32.4-5, R32.4-6, R32.4-7, R32.4-8, R33.1-3, R34.1-4); `NavigationService.networksBuilt`, a count for tests only.

### Round 1

Reviewer: one fresh reviewer (opus), checks 9, 10 and 13 by reading: each author-expected kill traced through the code; the R32.4-8 test is deterministic (scan held at a gate, input processing does not wait on it). Result: 0 BLOCKER / 0 MAJOR / 0 MINOR. Sample mutations (orchestrator, throwaway worktree): `newSelectionRequest = nil` deleted in `LiveNavigationRun.ingest` → (a3) fails; `knownRefusals.append` deleted → `networksBuilt == 1` fails; `lastOutcome` from the service instead of the recording → the R34.1-4 test fails. All killed.

Tests: `cd Core && swift test` 991 passed, 36 known issues (after merge); release timing suites passed; App suites NavigationServiceRoadsTests and RoadPackLibraryTests 19 passed (simulator).

### Run 54 summary

1 round; 0 fixed, 0 rejected, 0 deferred; 6 backlog rows closed.

## Run 55 (lite): N2-3 magnetometer heading prior, result only (7b1f833..7d67794, branch sweep-n23doc), started 2026-10-18

Commits: 7d67794 NAVIGATION.md "N2-3: magnetometer heading prior": measured, fails the adoption rule on 4 of 18 gated cells; experiment code kept on the unmerged branch `exp-mag` (10f84ee), not on main (user rule: no engine merge unless it passes).

### Round 1

Reviewer: one fresh reviewer (sonnet), lite run, checks 10 and 11: no mag keys or types on main and none in the config table; every reference points to `exp-mag`; Δs, allowances and PASS/FAIL verdicts match the adoption rule (drive-7 roads consistency 1257/1365 = 92.1 % vs 96.3 %); off baselines equal "N3.2 decision". Privacy clean. Result: 0 BLOCKER / 0 MAJOR / 0 MINOR.

Tests: Core not run: no file outside docs/ changed.

### Run 55 summary

1 round; 0 fixed, 0 rejected, 0 deferred.

## Run 56: R53.1-2, vetoed steps keep the OBD-0 course veto (7fc5f3f..6f20b7a, branch sweep-zupt), started 2026-10-18

Commits: 6f20b7a `NavigationEngine.step`: a `zuptFixGate`-vetoed step's history records OBD's held value (0), not the Doppler speed it moved at, so course updates and reseeds stay vetoed (user decision: gate stays on; a freshness-only trigger would equal gate off, since a stale 0 already never ZUPTs). Also covers a gate-vetoed stale-parked step (consistent with the gate-off engine, R11.1-4). Tests: `ferryKeepsCourseVeto` (new), `parkedIsVetoed` (stalled link, stale moving reply), `stuckZeroDoesNotFreeze` (`courseUpdates == 0`), `vetoedStepSpeed` (`held == 0`). Adoption rule: seeds 1–5, every acceptance run with and without roads, 100 GeoJSON pairs byte-identical, `zuptVetoedSteps` 0: PASS, trivially. Simulator recording: course updates 88 → 0, reseeds 1 → 0.

### Round 1

Reviewer: one fresh reviewer (opus), checks 6, 8–13. `held` is read only through `heldAtFix` → `courseValid`, so only course use changes; catch-up and step-by-step history now agree on vetoed steps. Identical error figures in the stalled-link and simulator tests explained (same fixture, same path). No bound loosened. Bit-identical re-run: drive "clean", seed 1, roads, base vs head: GeoJSON identical. Mutations: author's `vetoed ? heldOBDSpeed : vObd` → `vObd` re-run (4 tests fail); `(vetoed || stale) ? 0 : vObd` → stale-moving assertion fails. Author mutations: 3, all killed. Result: 0 BLOCKER / 0 MAJOR / 0 MINOR.

Tests: `cd Core && swift test` 992 passed, 36 known issues (after merge); release `NavigationRoadPerfTests|NavigationB0Tests` 9 passed; no App change.

### Run 56 summary

1 round; 0 fixed, 0 rejected, 0 deferred; R53.1-2 closed.

## Run 57 (lite): M7.1-1 closed, R5.1-3 pipes escaped; throwaway worktree per mutation run (7fc5f3f, 7fc5f3f..432c835, merged 86625ca), started 2026-10-18

Commits: 7fc5f3f M7.1-1 closed as BELOW-BAR (user decision), R5.1-3 `||` escaped (user request). 432c835 mutation runs (reviewer check 13, author-side mutations) use a throwaway detached `.claude/worktrees/mut-<short-sha>`, removed after; authors commit first; shared `../dead-reck-mutants` and its settings rules dropped; mut-* add/undo/diff/status allowed, `..` denied. Lite at the user's request although the range touches `.claude/settings.json` and a hook comment. Measured: cold build 32 s, new worktree with the shared build dir 19–25 s, incremental after a one-line mutation 5 s.

### Round 1

Reviewer: one fresh reviewer (sonnet), lite run, checks 10 and 11 plus every documented command form against the allow/deny rules.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R57.1-1 | MAJOR | 2d3c45c (Run 56 ledger, between the two ranges) truncated `docs/REVIEW_LOG.md` (496 → 15 lines) and `docs/archive/BACKLOG-closed.md` (270 → 1 row). | CONFIRMED, FIXED | Orchestrator's script opened each file for writing before reading it. 632bdeb restores both from 2d3c45c^ and appends the Run 56 section and the R53.1-2 row (additions only). |
| R57.1-2 | MINOR | `.claude/settings.json`: `git -C .claude/worktrees/mut-* checkout -f -- .` also matches a second `-C <main tree>`, auto-approving a discard of the main tree's uncommitted changes. | FIXED | 632bdeb: deny `Bash(git -C .claude/worktrees/mut-* -C *)`. Fixed in the run, not deferred: it is in the rules this range introduces. |

### Round 2

Reviewer: one fresh reviewer (sonnet), lite: restore is additions only against 2d3c45c^ (265 → 266 archive IDs, the new one R53.1-2; M7.1-1 and R5.1-3 byte-identical; runs 35–56 in order); the new deny rule blocks no documented form; privacy clean. Result: 0 BLOCKER / 0 MAJOR / 0 MINOR.

Tests: Core not run: no Core change (lite).

### Run 57 summary

2 rounds; 2 fixed (R57.1-1, R57.1-2), 0 rejected, 0 deferred.

## Run 58 (lite): append-only guard; mutations Core-only by default (f70899f..51c488f plus the round-2 fix), started 2026-10-18

Commits: 19ef7df `.claude/hooks/append-only.sh` (PreToolUse, Bash) blocks a commit that loses more than 5 lines from `docs/REVIEW_LOG.md` / `docs/archive/**`; override only through `APPEND_ONLY_OVERRIDE=1` in the environment Claude Code starts with, a command naming it is refused (so commit messages naming it go through `-F <file>`); mutation scope: Core logic by default, an App mutation only for a reviewer-named App finding (reviewer.md check 13, the four engineer files, review-loop skill), ios-ui lists `logic -> test` instead. 73278d6 WORKFLOW hooks line. Lite at the user's request although the range touches `.claude/hooks/` and `.claude/settings.json`.

### Round 1

Reviewer: one fresh reviewer (sonnet), lite, checks 10 and 11; about 20 payloads piped to the hook in a throwaway worktree. Mutation-scope texts consistent.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R58.1-1 | MAJOR | `append-only.sh`: `git add ... && git commit` in one command is not guarded: the hook runs before the command, so the index is still empty (30-line truncation passed). | CONFIRMED, FIXED | 51c488f: working tree vs HEAD for the guarded paths, staged or not. |
| R58.1-2 | MINOR | `sh -c "git commit"`, `git -c k="a b" commit`, `git --no-pager commit`, `git commit <path>` are not matched. | FIXED | 51c488f: any command naming `git` and `commit` triggers; a false match blocks only when lines are really lost. |
| R58.1-3 | MINOR | WORKFLOW.md:314 (move old runs to `docs/archive/REVIEW_LOG-runs-<a>-<b>.md`) is blocked by the guard. | FIXED | 51c488f: only lost lines count (removed and not added back in the guarded files; untracked archive files count as added). |
| R58.1-4 | MINOR | jq missing: the first Bash call of a session is blocked once, then the hook fails open. | ACCEPTED | jq is a documented requirement; same as the other hooks. |

### Round 2

Reviewer: one fresh reviewer (sonnet), lite: about 15 cases (moves into untracked files with spaces/newlines in names, 2M-line file in ~1.5 s, truncation plus appended blanks, whitespace rewrite, symlink, `git rm`): all as intended.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R58.2-1 | MINOR | Fails open on invalid UTF-8: an untracked non-UTF-8 file under `docs/archive/` makes `sed`/`awk` fail, `lost` is empty and the truncation passes. | FIXED | Round-2 fix commit: `LC_ALL=C` on `sed` and `awk`; a non-numeric count blocks. Fixed in the run, not deferred: it is a fail-open in the guard this range adds. Test: random-bytes file under `docs/archive/` alone → 0; with a 60-line truncation → 2. |

Orchestrator tests after the fix (simulated payloads, throwaway worktree, no commits): truncation blocked in 9 command forms and staged; env override → 0; name in command → 2; 1 line removed, append, BACKLOG row move, runs moved to a new archive file → 0; 10 archive rows rewritten → 2; binary file cases as above.

Tests: Core not run: no Core change (lite).

### Run 58 summary

2 rounds; 4 fixed (R58.1-1, R58.1-2, R58.1-3, R58.2-1), 0 rejected, 0 deferred, 1 accepted (R58.1-4).

## Run 59: UX-1 part 1, Navigate mode state machine and engine without a writer (main..ux1-navigate-core: 3947b69, 679bb5c, ad03c68), started 2026-10-18

Commits: 3947b69 `NavigationService` runs a `RecordingNavigationFeed` with `Output.navigateOnly` (no sidecar writer; same engine path), `RoadsStatus.recording` → `active`. 679bb5c Core `LogSink.tapOnly` (keeps nothing, taps like a writer's sink); `RecordingSession` Navigate mode (`NavigateState` off/calibrating/running/waitingForOBD, auto-start at `polling`, 5 s still phase at speed 0, reconnect keeps the session, auto-stop after 5 min on `ContinuousClock`, Record ends Navigate and Stop returns to it, pins in Navigate go to the tap only, idle timer, no background location in Navigate via `ReferenceLocationSource.holdsBackgroundLocation`). ad03c68 map track/pins reset per run generation, fix age from the run clock, Diagnostics "Roads in use".

### Round 1

Reviewers: two fresh reviewers (opus) in parallel. A: Core sink, `RecordingSession`/`NavigateMode`, `AppServices`, `ReferenceLocationSource`, their tests, PLAN.md; re-ran author mutation 1 (`LogFile.swift:160` drop `isTapped`): killed by `tapsLikeAWritersSink`, `keepsNothing`; no further mutations (the author's three cover the changed Core logic). B: `NavigationService`, feed struct, map/UI files and their tests; no mutations (no Core logic); bit-identical acceptance re-run skipped by both (engine, config and Record's path unchanged). Both: no BLOCKER or MAJOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R59.1-1 | MINOR | PLAN.md §6 D1 and "Clears", NAVIGATION.md: still name the Diagnostics row "Recording uses", renamed "Roads in use" in this range. | FIXED | Run 59 ledger commit (one-line wording, stale because of this range). |
| R59.1-2 | MINOR | `scripts/push_packs.sh:131-146`: its in-use guard looks only for a recently changed log file; Navigate maps packs with no log, so a push during Navigate can SIGBUS the app. | DEFERRED | docs/BACKLOG.md R59.1-2. |
| R59.1-3 | MINOR | PLAN.md §6 "Added by UX-1 part 1" item 2: `navigateState` is not shown anywhere, so the still-phase check cannot be done on the device. | FIXED | Run 59 ledger commit: observe it in the debugger until UX-1 part 2 shows it. |

Not a finding (reviewer B, recorded for the record): the road-pack library's rescan at a run's start may rewrite `RoadPackVerification.json` in Application Support when the pack set changed — already the case for a recording's start or opening Diagnostics; pack names, sizes and hashes only, no positions, not visible in Files. Not counted against "Navigate writes nothing while driving".

Tests at HEAD (ad03c68): `cd Core && swift test` 997 tests in 129 suites passed (36 known issues, KI-1); App simulator `test` 382 tests in 55 suites passed. Core `Navigation/` logic unchanged (doc comments only), so the release perf suites were not required (navigation engineer ran them: 9 passed).

### Run 59 summary

1 round; 0 BLOCKER/MAJOR; 2 MINOR fixed in the ledger commit (R59.1-1, R59.1-3), 1 deferred (R59.1-2), 0 rejected.

## Run 60: UX-1 follow-ups, push_packs.sh app guard (R59.1-2) and navigateWritesNothing with the real verification cache (main..ux1-followups: 435deab, 89ba551), started 2026-10-18

Commits: 435deab `scripts/push_packs.sh` refuses while the app process runs on the phone (`devicectl device info processes`, executable path ending `/DriveLogger.app/DriveLogger`, name read from project.yml), fails closed when the list can't be read, keeps the log-mtime guard; `--force` overrides both, `--dry-run` reports both; hidden `--processes-json` for tests; help text, PLAN §6 D1/D2/Clears/N3.4, CLAUDE.md command comment. 89ba551 both `navigateWritesNothing` tests use `RoadPackLibrary.defaultCacheURL()` (set aside and restored, `FootprintLock`); exactly `Application Support/RoadPackVerification.json` may change (size and mtime compared), it must equal a scan of the pack files alone, and hold no session ID (any case, no hyphens, raw bytes) and no drive coordinates (exact, 4–6 dp, E7; coordinate-named keys only as the pack bounds). The cache rewrite itself is accepted by the user.

### Round 1

Reviewer: one fresh reviewer (opus). Parser fed fabricated JSON under `/bin/bash` 3.2; tests read for vacuity and flakiness; checks 10 and 11. No mutations (no Core logic; no App mutation justified). No BLOCKER or MAJOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R60.1-1 | MINOR | `scripts/push_packs.sh:111-118`: entries without a string `executable` were skipped, so a renamed key (e.g. `executableURL`, or a dict) gave "not running" (rc 0) and the packs could be overwritten while mapped; the comment claimed a changed shape refuses. | FIXED | 5485f69: no entry with a string `executable` exits 2 (refuse). Fixed in the run, not deferred: a fail-open in the guard this range adds (as R58.2-1). Orchestrator check via `--processes-json`: renamed key / dict → 2, empty → 2, other app only → 0, app listed → 1. |

Device checks for the guard: PLAN §6 "Added by run 60". R59.1-2 closed (moved to docs/archive/BACKLOG-closed.md).

Tests at 89ba551: `cd Core && swift test` 997 tests in 129 suites passed (36 known issues, KI-1); App simulator `test` 382 tests in 55 suites passed. 5485f69 touches only the script.

### Run 60 summary

1 round; 0 BLOCKER/MAJOR; 1 MINOR fixed in the run (R60.1-1), 0 deferred, 0 rejected; R59.1-2 closed.

## Run 61: UX-1 part 2, Navigate UI, R24.1-1 fix on arrival (main..ux1-navigate-ui: a66d3fc, eb737ca, 48416da, 1d12c3c), started 2026-10-18

Commits: a66d3fc map status line for `navigateState` (`NavigateStatus`, MapNavigateStatus.swift: calibrating "Hold still — calibrating" + 5 s countdown, running nothing, waitingForOBD "OBD lost — reconnecting" + "Stops in m:ss", off without a recording "Connect OBD for navigation without GPS" and no DR dot/ellipse), map Start removed (`MapRecordingControl.none`), Settings "Test drive recording" and "Mount and orientation", first-launch checklist (`FirstLaunchStore`, `firstLaunch.checklistConfirmed`), heading reset per run (`MapRunKey`, `HeadingReset.newRun`), `RecordingSession.navigateStartedAt`/`navigateTimings`. eb737ca PLAN §6 UX-1 part 2 checks. 48416da R24.1-1: `RecordingSession.latestFix` fed by `onReferenceFix` on arrival (App `ReferenceLocationSource`, Core `SimulatedLocationSource`), MapFeed reads it, `MapSpeedRule.maxGPSAgeS` 3 → 2 s (replayed fix timing on clean-long, clean, drive-7, drive-8, drive-10: 3 blinks ≤ 0.01 s in ~105 min at 2 s on arrival). 1d12c3c DEBUG-only `-navigateConnect`/`-navigateDisconnectAt` (DebugNavigate.swift) for simulator screenshots.

### Round 1

Reviewer: one fresh reviewer (opus). Mutation: author's `SensorSource.swift show()` callback above the run guard re-run, killed by `displayCallbackStaleRun`. No engine input path touched, no bit-identical replay.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R61.1-1 | MAJOR | `MapView.swift:79`: `.needsOBD` passed `navigation: nil` into GPSMapView, whose `runLoop` runs in `.task(id: isLive)` with the view copy from its start; opening the map before OBD polls (the normal case) left the loop without the feed, so after OBD connected no DR dot/ellipse appeared, follow and heading-up ignored the estimate until a tab switch or lock. | FIXED | 33f73de: the feed is always passed; `showsEstimate` gates drawing and every use of the estimate; the task is keyed on `MapLoopKey(isLive, showsEstimate)`. Test `loopKeyFollowsShowsEstimate` (cannot fail on the old code: the key type is new; the task capture itself is not unit-testable); simulator screenshot 04 retaken from a launch before OBD: the DR dot and ellipse appear without a tab switch. |
| R61.1-2 | MINOR | `ReferenceLocationSource.swift:142-146`: the queued main-actor display Task read `onReferenceFix` when it ran, with no run check, so a Navigate fix queued before Start reached the recording's callback (`latestFix` with an age against the wrong clock, looking fresh); `latestReferenceFix` could also be set after `stop()` cleared it. | FIXED | 66f7ed5: `ReferenceFixDisplay` run counter, as `SimulatedLocationSource.show`. Fixed in the run, not deferred: a defect in this range's own new code (as R60.1-1). Tests `referenceFixDisplayRun` (failed on the old code, 3 issues) and `referenceFixDisplay`. Sink path unchanged. |
| R61.1-3 | MINOR | `docs/PLAN.md` UX-1 part 2 item 5 said the screen does not dim while the "Connect OBD" line shows (`updateIdleTimer` keeps it on only while a session exists); part 1 item 4 said the countdown reaches 0:00 (auto-stop fires at the deadline). | FIXED | dd30ba6: wording matches the code. |
| R61.1-4 | MINOR | Decision (d) says the map shows the plain GPS position without OBD, but with Navigate off and no earlier run no location source runs: the map shows no position dot, the cached location only frames the camera. | DEFERRED | User decision: run the location source for display only while off, or amend (d). BACKLOG row R61.1-4. |

Tests at 1d12c3c: `cd Core && swift test` 999 tests in 129 suites passed (36 known issues); App simulator `test` 397 tests in 57 suites passed. At 66f7ed5: App 400 tests in 57 suites passed; Core unchanged since 1d12c3c.

### Round 2

Reviewer: one fresh reviewer (opus). Whole range, focus on 33f73de and 66f7ed5. Mutation: author's `SimulatedLocationSource.show` callback removed, killed by `displayCallback`. No engine input path touched. No BLOCKER or MAJOR.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R61.2-1 | MINOR | `docs/PLAN.md:255-257`: the UX-3 device checks still described the removed map Start button ("Start opens Settings, Recording", "the indicator turns back into Start") and the old row name "Recording", contradicting UX-1 part 2 item 3. | FIXED | In this ledger commit: UX-3 items 2–4 reworded (row "Test drive recording", no Start, the indicator disappears after Stop). A one-line docs fix to stale wording this range caused. |

Tests at 66f7ed5 (unchanged by round 2, docs only): `cd Core && swift test` 999 tests passed (36 known issues); App simulator `test` 400 tests in 57 suites passed.

### Run 61 summary

2 rounds; 1 MAJOR fixed (R61.1-1); 3 MINOR fixed (R61.1-2, R61.1-3, R61.2-1), 1 deferred (R61.1-4, user decision on (d)), 0 rejected; T61-1 (pre-existing flaky Core test) logged.

## Run 62: UX-1 follow-ups 2: GPS position without OBD (R61.1-4), status line, tab bar, T61-1 (a478bbc..ux1-followups-2: 3d0051d, a7d3ae5, 2f58bd0, cf723be), started 2026-10-18

### Round 1

Reviewer: one fresh reviewer (opus). No mutations: the Core change is test-only, and each App hand-over guard was mapped to a `DisplayLocationTests` test by reading.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R62.1-1 | MAJOR | `docs/PLAN.md` §6 UX-1 part 1 item 4 (auto-stop) said the location arrow disappears and no dot shows after auto-stop; with the display feed (R61.1-4) the GPS dot and the arrow stay while the app is open. | FIXED | docs-editor: PLAN §6 item 4 reworded (no DR dot or ellipse, sensors off, GPS dot and arrow stay while the app is open, both go away when backgrounded). |

Tests at HEAD: `cd Core && swift test` 999 tests in 129 suites passed (36 known issues); App simulator `test` 407 tests in 58 suites passed.

### Round 2

Reviewer: one fresh reviewer (opus). No mutations (no Core logic change; no App finding needed one). Checked the map side of the display feed (ingestion, first-fix framing at max(500 m, 3 × accuracy), run start/end while a display fix shows, staleness on inactive/background), the `ViewThatFits` status line with VoiceOver, the tab bar and accent, PLAN §6 / BACKLOG_UX / RELEASE_PLAN wording; R62.1-1 verified fixed.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R62.2-1 | MINOR | `AccentColor.colorset` dark variant (0.40, 0.70, 1.00) leaves white `.borderedProminent` labels at ~2.2:1 contrast in dark mode (was ~10.8:1): fix-toast Undo (`MapView.swift:611`), first-launch Continue, Record's Mark, Console Send / Re-initialise. | DEFERRED | BACKLOG row R62.2-1. |

Tests at HEAD: unchanged since round 1 (docs only): Core 999 tests in 129 suites passed (36 known issues); App 407 tests in 58 suites passed.

### Run 62 summary

2 rounds; 1 MAJOR fixed (R62.1-1, docs); 0 rejected; 1 MINOR deferred (R62.2-1). R61.1-4 and T61-1 closed by the range.

## Run 63: R62.2-1 prominent buttons readable in dark mode (main..r62-accent-contrast: 00c58fe), started 2026-10-18

### Round 1

Reviewer: one fresh reviewer (sonnet; 40-line view-only change, run at user's "lite is fine" with full checks). No mutations (view-only). Checked WCAG ratios from the colorsets (dark: black on accent 9.42:1, was white 2.23:1; light: white 10.85:1), every `.borderedProminent` now through `.prominentButton()`, disabled state (grey label, reads disabled), label colour through `.font`/`.frame`, no `.tint` conflicts, privacy and docs.

No findings.

Tests at HEAD: App simulator `test` 407 tests in 58 suites passed; Core unchanged from main (999 tests in 129 suites passed, 36 known issues).

### Run 63 summary

1 round; 0 findings. R62.2-1 closed.

## Run 64 (lite): BACKLOG_UX sync with UX-1 state (HEAD~1..HEAD on backlog-ux-sync: 1415a81), started 2026-10-18

### Round 1

Reviewer: one fresh reviewer (sonnet, lite: checks 10 and 11 only, no mutations, no tests). Verified the four UX-1 SHAs, "Test drive recording" in SettingsView, FollowSpan cap 1000 m heading-up only, Navigate tap-only sink vs Record writer + tap, `mapControlStyle` white on blue; privacy clean.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R64.1-1 | MINOR | UX-12's premise ("no engine running") does not match the code: with no session a pin is silently ignored; in Navigate `waitingForOBD` the engine still runs and takes the pin; in Record without OBD the pin is recorded. A literal fix could refuse valid ground-truth pins. | FIXED | In this run's ledger commit: UX-12 wording (repro state to confirm, scope of the refusal). |
| R64.1-2 | MINOR | UX-13 named only "Following"; `mapControlStyle(active:)` is shared with the Heading up / North up control. | FIXED | In this run's ledger commit: both controls in the item and acceptance. |

Tests: none (lite, docs only).

### Run 64 summary

1 round; 2 MINOR findings, both one-line wording fixes done in the ledger commit; 0 deferred, 0 rejected.

## Run 65: N3.4 pack storage, install path, Settings → Maps (main..n34-pack-storage: d41f69f, 061b7af, 323efbc, 3429efe, 49b81c3), started 2026-10-18

### Round 1

Reviewers: three parallel opus reviewers (A: Core + docs, B: App storage/library/push_packs.sh, C: App UI). Author mutations 5/5 killed; reviewer A re-checked 1 + 2 own, all killed.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R65.1-1 | MAJOR | `App/Sources/UI/Settings/MapsView.swift:206` / `SettingsView.swift:120`: `PackStatus.preview` is defined under `#if DEBUG` but used by an unguarded global and by `#Preview` blocks, so the Release configuration (DriveLogger-Release scheme, Archive) does not compile. | CONFIRMED | Fix: un-guard the preview helper (ios-ui-engineer, round 1 commit). Regression check: Release-configuration build. |
| R65.1-2 | MINOR | `MapsView.swift:160`: Maps shows the empty state ("No road maps installed") until the first scan, which runs launch maintenance (inbox copy + verify), so right after a push or the first launch after this update the screen says no maps while they install. | DEFERRED | Fix: pass `scansCompleted`/`scanning`, show "Looking for maps" until the first scan finishes. Backlog, UX-8 (prompt 25). |
| R65.1-3 | MINOR | `MapsView.swift:151`: the notice's OK button is ~34 pt tall, below 44 pt. | DEFERRED | Fix: `.frame(minHeight: 44)` or `.controlSize(.large)`. Backlog, UX-8 (prompt 25). |
| R65.1-4 | MINOR | `scripts/push_packs.sh:352-354`: skip-if-unchanged counts a store file marked for removal as installed (never reads `RoadPackStoreState.json`), so pushing to restore a pack after Remove-while-navigating prints "skipped (unchanged)" and the next launch deletes it. | DEFERRED | Fix: read the state file via devicectl and ignore marked names, or document in `--help` that `--force` is needed after a Remove until relaunch. Backlog, N3.4 / tooling. |

Tests before review: Core 1016 tests in 132 suites passed (36 known issues); release `NavigationRoadPerfTests|NavigationB0Tests` 9 tests in 2 suites passed; AppTests 436 tests in 65 suites passed.

Round 1 outcome: R65.1-1 fixed (preview helper no longer DEBUG-only); Release and Debug simulator builds succeed; Core unchanged since the pre-review run.

### Round 2

Reviewer: one fresh sonnet reviewer on the fix commit (f5ea05f) plus a Release-only sweep of the range. Release simulator build verified; no other DEBUG-guarded symbol used outside its guard. No new findings.

Tests at f5ea05f: AppTests 436 tests in 65 suites passed; Debug and Release simulator builds succeed; Core unchanged since round 1 (1016 tests in 132 suites passed, 36 known issues; release perf 9 tests in 2 suites passed).

### Run 65 summary

2 rounds; 1 MAJOR fixed (R65.1-1), 0 rejected, 3 MINOR deferred (R65.1-2, R65.1-3, R65.1-4).

## Run 66: UX-8 download, manifest, Settings → Maps, Diagnostics gate (main..ux8-download: f3fe2bd..b2999c2), started 2026-10-19

### Round 1

Reviewers: three parallel opus reviewers (A: Core + scripts/push_packs.sh, B: App downloader/manifest/network/installer/record-active relay, C: App UI + docs/site). Author mutations 3/3 killed; reviewer A re-checked 1 + 2 own (opaqueTag `W/` strip, stalePartials name-only), all killed. B and C: no App mutations (none needed).

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R66.1-1 | MAJOR | `site/public/privacy.html:37`: a leftover editing-tool fragment (`<parameter name="replace_all">false`) was committed into the Map downloads section (7982374); deployed, the public privacy policy would show a stray "false" and an unclosed unknown element. | CONFIRMED | Fix: line deleted (docs-editor); both privacy pages grepped for other leftovers, none. Same commit adds R66.1-4's sentence. |
| R66.1-2 | MAJOR | `App/Sources/UI/Settings/MapsView.swift:113,307` / `PackManifestService.swift:90`: the "Offline" note appears only after a failed fetch, and a fetch happens only when the cache is ≥ 24 h old or on pull to refresh, so airplane mode with a fresh cache shows no note (brief item 4, PLAN §6 UX-8 check 4). | CONFIRMED | Fix: `MapsText.listNote` also takes the path monitor's connection (`.none` → "Offline. Showing the saved list."), fed through the downloader snapshot (ios-ui-engineer). Regression tests: `MapsRowsTests/offlineFromConnection`, `modelOffline`. |
| R66.1-3 | MAJOR | `App/Sources/Maps/PackDownloader.swift:412-420`: `sha256(of:)` reads 1 MB chunks with `FileHandle.read(upToCount:)` (autoreleased) inside one detached job whose pool never drains, so the whole file stays in memory until the hash ends (reviewer measured a 300 MB file peaking at 307 MB; 8 MB with a pool); up to 150 MB per pack, also during Navigate. | CONFIRMED | Fix: each read in `autoreleasepool` (ios-ui-engineer). Regression test `PackHashMemoryTests/footprint` (128 MB file, footprint growth < 48 MB): verified by the orchestrator to fail without the fix (grew 125 MB) and pass with it. |
| R66.1-4 | MINOR | `site/public/privacy.html:38`, `site/public/uk/privacy.html:37`: the pages describe network use only as Wi-Fi-only map downloads, but the ~16 KB manifest is fetched on any network when Maps opens (`PackManifestService.swift:11`). | FIXED | Fixed with R66.1-1 (same paragraph of a public policy page, before deploy): one sentence in EN and UK. |
| R66.1-5 | MINOR | `docs/PLAN.md:288` and the BACKLOG_UX UX-8 row: "Updated · used from the next start" is shown only when the update installs while a Navigate or Record run is active (`PackDownloader.swift:404`); otherwise the row shows "Installed". | DEFERRED | Fix: say "while Navigate or Record runs". Backlog, UX-8 (prompt 26). |
| R66.1-6 | MINOR | `Core/.../PackDownloadRules.swift:123-125`: every 5xx to a ranged request → `restartWithoutRange`, which deletes the partial; since `plan` never asks past the size and URLs are immutable, a transient 502/503 on resume throws away e.g. 100 MB of a 120 MB pack. | DEFERRED | Fix: `.fail` and keep the partial for a 5xx to a ranged request (keep the restart for 416 / Content-Range mismatch); update `restartStatuses`. Backlog, UX-8 (prompt 26). |
| R66.1-7 | MINOR | `App/Sources/Maps/PackManifestService.swift:106,115-121`: applying a fresh manifest that gives the pack being downloaded a new contentHash deletes its partial as stale; the transfer writes into the unlinked file and fails "incomplete download" at the end (nothing wrong installed); a queued job keeps the outdated pack. | DEFERRED | Fix: skip partials of running/queued jobs in deleteStalePartials, or cancel and requeue those jobs with the new pack. Backlog, UX-8 (prompt 26). |
| R66.1-8 | MINOR | `App/Sources/Recording/AppServices.swift:81`: each path change reaches the downloader via its own `Task`, so cellular→Wi-Fi in quick succession can arrive reversed and leave rows "Waiting for Wi-Fi" on Wi-Fi until the next path change (never downloads over cellular: the session's `allowsCellularAccess` follows the toggle). | DEFERRED | Fix: an ordered relay like `RecordActivityRelay`. Backlog, UX-8 (prompt 26). |

Tests before review: Core 1040 tests in 134 suites passed (36 known issues); release `NavigationRoadPerfTests|NavigationB0Tests` 9 tests in 2 suites passed; AppTests 478 tests in 72 suites passed; Debug and Release simulator builds succeed.

Round 1 outcome: R66.1-1..4 fixed; AppTests 481 tests in 73 suites passed; Release simulator build succeeds; Core unchanged since the pre-review run.

### Round 2

Reviewer: one fresh opus reviewer on the fix commit (b7f4382) plus a sweep of the whole range (mapped `.roadpack` safety, recorder not disturbed, plain GETs only). No new findings. Note on deferred R66.1-8: since R66.1-2 the Offline note also reads the downloader's connection, so a reversed path update can show "Offline." until the next path change; the same ordered relay fixes it (added to the backlog row).

Tests at b7f4382: AppTests 481 tests in 73 suites passed; Release simulator build succeeds; Core unchanged since round 1 (1040 tests in 134 suites passed, 36 known issues; release perf 9 tests in 2 suites passed).

### Run 66 summary

2 rounds; 3 MAJOR fixed (R66.1-1, R66.1-2, R66.1-3), 1 MINOR fixed with R66.1-1 (R66.1-4), 0 rejected, 4 MINOR deferred (R66.1-5, R66.1-6, R66.1-7, R66.1-8).

## Run 67: UX-8 first launch, at-a-stop offer, R66.1-5..8, server 416 (main..ux8-first-launch: f52c7a1..0c45720), started 2026-10-19

### Round 1

Reviewers: three parallel opus reviewers (A: Core PackRegionChoice/PackOfferRule/PackDownloadRules + RoadPackLibrary.coverages + site function; B: App services (first-launch model, coarse fix, offer monitor, downloader/manifest, relays); C: App UI + Info.plist + project + docs/site). Author mutations 6/6 killed; reviewer A re-checked 1 + 2 own (time-backwards reset: survived → R67.1-3; card stays up in motion: killed). B and C: no App mutations (none needed).

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R67.1-1 | MAJOR | (user, 2026-10-19) `PackOfferRule`: a region counted as offered the moment its card showed, so a card hidden by drive-off before an answer never came back in that drive. | CONFIRMED | Fix (0c45720): only an answer (Download, Not now, Never) retires a region; an unanswered card shows again at the next stop, at most `maxShowsPerRegion` = 3 per region per drive; one continuous stop is one show; a hidden map consumes no show. Regression test `PackOfferRuleTests/unansweredReshowsAtNextStop` (fails on c993ea5). BACKLOG_UX UX-8 and PLAN §6 item 7 updated. |
| R67.1-2 | MAJOR | `App/Sources/Maps/PackOfferMonitor.swift:166,117`: the at-a-stop Download queued the pack entry from the cached manifest and nothing in the offer path refreshes it; after a `publish_packs.sh --prune` the old key 404s on every drive for a user who never opens Settings → Maps (failure visible only there). | CONFIRMED | Fix: the tap answers the rule and hides the card at once, then `manifest.refresh(force: false)` (24 h rule, shared in-flight fetch) and queues the entry with the same name from the snapshot; offline → cached entry; name gone → nothing queued. Tests `PackOfferManifestRefreshTests/freshEntry`, `cachedEntry`, `goneEntry` (all 3 fail on 0c45720). Residual (prune within the 24 h window) deferred as R67.1-7. |
| R67.1-3 | MINOR | `Core/Tests/DriveLoggerCoreTests/PackOfferRuleTests.swift:368`: the `clock()` test passes without the time-backwards reset (`PackOfferRule.swift:209-213`; mutation survived): the NaN step resets the timers before any distinguishing assertion. | DEFERRED | Fix: after `d.run(0...29, …)` expect the offer at 30; test NaN on a fresh drive. Backlog. |
| R67.1-4 | MINOR | `Core/.../PackOfferRule.swift:232-233,255`: after the estimate moves into another (uninstalled) region, the old `pendingRegion` stays for up to 30 s; a stop in that window offers the previous region ("You are in A" while in B). | DEFERRED | Fix: offer only when `pendingRegion == outside?.region`, or clear it when a confident estimate is in a different region. Backlog. |
| R67.1-5 | MINOR | `App/Sources/UI/Map/PackOfferCard.swift:52-77`: no Dynamic Type cap (the status line caps at `.accessibility2`); at AX3+ the card grows over the speed readout and "Download" wraps. | DEFERRED | Fix: `.dynamicTypeSize(...DynamicTypeSize.accessibility2)` as `MapNavigateStatus`. Backlog. |
| R67.1-6 | MINOR | `site/public/privacy.html:37`, `site/public/uk/privacy.html:37`: the pages say the ~16 KB maps list is fetched when Settings → Maps opens; it is now also fetched in the first-launch "Road maps" step (`FirstLaunchMaps.swift:237`) and, when due, on the at-a-stop Download (R67.1-2). | DEFERRED | Not fixed in the loop: prompt 26 limited `site/` edits to the UK label. Fix: one sentence in EN and UK before the next deploy. Backlog; raised to the user. |
| R67.1-7 | MINOR | (residual of R67.1-2) `PackOfferMonitor.download()` refreshes with `force: false`: a prune published within the cache's 24 h window still queues the old key and 404s. | DEFERRED | Fix: on a 404 to a pack, force one manifest refresh and retry once with the fresh entry of the same name (`PackDownloader` + PackTransfer result case). Backlog. |

Tests before review (0c45720 / c993ea5): Core 1066 tests in 136 suites passed (36 known issues); release `NavigationRoadPerfTests|NavigationB0Tests` 9 tests in 2 suites passed; AppTests 519 tests in 80 suites passed (c993ea5), PackOfferMonitorTests 6/6 (0c45720); simulator build succeeds.

Round 1 outcome: R67.1-1, R67.1-2 fixed; AppTests 522 tests in 81 suites passed; simulator build succeeds; Core unchanged since 0c45720.

### Round 2

Reviewer: one fresh opus reviewer on the round-1 fix commits (0c45720, c80d91e) plus a sweep of the range (offer never in motion / with a dialog / with the map hidden, nothing to the recording or sidecar, coarse fix never stored or sent). Mutations 3/3 killed (author's `<`→`<=` re-checked; per-stop show guard; per-stop reset). No new findings.

Tests at c80d91e: AppTests 522 tests in 81 suites passed; simulator build succeeds; Core unchanged since 0c45720 (1066 tests in 136 suites passed, 36 known issues; release perf 9 tests in 2 suites passed).

### Run 67 summary

2 rounds; 2 MAJOR fixed (R67.1-1 from the user, R67.1-2), 0 rejected, 5 MINOR deferred (R67.1-3..7).

## Run 68: UX-14/31/32/33/34 map HUD layout E, Settings hub, OBD adapter, About (main..ux32-map-settings: b566b81..269ed34), started 2026-10-19

### Round 1

Reviewers: two parallel opus reviewers (A: map HUD — App/Sources/UI/Map/*, MapHUDTests; B: RootView/AppNavigation, Settings/About/OBD adapter, Console, Link, Sessions, project, README/site/docs). No mutations (Core untouched; App logic covered by the authors' logic -> test lists; no finding needed an App mutation).

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R68.1-1 | MAJOR | `App/Sources/UI/Map/MapView.swift:817-825` (`cameraCenter`) with `MapNavigation.swift:358-362` (`FollowZoom.distance`/`FollowSpan`): the heading-up ellipse fit still assumed a centred car; with the car at 2/3 height (`CarPlacement`) only a third of the visible height is behind it, so a 300 m semi-major lost its rear third off-screen (undoes the UX-6 "ellipse fit wins in heading-up" rule in the jammed case). | CONFIRMED | Fix (b5a061a): `FollowSpan.span(carFromTop:)` scales the ellipse requirement by 0.5 / (1 − carFromTop) (×1.5 at 2/3) after the 1000 m cap, then max with the driver's zoom; `FollowZoom.distance` passes `CarPlacement.carFromTop` in heading-up; north-up unchanged. Regression test `CarPlacementTests.ellipseFitBehindCar` (fails 3× on 269ed34); `followZoomDriverGesture` updated 880 → 1320 m. |
| R68.1-2 | MINOR | `App/Sources/UI/Map/MapView.swift:549`, `MapHUDViews.swift:89`: `hasRecording: recordingControl != nil` is always true (`MapScreen` always passes a non-nil `AnyView(MapRecordingButton…)`, empty while idle), so the card has 0 pt bottom padding in every non-recording session; a "Thermal fair" row sits on the card's bottom edge. | DEFERRED | Fix: derive from `session.state` (calibrating/recording/stopping) or pass nil while idle. Backlog. |
| R68.1-3 | MINOR | `MapView.swift:604` with `CarPlacement.carFromTop`: the at-a-stop offer card (~210 pt, x 12…295 on SE) covers the car arrow at 2/3 height in heading-up while shown (stationary only; `PackOfferRule` hides it in motion). | DEFERRED | Fix: centre the car (offset 0) while the offer is shown, or accept and record the decision. Backlog; raised to the user. |
| R68.1-4 | MINOR | `App/Sources/UI/Console/ConsoleViewModel.swift:218`: `adapterName` = `link.adapter?.name ?? link.rememberedAdapterName`, but `OBDLinkService.adapter` is never cleared on disconnect/forget/retarget; after forgetting A and tapping B, Settings → OBD adapter says "Connecting to A" / "A not found" until B initialises (forever if it never does). `AdapterSettingsTests.name` asserts this order. | DEFERRED | Fix: use `link.adapter?.name` only when its identifier equals `rememberedAdapterID`, else `rememberedAdapterName`; add a mismatched-record test. Backlog. |
| R68.1-5 | MINOR | `README.md:156`: "Diagnostics … in Release after 7 taps on Version" — Version moved to Settings → About; `README.md:52` "Open" still lists "dark-mode map controls (UX-13)", superseded by UX-32. | DEFERRED | Fix: "7 taps on Version in Settings → About"; drop UX-13 from Open. Backlog. |

Reviewer A dismissed: GPS-quality chip colour removal (the accuracy circle still carries the band colour), rail active state without colour, recording-row hit area (fixed 269ed34), OSM line vs Apple's marks (no overlap by code; device check), camera offset reaches nothing downstream. Reviewer B dismissed: Mount-and-orientation 0.5 s cover hand-off, `mapIsLive` gating, `BLEAvailability.Reason` byte-identical strings, no user text sends users to Console, Sessions ShareLink in a cover, 15 s timer, guard sharing, README/site accuracy.

Tests before review (269ed34): Core 1066 tests in 136 suites passed (36 known issues; Core untouched in the range); AppTests 567 tests in 87 suites passed.

Round 1 outcome: R68.1-1 fixed (b5a061a); AppTests 568 tests in 87 suites passed.
