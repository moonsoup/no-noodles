# no-noodles

**v1.0.0** — the version in `VERSION` is the single source of truth, and `install.sh` stamps it into each config dir at `$CLAUDE_CONFIG_DIR/no-noodles/VERSION` so you can tell which build a given host or container is actually running.

Anti-noodle discipline for [Claude Code](https://claude.com/claude-code), enforced two ways: **hard** (PreToolUse hooks that mechanically block specific tool-call shapes) and **soft** (a skill doc for the parts that require judgment, not pattern-matching).

> **Installing puts the docs in two places on purpose.** `$CLAUDE_CONFIG_DIR/commands/` is what makes `/no-noodle` and `/noodle-options` **invocable**; a flat `.md` under `skills/` lands on disk but is never loaded by Claude Code. Getting that wrong is not a small bug — it leaves the hooks blocking work while the document explaining what to do instead cannot be opened by the agent being corrected. See `IMPLEMENTATION_LOG.md` (2026-07-29).

## The problem

**Noodling = improvised, meandering work:** ad-hoc terminal probes instead of scripts, side-quest tangents instead of finishing the thread, handing the turn back the moment something goes green instead of driving to done, writing a new one-off file instead of extending the pipeline that already does 90% of the job. It feels productive in the moment. It isn't — it's how a codebase accumulates untracked, unreviewable, un-rerunnable one-offs, and how a single session sprawls into a dozen half-finished threads.

Four rules. Two of them are checkable from a single tool call's *shape* — those get hard-blocked. Two require understanding *intent* across a whole turn — those stay documented discipline, because a shell script can't reliably tell a genuine blocker from a lazy handback, or a real tangent from a legitimate next step.

## What's enforced, and how

| Rule | Enforcement | Why |
|---|---|---|
| **1. No ad-hoc probes** | Hard — `hooks/no_noodle.sh` | `curl\|wget` piped into a parser, or `base64 -d`, is unambiguous tool-shape: block it, make the case for a script instead. |
| **2. Drive to done, don't hand back** | Soft — skill doc only | Detecting "handed back on a decision it could've made" requires reading the assistant's own closing text and knowing whether a stated blocker is real. Not a tool-call pattern; a hard block here would misfire on genuine "I'm stuck" moments. |
| **3. One thread at a time** | Soft — skill doc only | "Is this a continuation or a tangent" needs the conversation's intent, not a single call in isolation. |
| **4. Check before building** | Hard — `hooks/check_before_build.sh` | Creating a *new* script file under a `scripts/` directory is unambiguous tool-shape too: block it unless justified, make the case for extending an existing pipeline instead. |

### Rule 1 — `no_noodle.sh`
Blocks (exit 2) any `Bash` tool call matching:
- `curl` or `wget` piped into `python`/`python3`/`jq`/`node`/`perl`/`ruby`
- `base64 -d` / `base64 --decode` / `base64 -D`

Escape hatch for a genuinely justified one-off: append `# noodle-ok` to the command.

### Rule 4 — `check_before_build.sh`
Blocks (exit 2) any `Write` tool call that **creates** (not overwrites) a script-like file (`.py .sh .js .ts .rb`) inside a `scripts/` directory. New capability is presumed to belong *inside* whatever existing script already does the adjacent work — as a new flag or function — not as a parallel one-off file sitting next to it.

Escape hatch for a genuinely new, unrelated capability: include `# build-ok: <reason>` (or `// build-ok: <reason>`) anywhere in the new file's content.

Both hooks exempt themselves automatically for non-matching tool calls and for test files (`test_*.py`, `*_test.py`, `*.test.js`, `*.test.ts`), so pairing a justified new script with its test doesn't require the marker twice.

## Install

```bash
git clone https://github.com/moonsoup/no-noodles.git
cd no-noodles
./install.sh
```

This copies both hooks and the skill doc into `~/.claude/` (or `$CLAUDE_CONFIG_DIR` if set) and registers both hooks under `settings.json`'s `PreToolUse` list. Safe to re-run — registration is idempotent, won't duplicate entries.

```bash
./install.sh --uninstall   # removes the copied files and hook registrations
```

## Configure

**Per-project or per-preference (finer-grained):** run the `/noodle-options` skill in Claude
Code. It asks which rule(s), which scope (this project only, or your global default), and
on/off, then writes `./.no-noodles.json` (project-local) or `~/.claude/no-noodles.json`
(global) accordingly:

```json
{ "no_ad_hoc_probes": "on", "check_before_build": "off" }
```

Resolution order (first match wins): project-local JSON → global JSON → legacy state file →
default on. Project-local always overrides global, so one project can opt out of a rule you've
otherwise turned on everywhere else, or vice versa.

**Blunt global toggle (unchanged):** each hook still reads its own state file too — on by
default, independently switchable:

```bash
echo off > ~/.claude/no-noodle.state             # disable rule 1's hook
echo off > ~/.claude/check-before-build.state    # disable rule 4's hook
# delete the file, or `echo on > <file>`, to re-enable
```

## Test

```bash
./tests/test_no_noodle.sh
./tests/test_check_before_build.sh
./tests/test_lib_config.sh
./tests/test_install.sh
```

These run the real hook scripts against synthetic JSON on stdin — the same shape Claude Code sends a PreToolUse hook — so nothing real is ever touched or executed.

## Files

```
hooks/
  no_noodle.sh           # rule 1 enforcement
  check_before_build.sh  # rule 4 enforcement
  lib_config.sh           # shared per-project/global config resolution
  lib_risk.sh             # weighted risk model: static scoring (Phase 1, not yet wired into a hook)
  risk_score.py           # the actual scoring engine lib_risk.sh wraps
  risk-rules.json         # seed rule table for the risk model
skills/
  no-noodle.md           # the full four-rule doc, invoked by name or when told "stop noodling"
  noodle-options.md      # /noodle-options -- configure per-project or global preference
tests/
  test_no_noodle.sh
  test_check_before_build.sh
  test_lib_config.sh
  test_install.sh
  test_lib_risk.sh
IMPLEMENTATION_LOG.md    # append-only build record for the risk model (required per commit)
install.sh
```

## License

MIT
