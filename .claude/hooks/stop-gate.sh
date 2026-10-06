#!/bin/bash
# Stop: do not let a turn end with failing Core tests.
# Exit 2 = Claude must continue and fix. Guarded against loops.
input=$(cat)
[[ "$(jq -r '.stop_hook_active // false' <<<"$input")" == "true" ]] && exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
source .claude/hooks/env.sh

# Only run when Core changed relative to HEAD (incl. untracked files).
changed=$( { git diff --name-only HEAD; git ls-files --others --exclude-standard; } 2>/dev/null | grep -E '^Core/.*\.swift$')
[[ -z "$changed" ]] && exit 0

if ! out=$(cd Core && swift test 2>&1); then
  echo "Core tests fail (cd Core && swift test) - fix before finishing:" >&2
  grep -E 'error:|failed|✘' <<<"$out" | head -20 >&2
  exit 2
fi
exit 0
