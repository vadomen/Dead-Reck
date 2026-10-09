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

## Run 4 — range `129c9d9..395aeac` (M2 part 2), started 2026-10-08

### Round 1

Reviewer: fresh `reviewer` agent. Result: **0 BLOCKER / 0 MAJOR / 8 MINOR**.
Verified: one `SessionClock` per recording, CoreMotion stamped via
`timestamp(uptimeSeconds:)` and never clamped, `Date()` only in the header and
the §3.4 location pair, no row after `stop` (`SampleGate`, synchronous link
cut-off, `isWritable`/`stopRowQueued`), idempotent `finish()`, stale writers
ignored by generation, no `@unchecked Sendable`, frozen fixture untouched, no
on-disk string changed. Core 477/477, app tests 65/65.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R4.1-1 | MINOR | A write failure queued before `stop()`'s Task body runs sees `state == .recording`, calls `end()` which only awaits; `pendingFailure` is never set and a successful final `finish()` ends `idle` with a "write failed" row in the file. | DEFERRED | BACKLOG |
| R4.1-2 | MINOR | `isStarting` stays true through the 5 s calibration sleep, so Start is refused (`recordingInProgress`) after a stop or failure during calibration. | DEFERRED | BACKLOG |
| R4.1-3 | MINOR | `quiesce` stops `ReferenceLocationSource` (and its `CLBackgroundActivitySession`) before the final `stats`/`finish()`; a floor stop or failure while locked has no background task covering the tail. | DEFERRED | BACKLOG |
| R4.1-4 | MINOR | No `willTerminate` handling: swipe-away while recording in the background loses up to 2 s and leaves no row saying why the file ends. | DEFERRED | BACKLOG |
| R4.1-5 | MINOR | With location unavailable no background session exists, but nothing in the file or the session API says capture may pause while locked. | DEFERRED | BACKLOG |
| R4.1-6 | MINOR | `LogFileReadError.readFailed` is effectively unreachable: an I/O error at offset 0 surfaces as the raw Foundation error, contrary to the reader doc and LOG_FORMAT; untested. | DEFERRED | BACKLOG |
| R4.1-7 | MINOR | LOG_FORMAT says every row of a cleanly stopped recording is counted in exactly one `stats` row; the final `stats` row is counted in none. | DEFERRED | BACKLOG |
| R4.1-8 | MINOR | Writer-queue error row and its 200-event floor are undocumented and untested at App level. | DEFERRED | BACKLOG |

**Loop stopped: no BLOCKER or MAJOR findings.** The reviewer suggested fixing
R4.1-1…3 in the loop; per the review-loop rules MINORs are deferred instead.

### Run 4 summary

- Rounds run: 1.
- Findings fixed: 0. Rejected: 0. Deferred: 8 MINOR (R4.1-1…R4.1-8 in BACKLOG).
- Commits: 57d4de3 + 395aeac (change under review), plus this ledger update.
- Final tests: `cd Core && swift test` 477 tests in 75 suites, all pass;
  simulator build green, no Swift warnings; app tests 65 in 11 suites, all
  pass.

## Run 5 — range `641cdbd..c6a6368` (M3: prep fixes + UI), started 2026-10-08

### Round 1

