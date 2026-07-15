---
description: Orchestrate one task end-to-end through plan → execute → validate → review → record, with phase checkpoints.
argument-hint: (optional) "<task id or a short description of what to work on>"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion, Skill
---

# /work — drive one task through the full workflow

Target: $ARGUMENTS (default: the top unchecked item in `state/fix_plan.md`)

You are the **orchestrator**. Take ONE task from `todo` to `done` through the five phases, separating
the doer from the judge at each step. Honor `harness/harness.config.json` → `workflow` and `autonomy`.
Read [`docs/principles/workflow.md`](../../docs/principles/workflow.md) for the phase contract.

> In **supervised** mode (and when `workflow.checkpointBetweenPhases`), pause after each phase, report
> in 2–3 lines, and get a 👍 before the next. In **auto** mode, flow through, stopping only if a phase's
> exit gate fails or an ambiguous product decision appears (then escalate to `state/handoff.md`).

## Model routing per phase — resolve, then route (cross-vendor)
Each phase below spawns a Claude subagent **and** maps to a `config.models.<phase>` entry (`planner`→
`plan`, `generator`→`implement`, `reviewer`→`review`; `explorer`→`explore`, `evaluator`→`evaluate`). A
phase's `model`/`fallback` may be a **Claude** alias/ID **or** the literal **`codex`** (the OpenAI Codex
CLI). A Claude subagent cannot *become* codex, so before running a phase you **resolve, then route** (this
is the interactive twin of the headless `Invoke-Phase` dispatcher the loop/fleet use — decision A):

1. **Resolve** the phase's `{primary, fallback}` from `config.models.<phase>` (tolerant of the legacy flat
   `"phase":"alias"` form). Either read `config.models.<phase>.model`/`.fallback` directly, or source the
   resolver — in this repo the engine libs live under `harness/lib/` (a deployed project sources them from
   its installed plugin engine dir):
   ```bash
   . harness/lib/gate.sh   # bash resolvers take the config FILE PATH ($1) — jq opens it:
   #   phase_model harness/harness.config.json review ; phase_fallback harness/harness.config.json review
   # PowerShell resolvers take a PARSED object: . harness/lib/gate.ps1
   #   $cfg = Get-Content harness/harness.config.json -Raw | ConvertFrom-Json
   #   Resolve-PhaseModel $cfg 'review' ; Resolve-PhaseFallback $cfg 'review'
   ```
2. **Primary is a Claude model** (or `null` = inherit the session model) → spawn the phase's subagent as
   today, pinned to that model via the Agent `model:` override (the frontmatter already carries it as the
   default). If the subagent dies on a **usage/limit** cap and the phase has a `fallback`: a `codex`
   fallback → dispatch the codex lib (step 3); a Claude fallback → re-spawn the subagent with that `model:`
   override (CLAUDE.md ratchet: a fresh-context judge that hits its own cap is re-spawned with an override).
