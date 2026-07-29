---
description: Decompose intent into specs + a prioritized, one-task-at-a-time plan and JSON manifest.
argument-hint: "<what you want built or fixed>"
allowed-tools: Read, Write, Edit, Glob, Grep, Agent, AskUserQuestion, Skill, WebSearch
---

# /plan — turn intent into an executable plan

Goal: $ARGUMENTS

Expand the intent into a plan the loop can execute one item at a time. Ambitious about scope, precise
about decomposition. No feature code here.

1. **Study first** — `CLAUDE.md`, relevant `specs/`, `docs/architecture/`, the existing code.
2. **Clarify the why.** Ask (AskUserQuestion) when the outcome or acceptance criteria are ambiguous;
   capture *why* it matters for the amnesiac loops that follow.
3. **Update the source of truth** — new/changed requirements go in `specs/NNN-<slug>.md` with
   concrete, preferably executable acceptance criteria ("startup < 800ms", "endpoint returns 200 with
   schema X").
4. **Decompose** into small, independently-shippable items — each one loop iteration's worth, ordered
   by priority and dependency.
5. **Write `state/fix_plan.md`** — checkbox list, highest priority first:
   `- [ ] <imperative task> — done when: <verifiable condition>`
6. **Mirror into `state/tasks.json`** (v2 schema): every field populated — `id` (stable, e.g.
   `AUTH-001`), `category`, `component`, `description`, `steps`, `acceptance`, `files` (ownership —
   what lets the fleet parallelize), `status: "todo"`, `evidence: ""`, `passes: false`. Downstream
   edits only `status`/`evidence`/`passes`.
7. **Sprint contract** — for non-trivial items, agree one now (`sprint-contract` skill) or flag that
   the item needs one before code (`workflow.requireSprintContractBefore` is a gate the
   `/plan → /loop` path must not skip).

## Output
The spec(s) touched, the number of plan items, the first 3 the loop will tackle, and any escalated
questions. Then stop — execution is `/loop`'s job.
