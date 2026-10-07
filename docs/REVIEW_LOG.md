# Review log

Ledger for `/review-loop` runs (`.claude/skills/review-loop/SKILL.md`).
Statuses: CONFIRMED (verified against code, fixed in the round named),
REJECTED (verified not to hold — reason given), DEFERRED (MINOR, moved to
`docs/BACKLOG.md`). Reviewers must not re-raise REJECTED or DEFERRED items
without new evidence.

## Run 1 — range `HEAD~1..HEAD` (80e0161..7acfa9a), started 2026-10-06

Commit under review: 7acfa9a "Fix second contract review: guard hardening,
write-failure contract, docs".

### Round 1

Reviewer: fresh `reviewer` agent. Result: 0 BLOCKER / 2 MAJOR / 8 MINOR.
Tests at review time: `swift test` 91/91 green, simulator build-for-testing
green, frozen fixtures byte-identical to e712d29.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R1-1 | MAJOR | `LogFileWriter` contract never says what `.lowDiskSpace` does to writing; a natural reading makes `flush()`/`finish()` refuse to write at the threshold, losing the last flush and the error row with ~200 MB free. Re-reporting rule undefined (payload changes every flush); `init` behaviour undefined. | CONFIRMED | Verified `LogFile.swift:70-73,130-131`: no "advisory" rule, `flush()` is `throws(LogWriteError)` and `.lowDiskSpace` is a `LogWriteError`. |
| R1-2 | MAJOR | "Truncate back to the start offset, then retry" with a raw `O_EXCL` fd says nothing about the file position; `ftruncate` doesn't move it, so the retry leaves a zero gap and readers lose everything after. Failure of `ftruncate` itself unspecified. | CONFIRMED | Verified `LogFile.swift:115-123`: no `O_APPEND`/`lseek` requirement. POSIX `ftruncate` leaves the offset unchanged. |
| R1-3 | MINOR | `RepositoryInvariantTests` uses a plain `writeValue(` substring; bypassable (space before paren, method reference, L2CAP), exempts any `BLETransport.swift` by name. | DEFERRED | BACKLOG |
| R1-4 | MINOR | `validate(_:scope:)` defaults to permissive `.session`; `ValidatedELMCommand` doesn't carry scope; `OBDLinkServicing.sendManual` doc doesn't say `.manual`. | DEFERRED | BACKLOG |
| R1-5 | MINOR | `PollingPlan.primaryCommand` returns `String`, so validating it via the policy reopens the `010D10` hole. | DEFERRED | BACKLOG |
| R1-6 | MINOR | `ATST` is allowlisted but no `ELM327Command` case can send it and the console refuses it; "below 0x19 every poll is NO DATA" overstated (J1979 P2 = 50 ms). | DEFERRED | BACKLOG |
| R1-7 | MINOR | `ELMExchange.tx` doc stale ("as written"); LOG_FORMAT `elm` `t` column omits `rejected`. | DEFERRED | BACKLOG |
| R1-8 | MINOR | Session-originated rejection (plan fails `validated()`) unspecified; could loop retry→reinit→reconnect without a row. | DEFERRED | BACKLOG |
| R1-9 | MINOR | `finish()` idempotency, single failure reporting (`flush()` throw vs `failures`), sources not stopped before `finish()` so post-finish drops aren't shown. | DEFERRED | BACKLOG |
| R1-10 | MINOR | `docs/SPEC_V1.md:76` and `WORKFLOW.md:52` still describe the console as "AT commands and mode 01". | DEFERRED | BACKLOG |

Fix: R1-1 and R1-2 by `sensors-logging-engineer` (owns log/writer).

- R1-1 → `LowDiskSpaceMonitor` (implemented: report once per crossing,
  50 MB hysteresis), injectable `DiskSpaceProvider` /
  `VolumeDiskSpaceProvider`, contract text: `.lowDiskSpace` is advisory,
  never thrown by `init`/`flush()`, `finish()` always writes, `init` below
  threshold still starts. Regression tests: `LowDiskSpaceMonitorTests` (8),
  `VolumeDiskSpaceProviderTests` (2). These cover a new type, so "fails
  before" is a compile failure, not a behavioural one; the writer itself is
  still an M1 stub, and the contract lists the M1 tests it must pass.
