#!/bin/bash
# PreToolUse (Bash): docs/REVIEW_LOG.md and docs/archive/** are append-only.
# Blocks a command that commits (`git ... commit`, any form) while those
# files, in the working tree, have lost more than 5 lines against HEAD.
# A line counts as lost only if its exact text is not added back anywhere
# in them, so moving runs to docs/archive/ passes and truncating or
# rewriting does not. Working tree, not the index: the hook runs before
# the whole command, so `git add ... && git commit` has staged nothing yet.
# Moving rows out of docs/BACKLOG.md is not affected. Exit 2 = the command
# is not run and stderr goes to Claude.
# Override: APPEND_ONLY_OVERRIDE=1 in the environment Claude Code was
# started with (the user's shell). A command that names it is refused.
input=$(cat)
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
require_jq "$input"
cmd=$(jq -r '.tool_input.command // empty' <<<"$input")

# Any command with `git` and the word `commit` (not commit-tree): quoting,
# `sh -c`, global options and pathspecs don't hide it. A false match costs
# one diff, and blocks only when the files really lost lines.
re_git='(^|[^[:alnum:]_.-])git([^[:alnum:]_.-]|$)'
re_commit='(^|[^[:alnum:]_-])commit([^[:alnum:]_-]|$)'
[[ "$cmd" =~ $re_git && "$cmd" =~ $re_commit ]] || exit 0

if [[ "$cmd" == *APPEND_ONLY_OVERRIDE* ]]; then
  echo "append-only guard: APPEND_ONLY_OVERRIDE is set by the user in their own shell, never in a command. Refused." >&2
  exit 2
fi
[[ "$APPEND_ONLY_OVERRIDE" == 1 ]] && exit 0

# The tree the commit runs in: `git -C <path> ... commit`, else the last
# `cd <path>` in the command, else the session's cwd (also the fallback
# when the parsed path is not in this repo).
cwd=$(jq -r '.cwd // empty' <<<"$input")
dir="${cwd:-.}"
re_cd='(^|[;&|({[:space:]])cd[[:space:]]+([^[:space:];&|]+)'
rest="$cmd"
while [[ "$rest" =~ $re_cd ]]; do
  p="${BASH_REMATCH[2]}"
  [[ "$p" == /* || "$p" == \~* ]] && dir="$p" || dir="$dir/$p"
  rest="${rest#*"${BASH_REMATCH[0]}"}"
done
re_dashc='git[[:space:]]+-C[[:space:]]+([^[:space:];&|]+)[^;&|]*[[:space:]]commit([[:space:]]|$)'
if [[ "$cmd" =~ $re_dashc ]]; then
  p="${BASH_REMATCH[1]}"
  [[ "$p" == /* || "$p" == \~* ]] && dir="$p" || dir="$dir/$p"
fi
dir="${dir/#\~/$HOME}"
root=$(repo_root "$dir") || root=$(repo_root "${cwd:-.}") || exit 0

# Lines removed from the guarded files (working tree vs HEAD, staged or
# not) whose text is not added back in them. A new archive file that is
# not tracked yet (runs moved out of REVIEW_LOG) counts as added text.
lost=$( {
  git -C "$root" diff HEAD -U0 --no-renames --no-color -- docs/REVIEW_LOG.md docs/archive 2>/dev/null
  git -C "$root" ls-files -z --others --exclude-standard -- docs/archive 2>/dev/null |
    while IFS= read -r -d '' f; do sed 's/^/+/' "$root/$f"; done
} | awk '
  /^--- (a\/|\/dev\/null)/ || /^\+\+\+ (b\/|\/dev\/null)/ { next }
  /^Binary files/ { bin++ ; next }
  /^-/ { del[substr($0, 2)]++ ; next }
  /^\+/ { add[substr($0, 2)]++ ; next }
  END {
    n = 0
    for (l in del) { d = del[l] - add[l]; if (d > 0) n += d }
    print n + bin * 1000000
  }')

if (( lost > 5 )); then
  {
    echo "append-only guard: docs/REVIEW_LOG.md / docs/archive/** in $root have lost $lost lines against HEAD (removed and not added back):"
    git -C "$root" diff HEAD --numstat --no-renames -- docs/REVIEW_LOG.md docs/archive | awk '$2 > 0 { print "  " $3 ": -" $2 " +" $1 }'
    echo "These files only grow: append, or move text unchanged; never rewrite or truncate."
    echo "Compare with HEAD (git diff HEAD -- docs/REVIEW_LOG.md docs/archive) and restore what was lost. Only the user can override (APPEND_ONLY_OVERRIDE=1 in their own shell)."
  } >&2
  exit 2
fi
exit 0
