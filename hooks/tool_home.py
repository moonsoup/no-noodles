#!/usr/bin/env python3
"""Placement half of no-noodle rule #4 (check before building): a new tool must land in
the RIGHT HOME, not just "nowhere that already has one".

Real incident (2026-11-19): globally useful IES operations tools (a DNS zone mover, a
Hostinger catalog/order script, a page-blank verifier, a cPanel canary) were each created
with a valid `# build-ok: nothing similar here` marker -- in whichever project repo was
nearest (site-platform, agency-os, ies-deploy) instead of the operations home with its
approved-script registry. The marker answered "is there an existing script HERE?", never
"is HERE the right place?". Moving a script in with `mv`/`cp` skipped the check entirely.

Config (`tool_homes`, a list; project ./.no-noodles.json entries first, then global
$CLAUDE_DIR/no-noodles.json -- same layering as lib_config.sh):
  {"tool_homes": [{"applies_to": "~/work/IronEggShell",
                   "path": "~/work/IronEggShell/ironeggshell_ai_ops/scripts/approved",
                   "scope": "ops",
                   "registry": "~/work/IronEggShell/ironeggshell_ai_ops/script_registry/registry.yaml"}]}

Marker grammar when a tool home applies to the destination:
  # build-ok: home=ops <reason>                       -> must be created under the home path
  # build-ok: home=project consumer=<who uses it> <reason>
                                                     -> allowed anywhere, consumer named
Where no tool home applies, the original bare `# build-ok: <reason>` still passes
(backward compatible -- never remove an option).

CLI (used by hooks/check_before_build.sh; JSON tool call on stdin):
  tool_home.py write   -> exit 0 allow, 2 block (message on stderr)
  tool_home.py bash    -> mv/cp/install/ln into a scripts/ dir; 0 allow/warn, 2 block
"""
import json
import os
import re
import shlex
import sys

SCRIPT_EXT = (".py", ".sh", ".js", ".ts", ".rb")
TEST_NAMES = re.compile(r"^(test_.*|.*_test\.py|.*\.test\.(js|ts))$")
MARKER = re.compile(r"(?:#|//)\s*build-ok:\s*(.*)")
MOVERS = {"mv", "cp", "install", "ln"}


def _expand(p):
    return os.path.realpath(os.path.expanduser(p)) if p else ""


def _claude_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")


def load_homes(cwd="."):
    homes = []
    for f in (os.path.join(cwd, ".no-noodles.json"), os.path.join(_claude_dir(), "no-noodles.json")):
        try:
            with open(f) as fh:
                data = json.load(fh)
        except Exception:
            continue
        for h in data.get("tool_homes") or []:
            if isinstance(h, dict) and h.get("path") and h.get("applies_to"):
                homes.append(h)
    return homes


def is_new_script(path):
    """Script-like file inside a scripts/ dir that is not a test -- the rule #4 net."""
    norm = path.replace("\\", "/")
    if "/scripts/" not in norm or not norm.endswith(SCRIPT_EXT):
        return False
    return not TEST_NAMES.match(os.path.basename(norm))


def applicable_home(dest, homes):
    d = _expand(dest)
    for h in homes:
        root = _expand(h["applies_to"])
        if d == root or d.startswith(root + os.sep):
            return h
    return None


def parse_marker(content):
    """(present, home, consumer, reason) from the first build-ok marker."""
    m = MARKER.search(content or "")
    if not m:
        return False, None, None, ""
    rest = m.group(1).strip()
    home = re.search(r"\bhome=(\S+)", rest)
    consumer = re.search(r"\bconsumer=(\S+)", rest)
    return True, home.group(1) if home else None, consumer.group(1) if consumer else None, rest


OLD_MSG = ("CHECK-BEFORE-BUILD: new script {path} — before creating it, confirm no existing script "
           "in this scripts/ dir already covers this (or could grow a flag/option to cover it). If this "
           "is genuinely a new, unrelated capability, add a first-line comment '# build-ok: <why this "
           "isn't an extension of an existing script>' and retry. See ~/.claude/skills/no-noodle.md rule 4.")


def _home_desc(h):
    reg = f" and register it in {h['registry']}" if h.get("registry") else ""
    return f"{h.get('scope', 'ops')} home {h['path']}{reg}"


