# 2026-07-26 — Claude-5 context-engineering refresh

**Trigger:** Anthropic's *The new rules of context engineering for Claude 5 generation models*
(claude.com blog) + *Prompting Claude Opus 5* (platform docs), applied per harness-philosophy #10
("re-examine the harness on every new model and strip pieces that are no longer load-bearing").
Sources recorded as row 8 of `docs/principles/sources.md`.

## Verdict on the harness as found
Mostly already aligned: no XML-tag prompting, no outdated model IDs, reset-over-compact already
policy, progressive disclosure already the skill layout, effort tiers already on agents, `context:
fork` on /verify, worktree isolation on the generator. Three residual legacy-era items plus one class
of real rot were fixed.

## Changed
1. **Thinking-trigger phrases removed** (`CLAUDE.md`, `PROMPT.md` ×2). "Think hard." was a Claude
   3.5/4-era thinking-budget hack; Claude 5 models control depth via the effort parameter, and the
   phrase is dead weight.
2. **Self-repetition removed** (`PROMPT.md` Phase 1). "I need to repeat myself here — one item per
   loop" was Ralph-loop-era emphasis; Claude 5 follows the instruction stated once.
3. **Delegation calibrated down, not up** (`PROMPT.md` steps 7/9, `generator.md`). Claude 5 models
   delegate *more* readily than prior models; blanket "fan out subagents" encouragement now costs
   tokens on work finishable in a handful of tool calls. The explorer fan-out pattern stays — scoped
   to genuinely wide sweeps, with "do small targeted reads yourself" as the counterweight.
4. **Stale-path rot purged from prompt surfaces** (post-plugin-flip). Wrong references are context
   poison — the model acts on them. Fixed: `PROMPT.md` (`.claude/agents/explorer.md`), `work.md`
   (`harness/lib/` → plugin engine lib), `ratchet.md` + `harness-prune.md` (pre-flip hook/skill/profile
   paths, rescoped for plugin vs copied-in layouts), `harness-doctor.md` check 5 (four → **five** hook
   scripts incl. `lock-config`; wired in the plugin's `hooks.json` via `run.mjs`, not settings.json),
   `review.md` (`models.reviewFallback` → `models.review.fallback`), `loop.ps1`/`loop.sh` embedded
   judge prompts, `block-destructive.*` block messages, `harness.schema.json` descriptions,
   `stack-detect` skill, component-CLAUDE template + example nested maps (profile now by name).
5. **Root `CLAUDE.md` re-compressed** toward its own ~100-line rule: 128 → 115 lines,
   header/workflow/gate sections tightened, all six ratchet rules kept with every operative clause
   intact. Still slightly over ~100 — the ratchet section dominates the remainder, and cutting real
   failure rules to hit a line count would invert the discipline.

## Deliberately kept (and why the "remove verification instructions" rule does NOT apply)
- **The gate, e2e-evidence, and fresh-context review/evaluator.** Opus 5 guidance says to remove
  instructions telling an agent to re-check *its own* work (it self-verifies; instructions compound
  into over-verification). The harness's judges are *structural*: a different context, read-only,
  fail-closed — process architecture, not model babysitting. Doer ≠ judge stands.
- **"Default to REJECT when unsure"** in the loop's judge prompts — that's fail-closed verdict
  parsing, not a severity filter. The reviewer prompts already scope findings by *category*
  (correctness/evidence/guardrails) with an anti-padding clause, which matches — not contradicts —
  the Opus 5 review guidance.
- **Cross-file repetition of the core invariants** (one-task, no-placeholders, never-weaken-a-test)
  across `PROMPT.md` / `generator.md` / `work.md` — these are *independently loaded* fresh-context
  entry points, not duplication within one context window. Single-source applies within a window,
  not across amnesiac spawns.
- **Model routing table** (`opus`/`fable`/`haiku` + codex) — already current-generation; aliases
  track latest models.
