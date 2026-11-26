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

Independent check (drive-analyst, 2026-11-15; details in `docs/NAVIGATION.md`
"Prompt 51 E.3"): the clean-fix selection, coverage (within 0.02) and cross-track
numbers were reproduced. clean-long is trustworthy for the whole drive. drive-8 is
trustworthy, but on two dual-carriageway stretches the reference sits 10–14 m off the
true carriageway (matched, just inside 15 m). drive-7 is trustworthy only for its
clean span, the last ~270 s; its weak flag comes from one residential oneway that was
driven against its mapped direction (mapping error or contraflow: unresolved), so it
is a pack-data property, not route quality. clean is trustworthy only for 6–122 s
and 202–~361 s: its tail (~362–445 s) is unmapped and slow, and 623 m of its length
is a chord across a GNSS hole.

BACKLOG `ROUTE-REF-CONFIRMED` (user, a prerequisite of prompt 53) is the way out: a
candidate rendered for the driver to confirm or correct, stored in git-ignored
`logs/routes/`. Reference routes are never in the repo. First measurements:
`docs/NAVIGATION.md` "Prompt 51 E.3".

## App flow (prompt 52)

Done in code on branch `r2-route-ui`; device checks in `docs/PLAN.md` §6 "Added by
prompt 52". The search limits in "Spike" above apply: uk/en only, the long-press pin
as a required fallback, paced requests with a retry on throttling.

**Where MapKit lives.** The `MKRoute` to `Route` adapter and the search code are in
`App/Sources/Route/`, the only place `MKLocalSearch`, `MKDirections`, `MKRoute` and
`MKMapItem` may appear. `RepositoryInvariantTests` forbids those names everywhere
else, including `Core/` and `App/Sources/Navigation`. The views are in
`App/Sources/UI/Route/`.

**Flow** (`RouteFlowModel`): idle, search, place card, requesting, alternatives,
guiding, arrived, idle.
- `cancel()` goes to idle from any state; with an active route it writes
  `routeCleared` `cancelled`. `dismiss()` backs out of a sheet or a rebuild and keeps
  the active route.
- A long press (0.5 s; a drag of 10 pt or more cancels it) on the map opens the place
  card directly. The point is passed as pressed, with no snapping to our packs:
  MKDirections snaps to its own network.
- Search shows completions as you type. The region is centred on the FuGPS estimate,
  else the last good fix, else Kyiv-wide. uk and en only, no transliteration. The empty
  state shows recents and the pinned Home and Work.
- Layout E (UX-32): a 52 pt destination bar at the bottom above the OSM credit band;
  the right rail sits above it. During guidance it becomes the next-manoeuvre bar
  (glyph and distance, instruction, remaining distance and time, X to cancel with a
  confirmation). Nothing is added at the top.

**Origin rules** (`origin.source` in the `route` row):
- (a) Navigate or Record running and the engine estimate not "finding" (converged,
  95 % semi-major at most 1,000 m, that is `PositionStatus.isFinding` false): the
  estimate, source `estimate`.
- (b) Estimate finding: the card says the position is uncertain; "I'm here" pin first
  (source `pin`), "Route anyway" second (source `estimate`).
- (c) No estimate: the raw fix only if accuracy is at most 15 m, age at most 5 s and
  GPS is not switched off (source `fix`); otherwise the app asks for a pin.
- Raw iOS location is never used silently.

**Failure and pacing.**
- The completer is debounced; requests are at least 1.5 s apart.
- Throttled (`MKError` code 3): backoff 2, 4, 8, 16, 30 s; after 6 attempts a "busy"
  message, never "nothing found".
- Offline or nothing found: a message and Retry.
- An in-flight request is cancelled when the query or the destination changes.
- A failed request with no route writes nothing; a failed rebuild keeps the current
  route.
- Up to 3 alternatives are kept as shown and never re-requested to redraw (the sets
  are not stable between calls).

**Guidance.**
- The route line is drawn under the estimate marker. Progress is the Core projection
  of the FuGPS estimate on the polyline. With an uncertain estimate the bar shows
  "Position uncertain" instead of a distance.
