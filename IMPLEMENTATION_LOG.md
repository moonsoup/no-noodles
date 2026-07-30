# Implementation log — weighted risk model

Append-only, reverse-chronological. One entry per landed change touching
`hooks/lib_risk.sh`, `hooks/risk_gate.sh`, `hooks/risk-rules.json`,
`hooks/risk_score.py`, or the risk profile schema — required in the same
commit as the change, per `skills/no-noodle.md`. This exists per explicit
user requirement (2026-07-13): "keep careful records of how we implement
this through the entire process."

Full design plan: `docs/RISK_MODEL_PLAN.md` (ZTAI research, external
prior-art research including sh-guard/OPA/Falco/NIST-800-207/UEBA/GuardFall,
right-brain's shadow-scoring pattern) — this log records what actually
landed and any deviations from that plan, not the plan itself.

---

## 2026-07-15 — Phase 3: shadow scoring, observation log, session-trust grant, summary/promote

**What landed:** `risk_score.py` extended with `apply_profile_adjustment()` (an optional 4th
CLI arg, `profile.json`, wraps the existing 2-3-arg output unchanged — additive only) and
`lib_risk.sh`'s new `risk_shadow_score` wrapper; `hooks/lib_observe.sh` (`risk_observe` — logs
`{ts, command_signature (sha256, NOT the raw command), context, primary, shadow, outcome}` to
`$CLAUDE_DIR/no-noodles/observations.jsonl`, rotated at a configurable line-count bound,
wrapped fail-open in a subshell so nothing it does can ever fail the calling hook); one
additive `risk_observe` line each in `no_noodle.sh` and `check_before_build.sh` (both existing
rule test suites confirmed byte-for-byte unchanged — same pass count, same checks); `hooks/
grant_session_trust.sh` (grant/revoke/status for the session-trust file risk_gate.sh's
Danger/Critical tiers check for — without this Phase 3 piece those tiers would be permanently
unreachable, the exact hard-lockout the plan's Decision section explicitly rejected);
`hooks/risk_summary.py` (agreement-rate + outcome-mix + tier-distribution summary from
observations.jsonl, plus `--promote <profile>` — the ONLY place `learning.mode` ever flips
shadow-only -> live, always an explicit human-triggered action, never automatic).

**Real scope decision, not fully specified in the plan**: the plan names `risk_maybe_retrain`
and "learned weights" but never specifies the actual learning algorithm. Rather than invent an
untested weight-computation scheme under time pressure — which would be exactly the kind of
un-disciplined engineering the plan's own "shadow-only, human decides, never autonomous"
philosophy argues against — this phase ships the full observation/summary/promote *mechanism*
with an honest, documented default: `command_adjustments` defaults to an empty map (multiplier
1.0 everywhere), so shadow == primary until someone deliberately writes a real adjustment into
risk-profile.json. The actual weight-learning algorithm (how `command_adjustments` values get
computed from accumulated observations) is real remaining scope, not silently implied done.

**Real decision on data retention**: `install.sh --uninstall` was extended to remove the new
hook files but was deliberately NOT extended to delete `$CLAUDE_DIR/no-noodles/` (observations.
jsonl, risk-profile.json, session-trust) — that directory holds accumulated training data +
audit trail per the plan, not disposable on/off-toggle state like the `.state` files uninstall
already removes. Test added (`test_install.sh`) confirming this explicitly.

**Deferred, explicitly out of scope this phase**: the actual `command_adjustments`
weight-learning algorithm; risk_gate.sh's own decisions are not yet observation-logged (only
rule 1/4 per the plan's stated Phase 3 scope — risk_gate.sh already computes both scores
internally, so wiring it in later is a small addition, not a redesign); an MCP/dogfooder
integration (Phase 4, not started — needs the dogfooder runner's actual internals read first,
per the plan's own explicit caution against assuming that shape).

---

## 2026-07-15 — Phase 2: risk_gate.sh wired in, GuardFall bypass tests, OFF by default

**What landed:** `hooks/risk_gate.sh` (new PreToolUse hook, tiered-confirmation gate per the
plan's Decision section — Safe auto-allows, Caution needs `# risk-ok`, Danger needs marker +
an active `$CLAUDE_DIR/no-noodles/session-trust` file, Critical needs marker + trust +
`NO_NOODLES_RISK_CRITICAL_OVERRIDE=1`), wired into `install.sh` (copy/register/uninstall for
risk_gate.sh + lib_risk.sh + risk_score.py + risk-rules.json), `hooks/lib_config.sh` extended
with an optional 3rd `default` arg to `resolve_state` (existing 2-arg callers unchanged),
`skills/noodle-options.md` updated, `tests/test_risk_gate.sh` (17 checks incl. GuardFall-class
obfuscation: nested `bash -c`, `eval`-wrapped pipelines — scoring runs against the real command
text, not defeated by a shell wrapper).

**Real decision this session, confirmed with the user**: risk_gate.sh ships **off by default**
(`resolve_state risk_scoring "$STATE" off`), unlike `no_ad_hoc_probes`/`check_before_build`
(on by default). Rationale: this scores EVERY Bash command via a weighted model, a much
broader surface than the other two rules' one narrow literal pattern each — an untested new
rule at that surface area risked broadly blocking real work on day one. Opt in via
`/noodle-options` or the same JSON config layer as every other rule.

**Real bug found and fixed while writing tests**: `risk_gate.sh`'s first draft called
`risk_score "$CMD"` with no target_path, so `dd if=/dev/zero of=/dev/disk4` never reached
Critical tier (context multiplier defaulted to "project" instead of "root") — added a
best-effort target-path extraction (`grep -oE` for the last path-like substring in the command,
handling `of=/dev/x`-style embedded paths, not just leading tokens) so the gate actually sees
what `lib_risk.sh`'s scoring model was designed to use.

**Known limitation, not a bug**: `base64 -d` alone scores exactly 20 (risk-rules.json's
Safe/Caution boundary) — too low on its own to trigger Caution. This is a Phase 1 seed-rule
weighting question, out of scope for Phase 2 (wiring, not re-tuning weights); a GuardFall test
originally written against this case was corrected to use a properly-demonstrative example
(`eval`-wrapped `curl|bash`, which does score well above Safe) instead of asserting behavior
the current weights don't support.

**Deferred to Phase 3** (per the plan's own phasing, confirmed with the user before starting):
the session-trust file's actual *creation* mechanism (risk_gate.sh only checks for its
presence), risk_observe/risk_shadow_score, the observation log, and summary/promote tooling.

---

## 2026-07-13 — Phase 1: static scoring engine, no learning, not wired in yet

**What landed:** `hooks/risk-rules.json` (seed rule table), `hooks/risk_score.py`
(scoring engine), `hooks/lib_risk.sh` (bash wrapper, `risk_score` function),
`tests/test_lib_risk.sh` (22 checks). Not sourced by any hook and not
registered in `install.sh` yet — pure library, exercised only by its own tests.

**Design decisions made / research applied:**
- Score formula (intent × context multiplier + flag penalties + fileset
  sensitivity bonus) adapted from sh-guard's intent×context×flag-penalty
  shape and Falco's weighted-priority convention (see plan §2).
- Tier boundaries (Safe 0-20 / Caution 21-50 / Danger 51-80 / Critical
  81-100) kept identical to sh-guard's published scale rather than inventing
  a new one, per the plan's explicit reasoning.
- `risk_category` field values are inspired by ZTAI's Red Teaming taxonomy
  vocabulary (e.g. "Blast Radius", "Supply Chain") as plain strings only —
  the field is named `risk_category`, not ZTAI's `csa_category`/
  `csa_reference`, and nothing in this codebase imports or depends on any
  ZTAI file, per the plan's explicit no-coupling boundary.
- 22 seed rules re-authored fresh for no-noodles' own scope (not copied from
  sh-guard's 157-rule set, whose license/attribution on rule *content* is
  unconfirmed) — covers rm/dd/mkfs/diskutil (delete), git force-push/reset
  --hard/clean (write), curl|sh/base64 -d (execute), sudo/chmod 777/chown -R
  (privilege), credential-file reads, netcat listeners, package-publish
  commands, crontab -r, firewall flush, shutdown/reboot.

