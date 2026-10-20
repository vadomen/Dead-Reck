#!/usr/bin/env bash
# Bump CURRENT_PROJECT_VERSION (the integer build number, CFBundleVersion) in
# project.yml by one and regenerate DriveLogger.xcodeproj. Run once per App
# Store Connect upload: every upload of the same MARKETING_VERSION needs a
# higher build number. Commit project.yml and the regenerated project together.
#
# Usage: scripts/bump_build.sh [--dry-run]
set -euo pipefail

dry_run=0
case "${1:-}" in
  "") ;;
  --dry-run) dry_run=1 ;;
  -h|--help)
    sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  *) echo "bump_build.sh: unknown argument: $1" >&2; exit 2 ;;
esac

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
spec="$repo_root/project.yml"
[ -f "$spec" ] || { echo "bump_build.sh: $spec not found" >&2; exit 1; }

# Exactly one CURRENT_PROJECT_VERSION line, holding a plain integer (quoted or
# not). Anything else is refused rather than guessed at.
pattern='^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?[0-9]+"?[[:space:]]*(#.*)?$'
count="$(grep -cE "$pattern" "$spec" || true)"
total="$(grep -cE '^[[:space:]]*CURRENT_PROJECT_VERSION:' "$spec" || true)"
if [ "$count" != "1" ] || [ "$total" != "1" ]; then
  echo "bump_build.sh: expected exactly one integer CURRENT_PROJECT_VERSION in project.yml, found $total line(s), $count integer" >&2
  exit 1
fi

old="$(grep -E "$pattern" "$spec" | sed -E 's/^[^:]*:[[:space:]]*"?([0-9]+)"?.*$/\1/')"
new=$((10#$old + 1))

if [ "$dry_run" = 1 ]; then
  echo "CURRENT_PROJECT_VERSION $old -> $new (dry run, nothing changed)"
  exit 0
fi

command -v xcodegen >/dev/null 2>&1 || { echo "bump_build.sh: xcodegen not found on PATH" >&2; exit 1; }

# Write the edit to a temporary file (no `sed -i`, whose syntax differs between
# BSD/macOS and GNU sed), check it, then copy it over project.yml in place so a
# failed edit never leaves a half-written spec and the file keeps its mode.
tmp="$(mktemp "${TMPDIR:-/tmp}/project.yml.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
sed -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*)\"?[0-9]+\"?/\1\"$new\"/" "$spec" > "$tmp"
grep -qE "^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*\"$new\"" "$tmp" \
  || { echo "bump_build.sh: edit did not apply; project.yml unchanged" >&2; exit 1; }
[ "$(wc -l < "$tmp")" = "$(wc -l < "$spec")" ] \
  || { echo "bump_build.sh: line count changed; project.yml unchanged" >&2; exit 1; }
cat "$tmp" > "$spec"

(cd "$repo_root" && xcodegen generate --spec project.yml)
echo "CURRENT_PROJECT_VERSION $old -> $new; DriveLogger.xcodeproj regenerated. Commit project.yml and DriveLogger.xcodeproj."
