# Road pack format v1

A road pack (`*.roadpack`) is a binary, memory-mappable graph of OpenStreetMap roads
with a uniform grid index, for the navigation engine's road measurement
(docs/N3_PLAN.md). It is versioned independently of the log format and the
navigation sidecar.

Data in every pack: **© OpenStreetMap contributors**, licensed under the
[Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/).
A pack is a derived database. Personal use needs the attribution. Distributing a
pack publicly means offering it under the ODbL. Every pack's `META` carries
`attribution` and `license`, `build_roads --info` prints them, and the app and
the replay summary show the attribution wherever roads are used or shown.

Packs, OSM extracts and `osm/packs.json` (the admin relation IDs) are **never
committed**: they live in the git-ignored `osm/`, because the choice of regions
reveals where someone drives. Committed text uses aliases ("national",
"region-A") only.

Code:
- `Core/Sources/DriveLoggerCore/Navigation/Roads/`: Foundation only, linked by the app.
  - `RoadPackFormat`: constants, tags, hashes and record types.
  - `RoadPack`: the reader.
  - `RoadNetwork`: several packs used together.
  - `RoadGrid`: the cell maths.
  - `RoadGeometry`: point–segment, bearing and the level rule.
  - `RoadPackWriter`.
- `Core/Sources/RoadPackBuild/`: Mac only. It is not a package product, so the app
  cannot link it. It holds the OPL reader, `RoadGraphBuilder`, the GeoJSON coverage
  reader and the lookup bench.
- `Core/Sources/build_roads/`: the CLI.
- `tools/roads/build_packs.sh`: the osmium pipeline.

## Encoding

- **Byte order:** every integer is little-endian and is read with an explicit
  `littleEndian` conversion, so the format does not depend on the host. Floats are
  IEEE-754 binary64, little-endian.
- **Alignment:** the header is 96 bytes and the section table follows at offset 96.
  Every section starts at a multiple of 8 and is zero-padded to one. The file size is a
  multiple of 8. A mapped file is read in place with `loadUnaligned`, with no copies.
- **Coordinates:** E7 fixed-point degrees, Int32 (1e-7°, about 1.1 cm), as OSM
  stores them. The OPL reader converts the decimal text to E7 exactly, with no
  floating point, and refuses more than 7 decimals. All later arithmetic is Double
  on these exact integers, so it gives the same result on every platform.

## Header (96 bytes)

| offset | type | field |
|---:|---|---|
| 0 | 8 × UInt8 | magic `DLRPACK\0` (`44 4C 52 50 41 43 4B 00`) |
| 8 | UInt16 | `formatVersion` = 1 |
| 10 | UInt16 | `headerSize` = 96 |
| 12 | UInt32 | flags: bit 0 = `COVR` present; the other bits are 0 |
| 16 | UInt64 | `contentHash` (see Hash) |
| 24 | UInt64 | `fileSize`, which must equal the file's length |
| 32 | UInt64 | `sectionTableOffset` (96 in v1) |
| 40 | UInt32 | `sectionCount` |
| 44 | UInt32 | reserved, 0 |
| 48 | Int64 | `osmTimestamp`: Unix seconds UTC of the source extract's replication timestamp; 0 = unknown |
| 56 | Int32 | grid origin `latE7` |
| 60 | Int32 | grid origin `lonE7` |
| 64 | Float64 | grid metres per E7 unit of latitude (`kLat`) |
| 72 | Float64 | grid metres per E7 unit of longitude (`kLon`) |
| 80 | Float64 | `cellSizeM` |
| 88 | Float64 | `searchRadiusM`: the guaranteed radius in true metres |

Bytes 56–95 are the grid. Their FNV-1a 64 is the **grid ID**.

## Section table

`sectionCount` entries of 24 bytes each:

| offset | type | field |
|---:|---|---|
| 0 | 4 × ASCII | tag, in file order (`"NODE"` is the bytes `4E 4F 44 45`) |
| 4 | UInt32 | flags, 0 in v1 |
| 8 | UInt64 | offset from the start of the file |
| 16 | UInt64 | length in bytes, without padding |

