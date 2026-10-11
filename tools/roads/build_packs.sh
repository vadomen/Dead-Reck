#!/usr/bin/env bash
# Build road packs from an OSM extract (docs/ROAD_PACK.md, docs/N3_PLAN.md).
#
#   tools/roads/build_packs.sh [osm/packs.json] [--source <file.osm.pbf>] [--only <pack name>]
#
# Driven by osm/packs.json, which is git-ignored because its relation IDs
# reveal where someone drives:
#
#   {
#     "source": "osm/src/<country>-latest.osm.pbf",
#     "cellSizeM": 64, "searchRadiusM": 50,
#     "packs": [
#       {"name": "national", "classes": "national", "relation": <country relation>, "adminLevel": 2, "cut": false},
#       {"name": "region-A", "classes": "region",   "relation": <admin relation>,   "adminLevel": 4, "cut": true}
#     ]
#   }
#
# - classes: "national", "region" or a comma-separated list of highway values.
# - relation (optional): an admin boundary in the source. It is the pack's
#   coverage polygon (COVR); with "cut": true (the default when a relation is
#   given) the pack's roads are also cut out by it with
#   `osmium extract --strategy complete_ways`.
# - Every pack of one run shares one grid: the source's header bounding box,
#   cellSizeM and searchRadiusM. So the packs can be loaded together.
#
# Paths in packs.json are relative to the repository root. Work files go to
# osm/work/, packs to osm/packs/<name>.roadpack. The osmium version, the
# source's SHA-256 and replication timestamp, and the builder's git commit go
# into each pack's META. A pack over 150 MB is not written (build_roads exits
# with status 3); split the region at admin_level 6.
#
# Needs osmium-tool (brew install osmium-tool), jq, shasum and the Xcode
# toolchain (DEVELOPER_DIR is set to Xcode if xcode-select points elsewhere).
#
# Data: © OpenStreetMap contributors, ODbL 1.0.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="$ROOT/osm/packs.json"
SOURCE_OVERRIDE=""
ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --source) SOURCE_OVERRIDE="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
        -*) echo "build_packs: unknown option $1" >&2; exit 2 ;;
        *) CONFIG="$1"; shift ;;
    esac
done

for tool in osmium jq shasum; do
    command -v "$tool" >/dev/null || { echo "build_packs: $tool not found" >&2; exit 1; }