- Display guard: cross-track above 150 m shows "Away from the route" and Rebuild. There
  is no automatic rebuild and no log row (UX-45).
- Manual Rebuild is a new request to the same destination: `route` row with reason
  `alternative`; a new destination gives `user`.
- Arrival: remaining below 50 m along the route and stopped (below 1 m/s) for at least
  3 s writes `routeCleared` `arrived` and shows "Arrived".

**Matcher.** `RouteEdgeMatcher` runs once at Start when the installed packs cover the
route. The result is kept with the active route for prompt 53 and shown only in
Settings → Diagnostics → Route. It builds its own `RoadNetwork` from the pack library
(BACKLOG `ROUTE-NETWORK-SHARE`).

**Recording.** `RecordingSession.recordRoute` and `recordRouteCleared` write v7 rows
stamped `clock.now()`, only while Record runs. At Record start with an active route
(a Navigate to Record hand-over in the same app session) a `route` row with reason
`restored` follows `start` (and `navPrior`, if present), with the original origin. With
no route the recording is unchanged.

**Saved destinations.** Recents (at most 10, newest first, de-duplicated) and pinned
Home and Work, in Application Support, on the device only, no sync. Settings → "Saved
destinations": swipe to delete, "Clear recent destinations". Never in logs, analytics
or the pasteboard.

**Not in prompt 52:** engine use of the route (53), automatic off-route detection
and rebuild (UX-45), voice (54), a share extension, route restore after an app
relaunch (UX-44), offline routing.

## Coordinates, map links and the last leg (prompt 53a)

Done in code on branch `r2-coords-links` (cut from `routing`); device checks in
`docs/PLAN.md` §6 "Added by prompt 53a". Code: `App/Sources/Route/CoordinateInput.swift`
(typed values), `MapLinkResolver.swift` (links), `RouteLastLeg.swift` (last leg),
`App/Sources/UI/Route/RouteLastLegModel.swift`; the log field is
`Core/Sources/DriveLoggerCore/Log/RouteDestination.swift`.

