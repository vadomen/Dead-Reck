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
  (at least every 2 s, on stop, on entering background, on memory warning;
  no member is built from more than 8 MiB of JSON — a larger backlog is split
  at line ends). Concatenated members are a standard gzip stream: `gunzip`,
  `zcat` and Python's `gzip` module read the file as one.
- Member layout (RFC 1952 plus one extra subfield):

  | Bytes | Value |
  |---|---|
  | ID1 ID2 CM | `1f 8b 08` |
  | FLG | `04` (FEXTRA only) |
  | MTIME | `0` |
  | XFL OS | `00 ff` |
  | XLEN | `8` (UInt16 LE) |
  | Subfield | SI1 `'D'`, SI2 `'L'`, LEN `4`, then the compressed length of this member's DEFLATE data as UInt32 LE (32-bit, unlike BGZF's 16-bit `BSIZE`) |
  | Data | raw DEFLATE |
  | Trailer | CRC-32, ISIZE (UInt32 LE each) |

  DriveLogger's reader steps through members by the `DL` length and refuses
  a gzip file without it (e.g. one recompressed with `gzip`; `gunzip` it to
  `.jsonl` first). Plain `.jsonl` is also accepted.
- Damage: a crash or flat battery loses at most the last unflushed buffer.
  - A truncated final member, or a zero-filled tail after power loss, is
    dropped and reported as a truncated tail.
  - A complete member that fails its CRC/ISIZE check is skipped and listed in
    `damagedMemberIndices`; reading continues. Under `.strict` reading stops
    and reports the failure.
  - A header member (member 0) with a bad checksum is still decoded and used,
    and listed as damaged member 0. If it can't be inflated, or under
    `.strict`, reading fails with `damagedMember(index: 0)`. An event line is
    never taken for the header.
  - Under `LogRecovery.skipMalformedLines` undecodable lines are skipped;
    skipped-line indices count non-empty lines across the whole file, header
    = 0.
  - An I/O error while reading (e.g. `EIO` from failing media) ends reading
    under either recovery mode and is reported as a read error
    (`LogReadReport.readError`, an `inspect_log` warning), not as a damaged
    member or a truncated tail: the bytes after it were never seen. Before
    the header is complete it makes the reader throw.
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
| `device` | `{model, systemName, systemVersion}` | 1 | e.g. `iPhone16,1`, `iOS`, `18.6`. Simulator builds write `Simulator (<model>)`. |
| `notes` | string | 1 | Free text. Simulator builds say what is simulated: `Simulated sensors (simulator build): …` and `Simulated OBD adapter (…)`. |
| `adapter` | object, see below | 2 | Adapter as of start. Absent if started without OBD. |
| `polling` | object, see below | 2 | Polling combination as of start. |
| `sensors` | object, see below | 2 | Requested sensor configuration. |
| `mount` | string | 2 | Mount note from the pre-drive checklist. |
| `vehicle` | string | 2 | Vehicle note. |
| `timeZone` | string | 2 | IANA identifier at start, e.g. `Europe/Kyiv`. Display only. |

`adapter`:

| Field | Type | Meaning |
|---|---|---|
| `name` | string | BLE advertised name. `""` when the BLE layer supplied none. |
| `identifier` | UUID string | `CBPeripheral.identifier` (per phone). `""` when the BLE layer supplied none. |
| `gatt` | `{service, notify, write, writeType, maxWriteLength}` | UART pair used. `writeType`: `withResponse` / `withoutResponse`. `maxWriteLength` in bytes. |
| `gattTable` | `[{service, characteristics: [{uuid, properties: [string]}]}]` | Everything discovered. |
| `elmVersion` | string | `ATZ` banner, e.g. `ELM327 v2.1`. |
| `protocol` | string | Raw `ATDPN` reply, e.g. `A6` (`A` = auto-detected, `6` = ISO 15765-4 CAN 11-bit 500 kbaud). |
| `voltage` | double, V | Parsed `ATRV`. |

`polling`:

