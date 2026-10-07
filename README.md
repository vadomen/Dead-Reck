# Dead-Reck

## What it is

In Kyiv, GPS is regularly jammed or spoofed, which makes phone navigation in a
car unusable. The long-term goal of this project is an iPhone app that keeps
tracking the car's position without GPS, using dead reckoning: vehicle speed
from the car's OBD-II port plus heading from the phone's gyroscope, later
constrained to an offline road map.

This repository is not that navigator yet. Version 1 is a **data logger**
(app name: DriveLogger). It records synchronized raw sensor data during real
drives, so the dead-reckoning algorithm can be developed and tuned offline by
replaying those recordings.

What v1 records:

- **OBD-II** via a BLE ELM327-compatible adapter: vehicle speed (PID `0x0D`)
  and engine RPM (PID `0x0C`), with request and response timestamps.
- **Phone motion** at 100 Hz from Core Motion device motion: user
  acceleration, rotation rate, gravity, attitude; plus magnetometer and
  barometer.
- **GPS fixes** as ground truth only, when available. GPS is never an input to
  positioning.

All streams are timestamped against a single monotonic clock so they can be
aligned when replayed.

## Status

Experimental. v1 is the logger.

The project scaffold, the ELM327 reply parser, OBD-II decoding and the log
format exist and are tested. The sensor capture and recording UI are not
implemented yet; the app currently shows a placeholder screen.

## Hardware

- iPhone running iOS 17 or later.
- Vgate iCar Pro Bluetooth 4.0 (BLE, ELM327-compatible) OBD-II adapter.
- Test vehicle: VW Touareg (2025).
- A rigid phone mount. The phone must stay in one fixed orientation (portrait)
  for the whole drive — the motion data is recorded in the phone's reference
  frame, and any movement of the phone in the mount corrupts it.

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
iPhone as the destination, and run the `DriveLogger` scheme. The simulator has
no Bluetooth LE and no motion sensors, so it is only useful for build checks:

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
| `cd Core && swift test` | Builds and runs every Core unit test: ELM327 parsing, OBD decoding, the read-only command guard, the clock, and log format compatibility. Takes seconds. |
| `cd Core && swift test --filter OBDDecoderTests` | Runs one test suite, matched by its type name. |
| `cd Core && swift test --filter OBDDecoderTests/decodesEngineSpeed` | Runs one test, matched as `SuiteType/functionName`. `--filter` matches identifiers, not the display names in `@Test("…")`; a display name matches nothing and runs zero tests. |
| `cd Core && swift build --build-tests` | Compiles Core and its tests without running them. |
| `cd Core && swift run -c release inspect_log <file.jsonl.gz> [--csv <dir>] [--strict]` | Summarises a recording: header, events per kind, rates, gaps over 50 ms, OBD latency percentiles, adapter exchange outcomes, damage and truncation. `--csv` writes one CSV per event kind; `--strict` stops at the first damaged block or bad line. Exit status 0 = read (warnings printed), 1 = unreadable, 2 = usage. `-c release` is faster on long drives. |
| `grep -rhoE '^[[:space:]]*import[[:space:]]+[A-Za-z_]+' Core/Sources Core/Tests \| sort -u` | Lists every module Core imports. It must show only `Foundation`, `Testing` and `DriveLoggerCore`. No UIKit, SwiftUI, CoreBluetooth, CoreMotion or CoreLocation. |

### iOS app

| Command | What it does |
|---|---|
| `xcodebuild -project DriveLogger.xcodeproj -scheme DriveLogger -destination 'generic/platform=iOS Simulator' build` | Builds the app for the simulator. Unsigned, so it works without a signing identity. |
| `xcodebuild -project DriveLogger.xcodeproj -scheme DriveLogger -destination 'generic/platform=iOS Simulator' build-for-testing` | Compiles the app and its test target without running the tests. |
| `xcrun simctl list devices available \| grep iPhone` | Lists installed iPhone simulators with their UDIDs, which running the tests needs. |
| `xcodebuild -project DriveLogger.xcodeproj -scheme DriveLogger -destination 'platform=iOS Simulator,id=<UDID>' test` | Runs the app tests on a specific simulator. Match by `id=`, not `name=`: name matching fails against some runtimes and xcodebuild then reports a confusing macOS destination error. |

