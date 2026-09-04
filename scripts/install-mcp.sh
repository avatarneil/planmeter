#!/usr/bin/env bash
# Registers the bundled planmeter-mcp server with supported local agents that
# are installed: Claude Code (work and personal homes), Codex, and OpenCode.
set -euo pipefail

APP="${APP:-/Applications/PlanMeter.app}"
MCP="$APP/Contents/MacOS/planmeter-mcp"
NAME="planmeter"

if [ ! -x "$MCP" ]; then
  echo "planmeter-mcp not found at $MCP; run 'make install' first." >&2
  exit 1
fi

echo "MCP binary: $MCP"

# --- Claude Code -----------------------------------------------------------
register_claude() {
  local label="$1"
  shift
  if ! command -v claude >/dev/null 2>&1; then
    echo "claude CLI not found; skipping $label" >&2
    return
  fi
  "$@" claude mcp remove -s user "$NAME" >/dev/null 2>&1 || true
  "$@" claude mcp add -s user "$NAME" -- "$MCP" >/dev/null
  echo "Claude Code ($label): registered (user scope)"
}
register_claude "work" env
if [ -d "$HOME/.claude_personal_home" ]; then
  register_claude "personal" env CLAUDE_CONFIG_DIR="$HOME/.claude_personal_home"
fi

# --- Codex ------------------------------------------------------------------
if command -v codex >/dev/null 2>&1; then
  codex mcp remove "$NAME" >/dev/null 2>&1 || true
  codex mcp add "$NAME" -- "$MCP" >/dev/null
  echo "Codex: registered in ~/.codex/config.toml (shared by every Codex home that links config.toml)"
else
  echo "codex CLI not found; skipping" >&2
fi

# --- OpenCode ---------------------------------------------------------------
OPENCODE_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json"
if [ -f "$OPENCODE_CONFIG" ] || command -v opencode >/dev/null 2>&1; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found; skipping OpenCode registration" >&2
  else
    python3 - "$OPENCODE_CONFIG" "$MCP" "$NAME" <<'EOF'
import json, os, sys
path, mcp, name = sys.argv[1:4]
config = {}
if os.path.exists(path):
    with open(path) as f:
        config = json.load(f)
config.setdefault("mcp", {})[name] = {"type": "local", "command": [mcp], "enabled": True}
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
print(f"OpenCode: registered in {path}")
EOF
  fi
else
  echo "OpenCode config not found; skipping" >&2
fi
