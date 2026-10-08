# DriveLogger v1 - agent workflow

Install once from the repo root: `mkdir -p .claude && cp -R claude-setup/ .claude/ && rm -rf claude-setup && chmod +x .claude/hooks/*.sh`, then commit (`git add .claude WORKFLOW.md`). Hooks need `jq` (`brew install jq`) and use full Xcode automatically if `xcode-select` points at CommandLineTools. The main Claude Code session is the orchestrator; it delegates to the subagents below and never merges a milestone without the reviewer.

| Agent | Model | Owns | Can edit |
|---|---|---|---|
| main session | Opus | plan, contracts, merges, orchestration | yes |
| elm-ble-engineer | Opus | ELM327 protocol (Core), mock adapter, CoreBluetooth transport | yes |
| sensors-logging-engineer | Opus | sensors, clock, log format, writer/reader, background, inspect_log | yes |
| ios-ui-engineer | Sonnet | SwiftUI screens | App UI only |
| reviewer | Opus | review vs invariants | no |
| drive-analyst | Sonnet | field-log debrief | no |

Skills: `elm327-protocol`, `ios-build-test`, `drive-log-debrief` (preloaded into the agents that need them), `review-loop` (`/review-loop <range>`).
Hooks: after every edit -> incremental Core build + Foundation-only import check, XcodeGen reminders, no hand-edits of the .xcodeproj, recordings guard. On stop -> `cd Core && swift test` if Core changed.

Each of M2–M5 is self-contained: start it with **"Run Mx as in WORKFLOW.md"**.

## Read first (every milestone)

- `CLAUDE.md`: invariants, conventions, commands. It wins on any conflict.
- `docs/PLAN.md`:
  - the status block and decisions at the top;
  - §2, the milestone's deliverables and folder ownership;
  - the §4 contracts the milestone implements. **The code is authoritative over the §4 sketches.**
  - §6, the hardware checks.
- `docs/SPEC_V1.md`: what v1 must do.
- `docs/BENCH_TEST_2026-10-07.md`: real replies from the test car (VW Touareg 2025, Vgate iCar Pro BLE 4.0 advertising as `IOS-Vlink`).
- `docs/BACKLOG.md`: deferred items tagged with the milestone you're running. Close them, or say why not.
- `docs/LOG_FORMAT.md` whenever anything touches the log.

---

## M0 - Plan and contracts — **done**

Done in commit "contracts" (e712d29) plus two review-fix commits. Kept as history.

```text
Read CLAUDE.md, README.md, docs/LOG_FORMAT.md, docs/SPEC_V1.md and everything under Core/. docs/SPEC_V1.md is the v1 logger specification. In plan mode, produce docs/PLAN.md with:
- a gap analysis: what the scaffold already covers vs what the spec needs;
- milestones M1-M5 as in WORKFLOW.md;
- every LogEvent kind the spec needs (fields, units, timestamps) and whether it fits format v1 or needs v2;
- the contracts that let work run in parallel: an ELM transport protocol (send bytes / receive bytes), an ELM session API (state stream, poll result stream, read-only command guard), a log writer/reader API (buffered gzip writer, tolerant reader), a SensorSource protocol (real + simulated), the OBDLink service API and the RecordingSession orchestrator API.
Wait for my approval. After approval, implement ONLY the contracts as compiling stubs with doc comments, update docs/LOG_FORMAT.md, run `cd Core && swift test` and the simulator build, commit "contracts".
```

## M1 - Core in parallel (two worktrees) — **done**

Done: merges fcae007 (log/recording) and 1498d52 (ELM327), integration commit 189387e. The bench-test update (5644625, 2a7ac61) followed. Kept as history.

```text
Run two subagents in parallel, each in its own git worktree (isolation: worktree), both on top of the "contracts" commit:
1. elm-ble-engineer: implement the Core ELM327 layer behind the contracts - framing, parser (ATH0 and ATH1, fragments, statuses, multi-ECU, multi-PID), PID decoding, polling state machine with timeouts/retry/re-init, read-only command guard, and a MockELMAdapter that replays scripted responses with delays. Test-first.
2. sensors-logging-engineer: implement the Core log layer - row encoding, gzip JSONL writer with periodic flush, tolerant reader (truncated tail), formatVersion handling with a v1 fixture, MonotonicClock conversions, and inspect_log in Core/Sources/inspect_log (header, counts, rates, gaps, OBD latency, CSV export per row type). Test-first.
Both work only inside Core/ (ELM327/ + OBD/ vs Log/ + Time/ + tools); neither touches App/. When both finish, run the reviewer on each branch, fix CONFIRMED findings, merge both to main, run `cd Core && swift test`, commit.
```

---

## M2 - App services (sequential, in main)

**Goal:** implement every `fatalError("M2: …")` stub, so the app records a full drive on the device and a simulated one on the simulator. No UI beyond what already exists; screens are M3.

**Contracts:**
- PLAN.md §4.4: sensor sources.
- PLAN.md §4.5: OBD link service.
- PLAN.md §4.6: `RecordingSession`.

