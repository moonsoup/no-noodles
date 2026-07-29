#!/usr/bin/env bash
# Tests for hooks/lib_config.sh's resolve_state resolution order:
# project-local ./.no-noodles.json > global $CLAUDE_DIR/no-noodles.json >
# legacy .state file > default "on".
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../hooks/lib_config.sh"
FAILS=0

check() {
	if [ "$2" -eq 0 ]; then
		echo "    OK: $1"
	else
		echo "    FAIL: $1" >&2
		FAILS=$((FAILS + 1))
	fi
}

[ -f "$LIB" ]; check "lib_config.sh exists" $?
bash -n "$LIB"; check "lib_config.sh has valid bash syntax" $?

TMP="$(mktemp -d)"
export CLAUDE_CONFIG_DIR="$TMP/claude"
mkdir -p "$CLAUDE_CONFIG_DIR"
PROJECT_DIR="$TMP/project"
mkdir -p "$PROJECT_DIR"
LEGACY_STATE="$CLAUDE_CONFIG_DIR/some-rule.state"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

run_resolve() {
	# run_resolve <rule_key> -- from $PROJECT_DIR, sourcing the real lib
	( cd "$PROJECT_DIR" && source "$LIB" && resolve_state "$1" "$LEGACY_STATE" )
}

# --- default: nothing configured anywhere -> "on" ---
OUT="$(run_resolve my_rule)"
[ "$OUT" = "on" ]; check "no config anywhere: defaults to on" $?

# --- legacy .state file "off" is honored ---
echo off > "$LEGACY_STATE"
OUT="$(run_resolve my_rule)"
[ "$OUT" = "off" ]; check "legacy .state file off: resolves off" $?
rm -f "$LEGACY_STATE"

# --- global JSON overrides default ---
echo '{"my_rule": "off"}' > "$CLAUDE_CONFIG_DIR/no-noodles.json"
OUT="$(run_resolve my_rule)"
[ "$OUT" = "off" ]; check "global JSON off: resolves off" $?

# --- global JSON overrides a conflicting legacy state file too ---
echo on > "$LEGACY_STATE"
OUT="$(run_resolve my_rule)"
[ "$OUT" = "off" ]; check "global JSON wins over legacy .state file" $?
rm -f "$LEGACY_STATE"

# --- project-local JSON overrides global JSON ---
echo '{"my_rule": "on"}' > "$PROJECT_DIR/.no-noodles.json"
OUT="$(run_resolve my_rule)"
[ "$OUT" = "on" ]; check "project-local JSON wins over global JSON" $?

# --- a rule key present in neither JSON file falls all the way through to default ---
OUT="$(run_resolve other_rule)"
[ "$OUT" = "on" ]; check "unset key in both JSON files: falls through to default on" $?

# --- a rule key set in global but not project-local falls through to global ---
echo '{"my_rule": "on", "shared_rule": "off"}' > "$CLAUDE_CONFIG_DIR/no-noodles.json"
OUT="$(run_resolve shared_rule)"
[ "$OUT" = "off" ]; check "key unset in project-local, set in global: uses global" $?

# --- malformed JSON doesn't crash, falls through to next layer ---
# (global now has my_rule="on" from the previous step)
echo 'not valid json{{{' > "$PROJECT_DIR/.no-noodles.json"
OUT="$(run_resolve my_rule)"
[ "$OUT" = "on" ]; check "malformed project-local JSON: falls through without crashing" $?
rm -f "$PROJECT_DIR/.no-noodles.json" "$CLAUDE_CONFIG_DIR/no-noodles.json"

# --- optional 3rd arg overrides the hardcoded "on" default (existing 2-arg
# callers are unaffected -- every test above this point already proved that) ---
run_resolve_with_default() {
	( cd "$PROJECT_DIR" && source "$LIB" && resolve_state "$1" "$LEGACY_STATE" "$2" )
}
OUT="$(run_resolve_with_default fresh_rule off)"
[ "$OUT" = "off" ]; check "3rd-arg default 'off': nothing configured anywhere resolves off" $?
OUT="$(run_resolve_with_default fresh_rule on)"
[ "$OUT" = "on" ]; check "3rd-arg default 'on': explicit on behaves the same as the implicit default" $?

# --- the optional default is still overridden by every higher-priority layer ---
echo off > "$LEGACY_STATE"
OUT="$(run_resolve_with_default fresh_rule on)"
[ "$OUT" = "off" ]; check "3rd-arg default 'on': legacy .state file off still wins" $?
rm -f "$LEGACY_STATE"

echo '{"fresh_rule": "on"}' > "$CLAUDE_CONFIG_DIR/no-noodles.json"
OUT="$(run_resolve_with_default fresh_rule off)"
[ "$OUT" = "on" ]; check "3rd-arg default 'off': global JSON on still wins" $?
rm -f "$CLAUDE_CONFIG_DIR/no-noodles.json"

echo ""
if [ "$FAILS" -eq 0 ]; then
	echo "LIB_CONFIG TEST: ALL CHECKS PASSED."
else
	echo "LIB_CONFIG TEST: $FAILS CHECK(S) FAILED." >&2
	exit 1
fi
