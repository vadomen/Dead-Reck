# Routing

What prompt 51 (R1, 2026-11-15, branch `r1-route-core`) found and built for routes: the
MapKit spike, the route model, `RouteEdgeMatcher`, and the rule for reference routes.
Plan and later prompts: `docs/ROUTING_PLAN.md`. Log rows: `docs/LOG_FORMAT.md` (v7).
`replay_nav` flags and results: `docs/NAVIGATION.md`. No addresses, place names or
coordinates appear here: requests are described by kind.

## Spike (step A): MKLocalSearch and MKDirections

A Mac command-line tool called MapKit (it answered from a bare command-line process).
The raw output is git-ignored. **The geometry check covers Kyiv only**: Apple's route
geometry may be worse in other cities (BACKLOG `ROUTE-SPIKE-OUTSIDE`).

**Verdict (user, 2026-11-15): option A, MapKit, is usable with limits.** The limits:

- Search is reliable for uk and en text only. Latin transliteration of Ukrainian names
  and English-style Latin names often find nothing or another country.
- Fraction house numbers and businesses by name are unreliable, so the long-press pin
  is a required fallback in prompt 52.
- Unpaced bursts of requests are throttled (`MKError` code 3). A throttled call can
  look like "no result".
- Alternate route sets are not stable between calls.
- The first step ("depart") always has an empty instruction and distance 0.
- Not tested: oneway direction and turn restrictions of Apple routes.

### Search

31 queries: `MKLocalSearchCompleter` plus `MKLocalSearch`, the region biased to the city
centre, uk and en locales.

| kind of request | rank of the right result | distance to the nearest pack road |
|---|---|---|
| street + house number (uk, en) | 1st | 12–63 m |
| street without street type (uk) | 1st | 26 m |
| house number with a capital Cyrillic letter | 1st (completer); free text with a Latin letter drops it | – |
| house number with a lowercase letter | letter dropped, so the wrong building (existence unverified) | 24 m |
| fraction house number "n/m" | missing (resolves to another number or a town) | – |
| hyphen + fraction | 1st | – |
| specific business by name (uk, en) | missing | – |
| chain business (uk, en) | top 3 | 22–36 m |
| university or venue (uk, en) | 1st | 32 m |
| landmark (uk, en) | 1st | 11 m |
| landmark, Latin transliteration or English-style Latin | missing (no result, or another country) | – |
| metro station (uk) | 1st in free text; the first completion is a same-named place in another city | 14 m |
| metro station (en, Latin) | missing (other country or no result) | – |
| shopping centre (uk) | 1st | 82 m (set back from the road) |
| shopping centre (Latin) | missing | – |
| village outside the city | 2 of 3 first (4–7 m); 1 resolved to a neighbouring village | – |

- Latency: free-text or per-completion search 0.2–0.45 s; the completer's first update
  under 1 s.
- Throttling: `MKError` code 3 (`loadingThrottled`) on unpaced bursts (~60 calls),
  cleared after about a minute; none in ~130 calls spaced 1.5 s apart.
- The completer sends several delegate updates, gives identical titles for same-named
  streets in other towns, and its region bias is soft.
- The language of results and instructions follows the process's `AppleLanguages`.

### Directions

8 pairs, automobile, alternates on: 19 routes, about 596 km, no errors, no notices.

| kind of pair | routes | steps | points | vertex spacing median / max (m) | latency |
|---|---|---|---|---|---|
| across the river (A) | 2 | 7, 9 | 84, 85 | 39 / 877 | 0.41–0.43 s |
| across the river (B) | 3 | 10–12 | 140–159 | 37–49 / 803–1102 | 0.26–0.33 s |
| large interchange | 3 | 6–8 | 53–69 | 30–67 / 742–1265 | 0.21–0.26 s |
| onto or off a motorway-class road (34–37 km) | 3 | 6–8 | 186–211 | 75–78 / 2653 | 0.36–0.66 s |
| short residential | 2 | 4, 6 | 34, 67 | 13–16 / 802 | 0.31–0.35 s |
| intercity, 83 and 102 km | 2 | 15, 19 | 411, 546 | 92–107 / 3194 | 0.6–0.75 s |
| intercity, 139 km | 1 | 7 | 320 | 163 / 3618 | 0.49–0.60 s |
| city ring road crossing | 3 | 4–10 | 164–236 | 63–86 / 1729 | 0.49–0.70 s |

- Instructions: with the uk locale 147 of 147 are non-empty and in Cyrillic; with en
  they are English, but 22 of 146 contain Cyrillic street names.