The simulator has no Bluetooth LE and no real motion sensors, so it only proves
that the app builds and its logic works. Anything about the adapter, the
sensors or background recording has to be checked on an iPhone in the car.

### Reading a recording

| Command | What it does |
|---|---|
| `gunzip -c Drive_<stamp>.jsonl.gz \| head -1 \| jq .` | Pretty-prints a recording's header. |
| `gunzip -c Drive_<stamp>.jsonl.gz \| jq -c 'select(.kind=="obd")'` | Prints only the OBD rows. Swap in any kind: `motion`, `location`, `elm`, `stats`, … |

Every field is described in [docs/LOG_FORMAT.md](docs/LOG_FORMAT.md).

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
settings (echo, headers, spaces, timing, protocol, reset) are reserved for
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
| `ATSH7DF`, `ATSH7E0` … `ATSH7E7` | no | Sets the CAN header requests go to: `7DF` = every emissions ECU (the default after `ATZ`), `7E0` … `7E7` = one ECU (`7E0` = engine, which answers on `7E8`). Init ends with `ATSH7E0`: on the test car the response-count suffix otherwise returned the gearbox's (`7E9`) reply. Only these OBD request IDs are accepted, and requests stay mode 01. Not in the console: it changes addressing the app relies on. |
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
| `ATSH` with any other header (`7E8`, `6F1`, `7DE`, 29-bit `18DB33F1`, …) | Sets the CAN header, i.e. the address requests are sent to. | Retargets requests at a reply address or at modules that don't speak OBD mode 01. Only the OBD request IDs `7DF` and `7E0`–`7E7` are allowed (see above), and `ATCAF0` / `ATCRA` / `ATCEA` stay blocked, so a physically addressed `0104` is still a mode 01 request. |
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
0100 → ATDPN → ATRV → ATSH7E0`. The poll command is then the first of
`010D0C1` → `010D0C` → `010D1` → `010D` that returns the engine's (`7E8`)
values. The `1` suffix is used only if `ATSH7E0` was answered `OK`; otherwise
the order is `010D0C` → `010D`, and a note is recorded. Under functional
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

## Recording a drive

> The recording UI is not implemented yet. This is the intended procedure.

1. Fix the phone in the rigid mount in portrait. Don't move it until the
   recording is stopped.
2. Plug the adapter into the car's OBD-II port and switch on the ignition.
3. Open DriveLogger. On first launch, allow Bluetooth, Motion & Fitness and
   Location access.
4. Connect to the adapter and start recording while the car is stationary.
5. Drive. Leave the phone alone; recording continues with the screen locked.
6. After parking, stop the recording.
7. Copy the log off the phone using the Files app
   (On My iPhone → DriveLogger).

## Log format

Logs are JSON Lines, one header line followed by one event per line, with a
versioned format. See [docs/LOG_FORMAT.md](docs/LOG_FORMAT.md).

## Roadmap

1. **v1 — logger.** Record synchronized OBD-II, motion and GPS data on real
   drives.
2. **Replay and analysis tooling.** Load recordings offline, replay them, and
   compare dead-reckoned tracks against GPS ground truth.
3. **MVP dead-reckoning navigator.** Position tracking without GPS, constrained
   to an offline road map.

## Privacy

A recording contains the route driven and the times it was driven. Logs stay
on the phone until you copy them off. Never commit them to this repository;
`.gitignore` excludes `*.jsonl`, `*.jsonl.gz` and `logs/`.

## Safety

Don't touch the phone while driving. Start and stop recordings only while the
car is parked.
