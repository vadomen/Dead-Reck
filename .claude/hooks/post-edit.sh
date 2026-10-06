#!/bin/bash
# PostToolUse (Edit|Write): fast feedback after each file change.
# Exit 2 = stderr is shown to Claude as feedback (the edit is not undone).
input=$(cat)
file=$(jq -r '.tool_input.file_path // empty' <<<"$input")
tool=$(jq -r '.tool_name // empty' <<<"$input")
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
source .claude/hooks/env.sh
rel="${file#"$PWD"/}"

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

# Core Swift changed -> incremental build of the package incl. tests (seconds).
if [[ "$rel" == Core/*.swift ]]; then
  if ! out=$(cd Core && swift build --build-tests 2>&1); then
    echo "Core build failed after editing $rel:" >&2
    grep -E 'error:' <<<"$out" | head -15 >&2
    exit 2
  fi
  # Invariant: Core imports Foundation only.
  bad=$(grep -hoE '^[[:space:]]*import[[:space:]]+(UIKit|SwiftUI|CoreBluetooth|CoreMotion|CoreLocation|MapKit|Combine)\b' "$file" 2>/dev/null)
  if [[ -n "$bad" ]]; then
    echo "Core must not import Apple UI/hardware frameworks ($bad) in $rel - convert at the app boundary." >&2
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
