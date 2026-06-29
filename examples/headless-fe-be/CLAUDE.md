# Acme Dashboard

A real-time analytics dashboard. *(Example root CLAUDE.md for a headless frontend + backend project —
this is what `/harness-init` produces. It stays a map, not a manual.)*

## What this is
- **Domain / market:** B2B SaaS analytics.
- **Shape:** headless — `frontend/` (Next.js + TypeScript) talks to `backend/` (FastAPI + Python) over HTTP.

## Components (the buildable units)
Each has its own stack, gate, and nested `CLAUDE.md`. The harness runs each gate in its own directory;
see `harness/harness.config.json` → `components`.

| Component | Path | Stack | Run | Test |
|-----------|------|-------|-----|------|
| frontend | `frontend/` | Next.js + TS (pnpm) | `pnpm run dev` | `pnpm test` |
| backend  | `backend/`  | FastAPI + Python (uv) | `uv run uvicorn app.main:app --reload` | `uv run pytest` |

Cross-cutting: a Playwright e2e (`pnpm exec playwright test`) boots both and clicks through as a user.

## Where things live (the map)
- `specs/` — immutable requirements (the FE↔BE API contract lives here, e.g. `specs/020-api.md`).
- `frontend/CLAUDE.md`, `backend/CLAUDE.md` — each component's local map. Read the one you're working in.
- `docs/architecture/` — how FE and BE fit together. `state/` — live work (fix_plan, tasks, progress).

## How to work here (plan → execute → validate → review → record)
Full contract: `docs/principles/workflow.md`. In short: study the spec → pick ONE task and note its
**component** → work in that directory → run that component's gate, then the root e2e → capture
end-to-end evidence → fresh-context review → commit green. One task per iteration.

## Verification gate (must pass before "done")
Per component (run in its directory), then the cross-cutting root e2e. Exact commands in
`harness/harness.config.json`. Editing a file auto-runs the owning component's fast checks.

## Guardrails (hard constraints)
- Don't weaken/delete tests to go green. Don't edit `specs/` (the FE↔BE contract is law). Don't run
  destructive commands. Escalate ambiguous product calls. Review in a fresh context, never self-grade.

## Project rules (the ratchet — grows only from real failures)
<!-- Add via /ratchet. e.g. "- [2026-07-01] FE must call BE via the typed api client, not raw fetch — because a hand-rolled fetch skipped auth headers and 401'd in prod." -->
