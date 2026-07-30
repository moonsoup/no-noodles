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
[ -x "$FAKE_CLAUDE/hooks/risk_gate.sh" ]; check "risk_gate.sh installed and executable" $?
[ -x "$FAKE_CLAUDE/hooks/lib_risk.sh" ]; check "lib_risk.sh installed and executable" $?
[ -x "$FAKE_CLAUDE/hooks/lib_observe.sh" ]; check "lib_observe.sh installed and executable" $?
[ -f "$FAKE_CLAUDE/hooks/risk_score.py" ]; check "risk_score.py installed" $?
[ -f "$FAKE_CLAUDE/hooks/risk-rules.json" ]; check "risk-rules.json installed" $?
[ -f "$FAKE_CLAUDE/hooks/risk_summary.py" ]; check "risk_summary.py installed" $?
[ -x "$FAKE_CLAUDE/hooks/grant_session_trust.sh" ]; check "grant_session_trust.sh installed and executable" $?
[ -f "$FAKE_CLAUDE/skills/no-noodle.md" ]; check "skill doc installed" $?
[ -f "$FAKE_CLAUDE/skills/noodle-options.md" ]; check "noodle-options skill installed" $?

# The docs must land where Claude Code can actually LOAD them, not merely on
# disk. Found empirically 2026-07-29: a flat `.md` directly under
# `$CLAUDE_DIR/skills/` is NOT registered — `/no-noodle` returned "Unknown
# skill" and it was absent from the session's skill list, in both config dirs,
# for weeks. What does register at user level on this machine is
# `$CLAUDE_DIR/commands/<name>.md` (proven by `commands/drive-status.md`, which
# is invocable). The skill text itself says "run /noodle-options", so a command
# was always the intent — the installer just put it somewhere inert.
#
# This is the whole discipline being decoration: the enforcement hooks worked
# fine, while the document explaining WHY they fire could not be opened by the
# agent they were correcting.
# --- version stamping ---
# There was no version marker of any kind before 1.0.0: no VERSION file, no tags,
# no releases. That is not a cosmetic gap — this session found ~/.claude and
# ~/.claude-ies carrying DIFFERENT versions of no-noodle.md (3379 vs 4383 bytes),
# and the only reason anyone noticed was an `ls -la` byte count read by eye. With
# the package now installed onto containers as well as two host config dirs,
# "which version is in there?" has to be answerable mechanically.
[ -f "$PKG_ROOT/VERSION" ]; check "package declares a VERSION (single source of truth)" $?
grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' "$PKG_ROOT/VERSION" 2>/dev/null
check "VERSION is a bare semver line" $?
[ -f "$FAKE_CLAUDE/no-noodles/VERSION" ]; check "installed version is stamped into the config dir" $?
diff -q "$PKG_ROOT/VERSION" "$FAKE_CLAUDE/no-noodles/VERSION" >/dev/null 2>&1
check "the stamp matches the package VERSION" $?

[ -f "$FAKE_CLAUDE/commands/no-noodle.md" ]; check "no-noodle installed as an INVOCABLE command (not just a skills/ file)" $?
[ -f "$FAKE_CLAUDE/commands/noodle-options.md" ]; check "noodle-options installed as an INVOCABLE command" $?
diff -q "$PKG_ROOT/skills/no-noodle.md" "$FAKE_CLAUDE/commands/no-noodle.md" >/dev/null 2>&1
check "the command copy is byte-identical to the packaged doc (one source of truth)" $?
[ -f "$FAKE_CLAUDE/settings.json" ]; check "settings.json created" $?

python3 -c "
import json
data = json.load(open('$FAKE_CLAUDE/settings.json'))
cmds = [h.get('command','') for g in data['hooks']['PreToolUse'] for h in g.get('hooks',[])]
assert any('no_noodle.sh' in c for c in cmds), 'no_noodle.sh not registered'
assert any('check_before_build.sh' in c for c in cmds), 'check_before_build.sh not registered'
assert any('risk_gate.sh' in c for c in cmds), 'risk_gate.sh not registered'
"
[ "$?" -eq 0 ]; check "all three hooks registered in settings.json" $?

# --- real incident (2026-07-16): hook commands must use the RESOLVED
# CLAUDE_CONFIG_DIR, not a hardcoded ~/.claude -- otherwise `~` expands to
# $HOME at hook-execution time and silently misses every install whose
# CLAUDE_CONFIG_DIR differs from the default, even though the files were
# copied to the right place. Caught live: risk_gate.sh installed cleanly into
# ~/.claude-ies/hooks/ but its settings.json command still read literal
# `~/.claude/hooks/risk_gate.sh`, erroring "No such file or directory" on
# every tool call. A scratch dir alone doesn't catch this if its basename
# happens to be ".claude" (a substring match on the command would still
# pass) -- this test uses a dir whose basename is deliberately NOT ".claude"
# so a hardcoded `~/.claude` fallback cannot accidentally satisfy it.
FAKE_CLAUDE3="$TMP/not-dot-claude-at-all"
CLAUDE_CONFIG_DIR="$FAKE_CLAUDE3" "$INSTALLER" >/dev/null 2>&1
python3 -c "
import json
data = json.load(open('$FAKE_CLAUDE3/settings.json'))
cmds = [h.get('command','') for g in data['hooks']['PreToolUse'] for h in g.get('hooks',[])]
assert any(c == 'bash $FAKE_CLAUDE3/hooks/no_noodle.sh' for c in cmds), f'no_noodle.sh command does not use resolved CLAUDE_CONFIG_DIR: {cmds}'
assert any(c == 'bash $FAKE_CLAUDE3/hooks/check_before_build.sh' for c in cmds), f'check_before_build.sh command does not use resolved CLAUDE_CONFIG_DIR: {cmds}'
assert any(c == 'bash $FAKE_CLAUDE3/hooks/risk_gate.sh' for c in cmds), f'risk_gate.sh command does not use resolved CLAUDE_CONFIG_DIR: {cmds}'
"
[ "$?" -eq 0 ]; check "hook commands use the resolved CLAUDE_CONFIG_DIR, not a hardcoded ~/.claude" $?