- R1-2 → contract: open with `O_APPEND` (one rule, no `lseek`), truncate to
  the member's start offset on failure, stop writing for good if `ftruncate`
  fails. Internal `LogFileHandle` seam + `POSIXLogFileHandle` stub for fault
  injection. Behavioural tests are specified for M1 (short write / ENOSPC
  retry → `gzip -t` passes, no zero gap; truncate failure → nothing
  appended after a partial member).

Verification: `swift test` 101/101 green (16 suites); simulator build 0
errors/warnings; Core imports Foundation only; frozen fixtures untouched.
Committed as "review round 1: writer low-disk and file-position contract".

### Round 2

Range `80e0161..HEAD` (7acfa9a + c26f293). Reviewer: fresh `reviewer` agent.
Result: 0 BLOCKER / 2 MAJOR / 6 MINOR. R1-2 fix verified sound (O_APPEND +
ftruncate probed empirically). Tests at review time: 101/101 green, simulator
build-for-testing green, fixtures byte-identical.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R2-1 | MAJOR | `VolumeDiskSpaceProvider` reads resource values on the caller's `URL`; Foundation caches them until a run-loop turn, which never happens on the writer actor, so every per-flush reading after `init` returns the start-of-drive value and `.lowDiskSpace` never fires. | CONFIRMED | `DiskSpace.swift:30-36` uses the passed `url` directly. Caching is documented Foundation behaviour; reviewer reproduced it (2 GiB written, same-instance reading unchanged). New bug introduced by the R1-1 fix, not a recurrence. |
| R2-2 | MAJOR | Nothing defines what `RecordingSession` does on `.lowDiskSpace`: `LogFile.swift:167` says "RecordingSession decides", `:174` and PLAN:448 say it finishes on "any failure", `failures` is documented as "Write failures". Either the drive ends at 200 MB free as `failed`, or it records until ENOSPC. | CONFIRMED | Contradiction verified in `LogFile.swift:167,174,200` and `docs/PLAN.md:448`. Remaining half of R1-1 (consumer side). Product decision — asked the user. |
| R2-3 | MINOR | `LogFileHandleError` maps ENOSPC → `.diskFull` for any operation, conflicting with "ftruncate failure is always `.writeFailed`". | DEFERRED | BACKLOG |
| R2-4 | MINOR | fsync timing/failure, `endOffset()` failure and `bytesWritten` after a truncate failure unspecified. | DEFERRED | BACKLOG |
| R2-5 | MINOR | `POSIXLogFileHandle`'s own short-write / EINTR loop is never exercised by the listed tests. | DEFERRED | BACKLOG |
| R2-6 | MINOR | `handle: sending` stops a test from driving the injector after hand-over; contract should say faults are scheduled up front or via a lock-guarded plan. | DEFERRED | BACKLOG |
| R2-7 | MINOR | If the header write in `init` fails, the exclusively created file is left behind. | DEFERRED | BACKLOG |
| R2-8 | MINOR | `volumeAvailableCapacityForImportantUsage` includes purgeable space; ENOSPC may arrive while the reading is far above the floor. | DEFERRED | BACKLOG |

Fix: R2-1 and R2-2 by `sensors-logging-engineer`.

- R2-1 → `VolumeDiskSpaceProvider` builds a fresh URL and clears cached
  resource values on every reading. Regression test
  `VolumeDiskSpaceProviderFreshnessTests.secondReadingIsNotCached` (same URL
  instance, 512 MiB written and synced, read from an actor): **failed on the
  old code** ("dropped 0 bytes after writing 536870912"), passes after.
