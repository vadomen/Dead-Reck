# DriveLogger v1 — implementation plan (M0)

Status: **approved; M0 done** (commit "contracts"). The v2 format types and
codec are implemented and covered by a frozen v2 fixture; every other API in §4
exists as a compiling stub whose body is `fatalError("M1: …")` or
`fatalError("M2: …")`, which marks the milestone that implements it. All seven
decisions in §5 were approved as written.

Small deviations from the sketches below, made while writing the stubs:
`ELM327Command.currentDataMany(_:responseCount:)` (not `requestMany`);
`StatsAccumulator.closeWindow(at:…)` (not `window(endingAt:…)`); the
`needsReconnect` stream is folded into `ELMSessionEvent.needsReconnect`;
`OBDLinkServicing` exposes a merged `adapter: AdapterRecord?` + `plan` instead
of separate `adapterInfo`/`gatt`, and `sessionEvents()` instead of `events()`;
`RecordingSession` adds `handleMemoryWarning()`. `ELM327Command.handshake` still
has the old `ATH0` sequence; M1 replaces it with the spec sequence.

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

### M2 — App services, sequential
1. elm-ble-engineer: `BLETransport` (CoreBluetooth, GATT auto-detect, write splitting, state restoration), `OBDLinkService` (scan / pick / remember / reconnect / console feed), `SimulatedOBDLink` (mock adapter, used on the simulator).
2. sensors-logging-engineer: `MotionSource`, `RawIMUSource`, `AltimeterSource`, `LocationSource` (+ simulated twins), `LogStore` (Documents/logs), `RecordingSession` orchestrator, background lifecycle, 10 s stats.
- Acceptance: simulator build + app tests green after each; reviewer on the M2 diff.

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
| `lifecycle` | event | `event` (`start`, `stop`, `background`, `foreground`, `calibrationStart`, `calibrationEnd`, `pause`, `resume`, `error`, `memoryWarning`, `thermalState`, `protectedDataUnavailable`), `detail` String? | rare |
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
in App. Signatures below are what M0 commits as stubs; names may still be
polished during review of this plan, not after.

### 4.1 ELM transport (Core, `ELM327/ELMTransport.swift`)

```swift
/// A chunk as delivered by the radio, stamped where it arrived — in the BLE
/// delegate callback, before any actor hop adds latency.
public struct ELMChunk: Sendable { public var bytes: Data; public var uptime: Double }

public protocol ELMTransport: Sendable {
    /// Writes one complete command (CR-terminated). Splits to the link's max
    /// write length. Returns the uptime at which the write was issued.
    func send(_ data: Data) async throws -> Double
    /// Every inbound fragment, in order. Finishes when the link drops.
    var incoming: AsyncStream<ELMChunk> { get }
}
```

`ELMFramer` (struct): `mutating func append(_ chunk: ELMChunk) -> [ELMRawReply]`,
where `ELMRawReply { text: String; completedUptime: Double }` — accumulates until
`>`, strips NUL and the prompt.

### 4.2 ELM session (Core, `ELM327/ELMSession.swift`)

```swift
public enum ELMCommandPolicy {
    /// The read-only guard. Allows `AT…` and mode 01 requests
    /// (`01` + 1–6 PIDs + optional 1-digit count suffix) and nothing else.
    public static func validate(_ wire: String) throws(ELMSessionError)
}

public enum ELMState: String, Sendable {      // names are written into `link` rows
    case idle, resetting, initialising, searching, probing, ready,
         polling, retrying, reinitialising, failed
}

public struct ELMExchange: Sendable {          // → `elm` row
    public var seq: Int; public var phase: ELMPhase; public var tx: String
    public var requestUptime: Double; public var rx: String?
    public var completedUptime: Double; public var outcome: ELMOutcome
}

public struct OBDReading: Sendable {           // → `obd` row
    public var seq: Int; public var command: String; public var ecu: String?
    public var measurement: OBDMeasurement; public var raw: String
    public var requestUptime: Double; public var replyUptime: Double
}

public struct PollingPlan: Sendable, Hashable { command, pids, multiPID, responseCount, adaptiveTiming, rpmEvery, timeout }
public struct ELMAdapterInfo: Sendable, Hashable { elmVersion, protocolNumber, voltage, supportedPIDs: String?, plan: PollingPlan }

public enum ELMSessionEvent: Sendable {
    case state(from: ELMState, to: ELMState, reason: String?)
    case exchange(ELMExchange)
    case reading(OBDReading)
    case adapter(ELMAdapterInfo)
    case pollRate(hz: Double)
}

public actor ELMSession {
    public init(transport: any ELMTransport,
                configuration: ELMSessionConfiguration = .default,   // timeouts, retry N, re-init N
                clock: any Clock<Duration> = ContinuousClock())       // injectable for tests
    /// Single consumer (AsyncStream). OBDLinkService fans it out.
    public nonisolated var events: AsyncStream<ELMSessionEvent> { get }
    /// ATZ → ATE0 → ATL0 → ATS0 → ATH1 → ATSP0 → 0100 (10 s) → ATDPN → ATRV,
    /// then probes multi-PID / count suffix / ATAT2 and picks the fastest that parses.
    public func initialise() async throws -> ELMAdapterInfo
    public func startPolling(_ plan: PollingPlan)
    public func stopPolling()
    /// Debug console. Guarded; queued between polls so only one command is ever in flight.
    public func sendManual(_ command: String) async throws -> ELMExchange
    /// Escalation after N re-init failures: caller should reconnect BLE.
    public nonisolated var needsReconnect: AsyncStream<Void> { get }
}
```

