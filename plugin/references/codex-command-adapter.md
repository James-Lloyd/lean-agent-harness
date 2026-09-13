# Codex command adapter

The `harness-*` skills are thin Codex entry points for the canonical workflow commands in
`plugin/commands/`. Treat the source as authoritative; never copy its procedure into the skill wrapper.

When one of these skills is invoked:

1. Read this adapter and the linked command file completely before acting.
2. Treat the user's request after the skill invocation as `$ARGUMENTS`. If it is empty, use the
   command's documented default.
3. Apply the command procedure as Codex instructions. Claude-only frontmatter such as
   `allowed-tools`, `context`, and `argument-hint` is descriptive metadata, not a Codex requirement.
4. Resolve `${CLAUDE_PLUGIN_ROOT}` in command prose to the installed plugin root—the directory two
   levels above the invoking `SKILL.md`. `PLUGIN_ROOT` in hook commands is supplied by Codex.
5. Map references to slash commands onto the matching skill: `/work` becomes `harness-work`, while
   an already-prefixed command such as `/harness-doctor` keeps that name.
6. When a command names a specialist role, read its definition from `plugin/agents/<role>.md`, then
   delegate to an available fresh-context agent if the runtime supports that role. If it does not,
   perform the bounded role locally while preserving the command's required separation—for example,
   the doer must never act as the independent reviewer.
7. Prefer project-owned wrappers under `harness/` for engine operations. If a wrapper is absent and
   the command calls plugin-owned engine code, invoke it from the installed plugin root.
8. You are already in the Codex host. A command's checks for `claude plugin list`, requirement that
   the ambient session be Claude, or writes to Claude-only settings describe the Claude host only.
   Do not invoke Claude to rediscover this plugin. Resolve the Codex install from this skill's own
   root, keep Claude configuration as cross-host project metadata, and continue in Codex.

The repository's `AGENTS.md`, nested `AGENTS.md` files, immutable `specs/`, and live `state/` remain
the project authority. The plugin supplies workflow; it does not replace project context.
