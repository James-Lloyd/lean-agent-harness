# AGENTS.md

This project's agent instructions live in **[`CLAUDE.md`](./CLAUDE.md)**.

`AGENTS.md` exists as a portability shim so that non-Claude agents (OpenAI Codex, opencode, Cursor,
Aider, etc.) find the same context. The harness deliberately keeps all agent knowledge in plain,
version-controlled files — no proprietary auto-managed memory — so you can swap the model or the
tool without losing the harness.

**If you are any coding agent reading this:** read `CLAUDE.md`, then `specs/`, then
`state/fix_plan.md`, and follow the loop contract described there.

> Keep this file a pointer. Do not duplicate `CLAUDE.md`'s content here — two sources of truth drift.
