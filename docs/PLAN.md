# DriveLogger v1 — implementation plan (M0)

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

**Decisions taken during M1 (by the user, after review):**
- `NO DATA`: a PID that has answered OK in the session (poll or probe) is
  never dropped; its `NO DATA` is a failure (retry → re-init → reconnect). A
  PID that never answered OK is dropped. Answered-OK beats the `0100` bitmask.
- Write-off (a `>` missing for longer than timeout + grace): the link is
  desynchronised and only `ATZ` may be sent; while polling the session
  re-initialises at once. The earlier `ATRV` resync was removed after three
  review rounds showed a stale voltage reply could satisfy it.
- `ATST` dropped from the allowlist (nothing sends it).
- Bench test 2026-10-07 (`docs/BENCH_TEST_2026-10-07.md`):
  - **Physical addressing.** After `ATRV` the session sends `ATSH7E0` only
    when `ATDPN` reports 11-bit ISO 15765-4 CAN (`6`, `A6`, `8`, `A8`) and the
    `0100` reply had a `7E8` line. On other protocols a 3-digit `ATSH` isn't an
    OBD request ID. Physical addressing engages only if `ATSH7E0` answers
    `OK`. If it doesn't — or it was skipped — requests stay functional
    (`7DF`), a note is recorded, and initialisation and recording carry on:
    this is not an error.
  - **Poll command.** Chosen at start-up as the first of `010D0C1` →
    `010D0C` → `010D1` → `010D` that returns the engine's (`7E8`) values.
    The `1` suffix is used only after `ATSH7E0` answered `OK`: under
    functional addressing the suffix returned the gearbox's reply. Since
    the M4 follow-up (M6.1-3) the chosen plan and `ATAT` level are
    remembered per adapter for the app session: a reconnect to the same
    adapter reuses them after the full handshake if the `ATSH7E0` gate gives
    the same addressing, with `ATAT<n>` and one check poll instead of
    selection and the `ATAT1`/`ATAT2` comparison; if the check fails,
    selection runs as before (once per init).
  - **Functional fallback.** If nothing parses at `7E0` (or only without
    speed), the session sends `ATSH7DF` and selects again functionally
    (`010D0C` → `010D`, no suffix). Every fallback plan is functional. The
    gate is re-evaluated on every re-init.
  - `ATSH` is allowlisted for `7DF` and `7E0`–`7E7` only, in session scope.
    `polling.requestHeader` records the addressing.

For M1 the code is authoritative over the §4 sketches below; the ELM and log
behaviour is documented in the `ELMSession` / `LogFileWriter` doc comments and
in `docs/LOG_FORMAT.md`.

Small deviations from the sketches below, made while writing the stubs:
`ELM327Command.currentDataMany(_:responseCount:)` (not `requestMany`);
`StatsAccumulator.closeWindow(at:…)` (not `window(endingAt:…)`); the
`needsReconnect` stream is folded into `ELMSessionEvent.needsReconnect`;
`OBDLinkServicing` exposes a merged `adapter: AdapterRecord?` + `plan` instead
of separate `adapterInfo`/`gatt`, and a single event stream (now `linkEvents()`);
`RecordingSession` adds `handleMemoryWarning()`.

**Review fixes (commit after "contracts").** The review found ten issues in the
contracts; all were fixed before M1. Where a sketch in §4 differs from the
code, **the code is authoritative**. The sketches below have been updated for
the main points:

1. The read-only guard is an explicit **allowlist** (`ELMCommandPolicy`, now
   implemented and tested). "Any AT" was unsafe: `ATCAF0` then `0104` puts a
   service 04 (clear DTCs) frame on the bus.
2. Transports accept only `ValidatedELMCommand`, which only the policy can
   create. `ELM327Command.raw` and `.request(mode:pid:)` are gone; the enum
   can only express read-only commands.
3. `seq` is unique across reconnects: `ELMSession(firstSeq:)` + `nextSeq`.
4. `ELMSession` takes an `UptimeSource`. Every `ELMSessionEvent` carries the
   uptime at which it happened, and rows are stamped from that, not from when
   they were consumed.
5. BLE transitions reach the recorder: `LinkEvent` (`.ble` + `.session`), BLE
   state names frozen in `LinkSample.BLEState`; `linkEvents()` replaces
   `sessionEvents()`.
6. `ELM327Command.handshake` is the spec sequence with `ATH1`.
7. Calibration is the first phase of a started recording, so its samples are
   in the file.
8. Concurrency conventions (§4.0).
9. Frozen fixture suites assert only facts about their own version;
   "current state" assertions moved to `LogFormatCurrentStateTests`.
10. `LogFileWriter` creates files exclusively; `LogFileName` takes a
    `collisionIndex`; write-failure behaviour is defined (§4.3).

Inputs: `CLAUDE.md` (wins on conflict), `docs/SPEC_V1.md`, `WORKFLOW.md`,
`docs/LOG_FORMAT.md`, `.claude/skills/elm327-protocol/SKILL.md`, all of `Core/`.

---

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

## 2. Milestones

Same shape as `WORKFLOW.md`; this section pins down deliverables, folder
ownership and acceptance.

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

### M5 — drives
City drive, then highway + jammed-GPS area. Done = 3 consecutive GOOD verdicts, one ≥ 1 h with the screen locked. Tag `logger-v1`.

---

## 3. Log format v2

### 3.1 Why v2, not v1

Three changes cannot be made inside v1 without breaking the rules in CLAUDE.md:

1. **`obd.raw` changes meaning.** v1 wrote header-off replies (`410D32`). The spec
   requires `ATH1`, so the same field would start holding `7E803410D32`. Same
   key, different shape = repurposing a field, which is forbidden.
2. **New fields on existing kinds and the header.** A v1-era reader would decode
   a file with new keys and silently drop them on re-export (`JSONDecoder` ignores
   unknown keys). Bumping the header version makes an old build refuse the file
   instead, which is the documented behaviour.
3. **Header semantics.** The header now describes the adapter and polling
   configuration that is needed to interpret `obd` rows.

New *kinds* alone would have fitted v1 (old readers park them in
`.unrecognized`), but they ship together with the above, so everything goes into
v2 at once.

How v1 stays readable: every v2 addition is optional in the Swift types, so a v1
file decodes into the same structs with the new fields `nil`. One set of types,
one decoder, no migration code. The writer always emits v2.

**Test file edits this requires — please approve explicitly.**
`LogFormatCompatibilityTests` holds the frozen v1 fixture. The fixture string and
every v1 value assertion stay byte-for-byte untouched. Three *assertions about
the current state* must change, because they assert "there is only v1 / four
kinds":
- `allVersionsAreReadable`: `[.v1]` → `[.v1, .v2]`
- `writesCurrentVersion`: `"formatVersion":1` → `"formatVersion":2`
- `kindStringsAreStable`: keep the four existing asserts, add the nine new ones, count 4 → 13

Plus a new frozen `version2Recording` fixture and tests in the same file.

**Naming clash to avoid.** `preservesUnknownEventKinds` uses a made-up future kind
called `barometer`. If the real barometer kind were named `barometer`, that test
would start decoding it as known and fail. The real kind is `baro`, which also
keeps 100 Hz lines short.

