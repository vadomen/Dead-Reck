# N3 plan: OSM roads and map matching

**Plan. All open questions answered 2026-10-11; see "Decisions". N3.0 done
(2026-10-12) except R11.1-6, which failed the adoption rule and stays open; its exit
table, the baseline N3.2 is judged against, is "N3.0 exit" in docs/NAVIGATION.md.** Model, config, replay and adoption rule: `docs/NAVIGATION.md`.
Roadmap: `WORKFLOW.md`, "Navigator roadmap". Owner: `navigation-engineer`, plus
`ios-ui-engineer` for the N3.4 display. No logger, sensor or log-format change.

## Context

N2 and N4 deliver a causal, deterministic particle filter (heading and speed scale
sampled, position Gaussian per particle) that runs live in the app. Its weak spot is
absolute information when GNSS is jammed. Before a pin, and between pins, the only
evidence is tower fixes: roughly 1 km, correlated over minutes. That is why heading on
the manual drive converges only after 7.27 km. N3 adds the road network as a soft
measurement. A car drives on roads, along them, and only one way on a oneway.

### Ground rules
- **The engine uses only our own road graph, built from OpenStreetMap.**
- **MapKit is display only**: the base map, the DR dot and the ellipse. It is never a data
  source for navigation: no `MKDirections`, `MKLocalSearch`, `MKMapItem` or `MKRoute` output
  reaches the engine. N3.4 adds a repository invariant test for that (see N3.4).
- Switching the display to MapLibre or OSM tiles is **out of scope**. **Known display
  limitation:** Apple's road geometry is not OSM's. A dot matched to an OSM centreline can
  sit a few metres beside Apple's road, or on a road Apple draws differently or not at all.
  N3.4 measures it on the debug overlay and documents it. N3 does not fix it.
- Roads are a **soft** measurement in the existing Rao-Blackwellised filter, never a hard
  snap. Car parks, roads missing from OSM and forks must not break the estimate.
- Causal and deterministic as today. Same log + same seed + same config + same road pack →
  bit-identical output. The road pack is prior knowledge, not drive data, so using it is
  causal. Anything that matches a whole drive at once (the road truth below) lives in replay
  tooling and is labelled offline.
- The log format and `LogFormatVersion` stay unchanged, and `LogFormatCompatibilityTests` is
  untouched. Sidecar changes go through `NavSidecar.version` (docs/NAV_SIDECAR.md).
- OSM extracts and built packs are **never committed**. They go in the git-ignored `osm/`
  directory (N3.1 adds `osm/`, `*.osm.pbf` and `*.roadpack` to `.gitignore`). Pack names,
  admin relation IDs and the extracts reveal where the user drives. Committed docs, tests
  and fixtures use synthetic graphs near (0, 0) and aliases only.
- "© OpenStreetMap contributors" (ODbL 1.0) appears wherever roads are used or shown: in the
  app, in every pack's `META`, in `build_roads --info` and in the replay summary when
  `--roads` is given.

## Where we start (measured)

Reference: the N4-B1 table in docs/NAVIGATION.md, now docs/archive/NAVIGATION-history.md (seeds 1–5, arrival order, release, Mac,
default config). Local re-runs after R14.4 (`logs/r144`, seeds 1–5) agree with it.
b64b4a4 and later commits changed App code and tests only.

| alias | run | distance | criterion | mean (range) [inside 95 %] | heading converged at | ms/step |
|---|---|---:|---|---|---:|---:|
| clean-long | mask-after 380 | 7.75 km | max ≤ 30 m | 18.90 m (18.19–20.20) [100 %] | 0.02 km | 0.060 |
| clean | mask-after 230 | 3.58 km | max ≤ 30 m | 13.94 m (12.25–16.89) [100 %] | 0.03–0.04 km | 0.058 |
| manual | use, hold-out 100 | 8.31 km | truth point 1 ≤ 200 m | 50.57 m (47.43–57.42) [100 %] | **7.27–7.68 km (known FAIL vs 2 km)** | 0.063 |
| jammed-A | use | 11.23 km | end ≤ 2.5 % | 1.147 % (1.02–1.26) [100 %] | 8.15 km | 0.065 |
| jammed-B | use | 5.89 km | end ≤ 2.5 % | 1.068 % (0.93–1.39) [100 %] | 5.18–5.31 km | 0.061 |
| manual-3 (sanity) | use | 12.05 km | reported | pins 103–104 / 458–473 / 128–131 m [2/3] | 1.72 km | 0.065 |

- **Timing.** The `logs/r144` runs give 0.068–0.079 ms/step. The largest single `ingest`
  is 0.25–1.46 ms, plus one 4.47 ms outlier on manual-3. The road update has to fit next to
  this.
- **Pins in the replay set** (recorded fields, read with `jq`; no positions):

| drive | pin | `speedSource` | `gateSpeedKmh` | OBD age at tap | `mapSpanM` → σ | `t − pressedT` (old long-press flow) |
|---|---|---|---:|---:|---|---:|
| manual | 1 | obd | 0 | 0.08 s | 500 m → 42 m | 4.58 s |
| manual-3 | 1 | obd | 8 | 0.01 s | 1248 m → 104 m | 6.69 s |
| manual-3 | 2 | obd | 4 | 0.00 s | 364 m → 30 m | 1.22 s |
| manual-3 | 3 | obd | 8 | 0.03 s | 368 m → 31 m | 0.93 s |

  - Every pin in the set predates the double tap and is at 0–8 km/h. A speed-dependent
    pin σ therefore barely changes this set (see "Manual fixes").
  - The ~100 m uncertainty of manual-3's pins 2–3 is not explained by their recorded
    speed: 1–2 m at 4–8 km/h.
- **Tools.** At planning time neither osmium-tool nor pyosmium was installed on this Mac.
  osmium-tool 1.19.1 was installed for N3.1.

## Design

### Data flow
```
<country>-latest.osm.pbf (Geofabrik) ──osmium──▶ OPL with node locations ──build_roads──▶ *.roadpack (osm/packs/)
*.roadpack ──RoadPack (mmap, Foundation)──▶ RoadNetwork ──▶ NavigationEngine(config:roads:) ──▶ estimate, sidecar, replay
```

### Road model in the filter

Particle i carries a position mean μᵢ = (e, n) and covariance Pᵢ in the engine's
`LocalTangentPlane`, plus a heading ψᵢ (clockwise from north) and a scale. N3 adds three
per-particle values (SoA, about 13 B × N):
- `roadEdge[i]`: UInt32, none = max;
- `roadLevel[i]`: Int8, unknown = min;
- `offRoadM[i]`: Double.

Resampling copies them. A clean-fix reseed and a manual reset set them to none, unknown
and 0.

**When.** At the end of a moving grid step (not ZUPT or parked; fresh or stale OBD alike,
because roads help most during an OBD dropout), once at least `roadUpdateIntervalS` of grid
time has passed since the last road update. Never inside a catch-up macro step. Engaged only
if the cloud's 95 % semi-major axis is ≤ `roadEngageMaxEllipseM`: a tower-sized cloud has
too few particles per road corridor to be matched honestly.

**Distance tempering.** Δs is the sum of `lastMeanSpeed` × dt over the steps since the last
road update. The weight of a road update is

  w = min(1, Δs / `roadCorrelationM`).

- OSM centreline errors and the car's lane offset are correlated along the road, so the
  evidence scales with distance, not with time or update rate. This mirrors the
  network-fix tempering.
- It makes runs at different update rates comparable.
- At a light Δs = 0, so nothing is counted twice.

**Step 0: is there any road?** Using the unsplit means μᵢ, look up each particle's grid
cell. If no particle has any candidate segment, the update is skipped: no RNG draw, counter
`roadUpdatesNoRoad`. A car park or an area outside the pack is then exactly a no-op.

