---
name: drive-log-debrief
description: Step-by-step procedure to evaluate a recorded DriveLogger drive (.jsonl.gz, its .nav.jsonl sidecar, and any screen recording or notes from the drive) - data health, OBD rate and latency, GNSS state, background survival, OBD vs GPS speed, manual fixes, live navigation - and write a short report with a verdict and backlog rows. Use whenever a new drive log or field-test material is provided.
---

# Drive log debrief

Inputs, all under git-ignored `logs/` (drives in `logs/drives/`):
- `Drive_<stamp>.jsonl.gz` — the recording (source of truth for sensors).
- `Drive_<stamp>.nav.jsonl` — the live navigation sidecar, if Record ran with Navigate (docs/NAV_SIDECAR.md).
- Optional: a screen recording or the driver's notes. Extracted frames go to `logs/video_<date>/`.

Every number comes from a tool run or a computation you show. If it can't be computed from the inputs, say so; never estimate.

## 1. Inventory
`cd Core && swift run -c release inspect_log ../logs/drives/<file>.jsonl.gz [--csv ../logs/out/<stamp>]`
Record: format version, app build, **build configuration** (Debug/Release), adapter, ELM version, detected protocol, polling command, duration, file size, rows per kind. `inspect_log` already prints rates, gaps > 50 ms, OBD latency percentiles, `elm` outcomes, `stats` rows and manual fixes: take those numbers from it, don't recompute them.

Coverage: if the screen recording or notes cover more time than the log (e.g. a Navigate run without Record), say how much is unlogged. That is a finding in itself (see backlog NAV-LOG).

## 2. Health thresholds
| Check | Good | Investigate |
|---|---|---|
| motion rate | 98-100 Hz | < 95 Hz or gaps > 50 ms |
| OBD speed rate | >= 15 Hz on the test car (bench 16.4 Hz, `010D0C1` + `ATSH7E0`) | < 10 Hz, or gaps > 1 s while moving |
| OBD latency (`inspect_log`) | median ~60 ms | p95 > 150 ms or max > 400 ms |
| timeouts / re-inits / BLE disconnects | 0 / 0 / 0 | any - list times as "minute N"; `NO DATA` → re-init right after idle rpm at 0 km/h is ignition off, which is expected |
| background | rows continue across `background`/`foreground` lifecycle rows; `stats` every 10 s without holes | any gap aligned with a lifecycle event |
| writer | `stats` queue depth bounded | growing queue, missing tail, truncation report |
| lifecycle | no `memoryWarning`, `thermalState` nominal/fair, no `lowDiskSpace` | `thermalState` serious/critical (say when it started; it slows the engine) |

## 3. GNSS state
From `location` rows: count, share with `horizontalAccuracy` < 20 m, accessory vs phone fixes, the worst accuracy. Classify the drive: **good GNSS** / **degraded** / **network-only** (accuracy hundreds of m to km) / **none**. Flag a first fix that is cached (age far above the rest) — it matters for first-launch and initialisation.

## 4. OBD vs GPS speed (only where `horizontalAccuracy` < 20 m and `speedAccuracy` >= 0)
Skip with "not possible" if there are no such fixes.
- Use `--csv` output and a short Python script (`python3 -I`, script outside `logs/`). Align by `t`; find the lag that minimises the mean |difference| (search -2..+2 s, 0.05 s steps); report it.
- After the lag: median and p95 |difference| (km/h), and the OBD/GPS ratio above 30 km/h (a constant 1.02-1.05 is normal speedometer scaling).
- Mark segments where GPS looks jammed or spoofed (jumps, impossible speed, accuracy blow-up). Don't use them as truth.

## 5. Manual fixes (`manualFix` rows, format v3)
A `manualFix` is where the driver tapped on the map: the only ground truth that doesn't depend on GNSS. Fields: docs/LOG_FORMAT.md, `manualFix`. For each fix:
- Distance (haversine, m) to the time-nearest `location` row, that fix's `horizontalAccuracy` and age (`t_manual − t_location`). Distance ≫ accuracy means GNSS was wrong or the pin misplaced; judge with `mapSpanM` (a pin on a 2 km wide map can't be trusted to 20 m).
- Gate: `speedSource` (`obd`/`gps`/`unknown`) and `gateSpeedKmh`. `obdSpeedKmh` present but source not `obd` = OBD polling had stalled (report its age). Treat `unknown` with suspicion: check OBD speed and motion around `t`.
- List fixes inside jammed segments separately: they are the most valuable.
- Recordings older than the N4 double-tap change also have a confirm delay (`t − pressedT`): if several seconds while moving, compare against GPS at both instants.

## 6. Live navigation (if a `.nav.jsonl` exists)
Read docs/NAV_SIDECAR.md "Lines" for field meanings; don't load all of NAVIGATION.md.
- Header: `buildConfiguration`. `msPerStep`/`maxStepMs` describe phone performance only in **Release**; in Debug report them but don't judge them.
- `roads` line: which packs attached and when; `roadsSelection` attempts and refusals.
- Over time from `estimate` lines: time to `converged`, `onRoadShare` (share of time ≥ 0.9, and every drop below 0.5 with its minute and speed), ellipse `semiMajorM` (median, max), `droppedInputs`, max `maxStepMs`.
- Pins: for each `pin`, how far the `prior` estimate was from the pin and whether the next estimates moved toward it. A pin the engine ignored is a finding.
- Reproducibility: `cd Core && swift run -c release replay_nav ../logs/drives/<file>.jsonl.gz --as-live --compare ../logs/drives/<file>.nav.jsonl [--roads <pack>]... --out ../logs/out/<stamp>` (packs: the ones in the `roads` line; paths in `logs/ACCEPTANCE.md`). Report: bit-identical or the first differing `t`.
- If the drive has a truth track in `logs/truth.json`, also run `replay_nav --truth` and report its metrics. Whether the drive should become an acceptance run is a decision for the user, not this debrief.

## 7. Screen recording / notes (if given)
Build a timeline in "minute N" of the video and map it to the log's clock where they overlap. Note what the driver saw that the log can't show (on-road %, ellipse, ESS, pins that didn't take, UI state). Navigation behaviour seen only on video can't be replayed: say so.

## 8. Report
Write it to `logs/DEBRIEF_<date>.md` (git-ignored) and return the same text. Keep it to about one screen:
- Verdict: **GOOD** / **USABLE WITH CAVEATS** / **BAD** for data health, one sentence why; and separately whether it qualifies as a PLAN §6 / acceptance drive (Release build, Record from the start, long enough).
- Table of the numbers above (health, GNSS, OBD vs GPS, manual fixes, navigator, lifecycle).
- Top 3 problems with the code area most likely responsible.
- Proposed backlog rows (ID, source, finding, proposal) for new problems. Add them to `docs/BACKLOG.md` only if the user asks; check existing IDs first so you don't duplicate one.

## Privacy
- In the report and anything you write: positions only as distances, errors and bearings. No coordinates, street, place or region names.
- Times as "minute N of the drive/video". The drive's date may appear in the `logs/` file name and title (git-ignored); never put dates, clock times or positions in tracked files, backlog rows included ("2026-10-19 drive debrief" as a source label is the exception).
- Never commit a log, a sidecar, a CSV or frames.
