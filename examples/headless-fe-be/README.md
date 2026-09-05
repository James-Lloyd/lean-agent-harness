# Example: headless frontend + backend

A worked example of the harness configured for a **headless** project — one repo root containing two
sub-repos with different stacks:

```
acme-dashboard/
├── AGENTS.md                 # root map → points at both components  (see ./AGENTS.md)
├── CLAUDE.md                 # `@AGENTS.md` — Claude Code reads the map through this import
├── harness/                  # ONE harness governs the whole project
├── specs/                    # shared, immutable — incl. the FE↔BE API contract
├── frontend/                 # component: Next.js + TypeScript (pnpm)
│   ├── package.json
│   ├── AGENTS.md             # component's local map  (see ./frontend/AGENTS.md)
│   └── CLAUDE.md             # `@AGENTS.md`
└── backend/                  # component: FastAPI + Python (uv)
    ├── pyproject.toml
    ├── AGENTS.md             # component's local map  (see ./backend/AGENTS.md)
    └── CLAUDE.md             # `@AGENTS.md`
```

> **Note on this folder's layout.** To avoid duplicating the harness machinery, the example ships only
> the parts unique to a configured project: `harness.config.json` (here at the example root), the
> filled-in `AGENTS.md` maps, and stub `specs/`. In a *real* project the config lives at
> `harness/harness.config.json` as drawn above (stack profiles ship inside the plugin engine) — that's
> why the maps below reference `harness/…` paths even though this example flattens the config to its root.

## The point of this example
The file that makes it all work is [`harness.config.json`](./harness.config.json). Notice:

1. **`components[]` has two entries** — `frontend` (path `frontend/`) and `backend` (path `backend/`).
   Each declares its **own gate** (its own format/lint/typecheck/build/test commands). The harness runs
   each component's gate **in that component's own directory**, so the Python tools never run against
   the TypeScript code and vice-versa.

2. **The top-level `gate` holds the cross-cutting e2e** — a Playwright suite that boots the real
   frontend *and* backend and clicks through the app like a user. It runs from the repo root, after
   both component gates pass. This is the "unit-green is not done" check for the whole system.

3. **Editing a file auto-routes** — change a `.py` file under `backend/` and the PostToolUse hook runs
   *backend's* fast checks; change a `.tsx` under `frontend/` and it runs *frontend's*. You don't
   configure this; the hook matches the file to the component whose path is its deepest prefix.

## How it was produced
You don't write this by hand. In a real project you'd run **`/harness-init`**, which detects the two
sub-repos, interviews you to confirm each stack and its commands, and writes this config plus the
nested `AGENTS.md` files (each with a one-line `CLAUDE.md` import shim). This folder just shows you the finished shape.

## Files here
- [`harness.config.json`](./harness.config.json) — the multi-component config (the important bit).
- [`AGENTS.md`](./AGENTS.md) — the filled-in root map ([`CLAUDE.md`](./CLAUDE.md) is the `@AGENTS.md` shim).
- [`frontend/AGENTS.md`](./frontend/AGENTS.md), [`backend/AGENTS.md`](./backend/AGENTS.md) — per-component maps.
- [`specs/000-overview.md`](./specs/000-overview.md), [`specs/020-api.md`](./specs/020-api.md) — stub specs
  (the overview + the FE↔BE contract), modelling the `NNN-<slug>.md` numbering convention.

> A single-app project is just this with **one** component (`path: "."`) and no root e2e — the
> machinery is identical, which is the whole idea.