**Step 1: split wide Gaussians.** For each particle with λmax(Pᵢ) > σs²
(σs = `roadSplitSigmaM`):
- eigendecompose Pᵢ = V diag(λ₁, λ₂) Vᵀ;
- draw one `nextGaussianPair()` (z₁, z₂), always both values, so RNG use is fixed;
- for each axis with λⱼ > σs²: μᵢ += Vⱼ √(λⱼ − σs²) zⱼ and λⱼ ← σs².

The mixture over particles keeps the same distribution, but each particle now stands for a
place narrow enough to be on one road. Counter `roadSplits`.

Why it is needed: on jammed drives most of the position spread sits inside each particle's
Pᵢ (hundreds of metres), not across particle means. "The nearest road to μᵢ" would then mean
nothing. This partly gives up the Rao-Blackwellisation that N2 chose (see Risks, R3).

**Step 2: candidates.** These are the segments in the particle's cell (one lookup; see the
grid). A segment is eligible when:
- **Level rule** (below) passes.
- **Heading:** |Δψ| ≤ `roadHeadingGateDeg`. For a two-way edge, Δψ = wrapPi(ψᵢ − β) or
  wrapPi(ψᵢ − β − π), whichever is smaller. For a oneway edge, only the forward bearing β
  counts. The builder stores every oneway in its driving direction.
- **Geometry:** let Q be the point of the segment nearest to μᵢ (projection clamped to the
  segment) and d = |μᵢ − Q|. The unit vector h is the segment's normal pointing to μᵢ when
  the projection is interior, and (μᵢ − Q)/d at an end vertex. The vertex case handles bends
  and dead ends without overhang rules. With P_cc = hᵀPᵢh and S₀ = P_cc + σr²
  (σr = `roadSigmaM`), eligibility needs d ≤ `roadSearchRadiusM` and d²/S₀ ≤
  `roadInnovationGateChi2`.

For each eligible segment:

  L_road = exp(−d²/2S₀)/√(2πS₀) · exp(−Δψ²/2σψ²)/(√(2π)σψ),  σψ = `roadHeadingSigmaDeg`.

The particle takes e* = argmax L_road, so at equal headings this is the nearest segment.
Ties go to the lower segment key. One edge per particle per update. Forks are handled by
different particles taking different edges. No branch is ever forced, and there is no
transition model between edges.

**Step 3: mixture and weight.** The model: with probability 1 − ε (ε =
`roadOffRoadProbability`) the car is on a mapped road, and its cross-track offset and
heading offset are as in L_road. Otherwise it is anywhere within ±R of the road at any
heading: L_off = 1/(2R) · 1/(2π), with R = `roadSearchRadiusM`. Both are densities per metre
per radian.

  pᵢ = (1 − ε) L_road(e*) + ε L_off   (pᵢ = ε L_off when the particle has no candidate)
  rᵢ = (1 − ε) L_road(e*) / pᵢ        (responsibility: "this particle is on e*")
  log wᵢ += w · log pᵢ                (power tempering)

The weight uses the untempered S₀. Tempering by R/w inside L_road would make the on-road
density at small w lower than L_off, and off-road particles would win. Power tempering keeps
the ranking and scales the evidence.

**Step 4: cross-track update, with nothing changed along the road (default).** Work in the
road frame: c along h (across the road) and a ⊥ h (along it). The measurement is "cross-track
offset = 0" with noise R_w = σr²/w and innovation y = −d. With S_w = P_cc + R_w and
g = P_cc/S_w:
- **`roadAlongTrackCoupling` = 0** (Schmidt / consider update, the brief's "nothing along the
  road"): the gain is zero along the road. Δμ = g·y·h. The covariance follows the Joseph form
  with that gain, which is valid for any gain and so stays consistent:
  - P′_aa = P_aa
  - P′_ac = P_ac (1 − g)
  - P′_cc = P_cc R_w/S_w
- **`roadAlongTrackCoupling` = 1** (exact Kalman): K = Pᵢh/S_w, Δμ = K y and
  P_upd = Pᵢ − (Pᵢh)(Pᵢh)ᵀ/S_w. Along-track changes only through the along/cross correlation,
  which is small because each particle's process noise is aligned with its own heading and
  the heading gate keeps that near the road. Measured as an alternative in N3.2.

Moment-matched with the off-road branch, so the particle remains one Gaussian with no extra
draw:

  μᵢ ← μᵢ + rᵢ Δμ
  Pᵢ ← rᵢ P_upd + (1 − rᵢ) Pᵢ + rᵢ(1 − rᵢ) Δμ Δμᵀ

Heading is not updated directly. It is informed through the weights, plus the existing
resampling jitter. Then `normalizeWeights()` and `resampleIfNeeded()`.
- `motionEast/North` (the late-pin ring) are prediction-only and not touched, as for fixes.
- On a re-anchor, the matcher's cell cache is cleared. Edge state is plane-independent.

**Step 5: bookkeeping.**
- rᵢ ≥ 0.5: `roadEdge[i]` = e*, `roadLevel[i]` = level(e*), `offRoadM[i]` = 0.
- Otherwise `offRoadM[i]` += Δs, and beyond `roadLevelForgetM` the level becomes unknown.
- The engine keeps the following from this update for the estimate (below):
  - `onRoadShare` = Σ wᵢ rᵢ with the posterior weights;
  - `matchedEdge`, the e* with the largest Σ wᵢ rᵢ.

**Layer, bridge and tunnel rule.** The builder computes level(e):
- the `layer` tag (clamped to −5…5) when present;
- otherwise +1 for `bridge=*` (not `no`), −1 for `tunnel=*` (not `no`, including
  `building_passage`);
- otherwise 0.

The `bridge` and `tunnel` flags are kept too. A candidate e is eligible for particle i when
any of these holds:
1. `roadLevel[i]` is unknown;
2. level(e) = `roadLevel[i]`;
3. e is within `roadLevelHops` hops of `roadEdge[i]` in the pack's adjacency.

Rule 3 is how a car gets onto a bridge or into a tunnel: the ramp or approach shares a node
with it. So a particle on the street below a stacked viaduct cannot be captured by the
viaduct even when heading and distance agree, and vice versa. Hops are checked only when the
levels differ (rare). Counter `roadLevelBlocked`. Across packs there is no adjacency, so only
rules 1–2 apply at a pack border.

**GPS fix gate** (in addition to the existing GNSS-vs-OBD speed gate, which vetoes course and
speed only). A fix with a valid speed (GNSS, not a network fix) is ignored as a whole when
all of these hold:
- roads are loaded and the fix lies inside a pack's coverage;
- fresh OBD speed ≥ `roadFixGateMinKmh`;
- the last road update's `onRoadShare` ≥ `roadFixGateOnRoadShare`;
- no segment of any level lies within G = max(`roadFixGateMinM`, `roadFixGateSigma` · σ_fix)
  of the latency-shifted fix. The segment must be heading-compatible with the fix's course
  when the course is valid.

Counter `fixesRejectedOffRoad`. A multi-cell query is used, because G can exceed the pack
radius. `roadFixGateSigma` 0 disables the gate.
- **Deliberate interpretation of "incompatible with every road near the estimate":**
  compatibility is judged **at the fix**, not against the roads near the estimate. A fix on
  another road 2 km from a wrong estimate must be accepted, or the filter confirms its own
  error. Decided: judged at the fix (Q4).
- Network fixes (σ ~ 900 m) are never gated.

**Pins as road anchors.** A manual fix with `gateSpeedKmh` ≥ `roadPinAnchorMinKmh` (the car
was moving, so it was on a road) triggers a road update right after the pin is ingested,
regardless of the interval (counter `roadPinAnchors`). The pin then gives position along the
road and the road gives position across it. A stationary pin (possibly in a car park) gets no
forced road update.

### Config keys (new; `NavigationConfig`, all numeric so `--set` reaches them)

| key | proposed default | meaning |
|---|---:|---|
| roadUpdateIntervalS | 1.0 | grid time between road updates; 0 disables road updates even with a pack loaded |
| roadSigmaM | 7.0 | cross-track σ: lane offset plus OSM error (brief: 5–10 m). Calibrated from clean-drive residuals in N3.2 |
| roadHeadingSigmaDeg | 10 | heading agreement σ |
| roadHeadingGateDeg | 45 | heading compatibility gate (oneway: forward only) |
| roadSearchRadiusM | 50 | candidate radius; validation clamps it to the pack's guaranteed radius |
| roadInnovationGateChi2 | 9 | cross-track gate d²/S₀ (1 dof, 99.7 %) |
| roadOffRoadProbability | 0.1 | ε, the off-road share of the mixture |
| roadCorrelationM | 30 | distance tempering length |
| roadSplitSigmaM | 15 | wider particle Gaussians are split before matching |
| roadEngageMaxEllipseM | 1000 | no road update while the cloud's 95 % semi-major axis is above this |
| roadAlongTrackCoupling | 0 | 0 = Schmidt (along-track unchanged), 1 = exact Kalman |
| roadLevelHops | 2 | adjacency hops allowed for a level change |
| roadLevelForgetM | 100 | off-road distance after which a particle's level becomes unknown |
| roadFixGateSigma / roadFixGateMinM | 3 / 50 | GNSS fix gate radius = max(min, k · σ_fix); k = 0 disables |
| roadFixGateMinKmh / roadFixGateOnRoadShare | 20 / 0.8 | the gate applies only while moving this fast with the cloud this much on-road |
| roadPinAnchorMinKmh | 3 | a pin at or above this speed triggers an immediate road update; 0 disables |
| manualFixReactionS | 1.0 (N3.0) | pin σ grows by v × (this + max(0, t − pressedT)); 0 restores today's σ |
| manualFixUnknownSpeedMps | 10 (N3.0) | v for a pin with `speedSource` `unknown` |

`NavigationConfig.validated()` clamps:
- `roadUpdateIntervalS` to 0 or ≥ 1/`stepHz`;
- probabilities to (0, 1);
- σ, gates and radii to > 0.

The new keys change `configHash` for every run, with or without roads. Old sidecars then show
the existing config-mismatch warning with the new keys listed. Their estimates stay
identical.

**Counters** (`NavigationCounters`): `roadUpdates`, `roadUpdatesNoRoad`, `roadSplits`,
`roadCandidateTests` (deterministic work measure), `roadLevelBlocked`,
`fixesRejectedOffRoad`, `roadPinAnchors`.

**Estimate** (`NavigationEstimate`): `onRoadShare` and `matchedEdge` (pack index, edge,
OSM way ID), from the last road update. Both are nil without roads.

### Determinism, causality, reproducibility
- All road arithmetic is in Double, from E7 integers that convert exactly. Particles and
  candidates are iterated in index order. Ties are broken by segment key.
- **No `Dictionary` or `Set` is ever iterated in the engine.** Swift's hashing is seeded per
  process, so iteration order changes from run to run. The cell cache is lookup-only, and
  its contents are a pure function of (plane, cell). So eviction and cache size cannot change
  results; a test runs cache size 1 against the default.
- RNG draws happen only in Step 1. Without a pack, or with `roadUpdateIntervalS` 0, no road
  code runs: the N3.0 bit-identity gate.
- Every replay result records:
  - the seed and config;
  - **`roads`**: per pack, `contentHash`, `formatVersion`, OSM timestamp and grid ID;
  - `roadSetHash`: FNV-1a 64 over the packs' content hashes in ascending order (N3.2c
    item 7: the set, not the order given).

  These go into `metrics.json` (optional field, so older files decode), `metrics.md`, the
  summary and the GeoJSON properties. The mode label gets `-roads-<first 8 hex of
  roadSetHash>`, so runs with and without roads never overwrite each other's row.