Entries are sorted by offset. Sections do not overlap each other, the header or
the table, and lie inside the file. A known tag appears at most once. Unknown tags
are skipped, so an optional section needs no version bump. The writer emits the
sections in the order of the next table.

## Sections

n = nodes, m = edges, p = shape points, c = non-empty cells.

| tag | size | content |
|---|---|---|
| `META` | any | UTF-8 JSON object with sorted keys (see META) |
| `NODE` | n × 8 | topological nodes: {latE7 Int32, lonE7 Int32} |
| `EDGE` | m × 40 | edges (see EDGE) |
| `PNTS` | p × 8 | shape points: {latE7 Int32, lonE7 Int32} |
| `PTED` | p × 4 | UInt32: the edge of each point |
| `ADJO` | (n + 1) × 4 | UInt32 CSR offsets into `ADJE`: `ADJO[0]` = 0, `ADJO[n]` = entries in `ADJE` |
| `ADJE` | any × 4 | UInt32 edge indices: the edges incident to each node, ascending; a self-loop is listed once |
| `CELK` | c × 8 | UInt64 non-empty cell keys `cy << 32 \| cx` (each as its 32-bit pattern), strictly ascending |
| `CELO` | (c + 1) × 4 | UInt32 CSR offsets into `CELS`: `CELO[0]` = 0, `CELO[c]` = entries in `CELS`, strictly increasing (no empty cell) |
| `CELS` | any × 4 | UInt32 segment start-point IDs per cell, strictly ascending within a cell |
| `COVR` | any | optional coverage polygon (see Coverage); the header's flag bit 0 says whether it is present |

### EDGE (40 bytes)

| offset | type | field |
|---:|---|---|
| 0 | UInt32 | `from`: node index of the first point |
| 4 | UInt32 | `to`: node index of the last point |
| 8 | UInt32 | `firstPoint`: `PNTS` index |
| 12 | UInt32 | `pointCount` ≥ 2, both end nodes included |
| 16 | Int64 | `osmWayID` |
| 24 | UInt32 | `wayPointOffset`: index of the first point in the way's normalised node list |
| 28 | UInt32 | `lengthDm`: length in decimetres |
| 32 | UInt8 | `highwayClass`: 1 motorway, 2 trunk, 3 primary, 4 secondary, 5 tertiary, 6 unclassified, 7 residential, 8 living_street, 9 service, 10 road |
| 33 | Int8 | `level`, −5…5 (see Level) |
| 34 | UInt8 | flags: bit 0 oneway, 1 bridge, 2 tunnel, 3 roundabout (`junction=roundabout` or `circular`), 4 link (`*_link`), 5 oneway-implied |
| 35 | UInt8 | `lanes`, 0 = unknown |
| 36 | UInt32 | reserved, 0 |

- **Shape points:** each edge's points are contiguous in `PNTS`, in driving order for
  a oneway. Edges partition `PNTS` in edge order. The first and last points equal
  `NODE[from]` and `NODE[to]`.
- **Segments:** segment s is the pair of points (s, s + 1) inside one edge, so a
  segment is identified by its start point. There are p − m of them.
- **Segment key:** (`osmWayID`, `wayPointOffset` + k) for the edge's k-th segment.
- **Normalised node list:** the way's node references after the `oneway=-1` reversal,
  with consecutive repeats removed: the same node ID twice in a row, and consecutive
  distinct nodes with equal E7 coordinates (the first of each run is kept). The list
  depends only on the way's own node IDs and locations, never on other ways or on
  which pack is being built, so every pack built from the same OSM data gives a
  segment the same key, because extracts use `--strategy complete_ways`.
  `RoadNetwork` uses the key to de-duplicate overlapping packs: the first loaded pack
  that has a key wins.
