# Acme Dashboard

A real-time analytics dashboard. *(Example root CLAUDE.md for a headless frontend + backend project —
this is what `/harness-init` produces. It stays a map, not a manual.)*

**Domain:** B2B SaaS analytics · **Type:** greenfield · **Shape:** headless — `frontend/` (Next.js +
TypeScript) talks to `backend/` (FastAPI + Python) over HTTP.

## Components
Each has its own stack and gate, run in its own directory — see `harness/harness.config.json` → `components`.

| Component | Path | Stack | Run | Test |
|-----------|------|-------|-----|------|
| frontend | `frontend/` | Next.js + TS (pnpm) | `pnpm run dev` | `pnpm test -- --run` |
| backend  | `backend/`  | FastAPI + Python (uv) | `uv run uvicorn app.main:app --reload` | `uv run pytest -q` |

Cross-cutting e2e: a Playwright run (`pnpm exec playwright test`) boots both and clicks through as a user.

## The map
- `specs/` — **immutable** requirements (the FE↔BE API contract lives here, e.g. `specs/020-api.md`).
- `frontend/CLAUDE.md`, `backend/CLAUDE.md` — each component's local map. Read the one you're in.
- `docs/architecture/` — how FE and BE fit together. `docs/principles/workflow.md` — the task lifecycle.
- `state/` — live work: `fix_plan.md`, `tasks.json`, `PROGRESS.md`, `handoff.md`, `evidence/`.
- `AGENT_NOTES.md` — operational gotchas; append when you learn one.

## How to work
One task per iteration — the top unchecked item in `state/fix_plan.md`; note its **component** and work
in that directory. Done = that component's full gate **and** the root e2e pass, plus end-to-end
evidence under `state/evidence/`. Commit when green; roll back a red tree. At task boundaries prefer
`/handoff` then `/clear` over `/compact`.

## Guardrails
- Never weaken or delete a test to go green.
- Never edit `specs/` (the FE↔BE contract is law) — propose changes to the human.
- Escalate ambiguous product decisions instead of guessing.
- Review in a fresh context (`/review`) — the doer is not the judge.
- Destructive commands are hook-blocked; don't route around the hooks.

## Project rules (the ratchet — grows only from real failures)
<!-- Add via /ratchet. e.g. "- [2026-07-01] FE must call BE via the typed api client, not raw fetch — because a hand-rolled fetch skipped auth headers and 401'd in prod." -->
