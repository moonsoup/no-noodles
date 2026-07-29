---
name: noodle-options
description: Configure no-noodles enforcement (rule 1 ad-hoc-probe blocking, rule 4 check-before-build, the weighted risk gate) per-project or globally, per individual preference. Invoke as `/noodle-options`.
---

# noodle-options

Lets the user tune no-noodles enforcement instead of it being one global on/off switch. Three
independent rules (`no_ad_hoc_probes`, `check_before_build`, `risk_scoring`), two independent
scopes (this project only, or the global default), on or off.

`risk_scoring` (docs/RISK_MODEL_PLAN.md) is a much broader surface than the other two rules —
it scores EVERY Bash command via a weighted model instead of one narrow literal pattern, and
defaults to **off** (the other two default on). Explain that difference if a user asks to turn
it on: it enforces a tiered-confirmation gate (Safe auto-allows; Caution needs an inline
`# risk-ok` marker; Danger needs that marker AND an active session-trust file; Critical needs
marker + trust + a distinct env var) rather than a binary block.

## Resolution order (how the hooks actually decide, via `hooks/lib_config.sh`)

1. Project-local `./.no-noodles.json` in the current working directory — wins over everything.
2. Global `$CLAUDE_CONFIG_DIR/no-noodles.json` (`~/.claude/no-noodles.json` by default).
3. Legacy per-rule state file (`~/.claude/no-noodle.state`, `~/.claude/check-before-build.state`)
   — the original all-or-nothing toggle, still honored, never removed.
4. Default: on for `no_ad_hoc_probes`/`check_before_build`; **off** for `risk_scoring`.

## What to do when invoked

1. Read current state before asking anything:
   - `./.no-noodles.json` (project-local, if present)
   - `$CLAUDE_CONFIG_DIR/no-noodles.json` or `~/.claude/no-noodles.json` (global, if present)
   - The two legacy `.state` files, if the JSON configs don't already cover a rule
2. Summarize the current effective state for both rules in one or two lines before asking
   anything — the user may just want to know, not change anything.
3. Ask (AskUserQuestion) what to change: which rule(s) (`no_ad_hoc_probes`, `check_before_build`,
   or both), which scope (this project / global), and the new value (on/off). Don't assume —
   a user who says "turn off noodle checks here" means project-local + both rules; a user who
   says "I always want check-before-build off" means global + that one rule.
4. Write only the keys that changed, preserving any other existing keys already in that JSON
   file (read-modify-write, not overwrite). Create the file if it doesn't exist yet:
   ```json
   { "no_ad_hoc_probes": "on", "check_before_build": "off" }
   ```
5. Confirm exactly what changed and where (file path + scope), and remind the user that
   project-local always wins over global if both are set — so a global "off" won't silently
   un-suppress a project that explicitly turned a rule back on locally, or vice versa.

## Notes

- This only ever writes JSON config files — never touches the legacy `.state` files. A user who
  still wants the blunt global toggle can keep using `echo off > ~/.claude/no-noodle.state`
  exactly as before; nothing here removes that path.
- If asked to reset to defaults, offer to delete the specific keys (or the whole file if it's
  now empty) rather than writing `"on"` explicitly everywhere — an empty/absent config is the
  cleanest "just use the default" state, and it now falls back to project-local's fallthrough
  behavior for any keys another scope still wants to set.
