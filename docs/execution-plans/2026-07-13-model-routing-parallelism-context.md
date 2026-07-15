# Execution plan: per-phase model routing, parallel execution, fresh-context boundaries, main-window context control

**Status: APPROVED 2026-07-13.** Decisions: (1) session default opus in settings.json — yes;
(2) codex model floats on CLI default, `model_reasoning_effort = high`; (3) ChatGPT-plan sign-in,
config keeps an API-key escape hatch (`codex.auth`); (4) custom fleet runner, `parallel.maxWorkers: 3`.
Research inputs: Claude Code docs (worktrees, agent-teams, best-practices, headless), Anthropic's
multi-agent-research-system / when-to-use-multi-agent / long-running-harnesses posts, ctx.rs merge-queue,
Autonoma parallel-PR strategies, Amp's GPT-5 Oracle + compaction retirement, OpenAI Codex CLI docs
(v0.144.x) and codex-plugin-cc. Codebase seams verified against loop.ps1/loop.sh, lib/, agents/, commands/.

---

## 1. Per-phase model routing

### Facts that shape the design
- Today the harness has **zero model config**: no `--model` in either loop invocation site
  (`loop.ps1:252-256` main, `loop.ps1:115` reviewer; mirrored in loop.sh), no `model:` in any agent
  frontmatter, no `model` in settings.json. Everything inherits the ambient session model.
- Platform surfaces (July 2026): `model:` agent frontmatter (aliases `haiku|sonnet|opus|fable`, full IDs,
  `inherit`), `"model"` in settings.json (session default), `claude -p --model X` (headless), and
  `CLAUDE_CODE_SUBAGENT_MODEL` env (global subagent override — escape hatch, not the mechanism).
  Hooks **cannot** route models. Verify `fable` alias works in frontmatter; fall back to `claude-fable-5`.
- Anthropic's own finding: expensive lead/judges + cheap read-heavy workers; upgrading the worker model
  outperformed doubling token budget.

### Design
One declared routing table in `harness.config.json` (new `models` block); the *mechanisms* are agent
frontmatter + settings.json + loop `--model` flags. `/harness-init` writes the mechanisms from the
config; `/harness-doctor` fails on drift between them.

```jsonc
"models": {
  "session":        "opus",      // settings.json "model" — the main working window
  "explore":        "haiku",     // explorer agent frontmatter (new agent, see below)
  "plan":           "fable",     // planner agent frontmatter
  "implement":      "opus",      // generator frontmatter + loop main call --model
  "review":         "codex",     // "codex" = external reviewer; any claude alias = internal reviewer
  "reviewFallback": "fable",     // reviewer agent frontmatter + loop reviewer --model when codex unavailable
  "evaluate":       "fable",     // evaluator frontmatter (judges deserve the strongest model)
  "docs":           "haiku",     // doc-gardener frontmatter
  "codex":          { "model": null, "reasoningEffort": "high" }  // null = don't pin (see §2)
}
```

Frontmatter assignments: planner→fable, generator→opus, reviewer→fable, evaluator→fable,
doc-gardener→haiku, explorer(new)→haiku. Schema addition mirrors this; `Get-Prop`/`jq // default`
accessors mean trimmed configs degrade to today's behavior (inherit everything).

### The "Explore" step — one deliberate deviation from the requested shape
Explore should **not** become a pipeline phase with a context handoff into planning. Anthropic explicitly
warns against phase-decomposed agent pipelines (each handoff degrades context — the "telephone game"),
and the standard workflow keeps explore→plan in one context because the plan benefits from the
exploration reasoning. Instead: a new read-only **`explorer` agent (haiku, tools: Read/Glob/Grep/Bash,
effort: low)** that planner, generator, and PROMPT.md fan out to for searches/reads *within* their
phases. You still get "exploration on Haiku" — as a fan-out pattern available everywhere, not a stage
whose output must survive a handoff.

---

## 2. Codex as reviewer (cross-vendor), fallback Fable

Production precedent is real: Amp runs GPT-5 as an isolated-context "Oracle" reviewer against Sonnet
precisely for training-lineage diversity; OpenAI ships codex-plugin-cc (official Claude Code plugin,
`/codex:review`, `/codex:adversarial-review`). Evidence of value is directional (practitioner reports,
no rigorous benchmark), but it strictly dominates same-model self-review and complements fresh-context.

