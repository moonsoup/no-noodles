#!/usr/bin/env bash
# Run every tests/test_*.sh suite plus ruff on the Python hooks; print only
# failures and each suite's summary line. Exit 1 if anything failed.
# Usage: tests/run_all.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RC=0
for t in "$HERE"/test_*.sh; do
	OUT="$(bash "$t" 2>&1)" || RC=1
	printf '%s\n' "$OUT" | grep -E 'FAIL|TEST:'
done
if command -v ruff >/dev/null 2>&1; then
	ruff check "$HERE/../hooks/"*.py || RC=1
fi
exit "$RC"
