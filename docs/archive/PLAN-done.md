# Plan, completed milestones

Moved from `docs/PLAN.md` on 2026-10-12. Text unchanged; read only on demand. Open work, contracts and the §6 device checklist: [docs/PLAN.md](../PLAN.md).

## Status block (M0–M4)

Status: **M0 and M1 done.** M0 (commit "contracts") fixed the format and the
contracts. M1 implemented all of Core behind them (merges fcae007, 1498d52):
the ELM327 layer (framer, parser, multi-PID decoding, `MockELMAdapter`,
`ELMSession` state machine) and the log layer (gzip member writer and reader,
`LogSink`, `LogFileWriter`, stats, event mapping, simulated sources,
`inspect_log`). The bench test (2026-10-07, see below and §6) confirmed the
protocol and adapter; its findings are in the ELM layer (5644625, 2a7ac61).
What remains as stubs is App code, `fatalError("M2: …")`: **next is M2**
(`WORKFLOW.md`). All seven decisions in §5 were approved as written.
**M2 part 1 done** (BLE transport, `OBDLinkService`, `SimulatedOBDLink`, ELM
backlog items; see `docs/BACKLOG.md`); its hardware-only checks are at the end
of §6. **M2 part 2 done** (sensor sources and simulated twins, `LogStore`,
`RecordingSession`, launch wiring with a DEBUG `-autoRecordSeconds N`; the
recording backlog items; see `docs/BACKLOG.md`). A simulated end-to-end
recording reads with `inspect_log --strict` and no warnings. Its
hardware-only checks are at the end of §6. **M2 done:** part 1 reviewed in
review run 3 (2 MAJOR fixed, 38db605), part 2 in review run 4 (no BLOCKER or
MAJOR; MINORs in `docs/BACKLOG.md`). **M3 screens done** (record dashboard, pre-drive
checklist, sessions list, ELM console in `App/Sources/UI/`). **M3 done:**
reviewed in review run 5 (1 MAJOR fixed, e576601; MINORs in
`docs/BACKLOG.md`), tagged `logger-v1-rc1` (local). UI hardware checks are at
the end of §6. M4 (bench test with our app) is next.
**M4 done** (2026-10-08): bench session `docs/BENCH_TEST_2026-10-08.md`
debriefed, results in §6; fixes reviewed in review run 6 (no BLOCKER or
MAJOR; MINORs in `docs/BACKLOG.md`): the start-up init is now written at Start
(2437416, a7a5006), location authorisation is logged, and `ATAT1` is kept
unless `ATAT2` is ≥ 10% faster by median. The ≥ 5 min lock is superseded by
M5's ≥ 1 h screen-locked drive (user decision). M5 (drives) is next.
**M4 follow-up** (user decisions on M6.1-1 and M6.1-3): the start-up init is
replayed at Start only while the adapter is connected, and only the current
connection from its `→ connected`; and the poll plan with its `ATAT` level is
remembered per adapter across reconnects, so a re-init skips selection and
the timing comparison unless the remembered plan fails its check poll
(`ELMSession` "Remembered poll plan", `docs/LOG_FORMAT.md`). Hardware checks
at the end of §6.

## 1. Gap analysis

| Area | Scaffold has | Spec needs | Gap |
|---|---|---|---|
| Clock | `SessionClock`, `MonotonicTimestamp`, `UptimeSource` (system + fixed), tests | One clock, uptime base, wall clock once, OBD request + reply times, GPS fix time + receive time | Fine as is. Only the GPS fix-time conversion is new (§3.4). |
| ELM commands | `ELM327Command` with reset/echo/linefeeds/spaces/headers/autoProtocol/DPN/RV/request/raw; `handshake` | Spec init order with **ATH1**, `0100` search with ~10 s timeout, `ATAT1/2`, multi-PID `010D0C`, response-count suffix `010D1` | `handshake` uses `ATH0` and omits `0100`/`ATDPN`/`ATRV`. No adaptive timing, multi-PID or count-suffix commands. |
| Read-only guard | none — `.raw(String)` and `.request(mode:pid:)` send anything | Only `AT*` and mode `01` may ever reach the adapter; tested | Missing entirely. Most important gap: a car-safety property. |
| Framing | none | Buffer BLE fragments until `>`; strip NUL, echo, prompt | Missing. |
| Reply parser | Header-off lines, ISO-TP multi-frame block, status classification (`NO DATA`, `STOPPED`, `?`, `CAN ERROR`, …), scalar-view line split | Header-on (`7E803410D3C`), multi-ECU, multi-PID, AT text replies (`OK`, `ELM327 v2.1`, `A6`, `12.4V`) | Header-on lines are an odd number of hex digits and currently throw `malformedHex`. No ECU attribution, no multi-PID split, no text-reply path. `OK`/banner lines fail as malformed hex. |
| PID decoding | `OBDPID` (7 PIDs) + J1979 scaling, tests | `0x0D`, `0x0C`; `0x00` bitmask logged once | Need multi-PID payload splitting by `payloadByteCount`; `0x00` kept raw (no decoding needed — record it). |
| Polling | none | One in flight, 1 s timeout, retry → re-init after N → BLE reconnect; named states, every transition recorded; RPM every 5th cycle; probe combos; measure Hz | Missing. |
| Mock adapter | none | Scripted replies with delays for state-machine tests and the simulator | Missing. |
| Log format | v1: header + `motion`/`location`/`obd`/`marker`, `unrecognized` passthrough, frozen v1 fixture, byte-stable codec | Header adapter/GATT/ELM/protocol/polling/mount/vehicle; `obd` request time, command, ECU; raw IMU, mag, baro, ELM traffic, lifecycle, link, stats | All new. Needs format **v2** (§3.1). |
| Files | `LogCodec` line encode/decode, whole-document decode, `skipMalformedLines` | gzip JSONL, buffered writer actor, flush ≤ 2 s + on stop + on background, streaming reader tolerant of truncated gzip tail | No gzip, no writer, no file reader; `document(from:)` loads everything in memory. |
| Stats | none | `stats` every 10 s | Missing. |
| Sensors / BLE / background | Info.plist already declares `bluetooth-central` + `location` background modes, all purpose strings, Files-app sharing | CoreMotion 100 Hz + raw IMU + mag + altimeter; CoreLocation reference; CoreBluetooth with state restoration; live location session | All App code missing. Plist is ready. |
| UI | Placeholder `RootView` | Recording, checklist + calibration, sessions list, debug console | Missing. |
| Tools | none | `inspect_log` (header, counts, rates, gaps, OBD latency, CSV per kind) | Missing. |
| Docs | `LOG_FORMAT.md` stub | Full field reference with units | Rewrite in M0. |

