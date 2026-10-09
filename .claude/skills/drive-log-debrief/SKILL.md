---
name: drive-log-debrief
description: Step-by-step procedure to evaluate a recorded DriveLogger drive (.jsonl.gz) - data health, OBD rate and latency, sensor gaps, background survival, OBD vs GPS speed agreement - and write a short report with a go/no-go verdict. Use whenever a new drive log is provided.
---

# Drive log debrief

Input: one or more `Drive_*.jsonl.gz` files (keep them under `logs/`, which is git-ignored).

## 1. Inventory
Run the `inspect_log` tool on the file, using the command listed in CLAUDE.md (e.g. `cd Core && swift run inspect_log ../logs/<file>`). Record: format version, app build, adapter, ELM version, detected protocol, duration, file size, rows per type.

## 2. Health thresholds
| Check | Good | Investigate |
|---|---|---|
| motion rate | 98-100 Hz | < 95 Hz or gaps > 50 ms |
| OBD speed rate | >= 5 Hz (target 10+) | < 3 Hz or gaps > 1 s while moving |
| OBD latency (tRecv - tSent) | median < 150 ms | p95 > 400 ms |
| timeouts / re-inits / BLE disconnects | 0 / 0 / 0 | any - list times relative to start |
| background | rows continue across lock/background events | any gap aligned with a lifecycle event |
| writer | stats show queue depth bounded | growing queue, missing tail |

## 3. OBD vs GPS speed (only where GPS horizontalAccuracy < 20 m and speedAccuracy >= 0)
- Align by `t`; estimate the lag that minimises the difference (search -2..+2 s, 0.05 s steps) and report it.
- After the lag: median and p95 absolute speed difference (km/h), and the OBD/GPS ratio at > 30 km/h (a constant ratio near 1.02-1.05 is normal: speedometer/OBD scaling).
- Note segments where GPS looks jammed or spoofed (jumps, impossible speed) - those are exactly the conditions the app is for; mark them, do not use them as truth.

## 4. Manual fixes as ground truth (format v3+, `manualFix` rows)
A `manualFix` is a position the driver confirmed on the map while at or below 10 km/h (or with speed unknown). It is the only ground truth in a recording that does not depend on GNSS. `inspect_log` lists them, and `--csv` writes `manualFix.csv`. See docs/LOG_FORMAT.md, `manualFix`. For each fix:
- **Nearest reference GPS fix at `t`:** take the `location` row whose `t` is closest to the manual fix's `t`. Report the distance between the two positions in metres (haversine), that fix's `horizontalAccuracy`, and its age (`t_manual − t_location`, in seconds; also note `ageS` if present). A distance much larger than `horizontalAccuracy` means GNSS was wrong or the pin was misplaced. Use `mapSpanM` to judge which: a pin placed on a 2 km wide map cannot be trusted to 20 m.
- **Jammed / tunnel segments:** fixes inside segments flagged in section 3 (jumps, impossible speed, accuracy blow-up, no `location` rows) are the most valuable ones. List them separately and say whether GNSS was absent, degraded or confidently wrong there.
- **Gate:** report `speedSource` (`obd` / `gps` / `unknown`) and `gateSpeedKmh`.
  - The gate only uses an OBD reply at most 2 s old and a reference fix at most 5 s old (docs/LOG_FORMAT.md). So for `obd`, `t − obdSpeedT` is at most 2 s by construction.
  - A row with `obdSpeedKmh` present but `speedSource` not `obd` means OBD polling had stalled. Report how old it was and what it said.
  - For `gps`, the reference fix was its own gate, so weight that fix less as truth.
  - Treat `unknown` with suspicion: the car may have been moving. Check OBD speed (any age) and motion around `t`.
- **Confirm delay:** `t − pressedT`. Several seconds means the position may belong to the moment of the press rather than the confirm, so compare against GPS at both instants if the car was moving.
- Summarise: number of fixes, median and max distance to GPS (excluding jammed segments), and the jammed-segment fixes on their own.
- Privacy: in the report, give positions only as distances and errors. Never give coordinates.

## 5. Report (keep to one screen)
- Verdict: GOOD / USABLE WITH CAVEATS / BAD - one sentence why.
- Table of the numbers above (manual-fix comparison included when present).
- Top 3 problems with the code area most likely responsible.
- Recommended next code change, if any.

Privacy: no coordinates, street names, dates or clock times in the report beyond "minute N of the drive".
