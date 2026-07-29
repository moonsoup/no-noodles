#!/usr/bin/env python3
"""Static risk-scoring engine for no-noodles' weighted risk model (Phase 1).

Pure scoring logic, no side effects, no learning yet -- this is the "primary"
scorer from the plan's shadow-scoring design (right-brain pattern): it always
computes the same way from risk-rules.json, with no adaptive adjustment. A
later phase adds a "shadow" scorer that layers a learned profile on top of
this WITHOUT ever changing what this module returns.

Score formula (see plan's design doc for the prior-art it's adapted from --
sh-guard's intent x context x flag-penalty shape, Falco's weighted-priority
convention). Each rule carries its own base_score (a specific pattern's
severity), not a shared per-intent weight, so two rules of the same intent
(e.g. "privilege") can still score very differently:

    base_score = matched_rule.base_score
               * context_multiplier(target_path)
               + sum(flag_penalties matched)
               + fileset_sensitivity_bonus(target_path)

Re-authored fresh for no-noodles' own scope -- not copied from any external
project's rule content. See risk-rules.json's header comment / the plan doc
for the explicit no-ZTAI-file-dependency boundary this also respects.
"""
import json
import re
import sys


def load_rules(path):
    with open(path) as f:
        return json.load(f)


def classify_context(target_path, rules):
    """Which context_multipliers bucket a target path falls into. Defaults to
    'project' (the least-privileged assumption) when no path is given or it
    doesn't match a more specific bucket."""
    if not target_path:
        return "project"
    p = target_path
    if p.startswith("/etc") or p.startswith("/usr") or p.startswith("/System") or p.startswith("/var"):
        return "system"
    if p.startswith("/dev") or p == "/" or (len(p) <= 3 and p.startswith("/")):
        return "root"
    if p.startswith("~") or "/Users/" in p or "/home/" in p:
        return "home"
    return "project"


def matched_rule(command, rules):
    """First risk-rules.json rule whose pattern matches `command`, or None."""
    for rule in rules.get("rules", []):
        if re.search(rule["pattern"], command):
            return rule
    return None


def matched_flag_penalties(command, rules):
    """[(penalty, reason), ...] for every flag_penalties entry that matches."""
    out = []
    for fp in rules.get("flag_penalties", []):
        if re.search(fp["pattern"], command):
            out.append((fp["penalty"], fp["reason"]))
    return out


def fileset_sensitivity(target_path, rules):
    """(sensitivity, reason) for the first fileset_sensitivity pattern matching
    target_path, or (None, None) if nothing matches or no path given."""
    if not target_path:
        return None, None
    for fs in rules.get("fileset_sensitivity", []):
        if re.search(fs["pattern"], target_path):
            return fs["sensitivity"], fs["reason"]
    return None, None


def classify_tier(score, rules):
    """Tier name for a 0-100 score, per risk-rules.json's `tiers` table
    (ascending `max` boundaries, first one the score is <= wins)."""
    for tier in rules["tiers"]:
        if score <= tier["max"]:
            return tier["name"]
    return rules["tiers"][-1]["name"]


def score_command(command, target_path, rules):
    """Compute a full score for `command` acting on `target_path` (may be "").
    Returns a dict: score, tier, risk_category, reason, intent, matched (bool).
    Never raises on an unmatched command -- an unmatched command is Safe by
    default (score 0), since Phase 1 has no way to prove a novel command is
    risky beyond the seed rules and flag penalties."""
    rule = matched_rule(command, rules)
    flags = matched_flag_penalties(command, rules)
    sensitivity, sens_reason = fileset_sensitivity(target_path, rules)

    if rule is None:
        intent = None
        base = 0
        risk_category = None
        reason = "no seed rule matched"
    else:
        intent = rule["intent"]
        context = classify_context(target_path, rules)
        multiplier = rules["context_multipliers"].get(context, 1.0)
        # Each rule carries its own base_score (a specific pattern's severity)
        # rather than falling back to the coarser per-intent weight -- "rm -rf /"
        # and "chown -R" are both "privilege"/"delete" intent but very
        # different severities, and a shared intent-level weight would flatten
        # that distinction. intent_weights stays in risk-rules.json as the
        # taxonomy reference for intents, not as a scoring input.
        base = rule["base_score"] * multiplier
        risk_category = rule["risk_category"]
        reason = rule["reason"]

    flag_total = sum(p for p, _ in flags)
    score = base + flag_total

    if sensitivity == "high":
        score += 15
        if reason:
            reason = f"{reason}; targets a high-sensitivity path ({sens_reason})"
        else:
            reason = f"targets a high-sensitivity path ({sens_reason})"
            risk_category = risk_category or "Credential Exposure"
    elif sensitivity == "medium":
        score += 5

    score = max(0, min(100, round(score)))

    return {
        "score": score,
        "tier": classify_tier(score, rules),
        "risk_category": risk_category,
        "reason": reason,
        "intent": intent,
        "matched": rule is not None,
        "flags_matched": [r for _, r in flags],
    }


def apply_profile_adjustment(primary_result, profile, rules):
    """Phase 3 shadow score: primary's score adjusted by a learned per-
    risk_category multiplier from risk-profile.json's command_adjustments.
    Never mutates primary_result or influences it -- this is purely a second,
    independently-computed number for the shadow scorer to log and be graded
    against primary, per the plan's right-brain shadow-scoring pattern
    ("primary always ships... shadow never influences what ships").

    A category with no learned adjustment yet (including an entirely empty/
    absent profile) defaults to multiplier 1.0 -- shadow equals primary until
    real learned adjustments exist, which is exactly what makes running this
    safe from day one in shadow-only mode: an empty profile can't diverge
    shadow from primary, so promotion always starts from 100% agreement.
    """
    category = primary_result.get("risk_category") or "unmatched"
    adjustments = (profile or {}).get("command_adjustments", {})
    multiplier = adjustments.get(category, 1.0)
    try:
        multiplier = float(multiplier)
    except (TypeError, ValueError):
        multiplier = 1.0
    shadow_score = max(0, min(100, round(primary_result["score"] * multiplier)))
    return {
        "score": shadow_score,
        "tier": classify_tier(shadow_score, rules),
        "risk_category": primary_result.get("risk_category"),
        "reason": primary_result.get("reason"),
        "intent": primary_result.get("intent"),
        "matched": primary_result.get("matched"),
        "flags_matched": primary_result.get("flags_matched", []),
        "multiplier_applied": multiplier,
    }


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    if len(argv) < 2:
        print("usage: risk_score.py <rules.json> <command> [target_path] [profile.json]", file=sys.stderr)
        return 2
    rules_path, command = argv[0], argv[1]
    target_path = argv[2] if len(argv) > 2 else ""
    profile_path = argv[3] if len(argv) > 3 else None
    rules = load_rules(rules_path)
    result = score_command(command, target_path, rules)

    # Existing 2-3-arg CLI shape (flat primary result) is UNCHANGED -- every
    # existing caller (lib_risk.sh's risk_score) keeps working byte-for-byte.
    # A 4th arg (profile path) is strictly additive: wraps the same primary
    # result plus a shadow score under {"primary": ..., "shadow": ...}.
    if profile_path is None:
        print(json.dumps(result))
        return 0

    try:
        with open(profile_path) as f:
            profile = json.load(f)
    except Exception:
        profile = None  # missing/malformed profile -> shadow defaults to == primary

    shadow = apply_profile_adjustment(result, profile, rules)
    print(json.dumps({"primary": result, "shadow": shadow}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
