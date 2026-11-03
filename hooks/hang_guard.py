#!/usr/bin/env python3
# build-ok: new capability (rule 5, hang guard) -- no existing hook looks at
# WHERE a command walks; no_noodle.sh matches two literal shapes and
# risk_scoring scores destructiveness, under which `du`/`find` are harmless.
"""Rule 5 -- hang guard. Decide whether a Bash command may run.

A one-off command that WALKS a directory tree (find, du, ls -R, rsync, ...) on a
hang-prone mount (FUSE, network, /Volumes external media) is held until the
caller has looked at what it costs. This guard never shortens a command: it does
not demand or recommend a timeout (owner's instruction, 2026-11-03 -- "you can't
know what will be needed for some"). It asks for one of:

  * run_in_background -- the walk gets all the time it needs and the session
    never freezes behind it; or
  * `# hang-ok: <estimate>` -- an inline, stated assessment of size/time.

Before either, the guard probes the mount itself (its own check, bounded, never
the user's command). A mount that does not answer is blocked even in the
background: touching a wedged FUSE mount puts the process in an unkillable wait,
which is how the 2026-11-02 incident froze every session sent to look at it.

Input: PreToolUse JSON on stdin. Exit 0 = allow, exit 2 = block (message on
stdout, same convention as the other no-noodles hooks).

Test seams (environment):
  NO_NOODLES_MOUNT_TABLE      file holding `mount` output to use instead of running it
  NO_NOODLES_HANG_PROBE_CMD   shell command used as the liveness probe; `{mount}`
                              is replaced by the quoted mount point
  NO_NOODLES_HANG_PROBE_SECS  probe wait, default 5
  NO_NOODLES_HANG_PATHS       extra hang-prone path prefixes, colon-separated
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time

# Userspace/network filesystems, plus the removable-media formats (an iPod, an
# SD card, a USB stick): on macOS those run through FSKit in userspace too, and
# the hardware underneath is the kind that fails.
PRONE_FSTYPES = ("fuse", "nfs", "smbfs", "afpfs", "webdav", "cifs", "sshfs", "ftp",
                 "msdos", "exfat", "ntfs")

# Commands that always walk a tree.
ALWAYS_WALK = {"find", "du", "tree", "rsync", "ditto", "rg", "fd", "tar", "zip"}
# Commands that walk only with a recursive flag.
RECURSIVE_FLAG = {
    "ls": re.compile(r"^-[A-Za-z]*R"),
    "grep": re.compile(r"^-[A-Za-z]*[rR]|^--recursive$|^--dereference-recursive$"),
    "cp": re.compile(r"^-[A-Za-z]*[rR]"),
    "scp": re.compile(r"^-[A-Za-z]*r"),
    "chmod": re.compile(r"^-[A-Za-z]*R"),
    "chown": re.compile(r"^-[A-Za-z]*R"),
    "chflags": re.compile(r"^-[A-Za-z]*R"),
    "xattr": re.compile(r"^-[A-Za-z]*r"),
}
PREFIX_WORDS = {"sudo", "time", "nice", "nohup", "command", "exec", "xargs", "env", "caffeinate",
                "timeout", "gtimeout"}
DURATION_RE = re.compile(r"^\d+(\.\d+)?[smhd]?$")

MARKER_RE = re.compile(r"#\s*hang-ok\b:?\s*(.*)$", re.MULTILINE)
MIN_ESTIMATE_CHARS = 8


def _norm(path: str) -> str:
    """Canonicalise WITHOUT touching the filesystem (realpath would stat the
    mount -- the very thing that hangs). Only the macOS /private aliases."""
    path = path.rstrip("/") or "/"
    for alias in ("/private/var", "/private/tmp", "/private/etc"):
        if path == alias or path.startswith(alias + "/"):
            return path[len("/private"):]
    return path


def read_mount_table() -> str:
    table = os.environ.get("NO_NOODLES_MOUNT_TABLE")
    if table:
        with open(table) as f:
            return f.read()
    # `mount` reads the kernel's table; it never stats a mount point.
    try:
        return subprocess.run(["/sbin/mount"], capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return ""


def prone_mounts(table: str) -> list[str]:
    out = []
    for line in table.splitlines():
        m = re.match(r"^.*? on (.*) \(([^,)]*)", line)
        if not m:
            continue
        path, fstype = m.group(1), m.group(2).lower()
        if any(t in fstype for t in PRONE_FSTYPES) or path.startswith("/Volumes/"):
            out.append(_norm(path))
    for extra in filter(None, os.environ.get("NO_NOODLES_HANG_PATHS", "").split(":")):
        out.append(_norm(os.path.expanduser(extra)))
    return out


def _strip_heredocs(cmd: str) -> str:
    lines, out, delim = cmd.split("\n"), [], None
    for line in lines:
        if delim is not None:
            if line.strip() == delim:
                delim = None
            continue
        out.append(line)
        m = re.search(r"<<-?\s*['\"]?(\w+)['\"]?", line)
        if m:
            delim = m.group(1)
    return "\n".join(out)


def _split_outside_quotes(body: str, split_pipes: bool) -> list[str]:
    """Split on ; && || newline ( ) $( and backticks -- and on | when
    split_pipes -- but never inside '...' or "...", nor on an escaped char.
    A regex split cut a multi-line `python3 -c "..."` into one 'command' per
    line (found live, 2026-11-03)."""
    parts, cur, i, quote = [], [], 0, None
    n = len(body)
    while i < n:
        c = body[i]
        if quote:
            cur.append(c)
            if c == "\\" and quote == '"' and i + 1 < n:
                cur.append(body[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            cur.append(body[i:i + 2])
            i += 2
            continue
        if c in "'\"":
            quote = c
            cur.append(c)
            i += 1
            continue
        two = body[i:i + 2]
        if two in ("&&", "||", "$("):
            parts.append("".join(cur))
            cur = []
            i += 2
            continue
        if c in ";\n()`" or (c == "|" and split_pipes):
            parts.append("".join(cur))
            cur = []
            i += 1
            continue
        if c == "|":  # a pipe that is not a split point stays inside the statement
            cur.append(c)
            i += 1
            continue
        cur.append(c)
        i += 1
    parts.append("".join(cur))
    return parts


def _statements(cmd: str, split_pipes: bool = True) -> list[list[str]]:
    """Split into simple commands (on ; && || newline and $( ), tokenised.
    With split_pipes, each pipeline stage is its own command too."""
    body = _strip_heredocs(MARKER_RE.sub("", cmd))
    parts = _split_outside_quotes(body, split_pipes)
    out = []
    for part in parts:
        try:
            toks = shlex.split(part, comments=True)
        except ValueError:
            toks = part.split()
        if toks:
            out.append(toks)
    return out


TRIVIAL_WORDS = {"echo", "printf", "cd", "pushd", "popd", "true", "false", ":", "set",
                 "export", "local", "sleep"}


def count_commands(cmd: str) -> int:
    """How many real commands a one-off line chains together (used by
    no_noodle.sh's compound-probe shape). A pipeline counts once; separators
    (echo/printf), cd, and bare assignments are not commands."""
    n = 0
    for toks in _statements(cmd, split_pipes=False):
        words = [t for t in toks if not re.match(r"^\w+=", t)]
        if words and words[0] not in TRIVIAL_WORDS:
            n += 1
    return n


def _is_walk(toks: list[str]) -> bool:
    i = 0
    # Skip assignments, wrapper words (sudo, timeout, ...), their flags, and a
    # timeout's duration -- a wrapper must never hide the walk inside it.
    while i < len(toks) and (re.match(r"^\w+=", toks[i]) or toks[i] in PREFIX_WORDS
                             or (i > 0 and toks[i - 1] in PREFIX_WORDS and toks[i].startswith("-"))
                             or (i > 0 and toks[i - 1] in ("timeout", "gtimeout")
                                 and DURATION_RE.match(toks[i]))):
        i += 1
    if i >= len(toks):
        return False
    word = os.path.basename(toks[i])
    args = toks[i + 1:]
    if word in ALWAYS_WALK:
        return True
    if word == "lsof":
        return "+D" in args
    flag = RECURSIVE_FLAG.get(word)
    return bool(flag) and any(flag.search(a) for a in args)


def _paths(cmd: str, home: str) -> list[str]:
    found = []
    # Quoted strings first, so "/Volumes/SAM'S IPOD/x" stays whole.
    for m in re.finditer(r"\"([^\"]*)\"|'([^']*)'", cmd):
        s = m.group(1) if m.group(1) is not None else m.group(2)
        if s.startswith(("/", "~", "$HOME", "${HOME}")):
            found.append(s)
    # Unquoted, allowing backslash escapes (/Volumes/SAM\'S\ IPOD/x), unescaped after.
    for m in re.finditer(r"(?:^|(?<=[\s=:(]))((?:~|\$HOME|\$\{HOME\})?/(?:\\.|[^\s'\";|&)<>\\])*)", cmd):
        found.append(re.sub(r"\\(.)", r"\1", m.group(1)))
    out = []
    for p in found:
        for pre in ("${HOME}", "$HOME", "~"):
            if p.startswith(pre):
                p = home + p[len(pre):]
                break
        if p.startswith("/"):
            out.append(_norm(p))
    return out


def _under(path: str, mount: str) -> bool:
    return path == mount or path.startswith(mount.rstrip("/") + "/")


def probe(mount: str, secs: float) -> tuple[bool, str]:
    """The guard's OWN liveness check. Never waits on a child it had to give up
    on: a process stuck on a wedged FUSE mount cannot be reaped, so it is
    abandoned in its own session rather than blocking this hook."""
    pidfile = _pidfile(mount)
    try:
        old = int(open(pidfile).read().strip())
    except (OSError, ValueError):
        old = 0
    if old and _alive(old):
        return False, (f"an earlier probe of this mount (pid {old}) is still stuck; "
                       "not starting another")
    custom = os.environ.get("NO_NOODLES_HANG_PROBE_CMD")
    if custom:
        argv = ["/bin/sh", "-c", custom.replace("{mount}", shlex.quote(mount))]
    else:
        argv = [sys.executable, "-c",
                "import os,sys;m=sys.argv[1];os.listdir(m);s=os.statvfs(m);"
                "print(s.f_files-s.f_ffree,(s.f_blocks-s.f_bfree)*s.f_frsize)", mount]
    try:
        p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             text=True, start_new_session=True)
    except OSError as e:
        return False, f"probe could not start ({e})"
    try:
        with open(pidfile, "w") as f:
            f.write(str(p.pid))
    except OSError:
        pass
    deadline = time.monotonic() + secs
    while time.monotonic() < deadline:
        if p.poll() is not None:
            try:
                os.unlink(pidfile)
            except OSError:
                pass
            out = (p.stdout.read() if p.stdout else "").split()
            if p.returncode != 0:
                return False, f"probe failed (exit {p.returncode})"
            if len(out) == 2 and all(x.isdigit() for x in out):
                files, used = int(out[0]), int(out[1])
                # FAT/exFAT have no inode table: statvfs reports 0, which is
                # "unknown", not "empty".
                count = (f"{files:,} files in use" if files else
                         "file count not reported by this filesystem (FAT/exFAT)")
                return True, f"{count}, {used / 1e9:,.1f} GB used on this filesystem"
            return True, "files in use: unknown (probe gave no statistics)"
        time.sleep(0.05)
    # Deliberately NOT killed: a probe stuck on a wedged FUSE mount cannot be
    # killed anyway, and its pidfile is what stops the next command from
    # spawning another one. If it ever finishes, probing resumes.
    return False, f"no reply within {secs:g}s"


def _pidfile(mount: str) -> str:
    d = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
                     "no-noodles", "probes")
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, hashlib.sha1(mount.encode()).hexdigest() + ".pid")


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def decide(payload: dict, cwd: str, home: str) -> tuple[int, str]:
    if payload.get("tool_name") != "Bash":
        return 0, ""
    tin = payload.get("tool_input") or {}
    cmd = tin.get("command") or ""
    if not cmd or not any(_is_walk(t) for t in _statements(cmd)):
        return 0, ""

    mounts = prone_mounts(read_mount_table())
    if not mounts:
        return 0, ""
    targets = _paths(cmd, home) or [_norm(cwd)]
    hit = sorted({m for m in mounts for t in targets if _under(t, m)}, key=len, reverse=True)
    # Also a relative walk whose cwd sits on the mount.
    hit += [m for m in mounts if _under(_norm(cwd), m) and m not in hit
            and not any(t.startswith("/") for t in _paths(cmd, home))]
    if not hit:
        return 0, ""

    marker = MARKER_RE.search(cmd)
    estimate = marker.group(1).strip() if marker else ""
    has_estimate = len(estimate) >= MIN_ESTIMATE_CHARS
    secs = float(os.environ.get("NO_NOODLES_HANG_PROBE_SECS", "5"))

    report = []
    for m in hit:
        ok, info = probe(m, secs)
        if not ok:
            if has_estimate:
                return 0, ""
            return 2, (
                f"HANG-GUARD: {m} is not answering ({info}). Anything that touches it now "
                "can freeze in an unkillable wait -- this session, and any session sent to "
                "look at it. Do not run this, in the foreground or the background. Check and "
                "recover the mount first with the fuse-mount-recovery skill "
                "(recover_fuse_ext2_mount.sh --check-only <mountpoint>). If you must proceed "
                "anyway, append '# hang-ok: <why>'."
            )
        report.append(f"  {m}: {info}")

    if tin.get("run_in_background") or has_estimate:
        return 0, ""

    why = ("A bare '# hang-ok' is not enough: state the estimate after it."
           if marker else "Look at what it costs before it runs.")
    return 2, (
        "HANG-GUARD: this one-off command walks a directory tree on a hang-prone mount "
        "(FUSE / network / external media):\n" + "\n".join(report) + "\n"
        f"{why} Steps: (1) is there already a script, skill, tool or MCP that does this? "
        "Use it. (2) Can it read the one file it needs (a log, a manifest) instead of "
        "walking? (3) Otherwise estimate how much of the tree it covers and how long that "
        "takes. Then either run it with run_in_background (it gets all the time it needs "
        "and the session is never frozen behind it), or state the estimate inline: "
        "'# hang-ok: <size, expected time, why>'. Do not cut it short to get past this "
        "guard; size it."
    )


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0
    rc, msg = decide(payload, os.getcwd(), os.path.expanduser("~"))
    if msg:
        print(msg)
    return rc


if __name__ == "__main__":
    sys.exit(main())
