# Backlog

Deferred items, mostly MINOR review findings from `/review-loop` runs (see
`docs/REVIEW_LOG.md` for context). Pick up in the milestone named, or earlier
if convenient. Status: DEFERRED until done.

| ID | Source | Item | Suggested fix | Milestone | Status |
|---|---|---|---|---|---|
| R1-3 | review run 1, round 1 | `RepositoryInvariantTests` matches the plain substring `writeValue(`; bypassable via `writeValue (`, an unapplied method reference, or L2CAP streams; exempts any file named `BLETransport.swift`. | Regex `\bwriteValue\b` and `openL2CAPChannel`; exempt by relative path `App/Sources/Link/BLETransport.swift`. | M2 | DEFERRED |
| R1-4 | review run 1, round 1 | `ELMCommandPolicy.validate(_:scope:)` defaults to the permissive `.session`; `ValidatedELMCommand` doesn't record its scope; `OBDLinkServicing.sendManual` doc doesn't say `.manual`. | Make `scope` required; say `.manual` in the protocol doc; optionally carry scope so `MockELMAdapter` can assert manual commands passed `.manual`. | M1 (ELM) | DEFERRED |
| R1-5 | review run 1, round 1 | `PollingPlan.primaryCommand` returns `String`; validating it through the policy would accept `010D10` for `responseCount: 10`. | Return `ELM327Command`/`[ELM327Command]`, or validate ranges in `PollingPlan.init`. | M1 (ELM) | DEFERRED |
| R1-6 | review run 1, round 1 | `ATST` is allowlisted but unreachable: no `ELM327Command` case, refused by the console. The "below 0x19 every poll is NO DATA" rationale is overstated (J1979 P2 = 50 ms on CAN). | Add `.setTimeout(UInt8)` with the range checked in `validated()`, or drop ATST; soften README/policy wording; revisit the floor after M4. | M1 / M4 | DEFERRED |
| R1-7 | review run 1, round 1 | `ELMExchange.tx` doc still says "as written"; LOG_FORMAT `elm` `t` column doesn't cover `rejected`. | Align with `LogRecords`/LOG_FORMAT ("uppercased; for rejected, as typed"; "or the moment of rejection"). | M1 | DEFERRED |
| R1-8 | review run 1, round 1 | A session-originated command that fails `validated()` has no defined behaviour; could loop retrying → reinitialising → needsReconnect with no explaining row. | Emit a `rejected` exchange with `tx = wireFormat`, go to `failed` with a reason, never retry. | M1 (ELM) | DEFERRED |
| R1-9 | review run 1, round 1 | `finish()` idempotency undefined; a `flush()` throw might also appear on `failures` (double error row / double finish); sources not stopped before `finish()`, so post-finish drops aren't in `failed(unwrittenEvents:)`. | Idempotent `finish()` returning the same summary; report each failure once; stop sources before `finish()` or include `LogSink.dropped`. | M1 / M2 | DEFERRED |
| R1-10 | review run 1, round 1 | `docs/SPEC_V1.md:76` and `WORKFLOW.md:52` still describe the console as "AT commands and mode 01". | Point both at the five query commands plus mode 01. | before M3 | DEFERRED |