done
[ -f "$CONFIG" ] || { echo "build_packs: no config at $CONFIG" >&2; exit 2; }
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ] \
    && [ "$(xcode-select -p 2>/dev/null)" != /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

abspath() { case "$1" in /*) echo "$1" ;; *) echo "$ROOT/$1" ;; esac; }

SOURCE="$(abspath "${SOURCE_OVERRIDE:-$(jq -r '.source' "$CONFIG")}")"
[ -f "$SOURCE" ] || { echo "build_packs: source $SOURCE not found" >&2; exit 1; }
CELL="$(jq -r '.cellSizeM // 64' "$CONFIG")"
RADIUS="$(jq -r '.searchRadiusM // 50' "$CONFIG")"
WORK="$ROOT/osm/work"
PACKS="$ROOT/osm/packs"
mkdir -p "$WORK" "$PACKS"

NATIONAL="motorway,motorway_link,trunk,trunk_link,primary,primary_link"
REGION="$NATIONAL,secondary,secondary_link,tertiary,tertiary_link,unclassified,residential,living_street,service,road"
classes_of() {
    case "$1" in national) echo "$NATIONAL" ;; region) echo "$REGION" ;; *) echo "$1" ;; esac
}

now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
elapsed() { perl -e "printf '%.2f', $2 - $1"; }

# --- Source metadata --------------------------------------------------------
OSMIUM_VERSION="$(osmium --version | head -1 | awk '{print $3}')"
# Geofabrik writes the replication timestamp as a header option; fall back
# to the generic header timestamp, else unknown (0).
OSM_TS="$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$SOURCE")"
[ -n "$OSM_TS" ] || OSM_TS="$(osmium fileinfo -g header.option.timestamp "$SOURCE")"
[ -n "$OSM_TS" ] || OSM_TS=0
# The grid family box: the header's bounding box, else a full scan.
BBOX="$(osmium fileinfo -g header.boxes "$SOURCE" | head -1 | tr -d '() ')"
[ -n "$BBOX" ] || BBOX="$(osmium fileinfo -e -g data.bbox "$SOURCE" | tr -d '() ')"
SHA256="$(shasum -a 256 "$SOURCE" | awk '{print $1}')"
COMMIT="$(git -C "$ROOT" rev-parse --short=12 HEAD)"
git -C "$ROOT" diff --quiet HEAD -- Core || COMMIT="$COMMIT-dirty"
echo "source $(basename "$SOURCE"): osmTimestamp $OSM_TS, grid box $BBOX, osmium $OSMIUM_VERSION, builder $COMMIT"

# --- build_roads ------------------------------------------------------------
swift build -c release --package-path "$ROOT/Core" --product build_roads >/dev/null
BUILD_ROADS="$(swift build -c release --package-path "$ROOT/Core" --show-bin-path)/build_roads"

COUNT="$(jq '.packs | length' "$CONFIG")"
selected() { [ -z "$ONLY" ] || [ "$1" = "$ONLY" ]; }

# --- One pass over the source: every class any pack needs -------------------
ALL_CLASSES="$(for i in $(seq 0 $((COUNT - 1))); do
    selected "$(jq -r ".packs[$i].name" "$CONFIG")" || continue
    classes_of "$(jq -r ".packs[$i].classes // \"region\"" "$CONFIG")" | tr ',' '\n'
done | sort -u | paste -sd, -)"
[ -n "$ALL_CLASSES" ] || { echo "build_packs: no pack selected" >&2; exit 2; }
t0="$(now)"
osmium tags-filter --overwrite --no-progress "$SOURCE" "w/highway=$ALL_CLASSES" -o "$WORK/roads.osm.pbf"
echo "roads filter: $(elapsed "$t0" "$(now)") s"

NEED_ADMIN="$(jq '[.packs[] | select(.relation != null)] | length' "$CONFIG")"
if [ "$NEED_ADMIN" -gt 0 ]; then
    t0="$(now)"
    osmium tags-filter --overwrite --no-progress "$SOURCE" r/boundary=administrative -o "$WORK/admin.osm.pbf"
    echo "admin filter: $(elapsed "$t0" "$(now)") s"
fi

# --- Boundaries: one GeoJSON polygon per relation ----------------------------
# `getid -r` alone also pulls in the relation's subarea relations (with
# their tags), which osmium then merges into the polygon as overlapping
# rings; `-t` strips tags from everything not asked for, and the export is
# narrowed to the one relation with jq.
EXTRACTS="$WORK/extracts.json"
echo '{"directory": "'"$WORK"'", "extracts": []}' > "$EXTRACTS"
for i in $(seq 0 $((COUNT - 1))); do
    NAME="$(jq -r ".packs[$i].name" "$CONFIG")"
    selected "$NAME" || continue
    REL="$(jq -r ".packs[$i].relation // empty" "$CONFIG")"
    [ -n "$REL" ] || continue
    osmium getid --overwrite --no-progress -r -t "$WORK/admin.osm.pbf" "r$REL" -o "$WORK/boundary-$NAME.osm.pbf"
    osmium export --overwrite --no-progress "$WORK/boundary-$NAME.osm.pbf" --geometry-types=polygon -a type,id \
        -f geojsonseq -x print_record_separator=false -o "$WORK/boundary-$NAME.geojsonseq"
    jq -c "select(.properties.\"@type\" == \"relation\" and .properties.\"@id\" == $REL) \
        | {type: \"Feature\", properties: {}, geometry: .geometry}" \
        "$WORK/boundary-$NAME.geojsonseq" > "$WORK/boundary-$NAME.geojson"
    [ -s "$WORK/boundary-$NAME.geojson" ] || { echo "build_packs: $NAME: relation did not assemble into a polygon" >&2; exit 1; }
    if [ "$(jq -r ".packs[$i] | if .cut == false then \"false\" else \"true\" end" "$CONFIG")" = true ]; then
        jq --arg out "$NAME.osm.pbf" --arg poly "$WORK/boundary-$NAME.geojson" \
            '.extracts += [{output: $out, polygon: {file_name: $poly, file_type: "geojson"}}]' \
            "$EXTRACTS" > "$EXTRACTS.tmp" && mv "$EXTRACTS.tmp" "$EXTRACTS"
    fi
done

# --- All cut regions in one extract pass ------------------------------------
if [ "$(jq '.extracts | length' "$EXTRACTS")" -gt 0 ]; then
    t0="$(now)"
    osmium extract --overwrite --no-progress -c "$EXTRACTS" --strategy complete_ways "$WORK/roads.osm.pbf"
    echo "extract: $(elapsed "$t0" "$(now)") s"
fi

# --- Per pack: classes, locations, build -------------------------------------
for i in $(seq 0 $((COUNT - 1))); do
    NAME="$(jq -r ".packs[$i].name" "$CONFIG")"
    selected "$NAME" || continue
    CLASSES="$(classes_of "$(jq -r ".packs[$i].classes // \"region\"" "$CONFIG")")"
    REL="$(jq -r ".packs[$i].relation // empty" "$CONFIG")"
    LEVEL="$(jq -r ".packs[$i].adminLevel // empty" "$CONFIG")"
    CUT="$(jq -r ".packs[$i] | if .cut == false then \"false\" else \"true\" end" "$CONFIG")"
    t0="$(now)"
    if [ -n "$REL" ] && [ "$CUT" = true ]; then INPUT="$WORK/$NAME.osm.pbf"; STRATEGY=complete_ways
    else INPUT="$WORK/roads.osm.pbf"; STRATEGY=none; fi
    if [ "$CLASSES" != "$ALL_CLASSES" ]; then
        osmium tags-filter --overwrite --no-progress "$INPUT" "w/highway=$CLASSES" -o "$WORK/$NAME.classes.osm.pbf"
        INPUT="$WORK/$NAME.classes.osm.pbf"
    fi
    osmium add-locations-to-ways --overwrite --no-progress "$INPUT" -f opl -o "$WORK/$NAME.opl"
    t1="$(now)"
    ARGS=("$WORK/$NAME.opl" --out "$PACKS/$NAME.roadpack" --classes "$CLASSES" --grid-bbox "$BBOX"
        --cell-size "$CELL" --radius "$RADIUS" --osm-timestamp "$OSM_TS" --source-name "$(basename "$SOURCE")"
        --source-sha256 "$SHA256" --osmium-version "$OSMIUM_VERSION" --strategy "$STRATEGY" --commit "$COMMIT")
    if [ -n "$REL" ]; then ARGS+=(--coverage "$WORK/boundary-$NAME.geojson" --relation-id "$REL"); fi
    if [ -n "$LEVEL" ]; then ARGS+=(--admin-level "$LEVEL"); fi
    "$BUILD_ROADS" "${ARGS[@]}"
    t2="$(now)"
    SIZE="$(stat -f %z "$PACKS/$NAME.roadpack")"
    [ "$SIZE" -le 150000000 ] || { echo "build_packs: $NAME is $SIZE bytes, over 150 MB" >&2; exit 3; }
    echo "$NAME: osmium $(elapsed "$t0" "$t1") s, build_roads $(elapsed "$t1" "$t2") s, $SIZE bytes"
    "$BUILD_ROADS" --info "$PACKS/$NAME.roadpack" | grep -E 'contentHash|verify'
done
