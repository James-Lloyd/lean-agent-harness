---
description: Migrate an existing copied-in harness onto the lean-agent-harness plugin without losing project customizations (ratchets, project skills/agents, tuned config).
argument-hint: (optional) "--apply" once you've reviewed the report
allowed-tools: Read, Bash, Grep, Glob
---

# /harness-migrate — move a deployed harness onto the plugin

Optional argument: $ARGUMENTS

A repo that had the harness **copied in** (not installed as the plugin) carries duplicate engine files:
agents, commands, skills, the 5 engine hooks, `harness/lib`, the runners. Most of them differ from the
current plugin only because of **version drift** — but some carry real project value (a ratcheted
`block-destructive` denylist, a project-authored skill, a tuned gate). This command safely removes the
provably-redundant copies and leaves everything customized in place for you to review.

## The safety rule (why this won't eat your ratchets)
A file is auto-removed **only if it is byte-identical** (line-ending/BOM normalized) to the plugin's
version. Anything that differs is **kept** and its diff shown; anything with no plugin counterpart is
**kept** as project-owned. The tool never deletes a file whose content the plugin doesn't already
provide verbatim.

## Procedure
1. **Report (default, writes nothing).** Run the classifier and read the output:
   - PowerShell: `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/engine/migrate.ps1"`
   - bash: `bash "${CLAUDE_PLUGIN_ROOT}/engine/migrate.sh"`
   It prints three classes — **IDENTICAL** (safe to remove), **DIFFERS** (kept, with a short diff), and
   **PROJECT-ONLY** (kept, yours) — plus what it would do with the runners. Nothing is written.
2. **Review with the human.** Walk the DIFFERS list together: each is either your customization (port it
   into the plugin or a project hook, then it can go) or just an older plugin version (safe to drop).
   Do **not** proceed to `--apply` without an explicit go-ahead.
3. **Apply (only on explicit user go).** Re-run with `--apply` (add `--replace-runners` to swap
   differing `harness/loop.*`/`fleet.*` for thin wrappers; identical runners are swapped automatically):
   - PowerShell: `... migrate.ps1 -Apply` (`-ReplaceRunners`, `-Force`)
   - bash: `... migrate.sh --apply` (`--replace-runners`, `--force`)
   `--apply` refuses a dirty tree unless `--force`, so the migration lands as one reviewable diff. It
   removes IDENTICAL files, strips the duplicate engine hook wiring from `.claude/settings.json` (your
   project-specific hooks and all non-hook settings survive), installs the runner wrappers (original
   backed up to `*.pre-plugin.bak`), and writes `harness/MIGRATION-REPORT.md`.
4. **Verify + commit.** Read `harness/MIGRATION-REPORT.md`, act on any **WARN** (an un-wired customized
   hook needs its ratchet ported or its wiring re-added), then **review `git diff`** and commit. Every
   change is reversible with `git`.

## Never touched
`CLAUDE.md`, `AGENT_NOTES.md`, `state/`, `specs/`, `docs/`, `harness/harness.config.json`,
`.claude/settings.local.json`.