### 3.2 Conventions (all kinds)
- Every timestamp field is **Int64 nanoseconds on the session clock**, same base as `t`. Names end in `T` (`requestT`, `receivedT`).
- Units follow the source framework (CoreMotion g, rad/s, µT; CoreLocation m, m/s, degrees; OBD native units). No conversion at record time.
- Optional fields are omitted when absent, never written as `null`.
- Strings that come off the wire (`raw`, `rx`, `tx`) are verbatim, minus only the trailing `>` prompt.

### 3.3 Header (v2 additions, all optional)

| Field | Type | Meaning |
|---|---|---|
| `adapter.name` | String | BLE advertised name |
| `adapter.identifier` | UUID string | `CBPeripheral.identifier` |
| `adapter.gatt` | `{service, notify, write, writeType, maxWriteLength}` | UART pair actually used; `writeType` = `withResponse` / `withoutResponse` |
| `adapter.gattTable` | `[{service, characteristics:[{uuid, properties:[String]}]}]` | Full discovered table |
| `adapter.elmVersion` | String | `ATZ` banner, e.g. `ELM327 v2.1` |
| `adapter.protocol` | String | Raw `ATDPN` reply, e.g. `A6` |
| `adapter.voltage` | Double, V | Parsed `ATRV` (raw reply is in the `elm` row) |
| `polling.command` | String | Exact poll command, e.g. `010D0C1` |
| `polling.pids` | [Int] | PIDs covered by `command` |
| `polling.multiPID` | Bool | Multi-PID request in use |
| `polling.responseCount` | Int? | Count suffix in use (`1`) or absent |
| `polling.adaptiveTiming` | Int | `ATAT` level 0/1/2 |
| `polling.rpmEvery` | Int | RPM polled every Nth cycle (single-PID mode) |
| `polling.timeoutMs` | Int | Per-command timeout |
| `sensors` | `{deviceMotionHz, accelerometerHz, gyroHz, magnetometerHz, referenceFrame, altimeter}` | Requested configuration |
| `mount` | String | Mount note from the checklist |
| `vehicle` | String | Vehicle note |
| `timeZone` | String | `TimeZone.current.identifier`, captured once — for display/export only |

Adapter info is only known after init, but the header is line 1. **Decision:**
Start is enabled when the link is `polling`, so the header carries the init
result. Starting without OBD is allowed as an explicit choice; then `adapter` and
`polling` are absent. Every later re-init writes an `adapter` event (below), so
reconnects mid-drive are captured too.

### 3.4 Event kinds — final names, frozen at "contracts"

| `kind` | `t` is | `data` fields (units) | Rate |
|---|---|---|---|
| `motion` *(v1)* | `CMDeviceMotion.timestamp` | v1 fields unchanged: `userAcceleration` g, `gravity` g, `rotationRate` rad/s, `attitude` quaternion, `magneticField` µT?; **v2 adds** `magneticAccuracy` Int? (−1…2, `CMMagneticFieldCalibrationAccuracy`) | 100 Hz |
| `accel` | `CMAccelerometerData.timestamp` | `x`,`y`,`z` g, raw (gravity included) | 100 Hz |
| `gyro` | `CMGyroData.timestamp` | `x`,`y`,`z` rad/s, raw (not bias-corrected) | 100 Hz |
| `mag` | `CMMagnetometerData.timestamp` | `x`,`y`,`z` µT, raw uncalibrated | ~10 Hz |
| `baro` | `CMAltitudeData.timestamp` | `pressureKPa` kPa, `relativeAltitude` m | ~1 Hz (device-driven) |
| `location` *(v1)* | **fix time** on the session clock (see below) | v1 fields unchanged; **v2 adds** `receivedT` ns, `fixTime` ISO 8601 (raw `CLLocation.timestamp`), `ageS` s, `ellipsoidalAltitude` m?, `simulated` Bool?, `accessory` Bool? (`CLLocationSourceInformation` — useful under spoofing) | ~1 Hz |
| `obd` *(v1)* | reply received | v1 fields unchanged (`pid`, `value`, `unit`, `raw`); **v2 adds** `requestT` ns, `command` String, `ecu` String? (`7E8`), `seq` Int. `raw` = full verbatim reply incl. headers and all ECUs. One row per PID per answering ECU. | poll rate |
| `elm` | reply complete / timeout fired | `seq` Int, `phase` (`init`/`probe`/`poll`/`manual`/`keepalive`), `tx` String, `requestT` ns, `rx` String? (absent on timeout), `outcome` (below) | every exchange |
| `adapter` | init finished | Same shape as header `adapter` + `polling`; written after every successful (re-)init | rare |
| `link` | transition | `layer` (`ble`/`elm`), `from`, `to` (state names, §4.2), `reason` String? | rare |
| `lifecycle` | event | `event` (`start`, `stop`, `background`, `foreground`, `calibrationStart`, `calibrationEnd`, `pause`, `resume`, `error`, `memoryWarning`, `thermalState`, `protectedDataUnavailable`, `lowDiskSpace`), `detail` String? | rare |
| `stats` | end of window | `windowS` s, `counts` {kind: Int}, `obdHz`, `motionHz`, `gaps` {`motion`/`accel`/`gyro`: count of intervals > 50 ms}, `maxGapMs` {same keys}, `timeouts` Int, `queueDepthMax` Int, `dropped` Int, `bytesWritten` Int | 0.1 Hz |
| `marker` *(v1)* | tap | String, unchanged | user |

`elm.outcome` values: `ok`, `noData`, `timeout`, `stopped`, `notRecognised`,
`canError`, `busError`, `busInitError`, `bufferFull`, `dataError`,
`unableToConnect`, `adapterError`, `malformed`, `rejected` (blocked by the
read-only guard — it never left the phone).

`elm` rows are written for **every** exchange, including successful polls, so
the raw traffic is complete in one place; `obd` rows are the decoded view and
reference it by `seq`. The duplication costs ~3 KB/s against ~75 KB/s of motion.

**GPS fix time — needs your call.** `CLLocation.timestamp` is a wall-clock
`Date`. To put the fix on the session clock, the plan computes
`ageS = Date().timeIntervalSince(location.timestamp)` at receipt and sets
`t = receivedT − ageS`. That is a `Date()` per location sample. It does not break
the intent of the invariant — it is a difference of two wall-clock readings taken
microseconds apart, so NTP jumps during the drive cancel out, and nothing is
*stamped* with wall time — but it is a literal exception to "never call `Date()`
per sample". The raw `fixTime` is kept too, so it can be redone offline. The
alternative (`fixTime − header.startedAt`) inherits every clock jump, which is
exactly what the invariant forbids.

### 3.5 Files
- `Documents/logs/Drive_<yyyyMMdd-HHmmss>.jsonl.gz`, local time from the header wall clock.
- **gzip without any dependency.** Core may only import Foundation, and Foundation has no streaming gzip. `NSData.compressed(using: .zlib)` (raw DEFLATE, available iOS 13 / macOS 10.15) compresses one flush worth of lines; the writer wraps it in a gzip **member** (header + CRC-32 + ISIZE) and appends it. Concatenated members are a valid gzip file (`gunzip`, Python `gzip` read it as one stream). Each member carries its compressed length in a gzip `FEXTRA` subfield, as BGZF does, so our reader can slice members without a streaming inflater.
- Consequence: a crash or flat battery loses at most the unflushed buffer (≤ 2 s) plus a partial last member, which the reader detects and drops. Inside a decoded member a half-written line can't happen; `skipMalformedLines` still applies for robustness.
- Flush triggers: every 2 s, on stop, on `didEnterBackground`, on memory warning.
- Verify in M1 (test): output passes `gzip -t` and round-trips through `/usr/bin/gunzip`.