- **A new pack build is an engine input change**: it is judged with the adoption rule like
  a config change. A drive is always replayed with a named pack hash.
- Causality tests are extended to roads: a prefix gives the same estimate, and garbage after
  T leaves estimates up to T unchanged.

### Performance
- **Budget** (docs/PLAN.md §6, N4 B item 1): ≤ 2 ms per 10 Hz step on the iPhone with 2000
  particles. The reference device is the **iPhone 16 Pro Max** (Q10). The binding case is
  the step that carries a road update, not the mean over steps.
- **Mac proxies** (release `replay_nav`, 2000 particles, the replay set):
  - road-update step ≤ 0.5 ms (p99 and maximum);
  - mean ≤ 0.15 ms/step (today 0.058–0.079).
- The iPhone 16 Pro Max / Mac speed ratio for this code is unknown and is measured in N3.3
  (Q10); the Mac proxies are recalibrated from it.
- **Cost model:**
  - per particle: one geodetic → grid conversion, one cell lookup, and about 20–40
    candidates;
  - the heading test (dot product with a precomputed sin/cos of ψᵢ) runs before the distance
    test, and squared distances are compared first;
  - one 1-D update;
  - target ≤ 150 ns per particle on the Mac.
- **Cell cache:** per update, the distinct cells under the cloud are converted once to plane
  segments (SoA: start point, unit vector, length, bearing, edge, flags, level). A dense
  window over the cloud's cell bounding box (≤ 128 × 128 cells, otherwise binary search per
  particle) avoids hashing in the hot loop.
- **Fallbacks, in order, if the device misses the budget:**
  1. a narrower window;
  2. staggered updates (1/k of the particles per step; changes the model, needs replay);
  3. fewer particles.
- **Memory:** packs are memory-mapped (`Data(contentsOf:options: .alwaysMapped)`). Road state
  is about 26 KB at 2000 particles, and the cell cache is bounded (4096 cells).

## Road pack format v1 (`docs/ROAD_PACK.md`, written in N3.1)

A binary file `*.roadpack`, versioned independently of the log and the sidecar.
- **Byte order:** integers little-endian, read with explicit `littleEndian` conversion, so
  the format does not depend on the host. Floats are IEEE-754 binary64, little-endian.
- **Layout:** sections are 8-byte aligned and zero-padded, so a mapped file is read with
  `loadUnaligned` and no copies.
- **Coordinates:** E7 fixed-point degrees (Int32, about 1.1 cm), as OSM stores them: exact
  integers, the same on every platform.

**Header (96 bytes):**

| offset | type | field |
|---:|---|---|
| 0 | 8 × UInt8 | magic `DLRPACK\0` |
| 8 | UInt16 | `formatVersion` = 1 |
| 10 | UInt16 | `headerSize` = 96 |
| 12 | UInt32 | flags (bit 0: `COVR` present) |
| 16 | UInt64 | `contentHash` |
| 24 | UInt64 | `fileSize` |
| 32 | UInt64 | `sectionTableOffset` |
| 40 | UInt32 | `sectionCount` |
| 44 | UInt32 | reserved, 0 |
| 48 | Int64 | `osmTimestamp`: Unix seconds UTC of the source extract (its replication timestamp); 0 = unknown |
| 56 | Int32, Int32 | grid origin `latE7`, `lonE7` |
| 64 | Float64 | grid metres per E7 unit of latitude |
| 72 | Float64 | grid metres per E7 unit of longitude |
| 80 | Float64 | `cellSizeM` |
| 88 | Float64 | `searchRadiusM`: the guaranteed radius in true metres |

**Section table:** `sectionCount` × 24 bytes: tag (4 ASCII bytes), flags UInt32, offset
UInt64, length UInt64. Entries are sorted by offset, non-overlapping and inside the file.