- R2-2 → user chose "warn, then stop at a floor". Advisory signals split from
  failures: `DiskSpaceNotice` (`.low` / `.critical`) on
  `LogFileWriter.diskSpaceNotices`; `LogWriteError.lowDiskSpace` removed.
  Pure `DiskSpacePolicy` (two edge-triggered monitors, 200 MB warning /
  50 MB floor, `canStart`). `RecordingSession` contract: warn row + UI flag
  at `.low`, `lowDiskSpace` row then `stop(reason: .lowDiskSpace)` at
  `.critical` (normal stop, not `failed`), start refused below 200 MB,
  `failed` only for real write failures. New lifecycle value
  `lowDiskSpace` pinned in the v2 vocabulary test (added assertion; fixture
  strings unchanged) and current-state count 13. Regression tests:
  `DiskSpacePolicyTests` (new type — "before" is a compile failure).

Verification: `swift test` 115/115 green (18 suites); simulator build 0
errors/warnings; fixtures byte-identical to e712d29; Core imports Foundation
only. Not included: `App/Resources/Info.plist`, `project.pbxproj` and the
shared scheme were rewritten by the open Xcode.app during build runs
(plist comments stripped, scheme version 1.7→1.3); left uncommitted for the
user to decide. Committed as "review round 2: fresh disk-space readings,
warn-then-stop low-disk policy".

### Round 3

