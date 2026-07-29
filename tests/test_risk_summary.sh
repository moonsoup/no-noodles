#!/usr/bin/env bash
# build-ok: new capability, not an extension of an existing script -- Phase 3's
# "summary/promote tooling" (docs/RISK_MODEL_PLAN.md, right-brain shadow-scoring
# pattern: "a human reads an agreement-rate summary and decides" on promoting
# learning.mode shadow-only -> live). risk_score.py computes one decision at a
# time; this aggregates the whole observations.jsonl log -- reporting, not
# scoring, and a genuinely separate concern.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../hooks/risk_summary.py"
FAILS=0

check() {
	if [ "$2" -eq 0 ]; then
		echo "    OK: $1"
	else
		echo "    FAIL: $1" >&2
		FAILS=$((FAILS + 1))
	fi
}

[ -f "$SCRIPT" ]; check "risk_summary.py exists" $?
python3 -c "import ast; ast.parse(open('$SCRIPT').read())"; check "risk_summary.py has valid Python syntax" $?

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OBS_FILE="$TMP/observations.jsonl"
PROFILE_FILE="$TMP/risk-profile.json"

# --- empty/missing log: reports zero observations, never crashes ---
OUT="$(python3 "$SCRIPT" "$TMP/does-not-exist.jsonl" 2>&1)"
RC=$?
[ "$RC" -eq 0 ]; check "missing observations file: exits 0, doesn't crash" $?
echo "$OUT" | grep -qi "0 observation"; check "missing observations file: reports zero observations" $?

# --- a real log: agreement rate + outcome mix ---
cat > "$OBS_FILE" <<'EOF'
{"ts": "2026-07-15T00:00:00Z", "command_signature": "aaa", "context": "", "primary": {"score": 60, "tier": "Danger"}, "shadow": {"score": 60, "tier": "Danger"}, "outcome": "blocked"}
{"ts": "2026-07-15T00:01:00Z", "command_signature": "bbb", "context": "", "primary": {"score": 10, "tier": "Safe"}, "shadow": {"score": 10, "tier": "Safe"}, "outcome": "allowed"}
{"ts": "2026-07-15T00:02:00Z", "command_signature": "ccc", "context": "", "primary": {"score": 30, "tier": "Caution"}, "shadow": {"score": 55, "tier": "Danger"}, "outcome": "overridden"}
{"ts": "2026-07-15T00:03:00Z", "command_signature": "ddd", "context": "", "primary": {"score": 10, "tier": "Safe"}, "shadow": {"score": 10, "tier": "Safe"}, "outcome": "allowed"}
EOF

OUT="$(python3 "$SCRIPT" "$OBS_FILE" 2>&1)"
RC=$?
[ "$RC" -eq 0 ]; check "real log: exits 0" $?
echo "$OUT" | grep -qF "4 observation"; check "real log: reports the correct total count" $?
echo "$OUT" | grep -qi "75.*%\|75%"; check "real log: reports the correct agreement rate (3/4 = 75%)" $?
echo "$OUT" | grep -qi "blocked.*1\|1.*blocked"; check "real log: outcome mix includes blocked count" $?
echo "$OUT" | grep -qi "allowed.*2\|2.*allowed"; check "real log: outcome mix includes allowed count" $?
echo "$OUT" | grep -qi "overridden.*1\|1.*overridden"; check "real log: outcome mix includes overridden count" $?

# --- a malformed line is skipped, not fatal ---
echo "not valid json{{{" >> "$OBS_FILE"
OUT="$(python3 "$SCRIPT" "$OBS_FILE" 2>&1)"
RC=$?
[ "$RC" -eq 0 ]; check "a malformed line in the log: still exits 0" $?
echo "$OUT" | grep -qF "4 observation"; check "a malformed line in the log: skipped, doesn't inflate the count" $?

# --- --promote flips risk-profile.json's mode (never automatic, this session
# always requires the flag to be passed explicitly by a human/agent action) --
echo '{"version": 1, "mode": "shadow-only", "command_adjustments": {}}' > "$PROFILE_FILE"
OUT="$(python3 "$SCRIPT" "$OBS_FILE" --promote "$PROFILE_FILE" 2>&1)"
RC=$?
[ "$RC" -eq 0 ]; check "--promote: exits 0" $?
python3 -c "
import json
d = json.load(open('$PROFILE_FILE'))
assert d['mode'] == 'live'
"
[ "$?" -eq 0 ]; check "--promote: flips risk-profile.json's mode to live" $?

# --- without --promote, the profile file is never touched ---
echo '{"version": 1, "mode": "shadow-only", "command_adjustments": {}}' > "$PROFILE_FILE"
python3 "$SCRIPT" "$OBS_FILE" >/dev/null 2>&1
python3 -c "
import json
d = json.load(open('$PROFILE_FILE'))
assert d['mode'] == 'shadow-only'
"
[ "$?" -eq 0 ]; check "without --promote: risk-profile.json's mode is untouched (never automatic)" $?

echo ""
if [ "$FAILS" -eq 0 ]; then
	echo "RISK_SUMMARY TEST: ALL CHECKS PASSED."
else
	echo "RISK_SUMMARY TEST: $FAILS CHECK(S) FAILED." >&2
	exit 1
fi