| tag | records | content |
|---|---|---|
| `META` | UTF-8 JSON, sorted keys | builder name and version (git commit), parameters (highway classes, cell size, radius, osmium extract strategy), source file name, SHA-256 and OSM timestamp (ISO 8601), coverage (admin level, relation ID), `attribution` "© OpenStreetMap contributors", `license` "ODbL 1.0" |
| `NODE` | n × {latE7 Int32, lonE7 Int32} | topological nodes: junctions (shared by ≥ 2 ways) and way ends |
| `EDGE` | m × 40 B | from UInt32, to UInt32, firstPoint UInt32, pointCount UInt32, osmWayID Int64, wayPointOffset UInt32, lengthDm UInt32, highwayClass UInt8, level Int8, flags UInt8 (oneway, bridge, tunnel, roundabout, link, oneway-implied), lanes UInt8 (0 unknown), reserved UInt32 |
| `PNTS` | p × {latE7, lonE7} | shape points. Each edge's points are contiguous, both end nodes included; segment s = (s, s + 1) inside one edge |
| `PTED` | p × UInt32 | the edge of each point |
| `ADJO`, `ADJE` | (n + 1) × UInt32, then UInt32 | CSR adjacency: the edges incident to each node, sorted |
| `CELK` | c × UInt64 | non-empty cell keys (cy << 32 \| cx), strictly ascending |
| `CELO`, `CELS` | (c + 1) × UInt32, then UInt32 | CSR: segment start-point IDs per cell, ascending |
| `COVR` | optional | coverage polygon: ring count, then per ring a point count and E7 points (even-odd rule). Without it, coverage = the bounding box |

- **Hash:** `contentHash` = FNV-1a 64 (`NavigationSeed.fnv1a64`, as for `configHash`) over
  the whole file with bytes 16–23 read as zero. It covers the header's grid parameters, which
  change behaviour.
  - It is an identity hash, not a security measure. The SHA-256 of the *source* extract is
    in `META`.
  - Verification is O(file size) and runs once at open in replay, and once at import in the
    app (result cached by hash, size and modification time).
  - Structure checks run on every open: magic, version, sizes, section bounds, and record
    counts against lengths. Full index-range and ordering checks run in `verify()`.
