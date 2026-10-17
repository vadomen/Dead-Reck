---
name: review-loop
description: Run a review-fix loop on a commit range - fresh reviewer subagent each round, verify findings, fix confirmed ones with the owning agent plus regression tests, commit per round, ledger in docs/REVIEW_LOG.md. Takes the commit range as its argument, e.g. /review-loop HEAD~1..HEAD or /review-loop e712d29.
argument-hint: <commit range, e.g. HEAD~1..HEAD or e712d29>
---

# Review-fix loop

Range: **$ARGUMENTS**

If no range was given, stop and ask for one. Don't guess.

Run a review-fix loop on the range above. Keep a ledger in `docs/REVIEW_LOG.md` (current runs). Older runs (1–34, indexed at the top of the ledger) and closed backlog rows are in `docs/archive/`: read them only on demand (e.g. a finding cites an old ID), never pass them whole.

## Lite path (no code in the range)

Run `git diff --stat <range>` first. If it touches nothing under `Core/`, `App/`, `AppTests/`, `project.yml`, `DriveLogger.xcodeproj`, `Config/`, `.claude/hooks/`, `.claude/settings.json`, `scripts/`, `tools/`, `site/functions/` or `site/*.sh` (so: docs, `.claude` agent/skill text, assets, `site/` copy only), run the lite path instead of the rounds below:

- ONE fresh `reviewer` on `sonnet`, told "lite run": checks 10 and 11 only, no mutations. Pass it the range and the backlog IDs as in step 1. Run no tests and pass none.
- No round 2 unless it finds a BLOCKER or MAJOR. Then verify, fix and re-review as in steps 2–4 (a fix that stays outside the paths above stays lite).
- MINORs that are one-line wording fixes go to `docs-editor`. They are fixed in the run's ledger commit, not deferred and not re-reviewed. Other MINORs are deferred as in step 5.
- Ledger it as a normal run with "lite" in its title, e.g. `## Run N (lite): <subject> (<range>), started <date>`.

## Rounds

Each round (max 4 rounds):

1. Spawn a FRESH `reviewer` subagent (never reuse the previous one).
   - **Pass it:**
     - the range;
     - this range's rows from `docs/REVIEW_LOG.md`, nothing else from it;
     - the DEFERRED/REJECTED IDs from `docs/BACKLOG.md` whose text names a file in the diff, with their one-line findings. Never pass either file whole;
     - the current HEAD's `cd Core && swift test` result (totals and any failures), and the simulator/app results if `App/` changed. Run them yourself first;
     - the author's mutation list (`mutation -> test that failed`) from the engineer's summary, verbatim. The reviewer re-checks one and spends its own budget only on logic the list does not cover. If an engineer changed Core logic and gave no list, send the engineer back for it before the review;
     - for navigation changes, a pointer to `logs/ACCEPTANCE.md` (git-ignored: drive paths, seed, truth file, packs, procedure) for its "bit-identical" re-run. If the file is missing or a drive moved, fix the file first.
   - **Instruction:** tag every finding BLOCKER / MAJOR / MINOR; do not re-raise anything marked REJECTED or DEFERRED unless you have new evidence.
   - **Model:** use `sonnet` for docs/config-only ranges, or under 200 changed lines with no new logic. Use `opus` for anything touching Core or App logic.
   - **Scale:** for a range over ~1500 changed lines, spawn 2–3 fresh reviewers in parallel on disjoint file sets you name (e.g. engine / replay / app), each told its set. Merge their findings into one ledger round.
   - **Mutation worktree:** `../dead-reck-mutants` is shared by reviewers and authors. Never run two agents that mutate (a reviewer with check 13, an engineer finishing Core or view-model logic) at the same time; parallel batches queue their review.
   - **Resume:** if a reviewer stops early (API limit, network), spawn a fresh one for the same round. It resumes from `.claude/review-scratch/<range>.md`. A cut-off attempt is not counted as a round.
2. For each BLOCKER/MAJOR finding, verify it yourself against the code before acting: mark it CONFIRMED or REJECTED (with a one-line reason) in the ledger. Do not fix unconfirmed findings.
3. Fix CONFIRMED findings with the owning agent:
   - `elm-ble-engineer` for ELM327/OBD/BLE;
   - `sensors-logging-engineer` for clock/log/sensors;
   - `ios-ui-engineer` for UI views;
   - `navigation-engineer` for Core/Navigation, Replay, replay_nav and road packs (Roads/, RoadPackBuild, build_roads, tools/roads), and the app side: `App/Sources/Navigation/` (NavigationService, RoadPackLibrary) and the Diagnostics road rows (`RoadsDiagnostics.swift`).
   - `docs-editor` for docs-only fixes (wording in `docs/*.md` or `WORKFLOW.md`), whatever area the finding is about. It has no shell, so you run tests and commit.

   Every real bug gets a regression test that fails before the fix and passes after. When the range is on a branch outside the main tree, the fixer works in that branch's worktree, `.claude/worktrees/<task>` (WORKFLOW.md "One engineer agent at a time").
4. Run `cd Core && swift test`, and the simulator build if `App/` changed (see the `ios-build-test` skill for commands and the `DEVELOPER_DIR` note). If `Core/Sources/DriveLoggerCore/Navigation/` (incl. `Replay/`, `Roads/`) changed, also run `cd Core && swift test -c release --filter 'NavigationRoadPerfTests|NavigationB0Tests'` (their timing asserts run only in release) and report it. All must be green. Commit the round as "review round N: <summary>". Once the round is in the ledger, delete its scratch file(s) in `.claude/review-scratch/`.
5. Append MINOR findings to `docs/BACKLOG.md` as DEFERRED; do not fix them in the loop (lite runs: see "Lite path"). A backlog row the range closes moves, unchanged apart from its status, to `docs/archive/BACKLOG-closed.md`. Ledger and backlog row edits go to `docs-editor` when you delegate them.

Stop when a fresh reviewer reports no BLOCKER or MAJOR findings, then print: rounds run, findings fixed/rejected/deferred, final test results.

If round 4 still has BLOCKER/MAJOR findings, or the same finding comes back twice after a fix, stop and ask me instead of continuing.

Never push. Never edit the frozen fixtures in `LogFormatCompatibilityTests` (the v1 and v2 recordings) to make a test pass.
