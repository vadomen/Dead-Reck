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
   `Core/Sources/DriveLoggerCore/Navigation/` (incl. `Replay/`, `Roads/`) changed -> also `cd Core && swift test -c release --filter 'NavigationRoadPerfTests|NavigationB0Tests'` (their timing asserts run only in release) and report it.
2. Core invariant: `grep -rhoE '^[[:space:]]*import[[:space:]]+[A-Za-z_]+' Core/Sources Core/Tests | sort -u` shows only Foundation/Testing (+ DriveLoggerCore).
3. Files added/removed/renamed -> `xcodegen generate`, then commit `project.yml` and the regenerated `DriveLogger.xcodeproj` together. Never hand-edit the `.xcodeproj`. `Info.plist` is hand-maintained (`App/Resources/Info.plist`).
4. App code changed -> simulator build:
   `xcodebuild -project DriveLogger.xcodeproj -scheme DriveLogger -destination 'generic/platform=iOS Simulator' -quiet build`
5. App tests: get a UDID with `xcrun simctl list devices available | grep iPhone`, then
   `xcodebuild -project DriveLogger.xcodeproj -scheme DriveLogger -destination 'platform=iOS Simulator,id=<UDID>' test`
   (match by `id=`, not `name=`; `generic/platform=iOS Simulator` builds but cannot run tests).
6. Compile the test target without running it: same command with `-destination 'generic/platform=iOS Simulator' build-for-testing`.

## Long runs (xcodebuild test/build)
- Bound every wait at 30 min. Foreground: `timeout 1800 xcodebuild …`. Or run it in the background redirected to a log and wait with `timeout 1800 tail --pid=<PID> -f /dev/null` or a bounded loop (`for i in $(seq 360); do kill -0 <PID> 2>/dev/null || break; sleep 5; done`).
- Stock macOS has no `timeout` and BSD `tail` has no `--pid`: use `gtimeout` (coreutils) if installed, else `perl -e 'alarm shift; exec @ARGV' 1800 xcodebuild …` (exit 142 = timed out), and the bounded loop instead of `tail --pid`.
- Never an unbounded `until grep … log; do sleep …; done`: if xcodebuild crashes, the string never appears and the wait never ends.
- Judge the result by xcodebuild's exit code (`echo $?`, or `wait <PID>`), not by grepping the log for `TEST SUCCEEDED`. Use the log only to find `error:` lines and test counts.
- If a run crashes, hangs or times out: report that (command, exit code, last log lines) and stop waiting. Don't relaunch in a loop.

## Reading failures
- Search the output for `error:` first; fix the first error, rebuild - later errors are often consequences.
- Swift 6 concurrency errors: fix the isolation (actor, `@MainActor`, `Sendable` value types) instead of adding `@unchecked Sendable` or `nonisolated(unsafe)`. If you truly must, add a comment with the reason.
- "No such module" / missing type in the app but Core tests are green: the project was not regenerated - run `xcodegen generate`.
- `plugin for module 'TestingMacros' not found`: wrong developer dir, see Toolchain.

## What the simulator cannot prove
No BLE, no real motion sensors, no real background behaviour. Any claim about these must be phrased as "untested on hardware" and added to the field checklist.

## Reporting
Always report the exact command, pass/fail, and the number of tests run. Never say "should work" in place of running the command.
