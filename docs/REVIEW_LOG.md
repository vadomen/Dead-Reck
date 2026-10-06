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