- **Edge order:** edges are sorted strictly by (`osmWayID`, `wayPointOffset`), so a key
  is found by binary search.
- **Node order:** nodes are numbered by first appearance in edge order, `from` before
  `to`.

The class's raw values and the flag bits are on disk. Never renumber them.

### Zero-length segments

A pack has none: no segment's two points are equal, so every segment has a defined
bearing (`atan2(0, 0)` would read as north and pass a heading test for a
north-bound particle).

- **Builder:** OSM sometimes stacks two node IDs on one position. The normalised
  node list keeps the first of each equal-coordinate run (see EDGE), and
  `build_roads` counts the dropped references as "points at a repeated coordinate".
- **Topology:** the IDs of each such run are merged into one topological node, the
  smallest ID of the set, across every kept way, and edges are split and connected
  on the merged IDs. A way that met the dropped node therefore still meets the kept
  one, at a junction or at a way's end. `build_roads` reports the merges as "node
  IDs merged". A way that collapses to one point has fewer than two nodes and is
  dropped as degenerate, but its nodes are still merged, so the ways it joined stay
  joined.
- **Writer and `verify()`:** both refuse a segment with equal end points, so a
  hand-made pack cannot carry one either. A closed edge (first point = last point)
  is not a zero-length segment.

### META

UTF-8 JSON, sorted keys, no build date or host, so the bytes are deterministic:

```json
{
  "attribution": "© OpenStreetMap contributors",
  "builder": {"commit": "<git hash>", "name": "build_roads", "version": "1"},
  "coverage": {"adminLevel": 4, "polygon": true, "relationID": 0},
  "formatVersion": 1,
  "license": "ODbL 1.0",
  "parameters": {"cellSizeM": 64, "excluded": ["area=yes", "service=parking_aisle"],
                 "highwayClasses": ["..."], "osmiumExtractStrategy": "complete_ways",
                 "osmiumVersion": "1.19.1", "searchRadiusM": 50},
  "source": {"fileName": "<country>-latest.osm.pbf", "osmTimestamp": "YYYY-MM-DDTHH:MM:SSZ",
             "sha256": "<hex>"}
}
```

`builder.commit` is provenance: the 12-digit hash of the last commit that touched
the files the pack bytes depend on, with `-dirty` if any of them has an uncommitted
or untracked change (see Hash). `build_roads --commit` writes it as given and omits
it when absent.

`coverage.relationID` and the source file name reveal places. They are written into
the pack only, which is git-ignored. Optional keys are omitted when unknown, and a
national pack has no `adminLevel` or `relationID`.

### Coverage (`COVR`)

UInt32 ring count, then for each ring a UInt32 point count (≥ 3) and that many
{latE7, lonE7}. The closing point is not repeated. Zero padding to 8 bytes follows.

- Rings are combined with the even-odd rule. That is exact for non-overlapping
  polygons with holes, which is what one admin boundary is.
- Without `COVR`, a pack's coverage is the bounding box of its shape points.
- `build_roads --coverage` reads it from GeoJSON: a Polygon or MultiPolygon, a Feature
  holding one, or the first feature of a FeatureCollection.

## Grid

Every pack of a **family** shares one uniform grid: all packs built in one
`build_packs.sh` run from one extract, with the same grid box, cell size and radius.
The frame is linear in E7:

  x = (lonE7 − originLonE7) · kLon,  y = (latE7 − originLatE7) · kLat,
  cell = (⌊x / cellSizeM⌋, ⌊y / cellSizeM⌋).

- **Origin and scales:** the origin is the south-west corner of the family box. The
  scales are the true metres per E7 at the box's centre latitude, from the meridian
  and parallel radii of curvature on WGS-84 (`LocalTangentPlane`).