**Input shapes in the search field** (no network; a recognised value is one row above
the completer's results, then the normal place card with the title "Coordinates"):
- Decimal latitude and longitude separated by comma, semicolon or whitespace; decimal
  comma (`-45,0031 -120,0007`); an `N`/`S`/`E`/`W` prefix or suffix (the letters decide
  the axis; a sign together with `S` or `W` is rejected); a `°` sign; U+2212 as minus.
  A bare whitespace-only pair of integers (for example `500 600`) is not a coordinate.
- A `geo:lat,lon[,alt][;params][?q=…]` URI, including `geo:0,0?q=lat,lon`.
- Out of range: a short message ("Latitude is between −90 and 90, longitude between
  −180 and 180."). A pair that is valid only when swapped is never taken silently: it is
  a separate row "Coordinates, swapped".
- A name in the input (or in a link) becomes the card title, control characters stripped
  and capped at 80 characters; without a name the title is "Coordinates".
- The place goes through the same path as a long-press pin: origin rules, alternatives,
  recents, saved places. No reverse geocoding.

**Links** (parsed without a network request; precedence, first match wins):
- Apple Maps: `coordinate=`, then `q=lat,lon`, then `ll=`, then `sll=`. `name=` or a
  `q=` that is not a coordinate gives the title.
- Google Maps: `!3d<lat>!4d<lon>` (the last pair), then `q`, `query` or `destination`
  with `lat,lon`, then `/place/lat,lon` or `/search/lat,lon`, then `@lat,lon` (the view
  centre, the weakest). `/place/<name>/` gives the title.
- OpenStreetMap: `mlat`/`mlon`, then `#map=z/lat/lon`.
- Share text with words before the link works; a link without a scheme works when the
  host is allowlisted and the link is the whole text (R94.3-4, BACKLOG: with words before
  it, the text goes to the completer and gets no Open link row).
- Not accepted ("This link has no point…"): unknown hosts, `http`, `javascript:`,
  `data:`, a URL with user info, a port other than 443. Text over 2048 UTF-8 bytes (trimmed) is
  not read at all in the search field: see Privacy (R95.1-3).

**Host allowlist** (https, default port, no user info; the same rule on every hop of a
short link):
- Google: `google.com`, `google.co.xx`, `google.com.xx`, `google.xx`, with or without
  `www.`, path starting `/maps`; `maps.google.*` with any path; short `maps.app.goo.gl`,
  `goo.gl/maps…`, `g.co/kgs…`.
- Apple: `maps.apple.com` (also `maps.apple.com/p/<token>`) and the short `maps.apple`.
- OpenStreetMap: `openstreetmap.org`, `www.openstreetmap.org`, `osm.org`, `www.osm.org`
  (`osm.org/go/…` is the short form).
- `consent.google.com`, `accounts.google.com` and look-alike hosts are not followed.

**Short links.** The row says "Open link"; nothing is requested until the user taps it.
Then: an ephemeral `URLSession` (no cache, cookies or credentials), 8 s timeout, `HEAD`
first and one `GET` fallback on 400, 403, 405 or 501, at most 5 redirects, every hop
https and allowlisted. The request is cancelled when the final headers arrive and the
body is never read. `RequestPacer` pacing and failure rules apply (429 backs off as
throttled; offline or timeout gives the usual offline message). A stopped hop, a 404, a
final URL with no point, or another short link ends with "This link has no point. Paste
the full link or the coordinates instead." **A consent or sign-in redirect to a host that
is not on the allowlist (for example an EU consent page) is not followed and ends with
this "no point in this link" message.**

**Privacy.** Coordinates and links that the gate recognises are never sent to the MapKit
search completer; they go nowhere until a route is requested from Apple (`MKDirections`
with the point). Plus codes (Open Location Code) are searched like an address, so they go
to the completer as typed (user decision 2026-11-24; local decoding is `ROUTE-PLUSCODE`,
BACKLOG). Decimal coordinates and map links that the gate recognises are never sent to the completer. The
privacy texts promise only what the gate recognises. Opening a short link sends one request chain to that link's host or hosts (for
example Google): that host sees the request and the device IP address. No reverse
geocoding. The empty search state has the system `PasteButton`, so iOS shows no
pasteboard prompt. Text held back from the place search (never sent to the completer, no
completions): text of only coordinate characters with a fraction or a mark; free text
embedding a decimal pair; any text with a digit followed by a degree, minute or second
mark; any decimal with 2 or more fraction digits; and, since round 3 (R94.3-1), text with
any of the angle marks `° º ′ ″ ' " ˚ ‘ ’ “ ” ´ ʹ ʺ` after a digit, text made only of
coordinate characters with an N/S/E/W letter and 3 or more numbers (unmarked DMS), and
text with a lat/lon label followed by a number (`lat`, `lon`, `lng`, `latitude`,
`longitude`, `широта`, `довгота`). Fractions up to 20 digits are read (full-precision
doubles; R94.3-2). Text over 2048 UTF-8 bytes (trimmed; one byte-based check, `CoordinateParser.isOverlong`) is
never parsed, never resolved and never sent to the completer, whatever it holds after the cap: the
field shows "nothing found" and no request is made (typed, pasted, re-sent or retried; R95.1-3).
Text at exactly 2048 bytes is handled as before. Held-back text that is not a recognised
point shows nothing (no row, no message); DMS is not read as a point (R94.2-5, BACKLOG).
Accepted side effect: dotted dates, "Price 1,500" and dotted phone numbers are not
searched. Texts: About → "Data and services", the site privacy pages (en, uk),
`docs/APP_STORE_METADATA.md` (point 12).

**Last leg.** Apple can end a route short of the destination (no roads there). After a
route is built or rebuilt, the straight distance from the route's last point to the
destination is measured (`LastLeg.thresholdM` = 50 m, one constant). At or below it
nothing changes. Above it:
- A dashed straight leg is drawn from the route end to the destination pin, for every
  alternative that has one (the chosen route at full strength, the others muted; the
  active route while guiding).
- The alternatives card says "Route ends N m before the destination" for each such route.
- The leg is drawn whenever the active route is drawn, including while a rebuild waits
  for an origin.
- The manoeuvre bar has four states. Before the last manoeuvre: normal guidance. After
  the last manoeuvre on a route with a last leg: the glyph is `arrow.up.forward`, the text
  is "Route ends N m before the destination" (N is the fixed gap) and the big number is
  the straight-line distance to the destination (it can be below the gap when the
  destination lies beside the route; R94.3-6, BACKLOG). On the leg: the
  same, counting down, and the remaining-time line is hidden. With a gap of 50 m or less:
  Apple's arrive step as before.
- On-last-leg rule: within 150 m (the away margin) of the straight segment route end to
  destination, and the route end has been reached (within 30 m along the route; a sticky
  flag). The "Away from the route" guard is checked after this rule, so more than 150 m
  beside the leg is still away. The flag resets when the car is back on the route more
  than 150 m from its end.

**Arrival.** For a route with a last leg: stopped (below 1 m/s for 3 s, unchanged) within
50 m of the destination point, straight line. Reaching the route end alone never clears
the route. With a gap of 50 m or less, arrival is unchanged (remaining below 50 m along
the route and stopped).

**The row.** The `route` row carries the optional `destination` (`latitude`, `longitude`,
`source` `search`, `pin`, `coordinates`, `link`, `saved`, `recent`) so a recording can be
replayed with the leg; `docs/LOG_FORMAT.md` "`route`, `routeCleared`". No version bump.

## No speed source (prompt 53d)

Done in code on branch `r2-no-speed` (cut from `routing`); device checks in
`docs/PLAN.md` §6 "Added by prompt 53d". Code: `App/Sources/UI/Map/NoSpeedSourceRule.swift`
(pure, injected clock). Without a speed the engine does not move the position, and the
ellipse can stay small while the car drives on, so "Finding your position… · keep
driving" would be wrong advice. The app says so instead.

**Scope.** Only while a Navigate or Record run is active and the engine has an estimate.
With Navigate idle nothing new is shown, with or without an adapter.

**Speed source.** The speed chip's own rule, `MapSpeedRule.resolve`: a fresh OBD reply
(at most 2 s old) or a fix at most 2 s old with a valid speed. A fix counts only while the
driver's GPS switch (the session's switch) is on: location rows keep being recorded while
it is off, but they are not a speed source for this rule, and the speed chip drops the fix
the same way. The guidance probe reads the session's switch, so it works with the map
hidden or the phone locked. Network fixes and GPS off give none.