**Deviations from plan:** the plan's §2 formula sketch used
`intent_weight(pattern.intent)` as the base multiplicand; implementing it
literally meant every rule sharing an intent (e.g. all six "privilege"-intent
rules) scored identically regardless of actual severity — `sudo ls` and
`kill -9 1` are both "privilege" but very different risks. Fixed to use
each rule's own `base_score` field instead (already present in the schema,
just unused by the formula as first drafted) — `intent_weights` stays in
`risk-rules.json` as a taxonomy reference, not a scoring input. This is a
strict improvement in expressiveness, not a scope change.

**Open questions / known limitations surfaced:**
- **Only the first matching rule counts.** `sudo rm -rf /` scores identically
  to plain `rm -rf /` — the separate sudo/privilege rule never gets a chance
  to add its own signal once the delete rule has already matched.
  Multi-rule combination (summing or taking the max across all matching
  rules) is a real improvement candidate but explicitly deferred — not
  attempted this phase to keep Phase 1 scoped to "does the basic engine work
  correctly," not "is the engine maximally accurate."
- **No discovery mechanism.** Nothing in Phase 1 proactively enumerates what
  commands/tools exist on this system (the kind of `command -v` sweep ZTAI's
  `zt_setup.sh` does). The seed table is static and hand-authored; the only
  planned mechanism for learning what's *actually used* on this system is
  Phase 3's observation log, which is reactive (built from real command
  invocations over time), not a proactive upfront scan. Confirmed with the
  user (2026-07-13) that this is intentional for now — proceeding
  reactive-only per the original plan, not adding a discovery sweep.
