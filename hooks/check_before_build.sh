#!/usr/bin/env bash
# PreToolUse hook — mechanical enforcement of "check before building" (no-noodle
# rule #4): a NEW script file dropped into a scripts/ dir is presumed to belong
# inside an existing pipeline script as a flag/option, not as a parallel one-off.
# Blocks Write calls that CREATE (not edit) a script-like file under a scripts/
# directory, unless the content carries an explicit justification marker.
# Input: JSON on stdin (tool_name, tool_input.file_path, tool_input.content).
# Exit 2 = block + surface message. Escape hatch: `# build-ok: <reason>` (or
# `// build-ok: <reason>`) anywhere in the new file's content.
# Discipline it enforces: ~/.claude/skills/no-noodle.md, rule 4.
# Real incident this responds to: reaching for scripts/resync_mismatches.py
# when verify_migration.py already had the diff logic that capability needed.

INPUT=$(cat)
TOOL=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null)
# Write = creating a file. Bash is checked only for mv/cp/install/ln INTO a scripts/
# dir (v1.2.0): moving a script in is the same as creating it there, and used to
# bypass this rule entirely.
case "$TOOL" in Write|Bash) ;; *) exit 0 ;; esac

# ADJUSTABLE / SWITCHABLE, same convention as no_noodle.sh:
#   off:  echo off > ~/.claude/check-before-build.state
#   on :  echo on  > ~/.claude/check-before-build.state   (or delete the file — default)
# Finer-grained, per-project or per-preference config (JSON, checked first) is
# available via the `/noodle-options` skill — see hooks/lib_config.sh.
STATE="$HOME/.claude/check-before-build.state"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_config.sh
source "$HOOK_DIR/lib_config.sh"
[ "$(resolve_state check_before_build "$STATE")" = "off" ] && exit 0

# Placement (v1.2.0, hooks/tool_home.py): rule #4 also asks WHERE a new tool belongs.
# With `tool_homes` configured, a script must say home=<scope> (and live in that home)
# or home=project consumer=<what uses it>. Without it, behaviour is unchanged.
TOOL_HOME="$HOOK_DIR/tool_home.py"
if [ "$TOOL" = "Bash" ]; then
  [ -f "$TOOL_HOME" ] || exit 0
  # cheap pre-filter: only a mover verb AND a scripts/ path is worth starting python for
  echo "$INPUT" | grep -qE '(^|[^a-z_])(mv|cp|install|ln)[[:space:]]' || exit 0
  echo "$INPUT" | grep -q 'scripts' || exit 0
  echo "$INPUT" | python3 "$TOOL_HOME" bash
  exit $?
fi

FILE_PATH=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null)
CONTENT=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('content',''))" 2>/dev/null)

# Phase 3 observation log (docs/RISK_MODEL_PLAN.md) -- same additive,
# never-blocking wiring as no_noodle.sh. This rule guards Write calls, not
# Bash commands, so the "command" logged is a synthesized `write <path>`
# signal rather than a literal shell command.
( source "$HOOK_DIR/lib_observe.sh" && risk_observe "write $FILE_PATH" "$FILE_PATH" ) >/dev/null 2>&1

[ -z "$FILE_PATH" ] && exit 0

# Only new files (Write on an existing path is an intentional overwrite/edit,
# already covered by "prefer Edit" norms elsewhere — not this hook's job).
[ -f "$FILE_PATH" ] && exit 0

# Only script-like files, and only inside a scripts/ directory -- the exact
# shape of the real incident. Narrower net on purpose: broaden later from
# evidence, same way no_noodle.sh's patterns grew one real case at a time.
case "$FILE_PATH" in
  */scripts/*.py|*/scripts/*.sh|*/scripts/*.js|*/scripts/*.ts|*/scripts/*.rb) ;;
  *) exit 0 ;;
esac

BASENAME=$(basename "$FILE_PATH")
# Test files are exempt: they're the natural, expected pairing with a script
# that already justified itself (or an existing script being extended).
case "$BASENAME" in
  test_*|*_test.py|*.test.js|*.test.ts) exit 0 ;;
esac

if [ -f "$TOOL_HOME" ]; then
  echo "$INPUT" | python3 "$TOOL_HOME" write
  exit $?
fi

echo "$CONTENT" | grep -qE '(#|//) *build-ok:' && exit 0

echo "CHECK-BEFORE-BUILD: new script $FILE_PATH — before creating it, confirm no existing script in this scripts/ dir already covers this (or could grow a flag/option to cover it). If this is genuinely a new, unrelated capability, add a first-line comment '# build-ok: <why this isn't an extension of an existing script>' and retry. See ~/.claude/skills/no-noodle.md rule 4." >&2
exit 2
