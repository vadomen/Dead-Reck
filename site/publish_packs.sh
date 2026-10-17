#!/usr/bin/env bash
# Upload osm/packs/*.roadpack to the R2 bucket behind https://fugps.pages.dev/packs/
# and publish packs/manifest.json pointing at them.
#
#   site/publish_packs.sh [--dry-run] [--bucket <name>]
#
# Pack objects are content-addressed (packs/v1/<name>-<contentHash>.roadpack) and
# immutable, so a re-run only changes the manifest. The manifest is uploaded last,
# so it never points at an object that is not there yet.
# Needs: python3, npx wrangler (logged in: `npx wrangler login`).
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

dry_run=0
bucket="fugps-packs"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --bucket) [ $# -ge 2 ] || die "--bucket needs a value"; bucket="$2"; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

site_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$site_dir/.." && pwd)"
packs_dir="$repo_root/osm/packs"
build_dir="$site_dir/.packs-build"
manifest="$build_dir/manifest.json"
uploads="$build_dir/uploads.tsv"

[ -d "$packs_dir" ] || die "osm/packs not found. Build the road packs first (docs/N3_PLAN.md)."
mkdir -p "$build_dir"

# Validate each pack's header and write the manifest + the upload list.
/usr/bin/env python3 -I - "$packs_dir" "$manifest" "$uploads" <<'PY'
import sys, os, json, hashlib, struct, glob, datetime
packs_dir, manifest_path, uploads_path = sys.argv[1:4]
MAGIC = b"DLRPACK\x00"; HEADER = 96; MAX = 150_000_000
files = sorted(glob.glob(os.path.join(packs_dir, "*.roadpack")))
if not files: sys.exit("error: no .roadpack files in osm/packs")
packs, uploads = [], []
for path in files:
    name = os.path.basename(path)[:-len(".roadpack")]
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        head = f.read(HEADER)
    def fail(msg): sys.exit(f"error: {name}: {msg}")
    if len(head) < HEADER: fail("shorter than the header")
    if head[:8] != MAGIC: fail("bad magic, not a road pack")
    version, header_size = struct.unpack_from("<HH", head, 8)
    if header_size != HEADER: fail(f"headerSize {header_size}, expected {HEADER}")
    content_hash, declared = struct.unpack_from("<QQ", head, 16)
    if declared != size: fail(f"header declares {declared} bytes, file has {size}")
    if size > MAX: fail(f"{size} bytes is over the {MAX} byte limit (Q1)")
    (osm_ts,) = struct.unpack_from("<q", head, 48)
    sha = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""): sha.update(chunk)
    chash = f"{content_hash:016x}"
    key = f"packs/v1/{name}-{chash}.roadpack"
    entry = {
        "name": name,
        "url": "/" + key,
        "size": size,
        "sha256": sha.hexdigest(),
        "contentHash": chash,
        "formatVersion": version,
        "osmTimestamp": osm_ts,
    }
    if osm_ts > 0:
        entry["osmDate"] = datetime.datetime.fromtimestamp(osm_ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    packs.append(entry)
    uploads.append((path, key))
    print(f"  {name}: {size/1e6:.1f} MB  sha256 {entry['sha256'][:12]}…  contentHash {chash}  -> {key}")
manifest = {
    "schema": 1,
    "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "attribution": "© OpenStreetMap contributors",
    "license": "ODbL 1.0",
    "licenseUrl": "https://opendatacommons.org/licenses/odbl/1-0/",
    "packs": packs,
}
with open(manifest_path, "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True, ensure_ascii=False); f.write("\n")
with open(uploads_path, "w") as f:
    for p, k in uploads: f.write(f"{p}\t{k}\n")
PY

echo "manifest: $manifest"
if [ "$dry_run" = 1 ]; then
  echo "dry run: nothing uploaded"; exit 0
fi

put() { # <file> <key> <content-type> <cache-control>
  npx --yes wrangler r2 object put "$bucket/$2" --remote \
    --file "$1" --content-type "$3" --cache-control "$4"
}

while IFS=$'\t' read -r file key; do
  echo "uploading $key"
  put "$file" "$key" "application/octet-stream" "public, max-age=31536000, immutable"
done < "$uploads"

echo "uploading packs/manifest.json"
put "$manifest" "packs/manifest.json" "application/json; charset=utf-8" "public, max-age=300"

echo "done: https://fugps.pages.dev/packs/manifest.json"
