#!/usr/bin/env bash
# Tests for hooks/hang_guard.sh (rule 5). Runs the real hook against synthetic
# PreToolUse JSON on stdin; no guarded command is ever executed. The mount table
# and the liveness probe are injected (NO_NOODLES_MOUNT_TABLE,
# NO_NOODLES_HANG_PROBE_CMD) so nothing here touches a real external mount.
#
# Motivating incident (2026-11-02): a one-off `find ... | sort | uniq -c; du -sh`
# over ~thousands of carved files on the fuse-ext2 DockProjects mount wedged the
# mount; the session froze, every session sent to inspect it froze, and the
# shutdown stalled. No existing rule looked at WHERE a command walks.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/hang_guard.sh"
FAILS=0

check() {
	if [ "$2" -eq 0 ]; then
		echo "    OK: $1"
	else
		echo "    FAIL: $1" >&2
		FAILS=$((FAILS + 1))
	fi
}

[ -f "$HOOK" ]; check "hang_guard.sh exists" $?
[ -x "$HOOK" ]; check "hang_guard.sh is executable" $?
bash -n "$HOOK"; check "hang_guard.sh has valid bash syntax" $?
[ -f "$HERE/../hooks/hang_guard.py" ]; check "hang_guard.py exists" $?

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP/claude"
mkdir -p "$CLAUDE_CONFIG_DIR"

MNT="$TMP/dock"            # stands in for a fuse-ext2 mount
VOL="$TMP/Volumes/SAM'S IPOD"  # name with an apostrophe and a space
mkdir -p "$MNT/carved" "$VOL"
TABLE="$TMP/mounts.txt"
cat > "$TABLE" <<EOF
/dev/disk3s3s1 on / (apfs, sealed, local, read-only, journaled)
fuse-ext2@macfuse0 on $MNT (macfuse, local, synchronous)
/dev/disk4s1 on $VOL (msdos, local, nodev, nosuid, noowners, noatime, fskit)
//user@nas/share on $TMP/nas (smbfs, nodev, nosuid, mounted by someuser)
EOF
export NO_NOODLES_MOUNT_TABLE="$TABLE"
export NO_NOODLES_HANG_PROBE_SECS=3

run_hook() {
	# run_hook <command> [run_in_background(true|false)]
	python3 -c "
import json, sys
bg = sys.argv[2] == 'true'
print(json.dumps({'tool_name': 'Bash', 'tool_input': {'command': sys.argv[1], 'run_in_background': bg}}))
" "$1" "${2:-false}" | bash "$HOOK"
}

# --- not our business: non-Bash, non-walks, walks elsewhere ---
OUT="$(echo '{"tool_name":"Read","tool_input":{}}' | bash "$HOOK" 2>&1)"
[ "$?" -eq 0 ]; check "non-Bash tool call is never blocked" $?

run_hook "du -sh $TMP/elsewhere" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "a walk on an ordinary local path is not blocked" $?

run_hook "tail -25 $MNT/carved/photorec.log" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "reading ONE named file on the mount is not blocked" $?

run_hook "ls $MNT/carved" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "a plain (non-recursive) ls on the mount is not blocked" $?

run_hook "$MNT/scripts/carve.sh --resume" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "invoking a script is not a walk (the script owns its own safety)" $?

# --- the incident's exact shape: blocked, with the scale and the right advice ---
INCIDENT="C=$MNT/carved; tail -25 \$C/photorec.log | grep -vE '^\\s*\$'; ls \$C; find \$C -path '*recup.*' -type f | sed 's/.*\\.//' | sort | uniq -c; du -sh \$C"
OUT="$(run_hook "$INCIDENT" 2>&1)"
RC=$?
[ "$RC" -eq 2 ]; check "the 2026-11-02 incident command is blocked" $?
echo "$OUT" | grep -qF "HANG-GUARD"; check "block message identifies the rule" $?
echo "$OUT" | grep -qF "$MNT"; check "block message names the mount" $?
echo "$OUT" | grep -qiE "files in use"; check "block message reports the filesystem's scale" $?
echo "$OUT" | grep -qF "run_in_background"; check "block message offers the background path" $?
echo "$OUT" | grep -qF "# hang-ok:"; check "block message shows the estimate marker" $?
# User instruction (2026-11-03): never arbitrarily cut a command short.
echo "$OUT" | grep -qiE "add (a|an arbitrary)? ?timeout|use timeout|wrap .*timeout"
[ "$?" -ne 0 ]; check "block message never recommends adding a timeout" $?

# --- every walker the rule claims to know ---
for c in "find $MNT -name x" "du -sh $MNT" "tree $MNT" "rsync -a $MNT/ /tmp/x/" \
	"ls -laR $MNT" "grep -rn foo $MNT" "cp -R $MNT/carved /tmp/y" "lsof +D $MNT" \
	"rg foo $MNT" "tar czf /tmp/a.tgz $MNT/carved" "chmod -R u+w $MNT/carved" \
	"sudo du -sh $MNT"; do
	run_hook "$c" >/dev/null 2>&1
	[ "$?" -eq 2 ]; check "walk is caught: $c" $?