Reviewer: fresh `reviewer` agent. Result: **0 BLOCKER / 1 MAJOR / 7 MINOR**.
Verified clean: console reaches the adapter only via `sendManual` (`.manual`),
no UI `linkEvents()` or log-data `Date()`, simulated GPS tap display-only,
R4.1-1 / R4.1-2 / R3.1-4 fixes correct, no double start, live file not
deletable, `failed` and blockers surfaced. Core 478/478, app tests 103/103.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R5.1-1 | MAJOR | Console Disconnect / Scan + tap another adapter are live while recording; `disconnect()` clears `target` and cancels reconnect, so one tap ends OBD for the rest of the drive. A scan left running competes with the link. | CONFIRMED | `ConsoleView.swift:88-121`, `OBDLinkService.disconnect()` sets `target = nil`. Fix: confirmation while recording, Scan disabled while connected/recording. |
| R5.1-2 | MINOR | "Record without OBD" toggle disappears once on (shown only while the blocker is `.obdNotReady`), so the choice is invisible and sticky until the next Start. | DEFERRED | BACKLOG |
| R5.1-3 | MINOR | `RecordingViewModel.isStartRequested` lasts through calibration: re-Start after a stop during calibration is silently ignored, and the late `defer` clears the new checklist. | DEFERRED | BACKLOG |
| R5.1-4 | MINOR | `writeFailureEntersFailed` flake: sources still tick until `performFail`'s Task runs, so a row can land after the "write failed" row. Test over-asserts; not data loss. | DEFERRED | BACKLOG |
| R5.1-5 | MINOR | `failureRightAfterStop` `yields == 1` case doesn't assert it reached `.stopping` first. | DEFERRED | BACKLOG |
| R5.1-6 | MINOR | Mark sheet confirms ("Marked: …" + haptic) marks the session dropped after stop/failure. | DEFERRED | BACKLOG |
| R5.1-7 | MINOR | Re-initialise enabled in `.failed` / `.reconnecting`, where `reinitialise()` is a no-op. | DEFERRED | BACKLOG |
| R5.1-8 | MINOR | Sessions list marks the live file by full URL equality; a `/private/var` vs `/var` mismatch would allow sharing a partial file (delete still refused). | DEFERRED | BACKLOG |

