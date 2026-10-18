#!/usr/bin/env bash
# Copy osm/packs/*.roadpack into the app's developer inbox Documents/RoadPacks/
# on the connected iPhone (CoreDevice file service, `xcrun devicectl device copy
# to`). The app installs them into its private store at its next launch.
# Run `scripts/push_packs.sh --help` for usage.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/push_packs.sh [--dry-run] [--force] [--device <id|udid|name>]

Copies osm/packs/*.roadpack to Documents/RoadPacks/ in the DriveLogger app
container on the connected iPhone. The bundle ID comes from
Config/Local.xcconfig (PRODUCT_BUNDLE_IDENTIFIER), the app's name from
project.yml.

Documents/RoadPacks/ is only an inbox. At its next launch, before any
Navigate or Record session, the app verifies each pack there, installs it
into its private store as Library/Application Support/RoadPacks/
<name>-<contentHash>.roadpack (<name> is the file name without .roadpack)
and deletes it from the inbox. A pack the app refuses stays in the inbox;
Settings > Diagnostics says why. Packs are never used from Documents.

Close the app first: swipe it away in the app switcher, push, then launch it.
The app reads the inbox only at launch, so a pack pushed while it runs waits
for the next launch anyway, and devicectl writes the file in place, so a push
that overlaps a launch can hand the app a half-written pack (refused, kept,
retried at the following launch). The script refuses when:
  - the app process is running on the phone (an app left suspended in the
    app switcher is still running), or the phone's process list cannot be
    read;
  - a file under Documents/logs changed in the last 30 s (a recording).
A dry run reports what these guards found and exits 0.

  --dry-run         show copied / skipped per pack and what the guards found,
                    copy nothing
  --force           copy every pack, even unchanged ones, and even if the app
                    is running, its process list cannot be read, or a
                    recording looks to be in progress
  --device <id>     CoreDevice identifier, UDID or name, when more than one
                    iPhone is connected
  -h, --help        this text

A pack is skipped when its size + sha256 equal what was last pushed to this
device (stamp file osm/.push_packs_stamps.tsv, git-ignored) AND the phone
still has it: installed in the app's store (<name>-<contentHash>.roadpack,
same size, and not marked for removal; the content hash is read from the pack
header) or still waiting in the inbox (same name and size). A store file the
app marked for removal ("Remove" while Navigate or Record ran; it is deleted
at the next launch) does not count, and if the marks
(RoadPackStoreState.json in the store) cannot be read, no store file counts.
If the phone's Documents cannot be listed, the stamp alone decides (a pack
deleted or removed on the phone is then not re-pushed; use --force).
Pushing a pack the app already has is harmless: the app finds the same file
in its store and only empties the inbox (and clears a removal mark on it).
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
# result.runningProcesses array, an empty one (a phone always runs
# processes, so an empty list means the read failed, not "app closed"), or
# no entry with a string `executable` (the shape changed: refuse, R60.1-1).
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
named = 0
for p in procs:
    exe = p.get("executable") if isinstance(p, dict) else None
    if not isinstance(exe, str):
        continue
    named += 1
    path = urllib.parse.unquote(urllib.parse.urlparse(exe).path if exe.startswith("file:") else exe)
    if path.endswith(suffix):
        hits.append("%s %s" % (p.get("processIdentifier", "?"), path))
if not named:
    sys.exit(2)
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
store_dir="Library/Application Support/RoadPacks"
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

# Two guards keep pushes and the running app apart. The app maps packs only
# from its private store, never from the inbox, so a push cannot SIGBUS it;
# but it reads the inbox only at launch (a push while it runs waits for the
# next launch), and devicectl writes in place (no temp-name-and-rename), so a
# push overlapping a launch can hand the installer a half-written file (it is
# refused and retried at the following launch). Both guards are checked once,
# before the first copy: launching the app while the script copies is not
# detected.
#
# Guard 1: the app process is running. Navigate (UX-1) runs whenever the app
# runs and OBD polls, without writing any log, so guard 2 cannot see it. A
# suspended app is still running, hence "swipe it away". The process
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
    refuse "the app is running (it installs pushed packs only at its next launch)" \
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

# Phone listing of the app's pack store: "fileName<TAB>size". The directory
# exists once the app with the store has launched; if it cannot be listed but
# Documents could, the store counts as empty (a pack is pushed again, which
# the app handles as already installed).
store_listing=""
if [ $listing_ok -eq 1 ]; then
  if store_json="$(xcrun devicectl device info files --device "$device_id" \
        --domain-type appDataContainer --domain-identifier "$bundle_id" \
        --subdirectory "$store_dir" --quiet --json-output - 2>/dev/null)"; then
    store_listing="$(printf '%s' "$store_json" | /usr/bin/python3 -I -c '
import json, sys
for f in json.load(sys.stdin)["result"].get("files", []):
    if f["resources"].get("isDirectory"):
        continue
    print("%s\t%d" % (f["relativePath"].split("/")[-1], f["metadata"]["size"]))
')" || store_listing=""
  else
    echo "note: could not list the app's pack store ($store_dir); treating it as empty." >&2
  fi
fi

# Store files marked for removal ("Remove" while Navigate or Record ran): they
# are still on disk but the next launch deletes them, so they do not count as
# installed (R65.1-4). The marks live in <store>/RoadPackStoreState.json,
# {"markedForRemoval":[<file name>...],"version":1}; the app deletes the file
# when no mark is left, so no state file = no marks. If it is listed but cannot
# be read, no store file counts as installed (copy rather than skip on a guess).
state_file_name="RoadPackStoreState.json"
marked_names=""
store_marks_ok=1
if printf '%s\n' "$store_listing" | awk -F'\t' -v p="$state_file_name" '$1==p {f=1} END {exit !f}'; then
  store_marks_ok=0
  if xcrun devicectl device copy from --device "$device_id" \
       --domain-type appDataContainer --domain-identifier "$bundle_id" \
       --source "$store_dir/$state_file_name" --destination "$tmp_dir/$state_file_name" \
       --quiet > /dev/null 2>&1; then
    if marked_names="$(/usr/bin/python3 -I -c '
import json, sys
with open(sys.argv[1]) as f:
    marks = json.load(f)["markedForRemoval"]
if not isinstance(marks, list) or not all(isinstance(m, str) for m in marks):
    sys.exit(1)
print("\n".join(marks))
' "$tmp_dir/$state_file_name" 2>/dev/null)"; then
      store_marks_ok=1
    fi
  fi
  if [ $store_marks_ok -eq 0 ]; then
    marked_names=""
    echo "note: could not read the app's removal marks ($store_dir/$state_file_name); no store file counts as installed." >&2
  elif [ -n "$marked_names" ]; then
    echo "Store files marked for removal (deleted at the app's next launch; not counted as installed):"
    printf '%s\n' "$marked_names" | sed 's/^/  /'
  fi
fi

# The store file name the app gives a pack file: <name>-<contentHash>.roadpack,
# <name> = the file name without .roadpack (or without -<16 hex>.roadpack),
# the content hash = header bytes 16..23, little-endian, as 16 hex digits
# (docs/ROAD_PACK.md "Header"). Empty when the app would refuse the name.
store_name() {
  /usr/bin/python3 -I -c '
import re, sys
path, file = sys.argv[1], sys.argv[2]
stem = file[:-len(".roadpack")]
m = re.fullmatch(r"(.+)-[0-9a-f]{16}", stem)
name = m.group(1) if m else stem
if not (1 <= len(name) <= 64 and re.fullmatch(r"[a-z0-9_-]+", name)) or name[0] == "-" or name[-1] == "-":
    sys.exit(0)
with open(path, "rb") as f:
    head = f.read(24)
if len(head) < 24:
    sys.exit(0)
print("%s-%016x.roadpack" % (name, int.from_bytes(head[16:24], "little")))
' "$1" "$2"
}

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
  inbox_size="$(printf '%s\n' "$listing" | awk -F'\t' -v p="RoadPacks/$name" '$1==p {print $2}' | head -n 1)"
  stored="$(store_name "$src" "$name")"
  [ -n "$stored" ] || echo "warning: $name: the app will refuse this file name (a-z, 0-9, _ and -; no leading or trailing -)." >&2
  stored_size=""
  [ -n "$stored" ] && stored_size="$(printf '%s\n' "$store_listing" | awk -F'\t' -v p="$stored" '$1==p {print $2}' | head -n 1)"
  # A marked store file, or any store file when the marks cannot be read, is not installed.
  if [ -n "$stored_size" ]; then
    if [ $store_marks_ok -eq 0 ] || printf '%s\n' "$marked_names" | grep -xF -- "$stored" > /dev/null; then
      stored_size=""
    fi
  fi

  unchanged=0
  if [ $force -eq 0 ] && [ "$stamp" = "$size	$sha" ]; then
    if [ $listing_ok -eq 0 ] || [ "$stored_size" = "$size" ] || [ "$inbox_size" = "$size" ]; then unchanged=1; fi
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
  echo "Next: launch the app (it installs the packs from the inbox at launch), then check Settings > Diagnostics shows them Verified and no inbox refusal."
fi
[ $failed -eq 0 ] || exit 1
