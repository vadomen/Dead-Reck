# DriveLogger v1 — implementation plan (M0)

Status of the completed milestones M0–M4: [docs/archive/PLAN-done.md](archive/PLAN-done.md).

**Decisions taken during M1 (by the user, after review):**
- `NO DATA`: a PID that has answered OK in the session (poll or probe) is
  never dropped; its `NO DATA` is a failure (retry → re-init → reconnect). A
  PID that never answered OK is dropped. Answered-OK beats the `0100` bitmask.
- Write-off (a `>` missing for longer than timeout + grace): the link is
  desynchronised and only `ATZ` may be sent; while polling the session
  re-initialises at once. The earlier `ATRV` resync was removed after three
  review rounds showed a stale voltage reply could satisfy it.
- `ATST` dropped from the allowlist (nothing sends it).
- Bench test 2026-10-07 (`docs/BENCH_TEST_2026-10-07.md`):
  - **Physical addressing.** After `ATRV` the session sends `ATSH7E0` only
    when `ATDPN` reports 11-bit ISO 15765-4 CAN (`6`, `A6`, `8`, `A8`) and the
    `0100` reply had a `7E8` line. On other protocols a 3-digit `ATSH` isn't an
    OBD request ID. Physical addressing engages only if `ATSH7E0` answers
    `OK`. If it doesn't — or it was skipped — requests stay functional
    (`7DF`), a note is recorded, and initialisation and recording carry on:
    this is not an error.
  - **Poll command.** Chosen at start-up as the first of `010D0C1` →
    `010D0C` → `010D1` → `010D` that returns the engine's (`7E8`) values.
    The `1` suffix is used only after `ATSH7E0` answered `OK`: under
    functional addressing the suffix returned the gearbox's reply. Since
    the M4 follow-up (M6.1-3) the chosen plan and `ATAT` level are
    remembered per adapter for the app session: a reconnect to the same
    adapter reuses them after the full handshake if the `ATSH7E0` gate gives
    the same addressing, with `ATAT<n>` and one check poll instead of
    selection and the `ATAT1`/`ATAT2` comparison; if the check fails,
    selection runs as before (once per init).
  - **Functional fallback.** If nothing parses at `7E0` (or only without
    speed), the session sends `ATSH7DF` and selects again functionally
    (`010D0C` → `010D`, no suffix). Every fallback plan is functional. The
    gate is re-evaluated on every re-init.
  - `ATSH` is allowlisted for `7DF` and `7E0`–`7E7` only, in session scope.
    `polling.requestHeader` records the addressing.

For M1 the code is authoritative over the §4 sketches (now in docs/archive/PLAN-done.md); the ELM and log
behaviour is documented in the `ELMSession` / `LogFileWriter` doc comments and
in `docs/LOG_FORMAT.md`.

Small deviations from the §4 sketches (docs/archive/PLAN-done.md), made while writing the stubs:
`ELM327Command.currentDataMany(_:responseCount:)` (not `requestMany`);
`StatsAccumulator.closeWindow(at:…)` (not `window(endingAt:…)`); the
`needsReconnect` stream is folded into `ELMSessionEvent.needsReconnect`;
`OBDLinkServicing` exposes a merged `adapter: AdapterRecord?` + `plan` instead
of separate `adapterInfo`/`gatt`, and a single event stream (now `linkEvents()`);
`RecordingSession` adds `handleMemoryWarning()`.

**Review fixes (commit after "contracts").** The review found ten issues in the
contracts; all were fixed before M1. Where a sketch in §4 differs from the
code, **the code is authoritative**. The sketches (docs/archive/PLAN-done.md) were updated for
the main points:

1. The read-only guard is an explicit **allowlist** (`ELMCommandPolicy`, now
   implemented and tested). "Any AT" was unsafe: `ATCAF0` then `0104` puts a
   service 04 (clear DTCs) frame on the bus.
2. Transports accept only `ValidatedELMCommand`, which only the policy can
   create. `ELM327Command.raw` and `.request(mode:pid:)` are gone; the enum
   can only express read-only commands.
3. `seq` is unique across reconnects: `ELMSession(firstSeq:)` + `nextSeq`.
4. `ELMSession` takes an `UptimeSource`. Every `ELMSessionEvent` carries the
   uptime at which it happened, and rows are stamped from that, not from when
   they were consumed.
5. BLE transitions reach the recorder: `LinkEvent` (`.ble` + `.session`), BLE
   state names frozen in `LinkSample.BLEState`; `linkEvents()` replaces
   `sessionEvents()`.
6. `ELM327Command.handshake` is the spec sequence with `ATH1`.
7. Calibration is the first phase of a started recording, so its samples are
   in the file.
8. Concurrency conventions (§4.0).
9. Frozen fixture suites assert only facts about their own version;
   "current state" assertions moved to `LogFormatCurrentStateTests`.
10. `LogFileWriter` creates files exclusively; `LogFileName` takes a
    `collisionIndex`; write-failure behaviour is defined (§4.3).

Inputs: `CLAUDE.md` (wins on conflict), `docs/SPEC_V1.md`, `WORKFLOW.md`,
`docs/LOG_FORMAT.md`, `.claude/skills/elm327-protocol/SKILL.md`, all of `Core/`.

---

§1 Gap analysis (M0): [docs/archive/PLAN-done.md](archive/PLAN-done.md).

## 2. Milestones

Same shape as `WORKFLOW.md`; this section pins down deliverables, folder
ownership and acceptance.

M0–M4 (done): [docs/archive/PLAN-done.md](archive/PLAN-done.md).

### M5 — drives
City drive, then highway + jammed-GPS area. Done = 3 consecutive GOOD verdicts, one ≥ 1 h with the screen locked. Tag `logger-v1`.

---

## 3. Log format v2 and 4. Contracts (moved)

The v2 format sketch (§3.1–§3.5) and the contract sketches (§4.0–§4.7) moved unchanged on 2026-10-17 to [docs/archive/PLAN-done.md](archive/PLAN-done.md). The code is authoritative over them, and the log format is `docs/LOG_FORMAT.md`. Code comments and WORKFLOW.md still cite them as `docs/PLAN.md §3.x` / `§4.x`: look the number up there. Open one only to look up a specific sketch (e.g. §4.0 concurrency conventions).