# --- idempotent: running again does not duplicate registrations ---
CLAUDE_CONFIG_DIR="$FAKE_CLAUDE" "$INSTALLER" >/dev/null 2>&1
python3 -c "
import json
data = json.load(open('$FAKE_CLAUDE/settings.json'))
cmds = [h.get('command','') for g in data['hooks']['PreToolUse'] for h in g.get('hooks',[])]
assert cmds.count([c for c in cmds if 'no_noodle.sh' in c][0]) == 1, 'no_noodle.sh duplicated'
assert cmds.count([c for c in cmds if 'check_before_build.sh' in c][0]) == 1, 'check_before_build.sh duplicated'
assert cmds.count([c for c in cmds if 'risk_gate.sh' in c][0]) == 1, 'risk_gate.sh duplicated'
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

# --- uninstall removes hooks but preserves accumulated observation data ---
mkdir -p "$FAKE_CLAUDE/no-noodles"
echo '{"ts":"2026-07-15T00:00:00Z"}' > "$FAKE_CLAUDE/no-noodles/observations.jsonl"
CLAUDE_CONFIG_DIR="$FAKE_CLAUDE" "$INSTALLER" --uninstall >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ]; check "uninstall exits 0" $?
[ ! -f "$FAKE_CLAUDE/hooks/no_noodle.sh" ]; check "no_noodle.sh removed" $?
[ ! -f "$FAKE_CLAUDE/hooks/check_before_build.sh" ]; check "check_before_build.sh removed" $?
[ ! -f "$FAKE_CLAUDE/hooks/lib_config.sh" ]; check "lib_config.sh removed" $?
[ ! -f "$FAKE_CLAUDE/hooks/risk_gate.sh" ]; check "risk_gate.sh removed" $?
[ ! -f "$FAKE_CLAUDE/hooks/lib_risk.sh" ]; check "lib_risk.sh removed" $?
[ ! -f "$FAKE_CLAUDE/hooks/lib_observe.sh" ]; check "lib_observe.sh removed" $?
[ ! -f "$FAKE_CLAUDE/hooks/risk_score.py" ]; check "risk_score.py removed" $?
[ ! -f "$FAKE_CLAUDE/hooks/risk-rules.json" ]; check "risk-rules.json removed" $?
[ ! -f "$FAKE_CLAUDE/hooks/risk_summary.py" ]; check "risk_summary.py removed" $?
[ ! -f "$FAKE_CLAUDE/hooks/grant_session_trust.sh" ]; check "grant_session_trust.sh removed" $?
[ -f "$FAKE_CLAUDE/no-noodles/observations.jsonl" ]; check "uninstall preserves accumulated observations.jsonl (not disposable state)" $?
# The stamp describes what IS installed, so uninstalling must clear it — leaving a
# version behind would claim the package is present when it isn't, which is the
# same false-presence problem that hid the unloadable skill for weeks.
[ ! -f "$FAKE_CLAUDE/no-noodles/VERSION" ]; check "uninstall removes the version stamp (it describes an install that no longer exists)" $?
[ ! -f "$FAKE_CLAUDE/skills/no-noodle.md" ]; check "skill doc removed" $?
[ ! -f "$FAKE_CLAUDE/skills/noodle-options.md" ]; check "noodle-options skill removed" $?
[ ! -f "$FAKE_CLAUDE/commands/no-noodle.md" ]; check "no-noodle command removed" $?
[ ! -f "$FAKE_CLAUDE/commands/noodle-options.md" ]; check "noodle-options command removed" $?
python3 -c "
import json
data = json.load(open('$FAKE_CLAUDE/settings.json'))
cmds = [h.get('command','') for g in data['hooks']['PreToolUse'] for h in g.get('hooks',[])]
assert not any('no_noodle.sh' in c or 'check_before_build.sh' in c or 'risk_gate.sh' in c for c in cmds), 'hook registrations survived uninstall'
"
[ "$?" -eq 0 ]; check "uninstall removes hook registrations" $?

echo ""
if [ "$FAILS" -eq 0 ]; then
	echo "INSTALL TEST: ALL CHECKS PASSED."
else
	echo "INSTALL TEST: $FAILS CHECK(S) FAILED." >&2
	exit 1
fi