3. **Primary is `codex`** → do **NOT** spawn the subagent. Invoke the codex lib via a **Bash tool call**
   instead, in the phase's **mode** (**workspace-write** for plan/execute — they mutate the tree;
   **read-only** for review/evaluate — a judge must never mutate what it judges). Prefer the whole
   dispatcher (`Invoke-Phase`/`invoke_phase`): it runs codex and, on codex-unavailable **or** a usage/limit
   error, retries once on the Claude `fallback` — giving you the fallback for free (that Claude arm runs
   headless `claude -p`, not the rich subagent; acceptable for a fallback). Use `Invoke-Codex`/`invoke_codex
   -Mode <mode>` for the codex arm alone.
   ```powershell
   . harness/lib/gate.ps1; . harness/lib/invoke-codex.ps1; . harness/lib/dispatch.ps1
   $cfg = Get-Content harness/harness.config.json -Raw | ConvertFrom-Json
   $r = Invoke-Phase -Mode read-only -Prompt $reviewPrompt -RepoRoot (Get-Location).Path `
                     -LogPath state/evidence/<id>/review.log `
                     -Primary (Resolve-PhaseModel $cfg 'review') -Fallback (Resolve-PhaseFallback $cfg 'review') `
                     -CodexCfg $cfg.models.codex
   # read $r.Ok / $r.Output / $r.Path (vendor that ran) / $r.UsedFallback
   ```
   In bash, call `invoke_phase` **directly, never in `$(...)`** — a subshell drops its `INVOKE_PHASE_*`
   return globals. **No subagent ever wraps codex.**

With the **current default config**, only **review** routes to codex as its primary — so REVIEW dispatches
the codex lib read-only and spawns the `reviewer` subagent only on the Claude fallback; PLAN and EXECUTE run
their Claude subagents (execute's `codex` is a fallback only). Subagent frontmatter stays each phase's
**Claude** model — and `reviewer`'s is review's Claude *fallback* (since review's primary is codex);
`/harness-doctor` check 10 validates exactly that.

## Phase 0 — PROJECT TYPE (do this first)
- Check `harness/harness.config.json` → `project.type`. If **brownfield**: load the `brownfield-safety`
  skill, confirm the baseline is green (`project.baseline.established`; if not, run `/onboard` first),
  isolate the work on a branch, and plan a **characterization test before changing any untested
  behaviour**. Keep the scope small. (Greenfield skips straight to Phase 1.)

## Phase 1 — PLAN
- Resolve the target task (from $ARGUMENTS or top of `fix_plan.md`). If it lacks a spec with
  **executable acceptance criteria**, create/extend one in `specs/` (delegate to the `planner`
  subagent for non-trivial work — first resolve the `plan` phase model per **Model routing** above; if
  it is `codex`, dispatch the codex lib **workspace-write** instead of the planner). For non-trivial
  work, agree a **sprint contract** (`sprint-contract`
  skill) before any code — that's the exit gate (`workflow.requireSprintContractBefore`).
- The plan artifact must be **self-contained** — files/interfaces to touch, what's out of scope, how
  to verify — because EXECUTE starts from a fresh context that reads only the artifact, never this
  conversation's reasoning.
- Identify which **component(s)** the task touches (from `config.components`); the gate and edits will
  be scoped to those directories.
- Set task `status: "planned"`. **Checkpoint.**

## Phase 2 — EXECUTE (fresh context, isolated tree)
- Delegate implementation to the `generator` subagent — **the default, not an option**: the builder
  starts from the written plan in a fresh context (inheriting the planning conversation biases the
  build; the artifact, not the chat, is the contract). Implement inline only for a trivial,
  single-file fix with no new behavior. First resolve the `implement` phase model per **Model routing**
  above: by default its primary is Claude, so spawn the generator; on a usage/limit cap or a `codex`
  primary, dispatch the codex lib **workspace-write** instead of the subagent.
- The generator runs in an **isolated worktree** (`isolation: worktree` in its frontmatter), so a bad
  build can never dirty the main tree. It implements the one task **fully**, no placeholders, searches
  before assuming, works within the owning component's directory (the PostToolUse hook runs that
  component's fast gate as it edits), and returns with the gate green and evidence captured — but does
  **not** tick `fix_plan.md` or commit. Recording is Phase 5, and it's yours.
- **Merge back** (when the generator ran isolated): commit its worktree
  (`git -C <worktree> add -A && git -C <worktree> commit`), then `git merge --squash <its-branch>`
  in the main tree — the changes land staged-but-uncommitted, exactly what VALIDATE wants. Then
  `git worktree remove <worktree>` and delete the branch. A merge conflict means the main tree moved
  mid-build: resolve it consciously against the task's intent, or send back — never auto-resolve.
- Set `status: "in_progress"`. **Checkpoint** (and pause before any risky op if `beforeRiskyOps`).

## Phase 3 — VALIDATE
- Run `/verify`: the full gate for the affected component(s) **and** the cross-cutting root gate, then
  capture **end-to-end evidence** (`e2e-evidence` skill) under `state/evidence/<task-id>/`.
- If red: send back to EXECUTE (fix; never weaken a test). If green + evidence maps to acceptance
  criteria: set `status: "validated"`. **Checkpoint.**

## Phase 4 — REVIEW (fresh context)
- Run `/review` — resolve the `review` phase model per **Model routing** above. By default its primary
  is `codex`, so dispatch the codex lib **read-only** via Bash and spawn the `reviewer` subagent only on
  the Claude fallback; when the primary is a Claude model, spawn the `reviewer` so it judges the diff
  independently, not from this conversation. Optionally run the `evaluator` (read-only) against the
  rubric if `verification.evaluator.enabled`.
- Verdict must be **ship** with guardrails intact (`workflow.requireReviewBefore`). *Reject* /
  *fix-then-ship* → back to EXECUTE with the findings. On ship: `status: "reviewed"`. **Checkpoint.**

## Phase 5 — RECORD
- Capture the *why* in code/docs; append learnings to `AGENT_NOTES.md`; tick the item in
  `state/fix_plan.md`; set `passes:true`, `status:"done"`, and the `evidence` path in
  `state/tasks.json`; add a `state/PROGRESS.md` line; commit (+tag) with the tree green.
- **Then offer the reset:** after a completed task, suggest `/handoff` + `/clear` before pulling the
  next item — a clean window seeded from the handoff beats a long one with accumulated corrections
  (`/compact` is the mid-task emergency tool, not the routine; see workflow.md → Context hygiene).

## Output
A phase-by-phase summary: the task, the spec/contract, what shipped, the evidence path, the review
verdict, and the commit. Then offer to `/work` the next task. Suggest a `/ratchet` rule for any failure
class you hit along the way.
