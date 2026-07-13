#!/usr/bin/env bash
# Shared config resolution for no-noodles hooks. Lets enforcement be configured
# per-project (case by case) or by individual preference, not just one global
# on/off switch -- set via the `/noodle-options` skill or by hand.
#
# Resolution order for a given rule key (first match wins):
#   1. project-local ./.no-noodles.json   { "<rule>": "on"|"off" }   (cwd of the hook)
#   2. global $CLAUDE_DIR/no-noodles.json { "<rule>": "on"|"off" }
#   3. legacy per-rule state file (unchanged, never removed -- see no_noodle.sh /
#      check_before_build.sh's original ADJUSTABLE comment)
#   4. default: on
#
# Usage: resolve_state <rule_key> <legacy_state_file>   # prints "on" or "off"

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

_json_get() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  python3 -c "
import json, sys
try:
    with open('$file') as f:
        data = json.load(f)
    v = data.get('$key', '')
    print(v if v in ('on', 'off') else '')
except Exception:
    print('')
" 2>/dev/null
}

resolve_state() {
  local rule_key="$1" legacy_state_file="$2"
  local v

  v=$(_json_get "./.no-noodles.json" "$rule_key")
  [ -n "$v" ] && { echo "$v"; return; }

  v=$(_json_get "$CLAUDE_DIR/no-noodles.json" "$rule_key")
  [ -n "$v" ] && { echo "$v"; return; }

  if [ -f "$legacy_state_file" ] && [ "$(tr -d '[:space:]' < "$legacy_state_file" 2>/dev/null)" = "off" ]; then
    echo "off"; return
  fi

  echo "on"
}