Timestamps: the session records **uptimes** (from the transport for receive,
from `send` for request). `RecordingSession` converts with
`clock.timestamp(uptimeSeconds:)`. That is the same base as `clock.now()` and
lets the link run before a recording exists (pre-drive init).

`MockELMAdapter: ELMTransport` (Core, library, not test-only so the simulator
app can use it): script of `(match: String, reply: String, delay: Duration,
fragmentSizes: [Int])`, plus canned Touareg scripts (headers on, two ECUs,
multi-PID supported, `NO DATA` for 0x0F).

Parser additions (`ELM327ResponseParser`): `replies(in raw:, headers: Bool) ->
[ECUReply]` with `ECUReply { header: String?; bytes: [UInt8] }`;
`OBDDecoder.decode(pids:payload:) -> [OBDMeasurement]` for multi-PID;
`ELMTextReply` for `OK` / banner / `ATDPN` / `ATRV`. `ELM327Command` gains
`.adaptiveTiming(Int)` and `.requestMany(pids:[OBDPID], responseCount: Int?)`;
`handshake` becomes the spec sequence.

### 4.3 Log writer / reader (Core, `Log/`)

```swift
/// Nonisolated, lock-free front door for 300+ events/s from sensor callbacks.
/// Never blocks the caller; counts depth and drops (`stats`).
public final class LogSink: Sendable {
    public func record(_ event: LogEvent)
    public var queueDepth: Int { get }
}

public actor LogFileWriter {
    public init(url: URL, header: LogHeader, flushInterval: Duration = .seconds(2)) throws
    public nonisolated var sink: LogSink { get }
    public func flush() async throws                 // background, memory warning
    public func finish() async throws -> LogFileSummary   // final flush + close
    public var bytesWritten: Int { get }
    public nonisolated var failures: AsyncStream<LogWriteError> { get }  // disk full etc. — never swallowed
}

public struct LogFileReader: Sequence {             // streaming, member by member
    public init(url: URL, recovery: LogRecovery = .skipMalformedLines) throws
    public var header: LogHeader { get }
    public var report: LogReadReport { get }        // truncatedTail, skipped line indices, members
}
```

One `LogCodec` lives inside `LogFileWriter` and one inside each reader (CLAUDE.md).
Queue policy: unbounded, because dropping is data loss; depth is reported every
10 s and a warning `lifecycle` row is written if it exceeds 2 s of data.

### 4.4 Sensor sources (protocol in Core `Recording/`, real ones in App)

```swift
public enum SensorAvailability: Sendable, Hashable { case available, unavailable(reason: String) }

public protocol SensorSource: AnyObject, Sendable {
    var name: String { get }
    var availability: SensorAvailability { get }
    /// Starts delivering events stamped with `clock` into `sink`.
    func start(clock: SessionClock, sink: LogSink) throws
    func stop()
}
```

Core: `SimulatedMotionSource`, `SimulatedLocationSource` (deterministic,
for previews and the simulator). App: `DeviceMotionSource`, `RawIMUSource`
(accel + gyro + mag), `AltimeterSource`, `LocationSource` (`CLLocationManager`,
best accuracy, `allowsBackgroundLocationUpdates`, no auto-pause, plus
`CLBackgroundActivitySession` while recording). Each converts at the boundary into
Core sample types and stamps with `clock.timestamp(uptimeSeconds: item.timestamp)`.

