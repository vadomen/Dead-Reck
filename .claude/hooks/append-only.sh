#!/bin/bash
# PreToolUse (Bash): docs/REVIEW_LOG.md and docs/archive/** are append-only.
# Blocks a `git commit` whose diff removes more than 5 lines from them
# (counted together, renames as delete + add). Moving rows out of
# docs/BACKLOG.md is not affected. Exit 2 = the command is not run and
# stderr goes to Claude.
# Override: APPEND_ONLY_OVERRIDE=1 in the environment Claude Code was
# started with (the user's shell). A command that sets it itself is refused.
input=$(cat)
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
require_jq "$input"
cmd=$(jq -r '.tool_input.command // empty' <<<"$input")

# git [-C <path>] [-c <k=v>]... commit
re_commit='(^|[;&|({[:space:]])git([[:space:]]+-(C|c)[[:space:]]+[^[:space:];&|]+)*[[:space:]]+commit([[:space:]]|$)'
[[ "$cmd" =~ $re_commit ]] || exit 0

if [[ "$cmd" == *APPEND_ONLY_OVERRIDE* ]]; then
  echo "append-only guard: APPEND_ONLY_OVERRIDE is set by the user in their own shell, never in a command. Commit refused." >&2
  exit 2
fi
[[ "$APPEND_ONLY_OVERRIDE" == 1 ]] && exit 0

# The tree the commit runs in: `git -C <path> ... commit`, else the last
# `cd <path>` in the command, else the session's cwd.
cwd=$(jq -r '.cwd // empty' <<<"$input")
dir="${cwd:-.}"
re_cd='(^|[;&|({[:space:]])cd[[:space:]]+([^[:space:];&|]+)'
rest="$cmd"
while [[ "$rest" =~ $re_cd ]]; do
  p="${BASH_REMATCH[2]}"
  [[ "$p" == /* ]] && dir="$p" || dir="$dir/$p"
  rest="${rest#*"${BASH_REMATCH[0]}"}"
done
re_dashc='git[[:space:]]+-C[[:space:]]+([^[:space:];&|]+)[^;&|]*[[:space:]]commit([[:space:]]|$)'
if [[ "$cmd" =~ $re_dashc ]]; then
  p="${BASH_REMATCH[1]}"
  [[ "$p" == /* ]] && dir="$p" || dir="$dir/$p"
fi
dir="${dir/#\~/$HOME}"
root=$(repo_root "$dir") || exit 0

# `commit -a`/`--all` commits unstaged changes too: compare with HEAD.
re_all='[[:space:]](-[A-Za-z]*a[A-Za-z]*|--all)([[:space:]]|$)'
if [[ "$cmd" =~ $re_all ]]; then
  stat=$(git -C "$root" diff HEAD --numstat --no-renames 2>/dev/null)
else
  stat=$(git -C "$root" diff --cached --numstat --no-renames 2>/dev/null)
fi

removed=0
files=""
while IFS=$'\t' read -r add del path; do
  case "$path" in
    docs/REVIEW_LOG.md|docs/archive/*)
      [[ "$del" =~ ^[0-9]+$ ]] || del=999999   # binary: treat as removed
      if (( del > 0 )); then
        removed=$((removed + del))
        files+="  $path: -$del"$'\n'
      fi ;;
  esac
done <<<"$stat"

if (( removed > 5 )); then
  {
    echo "append-only guard: this commit removes $removed lines from append-only files in $root:"
    printf '%s' "$files"
    echo "docs/REVIEW_LOG.md and docs/archive/** only grow: append, never rewrite or truncate."
    echo "Check the file against HEAD (git diff --cached) and restore what was lost. Only the user can override (APPEND_ONLY_OVERRIDE=1 in their own shell)."
  } >&2
  exit 2
fi
exit 0