def decide(dest, content, homes):
    """('allow'|'block', message). Pure: no filesystem writes."""
    present, home, consumer, _ = parse_marker(content)
    h = applicable_home(dest, homes)
    if h is None:
        return ("allow", "") if present else ("block", OLD_MSG.format(path=dest))
    scope = h.get("scope", "ops")
    head = (f"CHECK-BEFORE-BUILD (placement): new script {dest}. Rule #4 is also WHERE it lives: "
            f"is this tool for one project, or for {scope} in general? ")
    if not present:
        return "block", head + (
            f"First search for an existing script to extend. If none: an {scope} tool goes in the "
            f"{_home_desc(h)} with '# build-ok: home={scope} <reason>'; a tool only one project uses "
            f"stays here with '# build-ok: home=project consumer=<what uses it> <reason>'.")
    if home is None:
        return "block", head + (
            f"Your build-ok marker doesn't say which: add home={scope} (then create it in the "
            f"{_home_desc(h)}) or home=project consumer=<what uses it>.")
    under = _expand(dest).startswith(_expand(h["path"]) + os.sep)
    if home == scope:
        if under:
            return "allow", ""
        return "block", head + (f"Marked home={scope}, but it is being created outside the "
                                f"{_home_desc(h)}. Create it there instead.")
    if home == "project":
        if under:
            return "allow", ""
        if consumer:
            return "allow", ""
        return "block", head + ("home=project needs the project-specific consumer named: "
                                "'# build-ok: home=project consumer=<what uses it> <reason>'.")
    return "block", head + f"Unknown home={home!r}; use home={scope} or home=project."


# ── Bash: mv/cp/install/ln into a scripts/ dir (the bypass around the Write check) ──
def _segments(cmd):
    return [s for s in re.split(r"&&|\|\||;|\n|\|", cmd) if s.strip()]


def bash_targets(cmd):
    """[(src, dest)] for mover commands we can parse confidently, plus a list of
    unparseable mover segments (warned, never blocked)."""
    targets, unsure = [], []
    for seg in _segments(cmd):
        try:
            argv = shlex.split(seg)
        except ValueError:
            if any(w in seg.split() for w in MOVERS):
                unsure.append(seg.strip())
            continue
        if argv[:1] == ["git"] and argv[1:2] == ["mv"]:
            argv = argv[1:]
        if not argv or argv[0] not in MOVERS:
            continue
        if any(ch in seg for ch in "$`*?{"):
            unsure.append(seg.strip())
            continue
        args = [a for a in argv[1:] if not a.startswith("-")]
        if any(a in ("-t", "--target-directory") for a in argv[1:]) or len(args) < 2:
            unsure.append(seg.strip())
            continue
        srcs, dest = args[:-1], args[-1]
        dest_is_dir = dest.endswith("/") or os.path.isdir(os.path.expanduser(dest))
        for s in srcs:
            d = os.path.join(dest, os.path.basename(s.rstrip("/"))) if dest_is_dir else dest
            targets.append((s, d))
    return targets, unsure


def check_bash(cmd, homes, read=None):
    """('allow'|'block'|'warn', message)."""
    read = read or (lambda p: open(os.path.expanduser(p), errors="replace").read())
    targets, unsure = bash_targets(cmd)
    for src, dest in targets:
        if not is_new_script(dest) or os.path.exists(os.path.expanduser(dest)):
            continue
        try:
            content = read(src)
        except Exception:
            content = ""
        verdict, msg = decide(dest, content, homes)
        if verdict == "block":
            return "block", msg + " (A mv/cp into a scripts/ dir is the same as creating the file there.)"
    if unsure:
        scripts = [u for u in unsure if "scripts" in u]
        if scripts:
            return "warn", ("check-before-build: could not parse a file move into scripts/ confidently "
                            f"({scripts[0][:120]}); placement not checked -- check rule #4 by hand.")
    return "allow", ""


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    mode = argv[0] if argv else ""
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    ti = data.get("tool_input") or {}
    homes = load_homes(os.getcwd())
    if mode == "write":
        path = ti.get("file_path", "")
        if not path or os.path.exists(path) or not is_new_script(path):
            return 0
        verdict, msg = decide(path, ti.get("content", ""), homes)
        if verdict == "block":
            print(msg, file=sys.stderr)
            return 2
        return 0
    if mode == "bash":
        verdict, msg = check_bash(ti.get("command", ""), homes)
        if verdict == "block":
            print(msg, file=sys.stderr)
            return 2
        if verdict == "warn":
            print(msg, file=sys.stderr)
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