---

## 4. Contracts

Placement rule: anything Foundation-only goes in Core so it is tested by `swift
test`; anything touching CoreBluetooth / CoreMotion / CoreLocation / UIKit lives
in App.

### 4.0 Concurrency conventions (Swift 6, iOS 17)

`Mutex` and the atomics module need iOS 18, and Core may only import
Foundation, so:
- Prefer an **actor** when the type's API can be async (`ELMSession`,
  `LogFileWriter`, `MockELMAdapter`).
- A `Sendable` final class that must be called synchronously from any thread
  (`LogSink`, `BLETransport`) keeps its mutable state in
  `private nonisolated(unsafe) var` properties guarded by one `NSLock`, with a
  comment at each declaration naming the lock. Thread-safe Foundation and
  stdlib types (`AsyncStream.Continuation`) need no lock. Never put
  `@unchecked Sendable` on the whole type.
- `SensorSource` is `@MainActor`; framework callbacks are explicit `@Sendable`
  closures capturing only `clock` and `sink`. A non-Sendable closure in a
  main-actor method is inferred main-actor isolated and traps when CoreMotion
  calls it off the main thread.

The signatures below summarise what is committed in code. Where they differ,
the code wins.

### 4.1 ELM transport (Core, `ELM327/ELMTransport.swift`)

```swift
/// A chunk as delivered by the radio, stamped where it arrived — in the BLE
/// delegate callback, before any actor hop adds latency.
public struct ELMChunk: Sendable { public var bytes: Data; public var uptime: Double }

public protocol ELMTransport: Sendable {
    /// Writes one complete command (CR-terminated). Splits to the link's max
    /// write length. Returns the uptime at which the write was issued.
    func send(_ command: ValidatedELMCommand) async throws -> Double
    /// Every inbound fragment, in order. Finishes when the link drops.
    var incoming: AsyncStream<ELMChunk> { get }
}
```

`ELMFramer` (struct): `mutating func append(_ chunk: ELMChunk) -> [ELMRawReply]`,
where `ELMRawReply { text: String; completedUptime: Double }` — accumulates until
`>`, strips NUL and the prompt.

### 4.2 ELM session (Core, `ELM327/ELMSession.swift`)

```swift
public struct ValidatedELMCommand { public let wire: String; public var wireData: Data }  // internal init

public enum ELMCommandPolicy {
    public enum Scope { case session, manual }
    /// Allowlist. Printable ASCII only, checked before uppercasing.
    /// .session: ATZ ATI AT@1 ATE0/1 ATL0/1 ATS0/1 ATH0/1 ATSP0 ATDP ATDPN ATRV
    ///           ATAT0-2, plus mode 01. (ATST was dropped in M1.)
    /// .manual:  ATI AT@1 ATDP ATDPN ATRV, plus mode 01 (the debug console).
    /// Mode 01: 01 + 1–6 PID bytes + optional count digit 1–9.
    public static func validate(_ wire: String, scope: Scope) throws(ELMSessionError) -> ValidatedELMCommand  // scope required
}

public enum ELMState: String { idle, resetting, initialising, searching, probing, ready,
                               polling, retrying, reinitialising, failed }   // written into `link` rows

public struct ELMExchange {        // → `elm` row
    seq, phase: ELMPhase, tx, requestUptime, rx: String?, completedUptime, outcome: ELMOutcome
}
public struct OBDReading {         // → `obd` row
    seq, command, ecu: String?, measurement: OBDMeasurement, raw, requestUptime, replyUptime
}
public struct PollingPlan { pids, multiPID, responseCount: Int? /* 1–9 */, adaptiveTiming, rpmEvery, timeout
                            func validate() throws(ELMSessionError)        // 1–6 distinct PIDs, ranges
                            var primaryCommand: ELM327Command }            // wireFormat = recorded polling.command
public struct ELMAdapterInfo { elmVersion, protocolNumber, voltage, supportedPIDs: String?, plan }

/// Every case carries the uptime at which it happened.
public enum ELMSessionEvent {
    case state(from: ELMState, to: ELMState, reason: String?, uptime: Double)
    case exchange(ELMExchange)
    case reading(OBDReading)
    case adapter(ELMAdapterInfo, uptime: Double)
    case pollRate(hz: Double, uptime: Double)      // display only
    case needsReconnect(uptime: Double)            // always preceded by .state(to: .failed)
}

public actor ELMSession {
    public init(transport: any ELMTransport,
                configuration: ELMSessionConfiguration = .default,   // timeouts, retry N, re-init N
                uptime: any UptimeSource = SystemUptimeSource(),     // stamps events
                clock: any Clock<Duration> = ContinuousClock(),      // timeouts only, injectable
                firstSeq: Int = 0,                                   // = previous session's nextSeq
                rememberedPlan: RememberedPollingPlan? = nil)        // = previous session's, same adapter (M6.1-3)
    public nonisolated let events: AsyncStream<ELMSessionEvent>     // single consumer
    public private(set) var state: ELMState
    public private(set) var nextSeq: Int
    public private(set) var rememberedPlan: RememberedPollingPlan?   // plan + ATZ banner, for the next session
    /// ATZ → ATE0 → ATL0 → ATS0 → ATH1 → ATSP0 → 0100 (10 s) → ATDPN → ATRV,
    /// then probes multi-PID / count suffix and picks the first that parses; keeps ATAT1
    /// unless ATAT2's median is ≥ 10% lower over 10 samples each (M4). With a fitting
    /// rememberedPlan: ATAT<n> + one check poll instead; selection only if the check fails.
    public func initialise() async throws(ELMSessionError) -> ELMAdapterInfo
    public func startPolling(_ plan: PollingPlan) throws(ELMSessionError)
    public func stopPolling() async
    /// Debug console, `scope: .manual`; queued between polls so only one command is in flight.
    public func sendManual(_ command: String) async throws(ELMSessionError) -> ELMExchange
    public func shutdown() async
}
```

Timestamps: the session records **uptimes** (from the transport for receive,
from `send` for request, from its own `UptimeSource` for state changes,
timeouts and rejections). `RecordingSession` converts with
`clock.timestamp(uptimeSeconds:)`. That is the same base as `clock.now()` and
lets the link run before a recording exists (pre-drive init).

`MockELMAdapter: ELMTransport` (Core actor, library, not test-only so the
simulator app can use it): rules of `(command, reply?, delay, fragmentSizes)`,
plus canned Touareg rules (headers on, two ECUs, multi-PID supported,
`NO DATA` for 0x0F).

Parser additions (`ELM327ResponseParser`): `replies(in:headers:) -> [ECUReply]`
with `ECUReply { header: String?; bytes: [UInt8] }`;
`OBDDecoder.decode(requested:bytes:) -> [OBDMeasurement]` for multi-PID;
`textReply(to:raw:) -> ELMTextReply` for `OK` / banner / `ATDPN` / `ATRV`.
`ELM327Command` gains `.adaptiveTiming(Int)`, `.supportedPIDs`,
`.currentData(OBDPID)` and `.currentDataMany(_:responseCount:)`; `.raw` and
`.request(mode:pid:)` are removed; `handshake` is the spec sequence.

### 4.3 Log writer / reader (Core, `Log/`)

