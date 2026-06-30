---
description: Decompose intent into specs + a prioritized, one-task-at-a-time plan and JSON manifest.
argument-hint: "<what you want built or fixed>"
allowed-tools: Read, Write, Edit, Glob, Grep, Agent, AskUserQuestion, Skill, WebSearch
---

# /plan — turn intent into an executable plan

Goal: $ARGUMENTS

You are the **planner**. Expand the human's intent into a plan the loop can execute one item at a
time. Be ambitious about scope but precise about decomposition. Do **not** write feature code here.

## Do this
1. **Study first.** Read `CLAUDE.md`, relevant `specs/`, `docs/architecture/`, and existing code.
   Search before assuming something doesn't exist.
2. **Clarify the why, not just the what.** If the outcome or acceptance criteria are ambiguous, ask
   (AskUserQuestion). Capture *why* this matters — the next amnesiac loop needs it.
3. **Update the source of truth.** If this introduces or changes requirements, write/extend a spec in
   `specs/` (e.g. `specs/NNN-<slug>.md`) with concrete, testable acceptance criteria — prefer
   executable ones ("startup < 800ms", "endpoint returns 200 with schema X", "reproduce bug, verify fix").
4. **Decompose into small, independently-shippable items.** Each item = one loop iteration's worth of
   work, fully implementable (no "and also…"). Order by priority and dependency.
5. **Write the plan to `state/fix_plan.md`** as a checkbox list, highest priority first. Each item:
   `- [ ] <imperative task>  — done when: <verifiable condition>`
6. **Mirror into `state/tasks.json`** (the machine-readable manifest) using the v2 schema already there.
   Each item is one object with **every** field populated: `id` (stable, e.g. `AUTH-001`), `category`,
   `component` (which `config.components` entry it touches), `description`, `steps`, `acceptance`,
   `status: "todo"`, `evidence: ""`, `passes: false`. Enumerate granularly so the loop can't declare
   premature victory. Downstream (`/work`, the loop) edits only `status`, `evidence`, and `passes` —
   never `description`/`acceptance`. You set `status: "todo"` here and don't touch it again.
7. **Sprint contract (required for non-trivial work — it's a config gate).** The config gates EXECUTE on
   an agreed definition of done (`workflow.requireSprintContractBefore`, default `execute`). For
   non-trivial items, use the `sprint-contract` skill to agree it up front, or flag in the plan that each
   such item needs one before code — so the `/plan → /loop` path (no `/work` orchestrator) doesn't skip
   the gate. Trivial items may note "no contract needed".

## Output
A short summary: the spec(s) touched, the number of plan items, the first 3 the loop will tackle, and
any open questions you escalated. Then stop — execution is `/loop`'s job.