---

## From §2. Milestones

### M0 — contracts (this plan)
- Format v2 types, codec support, v2 fixture, `LogFormatVersion.current = .v2`.
- Every API in §4 as compiling stubs (`fatalError("M1")` / `fatalError("M2")` bodies) with doc comments.
- `docs/LOG_FORMAT.md` full reference.
- `cd Core && swift test` green, simulator build green, `xcodegen generate`, commit **contracts**.

### M1 — Core, two parallel worktrees off "contracts"
Disjoint folders, so no merge conflicts:

| Agent | Owns (edits only here) |
|---|---|
| elm-ble-engineer | `Core/Sources/DriveLoggerCore/ELM327/`, `OBD/`, their tests |
| sensors-logging-engineer | `Core/Sources/DriveLoggerCore/Log/`, `Time/`, `Recording/`, `Core/Sources/inspect_log/`, their tests |

- ELM: command policy, framer, header-on/off parser, multi-ECU, multi-PID, text replies, `ELMSession` state machine, `MockELMAdapter`, probing. Test-first.
- Log: gzip member writer + CRC-32, `LogFileWriter`, `LogFileReader` (streaming, truncated tail), `LogSink`, `StatsAccumulator`, event mapping from ELM types to log types, simulated sources, `inspect_log`. Test-first.
- Acceptance: both reviewed, CONFIRMED findings fixed, merged, `swift test` green on main.

### M2 — App services, sequential (in main)
Two parts, one after the other. Full instructions in `WORKFLOW.md` M2.

| Part | Agent | Owns (edits only here) |
|---|---|---|
| 1 | elm-ble-engineer | `App/Sources/Link/**`; `Core/…/ELM327/**`, `OBD/**` for M2 backlog items only; their tests; `project.yml` if a target setting is needed |
| 2 | sensors-logging-engineer | `App/Sources/Sensors/**`, `App/Sources/Recording/**`; `App/Resources/Info.plist` if a purpose string or background mode is missing; `Core/…/{Log,Time,Recording}/**` for M2 backlog items only; their tests |

1. `BLETransport` (CoreBluetooth, GATT auto-detect, write splitting, state restoration; adapter advertises as `IOS-Vlink`), `OBDLinkService` (scan / pick / remember / reconnect / console feed), `SimulatedOBDLink` (`MockELMAdapter` + `Rule.benchCar`, used on the simulator).
2. `DeviceMotionSource`, `RawIMUSource`, `AltimeterSource`, `LocationSource` (+ simulated twins), `LogStore` (Documents/logs), `RecordingSession` orchestrator, background lifecycle, 10 s stats, disk-space policy.
- Acceptance: green Core tests, simulator build and app tests after each part; `/review-loop` on each part's diff; a simulated end-to-end recording that `inspect_log` reads cleanly.

### M3 — UI (ios-ui-engineer, App UI only)
Recording dashboard, pre-drive checklist + 5 s calibration, sessions list (share/delete with confirmation), ELM debug console with guarded manual field, simulator "unavailable" states, previews for every screen. Tag `logger-v1-rc1` after review.

### M4 — bench test in the parked car (you)
Field checklist from the `elm327-protocol` skill; drive-analyst debrief; smallest fixes, especially the fastest stable polling combo.

