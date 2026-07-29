#!/usr/bin/env bash
# build-ok: new capability, not an extension of an existing script -- Phase 3
# of the weighted risk model (docs/RISK_MODEL_PLAN.md) explicitly calls out
# "session-trust file added here." risk_gate.sh only CHECKS for the file's
# presence (Phase 2); this is the deliberate-user-action tool that actually
# creates/removes it, without which ORANGE/RED gate tiers would be permanently
# unreachable -- a hard lockout the plan explicitly rejected as a design.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../hooks/grant_session_trust.sh"
FAILS=0

check() {
	if [ "$2" -eq 0 ]; then
		echo "    OK: $1"
	else
		echo "    FAIL: $1" >&2
		FAILS=$((FAILS + 1))
	fi
}

[ -f "$SCRIPT" ]; check "grant_session_trust.sh exists" $?
bash -n "$SCRIPT"; check "grant_session_trust.sh has valid bash syntax" $?

TMP="$(mktemp -d)"
export CLAUDE_CONFIG_DIR="$TMP/claude"
trap 'rm -rf "$TMP"' EXIT
TRUST_FILE="$CLAUDE_CONFIG_DIR/no-noodles/session-trust"

# --- status with nothing granted yet ---
OUT="$(bash "$SCRIPT" status 2>&1)"
echo "$OUT" | grep -qi "not active"; check "status: reports not active when nothing granted" $?
[ ! -f "$TRUST_FILE" ]; check "status: does not create the trust file as a side effect" $?

# --- grant creates the file ---
OUT="$(bash "$SCRIPT" grant 2>&1)"
RC=$?
[ "$RC" -eq 0 ]; check "grant: exits 0" $?
[ -f "$TRUST_FILE" ]; check "grant: creates the session-trust file" $?
echo "$OUT" | grep -qi "granted"; check "grant: confirms what happened" $?

OUT="$(bash "$SCRIPT" status 2>&1)"
echo "$OUT" | grep -qi "active"; check "status: reports active after granting" $?

# --- revoke removes it ---
OUT="$(bash "$SCRIPT" revoke 2>&1)"
RC=$?
[ "$RC" -eq 0 ]; check "revoke: exits 0" $?
[ ! -f "$TRUST_FILE" ]; check "revoke: removes the session-trust file" $?

# --- revoke when nothing was granted: still exits 0, not an error ---
OUT="$(bash "$SCRIPT" revoke 2>&1)"
RC=$?
[ "$RC" -eq 0 ]; check "revoke with nothing granted: still exits 0 (idempotent)" $?

# --- unknown subcommand: usage error, non-zero exit ---
OUT="$(bash "$SCRIPT" bogus 2>&1)"
RC=$?
[ "$RC" -ne 0 ]; check "unknown subcommand: non-zero exit" $?
echo "$OUT" | grep -qi "usage"; check "unknown subcommand: prints usage" $?

# --- this is what actually unlocks risk_gate.sh's Danger/Critical tiers ---
LIB_RISK="$HERE/../hooks/lib_risk.sh"
LIB_CONFIG="$HERE/../hooks/lib_config.sh"
HOOK="$HERE/../hooks/risk_gate.sh"
mkdir -p "$CLAUDE_CONFIG_DIR"
echo '{"risk_scoring": "on"}' > "$CLAUDE_CONFIG_DIR/no-noodles.json"
bash "$SCRIPT" grant >/dev/null 2>&1
OUT="$(python3 -c "
import json, sys
print(json.dumps({'tool_name': 'Bash', 'tool_input': {'command': 'rm -rf /tmp/foo # risk-ok'}}))
" | bash "$HOOK" 2>&1)"
RC=$?
[ "$RC" -eq 0 ]; check "end-to-end: a granted session-trust file + marker actually passes risk_gate.sh's Danger tier" $?
bash "$SCRIPT" revoke >/dev/null 2>&1

echo ""
if [ "$FAILS" -eq 0 ]; then
	echo "GRANT_SESSION_TRUST TEST: ALL CHECKS PASSED."
else
	echo "GRANT_SESSION_TRUST TEST: $FAILS CHECK(S) FAILED." >&2
	exit 1
fi