- Polylines are identical across locales except two alternates (the alternate sets
  are not stable between calls).
- Geometry against the packs (all 28 packs, nearest segment of any class): 100 % of
  every route's length is within 15 m (raw vertices and 10 m resampling), the maximum
  is 10 m, and 70 % of raw vertices are within 0.5 m. Apple's geometry appears to
  share a basis with OSM here. The largest offsets are on primary, trunk and
  secondary roads (plausibly dual-carriageway centrelines; not checked).
- Shift check (distance only): a 20 m sideways shift keeps 93 % of the length within
  15 m (length-weighted; worst route 79 %); 40 m keeps 69 %.
- Nothing was unfollowable: no ferries, closed-bridge notes or missing roads.

## The route model (item B)

`Core/Sources/DriveLoggerCore/Navigation/Route/`, Foundation only.

| Type | Content |
|---|---|
| `Route` | `id`, `polyline: [RoutePoint]`, `steps`, `distanceM`, `expectedTravelTimeS`, `source`, optional `label` |
| `RoutePoint` | `latE7`, `lonE7` (Int32). Rounded to 1e-7 degrees at construction, so the round trip is exact. |
| `RouteSource` | `appleMaps`, `synthetic`, `unknown(String)` |
| `RouteStep` | `instruction`, `distanceM`, `polylineRange` (closed; `to` inclusive), `maneuver`, optional `exitNumber` (key present only for `roundaboutExit`) |
| `RouteManeuver` | `depart`, `straight`, `slightLeft`, `left`, `sharpLeft`, `slightRight`, `right`, `sharpRight`, `uTurn`, `roundaboutExit(exit?)`, `merge`, `exitRamp`, `arrive`, `unknown(String, exitNumber?)` |

- The maneuver happens at the step's `to` vertex. Steps are in order, may share a
  boundary vertex, and need not cover the whole polyline.
- `unknown(name)` equals the known case with the same raw name. An unknown maneuver
  keeps its `exitNumber` (c87af37).
- `RoutePolyline` and `RouteGeometry`: cumulative distance, projection (distance
  along, signed cross-track with positive to the right, segment index), an optional
  along-range window for routes that pass a place twice, and `nextManeuver`.

On-disk JSON (sorted keys), as `replay_nav --route-write` writes it and a log `route`
row carries it:

```json
{"distanceM":99.5,"expectedTravelTimeS":20,"id":"r1","label":"Home","polylineE7":[100000,-200000,4500,0,0,4500],"source":"synthetic","steps":[{"distanceM":0,"from":0,"instruction":"","maneuver":"depart","to":0},{"distanceM":50,"from":0,"instruction":"Turn right","maneuver":"right","to":1},{"distanceM":49.5,"from":1,"instruction":"Arrive","maneuver":"arrive","to":2}]}
```

`polylineE7` is the first point absolute (latitude, longitude in degrees times 1e7),
then one (dLat, dLon) pair per further point. In the example the points are
(100000, -200000), (104500, -200000) and (104500, -195500). Deltas have no wrap at
180 degrees. Decode rejects an odd or short array, non-integers, out-of-range
coordinates, overflowing deltas, steps out of bounds or order, and negative or
non-finite distances or time.

**Maneuver thresholds** (`RouteManeuverThresholds`): Core computes the maneuver from
geometry, because `MKRoute.Step` has none. `chordLengthM` 40 and `junctionGapM` 20:
the turn at a vertex is the angle between the chord 40 to 20 m before it and the
chord 20 to 40 m after it. Straight below 20 degrees, slight below 45, normal below
120, sharp below 160, otherwise U-turn.

Measured limits, on the spike's routes:

- "Turn left" and "turn right" steps were classified to the right side 53 of 60 times.
- MapKit "U-turn" steps were found as U-turns 2 of 7 times. The rest are 40–60 m
  loops through a turnaround and read as left turns (BACKLOG `ROUTE-UTURN`).
- The roundabout exit number is nil when the ring crosses a pack border (BACKLOG
  `ROUTE-ROUNDABOUT-NIL`).

## RouteEdgeMatcher (item C)

`Core/Sources/DriveLoggerCore/Navigation/Roads/RouteEdgeMatcher.swift`. It maps a
route polyline onto the pack graph and reports which edges it follows, where it
leaves the graph, and how much of it is covered.

**Method.**

1. Resample the polyline every 10 m.
2. Candidates come from `RoadNetwork.forEachSegment` (shadowed segments never are),
   within 25 m of the sample and with a heading within 60 degrees of the route's
   (oneway edges only forwards).
