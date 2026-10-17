#!/bin/bash
# Stop: do not let a turn end with failing Core tests.
# Exit 2 = Claude must continue and fix. Guarded against loops.
input=$(cat)
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
require_jq "$input"
[[ "$(jq -r '.stop_hook_active // false' <<<"$input")" == "true" ]] && exit 0

# The tree the session works in (a worktree, or the main tree).
cwd=$(jq -r '.cwd // empty' <<<"$input")
root=$(repo_root "${cwd:-.}") || root="${CLAUDE_PROJECT_DIR:-.}"
cd "$root" || exit 0

# Only run when Core changed relative to HEAD (incl. untracked files).
changed=$( { git diff --name-only HEAD; git ls-files --others --exclude-standard; } 2>/dev/null | grep -E '^Core/.*\.swift$')
[[ -z "$changed" ]] && exit 0

if ! out=$(cd Core && swift test --parallel 2>&1); then
  echo "Core tests fail in $root (cd Core && swift test) - fix before finishing:" >&2
  # ✘ = Swift Testing issue; not 'failed', which matches test titles in
  # "◇ started" lines and expected-failure ("━ known issue") lines.
  grep -E 'error:|✘' <<<"$out" | head -20 >&2
  exit 2
fi
exit 0