```swift
/// Non-blocking front door for 300+ events/s from sensor callbacks
/// (AsyncStream continuation + NSLock-guarded counters, §4.0).
public final class LogSink: Sendable {
    public func record(_ event: LogEvent)
    public var queueDepth: Int { get }
    public var dropped: Int { get }
}

public actor LogFileWriter {
    /// open(O_WRONLY|O_CREAT|O_EXCL|O_APPEND|O_CLOEXEC) (throws .fileExists),
    /// protection .completeUntilFirstUserAuthentication. Below either threshold it
    /// still creates the file and writes the header, then delivers its notices.
    /// Precondition: stopFreeBytes < warningFreeBytes.
    public init(url: URL, header: LogHeader, flushInterval: Duration = .seconds(2),
                warningFreeBytes: Int64 = DiskSpacePolicy.defaultWarningFreeBytes,  // 200 MB
                stopFreeBytes: Int64 = DiskSpacePolicy.defaultStopFreeBytes,        // 50 MB
                diskSpace: any DiskSpaceProvider = VolumeDiskSpaceProvider()) throws(LogWriteError)
    init(handle: sending any LogFileHandle, url:, header:, …)    // internal test seam
    public nonisolated let sink: LogSink
    public nonisolated let failures: AsyncStream<LogWriteError>          // write failures only
    public nonisolated let diskSpaceNotices: AsyncStream<DiskSpaceNotice> // advisory, single consumer
    public func flush() async throws(LogWriteError)   // failed member truncated away, retried later;
                                                      // free space never makes it throw
    public func finish() async -> LogFileSummary      // final write regardless of free space;
                                                      // always closes; reports unwrittenEvents + failure
    public var bytesWritten: Int { get }
    /// Added in M2 part 2: the writer owns the `StatsAccumulator` (it is the one
    /// place every event passes, in write order) and fills in peak queue depth
    /// (measured at every `record`), drops and bytes written.
    public func closeStatsWindow(at end: MonotonicTimestamp) async -> StatsSample
}

public protocol DiskSpaceProvider: Sendable { func availableBytes(for url: URL) throws -> Int64 }
public struct VolumeDiskSpaceProvider: DiskSpaceProvider   // ForImportantUsage, else volumeAvailableCapacity

public enum DiskSpaceNotice: Hashable, Sendable {
    case low(availableBytes: Int64)        // below warningFreeBytes: warn, keep recording
    case critical(availableBytes: Int64)   // below stopFreeBytes: clean stop
}

/// Pure reporting rule, implemented and tested at M0: two edge-triggered monitors.
public struct DiskSpacePolicy: Hashable, Sendable {
    public static let defaultWarningFreeBytes: Int64 = 200_000_000
    public static let defaultStopFreeBytes: Int64 = 50_000_000
    public init(warningFreeBytes: Int64 = …, stopFreeBytes: Int64 = …,   // precondition stop < warning
                hysteresisBytes: Int64 = LowDiskSpaceMonitor.defaultHysteresisBytes)
    public mutating func observe(availableBytes: Int64) -> [DiskSpaceNotice]   // [.low, .critical] order
    public static func canStart(availableBytes: Int64, warningFreeBytes: Int64 = …) -> Bool  // >= warning
}
public struct LowDiskSpaceMonitor: Hashable, Sendable {   // one threshold, used twice by the policy
    public static let defaultHysteresisBytes: Int64 = 50_000_000
    public init(thresholdBytes: Int64, hysteresisBytes: Int64 = defaultHysteresisBytes)
    public mutating func observe(availableBytes: Int64) -> Bool   // true on a crossing
}

/// Internal: the writer's only access to the file, so M1 tests can inject faults.
protocol LogFileHandle: AnyObject {
    func endOffset() throws(LogFileHandleError) -> Int64   // where the next write lands
    func write(_ data: Data) throws(LogFileHandleError)    // a prefix may land before an error
    func truncate(to offset: Int64) throws(LogFileHandleError)
    func sync() throws(LogFileHandleError)
    func close() throws(LogFileHandleError)
}
final class POSIXLogFileHandle: LogFileHandle   // init(creatingExclusively:) throws(LogWriteError)

public final class LogFileReader: Sequence {        // streaming, member by member
    public init(url: URL, recovery: LogRecovery = .skipMalformedLines) throws
    public let header: LogHeader
    public var report: LogReadReport { get }        // members, truncatedTail, skipped line indices
}

public enum LogFileName {
    public static func make(for start: Date, timeZone: TimeZone, collisionIndex: Int = 1) -> String
}
```

**Low disk space is advisory and separate from failures.** A `DiskSpaceNotice`
never blocks, delays or fails a write, and is delivered only on
`diskSpaceNotices`; `failures` carries real write failures only. Free space is
read after the header in `init` and before every flush attempt; `finish()` does
not check it. Each reading goes through one `DiskSpacePolicy`: `.low` once when
free space goes strictly below `warningFreeBytes`, `.critical` once when it
goes strictly below `stopFreeBytes` (both, `.low` first, from a single reading
below both). Each threshold re-arms independently, only after free space has
risen strictly above that threshold + `hysteresisBytes` (default 50 MB).
Exactly at a threshold is not below it. A throwing provider skips that check
without a report. The writer only reports; the policy that acts on notices is
`RecordingSession`'s (§4.6).

**File position: `O_APPEND`, one rule.** Every write lands at end of file; the
writer never seeks. Before a member it records the start offset
(`endOffset()`); on a failed or short write it `ftruncate`s to that offset and
the retry appends there, so no zero gap and no partial member can sit between
members. If `ftruncate` fails, the writer never appends again: it closes the
file, reports `.writeFailed` on `failures`, later `flush()` calls throw it, and
`finish()` returns it with the unwritten count. A reader then sees every
complete member and `truncatedTail == true`.

M1 tests required by this contract (fault-injecting `LogFileHandle` wrapping
`POSIXLogFileHandle`):
- short write / `ENOSPC` on member N (some bytes and zero bytes), then a
  successful retry → file passes `gzip -t`, every member decodes, every event
  appears once in order, each member starts (`1f 8b`) where the previous one
  ended and the last ends at EOF (no zero bytes between members);
- partial write of member N, then `ftruncate` fails → the file never grows
  again (no member after the partial one), `.writeFailed` on `failures` once,
  `finish()` reports it with the right `unwrittenEvents`, reader returns
  members 0..<N with `truncatedTail == true`;
- fake `DiskSpaceProvider` → `init` below the warning threshold writes the
  header and delivers `.low` once; a later reading below the floor delivers
  `.critical` once; `init` below both delivers `[.low, .critical]`; later
  flushes still write without re-reporting; `finish()` below the floor writes
  its final member; nothing appears on `failures`.

One `LogCodec` lives inside `LogFileWriter` and one inside each reader (CLAUDE.md).
Queue policy: unbounded, because dropping is data loss; depth is reported every
10 s and a warning `lifecycle` row is written if it exceeds 2 s of data.
What `RecordingSession` does with disk-space notices and write failures is
stated once, in §4.6 ("warn, then stop at a floor").

### 4.4 Sensor sources (protocol in Core `Recording/`, real ones in App)

```swift
public enum SensorAvailability: Sendable, Hashable { case available, unavailable(reason: String) }

@MainActor public protocol SensorSource: AnyObject {
    var name: String { get }
    var availability: SensorAvailability { get }
    /// Starts delivering events stamped with `clock` into `sink`, off the main actor.
    func start(clock: SessionClock, sink: LogSink) throws
    func stop()
}
```

