# backend  (backend/)

The FastAPI + Python service for Acme Dashboard. Part of the project mapped in
[`../CLAUDE.md`](../CLAUDE.md).

## Stack & commands
- **Stack:** FastAPI + Python, uv  (profile: `harness/profiles/python.json`)
- **Run:** `uv run uvicorn app.main:app --reload`  ·  **Test:** `uv run pytest -q`
- All commands run **from this directory** (`backend/`).

## Gate (run in this directory)
```
uv run ruff format .
uv run ruff check .
uv run pyright
uv run pytest -q
```

## Layout & entry points
- `app/main.py` — FastAPI app + router wiring.  `app/api/` — endpoints.  `app/models/` — schemas.
- `app/db/` — data access.  `tests/` — pytest.

## How this component talks to the frontend
- Exposes the HTTP API consumed by `frontend/lib/api/`. The contract is owned by `specs/020-api.md`.
  Keep the OpenAPI schema in sync — the frontend's typed client is generated from it.

## Component rules (the ratchet — local failures only)
<!-- Project-wide rules go in ../CLAUDE.md; only backend-specific ones here. -->
