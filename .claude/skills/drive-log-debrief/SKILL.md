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

## 4. Report (keep to one screen)
- Verdict: GOOD / USABLE WITH CAVEATS / BAD - one sentence why.
- Table of the numbers above.
- Top 3 problems with the code area most likely responsible.
- Recommended next code change, if any.

Privacy: no coordinates, street names, dates or clock times in the report beyond "minute N of the drive".
