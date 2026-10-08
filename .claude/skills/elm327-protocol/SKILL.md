---
name: elm327-protocol
description: Reference for talking to an ELM327-compatible BLE OBD-II adapter (Vgate iCar Pro BLE 4.0) from iOS - GATT discovery, framing, init sequence, response formats, PID formulas, speed-up tricks and the hardware field checklist. Use for any ELM327, OBD-II PID or OBD BLE work.
---

# ELM327 over BLE - working reference

Target: Vgate iCar Pro BLE 4.0 in a VW Touareg 2025. **Bench-tested 2026-10-07** (`docs/BENCH_TEST_2026-10-07.md` has the verbatim transcripts):
- BLE name `IOS-Vlink`; `ATI` → `ELM327 v2.3`.
- `ATDPN` → `6`: ISO 15765-4 CAN, 11-bit, 500 kbaud, confirmed.
- Two ECUs answer functional requests: `7E8` (engine) and `7E9` (most likely the gearbox). Both support `0C` and `0D`.
- OBDonUDS is not needed: `22F40D` → `NO DATA`, and mode `01` works. Keep mode 22 out of v1; the read-only guard rejects it anyway.
- `ATRV` read 11.0 V (engine off) and 11.8 V (idling): low, as cheap clones under-read. Record it, but don't alarm on it.

Things still marked (verify) haven't been checked on the device yet; clones differ between batches.

## GATT discovery
- Do not hard-code. Scan, let the user pick, remember `peripheral.identifier`. The test adapter advertises as `IOS-Vlink`; other batches may use `iCar` names.
- Discover all services/characteristics; choose one notify/indicate characteristic + one write/writeWithoutResponse characteristic. Known layouts, in order of preference:
  1. Service `E7810A71-73AE-499D-8C15-FAA9AEF0C3F2`, characteristic `BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F` (notify + write, Vgate) (verify)
  2. Service `FFF0`: `FFF1` notify, `FFF2` write
  3. Service `FFE0`: `FFE1` notify + write
- Log the full GATT table (UUIDs + properties) into the session header.
- Writes: ASCII command + `\r`. Respect `maximumWriteValueLength(for:)` (often 20 bytes); split if longer.

## Framing
- Notifications arrive in arbitrary fragments. Append bytes to a buffer; a response is complete only when the `>` prompt arrives. Strip `\r`, `\n`, NUL, the echoed command, and the prompt.
- Possible non-data lines: `SEARCHING...`, `BUS INIT: ...`, `NO DATA`, `STOPPED`, `?`, `CAN ERROR`, `BUFFER FULL`, `UNABLE TO CONNECT`, `ELM327 v...`, `OK`. Treat them as statuses, never as data.
- One command in flight. Default timeout 1.0 s (first `0100` after `ATSP0` can take several seconds while searching - allow ~10 s).

## Init sequence
`ATZ` (reset, wait for banner; capture version string) -> `ATE0` (echo off) -> `ATL0` (linefeeds off) -> `ATS0` (spaces off) -> `ATH1` (headers ON: needed to tell ECUs apart) -> `ATSP0` (auto protocol) -> `0100` (forces search) -> `ATDPN` (log detected protocol; `6` on the test car, `A6` when auto-detected) -> `ATRV` (battery voltage) -> **`ATSH7E0`** (physical addressing to the engine ECU), only if `ATDPN` is `6`/`A6`/`8`/`A8` and `0100` had a `7E8` line. A 3-digit `ATSH` means header `00 0x yz`, which isn't an OBD ID on 29-bit CAN or K-line/J1850. Physical addressing engages only if it answers `OK`. If it doesn't, stay functional, record a note and carry on (see recipe step 4). If nothing parses at 7E0, send `ATSH7DF` and select again functionally.
Optional speed tuning, try and measure: `ATAT2` (aggressive adaptive timing). **Keep `ATAT1` unless `ATAT2` is clearly better**: the session sends the chosen poll command 10 times at `ATAT1` and 10 times at `ATAT2` and keeps `ATAT2` only if every reply parses and its median latency is at least 10% lower (`ELMSession.adaptiveTimingSamples`, `adaptiveTimingMinimumGain`); a `link` note `adaptive timing: …` records the decision. Bench 2026-10-08: steady state identical at both levels (59 ms median, 16.4 Hz), and a 3-sample probe had flipped to `ATAT2` on noise.

**Remembered plan across reconnects (M6.1-3).** The link service carries the chosen plan (`adaptiveTiming` and `requestHeader` included) into the next `ELMSession` on the same peripheral, like `nextSeq`, in memory for the app session; a different adapter or Forget clears it. The handshake still runs in full and the `ATSH7E0` gate is re-evaluated. The plan is reused only if its `requestHeader` matches what the gate produced, the `ATZ` banner is the same, and it validates; then the session sends `ATAT<n>` (the remembered level) and **one check poll cycle** (phase `probe`) instead of selection plus the 20-poll comparison. It fails if `ATAT<n>` isn't `OK` or any check exchange lacks the primary ECU's value for a requested PID (`NO DATA`, timeout, status, other ECU only); then the full selection and comparison run, at most once per init. Notes: `poll plan reused from the previous connection: 010D0C1, ATAT1, requestHeader 7E0`, `reused plan failed (<reason>); selecting again`, `remembered poll plan not reused: <why>; selecting again` (`ELMSession` doc, "Remembered poll plan").

