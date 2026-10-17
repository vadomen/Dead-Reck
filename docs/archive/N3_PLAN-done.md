# N3 plan: completed parts

Moved from `docs/N3_PLAN.md` on 2026-10-17. Text unchanged; read only on demand. Open plan: [docs/N3_PLAN.md](../N3_PLAN.md).

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
Re-measured in N3.2e (2026-10-14; docs/NAVIGATION.md, "N3.2e: candidates on the cross-pack level
rule") after the level rule's adjacency was extended across packs (N3.2e item 1): the default,
`roadCorrelationM` 100 and `roadSigmaM` 10 and 3.0, on all eight acceptance drives. No candidate passes
against N3.0 on every gated drive; `roadCorrelationM` 100 fails only drive-7's consistency (96.3 % against
99.6 %) and passes against the N3.2b default. N3.2e item 1 itself fails the adoption rule against the
N3.2b default only on drive-7's consistency (87.4 → 87.2 %, three end checkpoints); the user accepted it
as a correctness fix (2026-10-14).

**N3.2 done (2026-10-14).** The user chose the default config: N3.2e item 1 plus `roadCorrelationM`
100 (docs/NAVIGATION.md, "N3.2 decision (2026-10-14)"). It is a trade-off the user accepted against a
failing gated check; the adoption rule is unchanged. Regression cases for the failing check:
docs/N3_ROAD_OFFROAD.md.

**Exit:**
- Without `--roads`, the 30 acceptance runs are bit-identical to N3.0: every `metrics.json`
  field except ms/step and the config block, and every GeoJSON byte.
- With the chosen pack(s) and config: the adoption rule plus the N3 criteria below, every
  seed.
- A failing criterion (above all manual convergence) is reported as a measured FAIL, and the
  user decides. No criterion, metric definition or convergence rule is loosened to pass.
- **Exit notes (2026-10-14):** the drive-7 consistency criterion fails against N3.0 (99.6 → 96.3 %)
  and was accepted as a trade-off by the user. Every other gated drive passes. N3.3 is next and
  waits for a Release-build ms/step measured on the phone (device item).

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

**Amendment (decided by the user 2026-10-15).** Additions to N3.3; the items above stand.
- **Developer pack bridge (temporary).** The app reads `*.roadpack` from `Documents/RoadPacks/` (copied via Finder → iPhone → Files; `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` are already in Info.plist). Settings → Diagnostics lists the packs found (verified yes/no or the refusal reason, size, OSM date, hash prefix), which packs the current recording uses and when roads became active, and "© OpenStreetMap contributors" whenever a pack is in use. Consistent with Q1: no pack is bundled or downloaded. The loader does not depend on where the files come from; N3.4's import into Application Support replaces only the source.
- **Verification cache.** Each pack is verified once (content hash and structure), off the main actor. The cache key is the file's identity (name, size, modification date), not the content hash, because a content-hash key would need the full read the cache exists to skip. The value holds the content hash, verified yes/no, verify time, OSM date, bounds and grid ID. A file re-copied via Finder gets a new modification date and is verified again.
- **Pack selection when the first fix is about 1414 m.** The "first usable position" is the engine's own estimate right after it first initialises: its centre and the semi-major axis of its 95 % ellipse. Every verified pack whose coverage (`COVR` if present, else its bounding box) intersects that circle is selected. If none does, selection is repeated at each later accepted position until one does. Once a network is attached it stays for the recording; a second initialisation (a manual-fix reset of the cloud) keeps it and does not re-run selection. A wrong choice costs at most the no-roads result; it must not stall or crash the run.
- **Config unchanged by a pack set.** If `config.validated(roads:)` would change any key for the selected packs, that pack set is refused (reason shown in Diagnostics) and the recording continues without roads; the config never changes mid-run. With today's packs it is a no-op.
- **Roads becoming active mid-run.** Loading never delays the start of recording or of the sensor streams. Until the network is ready the run proceeds without roads, and its output up to that point is identical to the no-roads run. The network is attached at an input boundary.
- **Sidecar v2 (replaces the header fields above).** The header is written at Start, before any position exists, so it cannot name the packs. The app always writes v2. A `roads` line is written once, when roads become active: `t`, `afterInputs` (inputs ingested before the attach), per pack `contentHash`, `formatVersion`, `osmTimestamp` and grid ID, and `roadSetHash`. A v2 sidecar without a `roads` line means no roads were used. Estimates add `onRoadShare`. v1 readers refuse v2.
- **A corrupt or truncated pack** is refused at load (structure check or verification), with the reason in Diagnostics, and the run continues without it.
- **replay_nav:** `--roads` is allowed with `--as-live --compare` (attaching at the sidecar's `afterInputs`) and with `--write-sidecar`. Compare warns on a `roadSetHash` mismatch and gives no exact verdict without the same packs. N3-CMPHASH (road-only keys inert without roads) is closed in the same change.
- **Exit additions:** Mac memory of national + region-A after building the `RoadNetwork` (mapped and heap reported separately, with build time); the phone's number stays open for D1.

**N3.3 implemented (2026-10-15); device items open.** Items 0–6 are in: the plan amendment, the
mid-run attach, sidecar v2, the pack catalog and selection, `replay_nav --roads` with `--as-live`,
`--compare` and `--write-sidecar`, and the app wiring. The adoption replays were repeated as live, and every
criterion passes as live with and without roads (docs/NAVIGATION.md, "N3.3: roads live (2026-10-15)").
The live attach equals roads from the start on every acceptance run. The Mac memory of national +
region-A is measured: mapped and heap separately, with build time. N2-2 (`convergedHeadingStdDeg`)
is reported, with no change. Open: D1 and D2 (docs/PLAN.md §6, not claimed), including the phone's
memory number.
