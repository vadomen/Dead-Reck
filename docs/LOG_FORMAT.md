# Log format

> Stub. The authoritative definition is the code in
> `Core/Sources/DriveLoggerCore/Log/`; this document will describe it in full.

Current version: **1** (`LogFormatVersion.current`).

## Structure

JSON Lines (UTF-8, one JSON object per line, newline-terminated).

- **Line 1:** header (`LogHeader`) — format version, session ID, wall-clock
  start time (ISO 8601), reference uptime, app and device identity, optional
  notes.
- **Every following line:** one event (`LogEvent`):

  ```json
  {"data":{...},"kind":"obd","t":3000000}
  ```

  - `t` — nanoseconds since the session start, on a single monotonic clock
    shared by all sensors.
  - `kind` — `motion`, `location`, `obd` or `marker`.
  - `data` — the sample for that kind.

## Compatibility

- Every format version ever written stays readable.
- Unknown event kinds are preserved, not dropped.
- A header with a newer format version than the reader knows is rejected.

## TODO

- Field-by-field reference for each event kind, with units.
- Changes needed for v1 recording goals not yet in the format (see README):
  OBD request timestamps, barometer samples.
