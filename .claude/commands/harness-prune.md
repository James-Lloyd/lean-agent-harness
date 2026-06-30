---
description: After setup, strip the harness's own teaching scaffolding so less noise competes for the model's attention each session.
argument-hint: (optional) "aggressive" to also remove the init command, templates, and provenance docs
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, AskUserQuestion
---

# /harness-prune — slim the harness once it's yours

Mode: $ARGUMENTS (default: conservative)

The harness ships verbose on purpose — teaching comments, examples, reference profiles — so a newcomer
can understand it. Once `/harness-init` has configured it, much of that is dead weight that competes for
the model's attention every session. "Map, not manual" applies to the harness itself. This command
removes the scaffolding that has served its purpose. **Everything is one git commit, fully revertible.**

## Safety first
1. Refuse to run on a dirty tree (`git status --porcelain` must be empty) so the prune is a clean,
   isolated, revertible commit. Ask the human to commit/stash first if needed.
2. Confirm `/harness-init` has actually run (config has no `{{PLACEHOLDER}}`-derived nulls in `gate`,
   `CLAUDE.md` has real content). If it hasn't, stop — there's nothing safe to prune yet.
3. **Preview before deleting.** List exactly what you'll remove/trim and roughly how much (lines/files),
   then get a 👍. Deletion is destructive even with git behind it.

## Conservative tier (default — high value, low risk)
These reduce *per-session* context cost (the always-loaded files) and obvious clutter:

1. **Trim instructional comments from always-loaded files**, keeping all operative content:
   - `CLAUDE.md` (and any nested component `CLAUDE.md`): remove the top `<!-- ROOT CONTEXT MAP / RULES
     FOR THIS FILE -->` block and the inline `{{PLACEHOLDER}}`-hint comments. **Keep** the ratchet
     comment (it's live guidance) and all real content.
   - `AGENT_NOTES.md`, `PROMPT.md`: remove the leading meta-explanation comment blocks; keep the actual
     instructions and learnings.
   - `state/fix_plan.md`, `state/tasks.json`: remove the example/template comment blocks.
2. **Remove `examples/`** — the worked example is reference material, not part of a real project.
3. **Remove unused stack profiles** — delete `harness/profiles/*.json` whose `name` is not referenced by
   any `config.components[].profile`. **Keep** `_template.json` (needed to add components later) and the
   profiles actually in use.
4. **Strip the long `_comment` fields** in `harness/harness.config.json` for sections the human now
   understands — but keep the schema reference. (Optional; skip if unsure.)

## Aggressive tier (only if $ARGUMENTS contains "aggressive")
Also remove things you *can* regenerate or rarely need:
- `.claude/commands/harness-init.md` — one-time; re-cloneable from the upstream repo if you re-init.
- `harness/templates/` and `harness/profiles/_template.json` — only if you won't add components.
- `docs/principles/sources.md` — provenance/bibliography, not operational.
- `GUIDE.md` — the human onboarding guide (keep if others will use the repo).
Warn that these make a future `/harness-init` or "add a component" harder, and require explicit consent.

## Never remove
The operative core: `harness/loop.*`, `harness/lib/*`, `.claude/hooks/*`, `.claude/settings.json`, the
other commands/agents/skills, `specs/`, `state/` (your live work), `docs/principles/harness-philosophy.md`,
`workflow.md`, and `golden-principles.md` (the taste invariants reviewer/evaluator/skills enforce — no
config field points to it, so it isn't covered by the "referenced by `config`" rule below), and anything
referenced by `config`.

## Finish
1. Re-run a loop dry-run + the gate to confirm nothing operational broke
   (`powershell harness/loop.ps1 -DryRun` / `bash harness/loop.sh --dry-run`).
2. Commit: `chore: prune harness scaffolding after init`. Report what was removed, the lines/files
   saved, and that `git revert <hash>` restores it all.
