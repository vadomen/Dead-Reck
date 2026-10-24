#!/usr/bin/env bash
# App Store screenshots (6.9", 1320x2868) from the built-in demo drive, in uk and en.
# Run `scripts/store_screenshots.sh --help` for usage.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/store_screenshots.sh [--dry-run] [--sim <udid>] [--lang en|uk]... [--scene <name>]... [--no-build]

Builds the Debug app, installs it on an iPhone 17 Pro Max simulator, and saves
logs/appstore/{en,uk}-{1-map,2-nogps,3-maps,4-onboarding,5-about}.png
(git-ignored; images are never committed).

  --sim <udid>   simulator to use. Default: the first available "iPhone 17 Pro Max",
                 else one named "DriveLogger Store 6.9" is created.
  --lang <l>     only this language (en or uk); repeatable. Default: both.
  --scene <s>    only this scene (1-map 2-nogps 3-maps 4-onboarding 5-about); repeatable.
  --no-build     reuse the last build in logs/appstore/.dd
  --dry-run      print every command, run nothing (nothing is built, created or booted)
  -h, --help     this text

How it is made reproducible (DEBUG launch arguments of the app, ignored in Release):
  -storeScreenshots 1      hides the "nav:" strip, the DEMO badge and Stop demo, nothing else
  -uiDemo 1                starts the demo drive at launch (fixed seed, same engine state at equal demo time)
  -storeDemoReadyAt S      the app writes a file into its tmp dir when the demo clock reaches S seconds;
                           the script waits for it and shoots at once
  -AppleLanguages / -AppleLocale   the language of the run
First-run cards and the maps step are marked seen by launch arguments, except in scene 4.
The simulator is set to light appearance, default text size and a 9:41 status bar
(full battery); the override is cleared when the script ends.
Demo moments (env, demo seconds): STORE_T_MAP (default 40, GPS still on, the arrow on a road with
its ellipse) and STORE_T_NOGPS (default 90, GPS lost for 30 s, the arrow still on the road).
USAGE
}

DRY=0; SIM=""; BUILD=1; LANGS=(); SCENES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --sim) SIM="${2:?--sim needs a udid}"; shift ;;
    --lang) LANGS+=("${2:?--lang needs en or uk}"); shift ;;
    --scene) SCENES+=("${2:?--scene needs a name}"); shift ;;
    --no-build) BUILD=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
[[ ${#LANGS[@]} -gt 0 ]] || LANGS=(en uk)
[[ ${#SCENES[@]} -gt 0 ]] || SCENES=(1-map 2-nogps 3-maps 4-onboarding 5-about)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="logs/appstore"
DD="$OUT/.dd"
BUNDLE="com.vadomen.fugps"
T_MAP="${STORE_T_MAP:-40}"
T_NOGPS="${STORE_T_NOGPS:-90}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

run() {
  if [[ $DRY -eq 1 ]]; then printf '+'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}

# --- simulator
if [[ -z "$SIM" ]]; then
  SIM="$(xcrun simctl list devices available | sed -nE 's/^ *iPhone 17 Pro Max \(([0-9A-F-]{36})\).*/\1/p' | head -1)"
fi
if [[ -z "$SIM" ]]; then
  RUNTIME="$(xcrun simctl list runtimes available | sed -nE 's/.*(com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+).*/\1/p' | tail -1)"
  if [[ $DRY -eq 1 ]]; then
    echo "+ xcrun simctl create 'DriveLogger Store 6.9' com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max ${RUNTIME:-<ios runtime>}"
    SIM="<new-udid>"
  else
    SIM="$(xcrun simctl create 'DriveLogger Store 6.9' com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max "$RUNTIME")"
  fi
fi
echo "simulator: $SIM"
run mkdir -p "$OUT"
if [[ $DRY -eq 1 ]] || [[ "$(xcrun simctl list devices | grep "$SIM" | grep -c Booted)" -eq 0 ]]; then
  run xcrun simctl boot "$SIM"
fi
run xcrun simctl bootstatus "$SIM" -b

# --- build and install
if [[ $BUILD -eq 1 ]]; then
  run xcodebuild -project DriveLogger.xcodeproj -scheme DriveLogger -configuration Debug \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath "$DD" -quiet build
fi
APP="$DD/Build/Products/Debug-iphonesimulator/DriveLogger.app"
run xcrun simctl uninstall "$SIM" "$BUNDLE" 2>/dev/null || true
run xcrun simctl install "$SIM" "$APP"

# --- clean look
run xcrun simctl ui "$SIM" appearance light
run xcrun simctl ui "$SIM" content_size large
run xcrun simctl status_bar "$SIM" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3 --dataNetwork wifi --operatorName ""
trap 'xcrun simctl status_bar "$SIM" clear >/dev/null 2>&1 || true' EXIT

shoot() { # lang scene
  local lang="$1" scene="$2" locale file ready
  case "$lang" in en) locale=en_US ;; uk) locale=uk_UA ;; *) echo "error: language $lang" >&2; exit 2 ;; esac
  file="$OUT/$lang-$scene.png"
  local args=(-AppleLanguages "($lang)" -AppleLocale "$locale" -storeScreenshots 1)
  local seen=(-onboarding.cardsSeen YES -onboarding.mountConfirmed YES -firstLaunch.mapsDone YES)
  local wait_demo=""
  case "$scene" in
    1-map)        args+=("${seen[@]}" -uiDemo 1 -storeDemoReadyAt "$T_MAP"); wait_demo=1 ;;
    2-nogps)      args+=("${seen[@]}" -uiDemo 1 -storeDemoReadyAt "$T_NOGPS"); wait_demo=1 ;;
    3-maps)       args+=("${seen[@]}" -uiScreen maps -uiFakeMapsStore 1 -uiFakeConnection wifi) ;;
    4-onboarding) args+=(-firstLaunch.mapsDone YES -uiOnboarding 1) ;;
    5-about)      args+=("${seen[@]}" -uiScreen about) ;;
    *) echo "error: scene $scene" >&2; exit 2 ;;
  esac
  run xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
  if [[ $DRY -eq 1 ]]; then
    echo "+ xcrun simctl launch $SIM $BUNDLE ${args[*]}"
    [[ -n "$wait_demo" ]] && echo "+ (wait for the app's store-demo-ready file in its tmp dir, at most 150 s)"
    echo "+ xcrun simctl io $SIM screenshot $file"
    return
  fi
  if [[ -n "$wait_demo" ]]; then
    ready="$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)/tmp/store-demo-ready"
    rm -f "$ready"
  fi
  xcrun simctl launch "$SIM" "$BUNDLE" "${args[@]}" >/dev/null
  if [[ -n "$wait_demo" ]]; then
    for _ in $(seq 3000); do [[ -e "$ready" ]] && break; sleep 0.05; done
    [[ -e "$ready" ]] || { echo "error: demo did not reach its moment (no $ready)" >&2; exit 1; }
  else
    sleep 4
  fi
  xcrun simctl io "$SIM" screenshot --type=png "$file" >/dev/null 2>&1
  echo "$file: $(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/{printf "%s ", $2}')"
}

for lang in "${LANGS[@]}"; do
  for scene in "${SCENES[@]}"; do shoot "$lang" "$scene"; done
done
run xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
