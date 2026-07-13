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