Also follow §4.0 (concurrency conventions) and the doc comments on the stubs and on `ELMSession` / `LogFileWriter`, which are authoritative.

Two parts, run one after the other in the main working tree (no worktrees). Part 2 consumes part 1's `OBDLinkServicing`.

### Part 1 — `elm-ble-engineer`

- **May edit:**
  - `App/Sources/Link/**`;
  - `Core/Sources/DriveLoggerCore/ELM327/**` and `OBD/**`, only for the M2 backlog items listed below;
  - their tests: `AppTests/` for App code, `Core/Tests/` for Core;
  - `project.yml`, only if a target setting is needed.
- **Implement:**
  - `BLETransport`: CoreBluetooth.
    - Scan; let the user pick; remember the choice by `peripheral.identifier`. The test adapter advertises as **`IOS-Vlink`**.
    - GATT auto-detection per SPEC "BLE" and the `elm327-protocol` skill.
    - Write splitting to `maximumWriteValueLength`.
    - Uptime stamps taken in the delegate callback.
    - State restoration.
  - `OBDLinkService`:
    - scan / pick / remember / connect;
    - one `ELMSession` per connection, seeded with the previous `nextSeq`;
    - reconnect with backoff, both on `needsReconnect` and on link loss;
    - BLE state transitions as `LinkEvent.ble` with frozen state names;
    - the console feed;
    - `sendManual` with `.manual` scope, handling `ELMSessionError.desynchronised`.
  - `SimulatedOBDLink`: wraps `MockELMAdapter` with `Rule.benchCar`, and is chosen automatically on the simulator.
- **Backlog to close:**
  - R1-4: the protocol-doc half;
  - R2.1-2, R2.2-1, R2.2-2, R2.2-3;
  - M1-E4, M1-E5, M1-E6;
  - B1-3.
- **Check:** the only `writeValue` call is in `BLETransport.send` (`RepositoryInvariantTests`).

### Part 2 — `sensors-logging-engineer`

- **May edit:**
  - `App/Sources/Sensors/**` and `App/Sources/Recording/**`;
  - `App/Resources/Info.plist`, only if a purpose string or background mode is missing;
  - `Core/Sources/DriveLoggerCore/{Log,Time,Recording}/**`, only for the M2 backlog items listed below;
  - their tests in `AppTests/` and `Core/Tests/`.
- **Implement:**
  - Sensor sources, each with a simulated twin on the simulator:
    - `DeviceMotionSource`, `RawIMUSource` and `AltimeterSource` (CoreMotion);
    - `LocationSource` (CoreLocation: reference only, `CLBackgroundActivitySession` while recording, fix-time rule per PLAN §3.4).
  - `LogStore` in `Documents/logs`: list, size, delete, and never overwrite.
  - `RecordingSession`:
    - one `SessionClock` per recording;
    - calibration as the first phase;
    - wiring of sources + `linkEvents()` + `LogFileWriter`;
    - `stats` every 10 s;
    - lifecycle rows and background/foreground flushes;
    - the disk-space policy: warn at 200 MB, stop cleanly at 50 MB, refuse to start below 200 MB;
    - write failures leading to `failed`;
    - the idle timer kept off while recording.
- **Backlog to close:**
  - R1-9 and R3-2: the session side;
  - R3-1, R3-3, R3-4, R3-5;
  - M1-L1;
  - R2.1-4.

### Each part

1. Run `xcodegen generate` after adding or removing any App file, and commit the regenerated project with it.
2. Green: `cd Core && swift test`, the simulator build, and the app tests on a concrete simulator (`id=`). See the `ios-build-test` skill.
3. Commit the part.
4. Run `/review-loop <part's commit range>` and let it finish: it fixes, re-reviews and commits per round.

**Done when:**
- Both parts have been through `/review-loop`.
- Everything is green.
- The app runs on the simulator end to end and produces a recording that `inspect_log` reads without warnings. Keep that recording outside the repo.
- Docs are updated: `docs/LOG_FORMAT.md` for any new row text, the PLAN.md status block, README for the app's permissions and behaviour, and BACKLOG.md for items closed.
- Every hardware-only check found along the way is appended to PLAN.md §6.

**Stop after M2 — don't start the next milestone.**

---

## M3 - UI (`ios-ui-engineer`, App UI only)

**Goal:** the screens from SPEC_V1 "UI", built on the M2 services. No protocol, sensor or log-format changes. If a service API is missing, stop and report it rather than editing services.

- **May edit:** SwiftUI views and view models under `App/Sources/` (e.g. `App/Sources/UI/**`, `RootView.swift`, `DriveLoggerApp.swift`), and `AppTests/`. Not `Link/`, `Sensors/`, `Recording/` or Core.
- **Screens:**
  - **Recording dashboard**, readable at arm's length:
    - adapter status;
    - large OBD speed and GPS speed side by side;
    - OBD Hz, motion Hz, elapsed time, file size;
    - large Start, Stop and Mark buttons;
    - the low-disk warning;
    - the `failed` state with its unwritten count.
  - **Pre-drive checklist:** rigid mount, fixed orientation. Calibration is the first phase of a started recording (`RecordingState.calibrating`).
  - **Sessions list:** duration, size, date; share-sheet export; delete with confirmation.
  - **ELM debug console:**
    - every TX/RX line;
    - a manual field limited to `ATI`, `AT@1`, `ATDP`, `ATDPN`, `ATRV` and mode 01, matching `ELMCommandPolicy` `.manual`;
    - on `ELMSessionError.desynchronised`, offer re-initialise.
