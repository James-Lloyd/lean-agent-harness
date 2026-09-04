# 002 — Vendor-agnostic routing (Claude Code today, OpenAI Codex CLI swappable per phase)

- **Status:** accepted (slice V1 shipped; V2–V5 in `state/fix_plan.md`)
- **Date:** 2026-09-04

## Context

The harness was built on Claude Code and, on 2026-08-11, deliberately routed every phase to a Claude
model ("single-vendor by decision") while keeping the engine's `codex` arm tested but unrouted. James
asked on 2026-09-04 to make the harness model-agnostic so OpenAI Codex CLI (or a GPT model) can be
swapped into any phase, and to re-examine the design against the September 2026 state of both vendors.

What changed since the 08-11 decision (verified online 2026-09-04 against the Codex CLI docs and
releases, agents.md, agentskills.io, the Claude Code changelog, and the two papers cited below; the
findings are recorded here so this doc stands alone):

- **Codex CLI 0.153** now has lifecycle hooks (`PreToolUse`, `PostToolUse`, `Stop`, `SessionStart`, …)
  in `~/.codex/hooks.json` or `<repo>/.codex/hooks.json`, with the *same JSON shape* as Claude Code's
  (`matcher` + `{type: "command", command, timeout}`, JSON on stdin, exit 2 = deny). Repo-level hooks
  are **skipped silently under `codex exec`** until the repo is trusted, or with
  `--dangerously-bypass-hook-trust`.
- Codex has **custom subagents** (`.codex/agents/*.toml` with `model`, `model_reasoning_effort`,
  `sandbox_mode`), **plugins**, and reads the **Agent Skills** standard from `.agents/skills/` (not
  `.claude/skills/`). Claude Code reads `.claude/skills/` only. Both follow symlinks/junctions.
- Codex reads **`AGENTS.md`** (root → cwd chain, 32 KiB cap) and nothing else; **Claude Code does
  not read `AGENTS.md`** (2.1.260) but its `CLAUDE.md` can `@import` any file.
- Every `*-codex` model ID is **retired**; Codex runs the general models (`gpt-5.6-sol`,
  `gpt-6-astra`, …) with `model_reasoning_effort = minimal|low|medium|high|xhigh`.
- Codex still has **no `--max-turns`**; `codex exec --json` streams `turn.completed` events and
  `--output-schema` gives a structured final message.
- Independent evidence on cross-vendor review: on CR-bench (arXiv 2603.23448) Claude Code found 32.1%
  of seeded review bugs, Codex 20.1%, and their **union 41.5%** — the two miss *different* bugs. A
  review-and-repair study (arXiv 2607.21656) found a Codex reviewer **with write access** regressed
  Claude-written code (13 regressions vs 3 fixes) while a comment-only cross-vendor review improved
  it. Self-review changed nothing.

## Decision

Make the harness vendor-agnostic in four load-bearing moves, shipped as five slices. The default
routing stays single-vendor Claude (per 08-11); what changes is that routing a phase to Codex becomes
a **config edit with first-class guardrails**, not an exotic path.

**D1. `AGENTS.md` is the map; `CLAUDE.md` imports it.** (slice V1, this PR)
`AGENTS.md` carries everything vendor-neutral: components, the map, how to work, guardrails, the
ratchet, nested context. `CLAUDE.md` is `@AGENTS.md` plus a short "Claude Code specifics" section
(EnterWorktree, plugin-provided commands, settings.json permissions). The same pattern applies to nested
maps (`plugin/engine/AGENTS.md` + a one-line `plugin/engine/CLAUDE.md`) and to the component template
(`templates/component-AGENTS.md` + `component-CLAUDE.md` shim). Codex, Cursor, Copilot, Gemini CLI and
the rest read the map natively; Claude Code reads it through the import. One source of truth, and the
old "pointer" AGENTS.md — which Codex could only follow by opening a second file — goes away.

**D2. Per-phase Codex model and effort; the literal `"codex"` stays the vendor key.** (slice V2)
`models.<phase>.model: "codex"` remains the way to route a phase to Codex (back-compatible, already
tested), and the phase may now carry `codex: { model, reasoningEffort }` overrides that win over the
global `models.codex` block. We considered a separate `vendor` field and rejected it for now: it
changes the shape of every phase object and every resolver for a purely cosmetic gain, and it can be
added later without breaking anything. What actually matters — choosing a different Codex model and
depth per phase — is delivered by the override object.

