# DriveLogger v1 - agent workflow

Install once from the repo root: `mkdir -p .claude && cp -R claude-setup/ .claude/ && rm -rf claude-setup && chmod +x .claude/hooks/*.sh`, then commit (`git add .claude WORKFLOW.md`). Hooks need `jq` (`brew install jq`) and use full Xcode automatically if `xcode-select` points at CommandLineTools. The main Claude Code session is the orchestrator; it delegates to the subagents below and never merges a milestone without the reviewer.

| Agent | Model | Owns | Can edit |
|---|---|---|---|
| main session | Sonnet (Opus to verify findings / judge adoption) | plan, contracts, merges, orchestration | yes |
| elm-ble-engineer | Opus | ELM327 protocol (Core), mock adapter, CoreBluetooth transport | yes |
| sensors-logging-engineer | Opus | sensors, clock, log format, writer/reader, background, inspect_log | yes |
| ios-ui-engineer | Sonnet | SwiftUI screens | App UI only |
| navigation-engineer | Opus | DR engine, replay_nav, road graph, map matching | yes |
| reviewer | Opus | review vs invariants | no |
| docs-editor | Sonnet | docs-only edits, ledger/backlog row moves | docs only, no shell |
| drive-analyst | Sonnet | field-log debrief | no |

Skills: `elm327-protocol`, `ios-build-test`, `drive-log-debrief` (preloaded into the agents that need them), `review-loop` (`/review-loop <range>`).
Hooks: after every edit -> incremental Core build + Foundation-only import check, XcodeGen reminders, no hand-edits of the .xcodeproj, recordings guard. On stop -> `cd Core && swift test` if Core changed.

Each of M2–M5 is self-contained: start it with **"Run Mx as in WORKFLOW.md"**.

## Read first (every milestone)

- `CLAUDE.md`: invariants, conventions, commands. It wins on any conflict.
- `docs/PLAN.md`:
  - the decisions at the top;
  - §2, the open milestone's deliverables (completed milestones, the old status block and §1 are in `docs/archive/PLAN-done.md`);
  - the §4 contracts the milestone implements. **The code is authoritative over the §4 sketches.**
  - §6, the hardware checks.
- `docs/SPEC_V1.md`: what v1 must do.
- `docs/BENCH_TEST_2026-10-07.md`: real replies from the test car (VW Touareg 2025, Vgate iCar Pro BLE 4.0 advertising as `IOS-Vlink`).
- `docs/BACKLOG.md`: open (DEFERRED) items tagged with the milestone you're running. Close them, or say why not. Closed rows live in `docs/archive/BACKLOG-closed.md`.
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

## M4.2 - Map camera + manual fix — **done**

Adds an initial map camera and the driver's "I'm here" position fix, which is ground truth for dead reckoning offline (above all where GNSS is jammed).

- **Camera:** span = max(500 m, 3 × horizontalAccuracy). It is set on the first fix, when the Map tab opens with a fix, and on Following. Before recording, the reference source's cached last-known location (read only, no session) sets the initial camera.
- **Manual fix:** since N4 a double tap on the map (recording, map at most 300 m) writes a `manualFix` event (format **v3**), after a 3 s Undo window, with `t` = `pressedT` = the tap time:
  - the position under the finger and `mapSpanM`;
  - the last OBD speed and its reply time, and the GPS speed;
  - no note;
  - the speed that describes it: `speedSource` obd|gps|unknown and `gateSpeedKmh`.
  - Earlier builds: a long-press staged a draggable pin and Confirm wrote the row, refused above 10 km/h.
- **Speed source (`ManualFixGate`):** no limit. OBD counts if ≤ 2 s old. Otherwise GPS counts if the fix is accurate (≤ 100 m, valid speed accuracy) and ≤ 5 s old. Otherwise `unknown`.
- **Format:** `LogFormatVersion` v3 with a new frozen v3 fixture; the v1/v2 fixtures are untouched. `inspect_log` summary and `manualFix.csv`; `LOG_FORMAT.md`; `drive-log-debrief` uses manual fixes as ground truth.

## M4.3 - Map follow + heading-up (UI only)

Fixes Following switching off by itself during drives (the `positionedByUser`
handler is gone) and adds a heading-up camera. No Core, logging, sensor, log
format or `RecordingSession` change.

- **Follow:** only a real touch gesture (drag, pinch, rotate, double-tap) turns it off. It resumes 8 s after the last gesture or camera change, with a "Re-centre in N s" hint.  Tapping Follow while following turns it off for good (until tapped again). Logic: `MapFollow.swift` (`FollowController`).
- **Heading-up:** a separate "North up / Heading up" button (`@AppStorage("map.headingUp")`). Bearing is GPS course only (> 10 km/h, course accuracy 0...20 deg), never the compass; the camera holds still when OBD speed is exactly 0. `MapBearing.swift` (`MapBearingSource` is the seam for a later DR heading source).
- **RecordingSession:** two read-only accessors, no behaviour change: `obdSpeedReplyUptime` and `currentUptimeSeconds`, so the map can tell a fresh OBD speed 0 (age <= `ManualFixGate.maxOBDAgeS`) from a stale one.
- **Device checklist (not verified; PLAN.md section 6):** 10 min drive with no unexpected loss of Following; pan, then auto re-centre after 8 s; heading-up rotates smoothly and holds still at stops; the SwiftUI gestures on `Map` fire and do not block panning. If they do not, the fallback is an `MKMapView` wrapper, which needs the user's approval first.

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

