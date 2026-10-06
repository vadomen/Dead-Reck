# Log format

Field-by-field reference for DriveLogger recordings. The code in
`Core/Sources/DriveLoggerCore/Log/` is authoritative; this file must be updated
in the same commit as any change to it.

Current version: **2** (`LogFormatVersion.current`). Readable: **1, 2**.

## File

- Name: `Drive_<yyyyMMdd-HHmmss>.jsonl.gz` (or `…_2.jsonl.gz`, `_3`, … if a
  file with that name already exists — a recording is never overwritten),
  local time at start, in the app's
  `Documents/logs` (Files app → On My iPhone → DriveLogger → logs).
- Encoding: UTF-8 JSON Lines, one object per line, `\n`-terminated.
- Compression: gzip, written as a **sequence of gzip members**, one per flush
  (at least every 2 s, on stop, on entering background, on memory warning).
  Concatenated members are a standard gzip stream: `gunzip`, `zcat` and Python's
  `gzip` module read the file as one. Each member's header carries its
  compressed length in an `FEXTRA` subfield (BGZF-style), which DriveLogger's
  own reader uses to step through members.
- Damage: a crash or flat battery loses at most the last unflushed buffer. The
  reader drops a truncated final member and reports it; it also skips any
  undecodable line under `LogRecovery.skipMalformedLines`.
- Line 1 is the header. Every later line is an event.
- Recordings are never committed to git (see CLAUDE.md).

## Conventions

