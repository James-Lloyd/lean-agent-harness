# 001 — Risk-gated promotion

- **Status:** accepted
- **Date:** 2026-08-08

## Context

The harness stopped at "green gate + fresh-context review SHIP + e2e evidence" and handed
*everything* to a human. That is safe and it does not scale: the human becomes the bottleneck on
changes whose blast radius is a docs typo, and by the time they reach the change that actually moves
money they are rubber-stamping.

Two published accounts converge on the same shape:

- **Ona, "Auto-approving low-risk PRs"** — risk is decided by *objective, binary criteria* computed
  from the diff. Engineers cannot self-classify. Six conditions; failing any one escalates. Changing
  the criteria or the review prompt requires explicit approval, and a model swap counts as a
  material policy change. A human still clicks merge — their "trust anchor".
- **Anthropic, "How Anthropic secures its AI-native SDLC"** — tier the codebase and apply automation
  by tier; run several *narrow-focus* review agents rather than one omni-reviewer, because separate
  agents avoid shared blind spots; require an agent to write a proof that its finding is valid; log
  every automated approval, tool call, and message *with the signals it used* so decisions are
  attributable after the fact; keep regulated and mission-critical code on the human path; run new
  reviewers in **shadow mode** until they earn trust.

## Decision

Ship an opt-in `promotion` policy: classify a reviewed diff **LOW / MEDIUM / HIGH**, auto-approve and
auto-merge only LOW to **staging**, escalate everything else, and never automate **prod**.

Four choices are load-bearing:

**1. Deterministic first, agent second, escalate-only.**
`lib/risk.*` computes a tier from the diff — size, path globs, and the money vocabulary in the added
lines. Then a fresh-context `risk-classifier` agent runs and is merged with `max()`. The agent has
no way to *lower* a tier, so a persuasive model cannot talk a change down. Risk is never
self-declared by whoever wrote the change.

**2. Prod is unrepresentable, not merely defaulted.**
`promotion.prod.autoMerge` is `const false` in the schema, and `staging.autoMergeAtOrBelow`'s enum
has no `medium` member. `Get-PromotionDecision` *also* refuses prod before it reads config at all —
the schema protects a repo that validates config in CI, the code protects the ones that don't.
Automating prod is a code change with a review, not a value you can set.

**3. Money is content, not just paths.**
Path globs miss a pricing constant edited in a shared util. The added lines of the diff are scanned
for money vocabulary, matching at a **word start** with no constraint on what follows — inflected and
snake_case forms (`tax_rate`, `taxes`, `prices`) are most of how money words appear in code, and an
earlier whole-word rule missed all of them, i.e. failed OPEN. Over-matching is the safe direction: a
false HIGH costs one human glance; a false LOW auto-merges a money bug.

**4. The policy cannot approve a change to itself.**
`lib/risk.*` carries a *hardcoded* list — `specs/`, `harness.config.json`, settings, hooks, CI
workflows, the risk lib, the classifier, `/promote`, the risk-tiering skill — all pinned HIGH. Ona's
governance requirement expressed as code rather than as a promise. Deliberately not config-driven:
if the escalation list for "edits to the escalation list" lived in config, one edit could disarm the
mechanism and then auto-merge itself.

## Why (and what we rejected)

**Rejected: agent judgment alone.** Simpler, and exactly what Ona forbids — it is self-classification
with extra steps, and it drifts silently as the model changes.

**Rejected: deterministic rules alone.** Fully auditable but blind to semantic risk the paths don't
reveal. The two-stage max() keeps the audit floor while letting a judge catch what globs cannot.

**Rejected: extending `/review` with a risk section.** One judge with one checklist has one set of
blind spots, and the two questions are genuinely different — "is this correct?" versus "if it is
wrong anyway, what breaks?" A reviewer deep in correctness is the wrong context to ask about
reversibility. Separate agent, per Anthropic.

**Rejected: local `git merge` to staging instead of GitHub.** Would work in local-only repos, but
loses the review record, the labels, and the comment thread — i.e. most of the audit trail. GitHub
PR approve + auto-merge keeps the decision where a human will later look for it.

**Rejected: a numeric risk score.** Scores invite threshold-shopping and imply a precision the
signals do not have. Three named tiers map onto three distinct actions.

**Accepted cost: `enabled: false` by default**, so `/plugin update` cannot switch promotion on in a
repo that never asked for it. The feature is inert until someone reads `docs/promotion.md`.

## Consequences

- A new opt-in config block, one engine lib twin pair, one agent, one command, one skill.
- `/harness-doctor` gains check 11; the ledger gains a `risk` result row.
- GitHub rejects self-approval, so auto-approval requires a **separate reviewer identity**. Getting
  this wrong fails toward "nothing auto-merges", which is the correct direction.
- Rollout is shadow mode first (`autoMergeAtOrBelow: null`) — classify and log, merge by hand, and
  compare — before the mechanism gets the merge button. Anthropic's shadow mode, adopted wholesale.
- The human's job moves from reviewing every merge to auditing the classifier's decisions. That is
  the intended trade and it is only safe while the audit record stays complete.