**Logger v1 is done after M5.** M5 drives continue in parallel with the navigator work below; each new drive also joins the replay set.

---

## Navigator roadmap

Dead reckoning on top of the logger. The model, config, replay commands, acceptance runs and baselines are in `docs/NAVIGATION.md`. Owner: `navigation-engineer`, with `ios-ui-engineer` for the map and `sensors-logging-engineer` for anything touching the logger.

- **N2 - engine + replay — done.** Causal, deterministic particle filter in `Core/Navigation`, plus the `replay_nav` evaluation CLI (docs/NAVIGATION.md).
- **N2.1 / N2.2 - tuning — done.** Speed-scale prior, manual-fix σ from map span, network-fix tempering, ellipse consistency metric, stale-fix σ growth (docs/NAVIGATION.md: acceptance, adoption rule).
- **N4 - live navigation in the app — done.** Sample tap, NavigationService, sidecar `.nav.jsonl`, dead-reckoning dot and ellipse on the map, pin from the estimate (docs/NAVIGATION.md "Live in the app (N4 B)").
- **N3 - OSM roads + map matching** (plan: docs/N3_PLAN.md):
  - **N3.0 - engine fixes, new baseline — done.** docs/NAVIGATION.md "N3.0 exit".
  - **N3.1 - road pack format, builder, index, tests — done.** docs/ROAD_PACK.md.
  - **N3.2a - off-road model prototypes — done.** Test 3 is a known FAIL (docs/N3_ROAD_OFFROAD.md).
  - **N3.2b - `replay_nav --roads`, first measurement — done.**
  - **N3.2c - canonical pack order, unmapped metric, perf test — done.**
  - **N3.2d - pre-declared grids — done.** No config chosen.
  - **N3.2e - level rule across packs — done.** Re-run of the declared candidates and a trade-off table against N3.0.
  - **N3.2 - done (2026-10-14).** Default config: N3.2e item 1 plus `roadCorrelationM` 100, a trade-off the user accepted (drive-7 consistency fails; docs/NAVIGATION.md "N3.2 decision").
  - **N3.3 - enable roads on the live path (sidecar v2) — next.** Waits for a Release-build ms/step measured on the phone (device item).
  - **N3.4 - packs in the app (import), display — after N3.3.**
- **NAV-NOOBD - navigation without OBD — after N3.** See docs/BACKLOG_UX.md.

Every engine change is judged on the replay set first and goes through `/review-loop` before merge.

---

## Rules for the orchestrator
- **Model.** The main session runs on Sonnet by default. Switch to Opus (`/model`) only to verify review findings (CONFIRMED / REJECTED) or to judge an adoption-rule verdict yourself (docs/NAVIGATION.md), then switch back. Engineer agents and the reviewer stay on Opus with effort high (their frontmatter); `ios-ui-engineer`, `drive-analyst` and `docs-editor` run on Sonnet.
- **Delegate by default.** Code and analysis go to the owning agent with a self-contained brief: `navigation-engineer` (Core/Navigation, Replay, replay_nav, Roads, RoadPackBuild, tools/roads), `sensors-logging-engineer` (clock, log, sensors, RecordingSession), `elm-ble-engineer` (ELM327/OBD/BLE), `ios-ui-engineer` (App UI), `drive-analyst` (recordings), `docs-editor` (docs).
  - Give the agent a self-contained brief: files to read, goal, exit criteria, memory limits.
  - Take back a short result: what changed, commits, test counts, numbers, open decisions.
- **The main session itself only** plans, asks me for decisions, verifies review findings, runs the final checks, commits and merges. It does not read large source files or run replay grids itself; it reads the agent's summary.
- **API limit.** If an agent stops on an API limit, start a fresh one with a brief that says "resume from the last commit on <branch>".
- **Archive.** `docs/archive/` is history: read it only on demand, never as default context for an agent. When a backlog row closes (DONE, FIXED, SUPERSEDED, OBSOLETE), move it to `docs/archive/BACKLOG-closed.md` unchanged; superseded NAVIGATION result tables go to `docs/archive/NAVIGATION-history.md`.
- **Docs-only work goes to `docs-editor`**, not `navigation-engineer` or another engineer: wording fixes, ledger/backlog row moves, plan text. It has no shell, so you run tests and commit.
- **One engineer agent at a time in the main working tree.** Parallel sessions each get their own git worktree: `git worktree add ../dead-reck-<task> -b <task>`.
  - Merge them one at a time.
  - Run `cd Core && swift test` after each merge, plus the simulator build if `App/` changed.
  - Remove the worktree and branch once merged.
- Contracts first; parallel work only on disjoint folders. UI only after the service APIs exist.
- Every part ends with `/review-loop` on its diff, green tests, and a commit. No push without asking me.
- Decisions that are genuinely mine (behaviour, safety trade-offs, a finding that comes back twice) go to me before a fix, not after.
- Anything that needs the iPhone or the car goes to PLAN.md §6 as a checklist item for me; never claim it works.
- Recordings stay outside the repo. Never commit one.
