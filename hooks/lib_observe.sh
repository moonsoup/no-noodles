#!/usr/bin/env bash
# build-ok: new capability, not an extension of an existing script -- Phase 3
# of the weighted risk model, the "Learning loop" observation log
# (docs/RISK_MODEL_PLAN.md). lib_risk.sh scores a single command on demand;
# this is the append-only decision log risk_observe writes (persistence +
# rotation + fail-open wrapping), a genuinely separate concern from scoring.
#
# risk_observe logs one decision (primary + shadow score, outcome) to
# $CLAUDE_DIR/no-noodles/observations.jsonl -- the training data + audit trail
# for Phase 3's summary/promote tooling. NEVER fails the caller: any error
# (unwritable dir, broken scorer) is swallowed and the function still returns
# 0, since observation must never become the reason a hook blocks or errors.
# The command itself is NOT stored verbatim -- only a stable signature (a
# truncated sha256 hash), so the log doesn't become a second copy of
# potentially sensitive command text.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# risk_observe <command> [target_path] [outcome] -- always returns 0.
risk_observe() {
	local command="$1" target_path="${2:-}" outcome="${3:-allowed}"
	(
		set -e
		local claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
		local obs_dir="$claude_dir/no-noodles"
		local obs_file="$obs_dir/observations.jsonl"
		local max_lines="${RISK_OBSERVATIONS_MAX_LINES:-5000}"

		# shellcheck source=lib_risk.sh
		[ -n "${RISK_SCORE_PY:-}" ] || source "$HOOK_DIR/lib_risk.sh"
		local shadow_result
		shadow_result="$(risk_shadow_score "$command" "$target_path")"
		[ -n "$shadow_result" ]

		mkdir -p "$obs_dir"

		local line
		line="$(python3 -c "
import json, sys, hashlib
from datetime import datetime, timezone
d = json.loads(sys.argv[1])
sig = hashlib.sha256(sys.argv[2].encode()).hexdigest()[:16]
entry = {
    'ts': datetime.now(timezone.utc).isoformat(),
    'command_signature': sig,
    'context': sys.argv[3],
    'primary': {'score': d['primary']['score'], 'tier': d['primary']['tier']},
    'shadow': {'score': d['shadow']['score'], 'tier': d['shadow']['tier']},
    'outcome': sys.argv[4],
}
print(json.dumps(entry))
" "$shadow_result" "$command" "$target_path" "$outcome")"
		[ -n "$line" ]

		echo "$line" >> "$obs_file"

		local count
		count="$(wc -l < "$obs_file" | tr -d ' ')"
		if [ "$count" -gt "$max_lines" ]; then
			tail -n "$max_lines" "$obs_file" > "$obs_file.tmp"
			mv "$obs_file.tmp" "$obs_file"
		fi
	) 2>/dev/null
	return 0
}