`StatsAccumulator` (Core, struct): `mutating func observe(_ event: LogEvent)`,
`mutating func window(endingAt: MonotonicTimestamp, queueDepthMax:, dropped:,
bytesWritten:) -> StatsSample`. Pure, fully unit-tested.

`EventMapping` (Core): `LogEvent(exchange:clock:)`, `LogEvent(reading:clock:)`,
`LogEvent(adapter:)`, `LogEvent(state:clock:)` — the one place ELM runtime types
become format types.

### 4.5 OBDLink service (App, `Link/`)

```swift
@MainActor protocol OBDLinkServicing: AnyObject, Observable {
    var bluetooth: SensorAvailability { get }
    var discovered: [DiscoveredAdapter] { get }       // name, identifier, RSSI
    var rememberedAdapterID: UUID? { get }
    var linkState: OBDLinkState { get }               // scanning/connecting/initialising/polling(protocol, voltage)/…
    var adapterInfo: ELMAdapterInfo? { get }
    var gatt: GATTSnapshot? { get }                   // for the header
    var pollHz: Double { get }
    var console: [ConsoleLine] { get }                // ring buffer for the debug screen
    func startScan(); func stopScan()
    func connect(_ id: UUID); func forget()
    func sendManual(_ command: String) async throws   // guarded by ELMCommandPolicy
    /// Session events for the recorder; one subscriber at a time.
    func events() -> AsyncStream<ELMSessionEvent>
}
```

`OBDLinkService` (CoreBluetooth, restore identifier, reconnect with backoff) and
`SimulatedOBDLink` (wraps `MockELMAdapter`; chosen automatically on the simulator).

### 4.6 RecordingSession orchestrator (App, `Recording/`)

```swift
@MainActor @Observable final class RecordingSession {
    init(link: any OBDLinkServicing, sources: [any SensorSource], store: LogStore,
         uptime: any UptimeSource = SystemUptimeSource())
    private(set) var state: RecordingState            // idle / calibrating / recording / stopping / failed(String)
    private(set) var live: LiveStatus                 // obdSpeed, gpsSpeed, obdHz, motionHz, elapsed, fileBytes
    func calibrate() async                            // 5 s keep-still, writes calibrationStart/End
    func start(mount: String, vehicle: String, allowWithoutOBD: Bool) async throws
    func mark(_ text: String)
    func stop() async
    func handleScenePhase(_ phase: ScenePhase)        // background/foreground rows + flush
}
```

Owns the single `SessionClock` per recording, the `LogFileWriter`, the stats
timer, and the `isIdleTimerDisabled` toggle. `LogStore` lists, sizes and deletes
files in `Documents/logs`.

### 4.7 `inspect_log` (Core package, executable target)

`swift run inspect_log <file> [--csv <dir>]` — header, events per kind, rates,
gaps > 50 ms, OBD latency (`t − requestT`) percentiles, `elm` outcome counts,
truncation report, CSV per kind. Foundation only, so it passes the import check.

---

## 5. Decisions needing your approval

1. **Format v2** (§3.1), including the three assertion edits in `LogFormatCompatibilityTests` — fixture string untouched.
2. **GPS fix time** via `Date()`-based age at receipt (§3.4).
3. **Start requires OBD `polling`** unless "record without OBD" is chosen explicitly (§3.3).
4. **gzip via concatenated members** built on `NSData.compressed(using: .zlib)`, no third-party code (§3.5).
5. **`MockELMAdapter` and simulated sensor sources ship in the Core library**, not only in tests, so the simulator app runs end to end.
6. **`elm` rows for every exchange**, including successful polls (§3.4).
7. **`inspect_log` lives in the Core package** (`Core/Sources/inspect_log`) rather than a separate `tools/` package, so it shares Core without a second `Package.swift`.

## 6. Risks to check on hardware (M4), not claimable before
- Whether the clone accepts `010D0C`, the `1` suffix and `ATAT2`; real poll Hz.
- Whether `7E8` is the only responder for 0x0D on the Touareg.
- Background survival over 5+ minutes locked with BLE + location.
- Actual Vgate GATT layout and max write length.
