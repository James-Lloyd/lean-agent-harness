---
name: risk-tiering
description: Decide how much human scrutiny merging a change needs — the LOW/MEDIUM/HIGH tier definitions, the objective escalation criteria, and the rule that nothing may ever lower a tier. Use during /promote, when tuning promotion.* in harness.config.json, and whenever someone asks why a change was escalated or what would let it auto-merge.
---

# risk-tiering

A change that is green through the gate and SHIPped by a fresh-context reviewer is *correct as far
as we can tell*. That is not the same as *safe to merge without a human*. This skill owns the
difference.

**This file is the single source of truth for the tier definitions and the criteria.**
`/promote`, the `risk-classifier` agent, `/harness-doctor` check 11 and `docs/promotion.md` point
here rather than restating them — one owner, so a retune can't leave a stale copy behind.

## The two questions

| | Asks | Owner | When it fails |
|---|---|---|---|
| Review | Is this change **correct**? | `/review` → `reviewer` | blocker findings, back to the builder |
| Risk | If it is wrong **anyway**, what breaks and can we undo it? | `/promote` → `risk-classifier` | escalate to a human, never merge |

They are separate agents on purpose. Two narrow judges have different blind spots; one omni-judge
has a single set.

## The tiers

| Tier | Means | Staging | Prod |
|------|-------|---------|------|
| `LOW` | Contained blast radius, trivially revertible, no criterion tripped | **auto-approve + auto-merge** | human |
| `MEDIUM` | A human should look — size, or a sensitive surface | human | human |
| `HIGH` | Money, irreversibility, or a weakened control | human | human |

Prod has no automated row and never will: `promotion.prod.autoMerge` is pinned to `const false` in
`harness.schema.json`, and `Get-PromotionDecision`/`promotion_decision` refuses a prod AUTO before it
reads config at all.

## The escalation criteria

Objective, computed from the diff, binary. **A change's author — human or agent — cannot classify
its own change.** Failing any single criterion escalates; LOW is what "none of these tripped" means.

| Criterion | Config key | Escalates to |
|-----------|------------|--------------|
| Path on the money/regulated list | `promotion.alwaysHuman` | `HIGH` |
| Money term in the **added lines** (content, not path) | `promotion.moneySignals` | `HIGH` |
| Edits the policy, the guardrails, or CI | (hardcoded — see below) | `HIGH` |
| Diff at or above the size limit | `promotion.criteria.maxChangedLines` | `MEDIUM` |
| `migrations` | `promotion.criteria.escalatePaths.migrations` | `MEDIUM` |
| `infra` | `promotion.criteria.escalatePaths.infra` | `MEDIUM` |
| `authz` | `promotion.criteria.escalatePaths.authz` | `MEDIUM` |
| `auditLog` | `promotion.criteria.escalatePaths.auditLog` | `MEDIUM` |
| `contracts` | `promotion.criteria.escalatePaths.contracts` | `MEDIUM` |

The size limit ships at **1000** changed lines (additions + deletions), at-or-above, and is pinned to
this table by the twin self-tests — a retune that updates one and not the other goes red.

`escalatePaths` category names are free-form: they appear verbatim in the audit record and the PR
comment, so a human can see *which* criterion tripped. Add categories freely; they cost one row here.

### Why `moneySignals` reads content, not paths

A pricing constant edited in a shared util has no telltale path. Path globs would miss it, so the
added lines of the diff are scanned for the money vocabulary too.

A term matches at a **word start**, case-insensitively, with no constraint on what follows — `tax`
fires on `tax_rate`, `taxes` and `TaxTable`, because inflected and snake_case forms are most of how
money words actually appear in code. It does **not** fire mid-word (`syntax`). The cost is a false
positive on a word that merely starts with a money term (`taxonomy`, `balancer`), and that is the
right trade: a false HIGH costs one human glance, a false LOW auto-merges a money bug.

### Why self-governance is hardcoded

`plugin/engine/lib/risk.*` carries a fixed list — `specs/`, `harness/harness.config.json`,
`.claude/settings.json`, `.claude/hooks/`, `.github/workflows/`, `plugin/hooks/`, the risk lib
itself, the `risk-classifier` agent, `/promote`, and this skill — all pinned to **HIGH**.

It is not config-driven on purpose. If the escalation list for "edits to the escalation list" lived
in config, one edit could disarm the mechanism and then auto-merge itself. Changing promotion
criteria, the classifier prompt, or the tier logic is a **policy change requiring human approval**,
and this is that requirement expressed as code rather than as a promise.

## The escalate-only rule

```
final tier = max(deterministic tier, classifier tier)
```

The deterministic engine runs first; the `risk-classifier` agent runs second and can **confirm or
raise, never lower**. This is `Merge-RiskTier`/`risk_tier_max`, a real max() — a lower answer from
the agent is discarded, not debated. There is no appeal path and no override flag.

Everything unresolvable resolves **HIGH / HUMAN**: an unparseable verdict, a classifier that could
not run, an empty diff, an unknown tier string, a missing precondition, an absent PR, an
unauthenticated `gh`.

## Preconditions are not risk

`promotion.preconditions` — `gateGreen`, `reviewShip`, `e2eEvidence` — gate the AUTO path but are a
*different* failure. A HIGH-risk change and an unreviewed change both go to a human, for reasons a
human needs told apart. The audit record says which.

Risk classification decides how much scrutiny a **good** change needs. It never substitutes for the
gate or the review.

## Turning it on

Ships `enabled: false`, so `/plugin update` cannot switch promotion on in a repo that never asked.
See `docs/promotion.md` for the rollout — including **shadow mode** (run it, log the decisions,
merge by hand, compare) before granting it the merge button, and the separate reviewer identity
GitHub requires for auto-approval.
