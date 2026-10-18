#!/usr/bin/env bash
# Copy osm/packs/*.roadpack into the app's Documents/RoadPacks/ on the connected
# iPhone (CoreDevice file service, `xcrun devicectl device copy to`).
# Run `scripts/push_packs.sh --help` for usage.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/push_packs.sh [--dry-run] [--force] [--device <id|udid|name>]

Copies osm/packs/*.roadpack to Documents/RoadPacks/ in the DriveLogger app
container on the connected iPhone. The bundle ID comes from
Config/Local.xcconfig (PRODUCT_BUNDLE_IDENTIFIER), the app's name from
project.yml.

Close the app first: swipe it away in the app switcher, push, then launch it.
The app memory-maps packs from Documents/RoadPacks while it navigates or
records (Navigate or Record), and devicectl overwrites a pack in place, which
can crash it (SIGBUS). The script refuses when:
  - the app process is running on the phone (an app left suspended in the
    app switcher still has its packs mapped), or the phone's process list
    cannot be read;
  - a file under Documents/logs changed in the last 30 s (a recording).
A dry run reports what these guards found and exits 0.

  --dry-run         show copied / skipped per pack and what the guards found,
                    copy nothing
  --force           copy even if the app is running (Navigate or Record), its
                    process list cannot be read, or a recording looks to be in
                    progress
  --device <id>     CoreDevice identifier, UDID or name, when more than one
                    iPhone is connected
  -h, --help        this text

A pack is skipped when its size + sha256 equal what was last pushed to this
device (stamp file osm/.push_packs_stamps.tsv, git-ignored) AND the phone's
listing shows the file with the same size.
USAGE
}

die() { echo "error: $*" >&2; exit 1; }

# refuse <reason> <what to do>: a guard that would stop the copy. --force
# continues, --dry-run reports it and goes on listing the packs, otherwise the
# script stops here.
blocked=0
refuse() {
  if [ $force -eq 1 ]; then
    echo "warning: $1 (--force given, copying anyway)" >&2
  elif [ $dry_run -eq 1 ]; then
    echo "dry run: a real run would refuse: $1. $2" >&2
    blocked=1
  else
    die "$1. $2"
  fi
}

dry_run=0
force=0
device_arg=""
processes_json_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --force) force=1 ;;
    --device)
      [ $# -ge 2 ] || die "--device needs a value"
      device_arg="$2"; shift ;;
    # Tests only (not in --help): run the process-list parser on a saved
    # `devicectl device info processes --json-output` file and exit with its
    # verdict (0 not running, 1 running, 2 unreadable). Needs no phone.
    --processes-json)
      [ $# -ge 2 ] || die "--processes-json needs a file"
      processes_json_file="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The app's executable inside its bundle, "<name>.app/<name>": the name of the
# project.yml target with `type: application` (PRODUCT_NAME and EXECUTABLE_NAME
# default to it), or that target's PRODUCT_NAME if project.yml sets one.
app_name="$(awk '
  /^targets:/ { in_t = 1; next }
  in_t && /^[^[:space:]#]/ { in_t = 0 }
  in_t && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { t = $1; sub(/:$/, "", t); next }
  in_t && t != "" && /^    type:[[:space:]]*application[[:space:]]*$/ { app = t }
  in_t && t != "" && t == app && /^[[:space:]]+PRODUCT_NAME:/ { v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); gsub(/"/, "", v); pn = v }
  END { if (pn != "") print pn; else print app }
' "$repo_root/project.yml")"
[ -n "$app_name" ] || die "no target with 'type: application' found in project.yml."
app_executable="$app_name.app/$app_name"

# Reads `devicectl device info processes --json-output` on stdin. Prints
# "<pid> <path>" for each process whose executable is .../<app_executable>.
# Exit 0: the list was read and the app is not in it; 1: it is; 2: no
# result.runningProcesses array, or an empty one (a phone always runs
# processes, so an empty list means the read failed, not "app closed").
app_processes() {
  /usr/bin/python3 -I -c '
import json, sys, urllib.parse
suffix = "/" + sys.argv[1]
try:
    procs = json.load(sys.stdin)["result"]["runningProcesses"]
except Exception:
    sys.exit(2)
if not isinstance(procs, list) or not procs:
    sys.exit(2)
hits = []
for p in procs:
    exe = p.get("executable") if isinstance(p, dict) else None
    if not isinstance(exe, str):
        continue
    path = urllib.parse.unquote(urllib.parse.urlparse(exe).path if exe.startswith("file:") else exe)
    if path.endswith(suffix):
        hits.append("%s %s" % (p.get("processIdentifier", "?"), path))
if hits:
    print("\n".join(hits))
    sys.exit(1)
' "$app_executable"
}

if [ -n "$processes_json_file" ]; then
  rc=0
  app_processes < "$processes_json_file" || rc=$?
  exit $rc
fi

packs_dir="$repo_root/osm/packs"
xcconfig="$repo_root/Config/Local.xcconfig"
stamp_file="$repo_root/osm/.push_packs_stamps.tsv"
remote_dir="Documents/RoadPacks"
recording_window_s=30

# Toolchain: CommandLineTools cannot run devicectl.
if [ -z "${DEVELOPER_DIR:-}" ] && [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ]; then
  [ -d /Applications/Xcode.app/Contents/Developer ] \
    || die "xcode-select points at CommandLineTools and /Applications/Xcode.app was not found; install Xcode or set DEVELOPER_DIR"
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Bundle ID.
[ -f "$xcconfig" ] || die "Config/Local.xcconfig not found. Run: cp Config/Local.xcconfig.example Config/Local.xcconfig and fill it in."
bundle_id="$(sed -E 's://.*$::' "$xcconfig" \
  | sed -nE 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' | tail -n 1)"
[ -n "$bundle_id" ] || die "PRODUCT_BUNDLE_IDENTIFIER not set in Config/Local.xcconfig (see Config/Local.xcconfig.example)."

# Packs.
[ -d "$packs_dir" ] || die "osm/packs not found. Build the road packs first (docs/N3_PLAN.md)."
packs=()
for f in "$packs_dir"/*.roadpack; do
  [ -f "$f" ] && packs+=("$f")
done
[ ${#packs[@]} -gt 0 ] || die "no .roadpack files in osm/packs."

# Device: exactly one connected physical iPhone (or --device).
devices_json="$(xcrun devicectl list devices --quiet --json-output - 2>/dev/null)" \
  || die "xcrun devicectl list devices failed."
set +e
device_id="$(printf '%s' "$devices_json" | /usr/bin/python3 -I -c '
import json, sys
want = sys.argv[1]
devs = json.load(sys.stdin)["result"]["devices"]
found, ok = [], []
for d in devs:
    p = d.get("properties", {})
    hw, conn, st = p.get("hardware", {}), p.get("connection", {}), p.get("state", {})
    if hw.get("reality") != "physical" or hw.get("deviceType") != "iPhone":
        continue
    state = conn.get("state", "unknown")
    found.append("  %s  [%s]  %s" % (st.get("name", "?"), state, d["identifier"]))
    if state != "connected":
        continue
    if want and want not in (d["identifier"], hw.get("udid"), st.get("name")):
        continue
    ok.append(d["identifier"])
if len(ok) == 1:
    print(ok[0]); sys.exit(0)
sys.stderr.write(("no connected iPhone matches" if not ok else "several connected iPhones; pass --device <id>") + "\n")
sys.stderr.write("iPhones CoreDevice knows about:\n" + ("\n".join(found) if found else "  (none)") + "\n")
sys.exit(1)
' "$device_arg")"
rc=$?
set -e
[ $rc -eq 0 ] || exit 1

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Two guards stop a copy into packs the app may have memory-mapped (devicectl
# overwrites in place; there is no temp-name-and-rename, so a mapped pack can
# SIGBUS the app). Both are checked once, before the first copy: launching the
# app while the script copies is not detected.
#
# Guard 1: the app process is running. Navigate (UX-1) maps packs whenever the
# app runs and OBD polls, without writing any log, so guard 2 cannot see it. A
# suspended app still has its packs mapped, hence "swipe it away". The process
# is matched by its executable path, .../<app_executable>, so another app with
# the same name would also block (fails safe). Fail closed: if the process list
# cannot be read (phone locked, older devicectl, JSON shape changed), refuse.
proc_rc=0
if xcrun devicectl device info processes --device "$device_id" \
     --quiet --json-output - > "$tmp_dir/processes.json" 2> "$tmp_dir/processes.err"; then
  app_processes < "$tmp_dir/processes.json" > "$tmp_dir/app_pids" || proc_rc=$?
else
  proc_rc=3
fi
case $proc_rc in
  0) echo "Guard 1 (app process): $app_executable is not running." ;;
  1)
    echo "Guard 1 (app process): the app is running on the phone (pid, executable):" >&2
    sed 's/^/  /' "$tmp_dir/app_pids" >&2
    refuse "the app is running (Navigate or Record maps the packs)" \
      "Swipe it away in the app switcher, then re-run; or re-run with --force." ;;
  *)
    reason="unexpected JSON (no or empty result.runningProcesses)"
    [ $proc_rc -eq 3 ] && reason="$(tail -n 1 "$tmp_dir/processes.err" 2>/dev/null)"
    echo "Guard 1 (app process): could not read the phone's process list: ${reason:-devicectl failed}" >&2
    refuse "cannot tell whether the app is running" \
      "Swipe the app away in the app switcher, unlock the phone and re-run; or re-run with --force." ;;
esac

# Phone listing of Documents (recursive): "relativePath<TAB>size<TAB>age_seconds".
listing=""
listing_ok=1
if listing_json="$(xcrun devicectl device info files --device "$device_id" \
      --domain-type appDataContainer --domain-identifier "$bundle_id" \
      --subdirectory Documents --quiet --json-output - 2>/dev/null)"; then
  listing="$(printf '%s' "$listing_json" | /usr/bin/python3 -I -c '
import json, sys, datetime
now = datetime.datetime.now(datetime.timezone.utc)
for f in json.load(sys.stdin)["result"].get("files", []):
    if f["resources"].get("isDirectory"):
        continue
    m = f["metadata"]
    t = datetime.datetime.fromisoformat(m["lastModDate"].replace("Z", "+00:00"))
    print("%s\t%d\t%d" % (f["relativePath"], m["size"], int((now - t).total_seconds())))
')" || listing_ok=0
else
  listing_ok=0
fi
if [ $listing_ok -eq 0 ]; then
  echo "warning: could not list the phone's Documents folder (app never launched, phone locked, or unreachable)." >&2
  echo "         Falling back to the local stamp file alone; a pack deleted on the phone will NOT be re-pushed." >&2
fi

# Guard 2: a recording in progress. Heuristic: a file under Documents/logs
# changed in the last 30 s (recording_window_s; log write times may lag, clock
# skew is ignored). A recording implies guard 1 too; this one is kept as a
# second, independent signal (it does not depend on the process list). Without
# the phone listing it is unavailable (warned above).
if [ $listing_ok -eq 1 ]; then
  recent="$(printf '%s\n' "$listing" | awk -F'\t' -v w="$recording_window_s" '$1 ~ /^logs\// && $3 <= w && $3 >= -w {print $1}')"
  if [ -n "$recent" ]; then
    echo "Guard 2 (recent log write): a recording file changed in the last ${recording_window_s} s (heuristic: log write times may lag, and clock skew is ignored):" >&2
    printf '%s\n' "$recent" | sed 's/^/  /' >&2
    refuse "a recording looks to be in progress" \
      "Stop it and swipe the app away, then re-run; or re-run with --force."
  else
    echo "Guard 2 (recent log write): no log file on the phone changed in the last ${recording_window_s} s (a heuristic, not proof)."
  fi
else
  echo "Guard 2 (recent log write): unavailable without the phone listing."
fi

mkdir -p "$(dirname "$stamp_file")"
touch "$stamp_file"

copied=0
skipped=0
failed=0
for src in "${packs[@]}"; do
  name="$(basename "$src")"
  size="$(stat -f %z "$src")"
  sha="$(shasum -a 256 "$src" | awk '{print $1}')"
  stamp="$(awk -F'\t' -v d="$device_id" -v n="$name" '$1==d && $2==n {print $3 "\t" $4}' "$stamp_file" | tail -n 1)"
  remote_size="$(printf '%s\n' "$listing" | awk -F'\t' -v p="RoadPacks/$name" '$1==p {print $2}' | head -n 1)"

  unchanged=0
  if [ "$stamp" = "$size	$sha" ]; then
    if [ $listing_ok -eq 0 ] || [ "$remote_size" = "$size" ]; then unchanged=1; fi
  fi

  if [ $unchanged -eq 1 ]; then
    echo "$name: skipped (unchanged)"
    skipped=$((skipped + 1))
  elif [ $dry_run -eq 1 ]; then
    echo "$name: would copy (dry run)"
    copied=$((copied + 1))
  else
    echo "$name: copying $size bytes ..."
    if xcrun devicectl device copy to --device "$device_id" \
         --domain-type appDataContainer --domain-identifier "$bundle_id" \
         --source "$src" --destination "$remote_dir/$name" --quiet; then
      echo "$name: copied"
      copied=$((copied + 1))
      unchanged=2
    else
      echo "$name: FAILED" >&2
      failed=$((failed + 1))
    fi
  fi

  # Rewrite the stamp for this pack: new value after a copy, old value kept otherwise.
  awk -F'\t' -v d="$device_id" -v n="$name" '!($1==d && $2==n)' "$stamp_file" > "$stamp_file.tmp"
  if [ $unchanged -ge 1 ]; then
    printf '%s\t%s\t%s\t%s\n' "$device_id" "$name" "$size" "$sha" >> "$stamp_file.tmp"
  elif [ -n "$stamp" ]; then
    printf '%s\t%s\t%s\n' "$device_id" "$name" "$stamp" >> "$stamp_file.tmp"
  fi
  [ $dry_run -eq 1 ] || mv "$stamp_file.tmp" "$stamp_file"
  rm -f "$stamp_file.tmp"
done

verb="copied"; [ $dry_run -eq 1 ] && verb="would be copied"
echo "Summary: $copied $verb, $skipped skipped (unchanged), $failed failed."
if [ $blocked -eq 1 ]; then
  echo "Dry run: a real run would refuse (see above); close the app or use --force."
fi
if [ $dry_run -eq 0 ] && [ $copied -gt 0 ]; then
  echo "Next: open the app, Settings > Diagnostics, and check the packs show Verified."
fi
[ $failed -eq 0 ] || exit 1
