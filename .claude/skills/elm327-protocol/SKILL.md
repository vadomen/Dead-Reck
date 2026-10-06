---
name: elm327-protocol
description: Reference for talking to an ELM327-compatible BLE OBD-II adapter (Vgate iCar Pro BLE 4.0) from iOS - GATT discovery, framing, init sequence, response formats, PID formulas, speed-up tricks and the hardware field checklist. Use for any ELM327, OBD-II PID or OBD BLE work.
---

# ELM327 over BLE - working reference

Target: Vgate iCar Pro BLE 4.0 (ELM327 v2.x clone) in a VW Touareg 2025 (ISO 15765-4 CAN, expected 11-bit 500 kbaud = protocol 6). Verify everything marked (verify) on the real device; clones differ between batches.

## GATT discovery
- Do not hard-code. Scan, let the user pick, remember `peripheral.identifier`. Name usually contains `Vlink` or `iCar` (verify).
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
`ATZ` (reset, wait for banner; capture version string) -> `ATE0` (echo off) -> `ATL0` (linefeeds off) -> `ATS0` (spaces off) -> `ATH1` (headers ON: needed to tell ECUs apart) -> `ATSP0` (auto protocol) -> `0100` (forces search) -> `ATDPN` (log detected protocol; expect `A6` or `6`) -> `ATRV` (battery voltage).
Optional speed tuning, try and measure: `ATAT2` (aggressive adaptive timing). If anything misbehaves, fall back to `ATAT1`.

## Response format (ATS0, ATH1, CAN 11-bit)
`7E803410D3C` = header `7E8` (engine ECU reply) + PCI `03` (3 data bytes) + `41` (mode 01 + 0x40) + `0D` (PID) + `3C` (A).
Several ECUs may answer (`7E8`, `7E9`, ...): keep all lines, choose the value from `7E8` for speed, log the rest.
With `ATH0` the same answer is `410D3C` - support both in the parser (tests for each).

## PIDs (mode 01, read-only)
| PID | Meaning | Formula | Notes |
|-----|---------|---------|-------|
| 0x00 | supported PIDs 01-20 | bitmask A..D | log once at start |
| 0x0D | vehicle speed | A km/h | integer km/h only, 0-255 |
| 0x0C | engine RPM | (256A + B) / 4 | |
| 0x11 | throttle position | A * 100 / 255 % | optional |

Multi-PID: `010D0C` may return both in one frame (`7E806410D3C0C1AF8`). Try once at start; if the answer parses correctly, use it, else fall back to single PIDs.
Response-count suffix: `010D1` tells the ELM to stop after the first reply instead of waiting for the timeout - often the biggest rate win. Clones may not support it (verify): if the reply is `?` or wrong, disable.

## Safety
Only `AT*` and mode `01` requests may be sent. Never send modes 04 (clear DTCs), 08, 2E, 31, 3B or any UDS/coding request. Enforce at the API boundary.

## Expected rates
Cheap clones: 3-10 Hz for one PID; with `ATAT2` + response-count suffix sometimes 15-25 Hz (verify). Log the achieved rate every 10 s.

## Field checklist (hardware only - cannot be tested in the simulator)
1. Parked, ignition ON, engine off: adapter visible in scan, GATT table logged, `ATZ` banner, `ATDPN` = 6, `ATRV` ~12 V.
2. `010D` returns `00` speed; `010C` returns 0 RPM with engine off, ~600-800 with engine idling.
3. Measure the poll rate for: single PID, multi-PID, with/without `1` suffix, `ATAT1` vs `ATAT2`. Keep the fastest stable combo.
4. Lock the screen for 5 minutes while polling: rows must continue (check `stats`).
5. Unplug/replug the adapter while recording: app must reconnect and re-init on its own and log both events.
