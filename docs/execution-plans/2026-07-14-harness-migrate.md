# Execution plan — `harness-migrate`

_Written 2026-07-14. Drives the `fix_plan.md` item "Build harness-migrate". Self-contained: the EXECUTE
(generator) phase reads only this doc._

## Goal
A plugin-shipped tool that migrates an **existing copied-in harness** (e.g. an already-configured
project) onto the `lean-agent-harness` plugin **without losing project customizations** — ratcheted
denylist patterns in `block-destructive.*`, project-authored skills/agents, tuned gate config. It
classifies every engine-ish file, prints a plan, and with `--apply` removes only what is provably
redundant, strips the duplicate hook wiring, drops in the runner wrappers, and reports what it kept.

## The core hazard this must not trip on (design driver)
Deployed repos are on an **older harness version**, so most engine files differ from the *current*
plugin due to **version drift, not customization**. A naive "differs ⇒ customized ⇒ keep" would keep
everything (no cleanup); a naive "differs ⇒ delete" would destroy ratchets. So the safety rule is:

> **Auto-remove a file ONLY if it is byte-identical (line-ending/BOM-normalized) to the plugin's
> version. Anything that differs is KEPT and its diff is shown for human review. Anything with no
> plugin counterpart is KEPT as project-owned.** The tool never deletes a file whose content the plugin
> does not already provide verbatim — so no ratchet, no local edit, can be lost.

## Classification (per file)
- **IDENTICAL** — byte-match to the plugin counterpart (after normalizing CRLF/LF + stripping a UTF-8
  BOM, since checkout line-endings are not customizations) → **safe to remove** (plugin provides it).
- **DIFFERS** — counterpart exists but content differs → **keep + show a short diff**, labelled
  "review: newer plugin version, or your customization?". (This is where a ratcheted `block-destructive`
  pattern lands — preserved.)
- **PROJECT-ONLY** — no plugin counterpart → **keep**, labelled "yours" (e.g. a project-authored skill).

