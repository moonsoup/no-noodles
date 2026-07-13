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
[ "$TOOL" = "Write" ] || exit 0

# ADJUSTABLE / SWITCHABLE, same convention as no_noodle.sh:
#   off:  echo off > ~/.claude/check-before-build.state
#   on :  echo on  > ~/.claude/check-before-build.state   (or delete the file — default)
STATE="$HOME/.claude/check-before-build.state"
[ -f "$STATE" ] && [ "$(tr -d '[:space:]' < "$STATE" 2>/dev/null)" = "off" ] && exit 0

FILE_PATH=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null)
CONTENT=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('content',''))" 2>/dev/null)

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

echo "$CONTENT" | grep -qE '(#|//) *build-ok:' && exit 0

echo "CHECK-BEFORE-BUILD: new script $FILE_PATH — before creating it, confirm no existing script in this scripts/ dir already covers this (or could grow a flag/option to cover it). If this is genuinely a new, unrelated capability, add a first-line comment '# build-ok: <why this isn't an extension of an existing script>' and retry. See ~/.claude/skills/no-noodle.md rule 4."
exit 2