Core: `SimulatedMotionSource`, `SimulatedLocationSource` (deterministic,
for previews and the simulator). App: `DeviceMotionSource`, `RawIMUSource`
(accel + gyro + mag), `AltimeterSource`, `ReferenceLocationSource` (renamed
from `LocationSource` in M2 so nobody mistakes it for an input;
`CLLocationManager`, `kCLLocationAccuracyBest`, activity `otherNavigation`,
`allowsBackgroundLocationUpdates`, no auto-pause, plus
`CLBackgroundActivitySession` while recording), and `SimulatedMagBaroSource`
(the simulator's mag + baro). `SensorSuite.makeDefault()` picks the real ones
on a device and the simulated twins on the simulator. CoreMotion sources stamp
with `clock.timestamp(uptimeSeconds: item.timestamp)`; the location source
stamps fixes per §3.4. Every source delivers through a `SampleGate`, so no
event reaches the sink after `stop()` returns.

`StatsAccumulator` (Core, struct): `mutating func observe(_ event: LogEvent)`,
`mutating func closeWindow(at:queueDepthMax:dropped:bytesWritten:) -> StatsSample`.
Pure, fully unit-tested.

`EventMapping` (Core): `LogEvent.rows(for: LinkEvent, adapter:clock:)` plus the
per-row initialisers `LogEvent(exchange:clock:)`, `LogEvent(reading:clock:)`,
`LogEvent(elmTransitionFrom:to:reason:uptime:clock:)`,
`LogEvent(bleTransitionFrom:to:reason:uptime:clock:)` and
`LogEvent(adapter:info:uptime:clock:)` — the one place link runtime types
become format types. `LinkEvent` = `.ble(from:to:reason:uptime:)` |
`.session(ELMSessionEvent)`.

### 4.5 OBDLink service (App, `Link/`)

```swift
@MainActor protocol OBDLinkServicing: AnyObject, Observable {
    var state: OBDLinkState { get }                   // unavailable/idle/scanning/connecting/…/polling(protocol, voltage)
    var discovered: [DiscoveredAdapter] { get }       // id, name, RSSI
    var rememberedAdapterID: UUID? { get }
    var adapter: AdapterRecord? { get }               // BLE + ELM info merged, for the header
    var plan: PollingPlan? { get }
    var pollHz: Double { get }
    var console: [ConsoleLine] { get }                // bounded, for the debug screen
    func startScan(); func stopScan()
    func connect(to id: UUID); func disconnect(); func forget()
    func sendManual(_ command: String) async throws(ELMSessionError) -> ELMExchange   // scope .manual
    func linkEvents() -> AsyncStream<LinkEvent>       // BLE transitions + ELM session events
}
```

`OBDLinkService` (CoreBluetooth, restore identifier, reconnect with backoff,
each new `ELMSession` seeded with the previous `nextSeq` and, on the same
adapter, its `rememberedPlan`; `lastInitEvents` only while connected) and
`SimulatedOBDLink` (wraps `MockELMAdapter`; chosen automatically on the
simulator). Only `BLETransport.send` may call `writeValue`
(`RepositoryInvariantTests`).

### 4.6 RecordingSession orchestrator (App, `Recording/`)

```swift
@MainActor @Observable final class RecordingSession {
    init(link: any OBDLinkServicing, sources: [any SensorSource], store: LogStore,
         uptime: any UptimeSource = SystemUptimeSource())
    // init also takes diskSpace: any DiskSpaceProvider, warningFreeBytes (200 MB),
    // stopFreeBytes (50 MB); the thresholds are passed unchanged to LogFileWriter.
    private(set) var state: RecordingState    // idle / calibrating / recording / stopping / failed(reason:unwrittenEvents:)
    private(set) var live: LiveStatus         // obdSpeed, gpsSpeed, obdHz, motionHz, elapsed, fileBytes,
                                              // lowDiskSpaceWarning, availableDiskBytes
    private(set) var lastStopReason: RecordingStopReason?   // .user / .lowDiskSpace
    private(set) var backgroundRiskWarning: String?         // R4.1-5: no background location session; not a blocker
    var canStart: Bool { get }                // startBlocker == nil
    var startBlocker: RecordingStartBlocker? { get }   // .lowDiskSpace(availableBytes:requiredBytes:) / .obdNotReady
    /// Starts clock, file and sources, then runs calibration as the first phase.
    /// Throws RecordingStartBlocker.lowDiskSpace below the warning threshold.
    func start(mount: String, vehicle: String, allowWithoutOBD: Bool,
               calibration: Duration = .seconds(5)) async throws
    func mark(_ text: String)
    func stop(reason: RecordingStopReason = .user) async
    func handleScenePhase(_ phase: ScenePhase)   // background/foreground rows + flush
    func handleMemoryWarning()                   // row + flush
}
```

Owns the single `SessionClock` per recording, the `LogFileWriter`, the stats
timer, and the `isIdleTimerDisabled` toggle.

**Disk space: warn, then stop at a floor** — the recorder's one low-disk
policy (the doc comment on `RecordingSession` is authoritative):
1. `.low` (below 200 MB): `lifecycle` `lowDiskSpace` row, detail
   `"warning: <bytes> free"`; UI warning via `live.lowDiskSpaceWarning`; keep
   recording.
2. `.critical` (below 50 MB): `lifecycle` `lowDiskSpace` row, detail
   `"floor: <bytes> free"`, then `stop(reason: .lowDiskSpace)` — the normal
   stop path, not `failed`: `stop` row with detail `"lowDiskSpace"`, final
   `stats` row, `finish()`, back to `idle`, `lastStopReason = .lowDiskSpace`.
3. Start is refused below the warning threshold (`DiskSpacePolicy.canStart`):
   `canStart == false`, `startBlocker == .lowDiskSpace(…)`; `start` re-checks
   and throws it before creating anything. An unreadable volume does not
   block start.
4. A write failure on `failures` (`ENOSPC`, I/O error): `lifecycle` `error`
   row, `finish()`, `failed(reason:unwrittenEvents:)` — so the user sees it
   even if the row never reached the disk. The only way into `failed`,
   including when the final `finish()` of any stop (user or rule 2) fails;
   then no further row is written (R3-3).

`LogStore` lists, sizes and deletes files in `Documents/logs`, and picks a
file name that doesn't exist yet (R3-6: split back out of rule 4).

M2 part 2 additions (the code is authoritative): `start` also throws
`RecordingStartBlocker.recordingInProgress`; `startBlocker` is derived from a
stored `availableDiskBytes` refreshed off the main actor (R3-5) and from
`allowsRecordingWithoutOBD`; `deleteRecording(_:)` and `refreshDiskSpace()`;
`init` also takes the header's `sensorConfiguration` and `notes`, and test
intervals. The session subscribes to `linkEvents()` once, in `init`, for the
app's lifetime. `AppServices` creates the link and the session once at launch
(`DriveLoggerApp`), which forwards scene phase and memory warnings.

### 4.7 `inspect_log` (Core package, executable target)

`swift run inspect_log <file> [--csv <dir>] [--strict]` — header, events per
kind, rates, gaps > 50 ms, OBD latency (`t − requestT`) percentiles, `elm`
outcome counts, damage/truncation report, CSV per kind. The analysis lives in
Core (`RecordingAnalyzer`, `RecordingCSVExporter`) so `swift test` covers it;
`main.swift` only parses arguments. Foundation only, so it passes the import
check. Exit status 0 read, 1 unreadable, 2 usage.

---

## 5. Decisions needing your approval

1. **Format v2** (§3.1), including the three assertion edits in `LogFormatCompatibilityTests` — fixture string untouched.
2. **GPS fix time** via `Date()`-based age at receipt (§3.4).
3. **Start requires OBD `polling`** unless "record without OBD" is chosen explicitly (§3.3).
4. **gzip via concatenated members** built on `NSData.compressed(using: .zlib)`, no third-party code (§3.5).
5. **`MockELMAdapter` and simulated sensor sources ship in the Core library**, not only in tests, so the simulator app runs end to end.
6. **`elm` rows for every exchange**, including successful polls (§3.4).
7. **`inspect_log` lives in the Core package** (`Core/Sources/inspect_log`) rather than a separate `tools/` package, so it shares Core without a second `Package.swift`.

## 6. Hardware checks (M4/M5), not claimable before

### Resolved by the bench test (2026-10-07, Car Scanner terminal, `docs/BENCH_TEST_2026-10-07.md`)
- **Protocol:** `ATDPN` = `6`, ISO 15765-4 CAN 11-bit 500 kbaud. Expect `A6` after the app's own `ATSP0`.
- **Adapter:** `ELM327 v2.3`; BLE name `IOS-Vlink`.
- **Two ECUs answer functional requests:** `7E8` (engine) and `7E9` (gearbox, most likely). Handled by `ATSH7E0` (gated, see the status block) with the functional fallback, and speed is taken from `7E8`. Under functional addressing the `1` suffix returned `7E9`'s reply, so the suffix is used only with `ATSH7E0`.
- **Multi-PID works:** `010D0C` / `010D0C1` → speed and RPM in one frame (663 rpm at idle).
- **OBDonUDS (`22F40D`) not needed:** `NO DATA`, while mode 01 works.

### Resolved by the M4 bench test (2026-10-08, our app, `docs/BENCH_TEST_2026-10-08.md`)
- **GATT:** Vgate layout `E7810A71-…` / `BEF8D6C9-…` (one characteristic, notify + write), `withResponse`, `maxWriteLength` 182. No write failures.
- **Poll plan and Hz:** `010D0C1` with `requestHeader` `7E0`; 16.4–16.5 exchanges/s, p50 latency 59 ms, p95 74 ms; `7E8` replies only. `ATDPN` → `A6` after our `ATSP0`; `ATSH7E0` → `OK` (re-init; start-up init not in the file).
- **`ATAT1` vs `ATAT2`:** no difference in steady state (59 ms median, 16.4 Hz either way); `ATAT2` does not cut replies short.
- **Lock:** 165 s locked (not 5 min) with no loss in any kind and `stats` every 10 s.
- **Unplug/replug:** BLE timeout → one reconnect attempt → connected +23.1 s → re-init with `ATSH7E0` → polling +30.3 s; `seq` continuous.
- **Also:** `ATZ` banner `ELM327 v2.3`; `ATRV` 12.2 V / 11.8 V; write-off/re-init only from the unplug; no `7E9` under physical addressing.
- **Still open from it:** start-up init not recorded; location `Code=1` error with no authorization info (both fixed in M4). The ≥ 5 min lock was not run; by the user's decision it is superseded by M5's ≥ 1 h screen-locked drive.

### Still open (M4 unless noted)
- **Real poll Hz** of `010D0C1` after `ATSH7E0`, and which plan start-up selection picks with our own init (the bench used Car Scanner's init).
- **`ATAT1` vs `ATAT2`:** which is faster and stable, and whether `ATAT2` cuts replies short.
- **Background survival:** 5+ minutes locked with BLE + location (M4); ≥ 1 h locked on a drive (M5).
- **GATT:** actual Vgate layout and max write length.
- From the bench update, also to confirm with our app: `ATSH7E0` → `OK` after our handshake; only `7E8` replies under physical addressing while driving; how often write-offs and re-inits happen; `ATRV` under-reads (11.0 / 11.8 V).

### Added by M2 part 1 (BLE transport, link service) — none of this is verified; the simulator has no Bluetooth
- **Scan / pick:** `IOS-Vlink` appears in the list (named advertisers only, likely adapters sorted first); picking it connects; the identifier is remembered and a relaunch reconnects without a scan.
- **GATT detection:** which layout `GATTDetection` picks on the Vgate (`vgate`, `fff0`, `ffe0` or `generic` — console line `ble: discovering → connected (…)`), the full `gattTable` in the header, and whether notifications on the chosen characteristic actually carry the replies.
- **Write type and length:** `adapter.gatt.writeType` (we prefer `withResponse` when offered) and `maxWriteLength` (capped at the without-response length, expected 20 on BLE 4.0 unless the MTU is negotiated up). Check that acknowledged writes don't produce `ble: write failed` lines, and compare poll Hz with `withoutResponse` if both are offered.
- **Write splitting:** no command is longer than 20 bytes today, so splitting only runs on a smaller MTU; if `maxWriteLength` < 9 is ever seen, confirm split commands are answered.
- **Timestamps:** OBD reply uptime is taken first thing in `didUpdateValueFor` on the private BLE queue; check `inspect_log` OBD latency is plausible (tens of ms) and not dominated by main-thread stalls.
- **State restoration:** with a recording running and the app terminated by the system (not swiped away), the app relaunches, a `ble` `restoring` row appears and polling resumes. Note: restoration only works if `OBDLinkService` (via `OBDLinkFactory.makeDefault()`) is created at launch — part 2 / M3 wiring.
- **Reconnect:** unplug/replug the adapter while recording → `connected → disconnected → reconnecting → connecting → discovering → connected`, a new `ATZ` handshake with `ATSH7E0`, polling resumes, `seq` continues without repeats. Also Bluetooth off/on in Control Centre (→ `unavailable`, then reconnect). Backoff is 1 s doubling to 30 s; the pending connect never times out.
- **needsReconnect:** if a session ever gives up (`elm` `failed` + reconnect), confirm the BLE cancel/reconnect cycle restores polling.
- **`ATSH7DF` refusal (R2.2-3):** whether the Vgate ever refuses or drops `ATSH7DF`; if a note `physical addressing disabled for this session` appears, record when.
- **Desynchronised console:** after a manual command times out, the console shows `link desynchronised …` and the link re-initialises; nothing is sent in between but `ATZ`.

### Added by review run 3, round 1 (R3.1-1, R3.1-2, R3.1-3, R3.1-7) — not verified; the simulator has no Bluetooth
- **Bluetooth off/on and bluetoothd reset (R3.1-2):** while recording, toggle Bluetooth off/on, in Settings and in Control Centre (which may only disconnect accessories rather than power the radio off; note which `unavailable` reason, if any, each one logs), and confirm `unavailable` → `idle` → `connecting` → … → `connected` and polling resume. If possible, also force a bluetoothd reset (`resetting` state, e.g. a sysdiagnose or a Bluetooth crash) and confirm the reconnect completes rather than sitting in `connecting`: below `poweredOff` every retained `CBPeripheral` is dropped and the identifier is retrieved again.
- **Re-enabling notifications after restoration (R3.1-7):** whether `setNotifyValue(true)` on a characteristic that is already notifying (an adopted, restored connection) still calls `didUpdateNotificationStateFor`. If it doesn't, the link stays in `discovering` forever.
- **Cancel → `didDisconnect` latency (R3.1-3):** on a live link and on a dead one (adapter unplugged), how long after `cancelPeripheralConnection` the disconnect callback arrives, compared with the 1 s first reconnect backoff. A late one shows up as a spurious extra `disconnected → reconnecting` cycle.
- **Write type and write stalls (R3.1-1):** which write types the Vgate's write characteristic offers (`write`, `writeWithoutResponse`, both) and, if `withoutResponse` is used, whether `canSendWriteWithoutResponse` ever stays false for the 1 s readiness timeout (`init failed: transport(writeFailed(…))` or `write failed: …` in the console). A write failure during the handshake must end in `disconnected (initialisation failed: …)` → `reconnecting` → a new handshake, never a silent `failed` link.

### Added by review run 3, round 2 (R3.2-1, R3.2-2) — not verified; the simulator has no Bluetooth
- **Write stalls show as timeouts (R3.2-1):** if the Vgate's write characteristic is `withoutResponse` only, look for an `elm` `timeout` row followed by `no prompt for … written off` and an `ATZ` re-init with no reply ever sent — that is a stalled write, not a silent adapter.
- **Double discovery after Bluetooth off/on (R3.2-2):** count `→ discovering` transitions in the console per reconnect; two in a row, or a duplicated GATT table, means both layers connected. Confirm the link still reaches `connected` every time.
- **Retrieval after a bluetoothd reset (R3.1-2):** after a reset, does `retrievePeripherals(withIdentifiers:)` still find the remembered adapter? If every attempt fails with `not known to this phone; scan and pick it again`, only a rescan recovers.
- **First state after restoration:** whether the first `didUpdateState` after a system relaunch is ever `resetting`/`unknown` (restored peripherals are then dropped and re-retrieved); confirm the reconnect still completes.

### Added by M2 part 2 (sensors, recording) — none of this is verified; the simulator has no motion sensors, no GNSS and no real background behaviour
- **Real sensor rates:** `stats.motionHz` ≈ 100 and `inspect_log` rates for `motion`, `accel`, `gyro` ≈ 100 Hz, `mag` ≈ 10 Hz, `baro` ≈ 1 Hz (device-driven), `location` ≈ 1 Hz; `gaps` and `maxGapMs` in the `stats` rows, screen on and screen locked. Note any `out-of-order` count from CoreMotion batches.
- **One CMMotionManager:** device motion and raw IMU share one manager (`SharedMotionManager`). Confirm neither stream's rate drops when both run, compared with either alone.
- **Device-motion magnetic field:** with `xArbitraryZVertical` CoreMotion is expected to report `magneticAccuracy` −1 and no `magneticField` in `motion` rows (the raw field is in `mag`). Record what the phone actually reports.
- **CoreMotion timestamps:** `motion`/`accel`/`gyro` `t` must track `clock.now()` (no offset of seconds). Check the first samples after start: a small negative `t` from a buffered batch is legal; a large offset would mean CoreMotion's timebase is not `ProcessInfo.systemUptime` on this iOS version.
- **Permissions:** first start prompts for Motion & Fitness (altimeter) and Location When In Use. Denying either must give a `lifecycle` `error` row (`altimeter unavailable: …`, `referenceLocation unavailable: …`) and the recording must still run. Revoking location mid-drive must give `referenceLocation: authorization denied while recording …`.
- **Background survival (`CLBackgroundActivitySession`):** with When-In-Use authorisation only, lock the screen for 5+ minutes (M4) and ≥ 1 h on a drive (M5): rows continue, `stats` rows every 10 s without holes, `background`/`foreground` rows bracket the lock, the blue location indicator shows. If the app is suspended, `stats` `t` values jump — that is the signature to look for.
- **Reference fix quality:** `location` `ageS` (expect 0–1 s), `horizontalAccuracy`, and whether `activityType = .otherNavigation` with `kCLLocationAccuracyBest` avoids road snapping (compare a drive's track with the road geometry at a junction). Also whether fixes keep arriving at 1 Hz while stationary (no auto-pause).
- **Fix time:** `t = receivedT − ageS`; on the phone `receivedT − t` should be a fraction of a second. Large or negative ages on most fixes would mean the wall clock and CoreLocation disagree.
- **Flush on background / memory warning:** after locking the screen, the file on disk grows within a second (a member is written inside a background task). Copy the file off while recording (Files app) and confirm it reads with `inspect_log` (only a truncated tail allowed).
- **Disk full on a real phone:** fill the phone to < 250 MB free (R2-8, R3-5): Start is refused below 200 MB; while recording, the `warning` row appears below 200 MB and a clean `lowDiskSpace` stop below 50 MB. Note how long the free-space query takes on the phone (it runs off the main actor) and whether purgeable space makes iOS free space before our floor is reached.
- **Write failure UI:** if a real write failure ever happens, the app must show `failed` with an unwritten count, and the file must still read up to the failure.
- **Thermal and lock rows:** `thermalState` rows on a hot dashboard; `protectedDataUnavailable` when a passcode-locked phone locks — and recording continues (files are `completeUntilFirstUserAuthentication`).
- **Idle timer:** the screen does not dim while recording; dims normally after stop.
- **State restoration with a recording running:** the link is created at launch (`AppServices`), so a system relaunch can restore the BLE central. But a relaunch is a new process: the recording that was running is gone (its file ends with a truncated tail at most; no `stop` row) and no new recording starts by itself. Confirm that is what happens, and decide whether auto-resume is wanted (a user decision, not implemented).
- **Writer queue:** `stats.queueDepthMax` stays small (tens of events) on the phone; a `writer queue peaked …` error row would mean the writer can't keep up.

### Added by review run 4, round 1 (R4.1-x) — not verified
- **Cached first fix:** whether the first CoreLocation fix after Start is cached with a large `ageS` (a `location` row well before `t = 0`; legal, not clamped). Confirm `inspect_log` tolerates it and note how often it happens.
- **Location denied / "Allow Once" (R4.1-5):** with location denied, lock for 5 min with and without OBD; do motion and `stats` rows continue on BLE wakes alone? With "Allow Once" plus `CLBackgroundActivitySession`, do fixes continue after lock? Since M3 prep: with location denied the dashboard must warn before Start (`backgroundRiskWarning`), and the file must hold `referenceLocation unavailable: …` followed by `no background location session; recording may pause while locked`. Revoke location in Settings mid-recording and confirm that row appears once on returning to the app, and whether the background session really ends (the row says "may").
- **Stop while locked (R4.1-3):** trigger a stop with the phone locked (floor via a debug fake provider, or a forced write failure); confirm the `stop` row, the final `stats` row and an intact tail.
- **Swipe-away while recording in background (R4.1-4):** measure tail loss and whether `willTerminate` arrives.
- **Delete path matching on device:** `URL.documentsDirectory` (`/var/mobile/…`) vs `contentsOfDirectory` (possibly `/private/var/…`); confirm Delete works from the M3 list and the "being recorded" guard matches (a mismatch fails safe with `.notInStore` but makes Delete unusable).

### Added by M3 (UI) — simulator screenshots only; none of this is verified on a phone
- **Readability at arm's length:** in the real mount, speed numbers (84 pt), banner and adapter status readable at a glance, driver's seat, day and night; note which text is too small (stats row, notices, console).
- **Glare and sunlight:** red/orange/green banner and tile outlines still distinguishable in direct sun and with polarised sunglasses; consider a forced dark or high-contrast mode if not.
- **Tap targets while mounted:** START, MARK and STOP (72 pt) and the checklist toggles hit reliably one-handed with the phone in the mount; the Mark sheet presets are usable without looking; no accidental STOP (there is no confirmation on STOP).
- **Idle timer:** screen does not dim while calibrating or recording on the Record tab and on the other tabs, and dims normally after stop and after a failed recording.
- **Permissions and unavailable states:** deny Motion and Location and turn Bluetooth off; the Record tab shows the matching notices and red adapter state, and the checklist and Start still behave.
- **Keyboard:** mount and vehicle note fields and the console field with the on-screen keyboard in the mount; the Start bar stays reachable.

### Added by M4 fixes (not verified)
Start-up init written at Start (link side 2437416, recorder side in this fix) and location authorisation in the file. Tested only against fakes on the simulator; none of this has been seen on the phone.
1. **Start after polling:** the file begins with the `start` row, then negative-`t` `link` rows `connecting → discovering → connected` (since the M4 follow-up only `discovering → connected`) and `elm` rows `ATZ` … `ATSH7E0`, then the probe and an `adapter` row, then live rows. `inspect_log --strict` is clean, and `seq` increases with exactly one gap (after the init's last exchange; the pre-Start polls are not written).
2. **Start during init** (allow without OBD): every init exchange appears exactly once: the first part replayed with negative `t`, the rest live.
3. **ATAT on the Touareg:** the `adaptive timing:` note says `ATAT1 kept`, with both medians around 59 ms. Measure the extra start-up and re-init time (about 1.2 s).
4. **Unplug and replug while not recording, then Start:** the replayed init is the reconnect's (one `connected`, its `ATZ`), not the first connection's.
5. **If `ATAT2 kept` ever appears,** check that steady-state replies aren't cut short.
6. **First `stats` window:** in a recording started minutes after the adapter connected, the first `stats` row's `windowS` is about 10 s (not stretched back to the replayed init), and `motionHz` is about 100.
7. **`locationAuthorization` at start:** the row after the source rows reads what Settings shows: `authorizationStatus=authorizedWhenInUse` (or what was granted), `accuracyAuthorization=full` (or `reduced` with Precise Location off), and `backgroundActivitySession=held`. Repeat once with location denied: `authorizationStatus=denied, …, backgroundActivitySession=none`, then `no background location session; …`.
8. **The bench's `Code=1` again:** if `referenceLocation: Error Domain=kCLErrorDomain Code=1 …` reappears, note the authorisation in its parentheses. With `authorizedWhenInUse`/`authorizedAlways`, fixes must keep coming and no background-risk row is written. With `denied`/`restricted`, the background-risk row must follow. Also check whether it comes right after Start on a fresh install, while `authorizationStatus=notDetermined`. That is the leading hypothesis for the bench, and if it holds it is a startup ordering issue, not a denial.
9. **Prompt answered after Start:** on a fresh install, Start, then answer the location prompt. You should get a `locationAuthorization` row with the new authorisation at the moment of the answer, and fixes start. If the answer was "Allow Once" or "Allow While Using", check whether `backgroundActivitySession=held` (created before the answer) actually keeps the app running when locked. The `stats` `t` values must continue across the lock.
10. **Precise Location off mid-recording:** gives `locationAuthorization` `…, accuracyAuthorization=reduced` and the recording continues. Note `horizontalAccuracy` afterwards.

### Added by M4 follow-up (not verified)
Replay only the current connection's init (M6.1-1) and remembered poll plan and `ATAT` across reconnects (M6.1-3). Tested against `MockELMAdapter`, `FakeBLECentral` and `SimulatedOBDLink` only; none of this has been seen on the phone.
1. **Unplug and replug while recording:** after the reconnect the `link` notes show `poll plan reused from the previous connection: 010D0C1, ATAT1, requestHeader 7E0` (with the level the start-up init chose), the `elm` rows of the re-init are the handshake with `ATSH7E0` → `OK`, then `ATAT1` and one `010D0C1` (phase `probe`), with no selection samples and no `adaptive timing:` note; polling resumes faster than the bench's 7.2 s init (`connected` → `polling`; most of it is still `0100` `SEARCHING...`, so expect roughly 7.2 s minus the ~1.2–1.5 s of probing). Note the `connected` → `polling` time.
2. **Start after a drop:** unplug the adapter, wait for `reconnecting`, tap Start (allow without OBD): the file has no negative-`t` `link`/`elm`/`adapter` rows (no replay); the first `link` row is the live `reconnecting → connecting` (or the next transition); replug, and the whole new connection is written live, `seq` increasing.
3. **Start while connected:** the replay begins with the `link` row `discovering → connected`; no `connecting`/`discovering` rows precede it.
4. **Reused plan failing on the car:** if a `reused plan failed (…); selecting again` note ever appears, record the reason and whether the following selection picked a different plan; the next reconnect must then show the newly selected plan in its `poll plan reused …` note.
5. **Forget / another adapter:** after Forget and re-pairing the same adapter, or after picking a different one, the first init runs the full selection and the `adaptive timing:` note (no `poll plan reused` note).

### Added by M4.3 map follow + heading-up (not verified on a device)
1. **Following survives a 10 min drive:** no unexpected loss of Following (the old `positionedByUser` handler is removed).
2. **Pan, then wait:** the "Re-centre in N s" hint counts down from 8 and the camera animates back to the car at the same zoom; panning again during the countdown restarts it. A long fling never re-centres mid-gesture.
3. **Pin:** long-press (recording) freezes the camera; the countdown starts only after Confirm/Cancel.
4. **Heading-up:** the map turns smoothly with the car above 10 km/h and holds still at stops (OBD speed 0); the arrow points up while following and shows true direction after a manual rotate; the mode persists across launches.
5. **SwiftUI gestures on `Map`:** the drag/pinch/rotate/double-tap gestures fire (Following goes off) and do not block panning, zooming or the long-press. If they fail, the fallback is an `MKMapView` wrapper; ask the user before building it.
6. **Heading-up while stopped:** returning to the Map tab or toggling North up to Heading up while stopped shows the correct heading at once (restored from the last good bearing).
7. **ELM stall at a stop:** after a stall, heading-up unfreezes on drive-off (a stale OBD 0 does not count as stopped).
8. **Turns:** the camera settles at the true heading after a turn.
9. **Zoom parity:** at equal zoom, the visible area in heading-up roughly matches north-up (checks the `distancePerSpan` 1.87 guess).

### Added by N4 A, sample tap and sidecar files (not verified on a device)
1. **The tap costs the logger nothing:** in a 30 min recording on the phone, the `stats` rows show motion ~100 Hz and OBD at its pre-N4 rate, `dropped` 0, gaps and `queueDepthMax` no worse than a pre-N4 drive. The tap runs under `SampleGate`'s lock at real CoreMotion rates; the simulator only runs simulated tickers.
2. **Export with a sidecar:** once N4 B writes `<recording>.nav.jsonl`, the share sheet offers both files and AirDrop / Save to Files delivers both. Without a sidecar it shares the recording alone, as before.
3. **Delete with a sidecar:** deleting a recording in the Sessions tab removes its `.nav.jsonl` too; Files app → DriveLogger → logs shows neither afterwards.
