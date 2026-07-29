#!/usr/bin/env bash
# build-ok: new capability, not an extension of an existing hook -- Phase 2 of
# the weighted risk model (docs/RISK_MODEL_PLAN.md). no_noodle.sh/
# check_before_build.sh each enforce one narrow, literal pattern; this scores
# EVERY Bash command via lib_risk.sh's weighted engine and enforces the
# ZTAI-derived tiered-confirmation model instead of a binary block.
#
# PreToolUse hook — weighted risk gate. Every risk tier stays reachable (no
# hard lockout, matching the plan's explicit rejection of a design that could
# lock the operator out of their own machine), but requires an escalating
# number of independent confirmation signals matching its severity:
#
#   Safe (0-20)     NONE   0 confirmations -- auto-allow
#   Caution (21-50) YELLOW 1 -- inline `# risk-ok` marker
#   Danger (51-80)  ORANGE 2 -- marker AND an active session-trust file
#   Critical(81-100)RED    3 -- marker AND session-trust AND a distinct env var
#
# Every override is itself a training signal for Phase 3's shadow-scoring
# learning loop (not implemented here -- see risk_observe in Phase 3).
#
# Input: JSON on stdin (tool_name, tool_input.command). Exit 2 = block.
# OFF BY DEFAULT (real decision this session): this is a much broader surface
# than the existing two literal-pattern rules -- it scores every Bash call, not
# one specific anti-pattern. Opt in via the /noodle-options skill (risk_scoring
# key) or lib_config.sh's usual JSON/legacy-state layers.
# Discipline it enforces: docs/RISK_MODEL_PLAN.md.

INPUT=$(cat)
TOOL=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null)
[ "$TOOL" = "Bash" ] || exit 0

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_config.sh
source "$HOOK_DIR/lib_config.sh"
# shellcheck source=lib_risk.sh
source "$HOOK_DIR/lib_risk.sh"

STATE="$CLAUDE_DIR/risk-gate.state"
# Off by default (3rd arg) -- see the file header for why. Same shared
# resolution chain (project-local -> global -> legacy -> default) as every
# other rule; only the fallback differs.
[ "$(resolve_state risk_scoring "$STATE" off)" = "off" ] && exit 0

CMD=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)
[ -z "$CMD" ] && exit 0

# Best-effort target-path extraction for lib_risk's context multiplier/fileset
# sensitivity (e.g. `dd ... of=/dev/disk4` is far more dangerous than the same
# command with no destination) -- last path-like substring anywhere in the
# command (not just leading tokens, since flags like `of=/dev/x` embed the
# path after an `=`). Absent entirely for an unmatched command, which is fine:
# classify_context defaults to the least-privileged "project" bucket.
TARGET_PATH="$(echo "$CMD" | grep -oE '(/[A-Za-z0-9_.~-]+)+' | tail -1)"

RESULT="$(risk_score "$CMD" "$TARGET_PATH")"
SCORE="$(risk_score_field "$RESULT" score)"
TIER="$(risk_score_field "$RESULT" tier)"
REASON="$(risk_score_field "$RESULT" reason)"

[ "$TIER" = "Safe" ] && exit 0

HAS_MARKER=1
echo "$CMD" | grep -qE '# *risk-ok' && HAS_MARKER=0

SESSION_TRUST="$CLAUDE_DIR/no-noodles/session-trust"
HAS_TRUST=1
[ -f "$SESSION_TRUST" ] && HAS_TRUST=0

HAS_CRITICAL_ENV=1
[ "${NO_NOODLES_RISK_CRITICAL_OVERRIDE:-}" = "1" ] && HAS_CRITICAL_ENV=0

case "$TIER" in
  Caution)
    if [ "$HAS_MARKER" -eq 0 ]; then exit 0; fi
    echo "RISK-GATE: Caution/YELLOW (score $SCORE) — $REASON. Append '# risk-ok' to confirm, or fix the underlying issue. See docs/RISK_MODEL_PLAN.md."
    exit 2
    ;;
  Danger)
    if [ "$HAS_MARKER" -eq 0 ] && [ "$HAS_TRUST" -eq 0 ]; then exit 0; fi
    echo "RISK-GATE: Danger/ORANGE (score $SCORE) — $REASON. Needs BOTH '# risk-ok' AND an active session-trust file ($SESSION_TRUST). See docs/RISK_MODEL_PLAN.md."
    exit 2
    ;;
  Critical)
    if [ "$HAS_MARKER" -eq 0 ] && [ "$HAS_TRUST" -eq 0 ] && [ "$HAS_CRITICAL_ENV" -eq 0 ]; then exit 0; fi
    echo "RISK-GATE: Critical/RED (score $SCORE) — $REASON. Needs '# risk-ok' AND session-trust AND NO_NOODLES_RISK_CRITICAL_OVERRIDE=1. See docs/RISK_MODEL_PLAN.md."
    exit 2
    ;;
esac
exit 0
