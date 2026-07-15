# Migrating a deployed harness to the plugin

As of v0.1.0 the harness engine ships as an installable Claude Code **plugin**
(`lean-agent-harness`), served from the in-repo marketplace at
`.claude-plugin/marketplace.json`. Engine fixes (skills, agents, hooks, doctor, loop/fleet) now arrive
via `/plugin update` instead of hand re-templating.

This guide migrates an **already-configured** project from a
copied-in `.claude/` + `harness/` engine to the plugin. It is a one-time, supervised operation. The
**scaffold stays yours**: `CLAUDE.md`, `specs/`, `state/`, and `harness/harness.config.json` are per-repo
and are NOT replaced by the plugin.

> The two halves. **Plugin (versioned, shared):** commands, agents, skills, hooks, and the loop/fleet
> engine. **Scaffold (per-repo, yours):** `CLAUDE.md`, `specs/`, `state/`, `harness/harness.config.json`,
> and the thin `harness/loop.*`/`fleet.*` wrappers that call the plugin engine.

## 0. Prerequisites
- Node on PATH (already required by Claude Code — the hook dispatcher uses it).
- A clean git tree in the target project (you're about to delete files; commit first).
- Know where the harness source repo lives (for a local marketplace) or use its GitHub URL.

## 1. Add the marketplace and install the plugin
GitHub source (recommended — gives versioned updates):
```
/plugin marketplace add James-Lloyd/lean-agent-harness
/plugin install lean-agent-harness@lean-agent-harness
```
Local source (offline / pre-push):
```
claude plugin marketplace add /path/to/lean-agent-harness --scope project
claude plugin install lean-agent-harness@lean-agent-harness --scope project
```
Confirm: `claude plugin list` shows `lean-agent-harness  Version: 0.1.0  Status: ✔ enabled`.

## 2. Remove the engine hooks from settings.json  ← DO NOT SKIP
Plugin hooks **merge with** your project hooks — they don't replace them. If you leave the old hook
blocks in `.claude/settings.json`, every guardrail fires **twice** (double format runs, double
destructive-block, a duplicated SessionStart banner).

Delete these five hook wirings from `.claude/settings.json` (the plugin now provides them):
`block-destructive`, `protect-specs`, `format-and-check` (PostToolUse), `lock-config` (ConfigChange),
`session-start` (SessionStart). In practice: remove the whole `"hooks": { … }` object unless you added
**project-specific** hooks of your own — keep only those.

Keep the rest of `settings.json`: `model`, `permissions` (including your gate allowlist), env, etc.

## 3. Delete the copied-in engine, keep the scaffold
Remove the now-duplicated engine files (the plugin supplies them):
- `.claude/agents/`, `.claude/commands/`, `.claude/skills/`, `.claude/hooks/`  ← all plugin-provided now
- `harness/lib/`, `harness/profiles/`, `harness/templates/`, `harness/harness.schema.json`
- the full engine scripts `harness/loop.ps1`, `harness/loop.sh`, `harness/fleet.ps1`, `harness/fleet.sh`
  (replaced by thin wrappers in the next step)

**Keep** `harness/harness.config.json` and everything under `state/`, `specs/`, and `CLAUDE.md`.

## 4. Drop in the thin runner wrappers
So `powershell harness/loop.ps1 …` (and cron) keep working from a bare terminal — where
`$CLAUDE_PLUGIN_ROOT` is not set — copy the four wrapper templates into `harness/`:
```
<plugin>/engine/wrappers/loop.ps1   → harness/loop.ps1
<plugin>/engine/wrappers/loop.sh    → harness/loop.sh
<plugin>/engine/wrappers/fleet.ps1  → harness/fleet.ps1
<plugin>/engine/wrappers/fleet.sh   → harness/fleet.sh
```
Each wrapper finds the installed engine (via `$HARNESS_ENGINE` → `$CLAUDE_PLUGIN_ROOT` →
`~/.claude/plugins` search) and dispatches with `--project-root <this repo>`. For cron / bare shells you
can pin the engine explicitly: `export HARNESS_ENGINE=~/.claude/plugins/cache/lean-agent-harness/lean-agent-harness/<version>/engine`.

> **cron / bare-shell CWD.** The wrappers derive the project root from their own location, so invoking
> `<repo>/harness/loop.ps1` works from any directory. But if you call the **raw engine** script directly
> (bypassing the wrapper), it resolves the project from the git top-level of your *current directory* —
> so a cron job must `cd` into the repo first **or** pass `-ProjectRoot`/`--project-root <repo>`
> explicitly. Prefer the wrapper.

`/harness-init` performs steps 3–4 automatically for a fresh project; this manual path is for upgrading
an existing one.

## 5. Verify
- `claude plugin list` → enabled, expected version.
- New session: the SessionStart banner appears **once** (not twice) → hooks de-duplicated correctly.
- Edit a file → the format/lint check runs once.
- `powershell harness/loop.ps1 -DryRun` → prints the harness banner + `[dry-run] would pipe PROMPT.md …`
  and writes nothing outside `harness/.runs/`.
- Trigger a blocked command (e.g. a `git reset --hard`) → still denied by the guardrail.

## 6. Upgrading later
```
/plugin update lean-agent-harness      # pulls the newer manifest version; restart to apply
```
`tasks.json` and everything under `state/` stay authoritative and untouched — the plugin only carries the
engine. Wrappers don't change between engine versions, so step 4 is a one-time move.

## Rollback
`claude plugin uninstall lean-agent-harness` and restore the previous `.claude/` + `harness/` from git
(`git checkout <pre-migration-commit> -- .claude harness`). Because the migration is all file
moves/deletes tracked in git, rollback is a single checkout.
