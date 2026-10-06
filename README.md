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
