# The workflow: plan → execute → validate → review → record

Every task moves through an explicit lifecycle — the Planner / Generator / Evaluator pattern
(separate the doer from the judge) made concrete as phases with a gate between each. `/work`
orchestrates all phases with checkpoints; `/plan`, `/verify`, `/review` run phases individually;
`/loop` runs one full iteration (study→implement→verify→record) — the same unit the unattended loop
repeats. Each task in `state/tasks.json` carries a `status` along the lifecycle:

```
 todo ──plan──▶ planned ──execute──▶ in_progress ──validate──▶ validated ──review──▶ reviewed ──record──▶ done
   │                                                                                                        ▲
   └──────────────────────────────── (a failed phase sends it back, never forward) ───────────────────────┘
```

**Supervised** mode pauses at each phase boundary (`workflow.checkpointBetweenPhases`); **auto** mode
flows through, held only by the exit gates.

## PLAN (`/plan` / the `planner`)
Intent → spec + granular tasks. **Exit gate:** falsifiable, preferably executable acceptance criteria;
for non-trivial work an agreed **sprint contract** (`workflow.requireSprintContractBefore`).
**Status:** `todo → planned` — made per task by `/work` as it picks each up (bulk `/plan` seeds the
manifest at `todo`; on the `/plan → /loop` path tasks jump `todo → validated`).

## EXECUTE (the `generator` / the implement step of `/loop`)
One task, implemented fully. The generator is a **fresh context by design** — it reads the plan
artifact, not the planning conversation, so the artifact must carry everything across the boundary
(files, interfaces, out-of-scope, verification). It runs in an **isolated worktree**; `/work` merges
back before VALIDATE. **Exit gate:** change complete, fast gate clean. **Status:** `planned → in_progress`.

## VALIDATE (`/verify`)
The **full** gate for affected component(s) + the root gate, then **end-to-end evidence**
(`e2e-evidence` skill) — unit-green is not done. **Exit gate:** all steps pass and evidence maps to
the acceptance criteria; red sends the task back to EXECUTE. **Status:** `in_progress → validated`.

## REVIEW (`/review` / the `reviewer`, fresh context)
An independent judge reviews the diff against the spec. The `reviewer` runs **always** (cheap,
diff-scoped: ship / fix-then-ship / reject vs specs + guardrails + principles). Every finding is
classified **blocker / should-fix / nit**; only blockers (spec violation, broken interface contract,
data loss, security hole, failing test) gate the verdict — should-fixes and nits are logged, never
re-cycled. Fix→re-review rounds carry the prior findings + resolutions forward and scope to the fix
delta + a regression check; they are **capped at 3** as a circuit breaker — hitting the cap escalates
the still-contested points to a human (`state/handoff.md`) instead of shipping. High-blast-radius
work (payments, auth, migrations, irreversible data ops) is uncapped. The `evaluator` is
**opt-in** (`verification.evaluator.enabled`) for quality-sensitive sprints: it scores each criterion
against `evaluator-rubric.md` with a hard `failBelow` threshold — any miss fails the sprint.
**Exit gate** (`workflow.requireReviewBefore`): verdict *ship* (zero blockers), guardrails intact.
**Status:** `validated → reviewed`.

## RECORD (commit + state)
The *why* into code/docs; learnings into `AGENT_NOTES.md`; tick `state/fix_plan.md`; `status:"done"`,
`passes:true` in `state/tasks.json`; a `state/PROGRESS.md` line; commit (+tag) green.
**Status:** `reviewed → done`.

## Context hygiene (the main window)
The phases protect their own contexts (subagents, `/verify` forks) but the orchestrating window
accumulates. Policy: **reset over compact** — at a task boundary run `/handoff` then `/clear`; state
lives in files and the SessionStart hook re-orients the fresh window. Compaction quietly loses the
*why*; treat `/compact` as the mid-task emergency tool only.

## Mapping to autonomy
- **Supervised:** `/work` runs one task through all phases, pausing at each checkpoint.
- **Auto / unattended:** `harness/loop.ps1` (or `.sh`) runs `PROMPT.md`, one task per iteration,
  rolling back any iteration that fails the gate.
