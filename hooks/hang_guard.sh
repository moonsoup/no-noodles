#!/usr/bin/env bash
# build-ok: new capability (rule 5) -- no existing hook looks at WHERE a command
# walks. Logic lives in hang_guard.py; this wrapper only does the shared
# on/off resolution, matching the other no-noodles hooks.
#
# PreToolUse hook -- hang guard. A one-off command that walks a directory tree
# on a hang-prone mount (FUSE / network / /Volumes) must be sized first: run it
# in the background, or state the estimate with '# hang-ok: <estimate>'. A mount
# that does not answer the guard's own probe is blocked outright. The guard
# never shortens a command and never recommends a timeout.
# Input: JSON on stdin. Exit 2 = block + message.
# Discipline it enforces: skills/no-noodle.md, rule 5.

INPUT=$(cat)

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_config.sh
source "$HOOK_DIR/lib_config.sh"
[ "$(resolve_state hang_guard "$CLAUDE_DIR/hang-guard.state")" = "off" ] && exit 0

OUT="$(printf '%s' "$INPUT" | python3 "$HOOK_DIR/hang_guard.py")"
RC=$?
# stderr: on exit 2 Claude Code feeds back stderr only.
[ -n "$OUT" ] && echo "$OUT" >&2
[ "$RC" -eq 2 ] && exit 2
exit 0