- **Also required:**
  - previews for every screen;
  - clear simulator states for "Bluetooth unavailable" and "Motion unavailable", with no crash;
  - the screen stays awake while recording.
- **Backlog to close:** items tagged M3, plus R2.1-5 (README wording) if it's still open.

**Then:**
1. Green: the simulator build and app tests.
2. Commit.
3. `/review-loop` on the M3 range.
4. Tag `logger-v1-rc1`, local only.

**Done when:**
- It has been reviewed and everything is green.
- The tag exists.
- README describes the screens and the recording procedure.
- Any UI-only hardware checks (readability in the mount, glare) are appended to PLAN.md §6.

**Stop after M3 — don't start the next milestone.**

---

## M4 - Bench test with our app (you + main session)

**Goal:** prove on the iPhone, parked with ignition on, what the simulator can't.

You install the build and run the checks. The main session prepares the checklist, reads the logs and proposes fixes. Never claim a hardware result that isn't in a log.

**Checklist** (extends the `elm327-protocol` skill's field checklist; record each answer in PLAN.md §6):
1. **GATT:** the GATT layout the transport chose, and `maxWriteLength` (from the header `adapter.gatt`).
2. **Poll plan:**
   - which plan start-up selection picks (`adapter` row);
   - whether `ATSH7E0` engages: `requestHeader: 7E0`, and `ATDPN` reads `A6` after our own `ATSP0`;
   - the real poll Hz (`stats.obdHz`, `inspect_log`).
3. **`ATAT1` vs `ATAT2`:** which the session kept, and whether `ATAT2` cuts replies short.
4. **Screen locked for 5 minutes while recording:** rows continue, there are no gaps in `stats`, and the flush timer keeps firing.
5. **Unplug/replug the adapter while recording:** BLE `link` rows, reconnect, re-init with `ATSH7E0` re-applied, and polling resumes; `seq` continues.
6. **Also note:** `ATZ` banner text, `ATRV` readings, write-off / re-init notes, and any `7E9` lines under physical addressing.

**Debrief:**
```text
Here is a bench-test log from the parked car: <path outside the repo>. Use drive-analyst to debrief it, then propose the smallest code changes to fix what it found.
```

**Then:**
1. Each fix goes through the owning agent (ELM/BLE → `elm-ble-engineer`; sensors/log/recording → `sensors-logging-engineer`; UI → `ios-ui-engineer`), with a regression test where the bug can be reproduced on the Mac.
2. Green builds and tests.
3. Commit.
4. `/review-loop` on the fix range.

**Done when:**
- Every checklist item has a logged answer in PLAN.md §6.
- The fixes are reviewed and green.
- `docs/BENCH_TEST_*.md` records the session (new file per date).
- SPEC/PLAN/skill are updated with anything that changed (e.g. the polling combination or timeouts).

**Stop after M4 — don't start the next milestone.**

## M4.1 - GPS map screen (UI only, read-only)

---

## M5 - Drives

**Goal:** three consecutive GOOD drives.

**Drives:**
1. A 20–30 min city drive.
2. A longer one with highway and a jammed-GPS area.
3. At least one of the drives must be **≥ 1 h with the screen locked**.

**After each drive:**
```text
New drive: <path outside the repo>. Use drive-analyst for the debrief. If the verdict is not GOOD, plan the fix, implement it with the owning agent, run /review-loop on the fix, and give me a new build checklist.
```

**Done when:**
- There are 3 consecutive GOOD debriefs, one of them ≥ 1 h screen-locked.
- Every fix along the way went through `/review-loop` and is green.
- PLAN.md §6 is updated with what the drives showed (background survival, real rates).
- The local tag `logger-v1` is set.

**Stop after M5 — v1 is done; don't start new work without a new plan.**

---

## Rules for the orchestrator
- **One agent at a time in the main working tree.** Parallel sessions each get their own git worktree: `git worktree add ../dead-reck-<task> -b <task>`.
  - Merge them one at a time.
  - Run `cd Core && swift test` after each merge, plus the simulator build if `App/` changed.
  - Remove the worktree and branch once merged.
- Contracts first; parallel work only on disjoint folders. UI only after the service APIs exist.
- Every part ends with `/review-loop` on its diff, green tests, and a commit. No push without asking me.
- Decisions that are genuinely mine (behaviour, safety trade-offs, a finding that comes back twice) go to me before a fix, not after.
- Anything that needs the iPhone or the car goes to PLAN.md §6 as a checklist item for me; never claim it works.
- Recordings stay outside the repo. Never commit one.
