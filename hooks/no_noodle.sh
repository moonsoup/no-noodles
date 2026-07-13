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

# Explicit override for the rare justified one-off.
echo "$CMD" | grep -qE '# *noodle-ok' && exit 0

REASON=""
# curl/wget piped into a parser = ad-hoc API/data probe.
if echo "$CMD" | grep -qE '(curl|wget)[^|]*\|[[:space:]]*(python3?|jq|node|perl|ruby)\b'; then
  REASON="a curl/wget piped into a parser is an ad-hoc data probe"
fi
# base64 decode of a blob = ad-hoc data handling.
if echo "$CMD" | grep -qE '\bbase64[[:space:]]+(-d|--decode|-D)\b'; then
  REASON="base64 decode is ad-hoc data handling"
fi

if [ -n "$REASON" ]; then
  echo "NO-NOODLE: $REASON. Write a script (with a test) and run that, or use a skill's documented command. For a genuine one-off append '# noodle-ok'. See ~/.claude/skills/no-noodle.md."
  exit 2
fi
exit 0
