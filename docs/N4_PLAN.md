# N4 plan: live navigation in the app

Approved plan. Model, config, replay commands and acceptance: `docs/NAVIGATION.md`.
Roadmap: `WORKFLOW.md`, "Navigator roadmap".

## Context
N2 delivered a causal, deterministic particle filter in Core and `replay_nav`.
N4 runs that filter live in the app and adds:
- a blue dead-reckoning dot with its 95 % ellipse;
- heading-up driven by the dead-reckoning heading;
- an "I'm here" pin that starts at the estimate;
- a debug stats overlay;
- a per-recording sidecar file, so a replay can prove it reproduces what the driver saw.

The logger keeps its behaviour, timing and log format.

## Prerequisites (done before N4 starts)
- **N2.1 engine update — done:**
  - speed-scale prior 1.016 ± 0.01;
  - manual-fix σ from the map span;
  - fixes without speed treated as network fixes;
  - ellipse consistency metric;
  - clean-long and manual-3 added to the replay set.
- **N2.2/N2.3 — done:**
  - stale-fix σ growth by age (> 5 s at ingest, k = 1.0 m/s);
  - mean-based adoption rule;
  - run-13 whole-engine review fixes: manual-fix reset, bounded stale speed with a parked latch, plane re-anchoring, discriminating tests.
- **Gate:** run-13 review must be clean and merged into main before the N4 branch is cut. Done: clean at round 3.

## N4
Branch `n4-live-nav` from main after the prerequisites are merged. The owners work in order B0 → A → B → C.

### B0. Engine fixes that change behaviour (navigation-engineer, own commit, first)
These change engine results, so they land before anything else and set a new baseline.
- **R13.2-2:** reset the motion EMA on every fresh OBD 0, so residual braking can't clear the parked latch.
- **R13.2-3:** the motion-EMA timestamp never goes backwards on an out-of-order sample.
- **R13.1-6:** coalesce long gaps, or cap the catch-up step count, so a resume after suspension doesn't block the actor.
- **R13.1-5:** cap the `estimate(at:)` extrapolation horizon, then hold or grow the covariance. The first UI frame after a resume must not jump.
- **R13.2-4:** doc drift (stale speed "random-walks", `stationary`, plane-relative `east`/`north`).
- Each fix has a regression test that fails before it.
- Acceptance: seeds 1–5 on the six drives under the mean-based adoption rule, recorded as an "N4-B0" table in NAVIGATION.md. This is the baseline the rest of N4 must reproduce bit for bit.

### A. Sample tap and sidecar file lifecycle (sensors-logging-engineer)
- **Tap at the single chokepoint, `LogSink.record`** (`Core/.../Log/LogFile.swift:89`).
  - `LogSink` gets an optional `tap: (@Sendable (LogEvent) -> Void)?`, set when the writer is created.
  - It is called after the event is enqueued for the writer, and only for `motion`, `location`, `obd` and `manualFix`.
  - The tap must never block, because callers hold `SampleGate`'s lock.
  - The live order is therefore exactly the file order.
- **Core `NavigationTap`:** wraps an `AsyncStream<NavigationInput>` continuation with `.bufferingNewest(4096)`.
  - A `.dropped` yield increments an atomic `droppedInputs` counter. Only navigation input is ever dropped, never a log row.
- **Wiring:** `RecordingSession.start` (:441-454) creates the tap with the writer and hands the stream to the NavigationService.
  - Stats rows and the writer are unchanged.
- **`LogStore`:** treats `<recording>.nav.jsonl` as a companion file.
  - It sits in the same folder, is exported together in the share sheet, and is deleted together with the recording.
  - It is not listed as a recording.
  - The logger and `inspect_log` never read it.
  - `.gitignore` already covers `*.jsonl`.
- **Tests:**
  - Core: a tap that never drains leaves the log rows byte-identical and in the same order, and `droppedInputs` counts the overflow; a nil tap has no effect.
  - App: share and delete include the companion file, and the recordings list ignores it.

### B. NavigationService, seed, sidecar and replay (navigation-engineer)
- **Seed:** Core `NavigationSeed.derive(header:)` is a stable 64-bit FNV-1a over the bytes of `header.sessionID`.
  - It is exact, unlike `startedAt` after ISO 8601 rounding.
  - A test pins its value.
- **`App/Sources/Navigation/NavigationService.swift`:** an `actor`, off the main thread. It holds one `NavigationEngine` per recording.
  - A fresh engine for every recording, so a relaunch mid-drive is a new recording (this fixes R11.2-3 in practice).
  - It consumes the tap stream and calls `ingest`. manualFix is the engine's position reset.
  - It measures ms/step with `ContinuousClock` (EMA and max).
  - It exposes `snapshot(at:) -> NavigationSnapshot` (`Sendable`): lat/lon, the ellipse, heading, heading σ, `converged`, `initialized`, and stats (ms/step, ESS, heading std, speed scale, `droppedInputs`).
