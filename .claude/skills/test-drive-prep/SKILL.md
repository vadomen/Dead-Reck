---
name: test-drive-prep
description: Checklist before and after a DriveLogger test drive on the phone - Release build, road packs, adapter, Record from the first minute, what to note during the drive, and getting the recording and sidecar back into logs/drives/ for the debrief. Use when the user plans a test drive, asks what to check before driving, or hands over a fresh drive.
---

# Test drive: prepare, drive, bring the data back

Goal: every minute the user wants analysed is in a recording. A Navigate run without Record writes nothing (backlog NAV-LOG), so a problem seen only on the screen can't be replayed.

## Before (Mac)
1. Build: `DriveLogger-Release` scheme, signed (`Config/Local.xcconfig`). Debug only if the user wants a debugger; then say that timings in the sidecar won't count. Installing on the phone is the user's action or an approved `xcodebuild`/`devicectl` call (`ios-build-test`, "Device builds").
2. Road packs: installed via Settings → Maps, or `scripts/push_packs.sh --dry-run` then the real push (asks for approval) with the app **swiped away**: packs are memory-mapped and the script refuses while it runs. Launch once and check Settings → Diagnostics: packs Verified, nothing left refused in the inbox.
3. If the drive tests a change: write down the commit, the config (default or which `--set`), and what to look for, in the handoff or prompt file under `logs/`.

## Before (car)
4. Phone mounted rigidly, portrait; adapter plugged in; phone not hot (Diagnostics thermal state nominal/fair). A hot phone slows the engine and invalidates timing.
5. Settings → Test drive recording: tick "rigid mount" and "fixed orientation", notes (purpose, packs, build), **START while stationary**, before driving off; keep still for the 5 s calibration.
6. If a screen recording is wanted, start it after Record and say so in the notes.

## During
7. MARK for events (tunnel, jam, wrong-road, pin not taken). Pins: double tap where the car is, ideally when stopped or slow. Notes per event: "minute N, what you saw" — never addresses.

## After
8. Park, STOP. Sessions tab → share the recording **and** its `.nav.jsonl` (AirDrop or Save to Files).
9. On the Mac: both files into `logs/drives/` (git-ignored), unchanged names; screen recording into `logs/` (frames to `logs/video_<date>/`). Never into a tracked directory.
10. Run the `drive-log-debrief` skill. A drive becomes an acceptance or truth drive only by the user's decision (`logs/truth.json`, `logs/ACCEPTANCE.md`).
