#!/usr/bin/env bash
# PreToolUse hook — the "no-noodle" guard. Blocks the ad-hoc data-probe anti-patterns
# the global CLAUDE.md prohibits (curl/wget piped into a parser; base64 blob decodes),
# forcing a script-with-a-test or a skill's documented command instead of a one-off riff.
# Input: JSON on stdin (tool_name, tool_input.command). Exit 2 = block + surface message.
# Escape hatch: append `# noodle-ok` to a command for a genuinely justified one-off.
# Discipline it enforces a slice of: ~/.claude/skills/no-noodle.md

INPUT=$(cat)
TOOL=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null)
[ "$TOOL" = "Bash" ] || exit 0

# ADJUSTABLE / SWITCHABLE — the ">> no-noodles" toggle:
#   off:  echo off > ~/.claude/no-noodle.state   (disable enforcement, like a mode)
#   on :  echo on  > ~/.claude/no-noodle.state   (or delete the file — enforce; default)
# Finer-grained, per-project or per-preference config (JSON, checked first) is
# available via the `/noodle-options` skill — see hooks/lib_config.sh.
STATE="$HOME/.claude/no-noodle.state"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_config.sh
source "$HOOK_DIR/lib_config.sh"
[ "$(resolve_state no_ad_hoc_probes "$STATE")" = "off" ] && exit 0

CMD=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)

# Phase 3 observation log (docs/RISK_MODEL_PLAN.md) -- logs every Bash command
# this rule sees, for the learning loop's summary/promote tooling. Additive
# only: never affects this rule's own on/off decision below, never blocks.
( source "$HOOK_DIR/lib_observe.sh" && risk_observe "$CMD" ) >/dev/null 2>&1

# Explicit override for the rare justified one-off.
echo "$CMD" | grep -qE '# *noodle-ok' && exit 0

SHAPE=""
# curl/wget piped into a parser = ad-hoc API/data probe.
if echo "$CMD" | grep -qE '(curl|wget)[^|]*\|[[:space:]]*(python3?|jq|node|perl|ruby)\b'; then
  SHAPE="fetch-pipe-parser"
  REASON="a curl/wget piped into a parser is an ad-hoc data probe"
fi
# base64 decode of a blob = ad-hoc data handling.
if echo "$CMD" | grep -qE '\bbase64[[:space:]]+(-d|--decode|-D)\b'; then
  SHAPE="base64-decode"
  REASON="base64 decode is ad-hoc data handling"
fi

[ -n "$SHAPE" ] || exit 0

# FREQUENCY, not shape, is the criterion — and always was. The rule's own words:
# "if you're typing it twice, it's a script." Blocking the FIRST use taxed genuine
# exploration exactly as hard as sloppiness, which is the friction that made people
# route around the guard instead of using it. A one-off research probe now passes; the
# repeat is where it has become a script, and that is where the block lands.
#
# Counted per project (cwd) as well as per shape, so a probe used once in each of
# several repos is not punished for the total.
COUNT_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/no-noodles/shapes"
mkdir -p "$COUNT_DIR" 2>/dev/null
PROJECT_KEY=$(printf '%s' "${PWD:-unknown}" | tr -c 'a-zA-Z0-9' '_' | tail -c 60)
COUNT_FILE="$COUNT_DIR/${SHAPE}__${PROJECT_KEY}"
SEEN=0
[ -f "$COUNT_FILE" ] && SEEN=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
case "$SEEN" in ''|*[!0-9]*) SEEN=0 ;; esac

if [ "$SEEN" -ge 1 ]; then
  echo "NO-NOODLE: $REASON, and I have seen this shape ($SHAPE) $SEEN time(s) already in this project. One is exploration; twice is a script. Write the script (with a test) and run that, or use a skill's documented command. If this genuinely is a distinct one-off, append '# noodle-ok'. See the no-noodle skill."
  exit 2
fi

# First use in this project: allow, and remember it.
echo $((SEEN + 1)) > "$COUNT_FILE" 2>/dev/null
exit 0