- **Grid:** a uniform grid in a pack-family frame:
  - x = (lonE7 − originLon) · kLon, y = (latE7 − originLat) · kLat, with k at the family's
    centre latitude; cell = (⌊x/cell⌋, ⌊y/cell⌋);
  - a segment is listed in every cell whose rectangle lies within R_eff of it, where
    R_eff = `searchRadiusM` × (1 + the frame's largest scale error over the bounding box);
  - a query is therefore one lookup per particle;
  - all packs from one build run share the grid (grid ID = FNV-1a of header bytes 56–95), so
    a cell means the same area in each, and the cache merges a cell's candidates across packs;
  - packs with different grid IDs are refused together.
  - **Cell size 64 m, radius 50 m:**
    - Cells ≥ 2R would allow a 2 × 2 query. Baking R into the index instead makes it one
      lookup.
    - At 64 m a lookup returns the segments within 50 m of a 64 × 64 m cell, about 3.4× the
      query disc's area. That is a few tens of segments in a dense city.
    - 128 m would be about 7× the disc area, roughly twice the candidates per particle. 32 m
      roughly doubles the duplication per segment.
    - N3.1 measured 32 / 64 / 128 m on the densest pack: candidates per lookup (p50, p95,
      max), index size and query time. **64 m stays the default** (see the N3.1 result).
  - **R-tree rejected:**
    - The queries are fixed-radius around a compact cloud, which suits a grid.
    - An R-tree means pointer-chasing and branchy log-n queries.
    - It is harder to memory-map and to keep bit-stable across builder versions.
- **Duplicates across packs:** each segment's key is (osmWayID, wayPointOffset + k). It
  is the same in every pack because extracts use `--strategy complete_ways`. The first
  pack in canonical order (ascending content hash; N3.2c item 7) wins.
- **Versioning:**
  - A reader refuses a newer `formatVersion`.
  - Unknown section tags are skipped, so an optional section needs no version bump.
  - Changing a record layout needs a new version. A reader keeps every version it ever read.
  - The builder is deterministic: same OPL + same builder version + same parameters →
    the same bytes.

## Builder pipeline (Mac only)

**Design choice:** osmium-tool does all PBF handling and writes OPL with node locations on
each way. A Swift builder (Foundation only) reads the OPL and writes the pack. pyosmium is
not needed. Writer and reader then share one Swift implementation of the format and its
hash, round-trip tests run in `swift test`, and the only external tool is
`brew install osmium-tool`.

```bash
# osm/ is git-ignored; packs.json (the list of admin relation IDs) lives there too.
# Verified in N3.1 (osmium-tool 1.19.1); docs/ROAD_PACK.md "Pipeline" has the full block.
osmium fileinfo -g header.option.osmosis_replication_timestamp osm/src/<country>-latest.osm.pbf   # ISO 8601
osmium fileinfo -g header.boxes osm/src/<country>-latest.osm.pbf                                 # family grid box
osmium tags-filter -O osm/src/<country>-latest.osm.pbf w/highway=<classes> -o osm/work/roads.osm.pbf
osmium tags-filter -O osm/src/<country>-latest.osm.pbf r/boundary=administrative -o osm/work/admin.osm.pbf
osmium getid -O -r -t osm/work/admin.osm.pbf r<relationID> -o osm/work/boundary-<pack>.osm.pbf   # admin_level 4 or 6
osmium export -O osm/work/boundary-<pack>.osm.pbf --geometry-types=polygon -a type,id \
  -f geojsonseq -x print_record_separator=false -o osm/work/boundary-<pack>.geojsonseq
jq -c 'select(.properties."@type" == "relation" and .properties."@id" == <relationID>)
  | {type: "Feature", properties: {}, geometry}' osm/work/boundary-<pack>.geojsonseq > osm/work/boundary-<pack>.geojson
osmium extract -O -c osm/work/extracts.json -d osm/work --strategy complete_ways osm/work/roads.osm.pbf  # all regions, one pass
osmium add-locations-to-ways -O osm/work/<pack>.osm.pbf -f opl -o osm/work/<pack>.opl
cd Core && swift run -c release build_roads ../osm/work/<pack>.opl --classes region --grid-bbox <box> \
  --osm-timestamp <ts> --source-sha256 <hex> --osmium-version <v> --strategy complete_ways \
  --coverage ../osm/work/boundary-<pack>.geojson --relation-id <relationID> --admin-level 4 \
  --out ../osm/packs/<pack>.roadpack
swift run -c release build_roads --info ../osm/packs/<pack>.roadpack --bench 100000   # header, counts, hash check, cell statistics
```

Verified in N3.1. The first draft of this block had four problems, all fixed above:
1. `getid -r` alone also returns the relation's `subarea` relations with their tags,
   and `osmium extract` merged them into one overlapping polygon: 970 instead of
   55 278 ways on region-A. `-t` and the single-relation GeoJSON fix that.
2. `osmium extract -c` writes its outputs relative to the current directory unless
   `-d` or `"directory"` is given.
3. The extract output has neither the source's bounding box nor its timestamp, so
   both are read from the source.
4. `-O` is needed on re-runs.

The national pack is not cut. It is `tags-filter` on `roads.osm.pbf` with the national
classes, and the country relation serves as its coverage.
- **Script:** `tools/roads/build_packs.sh` (outside Core) runs the osmium steps from
  `osm/packs.json` and records the osmium version, the source's SHA-256 and replication
  timestamp, and the builder commit in `META` (the last commit touching the builder's
  files, docs/ROAD_PACK.md "Hash"). A run is deterministic: a second run gives
  byte-identical packs.
- **Packs:**
  - **National highways:** `motorway`, `trunk`, `primary` and their `_link`s, for driving
    between regions.
  - **Region packs** cut by admin boundaries, `admin_level` 4 and 6, with every drivable
    class:
    - motorway … tertiary and links;
    - `unclassified`, `residential`, `living_street`, `service`, `road`.

    Excluded: `footway`, `cycleway`, `path`, `pedestrian`, `steps`, `bridleway`,
    `construction`, `proposed`, `platform`, `raceway`, `bus_guideway`, and `area=yes`. Also
    excluded: `track` and `service=parking_aisle`; car parks are left to the off-road
    component. `access=private` is kept, because gated residential and works roads are
    driven (Q5).
- **Normalisation:**
  - `oneway=-1` → reversed geometry, forward-only;
  - `motorway`, `motorway_link` and `junction=roundabout` imply oneway unless `oneway=no`;
  - `oneway=reversible|alternating` → two-way;
  - ways are split at topological nodes into edges.

## Manual fixes and speed (N4MF-1 folded in, judged on replay)

Since the double tap, a pin can be placed at any speed. Its row records `obdSpeedKmh`,
`obdSpeedT`, `gpsSpeedKmh`, `speedSource` (`obd`/`gps`/`unknown`, `ManualFixGate`) and
`gateSpeedKmh`. Use them in three places.

**1. σ in the engine (N3.0):**

  σ_pin² = max(`manualFixSigmaMinM`, mapSpanM / `manualFixSpanDivisor`)² + (v · (τ + max(0, t − pressedT)))²

- τ = `manualFixReactionS`: the finger marks a spot the car passed about a reaction time
  ago.
- t − pressedT is the confirm delay of the old long-press flow; it is 0 for double-tap rows.
- v = `gateSpeedKmh`/3.6 when `speedSource` is `obd` or `gps`, else
  `manualFixUnknownSpeedMps` = 10 m/s (Q6).
- Old long-press rows keep the t − pressedT allowance (Q6).
- `NavigationConfig.manualFixSigma` gains the sample's speed fields.
- **Expected effect on today's set:**
  - manual is unchanged (v = 0);
  - manual-3's σ goes 104 → 105.4, 30 → 30.1 and 31 → 31.2 m.
  - So it cannot be judged here. It needs a drive with pins at 30–60 km/h (device item D3),
    and the adoption run will show "no measurable change" honestly.

**2. As ground truth (replay):**
- Each pin is classed `stationary` (≤ 1 km/h from `obd` or `gps`), `moving` or `unknown`,
  and scored with the **frozen truth σ** (`NavigationReplay.manualFixTruthSigmaM`,
  max(30 m, mapSpanM / 12); see the constraint below), never with the engine's σ_pin above.
  Item 1 changes only what the engine ingests (σ_pin), not how the pin is scored.
  - **Constraint (R19.1-1):** the pin's *truth* σ for the consistency with the truth's σ is
    frozen in replay code (`NavigationReplay.manualFixTruthSigmaM`, max(30 m, mapSpanM / 12)),
    not the engine's σ_pin, so the engine change above cannot widen its own truth. A
    speed-dependent truth σ would be a change to the metric: decide it separately, as frozen
    constants in replay code, and re-baseline before it gates anything.
- Gated criteria use only stationary pins and truth-file points. Moving and unknown pins are
  reported, like manual-3 today.
- The class goes into `metrics.json` and the pin table.

**3. As a road anchor:**
- A pin at ≥ `roadPinAnchorMinKmh` forces a road update.
- A stationary pin does not, because it may be in a car park.

## Metrics added to replay_nav

- **Road truth (offline, labelled, tools only):**
  - For each withheld clean fix (≤ 15 m with a valid course), find the nearest
    heading-compatible edge (oneway respected) in the same road set. It counts only with a
    likelihood margin ≥ 2:1 over the second-best edge. Otherwise the fix is "ambiguous" and
    excluded, and the excluded share is reported.
  - As built (N3.2b, `NavigationReplay.RoadTruth`): "valid course" means a valid course
    and GNSS speed ≥ 3 m/s (`courseMinSpeedMps`); a stopped or creeping car has none
    ("no usable course", reported). The truth edge must lie within 15 m of the fix; a fix
    with no heading-compatible edge that close is "no road" (unmapped road, car park), not
    on the nearest mapped road. Every heading-compatible edge within 50 m competes for the
    margin. Likelihood: N(d; σ_fix² + 7²) · N(Δψ; σ_course² + 10°²), σ_fix = accuracy /
    2.45, σ_course = max(courseAccuracy, 2°).
  - If more than 20 % are ambiguous, upgrade to a Viterbi match over route distance.
  - It runs only when `--roads` is given and needs clean GNSS that the engine did not
    receive. So it is defined for clean (`mask-after 230`), clean-long (`mask-after 380`)
    and informational `mask-after-motion` runs. It is **n/a on manual, manual-3 and
    jammed-A/B**, which have no clean GNSS and no road-level truth (Q9).
- **Wrong-road share:** at each road-truth fix time, take the engine's `matchedEdge`. It
  scores:
  - **wrong** when it is not the truth edge (after de-duplication by way and point) and the
    truth fix is more than `wrongRoadToleranceM` (20 m, a replay option) from it. The
    tolerance means parallel geometry of one road and junction stubs are not penalised.
  - **off** when `onRoadShare` < 0.5 while the truth is on a road.

  Reported per drive as a share of scored fixes (≈ time at 1 Hz) and of OBD distance (each
  scored fix weighs the OBD distance since the previous fix with a usable course).
  It checks capture onto a wrong *mapped* road only (R21.1-11).
- **Unmapped / captured (R21.1-11, widened in N3.2c item 2):** an "unmapped" truth fix
  is a withheld clean fix with no heading-compatible edge of the loaded packs within
  15 m. Two disjoint cases, reported separately so the R21.1-11 figure stays visible:
  - `noRoadWithin15`: more than 15 m from every edge, any heading (the R21.1-11 rule);
  - `noCompatibleRoadWithin15`: an edge lies within 15 m, but with a usable course none
    within 15 m passes the road truth's course gate (road truth "no road"). This is the
    car-park and service-road case.

  A fix with no usable course keeps the distance-only rule, so the widening never drops
  a fix. Per drive: how many, and for each whether the estimate was **captured**
  (same widened set, same split): on a mapped edge (`onRoadShare` ≥ 0.5
  with a `matchedEdge`) with the 95 % ellipse's half-width across that edge < 25 m, and the
  truth outside the 95 % ellipse (engine ellipse).
- **Road residuals:** the cross-track distance of clean fixes to their truth edge, p50 and
  p95 per highway class. This is the measured basis for `roadSigmaM` (it includes about
  3–5 m of GNSS error). As built: every clean fix of the recording (used or withheld) with a
  matched truth edge, so censored at the truth's 15 m.
- **Ellipse consistency** as today, plus a variant with the truth's own σ added (Pᵢ-mixture
  + σ_truth² I). Roads shrink the ellipse across the road to a few metres, while pins have
  σ 30–104 m and clean fixes their own 3–5 m error. The current metric would then count
  correct estimates as outside. **Decided (Q3):** the gate uses the variant with the truth's
  σ added. Both are reported. The adoption-rule change is recorded explicitly in
  docs/NAVIGATION.md in N3.0, together with the metric tooling and before any road run, and
  the N3.0 baseline is reported under both definitions.
- **Other:** `onRoadShare` over time, `fixesRejectedOffRoad`, `roadSplits`,
  `roadCandidateTests` per update, and road-update time. Road-update time is measured in the
  replay around `ingest` by differencing runs with and without roads, never inside the
  engine.

## Stages

Every stage ends green (`cd Core && swift test`; the import check; for App changes,
`xcodegen generate`, the simulator build and the app tests on a concrete simulator id), then
`/review-loop` on its range, then a commit. No push without asking. Engine-behaviour changes
get their own commits.

