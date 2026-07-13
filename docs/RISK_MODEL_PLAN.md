# Weighted risk model — design plan

This is the durable, in-repo copy of the design plan for the weighted risk model feature. It
exists here (not only in the originating Claude Code session's plan file) specifically so any
future session or agent working in a fresh checkout of this repo — including one spawned
autonomously by projectMan's dogfooder — has the full design context without depending on a
file outside this repository. See `IMPLEMENTATION_LOG.md` for the running record of what has
actually landed against this plan; this file is the design, not the log.

## Context

`no-noodles` currently enforces two binary rules via PreToolUse hooks: block ad-hoc data-probe
commands, block unjustified new script files. Enforcement is on/off only.

The goal: grow this into a **weighted risk model** that learns the specific system it runs on —
which commands/tools are available, what risk each carries (including specific flags/options),
and which filesets are risky — adapting that understanding over time and persisting it as a
saved profile. Instead of a binary block, risky operations get flagged with a weight and the
user can override. The model also draws on architecture/vocabulary (not code) from ZTAI, an
internal Cloud Security Alliance Zero Trust project, without ever depending on ZTAI's files.

Non-negotiable process requirements: research existing software/weight-sets before building
(done — see below); keep careful records of the implementation process throughout (this file +
`IMPLEMENTATION_LOG.md`); add to the dogfooder once built (registration in progress).

## Research summary (full detail in the session that produced this plan; key findings only here)

- **sh-guard** (github.com/aryanbhosale/sh-guard): closest existing analog. 0-100 score, 4 tiers
  (Safe 0-20 / Caution 21-50 / Danger 51-80 / Critical 81-100). Score = intent × context ×
  flag-penalties. No adaptive/learning component — that gap is what this feature fills. Used as
  the seed for the tier scale and scoring *shape*, re-authored fresh (not its rule content).
- **OPA/Rego**: policy-evaluation engine precedent — structured decision output + built-in
  decision logs (audit trail), staged warn→enforce rollout pattern.
- **Falco/Wazuh**: numeric-scale + named-tier + threshold-action conventions.
- **NIST SP 800-207 (Zero Trust Architecture)**: Policy Engine/Administrator/Enforcement-Point
  separation; thresholds that vary by resource sensitivity (maps to fileset sensitivity here).
- **UEBA**: baseline-over-a-window → deviation scoring → step-up friction (not hard block) shape
  for adaptive learning.
- **GuardFall research (Adversa AI)**: 10/11 tested open-source AI coding agents have no or
  bypassable command guards — confirms static blocklists alone are insufficient; whatever ships
  must be tested against shell obfuscation (nested `$()`, encoding), not just literal strings.
- **ZTAI** (`/Users/isme/work/CSA/Software/ZTAI`, CSA-internal, never imported/depended on here):
  no risk-scoring algorithm exists there to port. What transferred: the NONE→YELLOW→ORANGE→RED
  gate-tier *concept* and its 12-category threat-taxonomy *vocabulary* (reused as plain strings
  under a no-noodles-owned field name, `risk_category`, never ZTAI's own field names).
- **right-brain** (`projectMan/packages/core/src/{brain,brainMonitor,brainRefine,brainExport}.ts`
  — a real, working pipeline in this user's own ecosystem, for a different purpose but the same
  shape): a "shadow model watches the primary decision" pattern — primary always ships, shadow
  runs on the same input purely to be logged/graded, never influences what ships, fails open on
  error. Promotion from shadow to primary is **never automatic** — a human reads an agreement-rate
  summary and decides. This directly replaced an earlier, weaker EMA/confidence-ratio design for
  this feature's learning loop (see §Learning loop below).

## Decision: override model follows ZTAI's tiered-confirmation gate, not a binary block

A binary "some tiers overridable, Critical cannot" design was considered and rejected — it would
lock the system's operator out of their own machine at the top tier, which conflicts with the
operator's standing preference to retain final say. Adopted instead: every risk tier remains
reachable, but requires an escalating number of independent confirmation signals matching its
severity:

| Score tier | Gate level | Confirmations | Mechanized as |
|---|---|---|---|
| Safe (0-20) | NONE | 0 | auto-allow |
| Caution (21-50) | YELLOW | 1 | inline marker (`# noodle-ok`-style) present |
| Danger (51-80) | ORANGE | 2 | marker **and** a session-trust file active |
| Critical (81-100) | RED | 3 | marker **and** session-trust **and** an explicit env var, distinct from the easy marker |

Every override (any tier) is logged as an override — this is the training signal for the
learning loop, not a bypass that vanishes.

## Scoring model (`hooks/lib_risk.sh` / `hooks/risk_score.py` / `hooks/risk-rules.json`)

```
base_score = matched_rule.base_score          # each rule's OWN severity, not a shared per-intent weight
           * context_multiplier(target_path)   # project 1.0 / home 1.3 / system 1.8 / root 2.5
           + sum(flag_penalties matched)        # e.g. -rf, --force, --no-verify, -y/--yes
           + fileset_sensitivity_bonus(target_path)  # +15 high-sensitivity path, +5 medium
```
Tiers: Safe 0-20 / Caution 21-50 / Danger 51-80 / Critical 81-100 (sh-guard's published scale).
Rules carry `{pattern, intent, base_score, risk_category, reason}` — `risk_category` values are
inspired by ZTAI's taxonomy vocabulary as plain strings, never sourced from ZTAI's files.

**Known limitation (Phase 1):** only the first matching rule counts — `sudo rm -rf /` scores
identically to plain `rm -rf /`, since the separate sudo/privilege rule never gets evaluated once
the delete rule has already matched. Multi-rule combination is a real improvement candidate,
deliberately deferred to keep Phase 1 scoped to "does the engine work correctly."

## Learning loop (right-brain's shadow-scoring pattern)

Every scored decision is logged (`observations.jsonl`, `BrainLogEntry`-shaped): `{ts,
command_signature, context, primary: {score, tier}, shadow: {score, tier} | error, outcome}`.
`primary` is always the static seed-rule score — this is what actually gates the decision,
forever. `shadow` is the same formula with a learned `profile_adjustment()` applied from
`risk-profile.json`; it runs once the profile has data, is graded against `primary`, and **never
influences what ships**. A shadow computation error is caught and logged, never surfaced.

`risk-profile.json`'s `learning.mode` (`"shadow-only"` / `"live"`) only ever changes via a
deliberate user action — reading an agreement-rate/outcome-mix summary and choosing to promote —
never a background threshold-flip. This is the main functional deliverable of the phase that
implements it: the shadow scorer, its logging, and the summary/promote tooling, not an
autonomously-adapting gate.

## Profile storage

- `$CLAUDE_DIR/no-noodles/risk-profile.json` — the learned/adaptive profile (versioned, `mode`
  field, per-command learned weights, per-fileset sensitivity).
- `$CLAUDE_DIR/no-noodles/observations.jsonl` — append-only decision log (training data + audit
  trail), rotated at a line-count bound.
- `./.no-noodles-risk.json` (project-local, optional) — per-project fileset sensitivity overrides
  only, not full learned profiles (those stay user/system-scoped).

## Phasing

- **Phase 1 — DONE.** Static scoring engine (`hooks/lib_risk.sh`, `hooks/risk_score.py`,
  `hooks/risk-rules.json`), 22 seed rules, 22 tests. Not wired into any hook or `install.sh` yet.
- **Phase 2 — Wire into a new `risk_gate.sh` hook + observation logging (no adaptation yet).**
  `install.sh` updated (copy/register/uninstall for the new hook + `risk-rules.json`);
  `lib_config.sh` gets a `risk_scoring` key through the *same* existing resolution chain;
  `skills/noodle-options.md` updated. Profile files start accumulating; `learning.mode` stays
  hardcoded `"shadow-only"`. GuardFall bypass tests (nested `$()`, encoding, whitespace
  obfuscation) land here — this is where scoring first runs against real command shapes. The
  ZTAI tiered-gate mechanization (YELLOW/ORANGE/RED confirmation-signal checks) is implemented
  here too.
- **Phase 3 — Shadow scoring + summary/promote tooling + rule 1/4 observation hooks.**
  `risk_shadow_score`, `risk_maybe_retrain`, a `brainMonitor.ts`-equivalent summary (agreement
  rate, outcome mix) for the user to read and decide on promotion — no automatic threshold-flip.
  One-line `risk_observe` added to `no_noodle.sh` and `check_before_build.sh` (wrapped fail-open).
  Session-trust file added here.
- **Phase 4 — Dogfooder + MCP wiring.** Starts with reading the dogfooder runner's actual
  task-registration internals before writing integration code — not assumed here. User has also
  asked for an MCP server exposing install/status/config tools for this feature, callable by the
  dogfooder or any MCP-capable client (cf. this user's existing `agent-mash`/`promo-agent`
  fastapi-mcp servers for the pattern to follow) — needs its own scoping pass once the dogfooder
  internals are actually read.

## Constraints that must not break, at any phase

- Rule 1 (`no_noodle.sh`) and rule 4 (`check_before_build.sh`) keep working byte-for-byte as
  documented through Phase 2; Phase 3's only change to them is one additive, wrapped-fail-open
  observation line each.
- `lib_config.sh`'s resolution order (project-local → global → legacy `.state` file → default)
  is extended with new keys, never replaced.
- `install.sh`'s copy/register/uninstall pattern is followed exactly for any new hook/data file.
- All new tests follow the existing hand-rolled bash `check()`/`FAILS`/`mktemp -d`/`trap cleanup`
  shape — see `tests/test_lib_config.sh` and `tests/test_lib_risk.sh` for the pattern.
- Every commit touching risk-model files gets an `IMPLEMENTATION_LOG.md` entry in the same
  commit — see that file's own header for the required format.