- **Time.** `t` and every field ending in `T` (`requestT`, `receivedT`) are
  integer **nanoseconds** since the session's reference instant, on one
  monotonic clock (seconds since boot, CoreMotion's timebase). Values can be
  **negative**: CoreMotion may deliver samples buffered before the session
  started. Wall-clock time appears only in the header (`startedAt`) and in
  `location.fixTime`.
- **Order.** Lines are in write order, which is close to but not strictly `t`
  order. Sort by `t` when aligning streams.
- **Units** are those of the source framework: CoreMotion g, rad/s, µT;
  CoreLocation degrees, metres, m/s; OBD values in the PID's native unit.
- **Absent fields** are omitted, never `null`. A field missing from a v1 file
  is simply absent.
- **Wire strings** (`raw`, `rx`, `tx`) are verbatim, minus only the trailing `>`
  prompt. Carriage returns appear as JSON `\r` escapes.
- **Key order** is sorted, so output is byte-stable for identical input.

## Header

| Field | Type | Since | Meaning |
|---|---|---|---|
| `formatVersion` | int | 1 | `1` or `2`. A reader refuses versions newer than it knows. |
| `sessionID` | UUID string | 1 | Unique per recording. |
| `startedAt` | ISO 8601 string | 1 | Wall clock at start, whole seconds, UTC. The only wall-clock anchor. |
| `referenceUptimeSeconds` | double, s | 1 | Seconds since boot at start; `t = 0` here. |
| `app` | `{name, version, build}` | 1 | Producing build. |
| `device` | `{model, systemName, systemVersion}` | 1 | e.g. `iPhone16,1`, `iOS`, `18.6`. |
| `notes` | string | 1 | Free text. |
| `adapter` | object, see below | 2 | Adapter as of start. Absent if started without OBD. |
| `polling` | object, see below | 2 | Polling combination as of start. |
| `sensors` | object, see below | 2 | Requested sensor configuration. |
| `mount` | string | 2 | Mount note from the pre-drive checklist. |
| `vehicle` | string | 2 | Vehicle note. |
| `timeZone` | string | 2 | IANA identifier at start, e.g. `Europe/Kyiv`. Display only. |

`adapter`:

| Field | Type | Meaning |
|---|---|---|
| `name` | string | BLE advertised name. |
| `identifier` | UUID string | `CBPeripheral.identifier` (per phone). |
| `gatt` | `{service, notify, write, writeType, maxWriteLength}` | UART pair used. `writeType`: `withResponse` / `withoutResponse`. `maxWriteLength` in bytes. |
| `gattTable` | `[{service, characteristics: [{uuid, properties: [string]}]}]` | Everything discovered. |
| `elmVersion` | string | `ATZ` banner, e.g. `ELM327 v2.1`. |
| `protocol` | string | Raw `ATDPN` reply, e.g. `A6` (`A` = auto-detected, `6` = ISO 15765-4 CAN 11-bit 500 kbaud). |
| `voltage` | double, V | Parsed `ATRV`. |

`polling`:

| Field | Type | Meaning |
|---|---|---|
| `command` | string | Exact command sent when all PIDs are due, e.g. `010D0C1`. |
| `pids` | [int] | PID numbers polled, decimal (`13` = 0x0D). |
| `multiPID` | bool | PIDs combined into one request. |
| `responseCount` | int | Response-count suffix in use; absent if not. |
| `adaptiveTiming` | int | `ATAT` level, 0–2. |
| `rpmEvery` | int | When not combined, RPM is polled every Nth cycle. |
| `timeoutMs` | int, ms | Per-command timeout. |

`sensors`: `deviceMotionHz`, `accelerometerHz`, `gyroHz`, `magnetometerHz`
(double, Hz, requested), `referenceFrame` (string, e.g. `xArbitraryZVertical`),
`altimeter` (bool).

## Events

Every event line: `{"data": …, "kind": "<kind>", "t": <ns>}`.

Kinds are frozen strings. A reader that meets a kind it does not know keeps it
verbatim (`LogEvent.Payload.unrecognized`) instead of dropping it.

| `kind` | Since | `t` is | Rate |
|---|---|---|---|
| `motion` | 1 | `CMDeviceMotion.timestamp` | 100 Hz |
| `location` | 1 | v1: unspecified. v2: GNSS fix time | ~1 Hz |
| `obd` | 1 | reply received | poll rate |
| `marker` | 1 | button tap | user |
| `accel` | 2 | `CMAccelerometerData.timestamp` | 100 Hz |
| `gyro` | 2 | `CMGyroData.timestamp` | 100 Hz |
| `mag` | 2 | `CMMagnetometerData.timestamp` | ~10 Hz |
| `baro` | 2 | `CMAltitudeData.timestamp` | ~1 Hz |
| `elm` | 2 | reply complete, or timeout fired | every exchange |
| `adapter` | 2 | init finished | each (re-)init |
| `link` | 2 | state transition | rare |
| `lifecycle` | 2 | occurrence | rare |
| `stats` | 2 | end of 10 s window | 0.1 Hz |

### `motion`

| Field | Type, unit | Since | Meaning |
|---|---|---|---|
| `userAcceleration` | `{x,y,z}` g | 1 | Gravity removed. Device frame. |
| `gravity` | `{x,y,z}` g | 1 | Gravity direction, device frame. |
| `rotationRate` | `{x,y,z}` rad/s | 1 | Bias-corrected. |
| `attitude` | `{x,y,z,w}` | 1 | Unit quaternion, in the header's `referenceFrame`. |
| `magneticField` | `{x,y,z}` µT | 1 | Calibrated; absent until CoreMotion reports usable accuracy. |
| `magneticAccuracy` | int | 2 | `CMMagneticFieldCalibrationAccuracy`: −1 uncalibrated, 0 low, 1 medium, 2 high. |

### `accel`, `gyro`, `mag`

`{x, y, z}` in the device frame, uncorrected:
`accel` in g (gravity included), `gyro` in rad/s (not bias-corrected), `mag` in
µT (uncalibrated, includes device bias).

### `baro`

| Field | Unit | Meaning |
|---|---|---|
| `pressureKPa` | kPa | Static pressure. |
| `relativeAltitude` | m | Change since the altimeter session started. |

### `location`

CoreLocation's "negative means invalid" convention is kept as-is.

| Field | Type, unit | Since | Meaning |
|---|---|---|---|
| `latitude`, `longitude` | double, degrees WGS 84 | 1 | |
| `altitude` | double, m | 1 | Above mean sea level. |
| `horizontalAccuracy` | double, m | 1 | Negative = position invalid. |
| `verticalAccuracy` | double, m | 1 | Negative = altitude invalid. |
| `speed` | double, m/s | 1 | Negative = unavailable. |
| `speedAccuracy` | double, m/s | 1 | Negative = unavailable. |
| `course` | double, degrees from true north | 1 | Negative = unavailable. |
| `courseAccuracy` | double, degrees | 1 | Negative = unavailable. |
| `receivedT` | int, ns | 2 | When the app received the fix. |
| `fixTime` | ISO 8601 string, fractional seconds | 2 | `CLLocation.timestamp` verbatim (wall clock). |
| `ageS` | double, s | 2 | Wall clock at receipt minus `fixTime`, read together. |
| `ellipsoidalAltitude` | double, m | 2 | Above the WGS 84 ellipsoid. |
| `simulated` | bool | 2 | `CLLocationSourceInformation.isSimulatedBySoftware`. |
| `accessory` | bool | 2 | `CLLocationSourceInformation.isProducedByAccessory`. |

In v2, `t = receivedT − ageS` (the fix time on the session clock). `fixTime`
lets that be recomputed offline. GNSS is reference only: ground truth for
evaluation, never an input.

### `obd`

One row per PID per answering ECU. A multi-PID reply produces several rows
that share `seq`, `raw`, `requestT` and `t`.

| Field | Type, unit | Since | Meaning |
|---|---|---|---|
| `pid` | int | 1 | Decimal PID, e.g. `13` (0x0D), `12` (0x0C). |
| `value` | double | 1 | Decoded per SAE J1979, in `unit`. |
| `unit` | string | 1 | `km/h`, `rpm`, `%`, `degC`. |
| `raw` | string | 1 | v1: header-off payload line (`410D32`). v2: full verbatim reply, headers on, every ECU (`7E803410D32\r\r`). |
| `requestT` | int, ns | 2 | When the request was written. Latency = `t − requestT`. |
| `command` | string | 2 | Command that produced it, e.g. `010D0C1`. |
| `ecu` | string | 2 | CAN header of the answering ECU, e.g. `7E8`. Absent with headers off. |
| `seq` | int | 2 | The `elm` exchange it was decoded from. |

PID formulas: `0x0D` speed = A km/h (integer, 0–255); `0x0C` engine speed =
(256A + B) / 4 rpm.

### `elm`

Every command/reply exchange with the adapter, including successful polls.
This is the complete raw traffic.

| Field | Type, unit | Meaning |
|---|---|---|
| `seq` | int | Increasing within the recording, including across adapter reconnects. |
| `phase` | string | `init`, `probe`, `poll`, `manual`, `keepalive`. |
| `tx` | string | Command as written, without CR. |
| `requestT` | int, ns | Write issued. |
| `rx` | string | Reply, verbatim minus `>`. Absent on `timeout` and `rejected`. |
| `outcome` | string | See below. |

`outcome`: `ok`, `noData` (PID not implemented by the vehicle; polling of it
stops), `timeout`, `stopped`, `notRecognised` (`?`), `canError`, `busError`,
`busInitError`, `bufferFull`, `dataError`, `unableToConnect`, `adapterError`
(`ERRxx`), `malformed` (reply arrived but did not parse), `rejected` (blocked by
the read-only guard, never sent).

### `adapter`

`{adapter, polling}`, same shapes as the header sections. Written after every
successful initialisation, including re-inits and reconnects mid-drive.

### `link`

| Field | Meaning |
|---|---|
| `layer` | `ble` or `elm`. |
| `from`, `to` | State names. `elm` states: `idle`, `resetting`, `initialising`, `searching`, `probing`, `ready`, `polling`, `retrying`, `reinitialising`, `failed`. `ble` states: `unavailable`, `idle`, `scanning`, `connecting`, `discovering`, `connected`, `disconnected`, `reconnecting`, `restoring`. |
| `reason` | Optional free text, e.g. `timeout`. |

### `lifecycle`

| Field | Meaning |
|---|---|
| `event` | `start`, `stop`, `pause`, `resume`, `background`, `foreground`, `calibrationStart`, `calibrationEnd`, `error`, `memoryWarning`, `thermalState`, `protectedDataUnavailable`. Calibration is the first phase of a recording: the samples between `calibrationStart` and `calibrationEnd` were taken with the car and phone still. |
| `detail` | Optional free text (error description, thermal state name, stop reason). |

### `stats`

Recorder health over the preceding window. Computed live because queue depth
and drops can't be reconstructed afterwards.

| Field | Type, unit | Meaning |
|---|---|---|
| `windowS` | double, s | Window length (10). |
| `counts` | {kind: int} | Events written in the window, by kind. |
| `obdHz` | double, Hz | Successful OBD exchanges per second. |
| `motionHz` | double, Hz | `motion` events per second. |
| `gaps` | {kind: int} | Intervals > 50 ms in `motion`, `accel`, `gyro`. |
| `maxGapMs` | {kind: double}, ms | Longest interval per kind. |
| `timeouts` | int | `elm` timeouts in the window. |
| `queueDepthMax` | int, events | Peak writer queue depth. |
| `dropped` | int | Events dropped. Should always be 0. |
| `bytesWritten` | int, bytes | Compressed file size so far. |

### `marker`

`data` is a plain string, e.g. `"tunnel"`.

## Versions

| Version | Changes |
|---|---|
| 1 | Header (`formatVersion`, `sessionID`, `startedAt`, `referenceUptimeSeconds`, `app`, `device`, `notes`); kinds `motion`, `location`, `obd`, `marker`. |
| 2 | Header `adapter`, `polling`, `sensors`, `mount`, `vehicle`, `timeZone`. `motion.magneticAccuracy`. `location` `receivedT`, `fixTime`, `ageS`, `ellipsoidalAltitude`, `simulated`, `accessory`; `t` defined as fix time. `obd` `requestT`, `command`, `ecu`, `seq`; `raw` becomes the full header-on reply. New kinds `accel`, `gyro`, `mag`, `baro`, `elm`, `adapter`, `link`, `lifecycle`, `stats`. |

Every version stays readable. v2 only adds optional fields, so DriveLogger
decodes a v1 file into the same types with those fields absent. Frozen fixtures
for both versions are in `LogFormatCompatibilityTests`.

## Reading recordings outside DriveLogger

```bash
gunzip -c Drive_20260528-232640.jsonl.gz | head -1 | jq .     # header
gunzip -c Drive_20260528-232640.jsonl.gz | jq -c 'select(.kind=="obd")' | head
```

```python
import gzip, json
with gzip.open("Drive_20260528-232640.jsonl.gz", "rt") as f:
    header = json.loads(next(f))
    try:
        for line in f:
            event = json.loads(line)
    except (EOFError, json.JSONDecodeError):
        pass  # truncated last gzip member or half-written line after a crash
```

`swift run inspect_log <file> [--csv <dir>]` (from `Core/`, M1) prints a summary
and exports one CSV per kind.
