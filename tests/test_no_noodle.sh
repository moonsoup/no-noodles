#!/usr/bin/env bash
# Tests for hooks/no_noodle.sh. Runs the real hook script against synthetic
# JSON on stdin (the same shape Claude Code's PreToolUse hook invocation
# sends) -- no real Bash command is ever executed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/no_noodle.sh"
FAILS=0

check() {
	if [ "$2" -eq 0 ]; then
		echo "    OK: $1"
	else
		echo "    FAIL: $1" >&2
		FAILS=$((FAILS + 1))
	fi
}

[ -f "$HOOK" ]; check "no_noodle.sh exists" $?
[ -x "$HOOK" ]; check "no_noodle.sh is executable" $?
bash -n "$HOOK"; check "no_noodle.sh has valid bash syntax" $?

STATE="$HOME/.claude/no-noodle.state"
STATE_BACKUP=""
[ -f "$STATE" ] && STATE_BACKUP="$(cat "$STATE")"
cleanup() {
	if [ -n "$STATE_BACKUP" ]; then
		echo "$STATE_BACKUP" > "$STATE"
	else
		rm -f "$STATE"
	fi
}
trap cleanup EXIT
rm -f "$STATE"  # ensure default (on) for the tests below

run_hook() {
	local tool_name="$1" command="$2"
	python3 -c "import json,sys; print(json.dumps({'tool_name': sys.argv[1], 'tool_input': {'command': sys.argv[2]}}))" \
		"$tool_name" "$command" | bash "$HOOK"
}

# --- non-Bash tool: never blocked ---
run_hook "Write" "curl x | python3" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "non-Bash tool call is never blocked" $?

# --- curl piped into a parser: blocked ---
OUT="$(run_hook "Bash" "curl -s https://api.example.com/data | python3 -c 'import sys,json; print(json.load(sys.stdin))'" 2>&1)"
RC=$?
[ "$RC" -eq 2 ]; check "curl | python3 is blocked" $?
echo "$OUT" | grep -qF "NO-NOODLE"; check "block message identifies the pattern" $?

# --- wget piped into jq: blocked ---
run_hook "Bash" "wget -qO- https://api.example.com | jq '.foo'" >/dev/null 2>&1
[ "$?" -eq 2 ]; check "wget | jq is blocked" $?

# --- base64 -d: blocked ---
run_hook "Bash" "echo abc123 | base64 -d > out.bin" >/dev/null 2>&1
[ "$?" -eq 2 ]; check "base64 -d is blocked" $?

run_hook "Bash" "echo abc123 | base64 --decode > out.bin" >/dev/null 2>&1
[ "$?" -eq 2 ]; check "base64 --decode is blocked" $?

# --- ordinary commands: never blocked ---
run_hook "Bash" "ls -la" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "plain ls is not blocked" $?

run_hook "Bash" "curl -s https://api.example.com/data -o data.json" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "curl without a piped parser is not blocked" $?

run_hook "Bash" "cat file.b64 | base64 > encoded.txt" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "base64 encode (no -d) is not blocked" $?

# --- escape hatch: # noodle-ok ---
run_hook "Bash" "curl -s https://api.example.com | python3 -m json.tool  # noodle-ok" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "# noodle-ok escapes an otherwise-blocked command" $?

# --- toggle: off disables enforcement ---
echo off > "$STATE"
run_hook "Bash" "curl -s https://api.example.com | python3" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "toggled off: no longer blocks" $?
rm -f "$STATE"

echo ""
if [ "$FAILS" -eq 0 ]; then
	echo "NO_NOODLE TEST: ALL CHECKS PASSED."
else
	echo "NO_NOODLE TEST: $FAILS CHECK(S) FAILED." >&2
	exit 1
fi
