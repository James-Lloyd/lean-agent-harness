---
description: Map an existing (brownfield) codebase so the harness understands and respects it before changing anything.
argument-hint: (optional) "<area to focus the mapping, e.g. the payments module>"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion, Skill
---

# /onboard — understand an existing codebase before touching it

Focus: $ARGUMENTS (default: the whole repo)

A brownfield project already works and already has opinions baked into it. Your job here is **not** to
build — it's to *learn the territory* and write it down, so every later session (and the loop) respects
what exists instead of reinventing or breaking it. Run this during `/harness-init` on an existing
codebase, or standalone after a big change. Read the `brownfield-safety` skill first.

## 1. Map the structure (fan out — reads only)
Fan out parallel read-only searches via the `Agent` tool (e.g. the `Explore` agent type); do not write
code. Determine:
- **Components** — the buildable units and their directories (mirror into `config.components`). Detect
  multi-repo/monorepo layouts (frontend/ + backend/, workspaces).
- **Architecture** — entry points, the main modules and how they depend on each other, the data flow,
  external services/integrations. Note the *implicit* layering even if it's not documented.
- **Conventions** — naming, error handling, logging, test style, file organization. These are the
  "golden principles" already in force; the harness must follow them, not impose new ones.

## 2. Discover the gate (don't invent it — find it)
The gate for a brownfield project already exists somewhere. Look, in order:
- CI config (`.github/workflows/*`, `.gitlab-ci.yml`, etc.) — the real source of truth for "what must pass".
- `package.json` scripts, `Makefile`/`justfile`/`taskfile`, `pyproject.toml`, `tox.ini`, pre-commit config.
- Confirm the exact `format`/`lint`/`typecheck`/`build`/`test`/`e2e` commands **per component** with the
  human, then write them into `config.components[].gate` (+ cross-cutting root gate).

## 3. Establish the green baseline (critical)
Run the discovered gate now, on the untouched code:
- If it passes → set `project.baseline.established = true` and `baseline.ref` to the current commit.
  This is the line auto-rollback measures against.
- If parts already fail → **record them** in `docs/technical-debt/` as pre-existing (not yours to fix
  silently), and either fix-then-baseline with the human's OK or mark those steps `null`/quarantined so
  the harness doesn't blame your future changes for them. Never start real work against an unknown baseline.

## 4. Write it down (the artifacts)
- `docs/architecture/README.md` (+ files) — the map you just built: components, dependencies, data flow.
- `docs/principles/golden-principles.md` — append the conventions you found (so they're enforced, not guessed).
- `specs/` — reverse-engineer "as-built" specs **only** for the area you're about to change; capture the
  current behaviour and its acceptance criteria. Don't try to spec the whole legacy system up front.
- `AGENT_NOTES.md` — the real run/build/test commands and any "looks broken but isn't" landmines.
- `CLAUDE.md` — fill the map and set the project as brownfield; add the "respect existing code" guardrail.

## 5. Report
Summarize: components found, the architecture in a few lines, the exact gate, baseline status
(green / known-red items), and the conventions captured. Recommend starting with a small,
well-isolated first task (on a branch/worktree) and a characterization test — not a broad sweep.
