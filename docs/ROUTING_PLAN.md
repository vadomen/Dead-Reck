# Routing plan: navigation along a route

**Status:** approved 2026-11-14 (D1–D5). Prompt 49 in progress (branch `routing-prereqs`).
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
| D1 | Which branch to start from | From `main`, on branch `routing`. Route UI lives in new files under `App/Sources/UI/Route/`. `MapView.swift` only gets hook points. | Keeps the unverified no-OBD code out. Later conflicts with `nav-noobd` stay limited to `MapView`, the log format and PLAN/BACKLOG. |
| D2 | Log format version | First port **only the v6 format** from `nav-noobd` to `main`: `manualFix.tapLatitude/tapLongitude`, the `.v6` case and a v6 fixture. That diff is about 60 lines in `Log/`. The route events then go in **v7**. | There can never be two different v6 formats, and `main` can read recordings made by the `nav-noobd` build. |
| D3 | Debrief prerequisites to take into `main` | Take #3 (rejecting fixes that jump), #6 (BLE goes silent after reconnect) and #8 (legend for the fix dot). #2 (losing the road on loops) is covered by R3. #1 and #5 stay with no-OBD. | #3, #6 and #8 hurt the OBD mode and every field test. |
| D4 | Routing source | **A: MapKit online.** That means `MKLocalSearch` and `MKDirections`. Option B (offline routing on the road packs) is deferred. | A takes about 5 prompts. B takes 8–12 and needs pack v2 (turn restrictions, maxspeed, names) plus an address index. |
| D5 | Saved destinations | Keep up to 10 recent destinations plus pinned ones ("Home", "Work"). Stored on the device only, with no sync. Settings gets a "Clear" button. | They are convenient. They are personal data, but they never reach logs, commits or tests. |

## Prompt sequence

The next free prompt number is 49. Every prompt gets its own branch or worktree, then `/review-loop`, then a merge.
The user does the push.

### 49: Prerequisites (on `main`)

In progress.

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

- **Problem.** A fix that claimed 15 m lay 472 m away. The engine accepted it, and it moved the estimate.
- **Gate.** Use the Mahalanobis distance of the fix from the particle cloud. If the fix is far outside its claimed accuracy, do not take it. A fix like that is only accepted after N consistent fixes in a row, which covers the case where the engine itself is the one that is lost.
- **Config.** Add a `NavigationConfig` key. The default is set by the adoption rule.
- **Adoption.** Use `nav-adoption`: all runs × seeds 1–5 × roads on and off. Report the drive-2026-11-02 case separately.

### 51 = R1: Spike, route model in Core, route log

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
   - `--route-from-truth`: a synthetic route built from the reference track, for replay without a real route.
   - `--route-perturb <mode>`: a wrong route, used for robustness tests in R3.
   - Without these flags the output must be byte-identical.
   - Document the flags in `docs/NAVIGATION.md`, section "replay_nav".

### 52 = R2: Destination and route UI

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

### 53 = R3: Route in the engine (OBD mode first)

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
   - **`--route-from-truth`:** the median does not regress, and there are gains on interchanges and loops. Report time off-road on those segments separately.
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
  - Replay with `--obd none` + (a) + `--route-from-truth`.
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
