---
name: no-noodle
description: The anti-noodle discipline — no ad-hoc probes, no tangents, no handing back at a green check. Invoke to re-anchor when a task risks turning into improvised riffing, or when the user says "stop noodling". Two PreToolUse hooks (~/.claude/hooks/no_noodle.sh, ~/.claude/hooks/check_before_build.sh) mechanically enforce rules #1 and #4's clearest cases; #2 and #3 are structurally not hook-enforceable (they're about intent/judgment across a turn, not a single tool call's shape) and stay on you.
---

# No-noodle

**Noodling = improvised, meandering work: ad-hoc terminal probes, side-quest tangents, and handing the turn back the moment something goes green.** It feels productive and isn't. Four rules; hooks enforce the structural slice of #1 and #4, the rest are on you.

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

## 2. Drive to done — don't hand back
Do not end a turn on a decision you can make. **Recommendations replace questions.** Stop only when (a) every acceptance criterion + quality check is green, or (b) you are *genuinely* blocked and can name the exact blocker (wall-clock/compute/external permission). "Want me to continue / do X or Y?" at a green check is a noodle. Keep going.

## 3. One thread
Finish the current task before starting a related-but-different one. A tangent that "would be quick" is how a focused build becomes a sprawl. Note the side idea, finish the thread, then decide.

## 4. Check before building
New capability belongs *inside* the existing pipeline it's part of — as a flag or function on an existing script — not as a parallel one-off file. Search for an existing script/skill/command that already does it (or can be extended) before writing anything new. A genuinely new, unrelated set of functions can get its own file, but ask first.
- The hook **blocks** creating a new script-like file under a `scripts/` directory without a `# build-ok: <reason>` marker justifying it. Don't route around it by adding the marker reflexively — actually check for an existing script to extend first; the marker is for when that check comes up empty.

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
