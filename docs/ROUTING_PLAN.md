# Routing plan: navigation along a route

**Status:** approved 2026-11-14 (D1–D6). Prompt 49 done (commit 579a796 on branch `routing`, 2026-11-14, review run 88; not in `main`). Prompt 50 done 2026-11-14 as observe-only (gate dropped by the user; branch `fix-jump-gate` into `routing`).
Context: `logs/HANDOFF_2026-11-13_ROUTING.md`, `logs/DEBRIEF_2026-11-02.md`.
Engine model and adoption rule: `docs/NAVIGATION.md`.

## Goal

The flow is: pick a destination, build a route, then guide the driver to it with dead reckoning.

Routing comes before the no-OBD work. Without a route, the no-OBD mode does not work well enough
(`nav-noobd`, prompts 44–47b). With a route, the engine has a strong constraint at junctions,
interchange loops and motorway entries. It helps the OBD mode as well.

Once routing is done, branch `nav-noobd` comes back, this time with the route as a prior.

## Decisions

| ID | Question | Decided | Why |
|---|---|---|---|
| D1 | Which branch to start from | On branch `routing` (cut from the 1.0 release). Route UI lives in new files under `App/Sources/UI/Route/`. `MapView.swift` only gets hook points. | Keeps the unverified no-OBD code out. Later conflicts with `nav-noobd` stay limited to `MapView`, the log format and PLAN/BACKLOG. |
| D2 | Log format version | First port **only the v6 format** from `nav-noobd` to `routing`: `manualFix.tapLatitude/tapLongitude`, the `.v6` case and a v6 fixture. That diff is about 60 lines in `Log/`. The route events then go in **v7**. | There can never be two different v6 formats, and `routing` can read recordings made by the `nav-noobd` build. |
| D3 | Debrief prerequisites to take into `routing` | Take #3 (rejecting fixes that jump), #6 (BLE goes silent after reconnect) and #8 (legend for the fix dot). #2 (losing the road on loops) is covered by R3. #1 and #5 stay with no-OBD. | #3, #6 and #8 hurt the OBD mode and every field test. |
| D4 | Routing source | **A: MapKit online.** That means `MKLocalSearch` and `MKDirections`. Option B (offline routing on the road packs) is deferred. | A takes about 5 prompts. B takes 8–12 and needs pack v2 (turn restrictions, maxspeed, names) plus an address index. |
| D5 | Saved destinations | Keep up to 10 recent destinations plus pinned ones ("Home", "Work"). Stored on the device only, with no sync. Settings gets a "Clear" button. | They are convenient. They are personal data, but they never reach logs, commits or tests. |
| D6 | Where routing work lands (user, 2026-11-14) | All routing work, prerequisites included, lives on branch `routing`. Prompt branches are cut from `routing` and merged back into it. `main` stays at release 1.0 until the user merges `routing` after real drives. | A release branch must not carry unverified routing code. Prompt 49 is 579a796 on `routing`, not in `main`. |

## Prompt sequence

The next free prompt number is 53 (prompt 52 is done in code on `r2-route-ui`, device checks open; prompt 51 is done on `r1-route-core`, merged into `routing` as 349d36c; prompt 50 is done, observe-only). Every prompt gets its own branch or worktree, then `/review-loop`, then a merge.
The user does the push.

### 49: Prerequisites (on `routing`)

Done (commit 579a796 on `routing`, 2026-11-14; review run 88; not in `main`).

1. **Port log v6.**
   - Port the format change only: the case, the two optional fields, `RecordingAnalysis` and the CSV.
   - Port the v6 fixture.
   - Do not port the pin-snapping logic.
   - v1–v5 fixtures must stay unchanged and green.
