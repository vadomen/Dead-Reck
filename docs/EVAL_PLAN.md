# EVAL plan: the adoption rule as an executable check

Status: proposed 2026-10-19 (backlog EVAL-1). Owner: navigation-engineer.
The rule itself is unchanged: `docs/NAVIGATION.md` "Adoption rule for engine
changes" and "Acceptance runs" stay the definition until step 6, after which
`eval_nav` is the definition and the doc describes it.

## Why

Today the adoption rule is prose. An agent reads the aliases from the private
`logs/ACCEPTANCE.md`, runs 50+ `replay_nav` invocations by hand, averages over
seeds, compares with numbers in markdown tables and writes the verdict. Every
step can go wrong silently: a drive left out, the wrong metric (`max %` instead
of `maxErrorByKind.cleanFix.maxPercent`), the wrong allowance, a mean taken
over 4 seeds. The earlier output directories the tables came from
(`logs/n32dec`, `logs/n3sc`) are gone, so the baseline exists only as text.
The engine changes often; each change re-runs this by hand.

Goal: one command gives PASS/FAIL against a frozen baseline, with a per-drive
table, and the decision logic is unit-tested.

## Non-goals

- No change to the engine, its defaults, the metrics or the thresholds.
- Not CI: recordings and truth are private and stay on the Mac.
- No LLM or agent evals.

## Design

### 1. Manifest (private): `logs/eval/acceptance.json`

Machine-readable form of `logs/ACCEPTANCE.md` plus the criteria table. One
entry per acceptance *run* (drive-9 has two):

- `alias`, `recording` (path, `~` expanded), `flags` (the acceptance flags as
  an argument array), `roads`: `gated` | `report` | `none` (drive-9: gated with
  roads only; the no-roads leg is report-only).
- `gate`: `metres` | `percent` | `none` (manual-3), the `metricKey` in
  `metrics.json` that is gated, and the criterion (`maxM` or `maxPercent`,
  plus any extra criterion such as manual's truth point 1).
- `reportOnly` entries (drive-10, drive-11, later drives) are run and reported,
  never gated: they show over-fitting to the gated set.
- Packs: the N3.2 default set, in canonical order; seeds: 1–5.

Tracked: the Codable types and a synthetic fixture in tests. Never a real path
or alias→file mapping (CLAUDE.md: recordings are private).

### 2. Baseline (private): `logs/eval/baseline.json`

Per run × roads leg × seed: the gated metric, `consistencyWithTruthSigma`, the
engine-only `consistency` (reported), criterion pass/fail; plus the commit,
the config hash, the packs' content hashes, the truth file's hash, and the
manifest hash. Written only by `eval_nav --write-baseline --reason "<text>"`;
the previous file is kept as `baseline.<UTC time>.json`, never overwritten.
An agent never runs `--write-baseline` on its own: like `truth.json`, it is
the user's decision (it moves the bar).

Accepted exceptions: the N3.2 decision accepted a FAIL against N3.0 (drive-7
consistency). That is expressed by re-baselining on the accepted config, with
the decision in `--reason`, not by a per-drive waiver in code.

### 3. Rule as pure logic in Core: `Navigation/Replay/Eval/`

`AdoptionRule.evaluate(baseline:candidate:manifest:) -> EvalVerdict`, Foundation
only, no I/O:

- metres drives: candidate mean ≤ baseline mean + max(2 m, 5 % of baseline mean);
- percent drives: candidate mean ≤ baseline mean + 0.1 percentage points;
- consistency with truth σ: candidate mean ≥ baseline mean (exact on the
  ratio of counts; no float tolerance needed if computed from counts);
- every criterion passes on every seed;
- manual-3 and convergence distances: reported, not gated;
- the verdict is FAIL if a gated run or seed is missing, if the truth,
  packs or manifest hash differ from the baseline's (the bar moved), or if a
  replay read is damaged. Each FAIL row says which rule failed.

### 4. Runner: `eval_nav` (Mac-only executable target, like `replay_nav`)

```
swift run -c release --package-path Core eval_nav \
  [--manifest logs/eval/acceptance.json] [--baseline logs/eval/baseline.json] \
  [--out logs/eval/runs/<sha>] [--jobs N] [--quick] [--no-report-only] \
  [--write-baseline --reason "<text>"]
```

- Runs the matrix through the **same code path as `replay_nav`** (move the
  per-log run out of `replay_nav/main.swift` into the library first if needed,
  as a no-behaviour-change commit proven bit-identical). No shelling out.
- `--jobs` runs replays in parallel (default: cores / 2). Results are
  deterministic per seed, so parallelism changes only timing fields, which are
  never gated.
- `--quick`: seed 1, gated runs only; prints the table with "QUICK, not a
  verdict" and exits 0 or 1 on the criteria only. For the inner loop.
- Output: `report.md` (per-drive table in the "N3.2 decision" layout: gated
  mean (range), Δ vs baseline (allowed), consistency baseline → now, verdict),
  `verdict.json`, and the per-run `metrics.json`/GeoJSON as `replay_nav` writes
  them.
- Exit status: 0 PASS, 1 FAIL, 2 usage or setup error (missing file, bad
  manifest), 3 a damaged recording read.

### 5. Proof it measures what it claims

- Unit tests (Swift Testing, synthetic numbers): each allowance at, just under
  and just over its edge (2 m vs 5 % crossover at 40 m); a missing seed; a
  missing run; hash mismatch; manual-3 never gates; report-only never gates;
  percent vs metres not mixed up; consistency from counts.
- Manifest/baseline decode tests with a synthetic fixture; a newer baseline
  schema version is refused, like a newer log header.
- On real data, once: (a) `eval_nav` on current `main` against a baseline
  written from current `main` → PASS with Δ 0 everywhere; (b) its per-seed
  numbers equal hand-run `replay_nav` for two drives (one metres, one percent),
  seed 1 and 3; (c) the numbers reproduce the current tables in NAVIGATION.md
  ("N3.2 decision", drive-9 rows), or every difference is explained;
  (d) a deliberately worse config (`--set` passed through, e.g. far fewer
  particles) → FAIL on the expected drives. Report all four in the review run.

### 6. Wiring

- `docs/NAVIGATION.md` "Adoption rule": add "executable form: `eval_nav`";
  the prose stays as the rationale. Disagreement between them is a bug.
- `.claude/agents/navigation-engineer.md` and the `review-loop` skill /
  `reviewer.md`: an engine or default change attaches the `eval_nav` verdict
  (full, not `--quick`) to the review run; a FAIL blocks the merge unless the
  user accepts it and re-baselines.
- `logs/ACCEPTANCE.md` points at the manifest as the source for runs.
- CLAUDE.md "Commands": one line for `eval_nav`.

## Steps (one commit each, on branch `eval-nav`)

1. Library extraction of the replay run, bit-identical (if needed).
2. Eval types + `AdoptionRule` + tests.
3. `eval_nav` target, manifest and baseline I/O, report.
4. Private manifest written from ACCEPTANCE.md; baseline written from `main`
   (after the user approves, with `--reason "initial baseline, main <sha>"`).
5. The real-data proofs (5 a–d).
6. Docs and agent/skill wiring. `/review-loop`, merge.

## Stop and ask

- If the matrix the docs describe is ambiguous (which runs gate with roads,
  which without; as-live leg in or out), list the reading before coding.
- If 5(c) does not reproduce the tables: report, do not "fix" the baseline.
