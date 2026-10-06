---
name: ios-build-test
description: How to build, test and regenerate the DriveLogger Xcode project from the command line, and how to report results. Use before claiming any iOS or Core change works.
---

# Build and test DriveLogger

Run from the repository root. `CLAUDE.md` is authoritative; if a command there differs from this file, CLAUDE.md wins.

## Toolchain
If `xcode-select -p` points at CommandLineTools, prefix commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (CLT cannot build iOS or load the Swift Testing macros).

## Order of checks (cheapest first)
1. Core changed -> `cd Core && swift test` (must pass, all of it). One suite: `cd Core && swift test --filter <SuiteName>`.
2. Core invariant: `grep -rhoE '^[[:space:]]*import[[:space:]]+[A-Za-z_]+' Core/Sources Core/Tests | sort -u` shows only Foundation/Testing (+ DriveLoggerCore).
3. Files added/removed/renamed -> `xcodegen generate`, then commit `project.yml` and the regenerated `DriveLogger.xcodeproj` together. Never hand-edit the `.xcodeproj`. `Info.plist` is hand-maintained (`App/Resources/Info.plist`).
4. App code changed -> simulator build:
   `xcodebuild -project DriveLogger.xcodeproj -scheme DriveLogger -destination 'generic/platform=iOS Simulator' -quiet build`
5. App tests: get a UDID with `xcrun simctl list devices available | grep iPhone`, then
   `xcodebuild -project DriveLogger.xcodeproj -scheme DriveLogger -destination 'platform=iOS Simulator,id=<UDID>' test`
   (match by `id=`, not `name=`).

## Reading failures
- Search the output for `error:` first; fix the first error, rebuild - later errors are often consequences.
- Swift 6 concurrency errors: fix the isolation (actor, `@MainActor`, `Sendable` value types) instead of adding `@unchecked Sendable` or `nonisolated(unsafe)`. If you truly must, add a comment with the reason.
- "No such module" / missing type in the app but Core tests are green: the project was not regenerated - run `xcodegen generate`.
- `plugin for module 'TestingMacros' not found`: wrong developer dir, see Toolchain.

## What the simulator cannot prove
No BLE, no real motion sensors, no real background behaviour. Any claim about these must be phrased as "untested on hardware" and added to the field checklist.

## Reporting
Always report the exact command, pass/fail, and the number of tests run. Never say "should work" in place of running the command.
