

## Run 56: R53.1-2, vetoed steps keep the OBD-0 course veto (7fc5f3f..6f20b7a, branch sweep-zupt), started 2026-10-18

Commits: 6f20b7a `NavigationEngine.step`: a `zuptFixGate`-vetoed step's history records OBD's held value (0), not the Doppler speed it moved at, so course updates and reseeds stay vetoed (user decision: gate stays on; a freshness-only trigger would equal gate off, since a stale 0 already never ZUPTs). Also covers a gate-vetoed stale-parked step (consistent with the gate-off engine, R11.1-4). Tests: `ferryKeepsCourseVeto` (new), `parkedIsVetoed` (stalled link, stale moving reply), `stuckZeroDoesNotFreeze` (`courseUpdates == 0`), `vetoedStepSpeed` (`held == 0`). Adoption rule: seeds 1–5, every acceptance run with and without roads, 100 GeoJSON pairs byte-identical, `zuptVetoedSteps` 0: PASS, trivially. Simulator recording: course updates 88 → 0, reseeds 1 → 0.

### Round 1

Reviewer: one fresh reviewer (opus), checks 6, 8–13. `held` is read only through `heldAtFix` → `courseValid`, so only course use changes; catch-up and step-by-step history now agree on vetoed steps. Identical error figures in the stalled-link and simulator tests explained (same fixture, same path). No bound loosened. Bit-identical re-run: drive "clean", seed 1, roads, base vs head: GeoJSON identical. Mutations: author's `vetoed ? heldOBDSpeed : vObd` → `vObd` re-run (4 tests fail); `(vetoed || stale) ? 0 : vObd` → stale-moving assertion fails. Author mutations: 3, all killed. Result: 0 BLOCKER / 0 MAJOR / 0 MINOR.

Tests: `cd Core && swift test` 992 passed, 36 known issues (after merge); release `NavigationRoadPerfTests|NavigationB0Tests` 9 passed; no App change.

### Run 56 summary

1 round; 0 fixed, 0 rejected, 0 deferred; R53.1-2 closed.
