# Shared by hooks: use full Xcode even if xcode-select points at CommandLineTools
# (CLT cannot load the Swift Testing macro plugin - see CLAUDE.md "Toolchain note").
if [[ -z "$DEVELOPER_DIR" && "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
