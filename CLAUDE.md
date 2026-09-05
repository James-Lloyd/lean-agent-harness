@AGENTS.md

<!--
  CLAUDE.md is a thin Claude Code shim: the project map lives in AGENTS.md (read natively by Codex,
  Cursor, Copilot, Gemini CLI…) and is pulled in above by the `@AGENTS.md` import. Only put things
  here that ONLY Claude Code needs. Keep it under ~20 lines. See docs/design-docs/002-vendor-agnostic-routing.md.
-->

## Claude Code specifics
- **Worktree:** at the start of a session call `EnterWorktree` before editing — `worktree.baseRef` is
  `fresh` in `.claude/settings.json`, so it branches from origin's default. The plugin, guard hooks,
  permissions, and the `.git/hooks` pre-commit privacy guard all resolve through the worktree to the
  main checkout, so they apply inside it with no extra wiring; while in a worktree, Claude Code blocks
  any edit to the main checkout. On exit you're prompted to keep or remove the worktree.
- **Commands, agents, skills, hooks** come from the installed `lean-agent-harness` plugin (this repo
  dogfoods its own `plugin/`). `/handoff` then `/clear` beats `/compact` at task boundaries.
- **Permissions** live in `.claude/settings.json` (`permissions.allow/deny/ask`); the session model and
  effort are pinned there from `harness.config.json` → `models.session`.
- **Nested maps:** each subsystem's `CLAUDE.md` is the same one-line `@AGENTS.md` import.
