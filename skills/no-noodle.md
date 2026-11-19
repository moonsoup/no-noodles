---
name: no-noodle
description: The anti-noodle discipline — no ad-hoc probes, no tangents, no handing back at a green check. Invoke to re-anchor when a task risks turning into improvised riffing, or when the user says "stop noodling". Two PreToolUse hooks (~/.claude/hooks/no_noodle.sh, ~/.claude/hooks/check_before_build.sh) mechanically enforce rules #1 and #4's clearest cases; #2 and #3 are structurally not hook-enforceable (they're about intent/judgment across a turn, not a single tool call's shape) and stay on you.
---

# No-noodle

**Noodling = improvised, meandering work: ad-hoc terminal probes, side-quest tangents, and handing the turn back the moment something goes green.** It feels productive and isn't. Five rules; hooks enforce the structural slice of #1, #4 and #5, the rest are on you.

## Switching it
Two layers, both still supported:
- **Per-project or per-preference (finer-grained):** run `/noodle-options` to turn either rule
  on/off, scoped to the current project (`./.no-noodles.json`) or globally
  (`~/.claude/no-noodles.json`). Project-local always wins over global.
- **Blunt global toggle (the original `>> no-noodles` mode, unchanged):** the hook reads
  `~/.claude/no-noodle.state` / `~/.claude/check-before-build.state`:
  - **off:** `echo off > ~/.claude/no-noodle.state` — enforcement disabled.
  - **on:** `echo on > ~/.claude/no-noodle.state` (or delete the file) — enforcing (default).

(Claude Code's real shift+tab modes are internal and can't be extended, so this is the one-word equivalent.)

## 1. No ad-hoc probes — write the script
Before any Bash call, the STOP CHECK: *could this be a script?* If it touches data or is remotely repeatable → write `the-script` + `test_the_script` (test passes first), then run it. One-liners to probe a system or parse a response are waste.
- The hook counts **repeats, not shapes** (v1.0.1). A first fetch-into-parser or blob decode is
  exploration and passes; the *second* of that shape in the same project is blocked, because that
  is the moment it became a script. Don't route around it — write the script, or use a skill's
  documented command (e.g. `dogfooder-ops`).
- A failed one-liner is **not** fixed by a better one-liner — that's still a probe, aimed better. Stop and reconsider the approach.
- `# noodle-ok` on a command is the escape hatch for a *genuine* one-off only. If you're typing it twice, it's a script.
- **Compound probes count too (v1.1.0).** A one-off line chaining 4+ real commands (`;` `&&` `||`
  newline; a pipeline counts once; `echo`/`cd`/assignments don't count) is a multi-step probe —
  the shape that walked a FUSE mount and froze every session on 2026-11-02. Same repeat rule:
  the first passes, the repeat blocks. Own key: `compound_probes`.

## 2. Drive to done — don't hand back
Do not end a turn on a decision you can make. **Recommendations replace questions.** Stop only when (a) every acceptance criterion + quality check is green, or (b) you are *genuinely* blocked and can name the exact blocker (wall-clock/compute/external permission). "Want me to continue / do X or Y?" at a green check is a noodle. Keep going.

## 3. One thread
Finish the current task before starting a related-but-different one. A tangent that "would be quick" is how a focused build becomes a sprawl. Note the side idea, finish the thread, then decide.

## 4. Check before building
New capability belongs *inside* the existing pipeline it's part of — as a flag or function on an existing script — not as a parallel one-off file. Search for an existing script/skill/command that already does it (or can be extended) before writing anything new. A genuinely new, unrelated set of functions can get its own file, but ask first.
- The hook **blocks** creating a new script-like file under a `scripts/` directory without a `# build-ok: <reason>` marker justifying it. Don't route around it by adding the marker reflexively — actually check for an existing script to extend first; the marker is for when that check comes up empty.
- **Placement is part of the check (v1.2.0).** "Nothing similar here" is half the question;
  the other half is *is here the right place?* A tool for operations in general does not belong
  in whichever project repo is nearest. Where a `tool_homes` entry applies (configured in
  `no-noodles.json`, see `/noodle-options`), the marker must say which:
  - `# build-ok: home=ops <reason>` — only accepted inside that tool home, and register the
    tool in the home's script registry (the block message names both).
  - `# build-ok: home=project consumer=<what uses it> <reason>` — stays in the project; name
    the one project-specific thing that uses it.
  Moving a script into a `scripts/` dir with `mv`/`cp`/`install`/`ln`/`git mv` gets the same
  check — it's creating the file there. Real incident 2026-11-19: four operations tools with
  valid bare markers landed in three different project repos.

## 5. Size it before you run it — the hang guard
When no script, skill, tool or MCP covers what you need and you must run a one-off command,
**check it for safety first**. Ask, before it runs:
- **Where does it run?** A FUSE mount (DockProjects), a network share, or `/Volumes` media
  (an iPod, an SD card) can hang. A wedged mount puts every process that touches it into an
  unkillable wait — including each session you send to look at it.
- **How much does it touch?** `find`, `du`, `ls -R`, `rsync`, `grep -r` walk the whole tree.
  Read the one file you need (a log, a manifest) instead when you can.
- **How long will it take?** Estimate it. Then give it that time — run it in the background
  if it is long. **Never cut a command short to be safe**: an arbitrary timeout just turns a
  slow job into a failed one, and you cannot know in advance what some jobs need.
- **Can it destroy anything?** That is what `risk_scoring` scores (off by default).

The hook (`hooks/hang_guard.sh`, key `hang_guard`, on by default) enforces the first three
for tree walks on hang-prone mounts: it probes the mount (blocking outright if it doesn't
answer), reports the filesystem's scale, and passes the command only when it runs with
`run_in_background` or carries a stated estimate: `# hang-ok: <size, expected time, why>`.
A bare `# hang-ok` is still blocked; a `timeout` prefix does not satisfy it.

## When you catch yourself noodling
Name it, drop the riff, and return to the plan's next concrete step. If there's no plan, that's the tell — make one, then execute it.

## Weighted risk model — implementation record requirement
The risk-scoring feature (`hooks/lib_risk.sh`, `hooks/risk_gate.sh`, `hooks/risk-rules.json`,
`hooks/risk_score.py`, the risk-profile schema) has its own non-negotiable discipline on top of
the four rules above: **any commit touching those files must append an entry to
`IMPLEMENTATION_LOG.md` in the same commit** — what landed, which prior-art research it applied,
any deviations from the plan, and any open questions/known limitations surfaced. This is
social/skill-level, not hook-enforced (a hook can't verify prose quality, same reasoning as rules
#2/#3 above) — self-enforce it the same way.
