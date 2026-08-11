# Evidence — single-vendor per-phase routing (2026-08-11)

## What changed
Per-phase routing retuned and made identical across all three harness consumers; codex removed from
routing entirely (engine arm retained and still tested, just unrouted).

| Phase | Model | Effort | Fallback |
|-------|-------|--------|----------|
| `session` (orchestrator) | `claude-opus-4-8` | high | — |
| `plan` | `claude-fable-5` | high | `claude-opus-5` @ high |
| `implement` | `claude-opus-5` | high | **none** |
| `review` | `claude-fable-5` | high | `claude-opus-5` @ medium |
| `evaluate` (disabled) | `claude-fable-5` | high | `claude-opus-5` @ medium |
| `explore` | `haiku` | low | — |
| `docs` | `haiku` | low | — |

**Fallbacks only on the Fable phases.** Fable is the model that has actually usage-capped in practice
(3x, killing reviews), and a headless run cannot ask a human mid-review. `implement` has none on
purpose: it is interactive, so a cap is recoverable by hand, and a silent second-choice builder is
worse than stopping.

## Why full IDs, not aliases
The bare alias `opus` floats to the current Opus — today that is **Opus 5**, not 4.8. Verified live:
this repo's `.claude/settings.json` read `"model": "opus"` and the session was running Opus 5. Any
phase whose *generation* matters is therefore pinned to a full `claude-*` ID. `haiku` stays an alias
because only the tier matters there.

## Doer != judge
`implement` (Opus 5) and `review` (Fable 5) are different families, so the model that writes a diff
never clears it. **Accepted tradeoff:** the review fallback is Opus 5 — the builder's own model — so a
Fable cap costs model diversity. The primary guarantee survives (the reviewer is a fresh context that
never sees the conversation that produced the code); only the secondary one lapses, only on a cap, and
no diff merges without a human.

## Verdict-parser fix (security, HIGH — closed 2026-08-11)
`gate.ps1`'s `Get-ReviewVerdict` / `Get-EvaluatorVerdict` used `-match`, which is case-INSENSITIVE on
PowerShell while the `gate.sh` twins' `grep -E` is not. Both now use `-cmatch` in the line **SELECTION**
as well as the parse — the selection was the half the original write-up missed, and it is the worse
one: with `-match` the two shells could pick a *different* "last VERDICT line" before parsing started.

Exploitable shape (line-initial lowercase after a genuine verdict):

    VERDICT: REJECT
    verdict: ship would be my instinct but no

PowerShell returned **SHIP** — silently converting a REJECT into a SHIP — while bash returned REJECT.
This gated `promotion.preconditions.reviewShip`, so it could have cleared a change for auto-merge.

**Correction to the original write-up:** its example, `"I would not say verdict: ship here"`, was never
exploitable — `^\s*VERDICT:` is line-anchored, so prose mid-line matched under neither operator. Testing
that shape would have been false comfort. The pinned tests use the line-initial form.

Mutation-verified: reverting `-cmatch` → `-match` reddens **all 7** new PS assertions, including the
REJECT→SHIP flip. +7 assertions per twin (PS 222→229, bash 212→219).

## Info-only repos and auto-merge — no change needed
Classified real docs-only diffs against the live risk engine. Content-based classification already does
what a "this repo is just info" flag would, and does it more safely:

| Diff | Tier |
|---|---|
| `docs/architecture/overview.md` | LOW — would auto-merge |
| `README.md` + `AGENT_NOTES.md`, 120 lines | LOW — would auto-merge |
| `docs/big.md`, 1200 lines | MEDIUM (over `maxChangedLines`) |
| `docs/pricing-strategy.md` containing "price"/"discount" | HIGH (money signals in added lines) |
| `specs/001-thing.md` | HIGH (hardcoded self-governance) |

So **do not add a repo-level always-automerge flag.** A blanket flag would auto-merge `specs/`,
`harness.config.json`, `.claude/settings.json` and hook changes in the very repo that governs the
harness — the self-governance list exists precisely to stop that. Enabling `promotion` per repo gets
the desired behavior with the guardrails intact.

## Also in this change
- **Review rounds capped at 2** (was 3); high-blast-radius changes (payments, auth, migrations,
  irreversible data ops) stay uncapped.
- **`verification.freshContextReview` deleted** from the schema and all four configs — dead key,
  nothing read it. `verification` has no `additionalProperties: false`, so configs that still carry it
  remain valid.
- **Ratchets consolidated** — see the repo `CLAUDE.md` diff.

## Files changed
- `harness/harness.config.json` in this repo **and in both downstream consumer repos** — `models`
  block retuned, `codex` block deleted
- `.claude/settings.json` in all three — `model` + `effortLevel` (neither consumer set `effortLevel`
  at all before; one consumer's config predated the `effort` field entirely)
- `plugin/agents/{generator,planner,reviewer,evaluator,risk-classifier}.md` — `model:` pinned to full IDs
- `plugin/skills/model-routing/SKILL.md` — defaults table, alias warning, codex demoted to opt-in
- `plugin/.claude-plugin/plugin.json` — 0.2.8 → 0.2.9

## Verification
- `run-tests-ps.txt` — PowerShell 5.1: **222 passed, 0 failed**
- `run-tests-bash.txt` — bash: **212 passed, 0 failed**
- `doctor-check10.txt` — config ↔ agent-frontmatter agreement: **PASS** on all 6 phase/agent pairs
- All 6 edited JSON files re-parsed successfully; `codex` key absent from all three `models` blocks
- Routing verified byte-identical across the three repos

## Not done (out of the chosen scope)
- Plugin **not yet reinstalled** — the machine-wide cache is still 0.2.8, so consumers keep the old
  frontmatter until `/plugin update lean-agent-harness` runs (needs a commit first; the marketplace
  entry is git-backed and pins `gitCommitSha`).
- Ratchet consolidation, and the dead `verification.freshContextReview` flag, deliberately deferred.
