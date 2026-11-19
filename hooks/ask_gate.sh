#!/usr/bin/env bash
# PreToolUse hook — rule #2 "drive to done": a question never stops the work.
#
# AskUserQuestion blocks the WHOLE session until the owner answers. Real incident
# (2026-11-19): questions were asked with nothing running in the background, so every
# task that did not depend on the answer sat idle while the owner was away. The rule
# existed in prose; this makes it mechanical.
#
# The first AskUserQuestion in a session is blocked (exit 2) with instructions to start
# all independent work in the background first. Asking again within ASK_GATE_WINDOW
# seconds (default 120) passes — that second ask is the deliberate one.
# Escape: a genuinely blocking decision (credentials, a purchase) passes at once when the
# question or its metadata carries `ask-ok: <reason>`.
#
# Switch: config key `ask_gate` (default on) via /noodle-options, or the legacy
#   echo off > $CLAUDE_CONFIG_DIR/ask-gate.state
INPUT=$(cat)
TOOL=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null)
[ "$TOOL" = "AskUserQuestion" ] || exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_config.sh
source "$HOOK_DIR/lib_config.sh"
[ "$(resolve_state ask_gate "$CLAUDE_DIR/ask-gate.state")" = "off" ] && exit 0

echo "$INPUT" | python3 -c "
import json, sys
ti = json.load(sys.stdin).get('tool_input') or {}
sys.exit(0 if 'ask-ok:' in json.dumps(ti) else 1)" && exit 0

WINDOW="${ASK_GATE_WINDOW:-120}"
SESSION=$(echo "$INPUT" | python3 -c "
import json, re, sys
sid = str(json.load(sys.stdin).get('session_id') or 'no-session')
print(re.sub(r'[^A-Za-z0-9_-]', '_', sid)[:80])" 2>/dev/null)
STATE_DIR="$CLAUDE_DIR/no-noodles/ask-gate"
mkdir -p "$STATE_DIR"
STAMP="$STATE_DIR/${SESSION:-no-session}"
NOW=$(date +%s)

if [ -f "$STAMP" ]; then
  LAST=$(tr -dc '0-9' < "$STAMP")
  if [ -n "$LAST" ] && [ $((NOW - LAST)) -le "$WINDOW" ]; then
    rm -f "$STAMP"   # this is the deliberate second ask; the next one is gated again
    exit 0
  fi
fi

echo "$NOW" > "$STAMP"
echo "ASK-GATE (no-noodle rule #2): Before asking: start every task that does not depend on this answer in the background (Agent with run_in_background, Bash run_in_background, or a fork), then ask again. A question blocks only the step that needs it. (Ask again within ${WINDOW}s to proceed; for a genuinely blocking decision such as credentials or a purchase, include 'ask-ok: <reason>' in the question.)" >&2
exit 2
