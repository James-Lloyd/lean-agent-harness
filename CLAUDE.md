<!--
  ROOT CONTEXT MAP — a navigation map, not a manual. Keep it under ~100 lines (shorter is better —
  the shipped map is ~60): every line competes with the task for attention. Point to docs/ and nested CLAUDE.md files; never inline specs or
  style guides. Ratchet rules only from real failures (/ratchet) — delete rules that stop earning
  their place. /harness-init fills the {{PLACEHOLDERS}}.
-->

# {{PROJECT_NAME}}

{{ONE_LINE_DESCRIPTION}}

**Domain:** {{DOMAIN}} · **Type:** {{PROJECT_TYPE}} · **Shape:** {{PROJECT_SHAPE}}

## Components
Each has its own stack and gate, run in its own directory — see `harness/harness.config.json` → `components`.

| Component | Path | Stack | Run | Test |
|-----------|------|-------|-----|------|
| {{COMPONENT_NAME}} | `{{COMPONENT_PATH}}` | {{COMPONENT_STACK}} | `{{COMPONENT_RUN}}` | `{{COMPONENT_TEST}}` |

Cross-cutting e2e: {{ROOT_E2E}}

## The map
- `specs/` — **immutable** requirements; the contract.
- `docs/architecture/` + `docs/design-docs/` — how it fits together, and decisions already made (with the why).
- `docs/principles/workflow.md` — the task lifecycle (plan → execute → validate → review → record)
  that `/work`, `/plan`, `/verify`, `/review`, `/loop` drive.
- `state/` — live work: `fix_plan.md` (priority stack), `tasks.json` (manifest), `PROGRESS.md`,
  `handoff.md`, `evidence/`.
- `AGENT_NOTES.md` — operational gotchas. Append when you learn one.

## How to work
One task per iteration — the top unchecked item in `state/fix_plan.md`. A task is done when the
changed component's full gate **and** the root gate pass (commands in `harness/harness.config.json`)
and end-to-end evidence of the user-visible behavior exists under `state/evidence/` — unit-green
alone is not done. Commit when green (exception: in the headless loop the runner commits —
PROMPT.md wins there); roll back a red tree rather than patching over it. At task boundaries prefer
`/handoff` then `/clear` over `/compact` — state lives in files.

## Guardrails
- Never weaken or delete a test to go green. Fix the code or escalate.
- Never edit `specs/`. Propose changes to the human (`/plan`, `/onboard`, `/harness-init` may author
  *new* specs with approval).
- Escalate ambiguous product decisions instead of guessing.
- Review in a fresh context (`/review` / the `reviewer` subagent) — the doer is not the judge.
- Destructive commands are hook-blocked; don't route around the hooks.

## Project rules (the ratchet — grows only from real failures)
<!-- Add via /ratchet: "- [YYYY-MM-DD] <rule> — because <the failure it prevents>" -->
- [2026-07-14] A fresh-context judge subagent that dies on its model's usage cap gets re-spawned with
  a `model:` override; `review`/`evaluate` carry an `opus` fallback in config for the headless path.
- [2026-07-26] When correcting a stale fact (path, count, field name) in any prompt surface, grep the
  whole repo for it before closing — it recurs in sibling surfaces.
- [2026-07-29] An edit to engine comment/behavior lands in BOTH `.ps1`/`.sh` twins in the same change —
  grep the sibling for the exact phrase (loop.sh got de-phased wording; loop.ps1 kept "Phase 3").
- [2026-07-29] Before deleting a doc/comment block, grep for inbound pointers and rehome the content or
  fix the pointer in the same change — a pointer into deleted content is worse than the verbosity.

## Nested context
Subsystems carry their own `CLAUDE.md` next to their code (in this repo: `plugin/engine/` holds the
engine's PS-5.1/twin-parity rules). When working in a subsystem, its local map applies too.
