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
HOOK_RISK_GATE="$CLAUDE_DIR/hooks/risk_gate.sh"
HOOK_LIB_RISK="$CLAUDE_DIR/hooks/lib_risk.sh"
HOOK_LIB_OBSERVE="$CLAUDE_DIR/hooks/lib_observe.sh"
HOOK_RISK_SCORE_PY="$CLAUDE_DIR/hooks/risk_score.py"
HOOK_RISK_RULES="$CLAUDE_DIR/hooks/risk-rules.json"
HOOK_RISK_SUMMARY_PY="$CLAUDE_DIR/hooks/risk_summary.py"
HOOK_GRANT_TRUST="$CLAUDE_DIR/hooks/grant_session_trust.sh"
SKILL_FILE="$CLAUDE_DIR/skills/no-noodle.md"
SKILL_OPTIONS_FILE="$CLAUDE_DIR/skills/noodle-options.md"

uninstall() {
  echo "no-noodles: removing installed files..."
  rm -f "$HOOK_NO_NOODLE" "$HOOK_CHECK_BUILD" "$HOOK_LIB_CONFIG" "$SKILL_FILE" "$SKILL_OPTIONS_FILE"
  rm -f "$HOOK_RISK_GATE" "$HOOK_LIB_RISK" "$HOOK_LIB_OBSERVE" "$HOOK_RISK_SCORE_PY" "$HOOK_RISK_RULES" "$HOOK_RISK_SUMMARY_PY" "$HOOK_GRANT_TRUST"
  # Deliberately NOT removing $CLAUDE_DIR/no-noodles/ (observations.jsonl,
  # risk-profile.json, session-trust) -- that's accumulated training data +
  # audit trail (per the plan), not disposable state like the .state toggles
  # below. Uninstalling the hooks shouldn't silently destroy it.
  rm -f "$CLAUDE_DIR/no-noodle.state" "$CLAUDE_DIR/check-before-build.state" "$CLAUDE_DIR/no-noodles.json" "$CLAUDE_DIR/risk-gate.state"
  if [ -f "$SETTINGS" ] && command -v python3 >/dev/null 2>&1; then
    python3 - "$SETTINGS" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
for entry in data.get("hooks", {}).get("PreToolUse", []):
    entry["hooks"] = [h for h in entry.get("hooks", [])
                       if "no_noodle.sh" not in h.get("command", "")
                       and "check_before_build.sh" not in h.get("command", "")
                       and "risk_gate.sh" not in h.get("command", "")]
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
cp "$PKG_DIR/hooks/risk_gate.sh" "$HOOK_RISK_GATE"
cp "$PKG_DIR/hooks/lib_risk.sh" "$HOOK_LIB_RISK"
cp "$PKG_DIR/hooks/lib_observe.sh" "$HOOK_LIB_OBSERVE"
cp "$PKG_DIR/hooks/risk_score.py" "$HOOK_RISK_SCORE_PY"
cp "$PKG_DIR/hooks/risk-rules.json" "$HOOK_RISK_RULES"
cp "$PKG_DIR/hooks/risk_summary.py" "$HOOK_RISK_SUMMARY_PY"
cp "$PKG_DIR/hooks/grant_session_trust.sh" "$HOOK_GRANT_TRUST"
cp "$PKG_DIR/skills/no-noodle.md" "$SKILL_FILE"
cp "$PKG_DIR/skills/noodle-options.md" "$SKILL_OPTIONS_FILE"
chmod +x "$HOOK_NO_NOODLE" "$HOOK_CHECK_BUILD" "$HOOK_LIB_CONFIG" "$HOOK_RISK_GATE" "$HOOK_LIB_RISK" "$HOOK_LIB_OBSERVE" "$HOOK_GRANT_TRUST"
echo "no-noodles: copied hooks + skills into $CLAUDE_DIR"

if [ ! -f "$SETTINGS" ]; then
  echo '{"hooks":{"PreToolUse":[{"hooks":[]}]}}' > "$SETTINGS"
fi

python3 - "$SETTINGS" "$CLAUDE_DIR" <<'PYEOF'
import json, sys
path = sys.argv[1]
claude_dir = sys.argv[2]
with open(path) as f:
    data = json.load(f)

data.setdefault("hooks", {}).setdefault("PreToolUse", [])
if not data["hooks"]["PreToolUse"]:
    data["hooks"]["PreToolUse"].append({"hooks": []})

group = data["hooks"]["PreToolUse"][0]
group.setdefault("hooks", [])
existing_cmds = {h.get("command", "") for h in group["hooks"]}

# Real incident (2026-07-16): these MUST use the resolved claude_dir
# (absolute path), not a literal "~/.claude" -- `~` expands to $HOME at
# hook-EXECUTION time, not to CLAUDE_CONFIG_DIR, so a hardcoded string here
# silently breaks every install whose CLAUDE_CONFIG_DIR differs from the
# default (e.g. CLAUDE_CONFIG_DIR=~/.claude-ies), even though the hook files
# themselves were correctly copied to the right place above.
to_add = [
    {"type": "command", "command": f"bash {claude_dir}/hooks/no_noodle.sh", "statusMessage": "No-noodle check..."},
    {"type": "command", "command": f"bash {claude_dir}/hooks/check_before_build.sh", "statusMessage": "Check-before-build check..."},
    {"type": "command", "command": f"bash {claude_dir}/hooks/risk_gate.sh", "statusMessage": "Risk gate check..."},
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
echo "no-noodles: installed. no_noodle.sh and check_before_build.sh are ON by default."
echo "  risk_gate.sh (weighted risk scoring, docs/RISK_MODEL_PLAN.md) is OFF by default --"
echo "  it scores every Bash command, a much broader surface than the other two rules."
echo "  Turn it on: echo '{\"risk_scoring\": \"on\"}' > $CLAUDE_DIR/no-noodles.json (or via /noodle-options)."
echo "  Configure per-project or per-preference: run the /noodle-options skill in Claude Code."
echo "  Blunt global toggle (unchanged):"
echo "    off:  echo off > $CLAUDE_DIR/no-noodle.state"
echo "          echo off > $CLAUDE_DIR/check-before-build.state"
echo "    on :  rm those files, or echo on > <file>"
echo "  Uninstall:   $0 --uninstall"
