#!/usr/bin/env bash
# Tests for install.sh. Runs it against a scratch CLAUDE_CONFIG_DIR via the
# env var override -- never touches the real ~/.claude.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG_ROOT="$(cd "$HERE/.." && pwd)"
INSTALLER="$PKG_ROOT/install.sh"
FAILS=0

check() {
	if [ "$2" -eq 0 ]; then
		echo "    OK: $1"
	else
		echo "    FAIL: $1" >&2
		FAILS=$((FAILS + 1))
	fi
}

[ -f "$INSTALLER" ]; check "install.sh exists" $?
[ -x "$INSTALLER" ]; check "install.sh is executable" $?
bash -n "$INSTALLER"; check "install.sh has valid bash syntax" $?

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_CLAUDE="$TMP/.claude"

# --- fresh install into an empty scratch dir ---
CLAUDE_CONFIG_DIR="$FAKE_CLAUDE" "$INSTALLER" >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ]; check "install exits 0 on a fresh scratch dir" $?
[ -x "$FAKE_CLAUDE/hooks/no_noodle.sh" ]; check "no_noodle.sh installed and executable" $?
[ -x "$FAKE_CLAUDE/hooks/check_before_build.sh" ]; check "check_before_build.sh installed and executable" $?
[ -x "$FAKE_CLAUDE/hooks/lib_config.sh" ]; check "lib_config.sh installed and executable" $?
[ -f "$FAKE_CLAUDE/skills/no-noodle.md" ]; check "skill doc installed" $?
[ -f "$FAKE_CLAUDE/skills/noodle-options.md" ]; check "noodle-options skill installed" $?
[ -f "$FAKE_CLAUDE/settings.json" ]; check "settings.json created" $?

python3 -c "
import json
data = json.load(open('$FAKE_CLAUDE/settings.json'))
cmds = [h.get('command','') for g in data['hooks']['PreToolUse'] for h in g.get('hooks',[])]
assert any('no_noodle.sh' in c for c in cmds), 'no_noodle.sh not registered'
assert any('check_before_build.sh' in c for c in cmds), 'check_before_build.sh not registered'
"
[ "$?" -eq 0 ]; check "both hooks registered in settings.json" $?

# --- idempotent: running again does not duplicate registrations ---
CLAUDE_CONFIG_DIR="$FAKE_CLAUDE" "$INSTALLER" >/dev/null 2>&1
python3 -c "
import json
data = json.load(open('$FAKE_CLAUDE/settings.json'))
cmds = [h.get('command','') for g in data['hooks']['PreToolUse'] for h in g.get('hooks',[])]
assert cmds.count([c for c in cmds if 'no_noodle.sh' in c][0]) == 1, 'no_noodle.sh duplicated'
assert cmds.count([c for c in cmds if 'check_before_build.sh' in c][0]) == 1, 'check_before_build.sh duplicated'
"
[ "$?" -eq 0 ]; check "re-running install does not duplicate hook registrations" $?

# --- install preserves a pre-existing unrelated hook entry ---
FAKE_CLAUDE2="$TMP/.claude2"
mkdir -p "$FAKE_CLAUDE2"
cat > "$FAKE_CLAUDE2/settings.json" <<'EOF'
{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/some_other_hook.sh"}]}]}}
EOF
CLAUDE_CONFIG_DIR="$FAKE_CLAUDE2" "$INSTALLER" >/dev/null 2>&1
python3 -c "
import json
data = json.load(open('$FAKE_CLAUDE2/settings.json'))
cmds = [h.get('command','') for g in data['hooks']['PreToolUse'] for h in g.get('hooks',[])]
assert any('some_other_hook.sh' in c for c in cmds), 'pre-existing unrelated hook was removed'
assert any('no_noodle.sh' in c for c in cmds), 'no_noodle.sh not added alongside existing hook'
"
[ "$?" -eq 0 ]; check "install preserves a pre-existing unrelated hook entry" $?

# --- uninstall removes files and hook registrations ---
CLAUDE_CONFIG_DIR="$FAKE_CLAUDE" "$INSTALLER" --uninstall >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ]; check "uninstall exits 0" $?
[ ! -f "$FAKE_CLAUDE/hooks/no_noodle.sh" ]; check "no_noodle.sh removed" $?
[ ! -f "$FAKE_CLAUDE/hooks/check_before_build.sh" ]; check "check_before_build.sh removed" $?
[ ! -f "$FAKE_CLAUDE/hooks/lib_config.sh" ]; check "lib_config.sh removed" $?
[ ! -f "$FAKE_CLAUDE/skills/no-noodle.md" ]; check "skill doc removed" $?
[ ! -f "$FAKE_CLAUDE/skills/noodle-options.md" ]; check "noodle-options skill removed" $?
python3 -c "
import json
data = json.load(open('$FAKE_CLAUDE/settings.json'))
cmds = [h.get('command','') for g in data['hooks']['PreToolUse'] for h in g.get('hooks',[])]
assert not any('no_noodle.sh' in c or 'check_before_build.sh' in c for c in cmds), 'hook registrations survived uninstall'
"
[ "$?" -eq 0 ]; check "uninstall removes hook registrations" $?

echo ""
if [ "$FAILS" -eq 0 ]; then
	echo "INSTALL TEST: ALL CHECKS PASSED."
else
	echo "INSTALL TEST: $FAILS CHECK(S) FAILED." >&2
	exit 1
fi
