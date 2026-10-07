# DriveLogger v1 — logger specification

What version 1 must do. How it is built is in `WORKFLOW.md`; repository rules and invariants are in `CLAUDE.md`, which wins on any conflict with this file.

## Goal

Record time-synchronised OBD-II speed, phone motion sensors and reference GPS during real drives into files that can be exported and replayed on a Mac. Capture fidelity matters more than UI polish: nothing is computed live that could be computed later from a recording.

Do not copy code from github.com/leea-software/gpsless (PolyForm Noncommercial licence). Ideas are fine; write the code yourself.

## Hardware

- Adapter: Vgate iCar Pro Bluetooth 4.0 — BLE, ELM327-compatible clone. Details and the field checklist: `.claude/skills/elm327-protocol/SKILL.md`.
- Vehicle: VW Touareg 2025, ISO 15765-4 CAN (expected protocol 6, 11-bit 500 kbaud — verify with `ATDPN`).
- Phone: iPhone in a rigid mount, fixed orientation for the whole drive.

### BLE

- Do not hard-code one GATT layout. Scan for peripherals (name usually contains `Vlink` or `iCar`), let the user pick from a list, remember the choice by `peripheral.identifier`.
- Discover all services and characteristics; select the UART pair automatically: one notify/indicate characteristic and one write/writeWithoutResponse characteristic. Preferred known layouts, in order:
  1. `E7810A71-73AE-499D-8C15-FAA9AEF0C3F2` / `BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F` (Vgate)
  2. `FFF0` (`FFF1` notify, `FFF2` write)
  3. `FFE0` (`FFE1` notify + write)
- Record the full discovered GATT table (UUIDs + properties) in the recording.
- Responses arrive in arbitrary BLE fragments: buffer bytes until the `>` prompt, then parse. Handle `SEARCHING...`, `NO DATA`, `STOPPED`, `?`, `CAN ERROR`, `BUS INIT`, `UNABLE TO CONNECT` and echoes. Split lines on the unicode-scalar view (see CLAUDE.md conventions).

## ELM327 protocol (Core, pure Swift, fully unit-tested)

- Build on the existing `ELM327Command`, `ELM327ResponseParser`, `OBDPID`, `OBDDecoder`.
- Init sequence: `ATZ` (wait for the banner, capture the version string) → `ATE0` → `ATL0` → `ATS0` → `ATH1` (headers on, to tell ECUs apart) → `ATSP0` → `0100` (forces protocol search; allow ~10 s) → `ATDPN` → `ATRV`, then `ATSH7E0` (physical addressing to the engine ECU) **only on 11-bit ISO 15765-4 CAN** — `ATDPN` is `6`, `A6`, `8` or `A8` — **and only if the `0100` reply had a `7E8` line**. On other protocols a 3-digit `ATSH` isn't an OBD request ID, so it is skipped with a recorded note. Physical addressing engages only if `ATSH7E0` answers `OK`; otherwise requests stay functional (`7DF`) and a note is recorded. The gate is re-evaluated on every re-init. Record every command and raw response.
- Polling: exactly one command in flight; per-command timeout (1 s default); retry, then re-init after N consecutive failures, then BLE reconnect. Model it as a state machine with named states; record every transition.
- PIDs: speed (`0D`) every cycle, RPM (`0C`) with it. Default poll command on the test car is `010D0C1` after `ATSH7E0` — one request, one reply from `7E8`, both values (verified on the bench, see `docs/BENCH_TEST_2026-10-07.md`). Fallbacks, in order, if a step fails at start-up: `010D0C` without the suffix → `010D1` → `010D`; a step counts only if the reply carries `7E8`'s value for every requested PID. If nothing parses with physical addressing (or only without speed), send `ATSH7DF` and select again functionally, `010D0C` → `010D`, without the suffix. If nothing parses at all, poll `010D` (with `010C` every 5th cycle) functionally. Also try `ATAT2` vs `ATAT1` and keep the higher stable rate. Record which combination is in use.
- Never use the response-count suffix unless `ATSH7E0` answered `OK`: with functional addressing (`7DF`) the first reply wins, and on the test car that was the gearbox (`7E9`), not the engine.
- Parse multi-line and multi-ECU answers (`7E8`, `7E9`, …); take speed from `7E8`, keep the rest. Support both header-on and header-off formats in the parser. On the test car both `7E8` and `7E9` answer functional requests and both support `0C`/`0D`.
- OBDonUDS (`22F4xx`) is not needed on the test car (`22F40D` → `NO DATA`, mode `01` works); keep it out of v1.
- `NO DATA` for a PID means the vehicle does not implement it: record it and stop polling that PID — but only if the PID has never answered successfully in this session. A PID that has answered OK is never dropped; its `NO DATA` is a transient failure (retry → re-init → reconnect). See the CLAUDE.md convention.
- Keep the raw response alongside the parsed value, always.
- Read-only: only allowlisted `AT` commands and mode `01` PIDs may ever be sent (the allowlist is `ELMCommandPolicy`; see README "ELM327 commands"). Enforce at the API boundary and test it. Never send modes 04, 08, 2E, 31, 3B or any coding/UDS request.
- Measure and record the achieved OBD rate (Hz).