2. **BLE reconnect (debrief #6).**
   - Backoff already exists in `OBDLinkService`. Yet on 2026-11-02 there was one attempt and then 3 minutes of silence.
   - Find out why: the reconnect task may be cancelled, a state may get stuck, or the app may be in the background.
   - Fix it and add a test with `SimulatedOBDLink`.
   - Every attempt is visible in the log.
3. **Legend for the fix dot (debrief #8).**
   - The dot is the raw iOS fix. Its colours mean: green ≤ 15 m, yellow ≤ 100 m, orange ≤ 1 km, red > 1 km, grey = stale.
   - Explain it with a tap on the dot or the "i" in the HUD, plus a site section in en and uk.
   - Make clear that the dot is not FuGPS's own position.
4. **Done when:**
   - `swift test` and the app tests pass.
   - Replay output is byte-identical (73/73).

### 50: Rejecting fixes that jump (debrief #3, engine, OBD mode)

Done as observe-only (commit cf42628 on branch `fix-jump-gate`; the gate was dropped by the user's decision on 2026-11-14).

- **Problem.** A fix that claimed 15 m lay 472 m away and the estimate moved.
- **Diagnosis (step A).** The fix was a network fix. The restored-prior check (`judgeRestore`) moved the estimate, not the fix gating. The pins show the fix was right and the restored prior wrong.
- **What landed.** An observe-only counter: `replay_nav` writes `fixJumps` per row in `metrics.json` and a "Fix jumps" line in the summary (M² of the innovation against P + R, threshold 25). It changes no engine behaviour and is off in the app. 101 cells hash-identical. Details: `docs/NAVIGATION.md` "Prompt 50: fix jumps (2026-11-14)".
- **Survey result.** A plain M² > 25 gate would have blocked correct fixes (clean 201.6 s, drive-11-02). The only bad-fix examples are the constant-offset stream (drive-10) and a bounded ~27 m drag (clean 123–127 s).
- **Backlog.** NAV-FIXJUMP (the gate, deferred) and NAV-RESTORE-1FIX (one fix discards a restored prior, deferred).
- **No device check.** The app is unchanged.
- **Next:** prompt 51, unchanged.

### 51 = R1: Spike, route model in Core, route log

**Status: done on branch `r1-route-core` (2026-11-15), merge pending review.** Results: `docs/ROUTING.md` (spike verdict "usable with limits", Kyiv-only geometry check; route model; `RouteEdgeMatcher`), `docs/LOG_FORMAT.md` (v7), `docs/NAVIGATION.md` ("replay_nav" and "Prompt 51 E.3"). Replay output without route flags is byte-identical (101/101). The plan below is the original; where the result differs: the reference-route flag is `--route-from-reference` (not `--route-from-truth`), `route` has the extra reason `restored` and an optional `origin` with `source`, and `routeCleared` carries `routeID`.

1. **Spike `MKLocalSearch` / `MKDirections` in Kyiv**, 5–10 typical requests. Check:
   - address quality (house number, entrance);
   - whether alternatives exist;
   - instruction language (uk and en);
   - how far the route polyline sits from OSM geometry;
   - latency and failures.
   Write the results in `docs/ROUTING.md` with no addresses or coordinates; the requests are described by type.
   **Gate:** if the quality is unacceptable, stop and revisit D4.
2. **Core types, Foundation only:**
   - `Route`: `id`, `polyline: [GeoPoint]`, `steps: [RouteStep]`, `expectedTravelTime`, `distance`, `source` (`appleMaps`, `synthetic`).
   - `RouteStep`: `instruction` (text), `distance`, `polylineRange`, `maneuver`.
   - `MKRoute.Step` has no maneuver type, so Core computes `maneuver` from geometry: left, right, slight, U-turn, exit, merge, straight, arrive. This is tested on synthetic polylines.
   - The App adapter `MKRoute → Route` is mechanical. MapKit stays in App only, so the Core invariant holds.
3. **`RouteEdgeMatcher` in Core, under Navigation/Roads.**
   - Map the route polyline onto the pack graph with Viterbi over `RoadMatcher` candidates.
   - Output: a sequence of edges as (`osmWayID`, `wayPointOffset`), the coverage fraction, and gaps.
   - Tests: a synthetic grid, a one-way street, a roundabout, and a polyline shifted by 10–30 m.
   - **Coverage threshold.** Below it, the route counts as a weak hint only, without the edge prior. The value is set from the spike.
4. **Log v7.**
   - Event `route`: set or rebuilt, with reason (`user`, `offRoute`, `alternative`), polyline and steps.
   - Event `routeCleared`: arrived or cancelled.
   - Add a v7 fixture. Earlier versions must stay readable. Update `docs/LOG_FORMAT.md`.
5. **`replay_nav`.**
   - `--route <file.json>`: a route from a file.
   - `--route-from-reference`: a route built from the recording's clean GNSS fixes (never from the engine's own estimate), for replay without a real route. Drives without clean fixes have none (`docs/ROUTING.md`).
   - `--route-perturb <mode>`: a wrong route, used for robustness tests in R3.
   - Without these flags the output must be byte-identical.
   - Document the flags in `docs/NAVIGATION.md`, section "replay_nav".

### 52 = R2: Destination and route UI

**Status: done in code on branch `r2-route-ui` (2026-11-15); device checks open (PLAN §6 "Added by prompt 52").** What was built: `docs/ROUTING.md` "App flow (prompt 52)". Where the result differs from the plan below: the long-press pin is passed as pressed, with no snapping to our packs (MKDirections snaps to its own network); the app adapter lives in `App/Sources/Route/`. Deferred: engine use of the route (53), automatic off-route detection and rebuild (UX-45), voice (54), share extension, route restore after relaunch (UX-44), offline routing. Notes for the next prompts:
- **53:** the `RouteEdgeMatcher` result is computed once at Start (when installed packs cover the route) and kept with the active route; the UI shows it only in Settings → Diagnostics → Route. The matcher builds its own `RoadNetwork` from the pack library because `NavigationService` does not expose the live network (BACKLOG `ROUTE-NETWORK-SHARE`). The display guard (cross-track above 150 m, "Away from the route") is UI only and writes no row; 53 owns real off-route detection and the `offRoute` reason.
- **53 and replay:** when Record starts with an active route, a `route` row with reason `restored` is written right after `start` (and `navPrior`), carrying the original origin, so `replay_nav` sees the route from the start of such a recording.
- **54:** guidance text and distances come from the Core projection of the estimate on the polyline; the uncertain-position state already shows "Position uncertain" instead of a distance, and voice must follow that rule.
- **55:** drive checks are the PLAN §6 list for prompt 52.

**What the spike changes (prompt 51, `docs/ROUTING.md`; user's search limits, 2026-11-15):**
- **Search languages:** uk and en only; no Latin transliteration of Ukrainian names.
- **Fallback:** fraction house numbers and businesses by name are unreliable, so the long-press pin is a required fallback, not an extra.
- **Pace and retry:** pace requests (about 1.5 s apart) and retry on throttling; `MKError` code 3 can look like "no result".
- **Alternatives:** the alternate route sets are not stable between calls; do not assume a second call returns the same set.
- **Steps:** the first step's instruction is empty; do not show it.
- **Adapter location:** `RepositoryInvariantTests` forbids the MapKit routing and search type names in `Core/` and `App/Sources/Navigation`. The `MKRoute` to `Route` adapter must live elsewhere, or the test needs a user decision. Settle this first.
- The geometry check covers Kyiv only (BACKLOG `ROUTE-SPIKE-OUTSIDE`).

**Choosing a destination:**
1. **Search.**
   - `MKLocalSearchCompleter` suggests results as you type. The search region is centred on the FuGPS estimate.
   - Picking a suggestion runs `MKLocalSearch` and gives an `MKMapItem`.
   - Places (businesses, landmarks) can be found too.
2. **Long press on the map.**
   - Drops a pin at the press point.
   - The pin snaps to the nearest road in the pack, so a route does not end on the far side of a block. The rule is the same one used for the "I'm here" pins.
3. **Recent and pinned destinations** (D5), shown in the empty search state.
4. **Card for the chosen point.** It shows name, address and straight-line distance. Buttons: "Route" and "Pin".

**Building the route:**
- **The source of `MKDirections.Request` is the FuGPS estimate, not the iOS location**, because under jamming the iOS location is wrong.
  - If the estimate is uncertain ("Position uncertain", a wide ellipse), show a warning and offer to mark the position with "I'm here".
- Ask for up to 3 alternatives. Each shows time, distance and the line on the map.
- The driver picks one and taps "Start". This writes a `route` event to the log while recording.
- Dragging the pin before start rebuilds the route.

**During guidance (the minimum for R2):**
- The route line is drawn on the map.
- The next step is shown as maneuver, distance and instruction text. Distance is still measured along the polyline from the estimate; the engine gets the route in R3.
- "Cancel route".

**Also in R2:**
- Update the privacy policy (site and app) and App Privacy: the route start and destination are sent to Apple.
- Strings in en and uk.

**Not in R2:**
- "Share → FuGPS" from Apple Maps or Google Maps. This needs a share extension (a new target, App Review risk), so it gets its own prompt after R4.

### 53a: Coordinates, pasted map links, the last leg (on `routing`)

**Status: done in code on branch `r2-coords-links` (merges into `routing`, 2026-11-24; review run 94 closed (4 rounds), 2026-11-24); device checks open (PLAN §6 "Added by prompt 53a").** What was built: `docs/ROUTING.md` "Coordinates, map links and the last leg (prompt 53a)". The optional `destination` on the v7 `route` row is within v7, no version bump (user decision 2026-11-24; `docs/LOG_FORMAT.md`). These are the last features before `routing` goes into `main` as release 1.1. **Next: prompt 54 (release 1.1).** The remaining drive findings are in `logs/PROMPT_53c_drive_findings_rest.md`.

### 53 = R3: Route in the engine (OBD mode first)

**From prompt 51:**
- **Weak rule:** a route whose `RouteEdgeMatcher` coverage is below 0.90 is weak: guidance and display only, no edge prior.
- **First numbers (`docs/NAVIGATION.md` "Prompt 51 E.3"):** with a strong reference the estimate is already on the route's edges 96–99 % of the time (clean-long, drive-8 after the mask), so there is little to gain there. The room is on weak references and loops, which cannot be scored until BACKLOG `ROUTE-REF-CONFIRMED` (human-confirmed reference routes for the jammed drives) is done. It is a prerequisite of this prompt.

1. **Edge prior.**
   - Particles on route edges get a bonus at the junction-transition step.
   - Leaving the route costs a configurable penalty. It is not a ban, because the driver may leave the route.
2. **Progress along the route.** Track the distance from the start and to the next maneuver. This feeds the UI and R4.
3. **Off-route detection.**
   - Signals: the gyro does not confirm the expected maneuver within a distance window, or it shows a turn where the route has none; plus the fixes.
   - Debounce: the condition must hold for N seconds or M metres.
   - Result: an "Off route" status and a rebuild from the FuGPS estimate. That writes `route` with reason `offRoute`.
   - Rebuild throttle: no more than once every X seconds.
4. **Adoption** (`nav-adoption`, two-sided):
   - **Without a route:** sidecar byte-identical.
   - **`--route-from-reference`:** the median does not regress, and there are gains on interchanges and loops. Report time off-road on those segments separately.
   - **`--route-perturb`:** the route diverges from the truth, for example a missed exit or a different street. The engine must not lock onto the route. It must detect leaving the route within the agreed time and distance, with no larger error than the run without a route. **This is the main risk of R3.**
5. Update NAVIGATION.md and NAV_SIDECAR.md (route progress and off-route fields in the sidecar if needed; that is a sidecar version, not a log version).

### 54 = R4: Voice prompts

- Use `AVSpeechSynthesizer` through the existing voice layer (`GPSVoice`, UX-22).
- **Thresholds depend on speed.** Roughly:
  - city: 300 m and "now";
  - above 80 km/h: 1 km, 400 m and "now".
  Timing is calculated from the FuGPS position and progress (R3).
- **Language:** the instruction text comes from `MKDirections` in the system language. Short phrases ("in 300 metres") are our own strings in en and uk.
- **Audio:** ducking for music, a mute switch on the map, and prompts keep playing in the background during an active route.
- **Do not speak** when the position is uncertain. Show "Position uncertain" instead.

### 55 = R5: Test drives, then back to no-OBD

- Drives per PLAN §6, using `test-drive-prep` and then `drive-log-debrief`.
- Mandatory parts of the route:
  - an interchange with a loop;
  - a motorway entry;
  - a deliberate exit off the route;
  - arrival.
- After the debrief:
  - Return to `nav-noobd`.
  - Replay with `--obd none` + (a) + `--route-from-reference`.
  - **Criterion:** median ≲ 100 m, and better than showing the last fix.
  - Then plan bringing no-OBD into routing.

## Risks

| Risk | Mitigation |
|---|---|
| `MKDirections` quality in Ukraine | Spike with a gate in R1 |
| Apple geometry does not match OSM | Coverage threshold in `RouteEdgeMatcher`; below it the route is a weak hint only |
| The engine locks onto a wrong route | Penalty instead of a ban, the gyro check, and `--route-perturb` in adoption |
| Needs internet (at start and on rebuild) | Guidance continues on the last route; the rebuild is queued until the network returns |
| Privacy | Start and destination go to Apple only. The log keeps the route because recordings are private and never committed. Saved destinations stay on the device. |
| Conflicts with `nav-noobd` | D1 and D2: separate files and one shared v6 |

## Later (not in this plan)

- Share extension "Share → FuGPS".
- Option B: offline routing on the packs (pack v2 with turn restrictions, maxspeed and names, plus an address index).
- Lane hints, which need `lanes` from the pack.
- Speed limits, which need maxspeed.