- GuardFall's shell-obfuscation bypass techniques (nested `$()` substitution,
  encoding, whitespace tricks) are **not yet tested** — this is intentional
  per the plan's own phasing (§7 / Phase 2 note: "this is where scoring
  first runs against real command shapes"), not an oversight. Phase 1 is a
  pure library with no hook wiring yet, so there's no real command shape to
  defend against — those tests land in Phase 2 alongside `risk_gate.sh`.

## 2026-07-29 — install.sh: the skill docs were installed somewhere Claude Code never loads

**What landed.** `install.sh` now also copies `no-noodle.md` and `noodle-options.md` into
`$CLAUDE_DIR/commands/`, creates that directory, and removes both on `--uninstall`. The existing
`$CLAUDE_DIR/skills/*.md` copies are untouched — this is purely additive, so anything reading the
old layout keeps working.

**The defect, found empirically.** A flat `.md` directly under `$CLAUDE_DIR/skills/` is written to
disk but **not registered** by Claude Code: `/no-noodle` returned "Unknown skill" and neither doc
appeared in the session's skill list, in *both* config dirs, for weeks. What does register at user
level is `$CLAUDE_DIR/commands/<name>.md` — proven against `commands/drive-status.md`, which is
invocable on this machine. Confirmed fixed in-session: after re-running the installer, both
`no-noodle` and `noodle-options` appeared as loadable skills and `/no-noodle` returned its content.

**Why it mattered more than a missing file usually would.** The two PreToolUse hooks were working
correctly the entire time. So noodling was being *blocked* while the document explaining what to do
instead was unreachable by the agent being corrected. Enforcement without the explanation is exactly
how a discipline degrades into decoration — which is how the owner described it before we looked.

The skill text has always said "run `/noodle-options`", so a command was the intended shape from the
start; the installer simply wrote to an inert path.

