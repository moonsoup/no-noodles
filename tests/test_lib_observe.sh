#!/usr/bin/env bash
# build-ok: new capability, not an extension of an existing script -- Phase 3
# of the weighted risk model, the "learning loop" observation log
# (docs/RISK_MODEL_PLAN.md's "Learning loop" section). lib_risk.sh scores a
# single command on demand; this is the append-only decision log risk_observe
# writes, a genuinely separate concern (persistence + rotation + fail-open
# wrapping around the scorer, not scoring itself).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB_RISK="$HERE/../hooks/lib_risk.sh"
LIB_OBSERVE="$HERE/../hooks/lib_observe.sh"
FAILS=0

check() {
	if [ "$2" -eq 0 ]; then
		echo "    OK: $1"
	else
		echo "    FAIL: $1" >&2
		FAILS=$((FAILS + 1))
	fi
}

[ -f "$LIB_OBSERVE" ]; check "lib_observe.sh exists" $?
bash -n "$LIB_OBSERVE"; check "lib_observe.sh has valid bash syntax" $?

TMP="$(mktemp -d)"
export CLAUDE_CONFIG_DIR="$TMP/claude"
mkdir -p "$CLAUDE_CONFIG_DIR"
trap 'rm -rf "$TMP"' EXIT

source "$LIB_RISK"
source "$LIB_OBSERVE"

OBS_FILE="$CLAUDE_CONFIG_DIR/no-noodles/observations.jsonl"

# --- a single observation appends one valid JSON line with the right shape --
risk_observe "rm -rf /tmp/foo" "" "blocked"
[ -f "$OBS_FILE" ]; check "risk_observe: creates the observations file on first call" $?
[ "$(wc -l < "$OBS_FILE" | tr -d ' ')" = "1" ]; check "risk_observe: appends exactly one line" $?

LINE="$(tail -1 "$OBS_FILE")"
python3 -c "import json; json.loads('''$LINE''')" 2>/dev/null; check "risk_observe: the appended line is valid JSON" $?
python3 -c "
import json
d = json.loads('''$LINE''')
assert 'ts' in d
assert 'command_signature' in d and len(d['command_signature']) > 0
assert d['outcome'] == 'blocked'
assert d['primary']['tier'] == 'Danger'
assert d['shadow']['tier'] == 'Danger'  # no profile yet -> shadow == primary
"
[ "$?" -eq 0 ]; check "risk_observe: entry has ts/command_signature/outcome/primary/shadow, shadow==primary with no profile" $?

# --- does not store the raw command text verbatim (privacy-conscious signature,
# not a full audit-log of literal commands) ---
echo "$LINE" | grep -qF "rm -rf /tmp/foo"; RC=$?
[ "$RC" -ne 0 ]; check "risk_observe: does not store the raw command text verbatim" $?

# --- multiple observations append, don't overwrite ---
risk_observe "ls -la" "" "allowed"
[ "$(wc -l < "$OBS_FILE" | tr -d ' ')" = "2" ]; check "risk_observe: a second call appends, doesn't overwrite" $?

# --- wrapped fail-open: a broken/unreadable rules file must never make
# risk_observe itself fail the caller ---
OUT="$(RISK_RULES_FILE=/nonexistent/rules.json risk_observe "rm -rf /" "" "blocked" 2>&1)"
RC=$?
[ "$RC" -eq 0 ]; check "risk_observe: missing rules file still exits 0 (fails open)" $?

# --- an unwritable observations dir must never fail the caller either ---
UNWRITABLE="$TMP/unwritable"
mkdir -p "$UNWRITABLE"
chmod 000 "$UNWRITABLE"
OUT="$(CLAUDE_CONFIG_DIR="$UNWRITABLE/claude" risk_observe "ls" "" "allowed" 2>&1)"
RC=$?
chmod 755 "$UNWRITABLE"
[ "$RC" -eq 0 ]; check "risk_observe: an unwritable observations dir still exits 0 (fails open, doesn't block the caller)" $?

# --- log rotation at a line-count bound: keeps the MOST RECENT lines ---
rm -f "$OBS_FILE"
for i in $(seq 1 12); do
	RISK_OBSERVATIONS_MAX_LINES=5 risk_observe "cmd$i" "" "allowed" >/dev/null 2>&1
done
LINE_COUNT="$(wc -l < "$OBS_FILE" | tr -d ' ')"
[ "$LINE_COUNT" -le 5 ]; check "risk_observe: rotates down to the configured max-lines bound (got $LINE_COUNT)" $?
LAST_SIG="$(python3 -c "import hashlib; print(hashlib.sha256(b'cmd12').hexdigest()[:16])")"
tail -1 "$OBS_FILE" | grep -qF "$LAST_SIG"; check "risk_observe: rotation keeps the most recent entry (cmd12), not the oldest" $?

echo ""
if [ "$FAILS" -eq 0 ]; then
	echo "LIB_OBSERVE TEST: ALL CHECKS PASSED."
else
	echo "LIB_OBSERVE TEST: $FAILS CHECK(S) FAILED." >&2
	exit 1
fi
