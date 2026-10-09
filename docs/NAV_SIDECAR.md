# Navigation sidecar `<recording>.nav.jsonl` (N4 B)

While a recording runs, the app's `NavigationService` writes what the live
dead reckoning showed the driver into a companion file next to the recording.
`Drive_<stamp>.jsonl.gz` gets `Drive_<stamp>.nav.jsonl` (`NavSidecarFile`). The
sidecar exists so that `replay_nav --as-live --compare` can prove a Mac replay
reproduces the drive exactly, or explain why it does not.

- It is separate from the log format and versioned on its own (`NavSidecar.version`,
  currently 1). The logger and `inspect_log` never read it. `LogStore` shares
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
| `header` | first line, written and flushed at Start | `sidecarVersion`, `sessionID`, `seed`, `configHash`, `configJSON`, `appBuild` |
| `estimate` | each whole second of session time, from the engine's initialisation on | `t`, `latitude`, `longitude`, `headingDeg`, `headingStdDeg`, `semiMajorM`, `semiMinorM`, `orientationDeg` (95 % ellipse), `converged`, `speedScale`, `droppedInputs`, `msPerStep`, `maxStepMs` |
| `pin` | at each confirmed manual fix (`manualFix` row) | `t` (the fix's), `latitude`, `longitude` (where the driver put the pin), `mapSpanM`, `prior` (an `estimate` object: the engine just before it ingested the pin; absent when the pin initialised the engine) |

- **seed** is `NavigationSeed.derive(header:)`: the 64-bit FNV-1a hash of the
  UTF-8 bytes of the header's `sessionID.uuidString`. It is a JSON integer up
  to 2⁶⁴ − 1.
- **configJSON** is `NavigationConfig.canonicalJSON()` as text: compact, with
  sorted keys. **configHash** is FNV-1a 64 of those bytes, as 16 hex digits.
  The app runs the default config with the derived seed.
- **estimate**: what `NavigationEngine.estimate(at: t)` returned at that grid
  second, from the engine state before the first input arriving at or after
  `t`. Position is latitude/longitude, not plane east/north, which jump when
  the plane re-anchors.
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
- The first line must be a `header` with a version this reader knows; a newer
  version is refused.
- A last line that does not decode is dropped and reported
  (`truncatedLastLine`). Any other bad line throws.
- Unknown kinds are skipped and counted.

## Compare

```bash
cd Core
swift run -c release replay_nav <recording> --as-live --compare <recording>.nav.jsonl \
  [--tolerance <m>] [--heading-tolerance <deg>] --out ../logs/out
```

`--compare` matches estimates by `t` and pins by `t` and order. It reports:
- the maximum position (m), heading and heading σ (°), ellipse axes (m),
  ellipse orientation (°) and speed-scale differences;
- converged-flag mismatches;
- the first `t` that differs;
- unmatched lines;
- the sidecar's `droppedInputs`;
- the recording's navigation rows that failed to encode (`encodingFailed`
  error rows: the live engine saw them, the file does not hold them).

A seed or config-hash mismatch is a warning, and the differing config keys are
listed.

**Verdict:**
- **PASS (exact)** when every compared field is identical bit for bit.
- **PASS within tolerance** when every difference is within `--tolerance`
  (default 1 m for position and ellipse axes) and `--heading-tolerance`
  (default 0.1°) and nothing is unmatched.
- **FAIL** otherwise, with exit status 4.

Any non-exact result names its known causes (drops, encoding failures, seed
or config, truncation), or says there is none.

Exact equality between an arm64 Mac and an iPhone is not verified yet (R13.1-7,
docs/PLAN.md §6), which is why a tolerance exists. Within one machine the
result is exact: on the Mac for a real drive, and in the app tests on the iOS
simulator, where the service's sidecar matches the Core loop.

`--write-sidecar <path>` writes the sidecar the app would have written for a
recording, with no drops. It uses the same loop with file order, the header
seed and the default config, to check `--compare` end to end on a Mac.
