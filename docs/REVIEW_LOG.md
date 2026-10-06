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