**D3. Codex surfaces are *generated*, machine-local, and gitignored.** (slice V3)
A new engine script pair `codex-setup.{ps1,sh}` writes `.codex/config.toml` (`[[skills.config]] path`
pointing at the installed plugin's `skills/`, `[agents]` defaults from `models.*`, hooks feature on),
`.codex/hooks.json` (four of the five guard hooks through the same `run.mjs` bodies — `lock-config` has no
Codex event, and `block-destructive` is scoped to the shell-tool matcher because its whole-payload
fallback scan would falsely deny edits under `*`), and `.codex/agents/*.toml`
(generated from `plugin/agents/*.md` frontmatter + body). Generated because the plugin lives in the
per-machine cache and a committed absolute path dies on the next device (ratchet 2026-07-30);
gitignored for the same reason `.claude/settings.local.json` is. `--user` writes the hooks to
`~/.codex/hooks.json` instead, which is the only place they run under headless `codex exec` without
the bypass flag. `/harness-doctor` grows a check that the generated set is present and not stale.

**D4. Cross-vendor review is a *second, read-only* reviewer, never a replacement.** (slice V4)
`models.review.second: { model, effort }` (default `null`) runs after the primary reviewer **ships** at
every review point — the loop's periodic review and `/review` — in read-only mode with the same prompt
and verdict contract; a primary REJECT already decides the point, so the second is not consulted on a
rejected batch. The verdict is SHIP only if **both** ship; both verdicts and transcripts are recorded.
Judge order at the loop's review point is primary → second → evaluator (when enabled); the
`harness-reviewed` watermark advances only after the LAST judge passes. The
second reviewer must differ from the primary in model (doctor ⚠️ otherwise: same model twice is
self-review, which measured as worthless). Read-only is non-negotiable: the regression mechanism in the
literature is a reviewer that rewrites. Recommended first use: primary `claude-fable-5-1` @ `high`,
second `codex` (`gpt-5.6-sol` @ `high`).

**Out of scope, recorded:** bridging the harness's slash commands (`/work`, `/review`, …) to Codex
(`$skills` are the Codex analogue; custom prompts are deprecated there) — a Codex operator runs the
loop headlessly or drives the phases by hand until a command→skill bridge exists (slice V6, unplanned).

## Consequences

- **Guardrails hold under Codex only when the generated hooks are installed and trusted.** The
  headless codex arm today is guarded by `--sandbox` + the gate + `autoRollbackOnRed`; V3 adds the
  hooks, and the doc for V3 must state the `exec` trust caveat in the first paragraph.
- **The Codex hook payload field names are unverified.** The shape is documented as the same, but
  `run.mjs` reads `tool_input.command`; V3's live-fire task checks the field names before the hooks are
  called equivalent.
- **32 KiB AGENTS.md chain.** The root map is ~8 KB; the component template ~2 KB. `/gc` and the
  doc-gardener already police "map over ~100 lines" — the rule moves to `AGENTS.md`.
- **`fable`/`opus` alias floating applies to Codex too:** a `codex.model: null` floats on the CLI
  default (recommended — retired IDs rot); a pinned GPT ID must be re-checked on each Codex release.
- **Model diversity is measured, not assumed.** V5 live-fires the second reviewer on this repo in
  shadow mode (findings recorded, verdict advisory) before it gates anything.

## Slices

| Slice | Content | Done when |
|---|---|---|
| V1 | D1: AGENTS.md canonical + CLAUDE.md import; nested + template + example; every prose surface that named `CLAUDE.md` as "the map" now names `AGENTS.md`; doctor check 2 verifies the import line | tests green; `grep` for `CLAUDE.md` outside Claude-specific sentences returns only history |
| V2 | D2: `models.<phase>.codex{model,reasoningEffort}` overrides; resolvers + dispatcher args + schema + doctor 10 + skill | stub-driven dispatcher test proves a per-phase codex model reaches `codex exec -m` |
| V3 | D3: `codex-setup.{ps1,sh}` + `.gitignore` + doctor check 12 + `harness/codex-setup` wrappers | generated files validate (`codex execpolicy check`-style dry run), doctor passes, live hook denial observed once |
| V4 | D4: second reviewer in loop twins + `/review` + doctor ⚠️ + tests | stub-driven: SHIP+REJECT ⇒ REJECT; findings unioned in the ledger |
| V5 | live-fire (supervised): second reviewer on a real diff of this repo in shadow mode; hook payload field names verified | evidence dir with one real second-review transcript and one real Codex hook denial |
