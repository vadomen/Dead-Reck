---
name: nav-adoption
description: Run the navigation adoption rule by hand - the acceptance matrix through replay_nav (runs x seeds 1-5 x roads on/off), the gated metric per run, the allowances against the baseline, and a PASS/FAIL table. Use before adopting any engine or NavigationConfig default change, or when asked whether a navigation change regresses the acceptance drives.
---

# Navigation adoption check (manual, until `eval_nav`)

The rule is defined in docs/NAVIGATION.md "Adoption rule for engine changes" and "Acceptance runs"; this skill is only the procedure. If they disagree, the doc wins: report the disagreement. Once backlog EVAL-1 (`docs/EVAL_PLAN.md`) lands, run `eval_nav` instead and this skill shrinks to a pointer.

## Inputs
- `logs/ACCEPTANCE.md` (private): alias → recording path and acceptance flags, packs, truth file. Never quote a path from it in a tracked file, finding or commit: use the alias.
- `logs/truth.json`: written by the user, never edited by an agent.
- Baseline: the latest decision table in NAVIGATION.md for the current `main` (e.g. "N3.2 decision", "N3.3: roads live"). If the baseline isn't in a table, run the same matrix on `main` in a throwaway worktree `.claude/worktrees/mut-<sha>` first (remove it after).

## Matrix
- Runs: every alias in the "Acceptance runs" table — clean-long, clean, manual, jammed-A, jammed-B, drive-7, drive-8, drive-9 (1), drive-9 (2). manual-3 runs but is reported only. Count them before you start; a missing run is a FAIL, not a skip.
- Seeds 1–5 each (`--seed N`). Means are over exactly 5 seeds.
- Roads: each run without and with the default packs (`--roads` × 2, from `logs/ACCEPTANCE.md`). drive-9's criterion is gated with roads only; consistency gates in both legs.
- Release build, one `--out` directory per leg: `logs/adopt-<sha>/{noroads,roads}`. `metrics.json` merges rows across invocations.

```bash
cd Core && swift run -c release replay_nav <recording> <acceptance flags> --seed <N> \
  --truth ../logs/truth.json [--roads <pack> --roads <pack>] --out ../logs/adopt-<sha>/<leg>
```
Use a script to loop the matrix (≈ 100 replays); run it in the background with a bounded wait (`ios-build-test`, "Long runs").

## What is gated (per run, read from `metrics.json`)
| runs | metric | criterion (every seed) | allowance (mean over seeds vs baseline) |
|---|---|---|---|
| clean-long, clean | max error, m | ≤ 30 m | worse by ≤ max(2 m, 5 % of baseline mean) |
| manual | error at truth point 1, m | ≤ 200 m | same as above |
| jammed-A, jammed-B | end error, % of distance | ≤ 2.5 % | worse by ≤ 0.1 pp |
| drive-7, drive-8 | `maxErrorByKind.cleanFix.maxPercent` (not "max %", which includes pins) | ≤ 2.5 % (drive-8: fixes up to truth `scoreUntilT`) | worse by ≤ 0.1 pp |
| drive-9 (1), (2) | error at the truth point, % | ≤ 2.5 %, with roads only | worse by ≤ 0.1 pp |
| all | `consistencyWithTruthSigma` (not `consistency`) | — | mean must not drop |

Reported, not gated: manual-3, manual's convergence distance, engine-only `consistency`, ms/step.

Pitfalls the rule has already been broken by: wrong metric key; a mean over 4 seeds; a drive left out; the no-roads leg of drive-9 gated; a criterion checked on the mean instead of on every seed.

## Report
One table in the "N3.2 decision" layout: run, leg, gated mean (min–max over seeds), baseline mean, Δ (allowed), every-seed criterion yes/no, consistency baseline → now, verdict. Then: **PASS** only if every gated row passes; otherwise **FAIL** naming the rows. Correctness fixes may move numbers: list every changed row with its explanation.

Never change the baseline, the truth file, the criteria or the frozen truth σ / clean-fix limits to make a run pass: that moves the bar and is the user's decision.
