# Navigation sidecar `<recording>.nav.jsonl` (N4 B)

While a recording runs, the app's `NavigationService` writes what the live
dead reckoning showed the driver into a companion file next to the recording.
`Drive_<stamp>.jsonl.gz` gets `Drive_<stamp>.nav.jsonl` (`NavSidecarFile`). The
sidecar exists so that `replay_nav --as-live --compare` can prove a Mac replay
reproduces the drive exactly, or explain why it does not.

- It is separate from the log format and versioned on its own (`NavSidecar.version`,
  currently 2). The logger and `inspect_log` never read it. `LogStore` shares
  and deletes it together with its recording. `.gitignore` covers it
  (`*.jsonl`), and it holds real positions, so it stays private like the
  recording.
- Types, writer and reader: `Core/Sources/DriveLoggerCore/Navigation/NavSidecar.swift`.
  The per-recording loop that produces the lines is `LiveNavigationRun`. The
  app and `replay_nav` run that same code.

## Lines

JSON Lines, one object per line, keys sorted, each object with a `kind`.
Times `t` are session-clock nanoseconds, as in the log. Doubles are written
at full precision, so a replay can match them bit for bit. Non-finite numbers
are written as the strings `"inf"`, `"-inf"` and `"nan"`.

| kind | when | fields |
|---|---|---|
| `header` | first line, written and flushed at Start | `sidecarVersion`, `sessionID`, `seed`, `configHash`, `configJSON`, `appBuild`, `buildConfiguration` (optional) |
| `estimate` | each whole second of session time, from the engine's initialisation on | `t`, `latitude`, `longitude`, `headingDeg`, `headingStdDeg`, `semiMajorM`, `semiMinorM`, `orientationDeg` (95 % ellipse), `converged`, `speedScale`, `droppedInputs`, `msPerStep`, `maxStepMs`, `onRoadShare` (v2, optional) |
| `pin` | at each confirmed manual fix (`manualFix` row) | `t` (the fix's), `latitude`, `longitude` (where the driver put the pin), `mapSpanM`, `prior` (an `estimate` object: the engine just before it ingested the pin; absent when the pin initialised the engine) |
| `roads` (v2) | once, when a road network becomes active | `t` (optional), `afterInputs`, `roads` (per pack: `contentHash`, `formatVersion`, `osmTimestamp`, `gridID`), `roadSetHash` |

- **seed** is `NavigationSeed.derive(header:)`: the 64-bit FNV-1a hash of the
  UTF-8 bytes of the header's `sessionID.uuidString`. It is a JSON integer up
  to 2⁶⁴ − 1.
- **configJSON** is `NavigationConfig.canonicalJSON()` as text: compact, with
  sorted keys. **configHash** is FNV-1a 64 of those bytes, as 16 hex digits.
  The app runs the default config with the derived seed.
- **buildConfiguration**: `"debug"` or `"release"`, the configuration of the
  app build that wrote the sidecar (the app sets it from `#if DEBUG`). It
  tells you how to read `msPerStep` and `maxStepMs`, which describe
  phone performance only in a Release build. Treat it as an open string set.
  It is absent from sidecars written before the field existed and from
  `replay_nav --write-sidecar`, and readers decode it as nil ("not
  recorded"). It is not compared. `replay_nav --compare` shows it on its
  `Sidecar` line after the app build.
- **estimate**: what `NavigationEngine.estimate(at: t)` returned at that grid
  second, from the engine state before the first input arriving at or after
  `t`. Position is latitude/longitude, not plane east/north, which jump when
  the plane re-anchors.
- **onRoadShare** (v2): `NavigationEstimate.onRoadShare`, the weight share
  of the cloud on a road at the last road update. The key is omitted when
  it is nil (no roads, or no road update yet), so a no-roads `estimate` line
  is byte-identical to a v1 line.
- **roads** (v2): written once, when the run attaches a road network
  (`LiveNavigationRun.attachRoads`, docs/NAVIGATION.md "Live in the app").
  A v2 sidecar without a `roads` line used no roads. Its line comes where
  the attach happened: right after the header for a network given at
  Start, else between the lines of the inputs before and after it.
  - `afterInputs`: the number of navigation inputs the run had been handed
    (`LiveNavigationRun.inputs`, a rejected time jump included) before the
    attach; the network is used from the next input on. 0: before the
    first input.
  - `t`: the engine's latest accepted arrival at the attach
    (`NavigationEngine.latestArrival`, session-clock ns): the arrival of
    the last input before it, unless that input was rejected as an
    implausible time jump. Omitted when `afterInputs` is 0.
  - `roads`: the packs in canonical order (ascending content hash), as
    `replay_nav` results record them: `contentHash` and `gridID` as 16
    lowercase hex digits, `formatVersion` an integer, `osmTimestamp` Unix
    seconds (0 unknown).
  - `roadSetHash`: FNV-1a 64 over the packs' content hashes in ascending
    order, 16 lowercase hex digits (`RoadNetwork.roadSetHashHex`).
  - Data: © OpenStreetMap contributors, ODbL 1.0.
- **Not compared** by `--compare`:
  - `droppedInputs`: navigation inputs the live feed had dropped by then
    (`NavigationTap.droppedInputs`). The feed buffers 4096 inputs and drops the
    oldest when the engine falls further behind.
  - `msPerStep` / `maxStepMs`: engine time per 10 Hz step, as an EMA and a
    maximum, to the microsecond.
- **Gaps**: when every input is silent for more than 600 s (the app was
  suspended), only the first 600 seconds of the gap are written, and the grid
  then resumes at the next input. An input rejected as an implausible time
  jump (B0-1) writes nothing.

## Versions

| Version | Changes |
|---|---|
| 1 | Header, `estimate` and `pin` as above. Within v1, with no version bump: the header's optional `buildConfiguration`. |
| 2 | N3.3: the `roads` line and the estimate's optional `onRoadShare`. The header is unchanged in shape (written at Start, before any position, so it cannot name the packs). The app always writes v2. A v1 reader refuses v2: it would skip the `roads` line and hide which packs the run used. |

The rules for a change:
- A new **optional** field that a reader can ignore without misreading
  anything else stays in the current version. It must be diagnostic or
  descriptive, never an input to `--compare`. Every reader of that version
  decodes it, because the header and line types ignore keys they do not
  know, and a missing key decodes as nil. `buildConfiguration` is such a
  field.
- A field whose absence or whose being ignored would mislead a reader needs
  a version bump. A reader refuses a newer version. Examples: something
  `--compare` must check, or a change in what an existing field means.
  The road-pack hashes of v2 (the `roads` line) are such a change.
- A new line kind is skipped and counted by older readers (`Unknown kinds`
  below).

## Writing

The header is flushed at once. Later lines are buffered and flushed every 10 s
on the service actor, then flushed and closed when the recording's feed ends
(on stop or on a write failure). A write error stops the sidecar, never the
navigation or the recording. Killing the app loses at most the last 10 s, and
can leave a partial last line.

The size is about 365 bytes per estimate, so about 1.3 MB per hour. That is
more than the 100 KB/h the N4 plan estimated, because values are written at
full precision for an exact compare.

## Reading

`NavSidecar.read(_:)` checks the following:
- The first line must be a `header` with a version this reader knows (1 or
  2); a newer version is refused.
- A second `roads` line is refused (`duplicateRoadsLine`): a run attaches
  roads once.
- A last line that does not decode is dropped and reported
  (`truncatedLastLine`). Any other bad line throws.
- Unknown kinds are skipped and counted.

## Compare

```bash
cd Core
swift run -c release replay_nav <recording> --as-live --compare <recording>.nav.jsonl \
  [--roads <pack.roadpack>]... [--tolerance <m>] [--heading-tolerance <deg>] --out ../logs/out
```

`--compare` matches estimates by `t` and pins by `t` and order. It reports:
- the maximum position (m), heading and heading σ (°), ellipse axes (m),
  ellipse orientation (°) and speed-scale differences;
- the largest `onRoadShare` difference (1 where only one side has one): part
  of the exact check, not gated by the tolerance;
- converged-flag mismatches;
- the first `t` that differs;
- unmatched lines;
- the sidecar's `droppedInputs`;
- the recording's navigation rows that failed to encode (`encodingFailed`
  error rows: the live engine saw them, the file does not hold them).

A seed or config-hash mismatch is a warning, and the differing config keys are
listed. When neither side used roads (no `roads` line in the sidecar, none
attached in the replay), keys in `NavigationConfig.roadOnlyKeys` (every
`road*` key) change nothing: they are listed as inert in a `Note`, not
blamed as a cause, and do not affect the verdict (N3-CMPHASH, closed in
N3.3). A sidecar written before `roadCorrelationM` became 100 compares that
way.

**Roads (v2).** The replay's road packs are `--roads` (each fully verified):
- the sidecar has a `roads` line: the given packs, all of them as one
  network, are attached after its `afterInputs` inputs;
- it has none (v1, or v2 without roads) and packs are given: the live rule
  (`replay_nav --as-live --roads`, docs/NAVIGATION.md);
- it has none and no packs are given: as before roads existed.

A `Roads` line names both sides' `roadSetHash` and `afterInputs`. The roads
**match** only when the sidecar's `roadSetHash` equals the given packs' and
the replay's `roads` line equals the sidecar's. Otherwise (another set,
packs on one side only, another attach point) a `Warning` names the hashes,
the mismatch is listed as a known cause, and the verdict is at best
**PASS within tolerance**, never exact: an unknown pack must not hide a
difference.

**Verdict:**
- **PASS (exact)** when every compared field is identical bit for bit and
  the roads match (or neither side used any).
- **PASS within tolerance** when every difference is within `--tolerance`
  (default 1 m for position and ellipse axes) and `--heading-tolerance`
  (default 0.1°) and nothing is unmatched.
- **FAIL** otherwise, with exit status 4.

Any non-exact result names its known causes (drops, encoding failures, a
different road set or attach, seed or config, truncation), or says there is
none.

Exact equality between an arm64 Mac and an iPhone is not verified yet (R13.1-7,
docs/PLAN.md §6), which is why a tolerance exists. Within one machine the
result is exact: on the Mac for a real drive, and in the app tests on the iOS
simulator, where the service's sidecar matches the Core loop.

`--write-sidecar <path>` writes the sidecar the app would have written for a
recording, with no drops. It uses the same loop with file order, the header
seed and the default config, to check `--compare` end to end on a Mac. With
`--roads` it attaches them by the live rule (the app with its packs ready),
at the same input as the `--as-live` metrics replay, and writes the `roads`
line there.
