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
| `roadsSelection` (within v2) | a road selection attempt, when its outcome is known and it differs from the last such line; identical repeats as one line, at the next change, at an attach or at the end | `t`, `afterInputs`, `recordedAfterInputs`, `request` (`radiusM`), `candidates` (per pack file: `name`, `state`, `reason` or `covering`; absent for `unfinished`), `outcome`, `packs` (optional), `reason` (optional), `repeats` and `firstT` (optional, a line of repeats only) |

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
- **roadsSelection** (within v2, no version bump): the road selection
  attempts, so a drive whose roads never attached can be diagnosed
  afterwards. Diagnostic only: never an input to `--compare`. Written
  where the outcome became known: in the app the selection runs
  asynchronously, so the line can come some inputs after the request.
  Several lines are allowed. Built by Core (`RoadPackSelection.attempt`,
  `LiveNavigationRun.finishSelection`, `LiveNavigationRun.closingLines(inFlight:)`,
  `NavSidecar.RoadsSelectionLog`), which the app and `replay_nav` share.
  - **Repeats.** An attempt is written only when it is not the same
    attempt as the last `roadsSelection` line written
    (`RoadsSelection.isRepeat(of:)`: the same `outcome`, `packs`, `reason`
    and `candidates`, with `covering`). The first attempt of a run is
    always written at once, so a killed app still has it. Later identical
    attempts are counted, not written. They are written as **one** line
    when the next line is written, before it: at an attempt that differs,
    at an attach (before the `selected` line, which is always written, and
    the `roads` line after it), and at the end of the recording (before an
    `unfinished` line, then the sidecar closes). That line is the last
    repeat's line (its `t`, `afterInputs`, `recordedAfterInputs`,
    `request` and the rest) plus:
    - `repeats`: the number of attempts the line stands for, ≥ 2;
    - `firstT`: the request `t` of the first of them, session-clock ns.

    Both keys are absent from a line for one attempt, so a single repeat
    is a plain line. The `t`, input counts and radius of the repeats
    before the last are not kept. A line of repeats sits where it was
    written, so its `recordedAfterInputs` (the last repeat's) can be
    smaller than that of the line before it. Killing the app loses the
    count of the repeats not yet written; the attempt they repeat is on
    disk. Example (keys sorted, as written):

    ```json
    {"afterInputs":2311,"candidates":[{"covering":false,"name":"far.roadpack","state":"verified"}],"firstT":75012345678,"kind":"roadsSelection","outcome":"noneCovering","recordedAfterInputs":2311,"repeats":1460,"request":{"radiusM":1414.2},"t":1987654321098}
    ```
  - `t`, `afterInputs`: the request's (`RoadSelectionRequest`), where the
    attempt was raised: the engine's latest accepted arrival and the
    inputs handed to the run then. A request is always raised after an
    input, so `t` is never omitted.
  - `recordedAfterInputs`: the inputs handed to the run when the outcome
    was recorded, which is where the line sits in the file (a line of
    repeats: where its last repeat was recorded). In a synchronous replay
    it equals `afterInputs`.
  - `request`: `radiusM` only, the request's 95 % semi-major axis. The
    request's centre is never written. Non-finite values follow the
    string rule above.
  - `candidates`: one per pack file the selection knew about. First the
    verified packs in candidate order with `state` `"verified"` and
    `covering` (their coverage intersects the request's circle; `false`
    for an unusable request), then the files refused when they were
    scanned or opened with `state` `"refused"` and `reason`. In the app
    `name` is the file name. `replay_nav` uses the `--roads` file names in
    name order, as the app's library lists them. Absent for `unfinished`.
  - `outcome`, checked in this order:
    - `unusableRequest`: the circle is unusable (non-finite, negative
      radius, out of range).
    - `noPacks`: no verified pack at all. There were no files, or every
      file was refused at the scan (`candidates` tells which).
    - `noneCovering`: verified packs exist, none covers the circle.
    - `refused`: the covering set is not used, with `packs` and `reason`.
      Either its network cannot be built (different grids, the same pack
      twice), or the run refused this set before (it is not built again;
      the earlier reason is repeated), or the run refused the attach
      (`RoadAttachRefusal`, e.g. the config would change).
    - `selected`: the covering set attached (`packs`: their names). Its
      `roads` line follows immediately.
    - `unfinished`: the attempt was still in flight when the recording
      ended. The app writes it last, after any pending repeats, before
      closing the sidecar.
    `outcome` and `state` are open string sets: a reader keeps a value
    it does not know.
  - `packs`: the pack names involved, for `selected` and `refused`.
  - `reason`: why, for `refused`.
  - Without packs to select from (no road pack library in the app; no
    `--roads` in `replay_nav`) there are no attempts and no lines.
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
| 2 | N3.3: the `roads` line and the estimate's optional `onRoadShare`. The header is unchanged in shape (written at Start, before any position, so it cannot name the packs). The app always writes v2. A v1 reader refuses v2: it would skip the `roads` line and hide which packs the run used. Within v2, with no version bump: the `roadsSelection` line. It is a new line kind and diagnostic only, never an input to `--compare`, so a v2 reader that predates it skips and counts it (the new-line-kind rule below). Its optional `repeats` and `firstT` (identical repeats folded into one line; before them, one line per attempt) are also within v2: a reader that predates them decodes such a line and ignores the two keys (the optional-field rule below), so it sees one attempt where the line stands for `repeats`. |

The rules for a change:
- A new **optional** field that a reader can ignore without misreading
  anything else stays in the current version. It must be diagnostic or
  descriptive, never an input to `--compare`. Every reader of that version
  decodes it, because the header and line types ignore keys they do not
  know, and a missing key decodes as nil. `buildConfiguration` and the
  `roadsSelection` line's `repeats` and `firstT` are such fields.
- A field whose absence or whose being ignored would mislead a reader needs
  a version bump. A reader refuses a newer version. Examples: something
  `--compare` must check, or a change in what an existing field means.
  The road-pack hashes of v2 (the `roads` line) are such a change.
- A new line kind is skipped and counted by older readers (`Unknown kinds`
  below). If it is diagnostic only, like `roadsSelection`, it stays in the
  current version.

## Writing

The header is flushed at once. Later lines are buffered and flushed every 10 s
on the service actor, then flushed and closed when the recording's feed ends
(on stop or on a write failure). A write error stops the sidecar, never the
navigation or the recording. Killing the app loses at most the last 10 s, and
can leave a partial last line.

The size is about 365 bytes per estimate, so about 1.3 MB per hour. That is
more than the 100 KB/h the N4 plan estimated, because values are written at
full precision for an exact compare.

A `roadsSelection` line is about 230 bytes with one pack file, plus about
60 per further file; a line of repeats about 30 more. While no pack covers
the car, every position the engine uses raises an attempt. In the app,
requests that arrive while one is in flight are merged. Identical attempts
share one line (repeats, above), so a run of them costs two lines however
long it is: the first attempt and the repeats. Replayed with one pack that
never covers (`--write-sidecar`), drive-8 has 1461 attempts over 35
minutes: 2 lines, 489 bytes, 0.06 % of its 764 KB sidecar. Written one line
per attempt, before repeats were folded, they took 1461 lines and 341 KB,
about 45 % on top of its estimates. Every change of outcome or candidates
(a pack becomes covering, a file appears or is refused) starts a new run.
Once roads attach there are no more attempts.

## Reading

`NavSidecar.read(_:)` checks the following:
- The first line must be a `header` with a version this reader knows (1 or
  2); a newer version is refused.
- A second `roads` line is refused (`duplicateRoadsLine`): a run attaches
  roads once.
- `roadsSelection` lines are a known kind (`Contents.roadsSelections`, in
  file order), any number of them; they are not counted as unknown. A line
  stands for `RoadsSelection.attempts` attempts (`repeats`, else 1).
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
  error rows: the live engine saw them, the file does not hold them);
- the road selection attempts (`roadsSelection`) of each side that has
  them, under `Selection`: the number of attempts (and of lines, when
  repeats were folded), then one compact row per line (`t`, `afterInputs`,
  `recordedAfterInputs` if different, radius, outcome, packs and reason,
  the candidates' counts and scan refusals; a line of repeats ends in
  "(×N, t a–b s)"). Consecutive lines of the same attempt (the writer's
  rule, `RoadsSelection.isRepeat(of:)`: they differ only in `t`, the input
  counts and the radius) are folded into the first row and the number of
  attempts the others stand for, "(and N more like it to t b s)". A sidecar
  written one line per attempt, before repeats were folded, gives the same
  rows, so a drive whose packs never cover stays readable either way. They
  are printed, never compared: they change neither the matching nor the
  verdict.

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
line there. The selection attempts are `roadsSelection` lines, repeats
folded as the app folds them, the pending ones written at the end;
`replay_nav` prints the number of lines and of attempts. The replay
selects synchronously, so `recordedAfterInputs` equals `afterInputs`.