- **Family box:** the source extract's header bounding box (`osmium fileinfo -g
  header.boxes`), so every pack cut from that extract has the same grid ID.
- **Grid ID:** a cell means the same area in every pack of the family, and the grid ID
  tells whether two packs can be used together. `RoadNetwork` refuses packs with
  different grid IDs.

**Guaranteed radius.** A segment is listed in every cell whose rectangle lies within
R_eff frame metres of it:

  R_eff = `searchRadiusM` · s · (1 + 10⁻³) + 0.05 m,

- s is the frame's largest ratio of frame metres to true metres over the pack's
  latitudes, widened by one cell and two radii, and never below 1.
- The 10⁻³ and the 5 cm cover the straight-line approximations.

So every segment within `searchRadiusM` true metres of any point in a cell is in that
cell's list, and a query is **one lookup**: find the cell's key in `CELK` by binary
search, then read its range of `CELS`. A lookup also returns segments up to about a
cell diagonal plus R_eff away. The caller tests distance itself.

`build_roads --bench` measures the candidates per lookup (see "Measured").

s is computed per pack from its own latitudes. For a pack at the poleward edge of a
family box h degrees of latitude from the centre latitude φ₀, s ≈ cos φ₀ / cos(φ₀ + h).
For example, φ₀ = 45° and h = 2° give 1.037, so R_eff ≈ 52 m for R = 50 m.

**Why a grid with the radius baked in, not a 2 × 2 query or an R-tree:**
- The queries are fixed-radius around a compact particle cloud.
- One lookup per particle avoids branchy log-n descents.
- The flat sorted arrays memory-map directly and stay byte-stable across builder
  versions.

## Hash

`contentHash` = 64-bit FNV-1a (`NavigationSeed.fnv1a64`, as for `configHash`) over
the **whole file**, with bytes 16–23 (the hash field itself) read as zero.

- It covers the header, including the grid parameters, which change behaviour, the
  section table, every section and the padding. That includes all of `META`, so a
  pack's identity includes its provenance: `builder.commit`, the source's name,
  SHA-256 and timestamp, and the osmium version. `META` has no build time or host.
- **`builder.commit` is scoped to the builder.** `build_packs.sh` takes it from
  `git log -1 -- <builder paths>`, not from HEAD. The paths are
  `Core/Sources/DriveLoggerCore/Navigation/Roads`, `NavigationSeed.swift` and
  `LocalTangentPlane.swift` (FNV and the grid scales), `Log/JSONValue.swift` (META's
  encoding), `Core/Sources/RoadPackBuild`, `Core/Sources/build_roads`,
  `Core/Package.swift` and `tools/roads`. It appends `-dirty` when `git status
  --porcelain` lists any of them, which includes untracked files. So a commit
  outside those paths, such as a docs-only commit, leaves a rebuilt pack
  byte-identical; a commit inside them changes the hash even if the lookups are
  the same. That is deliberate: a pack names the builder that made it.
- It is an identity hash, not a security measure. The SHA-256 of the *source* extract
  is in `META`.
- A set of packs is identified by `roadSetHash`: FNV-1a 64 over the packs' content
  hashes, each as 8 little-endian bytes, in load order.

## Checks

- **On every open** (`RoadPack(contentsOf:verify: false)`, O(1)):
  - the magic;
  - the version (1 ≤ v ≤ current);
  - `headerSize`, and `fileSize` equal to the file's length;
  - the reserved field is 0;
  - the grid values are finite and > 0;
  - section bounds and order, and no overlap with the header or table;
  - required sections are present and unique;
  - record counts agree with lengths;
  - the CSR end markers;
  - `COVR` agrees with flag bit 0.
- **`verify()`** (the default for `RoadPack(contentsOf:)`, O(file size)), in addition:
  - the content hash;
  - `META` is a JSON object;
  - every EDGE field is in range, with no unknown class, flag bits or reserved bits;
  - edges are contiguous over `PNTS` and end at their nodes;
  - edges are sorted strictly by key;
  - `PTED` marks each point with its edge;
  - `ADJE` is ascending per node, incident to its node, and lists every edge at both
    ends;
  - `CELK` is strictly ascending;
  - `CELO` is strictly increasing;
  - `CELS` is ascending per cell and every entry is a segment start;
  - no segment has equal end points (see "Zero-length segments");
  - `COVR` parses.

  Replay runs it at every open. The app runs it once at import and caches the result
  by hash, size and modification time (N3.4).
- **Accessors** check their index and trap rather than read outside the mapping, so
  even an unverified pack cannot read past the file.

## Versioning

- A reader refuses a newer `formatVersion` (and 0).
- Unknown section tags are skipped, so an optional section needs no version bump.
- Changing a record layout, a field's meaning or the hash definition needs a new
  version. A reader keeps every version it ever read.
- **v1 changed once before any pack was distributed** (2026-10-12): `verify()` and
  the writer started refusing zero-length segments. No pack had left the build Mac,
  so v1 was amended instead of bumped. From the first distributed pack on, v1 is
  frozen.
- **The builder is deterministic:** the same OPL, in any line order, with the same
  builder version and the same parameters gives the same bytes.
  - It processes ways in ascending ID order.
  - It iterates no `Dictionary`.
  - It writes no time or host into `META`.
- `RoadPackBuild.builderVersion` is bumped when the output for the same input changes.
  Version 2 collapses equal-coordinate nodes (no zero-length segments).
- A pinned golden `contentHash` of a synthetic fixture
  (`RoadPackPropertyTests.goldenHash`) guards both.
- A new pack build is an engine input change. It is judged with the adoption rule like
  a config change, and a drive is always replayed with a named pack hash.

## Size limit

A pack is at most **150 MB** (150 000 000 bytes, decided Q1). `RoadPackWriter`
refuses to write a larger one, and `build_roads` exits with status 3 without writing
it. The app's import refuses one too (N3.4). A region pack over the limit is split at
`admin_level` 6.

## Builder

`build_roads` reads OPL with node locations on each way (`osmium
add-locations-to-ways -f opl`). It reads way lines only; node, relation and changeset
lines are skipped. It then applies these rules:

- **Classes:**
  - `--classes national`: `motorway`, `trunk`, `primary` and their `_link`s.
  - `--classes region` (the default): also `secondary`, `tertiary` and their links,
    plus `unclassified`, `residential`, `living_street`, `service` and `road`.
  - An explicit list is also accepted.
- **Excluded:** every other `highway` value (`track`, `footway`, `cycleway`, `path`,
  `pedestrian`, `steps`, `bridleway`, `construction`, `proposed`, `platform`,
  `raceway`, `bus_guideway`, …), `area=yes`, and `service=parking_aisle`, which leaves
  car parks to the off-road component. `access=private` is kept (Q5).
- **Direction:**
  - `oneway=yes|true|1` is forward-only.
  - `oneway=-1` (or `reverse`) reverses the geometry and is forward-only.
  - `motorway`, `motorway_link`, `junction=roundabout` and `junction=circular` imply a
    oneway, flagged oneway-implied, unless `oneway=no`.
  - `oneway=no|reversible|alternating`, and anything else, is two-way.
- **Level:** the `layer` tag clamped to −5…5 when it is an integer. Otherwise +1 for
  `bridge` (anything but `no`), −1 for `tunnel` (anything but `no`, including
  `building_passage`), otherwise 0.
- **Splitting:** a way is split into edges at topological nodes:
  - nodes used more than once among the kept ways (shared by two ways, or used twice
    by one, such as a closed ring);
  - the way's ends;
  - the neighbours of a node without a location. The segments touching that node are
    dropped. With `complete_ways` this does not happen.

  A closed way with no other junction becomes one edge from its node to itself.
- **Stacked nodes:** consecutive nodes of a way at equal E7 coordinates are collapsed
  and their IDs merged (see "Zero-length segments").

The pipeline that produces the OPL is under "Pipeline" below.

## Pipeline

Verified with osmium-tool 1.19.1 / libosmium 2.23.1 on a Geofabrik country extract.
`tools/roads/build_packs.sh [osm/packs.json]` runs the whole pipeline. The commands
it runs for one region pack, run by hand from the repository root, give the same
bytes:

```bash
SRC=osm/src/<country>-latest.osm.pbf; W=osm/work; P=<pack>; REL=<relationID>   # from osm/packs.json
TS=$(osmium fileinfo -g header.option.osmosis_replication_timestamp $SRC)       # e.g. 2026-01-01T00:00:00Z
BOX=$(osmium fileinfo -g header.boxes $SRC | tr -d '()')                         # family grid box
SHA=$(shasum -a 256 $SRC | cut -d' ' -f1)
osmium tags-filter -O $SRC w/highway=<classes> -o $W/roads.osm.pbf
osmium tags-filter -O $SRC r/boundary=administrative -o $W/admin.osm.pbf
osmium getid -O -r -t $W/admin.osm.pbf r$REL -o $W/boundary-$P.osm.pbf
osmium export -O $W/boundary-$P.osm.pbf --geometry-types=polygon -a type,id \
  -f geojsonseq -x print_record_separator=false -o $W/boundary-$P.geojsonseq
