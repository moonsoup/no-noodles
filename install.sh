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

# Single source of truth for the version, stamped into each config dir on install
# so "which no-noodles is in there?" is answerable mechanically.
#
# Not cosmetic: before 1.0.0 there was no version marker at all, and this machine
# was found running DIFFERENT builds of no-noodle.md in ~/.claude vs ~/.claude-ies
# (3379 vs 4383 bytes) — noticed only because someone read an `ls -la` byte count
# by eye. The package now also installs into Docker containers, local and remote,
# so drift between installs is the normal case to detect, not an edge case.
VERSION="$(cat "$PKG_DIR/VERSION" 2>/dev/null || echo "0.0.0-unknown")"
VERSION_STAMP="$CLAUDE_DIR/no-noodles/VERSION"

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
# ALSO install as commands, because a flat `.md` under skills/ is NOT loaded.
#
# Found empirically 2026-07-29, after weeks of the discipline being unopenable:
# `/no-noodle` returned "Unknown skill" and neither doc appeared in the session's
# skill list, in EITHER config dir. What registers at user level is
# `$CLAUDE_DIR/commands/<name>.md` (proven against `commands/drive-status.md`,
# which is invocable). The skill text has always said "run /noodle-options" — a
# command was the intent from the start; the installer simply wrote to an inert
# path.
#
# Why this mattered so much: the two PreToolUse hooks worked perfectly the whole
# time, so noodling got BLOCKED without the agent being able to read the document
# that explains what to do instead. Enforcement without the explanation is how
# the discipline turned into decoration.
#
# The skills/ copies are kept as-is (never remove an install path something else
# may rely on); these are additional.
COMMAND_FILE="$CLAUDE_DIR/commands/no-noodle.md"
COMMAND_OPTIONS_FILE="$CLAUDE_DIR/commands/noodle-options.md"

uninstall() {
  echo "no-noodles: removing installed files..."
  rm -f "$HOOK_NO_NOODLE" "$HOOK_CHECK_BUILD" "$HOOK_LIB_CONFIG" "$SKILL_FILE" "$SKILL_OPTIONS_FILE"
  rm -f "$COMMAND_FILE" "$COMMAND_OPTIONS_FILE"
  # The stamp describes what IS installed; leaving it would claim a package that
  # is gone — the same false-presence trap that hid the unloadable skill.
  rm -f "$VERSION_STAMP"
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

mkdir -p "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/skills" "$CLAUDE_DIR/commands" "$CLAUDE_DIR/no-noodles"
printf '%s\n' "$VERSION" > "$VERSION_STAMP"

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
# Same bytes, invocable location — one source of truth, two install paths.
cp "$PKG_DIR/skills/no-noodle.md" "$COMMAND_FILE"
cp "$PKG_DIR/skills/noodle-options.md" "$COMMAND_OPTIONS_FILE"
chmod +x "$HOOK_NO_NOODLE" "$HOOK_CHECK_BUILD" "$HOOK_LIB_CONFIG" "$HOOK_RISK_GATE" "$HOOK_LIB_RISK" "$HOOK_LIB_OBSERVE" "$HOOK_GRANT_TRUST"
echo "no-noodles $VERSION: copied hooks + skills + commands into $CLAUDE_DIR"

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