## Recipe for the test car (bench-verified)
1. Finish init with `ATSH7E0` → `OK`. From now on requests go to the engine ECU only; `7E9` stays silent.
2. Poll speed + RPM with one request: `010D0C1` → `7E806410D000C0A5C` (one line from `7E8`: speed `00` = 0 km/h, RPM `0A5C`/4 = 663).
3. Start-up fallbacks, in order, if a step's reply doesn't parse (no `7E8` value for every requested PID): `010D0C1` → `010D0C` → `010D1` → `010D`.
4. If `ATSH7E0` did not answer `OK` (or was skipped), stay on functional addressing (`7DF`), record a note, and carry on: it is not an init failure and recording continues. **Never** use the `1` suffix then: the order becomes `010D0C` → `010D`.
5. Record which combination is in use (the `adapter` row's `polling` section).

`ATSH` is allowlisted only for the OBD request headers `7DF` and `7E0`–`7E7` (session scope; the debug console can't send it). Response headers (`7E8`…), other modules (`6F1`, `7xx`) and 29-bit headers stay blocked.

### Pitfall: the suffix picks the first ECU, not the engine
Under functional addressing (`7DF`) the response-count suffix stops after the **first** reply, whichever ECU sends it. On the test car `010D1` returned only `7E903410D00`, i.e. the gearbox (`7E9`), not the engine. Speed from the "wrong" ECU looks plausible and can't be detected from one line. That's why the suffix is only used after `ATSH7E0` returned `OK`.

## Response format (ATS0, ATH1, CAN 11-bit)
`7E803410D3C` = header `7E8` (engine ECU reply) + PCI `03` (3 data bytes) + `41` (mode 01 + 0x40) + `0D` (PID) + `3C` (A).
Several ECUs may answer (`7E8`, `7E9`, ...): keep all lines, choose the value from `7E8` for speed, log the rest. On the test car, functional `010D` returns two lines: `7E903410D00` then `7E803410D00`. Don't assume `7E8` comes first.
With `ATH0` the same answer is `410D3C` - support both in the parser (tests for each).

## PIDs (mode 01, read-only)
| PID | Meaning | Formula | Notes |
|-----|---------|---------|-------|
| 0x00 | supported PIDs 01-20 | bitmask A..D | log once at start |
| 0x0D | vehicle speed | A km/h | integer km/h only, 0-255 |
| 0x0C | engine RPM | (256A + B) / 4 | |
| 0x11 | throttle position | A * 100 / 255 % | optional |

Multi-PID: `010D0C` returns both in one frame: `7E806410D000C0000` on the test car, functional addressing also gives a `7E9` line. Verified working.
Response-count suffix: `010D1` tells the ELM to stop after the first reply instead of waiting for the timeout. It's often the biggest rate win, and it works on the v2.3 clone. **Only with `ATSH7E0`** (see the pitfall above).

## Safety
Only allowlisted `AT` commands (`ELMCommandPolicy`; see the README "ELM327 commands") and mode `01` requests may be sent. Never send modes 04 (clear DTCs), 08, 2E, 31, 3B or any UDS/coding request. Enforce at the API boundary.

## Expected rates
Cheap clones: 3-10 Hz for one PID; with `ATAT2` + response-count suffix sometimes 15-25 Hz (verify). Log the achieved rate every 10 s.

## Field checklist (hardware only - cannot be tested in the simulator)
1. Parked, ignition ON, engine off: adapter visible in scan as `IOS-Vlink`, GATT table logged, `ATZ` banner (`ELM327 v2.3` expected), `ATDPN` = 6, `ATRV` logged (11–12 V on this clone, under-reads), `ATSH7E0` → `OK`. *Done 2026-10-07 in Car Scanner, except the GATT table and the app's own init.*
2. `010D` returns `00` speed; `010C` returns 0 RPM with engine off, ~600-800 with engine idling. *Done: 663 rpm at idle via `010D0C1`.*
3. Measure the poll rate (Hz) of `010D0C1` after `ATSH7E0`, and `ATAT1` vs `ATAT2`. Keep the fastest stable combo. *Done 2026-10-08: 16.4 Hz, p50 59 ms either way; `ATAT2` cut no replies short. Since then the session keeps `ATAT1` unless `ATAT2` is ≥ 10% faster over 10 samples each: check the `adaptive timing:` note says `ATAT1 kept` on this car.*
4. Lock the screen for 5 minutes while polling: rows must continue (check `stats`).
5. Unplug/replug the adapter while recording: app must reconnect and re-init on its own and log both events. *Done 2026-10-08 (7.2 s re-init).* Since the M4 follow-up the re-init must show `poll plan reused from the previous connection: …`, `ATAT<n>` and one check poll instead of the selection and the `adaptive timing:` comparison, and reach `polling` sooner.
6. `ATDPN` after the app's own `ATSP0` (expect `A6`); `ATSH7E0` → `OK`; with 7E0, replies only from `7E8`. On a non-11-bit car, `ATSH7E0` must not appear in the `elm` rows.
