# 000 — Acme Dashboard (project overview)

> Illustrative stub for the worked example, showing the `NNN-<slug>.md` convention: every project's
> specs start at `000-overview.md`, the fixed reference point a memory-less loop orients from.

- Status: illustrative
- Owner: example

## What this is
A real-time analytics dashboard for B2B SaaS teams: users sign in, pick a time range, and watch their
product metrics update live. Two components, one contract:

- **`frontend/`** — Next.js + TypeScript web client; renders the dashboard, calls the backend only
  through the typed client in `frontend/lib/api/`.
- **`backend/`** — FastAPI + Python service; owns the data and serves the metrics HTTP API.

The FE↔BE API contract lives in [`020-api.md`](./020-api.md) — the single source of truth for both sides.

## Acceptance criteria (project-level)
- [ ] A user can load the dashboard and see a metric series for a chosen range (7d/30d) from a live backend.
- [ ] Every FE↔BE request/response conforms to `020-api.md`; contract changes land in the spec first.
- [ ] The cross-cutting Playwright e2e (`pnpm exec playwright test`) passes against both running components.