## Sensors (App)

- `CMMotionManager` device motion at 100 Hz, reference frame `xArbitraryZVertical`: user acceleration, rotation rate, gravity, attitude quaternion. Also raw accelerometer and gyroscope at 100 Hz, magnetometer at ~10 Hz, `CMAltimeter` relative altitude and pressure.
- `CLLocationManager` as **reference only** (ground truth for later evaluation, never an input): best accuracy, all fields — coordinate, horizontal accuracy, speed, speed accuracy, course, course accuracy, altitude.
- Convert into Core's `MotionSample`, `LocationSample`, `OBDSample` at the app boundary, field for field.

## Time

Exactly as CLAUDE.md "All sensor timestamps come from one monotonic clock": one `SessionClock` per recording, `MonotonicTimestamp` on every event, CoreMotion's uptime base, wall clock captured once in the header, negative offsets never clamped.

- OBD: record both request-sent and reply-received timestamps (`clock.now()` at each).
- GPS: the fix time converted to the session clock plus the receive time.

## Log format

Current format: JSON Lines, `LogHeader` then one `LogEvent` per line, kinds `motion`, `location`, `obd`, `marker` (see `docs/LOG_FORMAT.md` and `Core/Sources/DriveLoggerCore/Log/`).

v1 needs these additions — M0 decides for each whether it fits the current format version or requires a new one, following the versioning rules in CLAUDE.md:

- Header: adapter name/identifier, GATT layout used, ELM version string, detected protocol, polling combination in use, mount note, vehicle note.
- `obd`: add request-sent timestamp, command, raw reply text, responding ECU header.
- New kinds (proposed names, final names decided in M0 and then frozen): raw ELM traffic and init/diagnostics; raw accelerometer; raw gyroscope; magnetometer; barometer; lifecycle/connection events (start, stop, pause, background/foreground, BLE connect/disconnect, errors, calibration); `stats` every 10 s (events per kind, OBD Hz, motion Hz, gaps > 50 ms, timeouts, writer queue depth).
- User markers keep using `marker`.

Files:
- One session = one gzip-compressed JSON Lines file `Drive_<yyyyMMdd-HHmmss>.jsonl.gz` in `Documents/logs` (visible in the Files app).
- Writing happens off the main thread in a buffered writer owned by one actor (one `LogCodec` per writer). Flush at least every 2 s, on stop and on entering background. A crash may lose at most the last few seconds.
- The reader tolerates a truncated gzip tail and a half-written last line (`LogRecovery.skipMalformedLines`).

## Background

Recording must continue with the screen locked and the app in the background for a 2-hour drive: `bluetooth-central` and `location` background modes, CoreBluetooth state restoration, a live location session while recording. Record lifecycle transitions as events.

## UI (SwiftUI, minimal, readable at arm's length in a mount)

- Recording screen: adapter status (scanning / connecting / initialising / polling + protocol + voltage); large live OBD speed and GPS speed side by side; OBD Hz, motion Hz, elapsed time, file size; large Start, Stop and Mark buttons (Mark writes a `marker` event, e.g. "tunnel", "traffic jam"). Screen stays awake while recording.
- Before Start: checklist "phone in rigid mount, fixed orientation" and a 5-second keep-still calibration, recorded as an event.
- Debug screen: raw ELM console (every TX/RX line) with a manual command field restricted to the read-only queries `ATI`, `AT@1`, `ATDP`, `ATDPN`, `ATRV` and mode `01` PIDs (`ELMCommandPolicy` scope `.manual`; configuration commands are reserved for the session).
- Sessions list: duration, size, date; export via the share sheet; delete with confirmation.
- Simulator: clear "Bluetooth / motion unavailable" states, no crash.

## Tests and tools

- Core unit tests (Swift Testing): ELM reply parsing (fragmented chunks, echoes, `NO DATA`, multi-ECU, multi-PID, header on/off), PID decoding (`0x0D` = A km/h, `0x0C` = (256A+B)/4 rpm), read-only command guard, polling state machine (timeouts, retry, re-init) against a mock ELM327 adapter, writer/reader round trip, truncated-gzip and half-line reading, one frozen fixture per format version.
- Mac command-line tool `inspect_log` (Swift, uses Core): header, events per kind, OBD rate and latency, gaps, CSV export per kind for analysis in Python.

## Done means

- `cd Core && swift test` passes; the simulator build and app tests pass; the app runs in the simulator without crashing.
- `docs/LOG_FORMAT.md` is the full field-by-field reference with units; README and CLAUDE.md list any new commands.
- Small logical commits.
- A short "Field test checklist" for the first drive: what to check in the car, what to look for in the debug screen, which `inspect_log` output shows the log is good.
- Final acceptance (WORKFLOW.md M5): three consecutive drives with debrief verdict GOOD, one of them at least 1 hour with the screen locked.
