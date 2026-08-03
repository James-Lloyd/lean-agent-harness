---
description: Orchestrate one task end-to-end through plan → execute → validate → review → record, with phase checkpoints.
argument-hint: (optional) "<task id or a short description of what to work on>"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion, Skill
---

# /work — drive one task through the full workflow

Target: $ARGUMENTS (default: the top unchecked item in `state/fix_plan.md`)

You are the **orchestrator**. Take ONE task from `todo` to `done` through the five phases, separating
the doer from the judge. Honor `harness/harness.config.json` → `workflow` and `autonomy`; the phase
contract is [`docs/principles/workflow.md`](../../docs/principles/workflow.md).

> In **supervised** mode (and when `workflow.checkpointBetweenPhases`), pause after each phase, report
> in 2–3 lines, and get a 👍 before the next. In **auto** mode, flow through, stopping only on a failed
> exit gate or an ambiguous product decision (escalate to `state/handoff.md`).

## Model routing per phase — resolve, then route (cross-vendor)
Each phase maps to a `config.models.<phase>` entry (`planner`→`plan`, `generator`→`implement`,
`reviewer`→`review`, `explorer`→`explore`, `evaluator`→`evaluate`), whose `model`/`fallback` is a
Claude alias/ID **or** the literal `codex`. Before running a phase, resolve `{model, fallback}` from
the config (readable directly, or via the engine lib resolvers — bash `phase_model <config-path>
<phase>` / PS `Resolve-PhaseModel $cfg '<phase>'` in `${CLAUDE_PLUGIN_ROOT}/engine/lib/gate.*`), then:
- **Claude primary** (or null = session model) → spawn the phase's subagent, pinned via the Agent
  `model:` override. If it dies on a usage/limit cap: a Claude fallback → re-spawn with that override;
  a `codex` fallback → dispatch the codex lib.
- **`codex` primary** → do NOT spawn the subagent; invoke the codex lib via Bash in the phase's mode
  (**workspace-write** for plan/execute, **read-only** for review/evaluate). Prefer the dispatcher
  (`Invoke-Phase` / `invoke_phase` from `engine/lib/dispatch.*`) — it retries once on the Claude
  fallback for free. bash: call `invoke_phase` directly, never in `$(...)` (subshell drops its return
  globals). No subagent ever wraps codex.

With the default config only **implement** has a codex primary: EXECUTE dispatches the codex lib
workspace-write and spawns `generator` only on the Claude fallback; PLAN and REVIEW spawn their Claude
subagents. Subagent frontmatter carries each phase's Claude model (generator's = implement's Claude
*fallback*); `/harness-doctor` check 10 validates that.

## Phase 0 — PROJECT TYPE
- `config.project.type` = **brownfield** → load the `brownfield-safety` skill, confirm the baseline is
  green (`project.baseline.established`; else run `/onboard` first), isolate on a branch, and write a
  characterization test before changing untested behaviour. Greenfield skips to Phase 1.

## Phase 1 — PLAN
- Resolve the target task. If it lacks a spec with **executable acceptance criteria**, create one in
  `specs/` (delegate non-trivial work to the `planner`, routed per the table above). For non-trivial
  work, agree a **sprint contract** (`sprint-contract` skill) before code — the exit gate
  (`workflow.requireSprintContractBefore`).
- The plan artifact must be **self-contained** (files, interfaces, out-of-scope, verification) —
  EXECUTE starts from a fresh context that reads only the artifact, never this conversation.
- Note the affected **component(s)**; set `status: "planned"`. **Checkpoint.**

## Phase 2 — EXECUTE (fresh context, isolated tree)
- Delegate to the `generator` subagent — the default, not an option (the builder reads the written
  plan, not the planning chat). Implement inline only for a trivial single-file fix with no new
  behavior. Route per the table above.
- The generator works in an isolated worktree and returns with the gate green and evidence captured,
  uncommitted; recording is Phase 5, yours.
- **Verify the worktree's base before merging.** A worktree can come up on an *ancestor* of `main`.
  If its base ≠ `git rev-parse HEAD`, do not merge blind: for every file it touched, confirm the file
  is unchanged between base and tip (`git diff --quiet <base> HEAD -- <file>`). All identical ⇒ the
  squash applies exactly the agent's diff. Any differ ⇒ the build sat on stale content: rebase and
  re-verify, or rebuild — never squash a stale-base change over a moved file. (Recurred twice.)
- **Merge back:** commit in the worktree, `git merge --squash <branch>` in the main tree (lands
  staged-but-uncommitted — what VALIDATE wants), then remove the worktree and branch. A merge
  conflict means the main tree moved mid-build: resolve consciously against the task's intent, or
  send back — never auto-resolve.
- Set `status: "in_progress"`. **Checkpoint** (pause before risky ops if `beforeRiskyOps`).

## Phase 3 — VALIDATE
- Run `/verify`: the full component gate(s) + the root gate, and capture **end-to-end evidence**
  under `state/evidence/<task-id>/`.
- Red → back to EXECUTE (never weaken a test). Green + evidence maps to the acceptance criteria →
  `status: "validated"`. **Checkpoint.**

## Phase 4 — REVIEW (fresh context)
- Run `/review`, routed per the table above. Optionally run the `evaluator` (read-only) against the
  rubric if `verification.evaluator.enabled`.
- Verdict must be **ship** with guardrails intact (`workflow.requireReviewBefore`). The verdict gates
  on **blockers only** — spec violation, broken interface contract, data loss, security hole, failing
  test (`/review` classifies every finding blocker/should-fix/nit). Should-fixes and nits are logged
  with the task record; they never trigger another cycle.
- *Reject* / *fix-then-ship* (open blockers) → back to EXECUTE with the findings. Each later round
  hands the reviewer the prior findings **and their resolutions**, scoped to the fix delta plus a
  regression check — a fresh judge re-litigating settled points is what makes round 4 exist.
- **Cap: 3 rounds** — a circuit breaker, not a quality target. Hitting it is an escalation signal,
  not a ship signal: have the reviewer write up what is still contested to `state/handoff.md`
  (Needs human decision) and stop — the write-up usually reveals the spec was ambiguous, which is
  the real fix. Exception: high-blast-radius changes (payments, auth, migrations, irreversible data
  ops) are uncapped — let the rounds run.
- On ship: `status: "reviewed"`. **Checkpoint.**

## Phase 5 — RECORD
- Capture the *why* in code/docs; append learnings to `AGENT_NOTES.md`; tick `state/fix_plan.md`; set
  `passes: true`, `status: "done"`, and the `evidence` path in `state/tasks.json`; add a
  `state/PROGRESS.md` line; commit (+tag) with the tree green.
- **Then offer the reset:** suggest `/handoff` + `/clear` before the next task (see workflow.md →
  Context hygiene).

## Output
A phase-by-phase summary: the task, the spec/contract, what shipped, the evidence path, the review
verdict, the commit. Offer to `/work` the next task; suggest a `/ratchet` rule for any failure class
you hit.
