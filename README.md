# FuGPS (Dead-Reck)

## What it is

In Kyiv, GPS is regularly jammed or spoofed, which makes phone navigation in a
car unusable. FuGPS is an iPhone app that keeps showing the car's position
without GPS, using dead reckoning: vehicle speed from the car's OBD-II port,
heading from the phone's gyroscope, a particle filter, and an offline
OpenStreetMap road network to keep the estimate on the roads. GPS is used
while it can be trusted; the driver can also correct the position by hand at a
stop.

**Names.** FuGPS is the public name (App Store, website). DriveLogger is the
working name the code still uses: the Xcode project and schemes, the
`DriveLoggerCore` package and, for now, the app's display name.

The app has two modes:

- **Navigate** (daily use, the default). Starts on its own when the OBD
  adapter connects and feeds the navigation engine. **It writes nothing**: no
  recording, no file.
- **Record** (test drives, in Settings). Records synchronized raw sensor data
  plus what the navigator showed (the `.nav.jsonl` sidecar), so a drive can be
  replayed on a Mac and the engine developed and tuned offline.

What a recording contains:

- **OBD-II** via a BLE ELM327-compatible adapter: vehicle speed (PID `0x0D`)
  and engine RPM (PID `0x0C`), with request and response timestamps.
- **Phone motion** at 100 Hz from Core Motion device motion: user
  acceleration, rotation rate, gravity, attitude; plus magnetometer and
  barometer.
- **GPS fixes** as recorded; the engine uses them only while they look clean.
- **Manual fixes** (pins) the driver placed on the map.

All streams are timestamped against a single monotonic clock so they can be
aligned when replayed. Capture fidelity comes first: the log is the source of
truth, and live navigation never changes what is recorded.

## Status

Experimental. Preparing for TestFlight and the App Store
([docs/RELEASE_PLAN.md](docs/RELEASE_PLAN.md)): Ukraine only, free,
Ukrainian and English.

| Part | State |
|---|---|
| Logger (M0–M4) | Done. Bench-tested on the iPhone in the test car ([2026-10-07](docs/BENCH_TEST_2026-10-07.md), [2026-10-08](docs/BENCH_TEST_2026-10-08.md): ~16.4 OBD exchanges/s, p50 latency 59 ms) and used on real drives in Kyiv, including GPS-jammed ones. |
| Navigation engine (N2–N3.3) | Done. Particle filter with OSM road matching; proven on the recorded acceptance drives with `replay_nav`, live and replayed giving the same result. Numbers: [docs/NAVIGATION.md](docs/NAVIGATION.md) ("N3.3: roads live" and later). |
| Live navigation in the app (N4, UX-1, UX-2…UX-6) | Done in code: Navigate mode, map with the dead-reckoning dot and ellipse, manual fixes, speed-dependent zoom, Settings behind a gear on the map. The device checks in [docs/PLAN.md](docs/PLAN.md) §6 (including 1 h of Navigate: memory, battery, thermal) are still open. |
| Road packs (N3.4, UX-8) | Done in code: 28 packs (all of Ukraine + 27 regions) hosted; the app downloads them by region (first launch, Settings → Maps, an offer at a stop when you drive out of coverage) into its private store. Device checks in PLAN §6 are open. |
| Open | Navigation without OBD (NAV-NOOBD, then maybe UX-7), a "GPS off" switch for spoofing (UX-9), fit the whole ellipse under jamming (UX-10), notice of an interrupted recording (UX-11). See [docs/BACKLOG_UX.md](docs/BACKLOG_UX.md) and [docs/BACKLOG.md](docs/BACKLOG.md). |

## How it works

- **Predict** at 10 Hz on the session clock: OBD speed times a per-vehicle
  scale factor, heading from the gyroscope. 2000 particles, each carrying a
  heading, a speed scale and a Gaussian position.
- **Update** with whatever is available: clean GNSS fixes, network fixes,
  manual fixes (pins) and the road network (map matching against the
  installed road packs).
- **Show** the estimate with its 95 % ellipse. When GPS is jammed the ellipse
  grows honestly until a road, a fix or a pin shrinks it.
- **Causal and deterministic.** The same recording and seed give the same
  output, so `replay_nav --as-live --compare` reproduces on a Mac exactly what
  the phone showed.
- **Same code everywhere.** The engine lives in `DriveLoggerCore`
  (Foundation only) and runs unchanged in the app and in `replay_nav`.
  MapKit is only the base map: no Apple routing or search is used.

Details: [docs/NAVIGATION.md](docs/NAVIGATION.md). Open plans:
[docs/N3_PLAN.md](docs/N3_PLAN.md), [docs/N4_PLAN.md](docs/N4_PLAN.md).

## Hardware

- iPhone running iOS 17 or later.
- Vgate iCar Pro Bluetooth 4.0 (BLE, ELM327-compatible) OBD-II adapter.
- Test vehicle: VW Touareg (2025). The OBD speed scale prior is measured on
  this car; another car needs its own value.
- A rigid phone mount. The phone must stay in one fixed orientation (portrait)
  for the whole drive — the motion data is in the phone's reference frame,
  and any movement of the phone in the mount corrupts it.
