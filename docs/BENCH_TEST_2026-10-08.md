# Bench test — DriveLogger on the iPhone, test car parked (2026-10-08)

First bench session recorded with our own app (build `logger-v1-rc1`, DriveLogger
0.1.0 (1), iPhone17,2, iOS 27.0.1, log format v2). VW Touareg 2025, engine
idling, Vgate iCar Pro BLE 4.0 (`IOS-Vlink`). One recording, 603 s, 211,308
rows, 297 gzip members, `inspect_log --strict` clean, ended by a user `stop`.
The recording itself is kept outside the repo.

Markers were placed by hand ("baseline", "lock", "unplug", "replug", "end")
and are not at the events; the times below come from `lifecycle` and `link`
rows. `t` is seconds on the session clock.

## Results

| # | Check | Result |
|---|---|---|
| 1 | GATT | Vgate layout: service `E7810A71-73AE-499D-8C15-FAA9AEF0C3F2`, one characteristic `BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F` for notify and write; `writeType` `withResponse`; `maxWriteLength` 182 (MTU negotiated up). Also offered: `18F0` (`2AF0` notify/indicate, `2AF1` write/writeWithoutResponse) and `180A` (device info). No write failures. |
| 2 | Poll plan | `010D0C1` (speed + RPM, one reply), `requestHeader` `7E0`, replies from `7E8` only. 16.4–16.5 exchanges/s; latency p50 59.2 ms, p95 74.1 ms, max 131.5 ms; the loop is latency-bound. `ATDPN` → `A6` after our `ATSP0`; `ATSH7E0` → `OK` (seen in the re-init; the start-up init ran before Start and is not in the file). |
| 3 | `ATAT1` / `ATAT2` | Start-up kept `ATAT1`. The re-init's 3-sample probe picked `ATAT2` (58.9 vs 63.5 ms). Steady state identical: median 59.3 vs 59.2 ms, 16.40 vs 16.4 Hz. No short replies under `ATAT2` (1544/1544 polls well-formed). |
| 4 | Screen locked | Lock 165 s (`background` 203.25 → `foreground` 368.33, `protectedDataUnavailable` at 203.14), **not the planned 5 min**. Every kind continued: motion/accel/gyro 100.2 Hz with 0 gaps > 50 ms, OBD 16.4 Hz, `stats` every 9.96–10.04 s. Seven short unplanned background episodes (1–32 s) also show no loss. |
| 5 | Unplug / replug | `CAN ERROR` 462.53 → timeout and write-off 464.82 → BLE `disconnected` 465.55 ("The connection has timed out unexpectedly.") → reconnect attempt 1 after 1 s, pending until the adapter returned → `connected` 488.62 (+23.1 s) → full re-init with `ATSH7E0` → `OK` → polling 495.82 (+30.3 s). 5.5 s of the 7.2 s re-init is `0100` `SEARCHING...` after `ATSP0`. OBD outage 33.4 s, mostly the adapter being unplugged. `seq` continuous (13129 → 13130), no resets or duplicates. |
| 6 | Also | `ATZ` → `ELM327 v2.3`. `ATRV` 12.2 V (start-up, header) and 11.8 V (re-init). One write-off and one re-init, both from the unplug. No `7E9` under physical addressing (only in the functional `0100` reply). No `NO DATA`, no dropped PIDs. Writer queue max 27, 0 dropped. |

## Open after this session

- **Start-up init not recorded:** the link initialises (`ATZ` … `ATSH7E0`, plan probe) before Start; the file begins with `poll` rows (first `seq` 5524) and has no start-time `adapter` row. Only the header's `requestHeader`, `protocol` and `adaptiveTiming` reflect it.
- **Location:** one `lifecycle` `error` at t 2.08, `referenceLocation: Error Domain=kCLErrorDomain Code=1`, yet 36 fixes arrived (0.06 Hz, `speed` −1 on every fix, accuracy 20–62 m; indoor/obstructed). Authorization status isn't logged, so denial can't be confirmed; no background-risk row was written. OBD-vs-GPS speed comparison not possible here.
- **5-minute lock** not done (165 s); background survival over ≥ 1 h remains for M5.
- `ATAT2` was chosen on a 4.6 ms, 3-sample edge with no steady-state gain.
