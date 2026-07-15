# frontend  (frontend/)

The Next.js + TypeScript web client for Acme Dashboard. Part of the project mapped in
[`../CLAUDE.md`](../CLAUDE.md).

## Stack & commands
- **Stack:** Next.js (App Router) + TypeScript, pnpm  (profile: `harness/profiles/node.json`)
- **Run:** `pnpm run dev`  ·  **Build:** `pnpm run build`  ·  **Test:** `pnpm test -- --run`
- All commands run **from this directory** (`frontend/`).

## Gate (run in this directory)
```
pnpm exec prettier --write .
pnpm exec eslint . --max-warnings=0
pnpm exec tsc --noEmit
pnpm run build
pnpm test -- --run
```

## Layout & entry points
- `app/` — routes (App Router).  `components/` — UI.  `lib/api/` — the **typed client** for the backend.

## How this component talks to the backend
- All calls go through `lib/api/` (generated from the backend's OpenAPI). The request/response contract
  is owned by `specs/020-api.md` — if the shape needs to change, change the spec first, then both sides.

## Component rules (the ratchet — local failures only)
<!-- Project-wide rules go in ../CLAUDE.md; only frontend-specific ones here. -->
