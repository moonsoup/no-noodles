#!/usr/bin/env python3
# build-ok: new capability, not an extension of an existing script -- Phase
# 3's "summary/promote tooling" (docs/RISK_MODEL_PLAN.md). risk_score.py
# computes one decision at a time; this aggregates the whole
# observations.jsonl log into the agreement-rate/outcome-mix summary a human
# reads before deciding whether to promote, per the plan's right-brain
# shadow-scoring pattern ("primary always ships... promotion is never
# automatic -- a human reads a summary and decides").
"""
Usage: risk_summary.py <observations.jsonl> [--promote <risk-profile.json>]

Prints a summary of the observation log: total count, primary/shadow
agreement rate, and outcome mix. Never errors on a missing or malformed log
-- a summary tool that itself crashes on messy data defeats its own purpose.

--promote is the ONLY way learning.mode ever changes (shadow-only -> live).
There is no automatic threshold or background flip anywhere in this
codebase -- promotion is always this one explicit, human-triggered action,
matching the plan's explicit rejection of an autonomously-adapting gate.
"""
import json
import sys


def load_observations(path):
    """Parses observations.jsonl into a list of dicts, one per valid line.
    A missing file or a malformed line is skipped, not fatal -- summarizing
    messy real-world data is the whole point of this tool."""
    entries = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entries.append(json.loads(line))
                except (json.JSONDecodeError, ValueError):
                    continue
    except FileNotFoundError:
        return []
    return entries


def summarize(entries):
    """{'total', 'agreement_rate', 'outcome_mix', 'tier_mix'} from a list of
    observation dicts. agreement_rate is the fraction whose primary.tier ==
    shadow.tier (None when there are zero entries -- avoid a 0/0 division)."""
    total = len(entries)
    if total == 0:
        return {"total": 0, "agreement_rate": None, "outcome_mix": {}, "tier_mix": {}}

    agree = sum(1 for e in entries if e.get("primary", {}).get("tier") == e.get("shadow", {}).get("tier"))
    outcome_mix = {}
    tier_mix = {}
    for e in entries:
        outcome = e.get("outcome", "unknown")
        outcome_mix[outcome] = outcome_mix.get(outcome, 0) + 1
        tier = e.get("primary", {}).get("tier", "unknown")
        tier_mix[tier] = tier_mix.get(tier, 0) + 1

    return {
        "total": total,
        "agreement_rate": round(100 * agree / total, 1),
        "outcome_mix": outcome_mix,
        "tier_mix": tier_mix,
    }


def print_summary(summary):
    print(f"{summary['total']} observation(s) in the log.")
    if summary["total"] == 0:
        return
    print(f"Primary/shadow agreement rate: {summary['agreement_rate']}%")
    print("Outcome mix:")
    for outcome, count in sorted(summary["outcome_mix"].items()):
        print(f"  {outcome}: {count}")
    print("Primary tier distribution:")
    for tier, count in sorted(summary["tier_mix"].items()):
        print(f"  {tier}: {count}")


def promote(profile_path):
    """The ONLY place learning.mode changes -- an explicit, human-triggered
    flip from shadow-only to live. Never called except via the --promote
    flag; never invoked automatically by risk_observe/risk_shadow_score or
    any hook."""
    try:
        with open(profile_path) as f:
            profile = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        profile = {"version": 1, "command_adjustments": {}}
    profile["mode"] = "live"
    with open(profile_path, "w") as f:
        json.dump(profile, f, indent=2)
        f.write("\n")
    print(f"risk-profile.json mode promoted: shadow-only -> live ({profile_path})")


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    if not argv:
        print("usage: risk_summary.py <observations.jsonl> [--promote <risk-profile.json>]", file=sys.stderr)
        return 2
    obs_path = argv[0]
    entries = load_observations(obs_path)
    print_summary(summarize(entries))

    if "--promote" in argv:
        idx = argv.index("--promote")
        if idx + 1 >= len(argv):
            print("usage: risk_summary.py <observations.jsonl> --promote <risk-profile.json>", file=sys.stderr)
            return 2
        promote(argv[idx + 1])
    return 0


if __name__ == "__main__":
    sys.exit(main())