done

run_hook "find $TMP/nas -type f" >/dev/null 2>&1
[ "$?" -eq 2 ]; check "a network (smbfs) mount is treated as hang-prone" $?

run_hook "find \"$VOL/iPod_Control\" -type f" >/dev/null 2>&1
[ "$?" -eq 2 ]; check "a quoted /Volumes path with an apostrophe is matched to its mount" $?

ESCAPED="$(printf '%s' "$VOL" | sed -e "s/'/\\\\'/g" -e 's/ /\\ /g')"
run_hook "find $ESCAPED/iPod_Control -type f" >/dev/null 2>&1
[ "$?" -eq 2 ]; check "a backslash-escaped path (\\' and \\ ) is matched to its mount" $?

run_hook "find ~/x -name y" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "~ paths outside any hang-prone mount pass" $?

# --- relative walk with the working directory on the mount ---
( cd "$MNT/carved" && run_hook "du -sh ." >/dev/null 2>&1 )
[ "$?" -eq 2 ]; check "a relative walk from a cwd on the mount is caught" $?

# --- FAT/exFAT report no file count (f_files=0): say so, never claim "0 files" ---
OUT="$(NO_NOODLES_HANG_PROBE_CMD="echo 0 1200000000" run_hook "du -sh $MNT/carved" 2>&1)"
echo "$OUT" | grep -qF "file count not reported"; check "a filesystem with no file count says so" $?
echo "$OUT" | grep -qF "0 files in use"
[ "$?" -ne 0 ]; check "it never claims '0 files in use'" $?

# --- Claude Code feeds back STDERR on exit 2, not stdout ---
ERR="$(run_hook "du -sh $MNT/carved" 2>&1 >/dev/null)"
echo "$ERR" | grep -qF "HANG-GUARD"; check "block message goes to stderr (the agent sees it)" $?

# --- ways to proceed: background, or a stated effort estimate ---
run_hook "du -sh $MNT/carved" true >/dev/null 2>&1
[ "$?" -eq 0 ]; check "run_in_background passes (full time, session never frozen)" $?

run_hook "du -sh $MNT/carved  # hang-ok: ~3k carved files, expect <1 min on a healthy mount" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "a hang-ok marker WITH an effort estimate passes" $?

OUT="$(run_hook "du -sh $MNT/carved  # hang-ok" 2>&1)"
RC=$?
[ "$RC" -eq 2 ]; check "a bare hang-ok (no estimate) is still blocked" $?
echo "$OUT" | grep -qi "estimate"; check "bare-marker block asks for the estimate" $?

run_hook "timeout 30 du -sh $MNT/carved" >/dev/null 2>&1
[ "$?" -eq 2 ]; check "a timeout alone does not satisfy the rule (no effort assessment)" $?

# --- a mount that does not answer: blocked even in the background ---
START=$(date +%s)
OUT="$(NO_NOODLES_HANG_PROBE_CMD="sleep 30" NO_NOODLES_HANG_PROBE_SECS=1 run_hook "du -sh $MNT/carved" true 2>&1)"
RC=$?
ELAPSED=$(( $(date +%s) - START ))
[ "$RC" -eq 2 ]; check "an unresponsive mount is blocked even with run_in_background" $?
echo "$OUT" | grep -qi "not answering"; check "wedged-mount message says the mount is not answering" $?
echo "$OUT" | grep -qF "fuse-mount-recovery"; check "wedged-mount message points at the recovery skill" $?
[ "$ELAPSED" -le 6 ]; check "the hook itself never hangs on a wedged mount (${ELAPSED}s)" $?

OUT="$(NO_NOODLES_HANG_PROBE_CMD="sleep 30" NO_NOODLES_HANG_PROBE_SECS=1 run_hook "du -sh $MNT/carved  # hang-ok: it is wedged and I know; collecting evidence" 2>&1)"
[ "$?" -eq 0 ]; check "an explicit, reasoned override is still honoured on a wedged mount" $?

# --- config: per-rule key, default on ---
echo '{"hang_guard": "off"}' > "$CLAUDE_CONFIG_DIR/no-noodles.json"
run_hook "du -sh $MNT/carved" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "hang_guard off: no longer blocks" $?
rm -f "$CLAUDE_CONFIG_DIR/no-noodles.json"

echo off > "$CLAUDE_CONFIG_DIR/hang-guard.state"
run_hook "du -sh $MNT/carved" >/dev/null 2>&1
[ "$?" -eq 0 ]; check "legacy state file off: no longer blocks" $?
rm -f "$CLAUDE_CONFIG_DIR/hang-guard.state"

run_hook "du -sh $MNT/carved" >/dev/null 2>&1
[ "$?" -eq 2 ]; check "default (nothing configured) is on" $?

echo ""
if [ "$FAILS" -eq 0 ]; then
	echo "HANG_GUARD TEST: ALL CHECKS PASSED."
else
	echo "HANG_GUARD TEST: $FAILS CHECK(S) FAILED." >&2
	exit 1
fi
