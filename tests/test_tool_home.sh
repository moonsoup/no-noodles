#!/usr/bin/env bash
# Tests for the placement half of rule #4 (hooks/tool_home.py via check_before_build.sh):
# `tool_homes` config, the home=<scope>|project marker grammar, and the mv/cp bypass.
# Runs the real hook with a scratch CLAUDE_CONFIG_DIR -- no real config or project touched.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/check_before_build.sh"
FAILS=0
check() {
	if [ "$2" -eq 0 ]; then echo "    OK: $1"; else echo "    FAIL: $1" >&2; FAILS=$((FAILS + 1)); fi
}

TMP="$(cd "$(mktemp -d)" && pwd -P)"
STATE="$HOME/.claude/check-before-build.state"
STATE_BACKUP=""
[ -f "$STATE" ] && STATE_BACKUP="$(cat "$STATE")"
cleanup() {
	rm -rf "$TMP"
	if [ -n "$STATE_BACKUP" ]; then echo "$STATE_BACKUP" > "$STATE"; else rm -f "$STATE"; fi
}
trap cleanup EXIT
rm -f "$STATE"

export CLAUDE_CONFIG_DIR="$TMP/claude"
mkdir -p "$CLAUDE_CONFIG_DIR" "$TMP/work/ops/scripts/approved" "$TMP/work/proj/scripts" "$TMP/elsewhere/scripts" "$TMP/src"
cat > "$CLAUDE_CONFIG_DIR/no-noodles.json" <<EOF
{"tool_homes": [{"applies_to": "$TMP/work", "path": "$TMP/work/ops/scripts/approved",
                 "scope": "ops", "registry": "$TMP/work/ops/script_registry/registry.yaml"}]}
EOF
cd "$TMP"

write() { # path content -> exit code; stderr into $ERR
	ERR="$(python3 -c "import json,sys; print(json.dumps({'tool_name':'Write','tool_input':{'file_path':sys.argv[1],'content':sys.argv[2]}}))" "$1" "$2" | bash "$HOOK" 2>&1 >/dev/null)"
}
bashcmd() { # command -> exit code; stderr into $ERR
	ERR="$(python3 -c "import json,sys; print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]}}))" "$1" | bash "$HOOK" 2>&1 >/dev/null)"
}

echo "  Write, no tool home applies (backward compatible)"
write "$TMP/elsewhere/scripts/a.py" "# build-ok: new unrelated capability"; check "bare marker outside any tool home -> allowed" $?
write "$TMP/elsewhere/scripts/b.py" "print(1)"; [ $? -eq 2 ]; check "no marker outside any tool home -> blocked (old rule)" $?
echo "$ERR" | grep -q "CHECK-BEFORE-BUILD: new script"; check "old message kept" $?

echo "  Write, tool home applies"
write "$TMP/work/proj/scripts/c.py" "print(1)"; [ $? -eq 2 ]; check "no marker -> blocked" $?
echo "$ERR" | grep -q "placement" && echo "$ERR" | grep -q "registry.yaml"; check "message explains placement + names the registry" $?
write "$TMP/work/proj/scripts/d.py" "# build-ok: nothing similar here"; [ $? -eq 2 ]; check "bare marker (no home=) -> blocked" $?
echo "$ERR" | grep -q "home=ops"; check "message says how to choose" $?
write "$TMP/work/proj/scripts/e.py" "# build-ok: home=ops zone mover"; [ $? -eq 2 ]; check "home=ops outside the ops home -> blocked" $?
echo "$ERR" | grep -q "$TMP/work/ops/scripts/approved"; check "message names the ops home path" $?
write "$TMP/work/ops/scripts/approved/f.py" "# build-ok: home=ops zone mover"; check "home=ops inside the ops home -> allowed" $?
write "$TMP/work/proj/scripts/g.py" "# build-ok: home=project only this site"; [ $? -eq 2 ]; check "home=project without consumer= -> blocked" $?
write "$TMP/work/proj/scripts/h.py" "# build-ok: home=project consumer=proj-deploy one-off migration"; check "home=project consumer=... -> allowed" $?
write "$TMP/work/proj/scripts/i.py" "# build-ok: home=global x"; [ $? -eq 2 ]; check "unknown home= -> blocked" $?
write "$TMP/work/proj/scripts/test_j.py" "pass"; check "test files stay exempt" $?
write "$TMP/work/proj/k.py" "print(1)"; check "outside a scripts/ dir -> not this rule" $?

echo "  Bash mv/cp/install/ln (the bypass)"
printf '# build-ok: home=ops tool\nprint(1)\n' > "$TMP/src/ops_tool.py"
printf '# build-ok: home=project consumer=proj only here\n' > "$TMP/src/proj_tool.py"
printf 'print(1)\n' > "$TMP/src/plain.py"
printf 'notes\n' > "$TMP/src/notes.md"
bashcmd "mv $TMP/src/ops_tool.py $TMP/work/proj/scripts/"; [ $? -eq 2 ]; check "mv ops tool into a project scripts/ -> blocked" $?
echo "$ERR" | grep -q "mv/cp into a scripts/ dir"; check "message explains mv counts as creating" $?
bashcmd "mv $TMP/src/ops_tool.py $TMP/work/ops/scripts/approved/"; check "mv ops tool into the ops home -> allowed" $?
bashcmd "cp $TMP/src/proj_tool.py $TMP/work/proj/scripts/proj_tool.py"; check "cp project tool with consumer -> allowed" $?
bashcmd "cd /tmp && cp $TMP/src/plain.py $TMP/work/proj/scripts/new.py"; [ $? -eq 2 ]; check "chained cp of unmarked script -> blocked" $?
bashcmd "git mv $TMP/src/plain.py $TMP/work/proj/scripts/moved.py"; [ $? -eq 2 ]; check "git mv is checked too" $?
bashcmd "mv $TMP/src/*.py $TMP/work/proj/scripts/"; check "glob move -> not blocked (unsure)" $?
echo "$ERR" | grep -q "could not parse"; check "glob move -> warns instead" $?
bashcmd "mv $TMP/src/notes.md $TMP/work/proj/scripts/"; check "non-script file -> allowed" $?
printf 'x\n' > "$TMP/work/proj/scripts/exists.py"
bashcmd "cp $TMP/src/plain.py $TMP/work/proj/scripts/exists.py"; check "overwriting an existing script -> not this rule" $?
bashcmd "ls $TMP/work/proj/scripts"; check "non-mover command -> allowed" $?
bashcmd "cp $TMP/src/plain.py $TMP/elsewhere/scripts/x.py"; [ $? -eq 2 ]; check "unmarked script moved outside tool homes -> old rule blocks" $?

echo ""
if [ "$FAILS" -eq 0 ]; then
	echo "TOOL_HOME TEST: ALL CHECKS PASSED."
else
	echo "TOOL_HOME TEST: $FAILS CHECK(S) FAILED." >&2
	exit 1
fi