**Prior art applied.** None external — this was a format/layout mismatch established by differential
observation on this machine (which paths register vs. which don't), not a design question.

**Deviations.** None from any plan; this was an unplanned defect fix.

**Open questions / known limitations.**
- The `skills/<stem>/SKILL.md` *directory* form is proven for PROJECT-level skills
  (`<repo>/.claude/skills/<name>/`) but **unverified at user level**. It is still listed as an
  accepted shape by consumers of this package; do not treat it as proven without checking in a fresh
  session.
- Registration only refreshes at session start, so an installer run cannot self-verify invocability
  within the same session — it can only verify the files landed.
- A downstream checker (`projectMan/scripts/provision_session_skills.py`) had the mirror-image bug:
  it accepted the flat `skills/*.md` as proof of presence, so it reported no-noodle installed for
  weeks while no session could invoke it. Fixed there in the same sitting; that checker now requires
  an invocable location and also provisions local Docker containers, not just remote ones.

## 2026-07-29 — 1.0.0: the package now declares and stamps a version

**What landed.** A `VERSION` file (single source of truth, bare semver), read by `install.sh` and
stamped into each target at `$CLAUDE_CONFIG_DIR/no-noodles/VERSION`. The install summary now prints
the version, `--uninstall` removes the stamp, and the README states it. Tagged `v1.0.0` with a GitHub
release.

**Why a version now, and why it isn't cosmetic.** There was no version marker of any kind before
this: no `VERSION`, no tags, no releases. In the same sitting, this machine was found running two
DIFFERENT builds of `no-noodle.md` — `~/.claude` had 3379 bytes, `~/.claude-ies` had 4383 — and the
only reason anyone noticed was reading an `ls -la` byte count by eye. The package now installs onto
Docker containers as well (local and remote, via projectMan's `provision_session_skills.py`), so
drift between installs is the normal case to detect rather than an edge case. A stamp makes "which
build is in there?" answerable mechanically, which is a precondition for the downstream checker
verifying a *version* rather than mere presence.

**Why 1.0.0 specifically.** The hard-enforcement core is in daily use and now genuinely reachable:
both PreToolUse hooks wired and firing in two config dirs, and the skill docs invocable as of
`ff16903` (they were installed to an inert path before). Uninstall is clean and tested. Nine test
suites pass. That is a stable, usable surface worth a 1.0 boundary.

**Prior art applied.** None external; conventional `VERSION`-file layout for a shell package.

**Deviations.** None.

**Open questions / known limitations (unchanged by this release, restated so 1.0 is not read as
"finished").**
- GuardFall-style shell-obfuscation bypasses (nested `$()`, encoding, whitespace tricks) are still
  **not tested** — intentional per the risk model's own phasing, not an oversight.
- The `skills/<stem>/SKILL.md` *directory* form remains unverified at user level; only
  `commands/<name>.md` is proven invocable there.
- Nothing yet *compares* the installed stamp against the package version — the stamp is written and
  removed correctly, but drift detection is left to the consumer (projectMan's
  `provision_session_skills.py` currently checks presence and invocability, not version).

## 2026-07-30 — 1.0.1: rule 1 counts repeats, not shapes

**What landed.** `no_noodle.sh` now allows the FIRST use of a guarded shape in a project and blocks
the second. Counts are kept per (shape, project) under
`$CLAUDE_CONFIG_DIR/no-noodles/shapes/`. The block message states how many times the shape has been
seen and surfaces `# noodle-ok` at the moment it fires.

**Why.** The rule's own criterion has always been repetition — *"if you're typing it twice, it's a
script"* — but the hook enforced on shape, so a single exploratory research probe was taxed exactly
as hard as the eighth repeat. The owner raised it directly: is this too restrictive to produce
non-code output? The honest answer was that the axis is not code-vs-prose but *does the output make
a claim about data*, and that the friction was real: in one session an agent ran eight ad-hoc `ssh`
probes and routed around the guard rather than using its escape hatch. Frequency enforcement removes
the tax on exploration while catching the exact failure the rule cares about, at the moment it
occurs.

**Evidence it works, including on its author.** While implementing this, the hook blocked three of my
own commands — each contained guarded literals as *text* (writing tests and docs *about* the
patterns). That is a real property worth stating: the hook matches command text, so writing about a
pattern can trip it. `# noodle-ok` is the correct response and was used, which is also the first time
this session the escape hatch got used as designed rather than routed around.

**Deviations.** Three pre-existing test assertions expected the FIRST use to be blocked. They were
updated, not deleted, with the reason recorded inline — a deliberate contract change, not a test
weakened for green. The shapes are still caught; the block moved to the repeat.

**Also fixed.** The hook tests were not hermetic: they wrote counts into the developer's real
`CLAUDE_CONFIG_DIR`, so they passed or failed depending on what that person had run earlier. They now
own a temp config dir.

**Docs fact-checked against the code.** Three surfaces claimed the hook "blocks … outright" — the
skill doc, the README (twice) and the landing page. All corrected. Every other page claim was
verified against the source: the guarded regex, the `# build-ok: <reason>` marker, idempotent
registration, and project-local-beats-global resolution all check out as written.

**Open.** The text-matching property above means a command *mentioning* a guarded pattern is treated
as using it. Acceptable today, and `# noodle-ok` covers it, but a future version could look at the
parsed command rather than the raw string.
