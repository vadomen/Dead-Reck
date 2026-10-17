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
