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
- **Stack:** {{STACK_SUMMARY}}  (full profile: `harness/profiles/{{STACK_PROFILE}}.json`)
- **Run it:** `{{RUN_COMMAND}}`  ·  **Build:** `{{BUILD_COMMAND}}`  ·  **Test:** `{{TEST_COMMAND}}`
- **Entry points:** {{ENTRY_POINTS}}

## Where things live (the map)
- `specs/` — **immutable** requirements. Source of truth. Read first; never rewrite.
- `docs/architecture/` — how the system fits together. Read before structural changes.
- `docs/design-docs/` — decisions already made and *why*. Don't relitigate them.
- `docs/execution-plans/` — versioned plans + progress logs for in-flight work.
- `docs/technical-debt/` — known issues. Check before "discovering" one.
- `docs/principles/` — engineering norms / golden principles for this repo.
- `state/` — live work state: `tasks.json` (manifest), `fix_plan.md` (priority stack),
  `PROGRESS.md` (session log), `handoff.md` (context-reset handoff).
- `AGENT_NOTES.md` — run/build gotchas and learnings. **Append here when you learn something.**

## How to work here (the loop contract)
1. **Study first.** Read the relevant `specs/`, then the code, then `state/fix_plan.md`.
   **Search the codebase before assuming something isn't implemented.** Think hard.
2. **One task per iteration.** Pick the highest-priority unfinished item from `state/fix_plan.md`.
3. **Implement fully.** No placeholders, no stubs, no "simple version for now."
4. **Verify — this is the gate.** Run format → lint → typecheck → tests for the changed unit.
   Unit-green is not done: capture **end-to-end evidence** that it works as a user would see it.
5. **Checkpoint.** Commit with a descriptive message when green. Roll back a red tree, don't patch over it.
6. **Record.** Tick the item in `state/fix_plan.md`; note *why* in code/docs for the next (amnesiac) loop.

## Verification gate (must pass before "done")
```
{{FORMAT_COMMAND}}
{{LINT_COMMAND}}
{{TYPECHECK_COMMAND}}
{{TEST_COMMAND}}
{{E2E_COMMAND}}
```
Hooks run the fast subset automatically on edit (see `.claude/settings.json`). Failures come back
with the fix in the message — read them.

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
