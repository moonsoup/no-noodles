#!/usr/bin/env bash
# Tests for hooks/check_before_build.sh. Runs the real hook against synthetic
# Write-tool JSON on stdin, targeting a scratch temp dir -- no real file in
# ~/.claude or any project is ever touched.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/check_before_build.sh"
FAILS=0

check() {
	if [ "$2" -eq 0 ]; then
		echo "    OK: $1"
	else
		echo "    FAIL: $1" >&2
		FAILS=$((FAILS + 1))
	fi
}

[ -f "$HOOK" ]; check "check_before_build.sh exists" $?
[ -x "$HOOK" ]; check "check_before_build.sh is executable" $?
bash -n "$HOOK"; check "check_before_build.sh has valid bash syntax" $?

STATE="$HOME/.claude/check-before-build.state"
STATE_BACKUP=""
[ -f "$STATE" ] && STATE_BACKUP="$(cat "$STATE")"
cleanup() {
	rm -rf "$TMP"
	if [ -n "$STATE_BACKUP" ]; then
		echo "$STATE_BACKUP" > "$STATE"
	else
		rm -f "$STATE"
	fi
}
TMP="$(mktemp -d)"
trap cleanup EXIT
rm -f "$STATE"  # ensure default (on) for the tests below

run_hook() {
	local file_path="$1" content="$2"
	python3 -c "import json,sys; print(json.dumps({'tool_name': 'Write', 'tool_input': {'file_path': sys.argv[1], 'content': sys.argv[2]}}))" \
		"$file_path" "$content" | bash "$HOOK"
}

# --- new script in a scripts/ dir, no marker: blocked ---
OUT="$(run_hook "$TMP/scripts/newthing.py" "print('hi')" 2>&1)"
RC=$?
[ "$RC" -eq 2 ]; check "new script in scripts/ with no marker is blocked" $?
echo "$OUT" | grep -qF "CHECK-BEFORE-BUILD"; check "block message identifies the pattern" $?

# --- new script with # build-ok marker: allowed ---
run_hook "$TMP/scripts/newthing2.py" "# build-ok: unrelated new capability
print(1)" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "# build-ok marker allows the new file" $?

# --- new script with // build-ok marker (JS/TS comment style): allowed ---
run_hook "$TMP/scripts/newthing.ts" "// build-ok: standalone tool
console.log(1)" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "// build-ok marker allows the new file" $?

# --- test_ files are exempt regardless of marker ---
run_hook "$TMP/scripts/test_newthing.py" "pass" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "test_*.py file is exempt" $?

run_hook "$TMP/scripts/foo.test.js" "test()" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "*.test.js file is exempt" $?

# --- non-scripts directory: never blocked ---
run_hook "$TMP/README.md" "# hi" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "file outside scripts/ is never blocked" $?

run_hook "$TMP/main.py" "print(1)" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "script-like file outside scripts/ is never blocked" $?

# --- existing file (overwrite via Write): never blocked ---
mkdir -p "$TMP/scripts"
echo "old" > "$TMP/scripts/existing.py"
run_hook "$TMP/scripts/existing.py" "new content" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "overwriting an existing file is not blocked" $?

# --- non-Write tool: never triggers this hook ---
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | bash "$HOOK" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "non-Write tool call never triggers this hook" $?

# --- non-script extension in scripts/ dir: not blocked ---
run_hook "$TMP/scripts/notes.md" "notes" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "non-script-extension file in scripts/ is not blocked" $?

# --- toggle: off disables enforcement ---
echo off > "$STATE"
run_hook "$TMP/scripts/newthing3.py" "print(1)" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "toggled off: no longer blocks" $?
rm -f "$STATE"

echo ""
if [ "$FAILS" -eq 0 ]; then
	echo "CHECK_BEFORE_BUILD TEST: ALL CHECKS PASSED."
else
	echo "CHECK_BEFORE_BUILD TEST: $FAILS CHECK(S) FAILED." >&2
	exit 1
fi
