#!/usr/bin/env bash
# Tests for hooks/ask_gate.sh (rule #2, v1.3.0): the first AskUserQuestion in a session is
# blocked until independent work is started in the background; a repeat within the window
# passes; an `ask-ok:` reason passes at once; the ask_gate key (and legacy state) turns it off.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/ask_gate.sh"
FAILS=0
check() {
	if [ "$2" -eq 0 ]; then echo "    OK: $1"; else echo "    FAIL: $1" >&2; FAILS=$((FAILS + 1)); fi
}

[ -f "$HOOK" ]; check "ask_gate.sh exists" $?
[ -x "$HOOK" ]; check "ask_gate.sh is executable" $?
bash -n "$HOOK"; check "ask_gate.sh has valid bash syntax" $?

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP/claude"
mkdir -p "$CLAUDE_CONFIG_DIR"
cd "$TMP"

ask() { # session question [extra-json-field] -> exit code; stderr into $ERR
	ERR="$(python3 -c "
import json, sys
ti = {'questions': [{'question': sys.argv[2], 'header': 'h', 'multiSelect': False,
                     'options': [{'label': 'a', 'description': 'a'}, {'label': 'b', 'description': 'b'}]}]}
if len(sys.argv) > 3 and sys.argv[3]:
    ti['metadata'] = {'source': sys.argv[3]}
print(json.dumps({'tool_name': 'AskUserQuestion', 'session_id': sys.argv[1], 'tool_input': ti}))
" "$1" "$2" "${3:-}" | bash "$HOOK" 2>&1 >/dev/null)"
}

ask s1 "Which plan?"; [ $? -eq 2 ]; check "first ask in a session is blocked" $?
echo "$ERR" | grep -q "start every task that does not depend on this answer in the background"; check "block message says what to do" $?
ask s1 "Which plan?"; check "repeat within the window passes" $?
ask s1 "Another question?"; [ $? -eq 2 ]; check "after a pass, the next ask is gated again" $?

ask s2 "Buy the VPS? ask-ok: purchase needs the owner"; check "ask-ok: in the question passes at once" $?
ask s3 "Which card?" "ask-ok: credentials are the owner's"; check "ask-ok: in metadata passes at once" $?

ask s4 "Which?"; [ $? -eq 2 ]; check "sessions are independent (s4 blocked)" $?
python3 - "$CLAUDE_CONFIG_DIR/no-noodles/ask-gate/s4" <<'EOF'
import sys, time
open(sys.argv[1], "w").write(str(int(time.time()) - 600))
EOF
ask s4 "Which?"; [ $? -eq 2 ]; check "a block older than the window does not count (blocked again)" $?

ask "../../etc/x" "Which?"; [ $? -eq 2 ]; check "hostile session id still gated" $?
[ ! -e "$TMP/etc/x" ]; check "session id cannot escape the state dir" $?

echo '{"tool_name":"Bash","session_id":"s5","tool_input":{"command":"ls"}}' | bash "$HOOK" >/dev/null 2>&1
check "non-AskUserQuestion tools are ignored" $?

echo '{"ask_gate": "off"}' > "$CLAUDE_CONFIG_DIR/no-noodles.json"
ask s6 "Which?"; check "ask_gate off in config -> passes" $?
rm -f "$CLAUDE_CONFIG_DIR/no-noodles.json"
echo off > "$CLAUDE_CONFIG_DIR/ask-gate.state"
ask s7 "Which?"; check "legacy ask-gate.state off -> passes" $?
rm -f "$CLAUDE_CONFIG_DIR/ask-gate.state"

echo ""
if [ "$FAILS" -eq 0 ]; then
	echo "ASK_GATE TEST: ALL CHECKS PASSED."
else
	echo "ASK_GATE TEST: $FAILS CHECK(S) FAILED." >&2
	exit 1
fi
