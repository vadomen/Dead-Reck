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
Config/Local.xcconfig (PRODUCT_BUNDLE_IDENTIFIER).

  --dry-run         show copied / skipped per pack, copy nothing
  --force           copy even if a recording looks to be in progress
  --device <id>     CoreDevice identifier, UDID or name, when more than one
                    iPhone is connected
  -h, --help        this text

A pack is skipped when its size + sha256 equal what was last pushed to this
device (stamp file osm/.push_packs_stamps.tsv, git-ignored) AND the phone's
listing shows the file with the same size.

Do not copy during a recording: packs are memory-mapped from
Documents/RoadPacks and overwriting one in place can crash the app (SIGBUS).
USAGE
}

die() { echo "error: $*" >&2; exit 1; }

dry_run=0
force=0
device_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --force) force=1 ;;
    --device)
      [ $# -ge 2 ] || die "--device needs a value"
      device_arg="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# Recording in progress? Heuristic: a file under Documents/logs touched recently.
echo "Note: do not copy packs while a recording is running. Packs are memory-mapped by the app and"
echo "      devicectl overwrites them in place (no temp-name-and-rename available), which can crash it."
if [ $listing_ok -eq 1 ]; then
  recent="$(printf '%s\n' "$listing" | awk -F'\t' -v w="$recording_window_s" '$1 ~ /^logs\// && $3 <= w && $3 >= -w {print $1}')"
  if [ -n "$recent" ]; then
    echo "A recording file changed in the last ${recording_window_s} s (heuristic: log write times may lag, and clock skew is ignored):" >&2
    printf '  %s\n' $recent >&2
    if [ $force -eq 1 ]; then
      echo "--force given, continuing." >&2
    else
      die "a recording looks to be in progress. Stop it first, or re-run with --force."
    fi
  else
    echo "      (no log file on the phone changed in the last ${recording_window_s} s; this check is a heuristic, not proof.)"
  fi
else
  echo "      (recording detection unavailable without the phone listing.)"
fi

mkdir -p "$(dirname "$stamp_file")"
touch "$stamp_file"
new_stamps="$(mktemp)"
trap 'rm -f "$new_stamps"' EXIT

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
if [ $dry_run -eq 0 ] && [ $copied -gt 0 ]; then
  echo "Next: open the app, Settings > Diagnostics, and check the packs show Verified."
fi
[ $failed -eq 0 ] || exit 1
