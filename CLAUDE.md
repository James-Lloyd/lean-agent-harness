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
  a `model:` override; `review`/`evaluate` carry a Claude fallback in config for the headless path.
- [2026-07-26 · consolidated 2026-08-11] **A fact you change in one prompt surface exists in others —
  find them before you close.** Grep the whole repo for the literal (path, count, field name, phrase)
  you just edited. Four incidents, one lesson: a stale fact recurred in a sibling surface (07-26); an
  engine edit landed in `loop.ps1` but not the `.sh` twin (07-29); a deleted doc block left inbound
  pointers dangling, so rehome the content or fix the pointer *in the same change* — a pointer into
  deleted content is worse than the verbosity (07-29); and `/harness-migrate` deleted engine files from
  consumers without updating the plugin's own checks against those paths, so harness-doctor checks 1+7
  failed on every correctly-migrated repo (07-30).
- [2026-07-30] A committed config pointer ($schema, profile, path) is repo-relative or plugin-resolved,
  never an absolute local path — it dies on the next device (a consumer repo's $schema pointed at this
  machine's harness checkout).
- [2026-07-30] Compression may not swap a concrete fact for a pointer unless the pointed-at
  file/skill/command is verified to exist — resolve it before closing (a consumer map lost its model
  names to an unverified skill pointer).
- [2026-08-06] A doc that names a plugin-owned file as a WRITE target must say what a *consumer* repo
  writes instead — the installed cache is outside the project, shared machine-wide, and reverted by
  `/plugin update` (the routing skill told migrate to edit agent frontmatter that consumers can't own).
- [2026-08-06] A test pinning a doc table to a config asserts the value in its own COLUMN (split the
  row) and reads config keys via `PSObject.Properties[...]` — a row-wide match false-passes off a
  neighbouring cell, and a bare `$obj.$key` aborts the whole suite under StrictMode instead of failing.
- [2026-08-11] A bare model **alias** (`opus`, `sonnet`) floats to the newest model in that tier — it is
  a moving pointer, not a pin. Write the full `claude-*` ID anywhere the *generation* matters and the
  alias only where the *tier* is the point (`haiku` for scouts). Found live: `settings.json` said
  `"model": "opus"` intending Opus 4.8 while the session was actually running Opus 5.
- [2026-08-11] A config key that nothing reads is worse than no key — it advertises a control that does
  not exist. Before adding one, name the code path that consumes it; when deleting the consumer, delete
  the key in the same change (`verification.freshContextReview` sat in the schema and every config for
  months while `/work` ran the review unconditionally — turning it off disabled nothing).
- [2026-08-12] A change to a shipped engine function's signature or behaviour bumps
  `plugin/.claude-plugin/plugin.json` `version` in the SAME diff — an unbumped version leaves a
  consumer's `/plugin update` serving a cached prose/engine pair from different builds (found in review
  of the promotion-decision signature change: the lib changed but the version stayed 0.2.9).

## Nested context
Subsystems carry their own `CLAUDE.md` next to their code (in this repo: `plugin/engine/` holds the
engine's PS-5.1/twin-parity rules). When working in a subsystem, its local map applies too.