### N3.0 — N3-tagged backlog items that change engine behaviour, new baseline

**First, tools that must land before any new config key** (no engine change; acceptance runs
stay bit-identical):
- **R11.2-4 / R12.1-1:** a tolerant `decodeIfPresent` decoder for `NavigationConfig`,
  `NavigationCounters` and `ReplayMetrics`, and a warning when an existing `metrics.json`
  does not decode. Today the `try?` would silently drop every earlier row as soon as N3 adds
  a key.
- **R11.1-8:** print the reader's report; `--strict` aborts on damage.
- **R14.2-3:** skip scheduling for rejected inputs.
- **R13.1-8:** one consistency denominator; tests for the hold and the cap.
- **Q3:** the consistency variant with the truth's σ added, as the gated metric. The
  adoption-rule change is written into docs/NAVIGATION.md explicitly, in its own commit.
- **R14.1-2, R14.4-2 (`macroStep` half):** tests only.
- **R13.1-9, R14.4-3:** docs.

**Then engine fixes, one commit each, each with a regression test that fails before it:**

| item | change |
|---|---|
| R11.1-4 | course gate: a stale OBD 0, or no OBD at initialisation, vetoes a course (today `(obdAtFix ?? .infinity)` passes) |
| R11.1-5 | a stale fix accepted while stopped needs history covering its `fixNs` with every step since a ZUPT or parked step; otherwise ignored |
| R11.1-6 | a clean-fix reseed is applied after that fix's update (or reseeded indices are excluded from it), so the fix is not counted twice |
| R11.2-2 | latency shift interpolated between the two history entries around `fixNs`; tests at off-grid times (t = k + 0.07) |
| R11.2-3 (remainder) | a 0–5 s old initialising fix: σ inflated by age × OBD speed |
| R14.4-1 | a late pin before initialisation backfills `motionEast/North`, the ring, the mean history and cumulative motion |
| N4MF-1 | pin σ grows with speed at the tap (see above) |
| R11.1-7 | measure first: OU since N2.3 and the parked latch bound the drift. Close it with the measured realised-mean drift, or add antithetic offsets if it is still over 20 m at 10 min stale |

**Not in N3** (decided, Q7):
- **N2-1 (reversing):** large, and it interacts with oneway roads.
- **N2-3 (magnetometer prior).**
- **N4B1-1, engine half** (a ZUPT contradicted by moving clean fixes).
- **N4MF-2:** N4 follow-up.

**Exit:**
- An "N3.0" table in NAVIGATION.md: seeds 1–5 on the seven drives (with drive-7), arrival order plus
  `--as-live`.
- Every change against N4-B1 is explained. These are correctness fixes, reported per the
  adoption rule's last paragraph.
- Every criterion passes on every seed, and consistency does not drop.
- This is the baseline N3.2 is judged against.

### N3.1 — graph format, builder, index, tests

**Deliverables:**
- `docs/ROAD_PACK.md`.
- Core `Navigation/Roads/` (Foundation only):
  - `RoadPack`: mmap open, structure checks, `verify()`, hash, `RoadPackInfo` (Codable);
  - `RoadNetwork`: one or more packs with the same grid ID, `roadSetHash`, de-duplication;
  - `RoadGrid` (cell maths) and `RoadGeometry` (point–segment, bearing, level rule);
  - `RoadPackWriter`.
- A Mac-only library target `RoadPackBuild` (OPL reader, `RoadGraphBuilder`), which the app
  does not link, and the executable `Core/Sources/build_roads/`.
- `tools/roads/build_packs.sh`.
- `.gitignore`: `osm/`, `*.osm.pbf`, `*.roadpack`. `Package.swift` gains the two targets.

**Tests** (fixtures are hand-written OPL in the test files, synthetic coordinates near
(0, 0), no real extract):
- **Graphs:**
  - a 4-way junction;
  - a 15° Y-fork;
  - opposite oneway carriageways 15 m apart;
  - `oneway=-1`;
  - a roundabout;
  - a dead end;
  - a bridge (`layer=1`) stacked over a level-0 road, with a connected ramp;
  - a tunnel;
  - a 3 km straight segment crossing many cells;
  - a segment on a cell boundary.
- **Properties:**
  - a round trip;
  - brute force against the grid over 10 000 seeded random points: identical candidate sets
    within R;
  - a builder determinism test: the same bytes from shuffled OPL lines, and twice in a row;
  - a pinned golden `contentHash` of one fixture (format stability, like the
    `NavigationSeed` pin);
  - de-duplication across two overlapping packs.
- **Rejection:** truncated file, bad magic, newer version, hash mismatch, section out of
  range, overlapping sections, unsorted `CELK`.

**Exit:**
- All of the above green.
- One national and one region pack built locally. Their counts, sizes, build times,
  candidates per lookup and the 32 / 64 / 128 m comparison are reported with aliases only,
  no names or relation IDs.
- Every built pack is ≤ 150 MB (Q1); `build_roads` fails a build over the limit. If a
  region pack exceeds it, it is split at `admin_level` 6.
- `git check-ignore` confirms that `osm/` and the packs are ignored.

**Result (N3.1, measured; details in docs/ROAD_PACK.md "Measured"):**
- **national:** 41.3 MB, 56 163 edges, 369 250 segments, built in 1.5 s, verified in 69 ms;
  candidates per lookup p50 6, p95 37, max 176.
- **region-A** (admin_level 4, every drivable class): 17.3 MB, 86 671 edges, 231 390
  segments, built in 0.5 s, verified in 29 ms; candidates per lookup p50 28, p95 64, max 175.
- The whole pipeline takes 20 s. A rebuild gives byte-identical packs, and both packs
  share one grid ID.
- Region-A loaded after national has 11 415 shadowed segments. That is exactly its
  national-class segments.
- **Cell size on region-A**, as p95 candidates / pack size / lookup + distance time:

  | cell | p95 candidates | size | lookup + distance |
  |---|---:|---:|---:|
  | 32 m | 47 | 32.2 MB | 717 ns |
  | 64 m | 64 | 17.3 MB | 740 ns |
  | 128 m | 104 | 12.6 MB | 1002 ns |

  **The default stays at 64 m.** 32 m doubles the size for no speed gain, and 128 m
  exceeds 64 candidates at p95.

### N3.2 — road update in replay_nav only, behind `--roads <pack>` (repeatable)

**Deliverables:**
- In `NavigationEngine(config:roads:)` (default nil): `RoadMatcher` (cell cache, the Steps
  0–5 above, the level rule, the fix gate, the pin anchor) and the counters and estimate
  fields.
- `ReplayOptions`/`replay_nav` changes:
  - `--roads` (repeatable) and `--wrong-road-tolerance`;
  - the road metrics, and `roads` and `roadSetHash` in every output;
  - the `-roads-<hash>` label;
  - the GeoJSON gains the matched edge every 10 s and the rejected fixes.
- `LiveNavigationRun` and the app are untouched.

**Tests** (synthetic, Swift Testing):
1. Straight road, 20 m initial offset: the estimate converges across the road. With coupling
   0 the along-track coordinate is unchanged by each update (bit-exact in the road frame).
2. A car park, or outside the pack: bit-identical to no roads (`roadUpdatesNoRoad`).
3. A road missing from OSM, 40 m from a mapped parallel road for 1 km: no capture, and the
   truth stays inside the 95 % ellipse.
   **Known FAIL under this model (measured, 2026-10-13):** every seed is captured onto the
   mapped road, about 42 m off with a confident ellipse. The test runs inside
   `withKnownIssue`. Candidates and measurements: docs/N3_ROAD_OFFROAD.md (Risks, R2).
4. A 15° fork, with the car taking the right branch by gyro yaw: both branches stay
   populated before the turn, the right one wins after 300 m, and no branch is forced.