- **Sidecar `<recording>.nav.jsonl`**, always written while recording.
  - The format is versioned (`NavSidecar` v1 Codable types in Core, separate from the log format) and has three kinds of lines:
    - **header:** sidecar version, seed, config hash plus config JSON, app build, and the `sessionID`;
    - **estimate:** one per second of session-clock time (t, position, heading, ellipse, `converged`, speed scale, `droppedInputs`);
    - **pin:** the estimate at each confirmed manualFix, as the prior just before ingest.
  - Writing is buffered and flushed every 10 s on the actor. A truncated last line is tolerated.
  - Size is about 100 KB per hour.
- **`replay_nav`:**
  - `--seed header` uses the derived seed.
  - `--as-live` means file order, the derived seed and the default config.
  - `--compare <sidecar>` reports the max position, heading and ellipse difference against the replay at the same t, plus the sidecar's `droppedInputs`. A difference is expected only if inputs were dropped, and then the drop count is reported.
  - A config hash mismatch is a warning.
  - The replay output now also records the dead-reckoning estimate and its ellipse at each manualFix confirm time, in metrics and in GeoJSON.
- **Deferred review item to close here** (docs/BACKLOG.md; R13.1-5/6 moved to B0):
  - **R13.1-7:** check that an arm64 Mac and the iPhone give identical bits on one recording before relying on exact `--compare`; otherwise compare with a tolerance.
- **Tests:**
  - Core: seed stability; sidecar round trip; on a synthetic recording, `--as-live --compare` against a sidecar from the same engine run gives exactly 0.
  - App: service lifecycle (fresh engine per recording), the sidecar is written and closed on stop, and drops are surfaced.

### C. Map (ios-ui-engineer)
Builds on `MapViewModel`, `GPSMapView`, `FollowController`, `HeadingState` and `MapFraming`.
- **Feed:** a main-actor `NavigationFeed` polls `service.snapshot(at: clock.now())` from the existing 100 ms heading loop.
  - It runs only while the map is visible and the scene is active.
  - Writes go through a gate in the M9.1-5 style (position change above a threshold or heading change above 2°, at most every 0.25 s).
- **Dead-reckoning dot and 95 % ellipse** (a `MapPolygon`) from initialisation onward.
  - "Calibrating heading" is only a label.
  - While the heading has not converged, the ellipse is always drawn, never the dot alone.
- **Follow:** centres on the dead-reckoning estimate once initialised, otherwise on the GPS fix.
  - In heading-up, the span fits the ellipse: span = min(1000 m, max(current minimum, 2.2 × semi-major)).
- **Heading-up bearing:** the dead-reckoning heading once `converged`, otherwise the M4.3 rule (`GPSCourseBearingSource`).
  - The `CameraHeading.choose` logic is extended in pure code and tested.
- **Reference GPS:** unchanged, except that fixes with accuracy over 1000 m become faded dots that are not part of the polyline.
  - This lives in `GPSTrack` as a separate capped point list.
- **"I'm here":**
  - The pin starts at the current dead-reckoning estimate (the GPS fix before initialisation, the finger position as a last resort). The driver only nudges it.
  - Confirm is enabled only when `visibleSpanM` ≤ 300 m. Otherwise it shows "Zoom in to place the pin precisely".
  - `ManualFixGate` speed gate unchanged. The logged mapSpanM is computed as today.
- **Debug stats overlay:** toggled with `@AppStorage("debug.navStats")`. It shows ms/step, ESS, heading std, speed scale and dropped navigation inputs. Nothing is logged.
- **Tests:** pure logic only (bearing choice, ellipse framing span, faded-fix split, pin start, the 300 m rule), in the pattern of `MapCameraLogicTests`.

### D. Device checklist: `docs/PLAN.md` §6, "Added by N4 (not verified)"
- ms/step on the iPhone with 2000 particles (overlay and sidecar).
- CPU and thermal state over 30 min.
- OBD dropout while driving, and ignition-off.
- Relaunch mid-drive: fresh engine, new sidecar.
- Motion still ~100 Hz and OBD still ~16 Hz in the stats rows, unchanged from before N4.
- A jammed drive of 20+ min with 2–3 pins at full stops at recognisable spots, and the screen locked for 10 min in the middle.
  Afterwards, `replay_nav --as-live --compare <sidecar>` gives 0 difference, or the difference is explained by `droppedInputs`.

## Verification
- `cd Core && swift test`
- the import grep (Core: Foundation only)
- `xcodegen generate` after adding App files
- the simulator build
- app tests on a concrete simulator id
- the acceptance replays: B0 is re-baselined under the adoption rule; after B0, A, B and C must leave them bit-identical (only B0 may change engine results)
- no log-format diff (`LogFormatVersion`, `LogFormatCompatibilityTests` untouched)
- `/review-loop` on the N4 range, then merge
