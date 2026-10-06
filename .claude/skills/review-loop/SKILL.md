---
name: review-loop
description: Run a review-fix loop on a commit range - fresh reviewer subagent each round, verify findings, fix confirmed ones with the owning agent plus regression tests, commit per round, ledger in docs/REVIEW_LOG.md. Takes the commit range as its argument, e.g. /review-loop HEAD~1..HEAD or /review-loop e712d29.
argument-hint: <commit range, e.g. HEAD~1..HEAD or e712d29>
---

# Review-fix loop

Range: **$ARGUMENTS**

If no range was given, stop and ask for one. Don't guess.

Run a review-fix loop on the range above. Keep a ledger in `docs/REVIEW_LOG.md`.

Each round (max 4 rounds):

1. Spawn a FRESH `reviewer` subagent (never reuse the previous one). Give it the range, the ledger, and this instruction: tag every finding BLOCKER / MAJOR / MINOR; do not re-raise anything the ledger marks REJECTED or DEFERRED unless you have new evidence.
2. For each BLOCKER/MAJOR finding, verify it yourself against the code before acting: mark it CONFIRMED or REJECTED (with a one-line reason) in the ledger. Do not fix unconfirmed findings.
3. Fix CONFIRMED findings with the owning agent (`elm-ble-engineer` for ELM327/OBD/BLE, `sensors-logging-engineer` for clock/log/sensors, `ios-ui-engineer` for UI). Every real bug gets a regression test that fails before the fix and passes after.
4. Run `cd Core && swift test`, and the simulator build if `App/` changed (see the `ios-build-test` skill for commands and the `DEVELOPER_DIR` note). Both must be green. Commit the round as "review round N: <summary>".
5. Append MINOR findings to `docs/BACKLOG.md` as DEFERRED; do not fix them in the loop.

Stop when a fresh reviewer reports no BLOCKER or MAJOR findings, then print: rounds run, findings fixed/rejected/deferred, final test results.

If round 4 still has BLOCKER/MAJOR findings, or the same finding comes back twice after a fix, stop and ask me instead of continuing.

Never push. Never edit the frozen fixtures in `LogFormatCompatibilityTests` (the v1 and v2 recordings) to make a test pass.