5. A stacked bridge: the car below is never matched to the bridge (`roadLevelBlocked` > 0);
   a car via the ramp is.
6. Opposite oneways 15 m apart: heading picks the right carriageway.
7. A ring cloud after a pin on a grid with one exit road: heading converges within a stated
   distance. On a symmetric 4-way grid driven straight: no false collapse (heading stays
   multi-modal). This is the regression guard for N2's sampled-position collapse.
8. GPS gate: a fix 200 m from any road while on-road is rejected; a fix on another road 300 m
   from the estimate is accepted.
9. A moving pin anchors; a stationary pin does not.
10. Late pin with roads: the ring and `motionEast/North` are unaffected; it matches arrival
    order as today.
11. Re-anchor during a road drive: continuous, and equal to clearing the cache every step.
12. Determinism: same pack → bit-identical; cache size 1 equals the default; prefix
    causality and garbage-after-T with roads.
13. Resampling copies road state; reseed and manual reset clear it.
14. `NavigationRoadPerfTests`, run with `swift test -c release --filter
    NavigationRoadPerfTests` on a synthetic 100 m street grid over 10 km² with 2000
    particles. It asserts the Mac proxies: road-update step ≤ 0.5 ms mean, ≤ 1.5 ms max. A
    debug run checks only `roadCandidateTests` per particle ≤ 64.
    - As built (N3.2c item 6): 32 × 32 blocks (10.24 km², 100 m segments, shared crossing
      nodes); 600 s round a 1 km square at 12 m/s, clean fixes for 20 s only; each
      `ingest` that carries a full road update is timed. Release, 3 runs: 600 road
      updates, 6.9 candidate tests per particle, mean 0.366–0.369 ms, max 0.650–0.765 ms.
      Debug: 40 s, 9.5 per particle, under 1 s. The grid is lighter than the real drives
      (15–33 candidates per particle), so it guards against regressions; it does not
      replace the replay-set ms/step proxy.

**Experiments** (seeds 1–5, pre-declared grids, never tuned toward manual-3):
- `roadSigmaM` from the measured residuals, then {5, 7, 10};
- `roadOffRoadProbability` {0.02, 0.1, 0.3};
- `roadUpdateIntervalS` {1, 0.5, 0.2, 0.1}: does a higher rate help, and at what ms/step;
- `roadCorrelationM` {10, 30, 100};
- `roadSplitSigmaM` {10, 15, 25};
- `roadEngageMaxEllipseM` {500, 1000, 2000};
- `roadAlongTrackCoupling` {0, 1};
- fix gate on and off.

Each is reported as a table against N3.0.
Measured in N3.2d (2026-10-13; docs/NAVIGATION.md, "N3.2d: pre-declared grids"). No config was
chosen and the choice is open for the user. No single value passes clean and clean-long against N3.0. drive-7's
consistency fails against N3.0 for every value. The residual-derived `roadSigmaM` is 3.0 m (RMS; the
fix-error subtraction gave none).

**Exit:**
- Without `--roads`, the 30 acceptance runs are bit-identical to N3.0: every `metrics.json`
  field except ms/step and the config block, and every GeoJSON byte.
- With the chosen pack(s) and config: the adoption rule plus the N3 criteria below, every
  seed.
- A failing criterion (above all manual convergence) is reported as a measured FAIL, and the
  user decides. No criterion, metric definition or convergence rule is loosened to pass.

### N3.3 — enable in the engine (live path)

**Deliverables:**
- `LiveNavigationRun(…, roads:)`; `NavigationService` loads the packs for the recording
  (selected by coverage of the first position, else none).
- **Sidecar v2:**
  - the header adds `roads` (per pack: hash, version, OSM timestamp) and `roadSetHash`;
  - estimates add `onRoadShare`;
  - v1 readers refuse v2, because ignoring an unknown pack would hide a mismatch;
  - docs/NAV_SIDECAR.md updated.
- **Compare:** `--as-live --compare` warns on a pack hash mismatch and refuses an exact
  verdict without the same packs.
- Revisit `convergedHeadingStdDeg` against the road results (N2-2).
- The default config is the N3.2 winner.

**Tests:**
- the app's loop with a pack equals `replay_nav --as-live --roads` exactly (Mac and
  simulator);
- no pack → identical to N3.0 as live;
- the sidecar v2 round trip;
- a v1 reader refuses v2.

**Exit:**
- The adoption replays are repeated as live.
- The device items D1–D2 are added to PLAN.md §6, not claimed.

### N3.4 — pack in the app, and display

**Deliverables:**
- **Getting packs onto the phone (decided, Q1):** import via Files or AirDrop
  (`UIDocumentPicker`, "Open in DriveLogger"), stored in Application Support. No pack is
  bundled and none is downloaded. A pack is at most 150 MB; import refuses a larger one. It is verified
  once on import, and the list shows OSM date, size, hash prefix and coverage.
- **Display (`ios-ui-engineer`, MapKit unchanged as base map):**
  - the DR dot and ellipse as today;
  - a debug toggle drawing the matched OSM edge and `onRoadShare` in the stats overlay;
  - "© OpenStreetMap contributors" on the map whenever a pack is loaded, and in the pack
    list.
- **The OSM-vs-Apple geometry mismatch** documented as a known display limitation, with
  screenshots from the device drive (kept private).
- **Invariant test:** no `MKDirections|MKLocalSearch|MKMapItem|MKRoute` under
  `App/Sources/Navigation` or `Core/`.
- `xcodegen generate` for the new App files.

**Tests:** import validation (bad pack refused, hash cached), coverage selection, overlay
gating, attribution visibility (pure logic, in the `MapCameraLogicTests` pattern).

**Exit:** green builds and tests, `/review-loop`, PLAN.md §6 items D1–D4.

## N3 criteria (judged in N3.2 and re-checked as live in N3.3)

First measurement against them (N3.2b, default road config, no tuning, 2026-10-13):
docs/NAVIGATION.md, "N3.2b: first measurement with roads". Every per-seed criterion passes,
manual converges at 1.52 km; the adoption rule fails on clean, clean-long (max error) and
on clean-long and drive-7 (consistency). Open for the user's decision; the criteria are
unchanged. Clean's road truth is 20.3 % ambiguous (drive-7 33.2 %), over the 20 % Viterbi
trigger, and the Viterbi match is not implemented, so clean's wrong-road share is provisional
until the user decides.

| criterion | drive / run | today (N4-B1, seeds 1–5) | N3 target |
|---|---|---|---|
| heading converged | manual, use, hold-out 100 | 7.27–7.68 km, known FAIL | ≤ 2 km on every seed |
| truth point 1 | manual | 50.57 m mean | ≤ 200 m, and the adoption rule (+2.5 m) |
| end error | jammed-A / jammed-B, use | 1.147 % / 1.068 % mean | no worse than N3.0 (+0.1 pp), ideally ≤ 0.5 % |
| max error | clean-long / clean | 18.90 m / 13.94 m mean | no regression (adoption rule), ≤ 30 m every seed |
| worst withheld clean fix after 1800 s | drive-7, mask-after 1800 | 225.97 m mean, 1.138 % of distance from the start (4.55 % of distance since the last pin) | gated: ≤ 2.5 % of distance from the start on every seed (decided 2026-10-12), and the adoption rule (+0.1 pp). **Reported, not gated** until the first N3.2 replays: clearly below today's 226 m mean |
| wrong-road share, by distance | clean, clean-long (Q9) | (new) | ≤ 5 %; revisited after the first N3.2 replays (Q8) |
| ellipse consistency (truth σ added, Q3) | all seven (with drive-7) | N3.0 baseline under the new definition | does not drop |
| ms/step | all, Mac release | 0.058–0.079 | mean ≤ 0.15, road step ≤ 0.5 ms; device D1 |
| determinism, causality, log format | tests | — | unchanged; `LogFormatVersion` and its fixtures untouched |