**The state.** No speed source for more than 5 s (`NoSpeedSourceRule.thresholdS`, strict
`>`) and the car not shown standing. Standing is the engine's own
`NavigationEstimate.stationary`: a fresh OBD 0 (a zero-velocity update), or OBD stale
after an OBD 0 while the engine's IMU motion check has not cleared the parked latch. No
new motion detector. Ignition off (the Navigate auto-stop) ends the run, so the state
ends with it.

**Where it shows.**
- When `PositionStatus.isFinding` is true, the HUD status line says "No speed source —
  position not updating" (speedometer symbol) instead of "Finding your position… · keep
  driving" for as long as the state lasts. Driving on finds nothing without a speed
  source (user decision 2026-11-24); the "Connect OBD…" banner says what to do.
- The place card origin check (origin rule (b)) offers "I'm here" first.
- The guidance manoeuvre bar shows the reason in place of the distance, in the uncertain
  (warn) styling; remaining distance and time are hidden.
- Arrival cannot fire in the state (the remaining distance is nil).
- No banner and no sound.

**Clearing.** On the first fresh speed source, with no hysteresis. The estimate is not
reset.

**Does not trigger:** a fuel stop with the engine off, a red light with OBD answering 0,
reconnect gaps while standing. **Triggers:** the adapter unplugged or never connected,
GPS off or only network fixes, the car moving. This includes the 2026-11-02 case (OBD
lost at a stop with the last reply 0, then moving on network fixes): the state starts
within 5 s once the motion check clears `stationary`.

The engine, `NavigationConfig`, the sidecar and the log format are unchanged; the
`replay_nav` acceptance matrix is unchanged (hash proof).
