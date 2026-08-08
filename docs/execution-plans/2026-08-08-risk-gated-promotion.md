# Risk-gated promotion (staging → prod)

- **Status:** active (S0–S2 shipped; S3 is a supervise-first dogfood)
- **Spec:** none — this repo's requirements live in `ROADMAP.md` / `state/fix_plan.md`; the approved
  plan is the contract. Decision record: `docs/design-docs/001-risk-gated-promotion.md`.
- **Sources:** Anthropic, *How Anthropic secures its AI-native SDLC*; Ona, *Auto-approving low-risk PRs*.

## Goal

Let the harness say how risky it is to merge a change onward, and act on the answer: **LOW → staging
automatically; MEDIUM / HIGH / anything touching money → a human; prod → always a human.**

## Approach

Two-stage, escalate-only, fail-closed. Objective criteria computed from the diff produce a tier
(`lib/risk.*`); a fresh-context `risk-classifier` agent may raise it and has no way to lower it; the
result is `max()`. Preconditions (green gate, review SHIP, e2e evidence) gate the AUTO path
separately, so "too risky" and "not ready" are distinguishable in the audit record.

Prod is unrepresentable rather than merely defaulted off: `promotion.prod.autoMerge` is `const false`
in the schema and `Get-PromotionDecision` refuses prod before reading config.

## Progress log

- 2026-08-08: **S0 — privacy scrub** (`997c5a8`). 24 tracked `state/evidence/` files carried absolute
  local home paths into a public repo; normalized to `<repo>`/`<home>` (279+/279−, pure substitution).
  Widened the local `.git/hooks/pre-commit` denylist, and switched it from `grep -I` to `-a` — `-I`
  was silently skipping the UTF-8-with-BOM evidence logs as "binary", which is how the paths got past
  it originally. Guard re-tested both directions. Escalated (not acted on): the personal email in git
  commit-author metadata.
- 2026-08-08: **S1 — schema + config + engine.** `promotion` block in `harness.schema.json` (prod
  `autoMerge` pinned `const false`; `staging.autoMergeAtOrBelow` enum deliberately offers no
  `medium`) and seeded disabled in `harness.config.json`. New twin pair `plugin/engine/lib/risk.{ps1,sh}`:
  `Convert-GlobToRegex`/`glob_to_regex` (identical `**`/`*` semantics on both runners — neither PS
  `-like` nor bash `case` globs would agree), `Test-PathMatchesAny`, `Merge-RiskTier` (the escalate-only
  ratchet as a real `max()`), `Get-RiskVerdict` (fail-closed HIGH, mirroring the reviewer's
  last-`VERDICT:`-line rule), `Test-MoneySignal` (content not paths; `\b` emulated by an explicit
  class for BSD-grep parity), `Get-DeterministicRisk`, `Get-PromotionDecision`, `Get-DiffSignals`.
  +45 assertions on each runner (PS 150→195, bash 141→186 — exact parity). Mutation-verified: breaking
  the prod refusal and the leading-dot path handling turned exactly the intended 3 assertions red on
  **both** twins.
- 2026-08-08: **S2 — judge + action path.** `plugin/agents/risk-classifier.md` (narrow-focus, separate
  from `reviewer` on purpose; proof obligation on every raise; single trailing `RISK:` line),
  `plugin/commands/promote.md`, `plugin/skills/risk-tiering/SKILL.md` (SSOT for tiers + criteria),
  `/harness-doctor` check 11. Skill criteria table pinned to config by a per-column twin test,
  mutation-verified (breaking only the tier cell, and only the size limit, each went red). PS 203/0,
  bash 194/0. Docs: `docs/promotion.md`, design-doc 001, workflow.md gains a PROMOTE phase,
  `overnight.md` ledger table gains the `risk` row. Plugin 0.2.7 → 0.2.8.
- 2026-08-08: **Engine rule learned the hard way** (now in `plugin/engine/CLAUDE.md`): `jq.exe` under
  Git Bash emits CRLF, and `$(...)` strips only the *trailing* newline — so every interior line of a
  multi-line jq read keeps its `\r`, compiles to a regex ending `.*\r$`, and matches **nothing**.
  Every config-driven rule in `risk.sh` was failing OPEN until this was found. Invisible in CI, which
  runs bash on Linux only. Scalar reads elsewhere in the engine (`phase_model`) are unaffected —
  verified, not assumed.

## Remaining

- **S3 (supervise-first):** dogfood `/promote staging` in shadow mode (`autoMergeAtOrBelow: null`) on
  real ranges of this repo — a LOW, a MEDIUM, and a money-touching HIGH — plus the `gh`-unavailable
  path, and confirm the separate-reviewer-identity requirement against a real PR. Wall-clock human
  task; the mechanism must be watched before it gets the merge button.
