# Example: headless frontend + backend

A worked example of the harness configured for a **headless** project — one repo root containing two
sub-repos with different stacks:

```
acme-dashboard/
├── CLAUDE.md                 # root map → points at both components  (see ./CLAUDE.md)
├── harness/                  # ONE harness governs the whole project
├── specs/                    # shared, immutable — incl. the FE↔BE API contract
├── frontend/                 # component: Next.js + TypeScript (pnpm)
│   ├── package.json
│   └── CLAUDE.md             # component's local map  (see ./frontend/CLAUDE.md)
└── backend/                  # component: FastAPI + Python (uv)
    ├── pyproject.toml
    └── CLAUDE.md             # component's local map  (see ./backend/CLAUDE.md)
```

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
nested `CLAUDE.md` files. This folder just shows you the finished shape.

## Files here
- [`harness.config.json`](./harness.config.json) — the multi-component config (the important bit).
- [`CLAUDE.md`](./CLAUDE.md) — the filled-in root map.
- [`frontend/CLAUDE.md`](./frontend/CLAUDE.md), [`backend/CLAUDE.md`](./backend/CLAUDE.md) — per-component maps.

> A single-app project is just this with **one** component (`path: "."`) and no root e2e — the
> machinery is identical, which is the whole idea.