Fix (R5.1-1, `ios-ui-engineer`): `ConsoleViewModel` takes the session state;
while calibrating/recording/stopping, Disconnect, Forget and connecting to a
non-remembered adapter go through a destructive confirmation ("The recording
continues without OBD for the rest of the drive."); Scan only while the link
holds no adapter and nothing records; Start stops a running scan.
Re-initialise unchanged. 5 regression tests in `UIPresentationTests` ("Console
link gating"); they need the new VM init, so on the old code they fail to
compile rather than assert. Core 478/478, app tests 108/108. The R5.1-4 flake
showed once more during the fix run (passed on rerun).

### Round 2

Reviewer: fresh `reviewer` agent. Result: **0 BLOCKER / 0 MAJOR / 4 MINOR**.
R5.1-1 fix verified (dialog confirm ordering probed with a throwaway XCUITest:
the button action runs before the binding resets). Core 478/478, app tests
108/108; the R5.1-4 flake did not show.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R5.2-1 | MINOR | Connect-to-other skips the confirmation while recording when the link is `.unavailable`/`.idle` (`holdsAdapter` false); stale scan rows stay listed after connect. | DEFERRED | BACKLOG |
| R5.2-2 | MINOR | Start stops a scan only if `state == .scanning`; a scan pending while Bluetooth is off resumes mid-drive. | DEFERRED | BACKLOG |
| R5.2-3 | MINOR | Scan disabled in `.failed`, exactly where `.unusable` tells the user to pick another adapter. | DEFERRED | BACKLOG |
| R5.2-4 | MINOR | Guard tests cover only a polling link; Forget guard is view-only and untested; README Console paragraph omits the recording-time confirmation. | DEFERRED | BACKLOG |

**Loop stopped: no BLOCKER or MAJOR findings.**

### Run 5 summary

- Rounds run: 2.
- Findings fixed: 1 MAJOR (R5.1-1). Rejected: 0. Deferred: 11 MINOR (R5.1-2…8, R5.2-1…4 in BACKLOG).
- Commits: 60a37cc, 0087cdb, c6a6368 (change under review), e576601 (round 1), plus this ledger update.
- Final tests: `cd Core && swift test` 478 tests in 75 suites, all pass; simulator
  build green; app tests 108 in 19 suites, all pass (R5.1-4 is a known
  timing flake in `writeFailureEntersFailed`, seen twice under load, deferred).

## Run 6 — range `1af3a48..a7a5006` (M4 bench fixes), started 2026-10-08

### Round 1

Reviewer: fresh `reviewer` agent. Result: **0 BLOCKER / 0 MAJOR / 6 MINOR**.
Verified clean: replay dedup (reads and writes in one main-actor step, skip =
delivered − consumed, per-recording, replay once; `seq` unique and increasing
for Start while polling / mid-init / after a drop / reconnect during a
recording), replay rows on the recording's `SessionClock` unclamped, first
`stats` window from the `start` row, ATAT rule and restores, `locationAuthorization`
decodes in older readers (`event` is a String), frozen fixture untouched,
`inspect_log --strict` accepts negative-`t` replay rows. Core 488/488, app
tests 127/127.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| M6.1-1 | MINOR | Stale replay: Start after a drop replays the old connection ending at `connected`/`polling`; the drop events are skipped, so the first live row (`reconnecting → connecting`) doesn't follow. Documented in LOG_FORMAT. | DEFERRED | BACKLOG; user decision on stale replay pending |
| M6.1-2 | MINOR | `inspect_log` Duration and the 30 s no-stats check span the pre-Start replay. | DEFERRED | BACKLOG |
| M6.1-3 | MINOR | Every init now sends 23 probe polls (was 6); probe exchanges yield no `obd` rows, so each reconnect widens the `obd` gap by ~1 s. | DEFERRED | BACKLOG |
| M6.1-4 | MINOR | `ATAT2` timeout with a late `OK` plus a refused `ATAT1` restore leaves the adapter at level 2 while the plan says 1; no test for a mute `ATAT2`. | DEFERRED | BACKLOG |
| M6.1-5 | MINOR | A replay burst > ~720 rows can trip the "writer queue peaked" error row in window 1. | DEFERRED | BACKLOG |
| M6.1-6 | MINOR | Every authorisation callback while recording writes a "changed" row without comparing; a grant after a denied Start writes none. | DEFERRED | BACKLOG |

**Loop stopped: no BLOCKER or MAJOR findings.**

### Run 6 summary

- Rounds run: 1.
- Findings fixed: 0. Rejected: 0. Deferred: 6 MINOR (M6.1-1…6 in BACKLOG).
- Commits: 2437416, a7a5006 (change under review), plus this ledger update.
- Final tests: `cd Core && swift test` 488 tests in 77 suites, all pass; simulator
  build green; app tests 127 in 23 suites, all pass (R5.1-4 flake seen once by
  the fix agent, passed on rerun).

## Run 7 — range `f885836..21aada9` (M4 follow-up: replay scope, plan reuse), started 2026-10-08

### Round 1

Reviewer: fresh `reviewer` agent. Result: **0 BLOCKER / 0 MAJOR / 6 MINOR**.
Verified clean: a reused plan reaches the wire only through `validate()` and
the addressing check, so the `1` suffix can't go out under `7DF`; only
allowlisted `ATAT0–2` and mode 01 added; fallback at most once per init; ATAT
level recorded equals the adapter's after a reuse; NO DATA rule and `seq`
continuity kept; `forget()` epoch guard sound; replay reset on every exit from
`connected`, no loss or duplicate for Start at/around `connected`, empty
replay safe; free-text notes only. Core 499/499, affected app suites 23/23
(full app run by the fix agent 139/139).

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| M7.1-1 | MINOR | A degraded start-up selection (fallback command or a dropped PID) is remembered and reused on every reconnect, so a PID dropped once no longer gets a fresh chance per connection. | DEFERRED | BACKLOG |
| M7.1-2 | MINOR | A plan that passes the one-poll check but fails while polling is stored again on `needsReconnect`; selection/ATAT comparison never re-runs. | DEFERRED | BACKLOG |
| M7.1-3 | MINOR | Reuse key (peripheral id + banner) doesn't identify the vehicle; moving the adapter to another car reuses car A's ATAT level. | DEFERRED | BACKLOG |
| M7.1-4 | MINOR | After a successful reuse, a same-connection `reinitialise()` notes "from the previous connection", contradicting LOG_FORMAT ("previous initialisation"). | DEFERRED | BACKLOG |
| M7.1-5 | MINOR | Replay stops at `→ polling`, so a later `.adapter` re-announcement (PID dropped while polling) or ELM `retrying` isn't replayed; header and last replayed `adapter` row can disagree. Predates this commit. | DEFERRED | BACKLOG |
| M7.1-6 | MINOR | Untested: `ATAT<n> not accepted` reuse failure, single-PID remembered plan, late `ATSH7E0` OK before the reuse check; `forget()` epoch test relies on a fixed 200 ms sleep. | DEFERRED | BACKLOG |

**Loop stopped: no BLOCKER or MAJOR findings.**

### Run 7 summary

- Rounds run: 1.
- Findings fixed: 0. Rejected: 0. Deferred: 6 MINOR (M7.1-1…6 in BACKLOG).
- Commits: 21aada9 (change under review), plus this ledger update.
- Final tests: `cd Core && swift test` 499 tests in 78 suites, all pass;
  simulator build green; app tests 139 in 25 suites, all pass.

## Run 8 — M4.2 map camera + manual fix (1d61098..99e2b39)

### Round 1

Fresh reviewer, checks 2, 3, 5, 6, 7, 8, 9 (no adapter path in range). Clean:
v1/v2 fixtures byte-unchanged, v3 declared/current with its own fixture;
`manualFix` and `obd`/`gps`/`unknown` pinned; every row time on the
recording's `SessionClock` (`t` = gate `now`; `obdSpeedT` mapped like the `obd`
row); no per-sample `Date()`; gate re-checked at confirm, cross-recording press
refused; Map observation and render gating intact; cached location read-only;
Core Foundation-only; new logic tested. Tests at HEAD: Core 530/530, app
174/174, simulator build green.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| M8.1-1 | MINOR | Long-press `pressBegan` not reset when the gesture is cancelled; later long-presses become no-ops for the view's life. | DEFERRED | BACKLOG |
| M8.1-2 | MINOR | `pressedT` documented as press start but taken at recognition (+0.6 s). | DEFERRED | BACKLOG |
| M8.1-3 | MINOR | OBD speed/uptime carry over into a new recording; `obdSpeedT` may match no `obd` row in the file. | DEFERRED | BACKLOG |

**Loop stopped: no BLOCKER or MAJOR findings.**

### Run 8 summary

- Rounds run: 1.
- Findings fixed: 0. Rejected: 0. Deferred: 3 MINOR (M8.1-1…3 in BACKLOG).
- Commits: 99e2b39 (change under review), plus this ledger update.
- Final tests: `cd Core && swift test` 530 tests in 81 suites, all pass;
  simulator build green; app tests 174 in 30 suites, all pass.

## Run 9 — M4.3 map follow + heading-up (df91622..4afa2eb)

### Round 1

Fresh reviewer, UI-only range (Core, logging, sensors, format untouched; check 8
trivially clean). Verified: only touch gestures call `userGesture`,
`positionedByUser` gone, camera callbacks ignored while following; manual off
stays off; staged pin suspends resume, countdown starts on clear (incl. Start);
0.25 s coalescing correct; smoother short-way wrap, rate clamp and freeze
correct and tested; gate boundaries match spec; `MapFeed` still the only
`session.live` observer. Tests at HEAD: Core 530/530, app 191/191, simulator
build green.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| M9.1-1 | MINOR | Follow deadline on `systemUptime`, sleep on `ContinuousClock`, single tick: device sleep in the window can leave Following paused for good. | DEFERRED | BACKLOG |
| M9.1-2 | MINOR | Heading smoother not reset on a new recording. | DEFERRED | BACKLOG |
| M9.1-3 | MINOR | `frame()` resets to north-up on reselect/foreground; arrow then wrong until next fix. | DEFERRED | BACKLOG |
| M9.1-4 | MINOR | Freeze trusts a stale OBD 0. | DEFERRED | BACKLOG |
| M9.1-5 | MINOR | Heading-up re-renders Map content at up to 10 Hz. | DEFERRED | BACKLOG |
| M9.1-6 | MINOR | Missing tests: coalescing, `setOBDSpeed`, bearing reset. | DEFERRED | BACKLOG |

**Loop stopped: no BLOCKER or MAJOR findings.**

### Run 9 summary

- Rounds run: 1.
- Findings fixed: 0. Rejected: 0. Deferred: 6 MINOR (M9.1-1…6 in BACKLOG).
- Commits: 4afa2eb (change under review), plus this ledger update.
- Final tests: `cd Core && swift test` 530 tests in 81 suites, all pass;
  simulator build green; app tests 191 in 33 suites, all pass.

## Run 10 — M4.3 incl. M9.1 fixes (df91622..a7dbd83)

### Round 1

Fresh reviewer. M9.1-1 (resume loop on ContinuousClock, re-check on `isLive`),
M9.1-4 (fresh-zero rule, 2.0 s boundary), M9.1-5 (write gate wrap/rate, camera
settles via `recenter`), M9.1-2 verified fixed. RecordingSession accessors read
`@ObservationIgnored` storage only; `MapFeed` still the only `session.live`
observer. `TrackOverlay` isolation unprovable off-device (not a finding).

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| M10.1-1 | MAJOR | Heading-up activation (tab return, foreground, mode toggle, resume) writes the stale smoothed heading; frozen at a stop it holds the wrong heading until drive-off. | CONFIRMED → FIXED c202225 | Verified: smoother steps only while `headingActive`, `CameraHeading.choose` prefers `smoothed`. Fix: `CameraHeading.activate` reseeds smoother + resets gate at the top of `frame()`/`moveCameraToCar()`; 2 regression tests, shown failing with the reseed disabled. |
| M10.1-2 | MINOR | Bearing not fed while scene inactive. | DEFERRED | BACKLOG |
| M10.1-3 | MINOR | `mapSpanM` meaning changes in heading-up. | DEFERRED | BACKLOG |
| M10.1-4 | MINOR | `distancePerSpan` 1.87 guess, one axis only. | DEFERRED | BACKLOG; device checklist item |
| M10.1-5 | MINOR | `flipOnly` test doesn't exercise its guard. | DEFERRED | BACKLOG |
| M10.1-6 | MINOR | M9.1-1/-2 tests don't cover the actual fixes. | DEFERRED | BACKLOG |
| M10.1-7 | MINOR | WORKFLOW/PLAN docs stale (accessors, checklist). | FIXED c202225 | Cheap, in the fix's files |

Tests after fix: Core 530/530, simulator build green, app 204/204.

### Round 2

Fresh reviewer, range df91622..bf85177. M10.1-1 verified fixed: every
heading-up activation edge (tab return/foreground via `frame()` and
`resumeIfDue`, mode toggle, auto-resume, Follow tap, pin clear → resume, first
bearing after reset) reseeds before its camera write; steady-state writes
(per-fix `recenter`, 10 Hz loop) are not reseeded, so smoothing is intact.
North-up unchanged. New tests fail without the reseed and without the gate reset.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| M10.2-1 | MINOR | `frame()` heading-up branch doesn't `noteWrite`; one redundant identical camera write per activation. | DEFERRED | BACKLOG |

**Loop stopped: no BLOCKER or MAJOR findings.**

### Run 10 summary

- Rounds run: 2.
- Findings fixed: 1 MAJOR (M10.1-1) plus 1 MINOR docs fix (M10.1-7). Rejected: 0.
  Deferred: 6 MINOR (M10.1-2…6, M10.2-1 in BACKLOG).
- Commits: c202225 (fix), bf85177 (round 1 ledger), plus this ledger update.
- Final tests (at c202225; later commits are docs only): `cd Core && swift test`
  530 tests in 81 suites pass; simulator build green; app tests 204 in 35
  suites pass.

## Run 11 — N2 navigation engine + replay_nav (80fb354..43ed727), started 2026-10-09

Branch `n2-nav`. Commits under review: 182a4ba, db021fb, 3ea98c1, 43ed727.

### Round 1

Reviewer: fresh `reviewer` agent. Result: 0 BLOCKER / 3 MAJOR / 5 MINOR.
Tests at review time: `swift test --filter Navigation` 23/23 green. The reviewer
checked causality, determinism, filter maths, metrics honesty, invariants and the
performance budget without finding a code defect. All three MAJORs are coverage
gaps: the reviewer applied each mutation to a scratch copy of Core, and all
Navigation tests still passed.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R11.1-1 | MAJOR | Fix-latency shift (`shiftSince`) untested: returning a zero shift keeps all tests green (synthetic latency 0.05 s, causality fixtures 0.4 s). | CONFIRMED | Verified `NavigationTestSupport.swift:43` default latency 0.05 s; no test drives a late fix at speed or through a turn. |
| R11.1-2 | MAJOR | Tower tempering untested: `temper = 1` keeps `towerBiasNotChased` green, because each 1414 m fix barely moves the estimate. | CONFIRMED | Verified `NavigationEngineTests.swift:116-140`: 200 m bound holds with or without tempering. |
| R11.1-3 | MAJOR | Replay "score before ingest" untested; the causality tests cover only the engine (a value type), not `ReplayRun`. Scoring after ingest keeps all tests green. | CONFIRMED | Verified `NavigationReplay.swift:316-330`; the engine-only causality tests can't see the replay loop. |
| R11.1-4 | MINOR | Course gate passes when OBD is stale or absent, contrary to the docs. | DEFERRED | BACKLOG |
| R11.1-5 | MINOR | Stale fix accepted while stopped is shifted only ~10 s back. | DEFERRED | BACKLOG |
| R11.1-6 | MINOR | Clean-fix reseed double-counts that fix. | DEFERRED | BACKLOG |
| R11.1-7 | MINOR | Stale-speed random walk makes the mean drift; docs claim it doesn't. | DEFERRED | BACKLOG |
| R11.1-8 | MINOR | `replay_nav` ignores the reader's damage report. | DEFERRED | BACKLOG |

Fix: R11.1-1..3 by `navigation-engineer` (owns Navigation), as discriminating
tests shown to fail under each mutation.

Fixed in 47ac36b: six tests in `NavigationReviewTests` ("Navigation review run 11").
Each one fails under its mutation and passes on the real code; the failing output
under each mutation was captured before the mutation was reverted:
zero shift → straight line and turn cases fail; zero yaw shift only → turn case
fails; `temper = 1` → long correlated bias case fails (pulled 556 m); scoring
after ingest → rebuild-per-checkpoint and offset-pin cases fail. The only engine
change is `towerTemper(sinceLastS:correlationS:)`, extracted with no change in
behaviour; all 221 acceptance checkpoint errors are bit-identical. No engine
bug found.

Tests after fix: `cd Core && swift test` 559 tests in 86 suites pass. No App/
change, so no simulator build was needed for this round.

### Round 2

Fresh reviewer, range 80fb354..7bbbd90. R11.1-1..3 verified fixed: the reviewer
re-applied each mutation to a scratch copy of Core and the new tests failed under
every one. The `towerTemper` extraction is the same expression as before. Fresh
review of causality, determinism, filter maths, invariants and performance found
no further defect apart from the findings below. `swift test --filter Navigation`
29/29 green.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R11.2-1 | MAJOR | A fresh OBD zero (ZUPT) returns before the stale-offset reset, so `speedOffset` keeps the random walk from an earlier dropout; the next dropout starts at ~21 m/s RMS and the ellipse grows ~390 m in 10 s while parked. | CONFIRMED | Verified `NavigationEngine.swift:218-225` returns before the reset at `:230-233`; this contradicts the comment at `:56`. |
| R11.2-2 | MINOR | The latency shift is biased forward by up to one 10 Hz step of motion. | DEFERRED | BACKLOG |
| R11.2-3 | MINOR | Initialisation ignores the fix's age. | DEFERRED | BACKLOG |
| R11.2-4 | MINOR | `metrics.json` that no longer decodes is replaced silently. | DEFERRED | BACKLOG |

Fix: R11.2-1 by `navigation-engineer`, with a regression test written first.

Fixed in a30b1e4: the ZUPT branch resets speed offsets through
`resetSpeedOffsets()`, and only when they are set, so a normal stop stays
loop-free. Regression test `staleOffsetsResetOnZUPT` failed before the fix
(offset RMS 9.1 m/s through the ZUPT; variance growth ratio 13.2) and passes
after. Acceptance checkpoint errors are unchanged: the drives' only stale
periods are the final OBD loss at ignition-off, with no fresh zero after them.

Tests after fix: `cd Core && swift test` 560 tests in 86 suites pass.

### Round 3

Fresh reviewer, range 80fb354..531dc1a. R11.2-1 verified fixed: reverting only
the reset line in a scratch copy makes `staleOffsetsResetOnZUPT` fail both of its
checks. The steady-state ZUPT path stays loop-free, and the ZUPT branch still
draws no random numbers, so the results are unchanged. A fresh review of
causality, determinism, filter maths, metrics, invariants and performance found
nothing new. `swift test --filter Navigation` 30/30 green.

No findings.

**Loop stopped: no BLOCKER or MAJOR findings.**

### Run 11 summary

- Rounds run: 3.
- Findings fixed: 4 MAJOR. Three were coverage gaps closed with discriminating
  tests (R11.1-1..3, 47ac36b); one was an engine bug (R11.2-1, a30b1e4). Rejected: 0.
  Deferred: 8 MINOR (R11.1-4..8, R11.2-2..4 in BACKLOG).
- Final tests (at 531dc1a): `cd Core && swift test` 560 tests in 86 suites pass.
  No App/ change in the range; the simulator build was green at 43ed727.
- Acceptance (unchanged through the loop): clean 26 m max, PASS; manual 53 m at
  truth point 1, PASS, and convergence 6.80 km against 2 km, known FAIL; jammed-A
  1.24 %, PASS; jammed-B 1.76 %, PASS; 0.05–0.07 ms/step on the Mac.

## Run 12 — N2.1 engine update, step 0 of N4 (e15b30e..4d6b48b), started 2026-10-09

Branch `n2.1-engine`. Commits under review: 2251a3b, 4c5ae08, f011567, 4d6b48b.

### Round 1

Reviewer: fresh `reviewer` agent. Result: 0 BLOCKER / 0 MAJOR / 2 MINOR.

Verified correct:
- manual-fix σ rule: edge cases handled, and the engine and replay agree;
- network-fix rule: `!hasValidSpeed`; fixes with speed are never tempered; old keys removed and `--set` fails loudly on them;
- speed gate units;
- consistency denominators: only checkpoints the engine didn't receive;
- causality and determinism unchanged.

The new tests discriminate under mutation. `swift test --filter Navigation` 36/36 green.

| ID | Tag | Finding | Status | Note |
|---|---|---|---|---|
| R12.1-1 | MINOR | The `metrics.json` backward compatibility claimed in comment and test doesn't hold; renamed config/counter keys make pre-N2.1 files fail to decode and be replaced silently (new evidence for R11.2-4). | DEFERRED | BACKLOG |
| R12.1-2 | MINOR | Stale `towerCorrelationS` key in the NAVIGATION.md informational table. | DEFERRED | BACKLOG |

**Loop stopped: no BLOCKER or MAJOR findings.**

### Run 12 summary

- Rounds run: 1. Fixed 0, rejected 0, deferred 2 MINOR (R12.1-1, R12.1-2).
  Also recorded: N2.1-1, manual-3 ellipse overconfidence (acceptance note, BACKLOG).
- Final tests (at 4d6b48b): `cd Core && swift test` 566 tests in 86 suites pass.
  No App/ change.
- Acceptance, seeds 1–5:

  | drive | criterion | result |
  |---|---|---|
  | clean-long | ≤ 30 m | 18–20 m, 100 % inside the ellipse |
  | clean | ≤ 30 m | 12–17 m, 100 % inside |
  | manual @744.3 | ≤ 200 m | 47–57 m, 100 % inside |
  | manual convergence | ≤ 2 km | 7.27–7.68 km, known FAIL |
  | jammed-A | ≤ 2.5 % | 1.02–1.26 % |
  | jammed-B | ≤ 2.5 % | 0.81–1.11 % |
  | manual-3 | reported only | pins 416 / 640 / 248 m, 0/3 inside |
