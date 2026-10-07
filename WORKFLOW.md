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

Skills: `elm327-protocol`, `ios-build-test`, `drive-log-debrief` (preloaded into the agents that need them).
Hooks: after every edit -> incremental Core build + Foundation-only import check, XcodeGen reminders, no hand-edits of the .xcodeproj, recordings guard. On stop -> `cd Core && swift test` if Core changed.

---

## M0 - Plan and contracts (main session, plan mode)

The scaffold already exists (Time/, ELM327/, OBD/, Log/ in Core, frozen v1 log fixture). M0 extends it rather than starting over.

```text
Read CLAUDE.md, README.md, docs/LOG_FORMAT.md, docs/SPEC_V1.md and everything under Core/. docs/SPEC_V1.md is the v1 logger specification. In plan mode, produce docs/PLAN.md with:
- a gap analysis: what the scaffold already covers vs what the spec needs;
- milestones M1-M5 as in WORKFLOW.md;
- every LogEvent kind the spec needs (fields, units, timestamps) and whether it fits format v1 or needs v2;
- the contracts that let work run in parallel: an ELM transport protocol (send bytes / receive bytes), an ELM session API (state stream, poll result stream, read-only command guard), a log writer/reader API (buffered gzip writer, tolerant reader), a SensorSource protocol (real + simulated), the OBDLink service API and the RecordingSession orchestrator API.
Wait for my approval. After approval, implement ONLY the contracts as compiling stubs with doc comments, update docs/LOG_FORMAT.md, run `cd Core && swift test` and the simulator build, commit "contracts".
```

## M1 - Core in parallel (two worktrees)

```text
Run two subagents in parallel, each in its own git worktree (isolation: worktree), both on top of the "contracts" commit:
1. elm-ble-engineer: implement the Core ELM327 layer behind the contracts - framing, parser (ATH0 and ATH1, fragments, statuses, multi-ECU, multi-PID), PID decoding, polling state machine with timeouts/retry/re-init, read-only command guard, and a MockELMAdapter that replays scripted responses with delays. Test-first.
2. sensors-logging-engineer: implement the Core log layer - row encoding, gzip JSONL writer with periodic flush, tolerant reader (truncated tail), formatVersion handling with a v1 fixture, MonotonicClock conversions, and inspect_log in Core/Sources/inspect_log (header, counts, rates, gaps, OBD latency, CSV export per row type). Test-first.
Both work only inside Core/ (ELM327/ + OBD/ vs Log/ + Time/ + tools); neither touches App/. When both finish, run the reviewer on each branch, fix CONFIRMED findings, merge both to main, run `cd Core && swift test`, commit.
```

## M2 - App services (sequential)

```text
Use elm-ble-engineer to implement the CoreBluetooth transport and OBDLink service: scan/pick/remember adapter, GATT auto-detection per the elm327-protocol skill, framing via Core, reconnect, state restoration, raw TX/RX feed for the debug console.
Then use sensors-logging-engineer to implement real + simulated SensorSource, reference GPS, background execution and the RecordingSession orchestrator that wires sensors + OBD + writer and writes stats rows every 10 s.
Simulator build must pass after each. Then reviewer on the M2 diff; fix and commit.
```

## M3 - UI

```text
Use ios-ui-engineer to build: recording dashboard (big OBD and GPS speed, OBD Hz, motion Hz, elapsed, file size, Start/Stop/Mark), pre-drive checklist + 5 s still calibration, sessions list (share/delete), ELM debug console (manual commands limited to ATI, AT@1, ATDP, ATDPN, ATRV and mode 01 — `ELMCommandPolicy` `.manual`; it must handle `ELMSessionError.desynchronised` by offering a re-initialise). Previews for every screen. Simulator build + app tests must pass. Reviewer, fix, commit, tag logger-v1-rc1.
```

## M4 - Bench test in the parked car (you + main session)
Install on the iPhone, ignition ON, follow the "Field checklist" of the elm327-protocol skill. Give the session file to Claude:

```text
Here is a bench-test log from the parked car: logs/<file>. Use drive-analyst to debrief it, then propose the smallest code changes to fix what it found (especially the fastest stable OBD polling combo).
```

## M5 - First drives and loop
20-30 min city drive, then a longer one with highway and a jammed-GPS area. After each:

```text
New drive: logs/<file>. Use drive-analyst for the debrief. If the verdict is not GOOD, plan the fix, implement it with the owning agent, run reviewer, and give me a new build checklist.
```
Done = 3 consecutive drives with verdict GOOD, including one >= 1 hour with screen locked. Tag `logger-v1`.

## Rules for the orchestrator
- Contracts first; parallel work only on disjoint folders (Core/ELM vs Core/Log). UI only after the APIs exist.
- Every milestone ends with reviewer -> fixes -> green tests -> commit. No push without asking me.
- Anything that needs the iPhone or the car goes to a checklist for me; never claim it works.