3. Transitions between candidates cost the network distance, by a bounded Dijkstra:
   within a pack through end nodes; across packs at equal points where one is an
   edge end (the rule `RoadNetwork.adjacentEdges` uses). A bridge shares no node with
   the road below it, so there is no move between them.
4. The Viterbi path may restart at a fixed cost; the restart interval counts as
   unmatched.
5. Coverage counts a 10 m interval only if both its samples are within 15 m and are
   joined by a graph transition.

**Thresholds** (`RouteMatchThresholds`). The first three were decided by the user on
2026-11-15; the rest are tuning values.

| Name | Value | |
|---|---|---|
| `resampleSpacingM` | 10 | user |
| `matchDistanceM` | 15 | user |
| `weakCoverageBelow` | 0.90 | user |
| `candidateRadiusM` | 25 | tuning |
| `maxHeadingDifferenceDegrees` | 60 | tuning |
| `headingChordM` | 5 | tuning |
| `emissionSigmaM` | 5 | tuning |
| `headingSigmaDegrees` | 30 | tuning |
| `transitionScaleM` | 5 | tuning |
| `transitionSlackM` | 30 | tuning |
| `backtrackToleranceM` | 2 | tuning |
| `breakCost` | 20 | tuning |

**Output** (`RouteEdgeMatch`): `edges` (`osmWayID`, `wayPointOffset`, `pointCount`,
`forward`, `edgeFromM`/`edgeToM`, `segmentIndices`, `routeFromM`/`routeToM`,
`sampleCount`, mean and max distance, `highwayClass`, flags, level), `gaps`
(`startM`, `endM`), `coverage` and `isWeak`. **Coverage** is the matched fraction of
route length. A route with coverage below 0.90 is **weak**: prompt 53 uses it for
guidance and display only, with no edge prior. `roadContexts(for:match:)` feeds
`RouteManeuver`: link flags give merge or exitRamp, and the roundabout exit is counted
along the matched ring (only when the passage is contiguous within one pack, else nil).

**On the spike's 19 routes** (all packs): coverage at least 0.997 on every route (16
at 1.000), worst gap 30 m, none weak; 593 km in 1.46 s (10–280 ms per route).

**Shift results** (the spike routes shifted, coverage as the mean):

| shift | direction | coverage | weak routes |
|---|---|---|---|
| 10 m | perpendicular to travel | 0.99 (0.964–1.000) | none |
| 20 m | perpendicular | 0.25 | all |
| 30 m | perpendicular | 0.19 | all |
| 40 m | perpendicular | 0.14 | all |
| 20 m | east (the spike tool's method) | 0.66 | 18 of 19 |
| 40 m | east | 0.57 | – |

The matcher is stricter than the spike's distance-only check on every route, because
it also needs heading agreement and a connected path: with the spike tool's east
shift, 20 m gives 0.66 here against 93 % by distance alone.

**Timing** (Mac, release): a 50 km route takes 0.010–0.011 s; the packs load in 0.3 s.
The release perf test bounds a 51 km route at 5 s.

Tests (synthetic): straight street, junction turn, oneway against the route,
roundabout (exit 2), bridge over a road, parallel carriageways 20 m apart, shifts of
10, 20 and 30 m (10 gives above 0.99; 20 and 30 give 0 and weak), leaving coverage and
coming back, two packs sharing a border way (order independent), ramp and merge,
determinism.

## The reference-route rule

A reference route (`replay_nav --route-from-reference`) comes from the recording's
**clean GNSS fixes only**: accuracy in (0, 20] m, a valid speed, a valid course when
moving at 2 m/s or more, not simulated, and not in the truth file's `excludeFixes`.
Fixes at most 5 s apart join into a span (at least 2 fixes). It is never built from the
engine's own estimate: that would be circular.

So some drives have none:

- drive-9, manual and manual-3: **pin-anchored, not scored**. They have no clean track.
- jammed-A and jammed-B: no source.

BACKLOG `ROUTE-REF-CONFIRMED` (user, a prerequisite of prompt 53) is the way out: a
candidate rendered for the driver to confirm or correct, stored in git-ignored
`logs/routes/`. Reference routes are never in the repo. First measurements:
`docs/NAVIGATION.md` "Prompt 51 E.3".

## Note for prompt 52

- `RepositoryInvariantTests` forbids the MapKit routing and search type names in
  `Core/` and in `App/Sources/Navigation`. The `MKRoute` to `Route` adapter (and the
  search code) must live elsewhere, or the test needs a user decision. Decide this
  first.
- The search limits in "Spike" above apply: uk/en only, the long-press pin as a
  required fallback, paced requests with a retry on throttling.