jq -c "select(.properties.\"@type\" == \"relation\" and .properties.\"@id\" == $REL) \
  | {type: \"Feature\", properties: {}, geometry}" $W/boundary-$P.geojsonseq > $W/boundary-$P.geojson
# extracts.json: {"extracts": [{"output": "<pack>.osm.pbf",
#   "polygon": {"file_name": "boundary-<pack>.geojson", "file_type": "geojson"}}, ...]}
osmium extract -O -c $W/extracts.json -d $W --strategy complete_ways $W/roads.osm.pbf  # all regions, one pass
osmium add-locations-to-ways -O $W/$P.osm.pbf -f opl -o $W/$P.opl
cd Core && swift run -c release build_roads ../$W/$P.opl --classes region --grid-bbox "$BOX" \
  --osm-timestamp "$TS" --source-sha256 $SHA --osmium-version 1.19.1 --strategy complete_ways \
  --coverage ../$W/boundary-$P.geojson --relation-id $REL --admin-level 4 \
  --out ../osm/packs/$P.roadpack
swift run -c release build_roads --info ../osm/packs/$P.roadpack --bench 100000
swift run -c release build_roads --network ../osm/packs/national.roadpack ../osm/packs/$P.roadpack
```

The national pack is not cut by a polygon. It takes its classes from `roads.osm.pbf`
(`osmium tags-filter $W/roads.osm.pbf w/highway=motorway,…,primary_link`), so it
keeps the extract's border spillover. Its coverage polygon is the country relation,
exported as above.

What N3.1 found wrong in the plan's first draft of these commands:
- **The polygon from `getid -r`.** `osmium getid -r` on an admin relation also pulls in
  its `subarea` member relations with their tags. Used as `osmium extract`'s polygon,
  that OSM file merges every boundary in it. Here that was the region plus 10
  admin_level-10 subareas, overlapping, which the man page calls undefined. The
  extract kept 970 ways instead of 55 278.
  - `-t` (`--remove-tags`) strips the tags of everything not asked for, which leaves one
    polygon.
  - The pipeline goes further and exports that one relation to a single-feature
    GeoJSON with `osmium export` and `jq`. The same file then serves as the extract
    polygon and as the pack's `COVR`, so the builder needs no OSM-XML polygon reader.
- **Output paths.** In config mode `osmium extract` writes outputs relative to the
  **current directory**, not the config file's, unless `"directory"` or `-d` is given.
  Polygon `file_name`s are relative to the config file. Without `-d`, the outputs
  landed in the working directory and `add-locations-to-ways` found no input.
  `build_roads` now refuses an empty pack, so this cannot pass silently.
- **Grid box and timestamp come from the source.** `osmium extract` output carries
  neither the source's header bounding box nor its replication timestamp, so both are
  read from the source. `fileinfo -g header.option.osmosis_replication_timestamp`
  returns the ISO 8601 time, and `build_roads --osm-timestamp` accepts it as is.
- **`-O`** (`--overwrite`) is needed on every re-run. osmium otherwise refuses to
  replace an existing output.
- `--coverage` takes the GeoJSON polygon, not the `getid` OSM file.

## Measured

N3.1, osmium 1.19.1, `build_roads` release on an Apple-silicon Mac. Source: one
Geofabrik country extract. Packs are named by alias only.

| pack | ways kept | nodes | edges | segments | cells | cell entries (per segment) | size | build_roads | verify |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| national (motorway/trunk/primary + links) | 49 685 | 48 808 | 56 163 | 369 250 | 1 342 432 | 4 033 617 (10.9) | 41.3 MB | 1.5 s | 69 ms |
| region-A (admin_level 4, every drivable class) | 51 070 | 72 050 | 86 671 | 231 390 | 106 345 | 1 782 883 (7.7) | 17.3 MB | 0.5 s | 29 ms |

Notes on the table:
- **Dropped from region-A:** 4 192 ways for `service=parking_aisle` and 16 for
  `area=yes`.
- **Time:** the whole script for both packs takes 20 s. Most of it is the two
  `tags-filter` passes over the country file, about 5 s and 4 s.
- **Determinism:** a second run gives byte-identical packs.
- **Builder v2 (zero-length segments, 2026-10-12):** neither pack has a stacked
  or repeated node: 0 points at a repeated coordinate and 0 node IDs merged, which
  an independent scan of the OPL confirms. Every count in the table is unchanged;
  only `META` (`builder.version` 2 and the commit) and so the content hashes
  changed. A docs-only commit after the rebuild left both packs byte-identical.
- **De-duplication:** both packs share one grid ID. Loaded together, region-A has
  11 415 segments shadowed by national, which is exactly its motorway/trunk/primary
  segments, counted independently from the OPL. The count is the same in the reverse
  order.
- **Size:** both packs are well under 150 MB.

**Lookup bench:** `--bench 200000`, seed 1. Each query is a random point within 50 m
of a random segment, which is how particles near a road would be placed.
- "Lookup + distance" covers the cell search plus the frame conversion and
  point–segment distance for every candidate.
- "Cell search" is the `CELK` binary search and the `CELO` range alone.
- Region-A times are the median of 3 runs. National is a single run.

| pack, cell | candidates p50 / p95 / max (mean) | within 50 m (mean) | lookup + distance | cell search | cells | size | build_roads |
|---|---|---:|---:|---:|---:|---:|---:|
| region-A, 32 m | 20 / 47 / 141 (22.3) | 13.3 | 717 ns | 92 ns | 394 720 | 32.2 MB | 0.96 s |
| **region-A, 64 m** | **28 / 64 / 175 (31.3)** | 13.3 | **740 ns** | 69 ns | 106 345 | **17.3 MB** | 0.53 s |
| region-A, 128 m | 49 / 104 / 208 (52.8) | 13.3 | 1002 ns | 51 ns | 29 486 | 12.6 MB | 0.38 s |
| national, 64 m | 6 / 37 / 176 (10.9) | 6.2 | 568 ns | 134 ns | 1 342 432 | 41.3 MB | 1.5 s |

**Default cell size: 64 m, unchanged.**
- 32 m cuts the candidates by about 30 % (p95 47 vs 64). It almost doubles the pack
  (32.2 vs 17.3 MB, with CELS at 2.6× as many entries) and is no faster per lookup:
  the larger index costs as much in cache misses as the fewer candidates save.
- 128 m is 35 % slower per lookup and puts p95 at 104 candidates, above the 64 per
  particle that N3.2's perf test allows (docs/N3_PLAN.md, N3.2 test 14). It saves only
  4.7 MB.
- At 64 m, p95 is exactly 64 in the densest pack. The N3.2 budget therefore needs the
  heading test before the distance test, as planned, and the cell cache's plane
  segments, not the per-candidate E7 conversion measured here.
