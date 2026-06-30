<!--
  This is the ROOT CONTEXT MAP. It is a navigation map, not a manual.
  RULES FOR THIS FILE (the ratchet discipline):
    • Keep it under ~100 lines. It competes for the model's attention with the actual task.
    • Point to docs/ and nested CLAUDE.md files; do NOT inline full specs or style guides.
    • Every line in "Project rules" must trace to a real failure (added via /ratchet) or a hard
      constraint. Delete rules that no longer earn their place.
    • `/harness-init` fills the {{PLACEHOLDERS}} below. Until then they are intentionally blank.
-->

# {{PROJECT_NAME}}

{{ONE_LINE_DESCRIPTION}}

## What this is
- **Domain / market:** {{DOMAIN}}
- **Type:** {{PROJECT_TYPE}}  <!-- greenfield (build from scratch) | brownfield (existing code — respect it; see brownfield-safety skill) -->
- **Shape:** {{PROJECT_SHAPE}}  <!-- e.g. "single Node app" or "headless: frontend/ (Next.js) + backend/ (FastAPI)" -->

## Components (the buildable units)
Each component has its own stack, gate, and (for non-trivial ones) its own nested `CLAUDE.md`. The
harness runs each component's gate in its own directory; see `harness/harness.config.json` → `components`.

| Component | Path | Stack | Run | Test |
|-----------|------|-------|-----|------|
| {{COMPONENT_NAME}} | `{{COMPONENT_PATH}}` | {{COMPONENT_STACK}} | `{{COMPONENT_RUN}}` | `{{COMPONENT_TEST}}` |
<!-- one row per component; a single-root project has exactly one row with path `.` -->

Cross-cutting (e.g. an e2e that exercises the components together): {{ROOT_E2E}}

## Where things live (the map)
- `specs/` — **immutable** requirements. Source of truth. Read first; never rewrite.
- `docs/architecture/` — how the system fits together. Read before structural changes.
- `docs/design-docs/` — decisions already made and *why*. Don't relitigate them.
- `docs/execution-plans/` — versioned plans + progress logs for in-flight work.
- `docs/technical-debt/` — known issues. Check before "discovering" one.
- `docs/principles/` — engineering norms / golden principles for this repo.
- `state/` — live work state: `tasks.json` (manifest), `fix_plan.md` (priority stack),
  `PROGRESS.md` (session log), `handoff.md` (context-reset handoff), `evidence/` (e2e proof per task).
- `AGENT_NOTES.md` — run/build gotchas and learnings. **Append here when you learn something.**

## How to work here (the workflow: plan → execute → validate → review → record)
Full contract: [`docs/principles/workflow.md`](docs/principles/workflow.md). `/work` drives one task
through all phases; `/plan`, `/loop`, `/verify`, `/review` are the phases run individually. In short:
1. **Study first.** Read the relevant `specs/`, then the code, then `state/fix_plan.md`. Note which
   **component** the task touches and work in that directory.
   **Search the codebase before assuming something isn't implemented.** Think hard.
2. **One task per iteration.** Pick the highest-priority unfinished item from `state/fix_plan.md`.
3. **Implement fully.** No placeholders, no stubs, no "simple version for now."
4. **Verify — this is the gate.** Run the changed component's gate (format → lint → typecheck → build →
   test) and the cross-cutting root gate.
   Unit-green is not done: capture **end-to-end evidence** that it works as a user would see it.
5. **Checkpoint.** Commit with a descriptive message when green. Roll back a red tree, don't patch over it.
6. **Record.** Tick the item in `state/fix_plan.md`; note *why* in code/docs for the next (amnesiac) loop.

## Verification gate (must pass before "done")
The gate is **per component** (its commands run in that component's directory), then a cross-cutting
root gate. Exact commands live in `harness/harness.config.json`. For `{{COMPONENT_NAME}}`:
```
{{FORMAT_COMMAND}}
{{LINT_COMMAND}}
{{TYPECHECK_COMMAND}}
{{BUILD_COMMAND}}
{{TEST_COMMAND}}
{{E2E_COMMAND}}
```
The PostToolUse hook runs the fast subset (format/lint/typecheck) automatically on edit, **routed to
the component that owns the changed file**. Failures come back with the fix in the message — read them.

## Guardrails (hard constraints)
- **Do not** weaken or delete tests to make a build pass. Fix the code or escalate.
- **Do not** run destructive commands (`rm -rf`, `git push --force`, `DROP TABLE`, secrets exfil).
  The PreToolUse hook blocks the obvious ones; don't try to route around it.
- **Do not** edit anything under `specs/` — it is the contract. Propose changes to the human instead.
- **Escalate ambiguous product decisions** to the human rather than guessing. Ask for the *why*.
- Review code in a **fresh context** (use `/review` or the `reviewer` subagent), never self-grade.

## Project rules (the ratchet — grows only from real failures)
<!-- Add entries via /ratchet. Format: "- [YYYY-MM-DD] <rule>  — because <the failure it prevents>" -->
{{RATCHET_RULES}}

## Nested context
Larger subsystems may have their own `CLAUDE.md` next to their code (mirrors the one-map-per-package
pattern). When working in a subsystem, read its local map too.
