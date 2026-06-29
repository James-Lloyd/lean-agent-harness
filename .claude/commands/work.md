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

## Phase 1 — PLAN
- Resolve the target task (from $ARGUMENTS or top of `fix_plan.md`). If it lacks a spec with
  **executable acceptance criteria**, create/extend one in `specs/` (delegate to the `planner`
  subagent for non-trivial work). For non-trivial work, agree a **sprint contract** (`sprint-contract`
  skill) before any code — that's the exit gate (`workflow.requireSprintContractBefore`).
- Identify which **component(s)** the task touches (from `config.components`); the gate and edits will
  be scoped to those directories.
- Set task `status: "planned"`. **Checkpoint.**

## Phase 2 — EXECUTE
- Delegate implementation to the `generator` subagent (or do it directly): implement the one task
  **fully**, no placeholders. Search before assuming. Work within the owning component's directory; the
  PostToolUse hook runs that component's fast gate (format/lint/typecheck) as you edit.
- Set `status: "in_progress"`. **Checkpoint** (and pause before any risky op if `beforeRiskyOps`).

## Phase 3 — VALIDATE
- Run `/verify`: the full gate for the affected component(s) **and** the cross-cutting root gate, then
  capture **end-to-end evidence** (`e2e-evidence` skill) under `state/evidence/<task-id>/`.
- If red: send back to EXECUTE (fix; never weaken a test). If green + evidence maps to acceptance
  criteria: set `status: "validated"`. **Checkpoint.**

## Phase 4 — REVIEW (fresh context)
- Run `/review` — spawn the `reviewer` subagent so it judges the diff independently, not from this
  conversation. Optionally run the `evaluator` against the rubric if `verification.evaluator.enabled`.
- Verdict must be **ship** with guardrails intact (`workflow.requireReviewBefore`). *Reject* /
  *fix-then-ship* → back to EXECUTE with the findings. On ship: `status: "reviewed"`. **Checkpoint.**

## Phase 5 — RECORD
- Capture the *why* in code/docs; append learnings to `AGENT_NOTES.md`; tick the item in
  `state/fix_plan.md`; set `passes:true`, `status:"done"`, and the `evidence` path in
  `state/tasks.json`; add a `state/PROGRESS.md` line; commit (+tag) with the tree green.

## Output
A phase-by-phase summary: the task, the spec/contract, what shipped, the evidence path, the review
verdict, and the commit. Then offer to `/work` the next task. Suggest a `/ratchet` rule for any failure
class you hit along the way.
