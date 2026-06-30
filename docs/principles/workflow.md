# The workflow: plan → execute → validate → review → record

The harness drives every task through an explicit lifecycle. This is the Planner / Generator /
Evaluator pattern (separate the doer from the judge) made concrete as phases with a gate between each.
`/work` orchestrates the phases with a checkpoint between each; `/plan`, `/verify`, and `/review` are
individual phases you can also run by hand. `/loop` is different — it runs one **full** iteration
(study→implement→verify→record) in a single supervised pass, the same unit the unattended loop repeats.

Each task in `state/tasks.json` carries a **`status`** that advances along the lifecycle, so work is
resumable and glanceable:

```
 todo ──plan──▶ planned ──execute──▶ in_progress ──validate──▶ validated ──review──▶ reviewed ──record──▶ done
   │                                                                                                        ▲
   └──────────────────────────────── (a failed phase sends it back, never forward) ───────────────────────┘
```

In **supervised** mode the workflow pauses at the checkpoint between phases (config
`workflow.checkpointBetweenPhases`); in **auto** mode it flows straight through, held only by the phase
exit-gates below.

## Phase 1 — PLAN  (`/plan`, or the `planner` subagent)
Turn intent into a spec and a granular task. Define **executable acceptance criteria** and, for
non-trivial work, a **sprint contract** (agreed definition of done) *before any code*.
- **Exit gate:** the task has a spec with falsifiable acceptance criteria; if
  `workflow.requireSprintContractBefore` applies, a sprint contract exists and is agreed.
- **Status:** `todo → planned`. Note the split: bulk `/plan` *seeds* the whole manifest at `todo`
  (it doesn't pre-commit to an order of execution); the `todo → planned` transition is made **per task
  by `/work`'s PLAN phase** as it picks each one up. On the standalone `/plan → /loop` path there is no
  orchestrator, so tasks stay at `todo` until `/loop` advances the one it works to `validated`.

## Phase 2 — EXECUTE  (the `generator` subagent; or the implement step of `/loop`)
Implement **one** task, **fully** — no placeholders. Search before assuming. Edits trigger the fast
component gate automatically (format/lint/typecheck via the PostToolUse hook).
- **Exit gate:** the change is complete and the fast gate is clean.
- **Status:** `planned → in_progress`.

## Phase 3 — VALIDATE  (`/verify`)
Run the **full** gate for the affected component(s) + the cross-cutting root gate, then capture
**end-to-end evidence** (the `e2e-evidence` skill). Unit-green is not done.
- **Exit gate:** every gate step passes **and** e2e evidence exists that maps to the acceptance
  criteria. A red gate sends the task back to EXECUTE (and the loop rolls the tree back).
- **Status:** `in_progress → validated`.

## Phase 4 — REVIEW  (`/review` / the `reviewer` subagent, **fresh context**)
An independent agent judges the diff against the spec — reasoning from the change, not from the
conversation that produced it. Optionally the skeptical `evaluator` scores it against the rubric's hard
thresholds.

> **`reviewer` vs `evaluator` — when to use which.** The `reviewer` runs **always**: it's cheap,
> diff-scoped, and returns ship / fix-then-ship / reject against specs + guardrails + principles. The
> `evaluator` is **opt-in** (`verification.evaluator.enabled`) and only earns its cost on
> quality-sensitive sprints: it scores each acceptance criterion against `evaluator-rubric.md` with a
> hard numeric `failBelow` threshold (any miss fails the sprint). Reviewer = "is this correct and safe?";
> evaluator = "does this clear the quality bar we agreed, criterion by criterion?"
- **Exit gate (if `workflow.requireReviewBefore` = done):** verdict is *ship*; guardrails intact (no
  weakened tests, no edited specs, no destructive ops). *Reject* / *fix-then-ship* sends it back.
- **Status:** `validated → reviewed`.

## Phase 5 — RECORD  (commit + state)
Capture the *why* in code/docs; append learnings to `AGENT_NOTES.md`; tick the item in
`state/fix_plan.md`; set `passes:true`/`status:"done"` in `state/tasks.json`; add a `state/PROGRESS.md`
line; commit (and tag) with the tree green.
- **Status:** `reviewed → done`.

## Why these gates between phases
Every phase boundary is a sensor: planning without acceptance criteria produces unverifiable work;
executing without a contract invites scope drift; "done" without validation ships unit-green-but-broken
changes; merging without a fresh-context review lets the author grade their own homework. The gates are
cheap insurance against the failure modes each phase is prone to.

## Mapping to autonomy
- **Supervised:** `/work` runs one task through all phases, pausing at each checkpoint for your 👍.
- **Auto / unattended:** `harness/loop.ps1` (or `loop.sh`) runs PROMPT.md, whose phases mirror this
  lifecycle, one task per iteration, rolling back any iteration that fails the validate gate.
