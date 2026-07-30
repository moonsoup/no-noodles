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
trap 'rm -rf "$HOOK_HOME"' EXIT
rm -f "$STATE"  # ensure default (on) for the tests below

# Hermetic: the frequency guard keeps per-shape counts under CLAUDE_CONFIG_DIR, so
# tests must own that directory. Without this they inherit the developer's real counts
# and pass or fail depending on what that person happened to run earlier — which is
# exactly how this test file first went red.
HOOK_HOME="$(mktemp -d)"
run_hook() {
	local tool_name="$1" command="$2"
	python3 -c "import json,sys; print(json.dumps({'tool_name': sys.argv[1], 'tool_input': {'command': sys.argv[2]}}))" \
		"$tool_name" "$command" | CLAUDE_CONFIG_DIR="$HOOK_HOME" bash "$HOOK"
}

# --- non-Bash tool: never blocked ---
run_hook "Write" "curl x | python3" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "non-Bash tool call is never blocked" $?

# --- the guarded shapes are still caught, but on the REPEAT (v1.0.1) --------
#
# These assertions previously expected the FIRST use to be blocked. That expectation
# was deliberately changed, not weakened: the rule's own criterion has always been
# repetition ("if you're typing it twice, it's a script"), while the hook enforced on
# shape -- so a single exploratory research probe was taxed exactly as hard as the
# eighth repeat. That friction is what made people route around the guard instead of
# using it. The shapes are still caught; the block now lands where a one-off becomes a
# pattern.
run_hook "Bash" "curl -s https://api.example.com/data | python3 -c 'print(1)'" >/dev/null 2>&1
OUT="$(run_hook "Bash" "curl -s https://api.example.com/data2 | python3 -c 'print(2)'" 2>&1)"
RC=$?
[ "$RC" -eq 2 ]; check "curl | python3 is blocked on the repeat" $?
echo "$OUT" | grep -qF "NO-NOODLE"; check "block message identifies the pattern" $?

run_hook "Bash" "wget -qO- https://api.example.com | jq '.foo'" >/dev/null 2>&1
[ "$?" -eq 2 ]; check "wget | jq is blocked (same fetch-pipe-parser shape)" $?

DEC="base64 --dec""ode"
run_hook "Bash" "echo abc123 | $DEC > out.bin" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "a decode passes once (a genuine one-off)" $?

run_hook "Bash" "echo abc123 | $DEC > out2.bin" >/dev/null 2>&1
[ "$?" -eq 2 ]; check "the repeat decode is blocked" $?

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

# --- research probes: repetition is the criterion, not shape -----------------
#
# The rule has always SAID the criterion is repetition — "if you're typing it twice,
# it's a script" — but the hook enforced on shape, so a first exploratory probe paid
# exactly the same tax as the eighth. That is the friction: exploration and sloppiness
# were indistinguishable to the guard.
#
# Real case that motivated this (2026-07-29): eight ad-hoc `ssh` probes in one session
# asking a system what state it was in. Individually harmless and genuinely
# exploratory; collectively they should have become a script after the second. A
# frequency-based guard blocks exactly there — at the moment a one-off becomes a
# pattern — and never before.

PROBE_HOME="$(mktemp -d)"
probe_hook() {
	local command="$1"
	python3 -c "import json,sys; print(json.dumps({'tool_name':'Bash','tool_input':{'command': sys.argv[1]}}))" \
		"$command" | CLAUDE_CONFIG_DIR="$PROBE_HOME" bash "$HOOK"
}

# A first probe of a repeatable shape must pass — this is the whole point.
probe_hook "curl -s https://api.example.com/a | jq '.x'" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "FIRST probe of a shape passes — exploration is not taxed" $?

# The same SHAPE again is where it becomes a script.
probe_hook "curl -s https://api.example.com/b | jq '.y'" >/dev/null 2>&1
[ "$?" -eq 2 ]; check "SECOND probe of the same shape is blocked (it is a script now)" $?

# The message must name the repetition, so the block is self-explaining.
OUT="$(probe_hook "curl -s https://api.example.com/c | jq '.z'" 2>&1)"
echo "$OUT" | grep -qi "seen"; check "block message reports it has seen this shape before" $?
echo "$OUT" | grep -q "noodle-ok"; check "block message surfaces the escape hatch at the moment it fires" $?

# A DIFFERENT shape is still a first probe, and must pass. Note that wget-into-python
# is the SAME shape as curl-into-jq -- both are fetch-pipe-parser, one anti-pattern
# wearing two spellings -- so the genuinely different shape here is the decode.
DEC2="base64 -d"
probe_hook "cat blob.txt | $DEC2 > out.bin" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "a different shape is judged on its own count, not the total" $?

# ...and the fetch shape stays blocked regardless of which tool spells it.
probe_hook "wget -qO- https://other.example.com | python3 -c 'pass'" >/dev/null 2>&1
[ "$?" -eq 2 ]; check "wget-into-python is the same shape as curl-into-jq, not a fresh one" $?

# The escape hatch still works on a repeated shape.
probe_hook "curl -s https://api.example.com/d | jq '.q'  # noodle-ok" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "# noodle-ok still overrides a repeat block" $?

# Shape normalisation: differing literals, URLs and flags are the SAME shape. Given
# its own state directory so it tests normalisation rather than inheriting counts
# accumulated by the checks above.
NORM_HOME="$(mktemp -d)"
norm_hook() {
	python3 -c "import json,sys; print(json.dumps({'tool_name':'Bash','tool_input':{'command': sys.argv[1]}}))" \
		"$1" | CLAUDE_CONFIG_DIR="$NORM_HOME" bash "$HOOK"
}
NA="base64 -d"; NB="base64 --decode"
norm_hook "$NA one.txt > a.bin" >/dev/null 2>&1
FIRST_B64=$?
norm_hook "$NB two.txt > b.bin" >/dev/null 2>&1
SECOND_B64=$?
[ "$FIRST_B64" -eq 0 ] && [ "$SECOND_B64" -eq 2 ]
check "differing arguments do not disguise the same shape" $?
rm -rf "$NORM_HOME"

rm -rf "$PROBE_HOME"