## File map (repo path → plugin path)  [pluginRoot = the installed plugin dir]
- `.claude/agents/*.md`            → `<pluginRoot>/agents/*.md`
- `.claude/commands/*.md`          → `<pluginRoot>/commands/*.md`
- `.claude/skills/<name>/**`       → `<pluginRoot>/skills/<name>/**`  (a skill dir absent from the plugin = PROJECT-ONLY)
- `.claude/hooks/<h>.{ps1,sh}`     → `<pluginRoot>/hooks/<h>.{ps1,sh}` (the 5 engine hooks only; repo won't have run.mjs/hooks.json)
- `harness/lib/**`                 → `<pluginRoot>/engine/lib/**`
- `harness/profiles/**`            → `<pluginRoot>/engine/profiles/**`
- `harness/templates/**`           → `<pluginRoot>/engine/templates/**`
- `harness/harness.schema.json`    → `<pluginRoot>/engine/harness.schema.json`
- `harness/{loop,fleet}.{ps1,sh}`  → `<pluginRoot>/engine/…` (SPECIAL, see below)

**Never touched** (scaffold — the project's own intelligence): `CLAUDE.md`, `AGENT_NOTES.md`, `state/`,
`specs/`, `docs/`, `harness/harness.config.json`, `.claude/settings.local.json`.

## Runner scripts — special case
The copied-in `loop/fleet.{ps1,sh}` are the FULL engine scripts and, on an old repo, will always DIFFER
from the plugin (the `--project-root` refactor). They must become **thin wrappers**. Default: treat like
any DIFFERS file (keep + flag "replace with wrapper once you confirm no local edits"). Opt-in
`--replace-runners` (or, when IDENTICAL, automatically): back up to `*.pre-plugin.bak`, then overwrite
with the wrapper from `<pluginRoot>/engine/wrappers/`. Never silently discard a differing runner.

## What `--apply` does (in order, all reversible via git)
1. Re-run classification; abort if the git tree is dirty (so the change is reviewable as one diff) unless `--force`.
2. Remove every **IDENTICAL** engine file (and prune emptied dirs).
3. **Strip engine hook wiring** from `.claude/settings.json`: drop hook entries whose `command`
   references any of the 5 engine hook scripts; prune emptied matcher groups/events; leave every other
   hook + all non-hook settings intact. (PS: ConvertFrom/To-Json; sh: jq.) If a project-specific hook
   references a CUSTOMIZED engine hook we kept, leave that wiring — warn.
4. Install the 4 wrappers into `harness/` (runner special-case above).
5. Write `harness/MIGRATION-REPORT.md`: removed / kept-differs (with why) / kept-project-only / settings
   edits / wrappers installed / manual next-steps. Print a summary + "review `git diff`, then commit."

Default (no `--apply`) = **report only**, nothing written.

## Interfaces
- `plugin/engine/migrate.ps1` — `param([string]$ProjectRoot, [switch]$Apply, [switch]$ReplaceRunners, [switch]$Force)`.
  `$ProjectRoot`: -ProjectRoot → git top-level → CWD (same discovery as loop.ps1). PluginRoot resolves
  self-relative (`Split-Path $PSScriptRoot` — migrate.ps1 sits in `engine/`, payload is its sibling).
- `plugin/engine/migrate.sh` — mirror: `--project-root`, `--apply`, `--replace-runners`, `--force`. Needs jq.
- `plugin/commands/harness-migrate.md` (+ synced `.claude/commands/`) — the `/harness-migrate` command:
  explains the flow, runs the report, shows it, and only on explicit user go runs `--apply`; reminds to
  review `git diff` + commit. `allowed-tools: Read, Bash, Grep, Glob`.

## Out of scope
- Auto-porting a CUSTOMIZED file's delta into the plugin or a project hook (tool surfaces the diff; human ports).
- Upgrading `harness.config.json` schema. Un-migrate/rollback beyond the git-revert already available.
- Running the migration on the real deployments (separate supervised op).

## Acceptance criteria (executable)
1. `migrate.ps1`/`.sh` with no flags print a classification (IDENTICAL/DIFFERS/PROJECT-ONLY) and write nothing.
2. On a **synthetic repo** carrying: identical engine copies + a `block-destructive.ps1` with an extra
   ratcheted denylist pattern (DIFFERS) + a project-authored skill `.claude/skills/proj-thing/` (PROJECT-ONLY):
   - the ratcheted hook and the project skill are classified KEEP and, after `--apply`, **still present + unchanged**;
   - the identical engine files are removed;
   - `.claude/settings.json` loses the engine hook blocks but keeps a project-specific hook + `model`/`permissions`;
   - the 4 wrappers exist in `harness/`; `harness/harness.config.json`, `state/`, `specs/`, `CLAUDE.md`, `AGENT_NOTES.md` untouched;
   - `MIGRATION-REPORT.md` lists all three classes.
3. Both runners (ps1 + sh) produce the same classification + apply result on the synthetic repo (a test in `harness/tests/`).
4. Existing suites stay green (PS 68, bash 64 w/ jq, fleet-queue 16).

## Verification
A new `harness/tests/migrate-test.ps1` + `.sh`: build the synthetic repo in a temp dir (copy plugin
engine files for IDENTICAL, mutate one hook for DIFFERS, add a project skill for PROJECT-ONLY, author a
settings.json with engine + one project hook), run report (assert classification), run `--apply` (assert
removals + preservations + settings surgery + wrappers + report). Wire both into run-tests.{ps1,sh}.
Manual: `migrate.ps1` report against a throwaway copy of THIS repo's `.claude`+`harness`.

## Risks / landmines
- settings.json surgery must not corrupt valid JSON or drop unrelated keys — round-trip carefully; test a
  settings.json that has BOTH engine and project hooks.
- Line-ending/BOM normalization for the IDENTICAL test (else CRLF-vs-LF false-negatives keep everything).
- New `.ps1` needs a UTF-8 BOM; `.sh` LF + jq dependency (mirror loop.sh's jq guard).
- Don't delete a DIFFERS runner without a `.bak`; never touch scaffold paths.
- migrate.sh under `set -euo pipefail`: guard empty globs and missing dirs.