- Navigate needs the screen on: with the phone locked the app is suspended
  and resumes when unlocked (no background location in Navigate). Record keeps
  recording with the screen locked.

## Screens

No tab bar, portrait only: the app is the full-screen **Map**, and a gear in
the map's right rail opens **Settings** full screen (Done returns to the map
with the camera mode unchanged). Sessions is a row inside Settings Developer (in Release behind the gate).
On the first launch it shows four skippable cards (how FuGPS works,
connect your adapter, mount the phone, getting the arrow fast; no
checkboxes) and then "Road maps" (pick which packs to download, see
[Road packs](#road-packs)), each once; Skip goes straight to the maps step.
Settings → "How FuGPS works" shows the cards again and "Mount and
orientation" shows the mounting text. At the first Navigate start on OBD
with the car standing, a one-time card asks "Phone mounted and won't move?"
(Mounted), once calibration has ended. The last card has no Skip. A phone that confirmed the old checklist sees neither.

- **Map.** The dead-reckoning dot with its 95 % ellipse, the GPS track for
  reference. A compact card top left holds the speed with GPS and OBD
  indicators (thermal only when not nominal) and, during a test recording,
  the recording row; a right rail holds North up / Heading up, Following
  (re-centres on its own 8 s after you pan) and the Settings gear; the car
  sits in the lower third in heading-up. The indicator of the current speed
  source (OBD or GPS) is shown bold; a failed one ("No GPS", "OBD lost") has
  a slashed glyph and a warning colour. The
  zoom follows speed (≈250 m when slow to ≈1500 m at 110+ km/h). Bottom left,
  above the bottom edge: the at-a-stop offer, toasts and a one-line
  status: "Hold still — calibrating" with a countdown, "OBD lost —
  reconnecting" with "Stops in m:ss", or "Connect OBD for navigation without
  GPS" (then only the plain GPS position is shown), and a road-pack warning
  when roads are off. "© OpenStreetMap contributors" is one line at the
  bottom edge when a pack is in use.
  **Manual fix:** zoom in to a visible span of 300 m or less and double tap
  where the car really is; "Fix recorded" with Undo for 3 s. During a test
  recording the map shows a red dot with the elapsed time; tapping it asks
  before stopping. When you have driven out of every installed region pack,
  a card at the next stop offers that region's pack (Download / Not now /
  Never); never in motion. A long press on the speed value toggles the navigation
  stats (ms per step, particles, thermal).
- **Settings → Developer → Sessions** (in Release behind the 7-tap gate). Recordings with date, duration and size. Share exports the
  recording together with its `.nav.jsonl` sidecar; trash asks first and
  deletes both. The list refreshes on appear and after a recording ends. The
  recording in progress can't be shared or deleted.
- **Settings.** Groups: OBD adapter, Maps, Mount and orientation, About, and
  Developer ("For test drives and diagnostics": Demo drive, Test drive
  recording, Sessions, Console). In Release, Developer shows only Demo drive
  until 7 taps on Version in About open the gate; then Test drive recording,
  Sessions and Console appear (a Debug build shows all of them).
  - **Developer → Demo drive (simulated car)**: runs Navigate on a
    deterministic synthetic drive (a closed loop of about 5 km) over a bundled
    read-only demo road pack, with simulated OBD speed and motion. Good GPS for
    the first minute, then only coarse network-like fixes, so the position
    continues on the roads. A DEMO badge and "Stop demo" show on the map. Works
    offline, writes nothing, and holds the real adapter and the app's own
    session until Stop (Record can't start meanwhile). Going to the background
    stops it. For App Review and screenshots.
  - **Developer → Test drive recording** (in Release behind the gate): the former Record screen, unchanged. A big
    banner (red NOT RECORDING, orange KEEP STILL with a countdown, green
    RECORDING with elapsed time), the adapter status (scanning, connecting,
    initialising, or polling with protocol and voltage), OBD speed and GPS
    speed side by side, OBD Hz, motion Hz and file size. START, MARK and STOP
    are large buttons pinned to the bottom. MARK opens presets (tunnel,
    traffic jam, junction, bad road, parking, stop) and a free-text field.
    Warnings appear as notices: low disk space, a write failure (reason and
    number of unwritten events), no background location session, unavailable
    sensors. Before Start, the checklist and the mount and vehicle notes are
    shown (the notes are remembered). If Start is refused, the reason is
    shown; with no polling adapter, "Record without OBD" is an explicit
    per-recording switch. The screen stays awake while recording.
  - **OBD adapter**: state, the paired adapter's name, Connect / Disconnect /
    Forget, Scan (same guards as Console) and a short help when no adapter is
    found.
  - **Developer → Console** (in Release shown only after 7 taps on Version in
    Settings → About, the Diagnostics gate): scan, pick, connect, disconnect and forget the adapter,
    Re-initialise, and the raw ELM traffic (TX, RX and status lines, newest at
    the bottom). A manual field and quick buttons send only the read-only
    queries (`ATI`, `AT@1`, `ATDP`, `ATDPN`, `ATRV`, mode 01). A rejected
    command is shown as rejected and never sent. After "link out of sync" a
    Re-initialise button appears. While a recording runs, Disconnect, Forget
    and tapping another adapter ask first (dropping the OBD feed, or
    connecting so the recording gains OBD from then on), and Scan is disabled.
  - **Mount and orientation**: the mounting text, read-only.
  - **How FuGPS works**: the four first-launch cards again (Next / Done).
  - **Maps**: every pack in the server's list, one row each (title, size,
    OSM date, state) with Download / Cancel / Update; Remove by swipe;
    "Use cellular data" (off by default); "Not offered on the road" with
    Reset. Packs not in the list appear under "Other".
  - **About**: version and build, Privacy policy, Support, "Data and
    services" (OpenStreetMap ODbL, Apple Maps), a driver-attention line.
  - **Diagnostics**: thermal state, version. Developer rows
    (build, memory, roads: packs found, verified or refused with the reason,
    packs in use) are always shown in DEBUG; in Release after 7 taps on
    Version in Settings → About (7 more hide them).

On the simulator the adapter and sensors are simulated and labelled so;
Bluetooth or a sensor being unavailable is shown as a red or orange state, not
a crash.

## Using it

### Navigate (daily)

1. Fix the phone in the rigid mount in portrait.
2. Plug the adapter into the car's OBD-II port and switch on the ignition.
3. Open the app. On first launch read or skip the cards,
   choose the road maps to download (all-Ukraine is preselected, your region
   too if location is allowed), and allow Bluetooth, Motion & Fitness and
   Location (While Using).
4. First time only: gear on the map → OBD adapter → Scan, tap the adapter. It is
   remembered and reconnects on its own.
5. Navigation starts when the adapter is polling. If the car is stationary
   the map shows "Hold still — calibrating" for 5 s: don't touch the phone or
   move the car. If already moving, it starts straight away.
6. Drive with the screen on. When GPS is jammed the dot keeps moving on OBD
   speed, gyro heading and the roads. If it drifts, correct it **at a stop**:
   zoom in and double tap your real position.
7. If the adapter drops, the map shows "OBD lost — reconnecting"; after
   5 min without OBD Navigate stops. Nothing is saved at any point.

### Recording a test drive

1. Mount the phone and plug in the adapter as above. Don't move the phone
   until the recording is stopped.
2. Settings → Developer → Test drive recording (in a Release build first tap
   Version in About 7 times). Tick "rigid mount" and "fixed
   orientation", optionally fill in the notes, and press START while the car
   is stationary. The first 5 seconds are a keep-still calibration (orange
   banner). Navigate stops and the recording starts its own fresh session.
3. Drive. Press MARK for events (tunnel, traffic jam). Pins placed on the map
   are written to the recording. Recording continues with the screen locked.
4. After parking, press STOP (on the map or in Settings). The map returns to
   Navigate if the adapter is still connected.
5. Settings → Developer → Sessions: share the recording and its sidecar, or copy them with the
   Files app (On My iPhone → DriveLogger). For a timing-faithful test drive,
   build with the `DriveLogger-Release` scheme (Debug is `-Onone`, so the
   sidecar's `msPerStep` is meaningless there).

## Road packs

A road pack (`*.roadpack`) is a binary, memory-mapped OSM road graph with a
grid index, used by the engine for map matching. Format:
[docs/ROAD_PACK.md](docs/ROAD_PACK.md).

**The set.** `national` (motorways, trunk and primary roads of all of
Ukraine, 41 MB) plus 27 regional packs named by ISO 3166-2 (`ua-05` …
`ua-77`, 7–59 MB, most 25–50 MB); 28 packs, about 1 GB in all. A typical
install is national plus one region, 60–100 MB. Border roads are in both
neighbouring packs and load together without duplicates.

**From OSM to the server** (Mac):

1. `tools/roads/build_packs.sh` builds the packs listed in the git-ignored
   `osm/packs.json` into `osm/packs/` (osmium + `build_roads`).
2. `site/publish_packs.sh` uploads them to the R2 bucket under immutable keys
   `packs/v1/<name>-<contentHash>.roadpack` and then publishes
   `https://fugps.pages.dev/packs/manifest.json` (schema 2: per pack name,
   kind, uk/en title, bbox, url, size, sha256, contentHash, format version,
   OSM timestamp). `--dry-run` first; `--prune` deletes superseded pack keys
   after the new manifest is up (each full rebuild adds ~1 GB to R2).

**From the server to the phone** (the user's path):

- **First launch**, after the cards: the "Road maps" step. National is
  always preselected. If location is allowed, a coarse one-shot fix
  (≤ 5 km, within 10 s) preselects the region whose bbox contains it and
  lists regions within ~20 km as "Nearby", not preselected. Nothing
  downloads until the user confirms; "Download maps later" is always there.
  The fix is never stored or sent.
- **Settings → Maps**: add, remove and update any pack at any time. A pack
  that finishes installing during a run is attached to it at once (the run's
  roads extend). Removing one during a run asks first; the run keeps using it
  until the app restarts, and "Download again" cancels the removal.
- **On the road**: when the estimate is confident and has been outside every
  installed region pack for 30 s, its region is remembered and offered at the
  next stop (speed 0 for ≥ 3 s), never in motion. Shown again at later stops
  until answered, at most 3 times per region per drive. "Not now" lasts the
  drive; "Never" (for that region) lasts until reset in Settings → Maps.
- **Download rules**: Wi-Fi only unless "Use cellular data" is on; one
  download at a time, the rest queued; resumable (HTTP Range); paused while
  Record runs (Navigate doesn't pause them). The manifest is refreshed when
  Maps opens and the cached copy is older than 24 h, or on pull to refresh;
  the last good one is kept for offline use.
- **Checks and install**: sha256 against the manifest, then the pack's own
  content hash, then install into
  `Application Support/RoadPacks/<name>-<contentHash>.roadpack` (excluded
  from backup, one active pack per name). A file that fails a check is
  deleted.
- **Updates**: when the manifest's contentHash differs from the installed
  pack's, Maps shows "Update available"; nothing updates without a tap. The
  new file is installed alongside and used from the next Navigate or Record
  start: a pack a running session has memory-mapped is never overwritten.
  Removed packs are deleted at the next launch.

**Developer path.** `scripts/push_packs.sh` copies `osm/packs/*.roadpack`
into the app's inbox `Documents/RoadPacks/` on the connected iPhone. At its
next launch, before any session, the app verifies each pack, installs it into
the same private store and deletes it from the inbox; a refused pack stays
there and Diagnostics says why. Packs are never used from `Documents`. Close
the app first (swipe it away): the script refuses while the app process runs
or a recording looks in progress, unless `--force`. There is no import via
Files or AirDrop.

**Without packs** the app works without roads, and the map says so.

**Licence:** © OpenStreetMap contributors,
[ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/). The attribution
is on the map whenever a pack is in use, and in Settings → Maps.

Packs, OSM extracts and `osm/packs.json` are **never committed**: the choice
of regions reveals where someone drives.

## Website

`site/` is the app's website on Cloudflare Pages, English in `site/public/`
and Ukrainian in `site/public/uk/`: landing, support, privacy, map data
(ODbL), supported vehicles, release notes. Road packs are served from R2
through a Pages Function at `/packs/*` with a manifest
(`/packs/manifest.json`); `site/publish_packs.sh` publishes them. Details:
[docs/RELEASE_PLAN.md](docs/RELEASE_PLAN.md) ("The site").

## Quick start

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Xcode must be the active developer directory (`xcode-select -p`); see
[CLAUDE.md](CLAUDE.md) if it points at the Command Line Tools.

```bash
brew install xcodegen
xcodegen generate
```

Signing: copy the example config and set your Team ID and a bundle identifier.
`Config/Local.xcconfig` is git-ignored; do not put a Team ID anywhere else.

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Run on a real iPhone: open `DriveLogger.xcodeproj`, select your connected
iPhone as the destination, and run the `DriveLogger` scheme (or `DriveLogger-Release` for a test drive,
so timings are meaningful). The simulator has
no Bluetooth LE and no motion sensors; simulator builds use a simulated OBD
adapter and simulated sensors instead (see "Simulated recording"):

```bash
xcodebuild -project DriveLogger.xcodeproj -scheme DriveLogger \
  -destination 'generic/platform=iOS Simulator' build
```

Core logic tests run on the Mac:

```bash
cd Core && swift test
```

## Commands

Run from the repository root unless the command starts with `cd Core`.

### Toolchain

| Command | What it does |
|---|---|
| `xcode-select -p` | Shows the active developer directory. It must be Xcode, not `/Library/Developer/CommandLineTools`, which can't build iOS targets or load the Swift Testing macros. |
| `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` | Makes Xcode the active developer directory, once per machine. |
| `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer <command>` | Alternative to the above: uses Xcode for a single command without changing the system setting. |
| `brew install xcodegen` | Installs XcodeGen, which generates the Xcode project from `project.yml`. |

### Project setup

| Command | What it does |
|---|---|
| `xcodegen generate` | Regenerates `DriveLogger.xcodeproj` from `project.yml`. Run it after adding, removing or renaming any app or test file, and commit the regenerated project with the change. Never edit the `.xcodeproj` by hand. |
| `cp Config/Local.xcconfig.example Config/Local.xcconfig` | Creates your git-ignored signing config. Put your Team ID and bundle identifier there and nowhere else. Needed only for builds on a real device. |

### Core package (fast, on the Mac, no simulator)

| Command | What it does |
|---|---|
| `cd Core && swift test` | Builds and runs every Core unit test: ELM327 parsing, OBD decoding, the read-only command guard, the clock, log format compatibility, the navigation engine, road packs and map matching. Takes seconds. |
| `cd Core && swift test --filter OBDDecoderTests` | Runs one test suite, matched by its type name. |
| `cd Core && swift test --filter OBDDecoderTests/decodesEngineSpeed` | Runs one test, matched as `SuiteType/functionName`. `--filter` matches identifiers, not the display names in `@Test("…")`; a display name matches nothing and runs zero tests. |
| `cd Core && swift build --build-tests` | Compiles Core and its tests without running them. |
| `cd Core && swift run -c release inspect_log <file.jsonl.gz> [--csv <dir>] [--strict]` | Summarises a recording: header, events per kind, rates, gaps over 50 ms, OBD latency percentiles, adapter exchange outcomes, damage and truncation. `--csv` writes one CSV per event kind; `--strict` stops at the first damaged block or bad line. Exit status 0 = read (warnings printed), 1 = unreadable, 2 = usage. `-c release` is faster on long drives. |
| `grep -rhoE '^[[:space:]]*import[[:space:]]+[A-Za-z_]+' Core/Sources Core/Tests \| sort -u` | Lists every module Core imports. It must show only `Foundation`, `Testing` and `DriveLoggerCore`. No UIKit, SwiftUI, CoreBluetooth, CoreMotion, CoreLocation or MapKit. |

### iOS app

| Command | What it does |
|---|---|
| `xcodebuild -project DriveLogger.xcodeproj -scheme DriveLogger -destination 'generic/platform=iOS Simulator' build` | Builds the app for the simulator. Unsigned, so it works without a signing identity. |
| `xcodebuild -project DriveLogger.xcodeproj -scheme DriveLogger -destination 'generic/platform=iOS Simulator' build-for-testing` | Compiles the app and its test target without running the tests. |
| `xcrun simctl list devices available \| grep iPhone` | Lists installed iPhone simulators with their UDIDs, which running the tests needs. |
| `xcodebuild -project DriveLogger.xcodeproj -scheme DriveLogger -destination 'platform=iOS Simulator,id=<UDID>' test` | Runs the app tests on a specific simulator. Match by `id=`, not `name=`: name matching fails against some runtimes and xcodebuild then reports a confusing macOS destination error. |

The simulator has no Bluetooth LE and no real motion sensors, so it only proves
that the app builds and its logic works. Anything about the adapter, the
sensors or background recording has to be checked on an iPhone in the car
(the checklist is `docs/PLAN.md` §6).

### Simulated recording (DEBUG builds)

| Command | What it does |
|---|---|
| `xcrun simctl launch --console-pty <UDID> <bundle id> -autoRecordSeconds 75` | Launches the app and records for 75 s with no UI: connects the simulated adapter, waits for it to poll, starts (5 s calibration included), stops, and prints the file path. DEBUG builds only. |
| `… -autoRecordSeconds 75 -autoRecordLinkLossAt 40` | Also "unplugs" the simulated adapter 40 s in, so the file shows the drop, the reconnect and a fresh handshake. |
| `xcrun simctl get_app_container <UDID> <bundle id> data` | The app's data directory; recordings are in `Documents/logs`. Copy one **outside the repo** before running `inspect_log` on it. |

Simulated recordings say so: the header `notes` names the simulated sensors
and adapter, the adapter is called `Simulated Vlink`, and every `location` row
has `simulated: true`.

### Reading a recording

| Command | What it does |
|---|---|
| `gunzip -c Drive_<stamp>.jsonl.gz \| head -1 \| jq .` | Pretty-prints a recording's header. |
| `gunzip -c Drive_<stamp>.jsonl.gz \| jq -c 'select(.kind=="obd")'` | Prints only the OBD rows. Swap in any kind: `motion`, `location`, `elm`, `stats`, … |

Every field is described in [docs/LOG_FORMAT.md](docs/LOG_FORMAT.md).

### Navigation replay (Mac)

| Command | What it does |
|---|---|
| `cd Core && swift run -c release replay_nav <file.jsonl.gz>... --truth ../logs/truth.json --out ../logs/out` | Replays recordings through the engine and writes metrics and GeoJSON against the truth file. All flags (`--gps`, `--roads`, `--seed`, `--set`, `--fix-offset`, …): [docs/NAVIGATION.md](docs/NAVIGATION.md) "replay_nav". |
| `cd Core && swift run -c release replay_nav <file.jsonl.gz> --as-live --compare <file.nav.jsonl>` | Replays exactly as the phone ran it (file order, the header's seed, default config) and checks the result against the drive's sidecar. |
| `cd Core && swift test -c release --filter NavigationRoadPerfTests` | Timing asserts; they run only in release. |

Recordings, replay output and the truth file live in the git-ignored `logs/`:
they hold real positions.

### Road packs and site

| Command | What it does |
|---|---|
| `tools/roads/build_packs.sh [osm/packs.json] [--only <pack>]` | Builds the packs listed in `osm/packs.json` from an OSM extract (osmium + `build_roads`). Mac only. |
| `scripts/push_packs.sh [--dry-run] [--force] [--device <id>]` | Developer path: copies `osm/packs/*.roadpack` into the app's inbox `Documents/RoadPacks/` on the connected iPhone; the app installs them at its next launch. Refuses while the app runs or a recording is in progress. |
| `site/publish_packs.sh [--dry-run] [--prune]` | Uploads packs to R2 and then publishes the manifest the app downloads from; `--prune` deletes superseded pack keys afterwards. |

## ELM327 commands

The app talks to the OBD adapter in plain-text ELM327 commands. `AT…`
commands configure the adapter itself; hex commands such as `010D` are
forwarded to the car. Every command, including the app's own init and polling
and anything typed in the debug console, passes a **read-only guard**
(`ELMCommandPolicy` in `Core/Sources/DriveLoggerCore/ELM327/`) before it can
reach the adapter. The guard is an allowlist: anything not listed under
"Allowed" is rejected and never leaves the phone.

Commands are typed without spaces (`ATAT2`, not `ATAT 2`). Input must be
plain ASCII: lookalike characters such as fullwidth digits are rejected, not
converted. Lower case is fine (`atrv`); the upper-case form is what is sent.

### Allowed

The **Console** column says whether the command can be typed in the debug
console. The console may only *query* the adapter. Commands that change its
settings (echo, headers, spaces, timing, protocol, addressing, reset) are reserved for
the app's own init, because the app depends on those settings to read replies
and attribute them to the right ECU. A change it didn't make would silently
corrupt every row after it.

| Command | Console | What it does |
|---|---|---|
| `ATZ` | no | Full reset, like unplugging the adapter. Prints the version banner (e.g. `ELM327 v2.1`), which is recorded. First step of init. |
| `ATI` | yes | Prints the adapter's version string without resetting. |
| `AT@1` | yes | Prints the adapter's device description (manufacturer text). |
| `ATE0` / `ATE1` | no | Command echo off / on. The app runs with echo off, so replies don't repeat the command. |
| `ATL0` / `ATL1` | no | Linefeed after each carriage return off / on. |
| `ATS0` / `ATS1` | no | Spaces between hex bytes in replies off / on. Off makes replies shorter, which matters over BLE. |
| `ATH0` / `ATH1` | no | CAN headers in replies off / on. The app uses `ATH1`, so each reply shows which ECU sent it (`7E8` = engine). |
| `ATSP0` | no | Protocol auto-detect: the adapter finds the car's OBD protocol itself. The adapter stores this choice in its memory as the default, which is harmless because "auto" is the factory setting. |
| `ATSH7DF`, `ATSH7E0` … `ATSH7E7` | no | Sets the CAN header requests go to: `7DF` = every emissions ECU (the default after `ATZ`), `7E0` … `7E7` = one ECU (`7E0` = engine, which answers on `7E8`). The app sends `ATSH7E0` only on 11-bit CAN (`ATDPN` `6`/`A6`/`8`/`A8`) when the engine answered `0100`, so the response-count suffix gets the engine's reply; if the engine then answers nothing it switches back with `ATSH7DF`. Only these OBD request IDs are accepted, and requests stay mode 01. Not in the console: it changes addressing the app relies on. |
| `ATDP` / `ATDPN` | yes | Describes the detected protocol, as text / as a number. `A6` means auto-detected protocol 6: CAN 11-bit, 500 kbaud. |
| `ATRV` | yes | Reads the car's battery voltage at the OBD port. Recorded at init. Also a cheap check that the adapter is alive. |
| `ATAT0` / `ATAT1` / `ATAT2` | no | Adaptive timing off / normal / aggressive: how long the adapter waits for slow ECU replies. `ATAT2` is often the biggest speed-up on cheap clones. Fall back to `ATAT1` if replies get cut off. |
| `0100` | yes | Asks which PIDs 01–20 the car supports (a bitmask). After `ATSP0` it also forces the protocol search, so the first one can take several seconds. |
| `01xx` | yes | Mode 01, "show current data", for one PID: `010D` = vehicle speed (km/h), `010C` = engine RPM. Read-only. |
| `01xxyy…` | yes | Mode 01 for up to six PIDs in one request, e.g. `010D0C` = speed and RPM in one reply. Fewer round trips, so a higher sample rate. |
| `01xx…n` | yes | Mode 01, one to six PIDs, with a response-count digit `n` from 1 to 9: the adapter stops after `n` replies instead of waiting out its timeout. `010D1` and `010D0C1` are the forms the app uses. Often the largest rate gain, but some clones don't support it. The count is a single digit: `010D10` would mean PIDs 0D **and 10**. |

### Blocked: adapter commands

These are ordinary ELM327 commands, but each can make an allowed request
unsafe, change the adapter permanently, or break the app's one-command-at-a-time
protocol. They're rejected everywhere, including the app's own init.

| Command | What it does | Why it's blocked |
|---|---|---|
| `ATCAF0` / `ATCAF1` | CAN auto-formatting off / on. With formatting off, the adapter sends the hex you type as the raw CAN frame, without adding the length byte itself. | **Clears fault codes by accident.** After `ATCAF0`, the allowed-looking `0104` (engine load) goes out as the frame `01 04`. The car reads that as a one-byte request for **service 04: clear diagnostic trouble codes, freeze frames and readiness monitors**. `ATCAF1` is the default and `ATZ` restores it, so it's never needed either. |
| `ATSH` with any other header (`7E8`, `6F1`, `7DE`, 29-bit `18DB33F1`, …) | Sets the CAN header, i.e. the address requests are sent to. | Retargets requests at a reply address or at modules that don't speak OBD mode 01. Only the OBD request IDs `7DF` and `7E0`–`7E7` are allowed (see above), and `ATCAF0` / `ATCRA` / `ATCEA` stay blocked, so a physically addressed `0104` is still a mode 01 request. A 3-digit `ATSH xyz` means header `00 0x yz`; only on 11-bit CAN is `7E0` an OBD request ID (on 29-bit CAN it would be `180007E0`), which is why the app checks the protocol first. |
| `ATCRAxxx` | Sets the CAN receive filter: which reply addresses the adapter shows. | Can hide the real ECU's replies, so the app records answers from the wrong module or nothing at all. |
| `ATCEA` / `ATCEAhh` | CAN extended addressing: adds an address byte in front of the data. | Changes how every frame is built; only meaningful for specific manufacturer modules. |
| `ATPPxxSVyy`, `ATPPxxON` / `OFF`, `ATPPS` | Programmable parameters: settings stored in the adapter's EEPROM. | **Permanent.** They survive power cycles and `ATZ`. One wrong value (e.g. the UART baud rate) can leave the adapter unable to talk to its own Bluetooth chip. |
| `ATMA` | Monitor all: prints every frame on the CAN bus continuously. | Never returns the `>` prompt until interrupted, so the app's one-command-in-flight framing breaks, and it floods the BLE link. |
| `ATMRhh` / `ATMThh` | Monitor only frames to / from one address. | Same problem as `ATMA`. |
| `ATBRDhh` / `ATBRThh` | Try a new UART baud rate divisor / set the timeout for that try. | Changes the speed between the ELM chip and the Bluetooth module. On clones this can drop the link until the adapter is unplugged. |
| `ATWS` | Warm start: a quick reset. | Silently undoes the init settings (headers, echo, spaces). The app resets only through `ATZ`, so the reset is recorded. |
| `ATD` | Restores all settings to factory defaults. | Same: headers go back off mid-session, and ECU attribution is lost without any error. |
| `ATLP` | Puts the adapter into low-power sleep. | The link goes dead until the adapter is woken up. |
| `ATSPh` (h ≠ 0), `ATSPAh`, `ATTPh` | Set / try a specific OBD protocol, e.g. `ATSP6`. | `ATSPh` is saved as the adapter's default, so a forced protocol would persist into other cars and apps. Blocked for now: only `ATSP0` (auto) is allowed. If the bench test (M4) shows that forcing protocol 6 speeds up init, it can be added to the list. |
| `ATSThh` | Sets the adapter's own reply timeout to `hh` × 4.096 ms. | Nothing in the app sends it (the session tunes speed with `ATAT`), and a too-short value turns every poll into `NO DATA`. May be reconsidered after the bench test (M4). |
| `ATSWhh` | Sets the interval of the wakeup (keep-alive) messages the adapter sends on the older ISO 9141 / ISO 14230 protocols; `ATSW00` stops them. They're on by default there and irrelevant on CAN. | Changes what the adapter transmits on its own. Not needed for this CAN car. |
| `ATFCSH`, `ATFCSD`, `ATFCSM` | Flow control header / data / mode: the frames the adapter sends during multi-frame transfers. | Lets custom frames be put on the bus. |

**Init and polling.** Init is `ATZ → ATE0 → ATL0 → ATS0 → ATH1 → ATSP0 →
0100 → ATDPN → ATRV`, then `ATSH7E0` on 11-bit CAN when the engine answered
`0100`. The poll command is then the first of `010D0C1` → `010D0C` → `010D1`
→ `010D` that returns the engine's (`7E8`) values. The `1` suffix is used only
if `ATSH7E0` was answered `OK`; otherwise the order is `010D0C` → `010D`, and a
note is recorded. A refused or skipped `ATSH7E0` is not an error:
initialisation and recording carry on with functional addressing. If `7E0`
answers nothing, the app switches back with `ATSH7DF` and selects again
functionally. Under functional
addressing the suffix stops at the first reply, whichever ECU sends it, which
on the test car was the gearbox. The console can still type `010D1`, but
console replies never become readings. Bench transcripts:
[docs/BENCH_TEST_2026-10-07.md](docs/BENCH_TEST_2026-10-07.md).

Malformed input is rejected rather than cleaned up: spaces, extra characters,
embedded line breaks (`ATZ\r04`), invalid parameters like `ATAT3`, or `ATST` in any form (not allowlisted; see
the table above).

### Blocked: diagnostic modes other than 01

Only mode `01` (live data) is allowed. Everything else is rejected, including
modes that only read, because the logger doesn't need them and a short list is
easier to verify.

| Mode | What it does |
|---|---|
| `02` | Freeze-frame data: sensor values captured when a fault was stored. Read-only. |
| `03` | Read stored trouble codes. Read-only. |
| `04` | **Clear trouble codes**, freeze frames and readiness monitors. Writes to the car. |
| `07` | Read pending trouble codes. Read-only. |
| `08` | Control an on-board system or run a test. Can actuate components. |
| `09` | Vehicle information (VIN, calibration IDs). Read-only. |
| `0A` | Read permanent trouble codes. Read-only. |
| `10` | UDS diagnostic session control: switches an ECU into extended or programming sessions. |
| `11` | UDS ECU reset: reboots a module, possibly while driving. |
| `14` | UDS clear diagnostic information. |
| `27` | UDS security access: unlocks protected functions. |
| `2E` | UDS write data by identifier: changes ECU configuration (coding). |
| `31` | UDS routine control: starts built-in routines (tests, adaptations, erase). |
| `3B` | KWP2000 write data by local identifier. |

## Permissions and what the app does while recording

| Permission | Asked | Used for |
|---|---|---|
| Bluetooth | at first launch (the Bluetooth link is created at launch so iOS can restore it) | the OBD-II adapter. Background mode `bluetooth-central` keeps the link alive with the screen locked; CoreBluetooth state restoration lets iOS relaunch the app for it. |
| Motion & Fitness | when navigation or a recording first starts the barometer | the altimeter (pressure, relative altitude). Accelerometer, gyroscope, magnetometer and device motion need no permission. |
| Location (While Using) | at first launch (the map shows the GPS position) | GPS fixes for the engine, used only while clean, and the reference track. Navigate uses location only while the app is in the foreground. In Record, background mode `location` plus a live location session (`CLBackgroundActivitySession`) keep recording with the screen locked; the blue location indicator shows while recording. "Always" is not needed. |

A permission that is refused does not stop the recording: the missing stream
is written as an `error` row at the start of the file and everything else is
recorded.

While a recording runs the app:
- stamps every sample from one clock (seconds since boot, CoreMotion's) and
  writes the wall clock only once, in the header;
- records device motion, raw accelerometer and gyroscope at 100 Hz,
  magnetometer at 10 Hz, the barometer at about 1 Hz, GPS at about 1 Hz
  (reference only), and every OBD exchange;
- writes the file in the background, compressed, flushing at least every 2 s,
  when the app goes to the background and on memory warnings — a crash loses
  at most the last couple of seconds;
- writes a `stats` row every 10 s (rows per stream, achieved rates, gaps over
  50 ms, writer queue depth) — the health record of the drive;
- writes app lifecycle events (background/foreground, memory warnings,
  thermal state, screen lock) as rows;
- keeps the screen awake (you can still lock it; recording continues);
- warns below 200 MB free, stops cleanly below 50 MB, and won't start below
  200 MB. A failed write stops the recording and the app shows how many
  events were lost.

Recordings are named `Drive_<yyyyMMdd-HHmmss>.jsonl.gz`, in the app's
`Documents/logs` folder; an existing file is never overwritten.

## Log format

Recordings are JSON Lines, one header line followed by one event per line,
with a versioned format; every version ever written stays readable. See
[docs/LOG_FORMAT.md](docs/LOG_FORMAT.md). The navigation sidecar
`Drive_<stamp>.nav.jsonl` sits next to its recording and is versioned on its
own: [docs/NAV_SIDECAR.md](docs/NAV_SIDECAR.md).

## Docs

| Doc | What's in it |
|---|---|
| [CLAUDE.md](CLAUDE.md) | Layout, invariants, conventions, commands. Wins on any conflict. |
| [WORKFLOW.md](WORKFLOW.md) | How the work is split between agents, hooks, review loop. |
| [docs/PLAN.md](docs/PLAN.md) | Milestones, decisions, device checklist (§6). |
| [docs/NAVIGATION.md](docs/NAVIGATION.md) | Engine model, config, `replay_nav`, adoption rule, acceptance drives and results. |
| [docs/N3_PLAN.md](docs/N3_PLAN.md), [docs/N4_PLAN.md](docs/N4_PLAN.md) | Open plans: roads, live navigation. |
| [docs/LOG_FORMAT.md](docs/LOG_FORMAT.md), [docs/NAV_SIDECAR.md](docs/NAV_SIDECAR.md), [docs/ROAD_PACK.md](docs/ROAD_PACK.md) | File formats. |
| [docs/BACKLOG.md](docs/BACKLOG.md), [docs/BACKLOG_UX.md](docs/BACKLOG_UX.md) | Open review findings; product changes. |
| [docs/RELEASE_PLAN.md](docs/RELEASE_PLAN.md) | App Store preparation, the site. |
| [docs/REVIEW_LOG.md](docs/REVIEW_LOG.md) | Review ledger (current runs). |
| `docs/archive/` | History; moved, never rewritten. |

## Roadmap

1. **Logger** — done.
2. **Replay and the engine** (`replay_nav`, particle filter) — done.
3. **Roads** (packs, map matching, live attach, packs in the app and
   downloaded by region: N3.0–N3.4, UX-8) — done in code; device checks
   open.
4. **Live navigation in the app** (N4, Navigate mode) — done in code; device
   checks open.
5. **Next:** Ukrainian localization (UX-15), navigation without OBD
   (NAV-NOOBD → UX-7), a switch for spoofed GNSS (UX-9), then TestFlight and
   the App Store as FuGPS.

## Privacy

- Navigate writes nothing to disk, and no location leaves the phone (the
  first-launch region suggestion is computed on the phone and not stored).
- A recording and its sidecar contain the route driven and the times it was
  driven. They stay on the phone until you copy them off. Never commit them;
  `.gitignore` excludes `*.jsonl`, `*.jsonl.gz` and `logs/`.
- `osm/` (extracts, packs, `packs.json`) is git-ignored for the same reason.
- The pack server sees which region packs are downloaded (a region, not a
  position) and the IP address. The privacy pages (EN and UK) say so.

## Safety

Don't touch the phone while driving. Pin, start and stop only while the car
is stopped. The position is an estimate: the ellipse shows how far off it may
be.
