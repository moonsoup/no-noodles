#!/usr/bin/env bash
# Phase 1 of the weighted risk model: a static scoring function, sourced by
# hooks the same way lib_config.sh is. Not wired into any hook yet -- pure
# library, exercised only by its own tests (tests/test_lib_risk.sh).
#
# risk_score prints one JSON line: {score, tier, risk_category, reason,
# intent, matched, flags_matched}. Never fails a caller's flow -- an error
# scoring (missing rules file, malformed command) resolves to Safe/0 rather
# than raising, since scoring must never itself become the reason a hook
# blocks something it didn't mean to.
#
# See hooks/risk-rules.json for the seed rule table and
# hooks/risk_score.py for the actual scoring logic (kept in Python since the
# rule-matching + multiplier arithmetic is real logic, not a single JSON
# field read like lib_config.sh's _json_get).

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RISK_RULES_FILE="${RISK_RULES_FILE:-$HOOK_DIR/risk-rules.json}"
RISK_SCORE_PY="${RISK_SCORE_PY:-$HOOK_DIR/risk_score.py}"

# risk_score <command> [target_path] -- prints the JSON result line, or a
# safe-default fallback JSON line if scoring itself fails for any reason.
risk_score() {
	local command="$1" target_path="${2:-}"
	local out
	out="$(python3 "$RISK_SCORE_PY" "$RISK_RULES_FILE" "$command" "$target_path" 2>/dev/null)"
	if [ -z "$out" ]; then
		echo '{"score": 0, "tier": "Safe", "risk_category": null, "reason": "scoring unavailable, defaulted safe", "intent": null, "matched": false, "flags_matched": []}'
		return
	fi
	echo "$out"
}

# risk_shadow_score <command> [target_path] [profile_path] -- Phase 3.
# Computes primary (same as risk_score) AND a shadow score adjusted by a
# learned profile, printed as {"primary": {...}, "shadow": {...}}. Fails open
# exactly like risk_score: any error (missing rules, missing/malformed
# profile) resolves to a safe primary=Safe/shadow=Safe result rather than
# raising, since scoring must never itself become the reason a caller blocks.
# profile_path defaults to $CLAUDE_DIR/no-noodles/risk-profile.json.
risk_shadow_score() {
	local command="$1" target_path="${2:-}" profile_path="${3:-${CLAUDE_DIR:-$HOME/.claude}/no-noodles/risk-profile.json}"
	local out
	out="$(python3 "$RISK_SCORE_PY" "$RISK_RULES_FILE" "$command" "$target_path" "$profile_path" 2>/dev/null)"
	if [ -z "$out" ]; then
		echo '{"primary": {"score": 0, "tier": "Safe", "risk_category": null, "reason": "scoring unavailable, defaulted safe", "intent": null, "matched": false, "flags_matched": []}, "shadow": {"score": 0, "tier": "Safe", "risk_category": null, "reason": "scoring unavailable, defaulted safe", "intent": null, "matched": false, "flags_matched": [], "multiplier_applied": 1.0}}'
		return
	fi
	echo "$out"
}

# risk_score_field <json_line> <field> -- pulls one field out of a
# risk_score() result line without needing a full JSON parser inline in
# every caller. Testing/composition convenience.
risk_score_field() {
	local json_line="$1" field="$2"
	python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    v = d.get(sys.argv[2])
    print(v if v is not None else '')
except Exception:
    print('')
" "$json_line" "$field" 2>/dev/null
}
