#!/usr/bin/env bash
# build-ok: new capability, not an extension of an existing script -- Phase 3
# of the weighted risk model (docs/RISK_MODEL_PLAN.md) explicitly calls out
# "session-trust file added here." risk_gate.sh (Phase 2) only CHECKS for the
# file's presence; this is the deliberate-user-action tool that actually
# creates/removes it. Without this, Danger/Critical gate tiers would be
# permanently unreachable -- a hard lockout the plan explicitly rejected.
#
# A session-trust grant is deliberately a manual, explicit action (run this,
# or ask Claude Code to run it when you've decided to trust the current
# session for elevated-risk commands) -- never granted automatically by any
# hook or scoring logic itself.
#
# Usage: grant_session_trust.sh grant|revoke|status
set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TRUST_FILE="$CLAUDE_DIR/no-noodles/session-trust"

case "${1:-status}" in
	grant)
		mkdir -p "$(dirname "$TRUST_FILE")"
		date -u +"%Y-%m-%dT%H:%M:%SZ" > "$TRUST_FILE"
		echo "session-trust: granted ($TRUST_FILE). Danger/Critical-tier risk_gate.sh commands can now clear that confirmation layer (still need their other required signals too)."
		;;
	revoke)
		rm -f "$TRUST_FILE"
		echo "session-trust: revoked."
		;;
	status)
		if [ -f "$TRUST_FILE" ]; then
			echo "session-trust: active (granted $(cat "$TRUST_FILE" 2>/dev/null))"
		else
			echo "session-trust: not active"
		fi
		;;
	*)
		echo "usage: $0 grant|revoke|status" >&2
		exit 1
		;;
esac