### Model correction
There is **no "GPT-5.6-codex"**. July 2026 lineup: `gpt-5.6-sol` (flagship, $5/$30 per 1M),
`gpt-5.6-terra` ($2.50/$15), `gpt-5.6-luna` ($1/$6); alias `gpt-5.6` → sol. Codex CLI's default is
already **gpt-5.6-sol at medium reasoning**. Recommendation: **don't pin** (`codex.model: null`) —
model-id drift breaks pinned `-m` values, and under ChatGPT-plan auth the default tracks the best
available — but set `model_reasoning_effort = high`. Pin `gpt-5.6-terra` if API-key cost matters.

### Mechanism — new `harness/lib/review-codex.ps1` + `.sh`
- **Detect:** `Get-Command codex` + `codex login status` (exit 0 = authed; known false-negative with
  Azure/custom providers — config flag to force-enable). Detection failure → silent fallback to the
  internal reviewer with `--model <reviewFallback>`; log which path ran to the ledger.
- **Invoke** (global flags BEFORE the subcommand — flag-placement quirk; PS 5.1 needs UTF-8
  `$OutputEncoding` for the stdin pipe):
  `codex --sandbox read-only --ask-for-approval never exec - -C <repo> --ephemeral
   --skip-git-repo-check -o <run-dir>/codex-verdict.txt`
  Prompt = same fresh-reviewer brief the loop builds today (specs + principles + `git diff base..HEAD`
  content inlined, since codex won't share Claude's session) + the existing VERDICT protocol.
- **No `--max-turns`/`--timeout` exists in codex exec** → wrap in an external watchdog (PS job /
  `timeout`) in the loop; kill + treat as fail-closed REJECT on expiry.
- **Parse fail-closed** with the existing `Get-ReviewVerdict`/`review_verdict` (last-VERDICT-line-only)
  against the `-o` file — never trust exit codes for verdicts.
- **Keep both read-only layers:** codex's OS-enforced read-only sandbox, *plus* the existing
  hard `git reset --hard && git clean -fd` after review regardless of outcome.
- Wire into: loop periodic reviewer (`Invoke-PeriodicReview`) and `/review` (try codex via Bash;
  fallback = spawn `reviewer` subagent as today).
- **Prompt hardening (applies to both reviewers):** constrain to correctness/requirement gaps only.
  Anthropic's docs note an adversarial reviewer told to find problems always will — unconstrained,
  it manufactures over-engineering churn.

---

## 3. Parallel execution across instances

### What the research settles
- **Isolation:** worktree-per-agent is now first-party (`claude --worktree <name>`,
  `isolation: worktree` frontmatter, `.worktreeinclude` for gitignored env files, worktree lock while
  running). Containers are overkill for same-repo work.
- **Scale:** 3–5 sessions max per Anthropic docs; community consensus is 2–4 because *human review
  bandwidth*, not compute, binds. (Gas-Town-scale 20–30 agents = frontier experimentation, not practice.)
- **Integration:** parallel generation, **serialized integration**. Local merge queue: freeze a base
  snapshot for the batch → each branch rebases onto current main in order → full gate re-runs on the
  *combined* state → only then does main advance. Conflicts go back to the **authoring agent** (it has
  the task context); humans only for declared overlap-zone files (auth, migrations, shared config).
- **Decomposition:** file-ownership partitioning. Two tasks touching the same file run sequentially,
  never in parallel. "Worktrees convert silent runtime corruption into visible merge-time conflicts."
- **Coding-specific warning:** Anthropic says coding has fewer truly parallelizable tasks than research;
  multi-agent costs 3–10× tokens. Parallelism is opt-in per batch, not the default mode.

### Current blockers in this codebase (all verified)
Shared mutable state that two concurrent loops would corrupt: git tree itself (rollback is
`reset --hard` + `clean -fd` tree-wide; commit is `git add -A`), `harness/.checkpoint` (single path),
`harness/.budget.json` (single path, reset per run), racy run-id allocation (max-suffix scan, no lock),
shared `harness-reviewed` tag and `state/handoff.md`.

### Phased build
**Phase A (small, already roadmapped):** `isolation: worktree` on the generator subagent + a merge-back
step in `/work` Phase 5. A build can no longer dirty the main tree; single-flight but structurally ready.
**Phase B (the fleet):** `harness/fleet.ps1` + `fleet.sh` — a worktree-pool runner:
1. Add `files:`/`area:` ownership to `state/tasks.json` entries (planner fills it in). Fleet refuses to
   co-schedule overlapping tasks.
2. Batch snapshot: record `main`@start; spawn ≤ `parallel.maxWorkers` (default 3) headless workers,
   each `claude -p --model <models.implement> --worktree task-<id>` with a self-contained task brief.
3. Per-worker state: move `.checkpoint` and `.budget.json` into `harness/.runs/<runId>/` (fixes the
   shared-path bug for sequential runs too); lock run-id allocation (mkdir-as-mutex).
