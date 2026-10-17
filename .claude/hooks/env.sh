# Shared by hooks: use full Xcode even if xcode-select points at CommandLineTools
# (CLT cannot load the Swift Testing macro plugin - see CLAUDE.md "Toolchain note").
if [[ -z "$DEVELOPER_DIR" && "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Without jq no hook can read its payload. Say so once per session (exit 2),
# then pass silently so the Stop hook cannot loop. $1 = the hook's stdin.
require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  local sid marker
  sid=$(sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' <<<"$1" | head -1)
  marker="${TMPDIR:-/tmp}/drivelogger-hooks-nojq-${sid:-nosession}"
  [[ -e "$marker" ]] && exit 0
  touch "$marker"
  echo "hooks disabled: install jq (brew install jq)" >&2
  exit 2
}

# Print the toplevel of the git tree containing $1 if it is this repo (main
# tree or any of its worktrees); fail otherwise.
repo_root() {
  local root common mine
  root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  if [[ -n "$CLAUDE_PROJECT_DIR" ]]; then
    common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    mine=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    [[ -n "$mine" && "$common" != "$mine" ]] && return 1
  fi
  printf '%s\n' "$root"
}