drive-7's reported target is about its long dead-reckoning stretch: 1.9–5.0 km of pure dead
reckoning from the last pin, with heading std 2.0–2.8° there. Roads should bound the
cross-track error that this heading uncertainty allows. A number for the target is set
after the first N3.2 replays, not before. Its two excluded pins (≈ 599 s, ≈ 626 s) are
likely, not proven, about 200 m off; they are still fed to the engine and not scored.

"Ideally ≤ 0.5 %" means 56 m on jammed-A and 29 m on jammed-B. jammed-B's truth `end`
itself has σ 30 m, so 0.5 % is at the resolution of its truth. The parked end may also be
off the road the filter matched.

## Risks

1. **OSM geometry and lanes.**
   - Centrelines are 2–5 m off, and a multi-lane car sits up to about 7 m from the centreline.
   - A σ that is too small makes the ellipse overconfident across the road.
   - Mitigation: σ from the measured residuals; distance tempering; `lanes` is stored for a
     later class- or lane-dependent σ.
2. **Missing, new or closed roads.** These capture the cloud onto a parallel road.
   Mitigation: the χ² gate, ε, moment-matched responsibilities, test 3. Not measurable on
   the replay set unless a drive crosses such a place (unknown).
   - **Measured (2026-10-13): test 3 fails.** A car on an unmapped road 40 m from a mapped
     parallel one is captured onto the mapped road on every seed (42 m off, cross-track
     semi-axis about 12 m). Two prototype rounds (a persistent on/off mode, Student-t,
     a band off-road density, a likelihood-ratio cap, geometry-novelty tempering) found no
     model that passes test 3 and keeps tests 1, 4, 7 and 8. Decided: keep this model, test
     3 stays a known FAIL. Details and the unmeasured next candidate:
     docs/N3_ROAD_OFFROAD.md.
   - **Real-data check (partial, R21.1-11):** the wrong-road share on clean and
     clean-long checks capture onto a wrong *mapped* road only: it scores fixes whose truth
     is on a mapped edge, so capture while the car is on an unmapped road is invisible to
     it. N3.2b adds the unmapped/captured count for that case (Metrics added to
     replay_nav), and every N3.2 replay result carries this caveat.
3. **Splitting gives up part of the Rao-Blackwellisation.**
   - N2 saw sampled positions collapse heading with no heading information.
   - Here splitting happens only when roads are engaged, and road evidence is genuinely
     about position. Test 7 guards the collapse.
   - If replay shows overconfidence, raise `roadSplitSigmaM` or lower the engage threshold.
4. **Particle depletion.** A large ellipse on a sparse rural network leaves few on-road
   samples. Mitigation: the engage threshold and ESS monitoring. 2000 particles may be too
   few for a 1 km ellipse.
5. **The consistency metric conflicts with a thin cross-track ellipse.** Resolved by Q3:
   the truth's σ is added.
6. **Reversing** (N2-1) on a oneway or in a car park is integrated forward. The heading
   gate rejects the road and the particle goes off-road, which is soft, but it may cost
   particles.
7. **Mis-tagged bridges and tunnels** (missing `layer`) defeat the level rule. Missing
   adjacency at pack borders weakens it.
8. **Device time and memory:** unknown iPhone/Mac ratio; pack hash verification at import
   (~100 MB, estimated well under a second); thermal state with the map open. The Mac
   already shows a 4.47 ms single-`ingest` outlier.
9. **Mac vs iPhone bits** (R13.1-7, still open): roads add trigonometry per cell, so an exact
   `--compare` is less likely. The tolerance path exists.
10. **Pack vs drive age:** the road network changes. Results are tied to a pack hash; a new
    build is re-judged.
11. **Overfitting five drives.** Pre-declared sweeps, the mean-based rule, manual-3 never a
    target, and parameters taken from measurements where possible.
12. **Privacy.** Region choice, relation IDs, pack names and the matched-edge GeoJSON reveal
    places. They stay in `osm/` and `logs/`; committed tests are synthetic.
13. **Licence.** Packs are ODbL derived databases. Personal use needs attribution. Public
    distribution would have to offer the pack under ODbL.

## Decisions (user, 2026-10-11)

- **Deviations from the brief** (split wide Gaussians, tempering by distance, GPS gate at
  the fix, no `--roads` bit-identical to N3.0, metrics tooling first, sidecar v2 in N3.3,
  no country or region names in committed docs): accepted as written.
- **Q1:** packs are imported via Files or AirDrop; ≤ 150 MB per pack.
- **Q2 (proposed default, accepted):** national highways plus region packs at `admin_level` 4 and 6.
- **Q3:** ellipse consistency adds the truth's σ. The adoption-rule change is recorded
  explicitly in docs/NAVIGATION.md (in N3.0).
- **Q4:** GPS fix compatibility is judged at the fix.
- **Q5 (proposed default, accepted):** `track` and `service=parking_aisle` excluded; `access=private` kept.
- **Q6 (default):** a pin with unknown speed uses 10 m/s; old long-press rows keep the
  `t − pressedT` allowance.
- **Q7:** N2-1, N2-3 and the engine half of N4B1-1 are out of N3.
- **Q8:** wrong-road share is measured by distance. Starting targets ≤ 5 % on clean drives
  and ≤ 10 % on jammed drives, revisited after the first N3.2 replays. With Q9 the jammed
  target has no truth to be measured against and is not gated in N3.
- **Q9:** no road-level truth for manual, jammed-A or jammed-B. Wrong-road share is
  measured on the clean drives only.
- **Q10:** the 2 ms budget is set on the iPhone 16 Pro Max.
- **Q11 (default):** the Schmidt update (`roadAlongTrackCoupling` 0). Exact Kalman stays an
  N3.2 experiment and is adopted only through the adoption rule.
- **Q12 (proposed default, accepted):** a moving pin is on a road and anchors a road update; a stationary pin
  may be off-road and does not.
- **Q13 (proposed default, accepted):** no scheduled refresh. OSM data is refreshed on demand (for example
  after driving a road missing from the pack). Each refresh gives a new pack hash and
  re-runs acceptance like a config change.

## Device checklist (docs/PLAN.md §6 when the stage lands; not verified)

- **D1:** with a region pack loaded, a 30 min city drive. The sidecar's `msPerStep` and
  `maxStepMs` stay ≤ 2 ms per 10 Hz step, including road-update steps. Also note CPU and
  thermal state, and resident memory with the pack mapped.
- **D2:** pack import time and hash verification time on the phone. An app relaunch reuses
  the cached verification.
- **D3:** a drive with pins at 30–60 km/h at recognisable spots, to judge N4MF-1 and the pin
  anchor, and with a stretch of jamming. Afterwards `replay_nav --as-live --roads <same pack>
  --compare <sidecar>` is exact or within tolerance, and any difference is explained.
- **D4:** on the map: the matched OSM edge against Apple's road (the size of the mismatch at
  junctions, bridges and new roads), attribution visible, and behaviour in a car park and on
  a road missing from OSM.

## Verification (each stage)

- `cd Core && swift test` (plus `swift test -c release --filter NavigationRoadPerfTests` from
  N3.2).
- `grep -rhoE '^[[:space:]]*import[[:space:]]+[A-Za-z_]+' Core/Sources Core/Tests | sort -u`
  shows Foundation and Testing (and DriveLoggerCore) only.
- The acceptance replays, seeds 1–5, from docs/NAVIGATION.md, with and without `--roads`;
  output in `logs/`.
- No log-format diff: `LogFormatVersion` and `LogFormatCompatibilityTests` untouched.
- `git status` shows no pack, extract or replay output.
- From N3.4: `xcodegen generate`, the simulator build, and the app tests on a concrete
  simulator id.
