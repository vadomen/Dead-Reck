#!/bin/bash
# PostToolUse (Edit|Write): fast feedback after each file change.
# Exit 2 = stderr is shown to Claude as feedback (the edit is not undone).
input=$(cat)
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
require_jq "$input"
file=$(jq -r '.tool_input.file_path // empty' <<<"$input")
tool=$(jq -r '.tool_name // empty' <<<"$input")
[[ -n "$file" ]] || exit 0

# Checks run against the tree that holds the file: the main tree or a
# worktree (../dead-reck-<task>, .claude/worktrees/*). Files outside the repo
# (scratchpad, memory) are not checked.
dir=$(cd "$(dirname "$file")" 2>/dev/null && pwd -P) || exit 0
root=$(repo_root "$dir") || exit 0
cd "$root" || exit 0
abs="$dir/$(basename "$file")"
rel="${abs#"$root"/}"

# Never let recordings into the repo tree outside logs/.
case "$rel" in
  *.jsonl|*.jsonl.gz)
    case "$rel" in logs/*) ;; *) echo "Drive recordings must live only in logs/ (git-ignored): $rel" >&2; exit 2 ;; esac ;;
esac

# Generated project must never be hand-edited.
if [[ "$rel" == DriveLogger.xcodeproj/* ]]; then
  echo "DriveLogger.xcodeproj is generated: edit project.yml and run 'xcodegen generate' instead." >&2
  exit 2
fi

if [[ "$rel" == Core/*.swift ]]; then
  # Invariant: Core imports Foundation and nothing else from Apple. Allowlist:
  # anything not named here fails, so a new framework can't slip past.
  allowed=" Foundation Testing DriveLoggerCore RoadPackBuild "
  [[ "$rel" == Core/Package.swift ]] && allowed+="PackageDescription "
  bad=""
  while IFS= read -r line; do
    mod=$(sed -nE 's/^([0-9]+):[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*).*/\5/p' <<<"$line")
    [[ -n "$mod" && "$allowed" != *" $mod "* ]] && bad+="  line ${line%%:*}: $mod"$'\n'
  done < <(grep -nE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]' "$abs" 2>/dev/null)
  if [[ -n "$bad" ]]; then
    printf 'Core may import only%s(convert at the app boundary). Not allowed in %s:\n%s' "$allowed" "$rel" "$bad" >&2
    exit 2
  fi

  # Core Swift changed -> incremental build of the package incl. tests (seconds).
  if ! out=$(cd Core && swift build --build-tests 2>&1); then
    echo "Core build failed after editing $rel:" >&2
    grep -E 'error:' <<<"$out" | head -15 >&2
    exit 2
  fi
fi

# New app/test source file -> must be registered via XcodeGen.
if [[ "$tool" == "Write" && ( "$rel" == App/*.swift || "$rel" == AppTests/*.swift ) ]]; then
  base=$(basename "$rel")
  if ! grep -q "$base" DriveLogger.xcodeproj/project.pbxproj 2>/dev/null; then
    echo "New file $rel is not in the Xcode project yet: run 'xcodegen generate' before building and commit the regenerated project." >&2
    exit 2
  fi
fi

if [[ "$rel" == project.yml ]]; then
  echo "project.yml changed: run 'xcodegen generate' and commit the regenerated project with it." >&2
  exit 2
fi
exit 0