| Field | Type | Meaning |
|---|---|---|
| `command` | string | Exact command sent when all PIDs are due, e.g. `010D0C1`; for single-PID polling the first PID plus the suffix (`010D1`). `""` for a plan with no PIDs. |
| `pids` | [int] | PID numbers polled, decimal (`13` = 0x0D). |
| `multiPID` | bool | PIDs combined into one request. |
| `responseCount` | int | Response-count suffix in use; absent if not. |
| `adaptiveTiming` | int | `ATAT` level, 0–2. |
| `rpmEvery` | int | When not combined, RPM is polled every Nth cycle. |
| `timeoutMs` | int, ms | Per-command timeout. |
| `requestHeader` | string | CAN request header set with `ATSH`, e.g. `7E0` (physical addressing to the engine ECU, which answers on `7E8`). Absent for functional addressing (`7DF`, the adapter's default) and in every recording made before this field existed. Added to v2 before the app wrote any v2 recording, so no version bump (same precedent as the `lowDiskSpace` lifecycle value). |

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
| `adapter` | 2 | init finished, or polled combination changed | each (re-)init and change |
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
lets that be recomputed offline (it has millisecond resolution; `ageS` carries
the full precision). `receivedT` and the wall-clock reading behind `ageS` are
taken together once per CoreLocation callback, so a late delivery changes
`receivedT` and `ageS`, not `t`. `ageS` is never clamped: a fix stamped
slightly after the reading has a negative age. GNSS is reference only: ground
truth for evaluation, never an input — the app's source is called
`ReferenceLocationSource` for that reason. It asks CoreLocation for
`kCLLocationAccuracyBest` (not `…BestForNavigation`, which mixes in other
sensors), activity type `otherNavigation` (no reason to snap to roads), no
distance filter and no automatic pausing.

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
| `seq` | int | Increasing within the recording, including across adapter reconnects. **Emission** order, not arrival order: rows held while the `ATZ` banner is being decided may have an earlier `t` than rows written before them. |
| `phase` | string | `init`, `probe`, `poll`, `manual`, `keepalive`. |
| `tx` | string | Command as sent, without CR: printable ASCII, uppercased. For `rejected`: as typed (debug console) or the command's wire form (session-originated). `""` for unsolicited rows. |
| `requestT` | int, ns | Write issued. For `rejected` (never sent), the moment of rejection. For unsolicited rows, equal to `t`. |
| `rx` | string | Reply, verbatim minus `>`. Absent on `rejected` and on a command's own `timeout` row; present on late and unsolicited rows (below). |
| `outcome` | string | See below. |

`outcome`: `ok`, `noData` (the vehicle answered `NO DATA`; see the rule
below), `timeout`, `stopped`, `notRecognised` (`?`), `canError`, `busError`,
`busInitError`, `bufferFull`, `dataError`, `unableToConnect`, `adapterError`
(`ERRxx`), `malformed` (reply arrived but did not parse, including invalid CAN
frames and ISO-TP sequence errors), `rejected` (blocked by the read-only
guard, never sent).

Every command that was sent has at least one `elm` row. A command still in
flight when the session shuts down or the link is lost gets a final `timeout`
row without `rx`, stamped at that moment.

**Late rows.** A command that times out still owes the adapter's `>`. Its own
`timeout` row (no `rx`) is written at the moment of the timeout. The next reply
is paid to the oldest command still owed, not to the command now in flight,
and is written as an extra row with `outcome` `timeout` **and** `rx` present;
`tx`, `phase` and `requestT` are those of the command that timed out, `t` is
when the late reply arrived, and the row has its own `seq`. A late row never
produces `obd` rows.

**Unsolicited rows.** Output no command is waiting for — data buffered when the
adapter connects, replies skipped while waiting for the `ATZ` banner, banner
text arriving while another command waits, or anything arriving while nothing
is owed or in flight — is written with `outcome` `timeout`, `rx` present and
`tx` `""`; `requestT == t`.

**Partial text.** Text received without a `>` when the link ends, or when `ATZ`
is sent, is written as a late row (routed like any late reply, below), or as
an unsolicited row.

**After a written-off prompt.** If a timed-out command's `>` doesn't arrive
within the grace period (default: the command timeout), the command is written
off, and a `link` row with `from == to` and `reason` `no prompt for <tx> within
<grace> of its timeout; written off` records it. From then on replies can't be
matched to commands, so nothing but `ATZ` is sent until `ATZ` is answered with
a banner. Replies arriving in the meantime are late rows for the written-off
commands, oldest first, or unsolicited rows; none becomes data. Late replies
are routed by shape: banner-like text (see "ATZ banner") goes only to a
written-off or owed `ATZ`, `ATI` or `AT@1` — an unsolicited row if there is
none — and anything else to the oldest other command first; written-off
commands before owed ones. Once `ATZ` is answered with a banner, output after
it is unsolicited, and banners held while `ATZ` waited out its window when the
session shuts down follow that `ATZ`'s own `timeout` row as late rows.
- While polling, the logger re-initialises at once (`link` reason `link
  desynchronised: a prompt was written off`), counting towards the re-init
  limit.
- During initialisation the sequence restarts from `ATZ`, with a `link` row
  (`from == to`, reason starting `link desynchronised during initialisation;
  restarting from ATZ`), a bounded number of times.
- A debug-console command is refused and nothing is sent.

**ATZ banner.** Banner-like text (containing `ELM`, or letters, digits and a
version token such as `v1.5`) is only ever accepted as the reply to `ATZ`,
`ATI` or `AT@1`; anywhere else it is a late or unsolicited row. The first reply
containing `ELM` is the banner. If an `ATZ`/`ATI`/`AT@1` was written off, `ATZ`
waits its full reset timeout and takes the last banner, and earlier banners are
late rows for the written-off commands. If no reply contains `ELM` within the
reset timeout, the last banner-like reply is used, and a `link` row with
`from == to` and `reason` `ATZ banner without 'ELM': <banner>` records it. If
there was none, initialisation fails at `ATZ`.

**`noData` and polling.** A PID that has never answered successfully in this
session (poll or probe) is dropped from polling on `NO DATA`. A PID that has
answered successfully before is never dropped: its `NO DATA` counts as a
failure (retry, then re-initialise, then reconnect), whatever the `0100`
bitmask says. A multi-PID request that answers `NO DATA` falls back to single
PIDs only if that exact request has never answered successfully; otherwise it
is a failure too.

### `adapter`

After `ATRV`, `ATSH7E0` (physical addressing to the engine ECU) is sent only
when `ATDPN` reported 11-bit ISO 15765-4 CAN (`6`, `A6`, `8`, `A8`) and `0100`
was answered from `7E8`; otherwise it is skipped. Physical addressing engages
only if `ATSH7E0` answers `OK`. If it doesn't — or it was skipped — requests
stay functional (`7DF`), a `link` note records why, and initialisation and
recording carry on: this is not an error. The poll command is then chosen at start-up: the first of `010D0C1` →
`010D0C` → `010D1` → `010D` whose reply carries the engine's value for every
requested PID; single-PID steps also send `010C1` / `010C`. The suffix steps
(`…1`) are tried only if `ATSH7E0` was answered `OK`. If nothing parses with
physical addressing (or only without vehicle speed), `ATSH7DF` is sent and the
selection runs again functionally, `010D0C` → `010D`. `ATAT2` replaces `ATAT1`
only if it measured faster. If nothing parses: `010D`, with `010C` every 5th
cycle, at `ATAT1`, functional. `polling` records the combination, including
`requestHeader`.

`ATSH7E0` appears in `elm` rows with phase `init` (the conditional last
handshake step); `ATSH7DF` with phase `probe` (physical selection found
nothing) or `poll`; `ATSH7E0` with phase `poll` (restoring a physical plan's
addressing, e.g. after a re-init).

`{adapter, polling}`, same shapes as the header sections. Written after every
successful initialisation, including re-inits and reconnects mid-drive, when
polling starts with a combination other than the last one written, and
whenever the polled combination changes (a PID dropped, the multi-PID
fallback). Its `polling` section is always the combination actually being
polled.

### `link`

| Field | Meaning |
|---|---|
| `layer` | `ble` or `elm`. |
| `from`, `to` | State names. `elm` states: `idle`, `resetting`, `initialising`, `searching`, `probing`, `ready`, `polling`, `retrying`, `reinitialising`, `failed`. `ble` states: `unavailable`, `idle`, `scanning`, `connecting`, `discovering`, `connected`, `disconnected`, `reconnecting`, `restoring`. |
| `reason` | Optional free text, e.g. `timeout`. `elm` `failed` reasons include `transport closed`, a re-init limit message, or a read-only-guard rejection of a session command (followed by no reconnect request). Rows with `from == to` are notes (write-offs, init restarts, non-`ELM` banners, addressing), not transitions. Addressing notes: `ATSH7E0 skipped: protocol <n> is not 11-bit ISO 15765-4 CAN (6, A6, 8, A8); requests stay functional (7DF), no response-count suffix`, `ATSH7E0 skipped: no 7E8 reply to 0100; …`, `ATSH7E0 not accepted (<outcome>); requests stay functional (7DF), no response-count suffix`, `late OK for ATSH7E0; requests go to 7E0`, `late OK for ATSH7DF; requests go to 7DF`, `no poll command parsed with physical addressing (7E0); selecting again with functional addressing (7DF), no response-count suffix` (or, when `ATSH7DF` is refused or never answered, `…; ATSH7DF not accepted (<outcome>); physical addressing disabled for this session; re-initialising without ATSH7E0`, followed by a second handshake from `ATZ` and functional selection), `ATSH7E0 skipped: physical addressing disabled for this session: ATSH7DF not accepted (<outcome>); requests stay functional (7DF), no response-count suffix` (every handshake after that, for the rest of the connection), `physical addressing unavailable: <cause>; polling with functional addressing (7DF), no response-count suffix` and `physical addressing available again; polling <command> at 7E0` (the gate closed or reopened at a re-init, or a physical plan was started on a closed gate; each followed by an `adapter` row with the plan now polled — no `adapter` row ever carries a plan that isn't polled). While polling, a refused `ATSH<header>` is a failure with reason `ATSH<header>: <outcome>`, except a refused `ATSH7DF`, which re-initialises at once with reason `ATSH7DF not accepted (<outcome>); physical addressing disabled for this session; re-initialising without ATSH7E0`; a suffixed poll under functional addressing is refused (an `elm` `rejected` row, then `failed`). |

### `lifecycle`

| Field | Meaning |
|---|---|
| `event` | `start`, `stop`, `pause`, `resume`, `background`, `foreground`, `calibrationStart`, `calibrationEnd`, `error`, `memoryWarning`, `thermalState`, `protectedDataUnavailable`, `lowDiskSpace`. Calibration is the first phase of a recording: the samples between `calibrationStart` and `calibrationEnd` were taken with the car and phone still. |
| `detail` | Optional free text (error description, thermal state name, stop reason). An event that couldn't be encoded (e.g. a NaN or infinite value) is replaced by an `error` row at the same `t` with detail `encodingFailed <kind>: <description>`. |

What the app writes (all at `clock.now()` when written):

| `event` | `detail` | When |
|---|---|---|
| `start` | absent, or `without OBD: link <state>` | First row. The second form when the user chose to record without a polling adapter (the header then has no `adapter`/`polling`). |
| `calibrationStart` | `keep still for <s> s` | Right after `start`: the keep-still phase begins. |
| `calibrationEnd` | absent; `cut short after <s> s`; `interrupted by stop` | End of the keep-still phase. Back to back with `calibrationStart` when calibration was skipped. `interrupted by stop` when the recording was stopped during calibration (it is then followed by `stop`). |
| `background` / `foreground` | absent | The app entered the background / left it. Each `background` is followed by a flush. |
| `memoryWarning` | absent | The system sent a memory warning; a flush follows. |
| `thermalState` | `nominal`, `fair`, `serious`, `critical` | At start when not `nominal`, then on every change. |
| `protectedDataUnavailable` | free text | The device was locked with a passcode. Recording continues: files are `completeUntilFirstUserAuthentication`. |
| `error` | `<source> unavailable: <reason>` | A sensor source could not run at start (e.g. no permission, no barometer). The rest of the recording goes on. |
| `error` | `<source> failed to start: <error>` | A sensor source threw when started. |
| `error` | `<source>: <error>` | A sensor reported an error while running; once per distinct error per source. Also `rawIMU: magnetometer unavailable; recording accel and gyro only`. |
| `error` | `writer queue peaked at <n> events, more than 2 s of data (<m>)` | The writer fell behind in that `stats` window (written after the `stats` row). |
| `error` | `write failed: <description>` | A write failure (below). |
| `lowDiskSpace` | see below | Free space crossed a threshold. |
| `stop` | `user` or `lowDiskSpace` | The normal stop path, followed by the final `stats` row and nothing else. |

Source names in `error` details: `deviceMotion`, `rawIMU`, `altimeter`,
`referenceLocation` on a phone; `simulatedMotion`, `simulatedMagBaro`,
`simulatedLocation` in simulator builds.

Stop reasons (`detail` of `stop`): `user` (the user stopped the recording) or
`lowDiskSpace` (free space fell below the stop floor). The strings are pinned
in Core (`LifecycleSample.StopReason`). Every sensor source is stopped before
the `stop` row is written, so no sensor or link row follows it; the final
`stats` row is the last line of a cleanly stopped file.

A **write failure** (`ENOSPC`, an I/O error, a failed `fsync`) ends the
recording: an `error` row with detail `write failed: <description>` is
written — it may not reach the disk — and the file is closed, with no `stop`
row and no final `stats` row. If the failure happens while a normal stop is
already under way, the `stop` row may be present, and the `error` row may sit
just before it or be missing; a failure in the very last write of a stop
leaves the `stop` row but no further row. **The app's state (failed, with the
count of unwritten events) is authoritative, not the file.** A truncated tail
or a missing final `stats` row is the file-side sign.

Low disk space ("warn, then stop at a floor"; thresholds default to 200 MB and
50 MB free):

| Row | `detail` | Meaning |
|---|---|---|
| `lowDiskSpace` | `warning: <bytes> free` | Free space fell below the warning threshold. Recording continued. Written again only if space recovered well above the threshold and fell again. |
| `lowDiskSpace` | `floor: <bytes> free` | Free space fell below the stop floor. Precedes the `stop` row in write order (rows of other kinds may sit between them); the recording then stops through the normal path. |
| `stop` | `lowDiskSpace` | The clean stop caused by the floor. The final `stats` row is still written. |

`<bytes>` is the free-space reading, in bytes, that crossed the threshold. A
reading that drops below both thresholds at once produces both `lowDiskSpace`
rows, `warning` first. No `lowDiskSpace` row follows the `stop` row. The
prefixes `warning: ` and `floor: ` are pinned in Core
(`LifecycleSample.lowDiskSpaceWarningPrefix` / `…FloorPrefix`). Like all
`detail` text this is for humans and `inspect_log`; a reader should not depend
on more than the prefix.

Free space is the smaller of the volume's "important usage" and plain
available capacity (purgeable space is not counted). A recording is not
started below the warning threshold.

### `stats`

Recorder health over the preceding window. Computed live because queue depth
and drops can't be reconstructed afterwards. Written every 10 s while
recording (calibration included), and once more right after the `stop` row,
closing the last, shorter window. The counts come from the writer itself —
the one place every row passes, in write order — so every row of the file
(this kind included: a `stats` row is counted in the next window) is counted
in exactly one `stats` row of a cleanly stopped recording. `t` is the end of
the window.

| Field | Type, unit | Meaning |
|---|---|---|
| `windowS` | double, s | Window length (10). The first window starts at the first observed event. |
| `counts` | {kind: int} | Events written in the window, by kind. |
| `obdHz` | double, Hz | `elm` rows with phase `poll` and outcome `ok`, per second. |
| `motionHz` | double, Hz | `motion` events per second. |
| `gaps` | {kind: int} | Intervals > 50 ms in `motion`, `accel`, `gyro`, in timestamp order, including the stream's last sample from the previous window. Always has all three keys. |
| `maxGapMs` | {kind: double}, ms | Longest interval per kind; only kinds with at least one interval. |
| `timeouts` | int | `elm` rows with outcome `timeout` and no `rx` — one per command that timed out (late and unsolicited rows excluded). |
| `queueDepthMax` | int, events | Peak writer queue depth in the window: events handed to the writer and not yet encoded, measured at every hand-over (not sampled), starting from the depth carried over from the previous window. A peak above 2 s of data is also written as a `lifecycle` `error` row. |
| `dropped` | int | Events refused in the window. Only possible after the file was closed; always 0 in a healthy file. |
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

### inspect_log

```bash
cd Core && swift run -c release inspect_log <file.jsonl.gz|file.jsonl> [--csv <dir>] [--strict]
```

Prints the header, events per kind, rates, gaps over 50 ms, OBD latency
(`t − requestT`) percentiles, `elm` outcome counts and a damage/truncation
report. `--csv` writes one CSV per kind: `t` in integer nanoseconds, empty cell
for an absent field, RFC 4180 quoting, compact JSON for `stats.counts` and for
unknown kinds. `--strict` stops at the first damaged member or malformed line.
Exit codes: `0` the file was read (warnings such as truncation, damage or
skipped lines are printed, not fatal), `1` unreadable file, `2` usage error.

Simulated recordings (simulator builds): locations have `simulated: true`,
`fixTime` derived from the header wall clock and `ageS` 0.