Range `80e0161..HEAD` (7acfa9a + c26f293 + 4ce952f). Reviewer: fresh
`reviewer` agent. Result: **0 BLOCKER / 0 MAJOR / 5 MINOR** (+2 noted, not
counted). R2-1 verified fixed (reviewer re-ran the test against the old
provider body: fails; HEAD: passes 6/6, no temp leftovers). R2-2 verified
fixed: one policy across code and docs, no leftover `minimumFreeBytes` /
`LogWriteError.lowDiskSpace`, boundaries tested. Simulator build of the
committed HEAD (from `git archive`, excluding Xcode's uncommitted rewrites)
green; `swift test` 115/115; fixtures byte-identical at e712d29, 21547c7,
80e0161 and HEAD.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R3-1 | MINOR | Floor row vs `stop` row ordering stated three incompatible ways ("immediately before", "immediately followed by", `.critical` while `stopping` writes its row). | DEFERRED | BACKLOG |
| R3-2 | MINOR | End of `failures`/`diskSpaceNotices` streams and interleaving with stop paths unspecified (stale writer notices, `.critical` during calibration, rule 4 while stopping). | DEFERRED | BACKLOG |
| R3-3 | MINOR | LOG_FORMAT "no `stop` row on a write failure" not guaranteed; rule 4 can't write an error row after `finish()`; PLAN says "rule-2 stop" vs "any stop". | DEFERRED | BACKLOG |
| R3-4 | MINOR | `RecordingStopReason` raw values and `warning:`/`floor:` detail prefixes are on-disk strings pinned by no test. | DEFERRED | BACKLOG |
| R3-5 | MINOR | `startBlocker` reads disk space synchronously on the main actor and isn't observable (Start may stay disabled after deletions). | DEFERRED | BACKLOG |
| R3-6 | MINOR (noted) | PLAN.md §4.6: `LogStore` paragraph merged into list item 4. | DEFERRED | BACKLOG |
| R3-7 | MINOR (noted) | Freshness test writes 512 MiB per `swift test`; fails unclearly below ~0.6 GB free. | DEFERRED | BACKLOG |

**Loop stopped: no BLOCKER or MAJOR findings.**

### Run 1 summary

- Rounds run: 3.
- Findings fixed: 4 (R1-1, R1-2, R2-1, R2-2), all MAJOR, all confirmed
  before fixing. Rejected: 0. Deferred: 21 MINOR (R1-3…R1-10, R2-3…R2-8,
  R3-1…R3-7) in `docs/BACKLOG.md`.
- No finding came back after its fix. R2-1 was a new bug introduced by the
  R1-1 fix; R2-2 was the unspecified consumer side of R1-1.
- Commits: c26f293 (round 1), 4ce952f (round 2), plus this ledger update.
- Final tests: `cd Core && swift test` 115 tests in 18 suites, all pass;
  simulator build 0 errors / 0 warnings.
- Outside the loop: `App/Resources/Info.plist`, `project.pbxproj` and the
  shared scheme carry uncommitted rewrites by the open Xcode.app; left for
  the user.

## M1 reviews (2026-10-07) — not a `/review-loop` run

Per WORKFLOW M1: each branch reviewed by `reviewer`, CONFIRMED findings fixed
by the owning agent with regression tests, then merged.

**Log/recording branch** (`worktree-agent-a496ab3915a06dc51`). One review:
0 BLOCKER / 0 MAJOR / 6 MINOR. Fixed before merge: duplicate failure reports
after a partial success (2800040), damaged header member making the drive
unreadable (8aecda4), two tests that didn't check their claim (e45316d).
Deferred: M1-L1, M1-L2; LOG_FORMAT member layout applied at merge.

**ELM327 branch** (`worktree-agent-a6745a3904557f4bf`). Four reviews.
- Review 1 (cad8c53): 1 BLOCKER (late reply after a timeout taken as the
  next command's answer, persistent off-by-one), 1 MAJOR (one NO DATA drops
  speed for the drive), 10 MINOR. User decided the NO DATA rule (answered-OK
  PIDs never dropped). Fixed in ce10d81 / 945ac22.
- Review 2 (945ac22): 2 MAJOR — the same two findings on paths the fix
  missed (probe NO DATA; prompt after a write-off). Fixed in 572bbb4 with an
  ATRV resync.
- Review 3 (572bbb4): 1 MAJOR — the write-off finding a third time (a stale
  ATRV voltage satisfied the sync). Escalated to the user, who chose: any
  write-off → ATZ re-init, no sync. Fixed in f68f9ff.
- Review 4 (f68f9ff): 0 BLOCKER / 0 MAJOR / 6 MINOR, ready to merge. No reply
  can be attributed to the wrong command. Deferred: M1-E4, M1-E5, M1-E6
  (stale comment fixed at merge).

**Merge** (fcae007, 1498d52, plus the integration commit): `stats.timeouts`
counts only `timeout` rows without `rx` (late/unsolicited rows excluded);
`PollingRecord.command` is `plan.primaryCommand.wireFormat` (empty plan →
`""`); both pinned in `M1IntegrationTests`, the timeout test verified to fail
without the fix.

## Run 2 — range `HEAD~1..HEAD` (189387e..5644625), started 2026-10-07

Commit under review: 5644625 "Bench test: ATSH7E0 physical addressing,
ordered poll selection, fixtures".

### Round 1

Reviewer: fresh `reviewer` agent. Result: 0 BLOCKER / 1 MAJOR / 5 MINOR.
Tests at review time: 441/441 ×3, simulator build-for-testing green,
fixtures byte-identical, five mutations of the new rules all caught. The
`polling.requestHeader` no-bump rationale was assessed as sound.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R2.1-1 | MAJOR | `ATSH7E0` is sent whatever protocol was detected and never abandoned: if no candidate parses physically, PIDs are dropped (never answered OK) and `fallbackPlan` keeps `requestHeader = 7E0`, so the drive records no OBD data; before this commit the same car polled functionally. Also, on non-11-bit-CAN protocols a 3-digit `ATSH` is not an OBD request ID, so the policy's "no non-OBD module" claim holds only on 11-bit CAN. | CONFIRMED | Verified: `ELM327Command.handshake` ends with `.setHeader(.engine)` unconditionally; `fallbackPlan` (`ELMSession.swift:697-702`) sets `requestHeader = planHeader`. |
| R2.1-2 | MINOR | Suffix guard checked before late prompts settle; a late `ATSH7DF` OK can let one `010D0C1` go out functionally (readings tagged 7E9, no misattribution). | DEFERRED | BACKLOG |
| R2.1-3 | MINOR | Docs disagree on the nothing-parses fallback's addressing. | DEFERRED | Resolved by the R2.1-1 fix if it makes the fallback functional; else BACKLOG. |
| R2.1-4 | MINOR | CSV export drops `requestHeader`. | DEFERRED | BACKLOG |
| R2.1-5 | MINOR | Skill says ATSH7E0 "must answer OK" (it's only a note); README's reserved-settings list omits addressing. | DEFERRED | BACKLOG |
| R2.1-6 | MINOR | `benchCar` mock answers `ATDPN` `6` after the app's own `ATSP0`; a real ELM reports `A6`. | DEFERRED | Needed by the R2.1-1 test (protocol gate must accept `A6`); handled there. |

Fix: R2.1-1 by `elm-ble-engineer`.

- R2.1-1 → `ATSH7E0` moved out of the unconditional handshake
  (`ELM327Command.physicalAddressing`) and sent only when `ATDPN` is
  6/A6/8/A8 and `0100` had a 7E8 line, otherwise skipped with a note. If
  nothing parses at 7E0 (or only without speed), `ATSH7DF` and a functional
  re-selection (`010D0C` → `010D`, no suffix). The nothing-parses and
  `probe: false` fallbacks are functional. The poll loop never sends a
  physical header while the gate is closed. `benchCar` answers `ATDPN` `A6`
  (R2.1-6). Regression tests: `ELMSessionAddressingGateTests`, 7 of 8 failed
  on 5644625 (the 8th asserts the bench outcome is unchanged); 3 of 4
  mutations caught (the 4th, gate left open across ATZ, is unobservable).
- Docs aligned: LOG_FORMAT, README, skill (incl. the "must answer OK"
  wording, part of R2.1-5); R2.1-3 resolved by the functional fallback.

Verification: `swift test` 453/453 (67 suites) ×2; simulator build 0
errors/warnings; compat tests untouched; Core imports Foundation only.
Committed as "review round 1: gate ATSH7E0 on 11-bit CAN, functional
fallback".

### Round 2

Range `189387e..HEAD` (5644625 + 2a7ac61). Reviewer: fresh `reviewer`
agent. Result: **0 BLOCKER / 0 MAJOR / 4 MINOR**. R2.1-1 verified fixed on
init, probe, fallback, re-init, repeated `initialise()`, stale physical
plans, late OK and the NO DATA rule; bench car unchanged (`ATSH7E0` →
`010D0C1` at 7E0 with `A6` and `6`). 453/453 ×3, simulator build green,
fixtures byte-identical, three mutations of the fix caught.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R2.2-1 | MINOR | After a re-init closes the gate (or `startPolling` with a physical plan on a closed gate), an `adapter` row announces the physical plan before the loop downgrades it; no poll goes out in between. | DEFERRED | BACKLOG |
| R2.2-2 | MINOR | Losing physical addressing is one-way for the rest of polling: a later re-init that reopens the gate sends `ATSH7E0`, then the loop sends `ATSH7DF`. No data lost; slower poll until the next `initialise()`. | DEFERRED | BACKLOG |
| R2.2-3 | MINOR | The new `ATSH7DF` step has no fallback: one timeout → baseline for the drive (B1-1 class); an adapter refusing `ATSH7DF` but accepting `ATSH7E0` would loop until `needsReconnect`. | DEFERRED | BACKLOG |
| R2.2-4 | MINOR | `docs/SPEC_V1.md:30,32` and `docs/PLAN.md:20-21` still describe `ATSH7E0` as unconditional, with no functional re-selection. | DEFERRED | BACKLOG |

**Loop stopped: no BLOCKER or MAJOR findings.**

### Run 2 summary

- Rounds run: 2.
- Findings fixed: 1 (R2.1-1, MAJOR, confirmed before fixing). Rejected: 0.
  Deferred: 9 MINOR (R2.1-2, R2.1-4, R2.1-5 in BACKLOG; R2.1-3 and R2.1-6
  resolved by the R2.1-1 fix; R2.2-1…R2.2-4 in BACKLOG).
- No finding came back after its fix.
- Commits: 5644625 (change under review), 2a7ac61 (round 1), plus this
  ledger update.
- Final tests: `cd Core && swift test` 453 tests in 67 suites, all pass;
  simulator build 0 errors / 0 warnings.

## Run 3 — range `803db28..0c7eda5` (M2 part 1), started 2026-10-07

### Round 1

Reviewer: fresh `reviewer` agent. Result: **0 BLOCKER / 2 MAJOR / 5 MINOR**.
Core 468/468, app tests 39/39, single `writeValue` site and `seq` continuity
across reconnects verified.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R3.1-1 | MAJOR | `initialiseAndPoll` treats every `.transport` error as link loss; a `.writeFailed` during the handshake (e.g. `canSendWriteWithoutResponse` stalled 1 s) leaves BLE connected, the session failed and no reconnect scheduled — no OBD for the drive. | CONFIRMED | `OBDLinkService.swift:380-383`: `case .transport, .cancelled: return` with no `.disconnected` ever coming. Fixed in round 1: only `.cancelled`, `.transport(.disconnected)` and `.transport(.notConnected)` stay silent; every other error, `.writeFailed` included, goes to `requestReconnect`. Test `OBDLinkServiceTests/initWriteFailureReconnects` (fails before the fix: 5 issues, no reconnect). |
| R3.1-2 | MAJOR | After Bluetooth goes `resetting`/`unknown`/`unauthorized`, `known` keeps invalidated `CBPeripheral`s and `connectNow` prefers them over `retrievePeripherals`; the never-timing-out connect can hang for the drive. | CONFIRMED | `BLECentral.swift` unavailable branch clears discovery/awaitingDisconnect/deferredConnect but not `known`; `connectNow` uses `known[id] ?? retrieve…`. Hardware confirmation added to PLAN §6. Fixed in round 1: `known` cleared (delegates nil'd) for every state but `poweredOn`/`poweredOff`, decided by `BLECentral.invalidatesPeripherals`. Test `BLECentralTests/invalidatingStates` (the decision only; the reset itself needs hardware, PLAN §6). |
| R3.1-3 | MINOR | The disconnect BLECentral itself requested is emitted as `.disconnected`; landing after the backoff it causes a spurious extra reconnect cycle. | DEFERRED | BACKLOG |
| R3.1-4 | MINOR | `reinitialise()` during the first initialisation joins the run, both callers `startPolling`, the second throws `.notInitialised` → full reconnect of a healthy link. | DEFERRED | BACKLOG |
| R3.1-5 | MINOR | Backoff `attempt` resets on init success, so init-OK-but-polls-fail cycles reconnect every ~1 s + re-init budget indefinitely. | DEFERRED | BACKLOG |
| R3.1-6 | MINOR | Acknowledged-write errors reach the console only, not the recording. | DEFERRED | BACKLOG |
| R3.1-7 | MINOR | GATT discovery has no watchdog; a missing discovery/notify callback leaves the link in `discovering` forever. | DEFERRED | BACKLOG |

### Round 2

Range `803db28..38db605` (part 1 + round-1 fix). Reviewer: fresh `reviewer`
agent. Result: **0 BLOCKER / 0 MAJOR / 2 MINOR**. R3.1-1 verified complete
(every transport-closing path traced; `.disconnected`/`.notConnected` always
come with a BLE `.disconnected` event, every other error reconnects); R3.1-2
verified correct and compatible with state restoration (`willRestoreState`
precedes the first `didUpdateState`). Core 468/468, app tests 41/41.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R3.2-1 | MINOR | A `withoutResponse` write that stalls past the 1 s readiness limit is first logged as a `timeout` (the session timer starts before `send`, same 1 s) and leaves an owed prompt, so the retry writes it off and forces an `ATZ` re-init; the row claims a command was sent that never was. | DEFERRED | BACKLOG |
| R3.2-2 | MINOR | On `poweredOn` both `BLECentral` (its own `target`) and the service connect; `connectNow` restarts discovery on an already-connected peripheral, and one interleaving can drop the notify callback and leave the link `discovering` (with R3.1-7). | DEFERRED | BACKLOG |

**Loop stopped: no BLOCKER or MAJOR findings.**

### Run 3 summary

- Rounds run: 2.
- Findings fixed: 2 (R3.1-1, R3.1-2, MAJOR, confirmed before fixing).
  Rejected: 0. Deferred: 7 MINOR (R3.1-3…R3.1-7, R3.2-1, R3.2-2 in BACKLOG).
- No finding came back after its fix.
- Commits: 0b6da00 + 0c7eda5 (change under review), 38db605 (round 1), plus
  this ledger update.
- Final tests: `cd Core && swift test` 468 tests in 71 suites, all pass;
  simulator build 0 errors / 0 warnings; app tests 41 in 8 suites, all pass
  on iPhone 15 Pro simulator.