## 5. Decisions needing your approval

1. **Format v2** (§3.1), including the three assertion edits in `LogFormatCompatibilityTests` — fixture string untouched.
2. **GPS fix time** via `Date()`-based age at receipt (§3.4).
3. **Start requires OBD `polling`** unless "record without OBD" is chosen explicitly (§3.3).
4. **gzip via concatenated members** built on `NSData.compressed(using: .zlib)`, no third-party code (§3.5).
5. **`MockELMAdapter` and simulated sensor sources ship in the Core library**, not only in tests, so the simulator app runs end to end.
6. **`elm` rows for every exchange**, including successful polls (§3.4).
7. **`inspect_log` lives in the Core package** (`Core/Sources/inspect_log`) rather than a separate `tools/` package, so it shares Core without a second `Package.swift`.

## 6. Hardware checks (M4/M5), not claimable before

### Resolved by the bench test (2026-10-07, Car Scanner terminal, `docs/BENCH_TEST_2026-10-07.md`)
- **Protocol:** `ATDPN` = `6`, ISO 15765-4 CAN 11-bit 500 kbaud. Expect `A6` after the app's own `ATSP0`.
- **Adapter:** `ELM327 v2.3`; BLE name `IOS-Vlink`.
- **Two ECUs answer functional requests:** `7E8` (engine) and `7E9` (gearbox, most likely). Handled by `ATSH7E0` (gated, see the status block) with the functional fallback, and speed is taken from `7E8`. Under functional addressing the `1` suffix returned `7E9`'s reply, so the suffix is used only with `ATSH7E0`.
- **Multi-PID works:** `010D0C` / `010D0C1` → speed and RPM in one frame (663 rpm at idle).
- **OBDonUDS (`22F40D`) not needed:** `NO DATA`, while mode 01 works.

### Resolved by the M4 bench test (2026-10-08, our app, `docs/BENCH_TEST_2026-10-08.md`)
- **GATT:** Vgate layout `E7810A71-…` / `BEF8D6C9-…` (one characteristic, notify + write), `withResponse`, `maxWriteLength` 182. No write failures.
- **Poll plan and Hz:** `010D0C1` with `requestHeader` `7E0`; 16.4–16.5 exchanges/s, p50 latency 59 ms, p95 74 ms; `7E8` replies only. `ATDPN` → `A6` after our `ATSP0`; `ATSH7E0` → `OK` (re-init; start-up init not in the file).
- **`ATAT1` vs `ATAT2`:** no difference in steady state (59 ms median, 16.4 Hz either way); `ATAT2` does not cut replies short.
- **Lock:** 165 s locked (not 5 min) with no loss in any kind and `stats` every 10 s.
- **Unplug/replug:** BLE timeout → one reconnect attempt → connected +23.1 s → re-init with `ATSH7E0` → polling +30.3 s; `seq` continuous.
- **Also:** `ATZ` banner `ELM327 v2.3`; `ATRV` 12.2 V / 11.8 V; write-off/re-init only from the unplug; no `7E9` under physical addressing.
- **Still open from it:** start-up init not recorded; location `Code=1` error with no authorization info (both fixed in M4). The ≥ 5 min lock was not run; by the user's decision it is superseded by M5's ≥ 1 h screen-locked drive.