4. Serialized merge queue: for each finished branch in completion order — rebase onto current main;
   conflict → re-invoke that task's agent in its worktree to resolve; run the FULL component+root gate
   on the merged state; green → advance main + tag; red → park branch, record to ledger, continue queue.
5. `.worktreeinclude` + per-worktree `commands.install` so each worktree can actually build.
Native **agent-teams** (experimental) is the alternative for interactive exploratory use; the fleet
runner wins for unattended work because budgets/rollback/ledger/fail-closed verdicts stay deterministic.

---

## 4. Fresh-context boundaries (which steps get a clean window)

| Step | Today | Best practice | Change |
|------|-------|---------------|--------|
| Explore | folded into planner/generator | same context as planning (handoffs degrade plans) | keep folded; route to haiku explorer agents |
| Plan | planner subagent (fresh) for non-trivial; inline for trivial | fresh is fine; artifact must be self-contained | keep; tighten plan artifact contract |
| Implement | generator subagent (fresh) *or* "do it directly" inline | **always fresh from the written plan**, not the planning conversation | make generator delegation the default; inline only for trivial one-file fixes |
| Review | always fresh (subagent / headless read-only) — settled correct | always fresh, different model or vendor | keep; add codex path + correctness-only constraint |
| Record | inline | inline (mechanical) | keep |

Boundary rule to encode in `workflow.md`: **a phase boundary is only legitimate if the artifact crossing
it is a self-contained written document** (files, interfaces, out-of-scope, verification steps) — never
a conversation summary. The plan/spec is that artifact; `/harness-doctor` phase-checks it exists before
EXECUTE.

---

## 5. Main-window context control

The harness's file-based-state + `/handoff` + SessionStart-hook design is already on the winning side of
this debate (Amp *retired* compaction entirely in favor of handoff-to-fresh-thread; Anthropic's docs:
"a clean session with a better prompt almost always outperforms a long session with accumulated
corrections"; compaction preserves *what* but loses *why*). Changes are refinements:

1. **Make reset-over-compact explicit policy** in `workflow.md` + CLAUDE.md one-liner: at every task
   boundary (post-RECORD) or when context feels heavy → `/handoff` then `/clear`; treat `/compact` as
   the emergency mid-task tool only.
2. **`/work` RECORD phase ends by offering the reset**: after commit+tick, if the session has processed
   ≥1 full task, suggest `/handoff` + `/clear` before pulling the next item.
3. **Keep noisy output out of the main window structurally**: `/verify` already runs `context: fork`;
   fleet/loop logs stay in `.runs/`; explorer fan-out keeps file dumps in subagent contexts. That's what
   makes the main window last long enough that resets are cheap rather than constant.
4. SessionStart hook already rebuilds orientation from files — unchanged, it's the other half of the
   contract.

---

## Implementation order (one task per iteration, as ever)
1. `models` block: schema + config + settings.json `"model"` + agent frontmatter + doctor drift-check.
2. New `explorer` agent + fan-out wiring (PROMPT.md, planner.md, generator.md guidance).
3. Loop `--model` flags (main + reviewer sites, both ps1/sh) + tests.
4. `review-codex` lib (detect/invoke/watchdog/parse/fallback) + tests; wire into loop + `/review`.
5. Reviewer-prompt hardening (correctness-only) in loop prompt + reviewer.md.
6. Fresh-context tightening: generator-by-default in `/work`, plan-artifact contract in workflow.md.
7. Context-control policy edits (workflow.md, CLAUDE.md line, `/work` RECORD suggestion).
8. Phase A worktree isolation for generator + merge-back in `/work`.
9. Per-run `.checkpoint`/`.budget` relocation + run-id lock (prereq for fleet; fixes real bugs anyway).
10. Fleet runner Phase B (tasks.json ownership field → spawn → merge queue) + tests.

## Decision points for James
1. **Session default Opus:** writing `"model": "opus"` into project settings.json makes every session in
   a harness project start on Opus (you currently run Fable sessions — `/model` still overrides live).
   Confirm you want the hard default, or leave session unset and route only the phases.
2. **Codex model pinning:** float on codex's default (currently gpt-5.6-sol medium) with
   `reasoning_effort=high` [recommended], or pin (`gpt-5.6-terra` if API-key cost matters)?
3. **Codex auth mode:** ChatGPT-plan sign-in (plan rate limits, tracks best model) vs API key
   (`CODEX_API_KEY`, metered, ~$25–50/mo for a moderately active repo per CI datapoints)?
4. **Parallelism vehicle:** custom fleet runner (deterministic, budget/rollback/ledger preserved)
   [recommended] vs experimental native agent-teams? And confirm default `maxWorkers: 3`.
