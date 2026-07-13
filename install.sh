#!/usr/bin/env bash
# Installs no-noodles into ~/.claude: copies the two hooks and the skill doc,
# then registers both hooks under settings.json's PreToolUse list (idempotent
# — running this twice does not duplicate the entries).
#
# Usage:
#   ./install.sh            # install
#   ./install.sh --uninstall  # remove the copied files and hook registrations
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$CLAUDE_DIR/settings.json"

HOOK_NO_NOODLE="$CLAUDE_DIR/hooks/no_noodle.sh"
HOOK_CHECK_BUILD="$CLAUDE_DIR/hooks/check_before_build.sh"
HOOK_LIB_CONFIG="$CLAUDE_DIR/hooks/lib_config.sh"
SKILL_FILE="$CLAUDE_DIR/skills/no-noodle.md"
SKILL_OPTIONS_FILE="$CLAUDE_DIR/skills/noodle-options.md"

uninstall() {
  echo "no-noodles: removing installed files..."
  rm -f "$HOOK_NO_NOODLE" "$HOOK_CHECK_BUILD" "$HOOK_LIB_CONFIG" "$SKILL_FILE" "$SKILL_OPTIONS_FILE"
  rm -f "$CLAUDE_DIR/no-noodle.state" "$CLAUDE_DIR/check-before-build.state" "$CLAUDE_DIR/no-noodles.json"
  if [ -f "$SETTINGS" ] && command -v python3 >/dev/null 2>&1; then
    python3 - "$SETTINGS" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
for entry in data.get("hooks", {}).get("PreToolUse", []):
    entry["hooks"] = [h for h in entry.get("hooks", [])
                       if "no_noodle.sh" not in h.get("command", "")
                       and "check_before_build.sh" not in h.get("command", "")]
with open(path, "w") as f:
    json.dump(data, f, indent=1)
    f.write("\n")
PYEOF
    echo "no-noodles: removed hook registrations from $SETTINGS"
  fi
  echo "no-noodles: uninstalled."
  exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall

mkdir -p "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/skills"

cp "$PKG_DIR/hooks/no_noodle.sh" "$HOOK_NO_NOODLE"
cp "$PKG_DIR/hooks/check_before_build.sh" "$HOOK_CHECK_BUILD"
cp "$PKG_DIR/hooks/lib_config.sh" "$HOOK_LIB_CONFIG"
cp "$PKG_DIR/skills/no-noodle.md" "$SKILL_FILE"
cp "$PKG_DIR/skills/noodle-options.md" "$SKILL_OPTIONS_FILE"
chmod +x "$HOOK_NO_NOODLE" "$HOOK_CHECK_BUILD" "$HOOK_LIB_CONFIG"
echo "no-noodles: copied hooks + skills into $CLAUDE_DIR"

if [ ! -f "$SETTINGS" ]; then
  echo '{"hooks":{"PreToolUse":[{"hooks":[]}]}}' > "$SETTINGS"
fi

python3 - "$SETTINGS" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

data.setdefault("hooks", {}).setdefault("PreToolUse", [])
if not data["hooks"]["PreToolUse"]:
    data["hooks"]["PreToolUse"].append({"hooks": []})

group = data["hooks"]["PreToolUse"][0]
group.setdefault("hooks", [])
existing_cmds = {h.get("command", "") for h in group["hooks"]}

to_add = [
    {"type": "command", "command": "bash ~/.claude/hooks/no_noodle.sh", "statusMessage": "No-noodle check..."},
    {"type": "command", "command": "bash ~/.claude/hooks/check_before_build.sh", "statusMessage": "Check-before-build check..."},
]
added = 0
for h in to_add:
    if h["command"] not in existing_cmds:
        group["hooks"].append(h)
        added += 1

with open(path, "w") as f:
    json.dump(data, f, indent=1)
    f.write("\n")

print(f"no-noodles: registered {added} new hook(s) in {path} (already present: {len(to_add) - added})")
PYEOF

echo ""
echo "no-noodles: installed. Both hooks are ON by default."
echo "  Configure per-project or per-preference: run the /noodle-options skill in Claude Code."
echo "  Blunt global toggle (unchanged):"
echo "    off:  echo off > $CLAUDE_DIR/no-noodle.state"
echo "          echo off > $CLAUDE_DIR/check-before-build.state"
echo "    on :  rm those files, or echo on > <file>"
echo "  Uninstall:   $0 --uninstall"