### Still open (M4 unless noted)
- **Real poll Hz** of `010D0C1` after `ATSH7E0`, and which plan start-up selection picks with our own init (the bench used Car Scanner's init).
- **`ATAT1` vs `ATAT2`:** which is faster and stable, and whether `ATAT2` cuts replies short.
- **Background survival:** 5+ minutes locked with BLE + location (M4); ≥ 1 h locked on a drive (M5).
- **GATT:** actual Vgate layout and max write length.
- From the bench update, also to confirm with our app: `ATSH7E0` → `OK` after our handshake; only `7E8` replies under physical addressing while driving; how often write-offs and re-inits happen; `ATRV` under-reads (11.0 / 11.8 V).

### Added by M2 part 1 (BLE transport, link service) — none of this is verified; the simulator has no Bluetooth
- **Scan / pick:** `IOS-Vlink` appears in the list (named advertisers only, likely adapters sorted first); picking it connects; the identifier is remembered and a relaunch reconnects without a scan.
- **GATT detection:** which layout `GATTDetection` picks on the Vgate (`vgate`, `fff0`, `ffe0` or `generic` — console line `ble: discovering → connected (…)`), the full `gattTable` in the header, and whether notifications on the chosen characteristic actually carry the replies.
- **Write type and length:** `adapter.gatt.writeType` (we prefer `withResponse` when offered) and `maxWriteLength` (capped at the without-response length, expected 20 on BLE 4.0 unless the MTU is negotiated up). Check that acknowledged writes don't produce `ble: write failed` lines (in the console, and since the backlog sweep also `ble` notes `write failed: …` in the log, R3.1-6), and compare poll Hz with `withoutResponse` if both are offered.
- **Write splitting:** no command is longer than 20 bytes today, so splitting only runs on a smaller MTU; if `maxWriteLength` < 9 is ever seen, confirm split commands are answered.
- **Timestamps:** OBD reply uptime is taken first thing in `didUpdateValueFor` on the private BLE queue; check `inspect_log` OBD latency is plausible (tens of ms) and not dominated by main-thread stalls.
- **State restoration:** with a recording running and the app terminated by the system (not swiped away), the app relaunches, a `ble` `restoring` row appears and polling resumes. Note: restoration only works if `OBDLinkService` (via `OBDLinkFactory.makeDefault()`) is created at launch — part 2 / M3 wiring.
- **Reconnect:** unplug/replug the adapter while recording → `connected → disconnected → reconnecting → connecting → discovering → connected`, a new `ATZ` handshake with `ATSH7E0`, polling resumes, `seq` continues without repeats. Also Bluetooth off/on in Control Centre (→ `unavailable`, then reconnect). Backoff is 1 s doubling to 30 s, reset by a connection's first successful poll (R3.1-5: not by a successful init, so a link that initialises and then fails every poll keeps backing off); the pending connect never times out.
- **needsReconnect:** if a session ever gives up (`elm` `failed` + reconnect), confirm the BLE cancel/reconnect cycle restores polling.
- **`ATSH7DF` refusal (R2.2-3):** whether the Vgate ever refuses or drops `ATSH7DF`; if a note `physical addressing disabled for this session` appears, record when.
- **Desynchronised console:** after a manual command times out, the console shows `link desynchronised …` and the link re-initialises; nothing is sent in between but `ATZ`.

### Added by review run 3, round 1 (R3.1-1, R3.1-2, R3.1-3, R3.1-7) — not verified; the simulator has no Bluetooth
- **Bluetooth off/on and bluetoothd reset (R3.1-2):** while recording, toggle Bluetooth off/on, in Settings and in Control Centre (which may only disconnect accessories rather than power the radio off; note which `unavailable` reason, if any, each one logs), and confirm `unavailable` → `idle` → `connecting` → … → `connected` and polling resume. If possible, also force a bluetoothd reset (`resetting` state, e.g. a sysdiagnose or a Bluetooth crash) and confirm the reconnect completes rather than sitting in `connecting`: below `poweredOff` every retained `CBPeripheral` is dropped and the identifier is retrieved again.
- **Re-enabling notifications after restoration (R3.1-7):** whether `setNotifyValue(true)` on a characteristic that is already notifying (an adopted, restored connection) still calls `didUpdateNotificationStateFor`. If it doesn't, the 10 s discovery watchdog (R3.1-7, backlog sweep) ends it with `discovering → disconnected (GATT discovery timed out after 10.0 seconds)` → `reconnecting`, so every restored relaunch would cost 10 s and a reconnect: note whether that row appears after a restoration.
- **Cancel → `didDisconnect` latency (R3.1-3):** on a live link and on a dead one (adapter unplugged), how long after `cancelPeripheralConnection` the disconnect callback arrives, compared with the 1 s first reconnect backoff. Since the backlog sweep a requested disconnect is reported as such (console `ble: requested disconnect completed`) and never drops the connection made after it: confirm no spurious extra `disconnected → reconnecting` cycle follows a `needsReconnect` or `initialisation failed` reconnect. Also note whether cancelling a *pending* connect (adapter unplugged) produces a disconnect callback at all.
- **Write type and write stalls (R3.1-1):** which write types the Vgate's write characteristic offers (`write`, `writeWithoutResponse`, both) and, if `withoutResponse` is used, whether `canSendWriteWithoutResponse` ever stays false for the 1 s readiness timeout (`init failed: transport(writeFailed(…))` or `write failed: …` in the console). A write failure during the handshake must end in `disconnected (initialisation failed: …)` → `reconnecting` → a new handshake, never a silent `failed` link.

### Added by review run 3, round 2 (R3.2-1, R3.2-2) — not verified; the simulator has no Bluetooth
- **Write stalls show as timeouts (R3.2-1):** if the Vgate's write characteristic is `withoutResponse` only, look for an `elm` `timeout` row followed by `no prompt for … written off` and an `ATZ` re-init with no reply ever sent — that is a stalled write, not a silent adapter.
- **Double discovery after Bluetooth off/on (R3.2-2):** count `→ discovering` transitions in the console per reconnect; two in a row, or a duplicated GATT table, means both layers connected. Since the backlog sweep `BLECentral` never connects on its own and a second `connect` joins a pending connect or running discovery, so expect exactly one per reconnect. Confirm the link still reaches `connected` every time.
- **Retrieval after a bluetoothd reset (R3.1-2):** after a reset, does `retrievePeripherals(withIdentifiers:)` still find the remembered adapter? If every attempt fails with `not known to this phone; scan and pick it again`, only a rescan recovers.
- **First state after restoration:** whether the first `didUpdateState` after a system relaunch is ever `resetting`/`unknown` (restored peripherals are then dropped and re-retrieved); confirm the reconnect still completes.

### Added by M2 part 2 (sensors, recording) — none of this is verified; the simulator has no motion sensors, no GNSS and no real background behaviour
- **Real sensor rates:** `stats.motionHz` ≈ 100 and `inspect_log` rates for `motion`, `accel`, `gyro` ≈ 100 Hz, `mag` ≈ 10 Hz, `baro` ≈ 1 Hz (device-driven), `location` ≈ 1 Hz; `gaps` and `maxGapMs` in the `stats` rows, screen on and screen locked. Note any `out-of-order` count from CoreMotion batches.
- **One CMMotionManager:** device motion and raw IMU share one manager (`SharedMotionManager`). Confirm neither stream's rate drops when both run, compared with either alone.
- **Device-motion magnetic field:** with `xArbitraryZVertical` CoreMotion is expected to report `magneticAccuracy` −1 and no `magneticField` in `motion` rows (the raw field is in `mag`). Record what the phone actually reports.
- **CoreMotion timestamps:** `motion`/`accel`/`gyro` `t` must track `clock.now()` (no offset of seconds). Check the first samples after start: a small negative `t` from a buffered batch is legal; a large offset would mean CoreMotion's timebase is not `ProcessInfo.systemUptime` on this iOS version.
- **Permissions:** first start prompts for Motion & Fitness (altimeter) and Location When In Use. Denying either must give a `lifecycle` `error` row (`altimeter unavailable: …`, `referenceLocation unavailable: …`) and the recording must still run. Revoking location mid-drive must give `referenceLocation: authorization denied while recording …`.
- **Background survival (`CLBackgroundActivitySession`):** with When-In-Use authorisation only, lock the screen for 5+ minutes (M4) and ≥ 1 h on a drive (M5): rows continue, `stats` rows every 10 s without holes, `background`/`foreground` rows bracket the lock, the blue location indicator shows. If the app is suspended, `stats` `t` values jump — that is the signature to look for.
- **Reference fix quality:** `location` `ageS` (expect 0–1 s), `horizontalAccuracy`, and whether `activityType = .otherNavigation` with `kCLLocationAccuracyBest` avoids road snapping (compare a drive's track with the road geometry at a junction). Also whether fixes keep arriving at 1 Hz while stationary (no auto-pause).
- **Fix time:** `t = receivedT − ageS`; on the phone `receivedT − t` should be a fraction of a second. Large or negative ages on most fixes would mean the wall clock and CoreLocation disagree.
- **Flush on background / memory warning:** after locking the screen, the file on disk grows within a second (a member is written inside a background task). Copy the file off while recording (Files app) and confirm it reads with `inspect_log` (only a truncated tail allowed).
- **Disk full on a real phone:** fill the phone to < 250 MB free (R2-8, R3-5): Start is refused below 200 MB; while recording, the `warning` row appears below 200 MB and a clean `lowDiskSpace` stop below 50 MB. Note how long the free-space query takes on the phone (it runs off the main actor) and whether purgeable space makes iOS free space before our floor is reached.
- **Write failure UI:** if a real write failure ever happens, the app must show `failed` with an unwritten count, and the file must still read up to the failure.
- **Thermal and lock rows:** `thermalState` rows on a hot dashboard; `protectedDataUnavailable` when a passcode-locked phone locks — and recording continues (files are `completeUntilFirstUserAuthentication`).
- **Idle timer:** the screen does not dim while recording; dims normally after stop.
- **State restoration with a recording running:** the link is created at launch (`AppServices`), so a system relaunch can restore the BLE central. But a relaunch is a new process: the recording that was running is gone (its file ends with a truncated tail at most; no `stop` row) and no new recording starts by itself. Confirm that is what happens, and decide whether auto-resume is wanted (a user decision, not implemented).
- **Writer queue:** `stats.queueDepthMax` stays small (tens of events) on the phone; a `writer queue peaked …` error row (peak above `max(2 s of data, 200)` events, docs/LOG_FORMAT.md) would mean the writer can't keep up. The start-up init replay at Start (~50–60 rows) shows in the first window's peak.

### Added by review run 4, round 1 (R4.1-x) — not verified
- **Cached first fix:** whether the first CoreLocation fix after Start is cached with a large `ageS` (a `location` row well before `t = 0`; legal, not clamped). Confirm `inspect_log` tolerates it and note how often it happens.
- **Location denied / "Allow Once" (R4.1-5):** with location denied, lock for 5 min with and without OBD; do motion and `stats` rows continue on BLE wakes alone? With "Allow Once" plus `CLBackgroundActivitySession`, do fixes continue after lock? Since M3 prep: with location denied the dashboard must warn before Start (`backgroundRiskWarning`), and the file must hold `referenceLocation unavailable: …` followed by `no background location session; recording may pause while locked`. Revoke location in Settings mid-recording and confirm that row appears once on returning to the app, and whether the background session really ends (the row says "may").
- **Stop while locked (R4.1-3):** trigger a stop with the phone locked (floor via a debug fake provider, or a forced write failure); confirm the `stop` row, the final `stats` row and an intact tail.
- **Swipe-away while recording in background (R4.1-4):** the recorder now flushes on `willTerminate` and waits for it (up to 3 s; no row is written). Lock or background the app while recording, wait 5+ s, swipe it away, then `inspect_log` the file: no truncated tail, no `stop` row, and the last `motion` `t` within about a second of the kill (not up to 2 s short). If the tail is still short, `willTerminate` did not arrive (the app was suspended, not terminated).
- **Delete path matching on device:** `URL.documentsDirectory` (`/var/mobile/…`) vs `contentsOfDirectory` (possibly `/private/var/…`); confirm Delete works from the M3 list and the "being recorded" guard matches (a mismatch fails safe with `.notInStore` but makes Delete unusable).

### Added by M3 (UI) — simulator screenshots only; none of this is verified on a phone
- **Readability at arm's length:** in the real mount, speed numbers (84 pt), banner and adapter status readable at a glance, driver's seat, day and night; note which text is too small (stats row, notices, console).
- **Glare and sunlight:** red/orange/green banner and tile outlines still distinguishable in direct sun and with polarised sunglasses; consider a forced dark or high-contrast mode if not.
- **Tap targets while mounted:** START, MARK and STOP (72 pt) and the checklist toggles hit reliably one-handed with the phone in the mount; the Mark sheet presets are usable without looking; no accidental STOP (there is no confirmation on STOP).
- **Idle timer:** screen does not dim while calibrating or recording on the Record tab and on the other tabs, and dims normally after stop and after a failed recording.
- **Permissions and unavailable states:** deny Motion and Location and turn Bluetooth off; the Record tab shows the matching notices and red adapter state, and the checklist and Start still behave.
- **Keyboard:** mount and vehicle note fields and the console field with the on-screen keyboard in the mount; the Start bar stays reachable.

### Added by M4 fixes (not verified)
Start-up init written at Start (link side 2437416, recorder side in this fix) and location authorisation in the file. Tested only against fakes on the simulator; none of this has been seen on the phone.
1. **Start after polling:** the file begins with the `start` row, then negative-`t` `link` rows `connecting → discovering → connected` (since the M4 follow-up only `discovering → connected`) and `elm` rows `ATZ` … `ATSH7E0`, then the probe and an `adapter` row, then live rows. `inspect_log --strict` is clean, and `seq` increases with exactly one gap (after the init's last exchange; the pre-Start polls are not written).
2. **Start during init** (allow without OBD): every init exchange appears exactly once: the first part replayed with negative `t`, the rest live.
3. **ATAT on the Touareg:** the `adaptive timing:` note says `ATAT1 kept`, with both medians around 59 ms. Measure the extra start-up and re-init time (about 1.2 s).
4. **Unplug and replug while not recording, then Start:** the replayed init is the reconnect's (one `connected`, its `ATZ`), not the first connection's.
5. **If `ATAT2 kept` ever appears,** check that steady-state replies aren't cut short.
6. **First `stats` window:** in a recording started minutes after the adapter connected, the first `stats` row's `windowS` is about 10 s (not stretched back to the replayed init), and `motionHz` is about 100.
7. **`locationAuthorization` at start:** the row after the source rows reads what Settings shows: `authorizationStatus=authorizedWhenInUse` (or what was granted), `accuracyAuthorization=full` (or `reduced` with Precise Location off), and `backgroundActivitySession=held`. Repeat once with location denied: `authorizationStatus=denied, …, backgroundActivitySession=none`, then `no background location session; …`.
8. **The bench's `Code=1` again:** if `referenceLocation: Error Domain=kCLErrorDomain Code=1 …` reappears, note the authorisation in its parentheses. With `authorizedWhenInUse`/`authorizedAlways`, fixes must keep coming and no background-risk row is written. With `denied`/`restricted`, the background-risk row must follow. Also check whether it comes right after Start on a fresh install, while `authorizationStatus=notDetermined`. That is the leading hypothesis for the bench, and if it holds it is a startup ordering issue, not a denial.
9. **Prompt answered after Start:** on a fresh install, Start, then answer the location prompt. You should get a `locationAuthorization` row with the new authorisation at the moment of the answer, and fixes start. If the answer was "Allow Once" or "Allow While Using", check whether `backgroundActivitySession=held` (created before the answer) actually keeps the app running when locked. The `stats` `t` values must continue across the lock.
10. **Precise Location off mid-recording:** gives `locationAuthorization` `…, accuracyAuthorization=reduced` and the recording continues. Note `horizontalAccuracy` afterwards.

### Added by M4 follow-up (not verified)
Replay only the current connection's init (M6.1-1) and remembered poll plan and `ATAT` across reconnects (M6.1-3). Tested against `MockELMAdapter`, `FakeBLECentral` and `SimulatedOBDLink` only; none of this has been seen on the phone.
1. **Unplug and replug while recording:** after the reconnect the `link` notes show `poll plan reused from the previous connection: 010D0C1, ATAT1, requestHeader 7E0` (with the level the start-up init chose), the `elm` rows of the re-init are the handshake with `ATSH7E0` → `OK`, then `ATAT1` and one `010D0C1` (phase `probe`), with no selection samples and no `adaptive timing:` note; polling resumes faster than the bench's 7.2 s init (`connected` → `polling`; most of it is still `0100` `SEARCHING...`, so expect roughly 7.2 s minus the ~1.2–1.5 s of probing). Note the `connected` → `polling` time.
2. **Start after a drop:** unplug the adapter, wait for `reconnecting`, tap Start (allow without OBD): the file has no negative-`t` `link`/`elm`/`adapter` rows (no replay); the first `link` row is the live `reconnecting → connecting` (or the next transition); replug, and the whole new connection is written live, `seq` increasing.
3. **Start while connected:** the replay begins with the `link` row `discovering → connected`; no `connecting`/`discovering` rows precede it.
4. **Reused plan failing on the car:** if a `reused plan failed (…); selecting again` note ever appears, record the reason and whether the following selection picked a different plan; the next reconnect must then show the newly selected plan in its `poll plan reused …` note.
5. **Forget / another adapter:** after Forget and re-pairing the same adapter, or after picking a different one, the first init runs the full selection and the `adaptive timing:` note (no `poll plan reused` note).

### Added by M4.3 map follow + heading-up (not verified on a device)
1. **Following survives a 10 min drive:** no unexpected loss of Following (the old `positionedByUser` handler is removed).
2. **Pan, then wait:** the "Re-centre in N s" hint counts down from 8 and the camera animates back to the car at the same zoom; panning again during the countdown restarts it. A long fling never re-centres mid-gesture.
3. **Manual fix:** a double tap (recording) records the point under the finger and still zooms the map (see the N4 C items below). Following behaves as for any double tap.
4. **Heading-up:** the map turns smoothly with the car above 10 km/h and holds still at stops (OBD speed 0); the arrow points up while following and shows true direction after a manual rotate; the mode persists across launches.
5. **SwiftUI gestures on `Map`:** the drag/pinch/rotate/double-tap gestures fire (Following goes off) and do not block panning, zooming or the double-tap manual fix. If they fail, the fallback is an `MKMapView` wrapper; ask the user before building it.
6. **Heading-up while stopped:** returning to the Map tab or toggling North up to Heading up while stopped shows the correct heading at once (restored from the last good bearing).
7. **ELM stall at a stop:** after a stall, heading-up unfreezes on drive-off (a stale OBD 0 does not count as stopped).
8. **Turns:** the camera settles at the true heading after a turn.
9. **Zoom parity:** at equal zoom, the visible area in heading-up roughly matches north-up (checks the `distancePerSpan` 1.87 guess).

### Added by N4 A, sample tap and sidecar files (not verified on a device)
1. **The tap costs the logger nothing:** in a 30 min recording on the phone, the `stats` rows show motion ~100 Hz and OBD at its pre-N4 rate, `dropped` 0, gaps and `queueDepthMax` no worse than a pre-N4 drive. The tap runs under `SampleGate`'s lock at real CoreMotion rates; the simulator only runs simulated tickers. **Verified 2026-10-12 (drive-7, iPhone 16 Pro Max, 38 min, installed build was Debug):** `motionHz` min 99.8 / mean 100.2, 0 motion/accel/gyro gaps > 50 ms (max 10 ms), OBD 16.8 Hz mean (min 14.3 per window; bench 16.4-16.5), `dropped` 0, timeouts 0, `queueDepthMax` 47 (peaks in 4 of 215 windows). No pre-N4 drive was compared for queue depth, only the bench's OBD rate. The 100 Hz and `dropped` 0 results were with a Debug build, so a Release build can only be better.
2. **Export with a sidecar:** once N4 B writes `<recording>.nav.jsonl`, the share sheet offers both files and AirDrop / Save to Files delivers both. Without a sidecar it shares the recording alone, as before.
3. **Delete with a sidecar:** deleting a recording in the Sessions tab removes its `.nav.jsonl` too; Files app → DriveLogger → logs shows neither afterwards.

### Added by N4 B, live navigation service and sidecar (not verified on a device)
1. **ms/step on the iPhone with 2000 particles:** the sidecar's `msPerStep` (EMA) and `maxStepMs` over a 30 min drive stay ≤ 2 ms per 10 Hz step. **NOT verified:** drive-7 (2026-10-12, iPhone 16 Pro Max) measured `msPerStep` median 2.8 ms, p99 4.9 ms, `maxStepMs` 45 ms, but the installed build was Debug (`-Onone`); drive-8 (2026-10-14, also Debug) measured median 3.1 ms, p99 7.2 ms, `maxStepMs` 68 ms; still NOT verified. Repeat with a Release build. **drive-9 (2026-10-15, iPhone 16 Pro Max, Release build, about 34 min): still NOT verified.** `msPerStep` (the sidecar's EMA, weight 0.1) median 0.31 ms, p99 0.61 ms: inside the budget; but `maxStepMs` is 28.5 ms, near 502 s, inside the background interval 478.9–522.5 s, and B-1 also asks for `maxStepMs` ≤ 2 ms. A re-run of the live input order shows every ingest ran at most one grid step (no catch-up anywhere in the drive), so the 28.5 ms is one step plus the unattributed time of the non-stepping ingests before it: a phone-side stall, not engine work. Smaller peaks of 3–5 ms at 232 s (pin 1 ingestion), 318 s (pin 2's tap time, likely UI) and 307 s (unexplained). Confound: a screen recording ran from about 212 s to 686 s and covers every peak; repeat on a Release drive without screen recording. The overlay shows the same once N4 C lands. The Mac release replay gives 0.06 ms/step; the simulator proves nothing about the phone's speed.
2. **First ingest after a long suspension:** lock the phone for 10 min mid-recording (if iOS suspends the app), then unlock. Nothing blocks visibly: the first snapshot after resume holds the position at the 2 s horizon with a grown ellipse, and `maxStepMs` stays modest. The sidecar has at most 600 estimates for the gap, then resumes at 1 Hz. `droppedInputs` says whether the feed overflowed during the catch-up. **Verified 2026-10-14 (drive-8, iPhone 16 Pro Max), with two caveats:** the screen was locked from about 10 s to 581 s of the session (`background` at 9.6 s, `foreground` at 580.7 s). The sidecar has 2091 `estimate` lines for a 2092 s session, one per second with no gap longer than 1 s, `droppedInputs` 0, and `maxStepMs` at most 44 ms inside the locked window. Caveat 1: iOS never actually suspended the app (the location background session kept it running), so the catch-up path after a suspension (at most 600 estimates for the gap, the first snapshot held at the 2 s horizon with a grown ellipse) was **not exercised**. Caveat 2: ms/step is **NOT verified**: the installed build was Debug (the sidecar header says `buildConfiguration` `debug`); `msPerStep` median 3.1 ms, p99 7.2 ms, `maxStepMs` 68 ms over the drive are not a device performance number (see item 1).
3. **Mac vs iPhone bit equality (R13.1-7):** copy a drive and its `.nav.jsonl` to the Mac and run `replay_nav <drive> --as-live --compare <drive>.nav.jsonl`. Report whether the result is **exact**. If it is not, report the first differing `t` and the largest differences, and whether `droppedInputs` or encoding failures explain them. A non-exact pass within the default tolerance is acceptable for now; a FAIL with no known cause is a bug.
4. **Sidecar lifecycle:** each recording gets its own `.nav.jsonl` with a header, about one estimate per second, and a `pin` line per recorded "I'm here" (written up to 3 s after the tap). After Stop it ends with a whole line. After a crash or kill it is readable and loses at most the last 10 s. A relaunch mid-drive starts a new recording with a new sidecar and a fresh engine (different seed). **Partly verified 2026-10-12 (drive-7, iPhone 16 Pro Max):** header present, 2149 `estimate` lines for a 2149 s session (exactly 1 per second, no gap), 12 `pin` lines matching the 12 `manualFix` rows, `droppedInputs` 0. Not checked: the 3 s write delay, the end-of-Stop line, crash or kill, relaunch.

### Added by N4 C, map with dead-reckoning dot and ellipse (not verified on a device)
1. **Feel at 10 Hz:** while following, the camera follows the dead-reckoning dot at up to 10 Hz (the feed publishes at 4 Hz through `NavWriteGate`, and every loop camera write, including the auto zoom moving, waits 0.25 s since the last one: at most 4 writes a second, 0.25 s linear animation). Check it is smooth at 30-100 km/h, not jittery, and that the dot and ellipse do not lag the road. Check heading-up turns with the DR heading once the heading has converged and with the GPS course before.
2. **CPU and thermal:** with the Map tab open for 30 min, CPU and thermal state compared with the same drive on the Record tab. The 100 ms loop awaits the navigation actor each tick; the debug stats line (`debug.navStats`, long-press the speed number on the map for 1 s (UX-5; thermal shows under it), or launch with `-debug.navStats YES`) shows ms/step, ESS, heading std, speed scale and dropped inputs. The polylines must not be rebuilt by estimate updates.
3. **Ellipse framing in heading-up:** after a long stop or an OBD dropout, when the ellipse grows, the view widens to 2.2 x semi-major (at most 1000 m, never narrower than the current zoom: the driver's after a pinch, else the speed-based one, UX-6 item 4) and returns to that zoom when it shrinks. Check that zooming by hand while following is respected and the widening is not fighting it.
4. **Double-tap manual fix:** while recording, zoomed in to at most 300 m, a double tap on a known spot still zooms the map, and the `manualFix` row (pull it with `inspect_log --csv`) holds the spot under the finger, not the post-zoom one. The "Fix recorded" toast offers Undo for 3 s with a success haptic and a translucent flag that becomes solid; Undo removes the flag and leaves no row; once the 3 s are over (also after a tab switch and back) the toast has no Undo, and a late Undo tap says "Already recorded, not undone" and keeps the flag. A tap on a map wider than 300 m (or before the first camera report) records nothing and says "Zoom in to place the pin precisely", but the double tap still zooms the map in, so a second double tap then passes (UX-6: while driving the auto zoom is wider than 300 m from about 55 km/h, and for about 6 s after slowing down). A fix while driving (try 50 km/h) is recorded with `obdSpeedKmh`/`gateSpeedKmh`. Stop within 3 s of a tap writes the row before `stop`. Going to the background within 3 s of a tap writes the row before the `background` row (then Undo is gone). After a write failure (hard to provoke) a pending flag disappears from the map instead of turning solid. Rows are in tap order with `t` = `pressedT`. Check the point is accurate enough when the finger is on a moving map (the pin is the finger's spot, the car has moved since). **Partly verified 2026-10-12 (drive-7, iPhone 16 Pro Max):** 12 `manualFix` rows, 8 at 20-47 km/h with `speedSource=obd` and `gateSpeedKmh` set (highest 47), rows in tap order, `t` = `pressedT` for all, `mapSpanM` 88-300 (none refused). Still open from this item: Undo (toast, late Undo, flag colours), the wide-map refusal, Stop or background within 3 s of a tap, write failure.
5. **Faded fixes:** with poor GPS (tunnel, garage) fixes over 1000 m show as faded red dots and do not draw lines.
6. **"Calibrating heading":** the label shows while the heading has not converged, with the ellipse drawn; the simulator's engine converges at once, so this was only seen in previews.

### Added by UX-2 map first (not verified on a device)
1. **Cold launch:** the app opens on the Map tab; the tab order is Map, Sessions, Settings (UX-3 moved Record and Console into Settings). The DEBUG `-uiTab` launch override uses tab order: 0 Map, 1 Sessions, 2 Settings (it was Record 0, Sessions 1, Console 2, Map 3).

### Added by UX-5 map speed block (not verified on a device)
1. **Source switch:** drive with OBD connected: the chip reads `OBD`. Unplug the adapter (or switch the ignition off while moving is not needed; stopping the link is enough): within about 2 s the chip changes to `GPS` with the GPS speed (m/s x 3.6, nearest km/h); replug: it returns to `OBD`. With neither (no fix, adapter gone) it reads `-- km/h` with no chip.
2. **Chip colour:** green with good GPS (accuracy 15 m or better), amber for 15-100 m, grey for network fixes, worse than 100 m, or no fresh fix. In a jammed or tunnel stretch the chip goes grey while the source stays `OBD`. Check the amber text is readable in sunlight.
3. **Agreement:** OBD and GPS speeds on a steady 50 km/h stretch differ by a few km/h (OBD shows the integer as received, no +0.5); the number does not flicker between sources at the 2 s edge.
4. **Hidden stats switch:** a 1 s long-press on the speed number toggles the navigation stats line and the thermal line under it. The "Calibrating heading" icon (blue scope) shows next to the chip while the heading has not converged and disappears once it has.
5. **Glance test:** the speed number is readable at arm's length in the mount, in daylight.

### Added by UX-3 Settings tab and map recording control (not verified on a device)
1. **Tabs:** Map · Sessions · Settings (gear); Console is a row inside Settings. `-uiTab` (DEBUG): 0 Map, 1 Sessions, 2 Settings.
2. **Recording lives in Settings:** Settings, Recording shows the unchanged Record screen (checklist, calibration, start/stop, mark, live stats). Opening it refreshes the screen (disk space, adapter). A full test drive: checklist, Start, Mark, Stop, all from there, with the file appearing in Sessions.
3. **Map Start button:** with no recording, Start (its own row above Heading/Follow, on the left) opens Settings, Recording and starts nothing. Back returns to Settings; the Map tab is where it was.
4. **Map recording indicator:** while calibrating or recording, a red dot and elapsed time replace Start. It must tick once a second without the map stuttering (follow camera, 10 Hz DR loop). Tapping it asks "Stop recording?"; Keep recording does nothing; Stop recording must actually stop (the dialog's button stops directly, it does not depend on SwiftUI's dismiss order): the indicator turns back into Start and the file is closed, complete and readable in Sessions (size stops growing, `inspect_log` shows a `stop` row and no damage). Check the 56 pt target is hit easily in the mount, and that it does not collide with the Re-centre hint or the Fix recorded toast.
5. **Diagnostics:** thermal state follows the system (try a warm phone) and the Version/Build rows show the version and Debug or Release.

### Added by UX-4 Console in Settings (not verified on a device)
1. **Reach:** Settings, then Console, two taps; the title bar shows "Console" with a back button to Settings. There is no Console tab and `-uiTab 3` opens Map.
2. **Guards unchanged:** with a recording running, Forget adapter and Drop OBD still ask first and say a recording is in progress; Scan is disabled while the link holds the adapter during a recording; the manual field still accepts only the allowed commands. Check with the real adapter.
3. **Keyboard:** the manual command field and keyboard behave inside the pushed screen (the field is not hidden by the keyboard, Send works, the log keeps scrolling to the newest line).

### Added by UX-6 speed-dependent zoom (not verified on a device)
1. **No pumping:** in stop-and-go traffic (0 to 30 km/h and back, a light every 10-20 s) the map zoom stays put and does not breathe. After a stop longer than about 6 s it zooms in; moving off zooms out.
2. **Feel at speed:** at a steady 50, 80 and 110 km/h the view is about 500 m, 900 m and 1500 m of camera distance (about 270, 480 and 800 m of visible span); judge whether it shows enough road ahead and whether the change between speeds feels smooth (about 3 s) and not sluggish or abrupt on a ramp.
3. **Pinch and re-centre:** a pinch holds the driver's zoom; after the 8 s auto-resume or a Follow tap the zoom returns to the speed-based one. Decide if the driver's zoom should last longer than 8 s (it does not today).
4. **Heading-up and the ellipse:** in heading-up after a GPS or OBD dropout the ellipse still widens the view beyond the speed-based zoom, and returns when it shrinks.
5. **No speed:** with OBD and GPS both stale (tunnel) the zoom holds its last value instead of snapping to 250 m. Cold start (no speed yet) is 250 m.
6. **Double tap:** from about 55 km/h (a 300 m span is a 561 m camera distance), and for about 6 s after slowing down (the zoom-in dwell), the first double tap on the map says "Zoom in…" and zooms; the second passes.

### Added by N3.3, roads live (not verified on a device)
1. **D1, a 30 min city drive with a region pack:** copy a region pack (and the national one, if used) to `Documents/RoadPacks/` with `scripts/push_packs.sh` (Finder still works as a fallback), check Settings → Diagnostics lists it as Verified, then record a 30 min city drive. Diagnostics shows "Recording uses" with the pack names and the time roads became active, the on-road share and "© OpenStreetMap contributors". The sidecar's `msPerStep` and `maxStepMs` stay ≤ 2 ms per 10 Hz step with roads, road-update steps included, and the sidecar has a `roads` line. Note the Memory row (`phys_footprint`) before the recording, after roads become active and at the end, and CPU and thermal state (Diagnostics' thermal row, or the stats line under the map speed). Mac references (docs/NAVIGATION.md, "N3.3: roads live"): 0.08–0.12 ms/step with roads; national + region-A add 0.73 MB of footprint at load, and the engine's road state about 2–2.4 MB of heap by the end of a drive. **drive-11** (Drive_20261016-174006, Release build, packs on the phone) is the first live-roads drive. It is NOT claimed for D1: the screen was being recorded for the whole drive (a CPU/thermal confound), and the drive was ~17.5 min (1047 s), not 30. Facts: lifecycle `roadPacks` "2 found, 2 verified"; sidecar `roadsSelection` outcome `selected` (national + region-A) and the `roads` line at 33.5 s; fully jammed (96 location fixes, none with a valid speed, all ≥ ~50 m accuracy, mostly ~1.4 km); one pin at 559.8 s, converged 4 s later (564 s) with the ellipse semi-major 1510 → 69 m; after that onRoadShare ≥ 0.98 in 475 of 484 estimates (dips: 0.07 at 902 s, 0.51–0.63 at 951–952 s, 0.95–0.98 at 570–571, 594–595, 901 and 996 s); `msPerStep` (per-second sidecar values, 1014 estimates) median 0.38 ms, p99 0.96 ms; `maxStepMs` 16.4 ms, already present in the first estimate line at 34.0 s, right after roads attached. The sidecar keeps a running max, so the attach step is the likely but unproven source. This is over the 2 ms D1 limit, so the attach step needs a check. D1 still needs a Release drive without screen recording. Memory (`phys_footprint`) was not noted. **NOT claimed.**
2. **D2, pack verify and load time on the phone:** after copying a pack, Diagnostics shows it as Verified with "verified in x s"; note x for each pack (Mac, warm file cache: national 70.5 ms, region-A 29.3 ms). Relaunch the app: the same packs show "cached" and are not verified again. Re-copying a pack via Finder (new modification date) verifies it again; `scripts/push_packs.sh` skips unchanged packs, so use Finder or delete the pack on the phone first to force it (whether `devicectl` copy sets a new modification date is untested). A truncated or corrupt pack shows "Refused: …" and the recording runs without it. **NOT claimed.**

### Added by road-pack warning (not verified on a device)
1. **Empty RoadPacks folder:** with `Documents/RoadPacks` empty (or every file refused), start a recording: within a second or two of the library scan the map shows one line above the recording indicator, "No road packs — roads off", with an orange outline. With a pack that does not cover the drive area it says "No road pack covers this area — roads off" once the first selection has ended; with a pack the run refuses it says "Road packs refused — see Diagnostics". No line before the first selection outcome when verified packs exist.
2. **Clears:** copy a covering pack to the phone (`scripts/push_packs.sh`) before Start: no line, and Diagnostics shows "Recording uses". After Stop the line is gone.
3. **No collisions:** double-tap a pin while the line is up: the "Fix recorded / Undo" toast stacks below it; the recording indicator, Re-centre hint and Heading/Follow buttons are not covered. Pan the map to get the Re-centre hint and check again.
4. **Readable in the mount:** read the line at arm's length in daylight; the long "No road pack covers this area" text may shrink to 80 % on a narrow phone (check it stays on one line and legible). Tapping it opens Settings (Diagnostics).

### Added by the backlog triage sweep (2026-10-17) — not verified on a device
1. **ELM write-offs and clone banners (bench):** count the write-off notes and the `ATZ banner without 'ELM'` notes over a bench session, and decide whether to model `STOPPED` in the mock (a real ELM327 aborts a pending command on any received byte). (M1-E3)
2. **Vgate write stalls:** check whether the Vgate write characteristic is `withoutResponse`-only, and whether write stalls past the 1 s readiness limit of `BLETransport` happen (they log a `timeout` first and cost a needless `ATZ` re-init). (R3.2-1)
3. **Camera distance/span ratio:** measure `camera.distance / visibleSpan` on the device and compare it with `MapFraming.distancePerSpan` (1.87, a guess that matches on one axis only). (M10.1-4)
4. **N3.4: Finder/Files overwrite of a road pack:** check whether a Finder or Files copy overwrites a pack in `Documents/RoadPacks` in place, which would affect the memory-mapped pack (SIGBUS risk during a recording). This decides whether N3.4 import must clone packs into a private directory. (R32.1-8)
5. **Multi-ECU replies on the Touareg (M1-E1):** with functional addressing (`ATSH7E0` refused or skipped), check the `elm` rows of `010D`/`010D0C` for replies holding a bad or status line next to `7E8`'s answer. They must now be `ok` with `obd` rows from every ECU that decoded and the whole reply in `rx`; one whose `7E8` line is bad must be `malformed`/the status, with no `obd` rows. Note how often it happens over a drive.
6. **First-sample timeout during selection (B1-1):** count `start-up selection: … timed out on its first sample; retrying once` notes over several inits (cold start, reconnects). After one, the plan should still be `010D0C1` at `7E0`; a `link desynchronised during initialisation` note right after it means the late prompt never came and init restarted from `ATZ`.
7. **Remembered plan keyed on the vehicle (M7.1-3):** on reconnect the `poll plan reused …` note still appears on the Touareg (`ATDPN` `A6`, the same `7E8` `0100` bitmask each time). If `remembered poll plan not reused: chosen on a vehicle whose 7E8 0100 bitmask is …` appears on the same car, the bitmask varies between connections (ignition state?) and the key is too strict: record both values.
8. **Plan after a failed polling run (M7.1-2) and a dropped PID (M7.1-1):** after a `needsReconnect` caused by poll failures (not an unplug), the reconnect runs the full selection (no `poll plan reused` note). After a session whose selection dropped RPM on `NO DATA`, the reconnect also selects in full.
9. **Replay after a PID drop (M7.1-5):** start a recording after polling has dropped a PID: the last replayed `adapter` row (negative `t`) carries the plan the header shows.
10. **Link loss in the log (R32.2-4):** after an unplug while recording, the dropped session's last `elm` row is `→ failed` with `transport closed` (never `→ idle` `shutdown`), and any reply bytes that arrived just before the loss are in an `elm` row.
11. **GATT discovery watchdog (R3.1-7):** over several connects, reconnects and Bluetooth off/on cycles, `discovering → connected` should take well under the 10 s limit; note the longest. A `GATT discovery timed out` row on the Vgate means a callback really went missing (or 10 s is too short for it): record which step was pending if the console shows it.
