# Execution plan — Package the harness engine as a Claude Code plugin

_Written 2026-07-14. Drives the `fix_plan.md` item "Package the engine as a Claude Code plugin."
Self-contained: the EXECUTE phase (generator) reads only this doc, not the conversation that produced
it._

## Goal (from fix_plan.md, restated)
Turn the harness from a **clone-and-template** repo into an **installable, versioned Claude Code
plugin** served from an **in-repo marketplace**, so already-configured projects
upgrade via `/plugin update` instead of hand re-templating. The per-repo scaffold
(`CLAUDE.md`, `specs/`, `state/`, `/harness-init`) stays the **template half**.

James's decisions (2026-07-14, this session):
- **Hosting:** in-repo marketplace, **GitHub source** (`James-Lloyd/lean-agent-harness`).
- **Scope:** EVERYTHING in one run — agents, skills, commands, **hooks**, AND the `harness/` runner
  scripts (loop/fleet/lib/profiles). Only the runner-script relocation is genuinely hard.
- **Cross-platform hooks:** a **node dispatcher** (`node run.mjs <hook>` → picks `powershell.exe`/`bash`
  by `os.platform()`), because Node is a hard dependency of Claude Code so it is always present.

## Authoritative plugin facts (verified via claude-code-guide, 2026-07-14)
- Manifest: `.claude-plugin/plugin.json`. Required: `name` (kebab-case). Optional: `version` (semver;
  falls back to git SHA), `description`, `author`, and path overrides `skills`/`agents`/`commands`/`hooks`.
- Default payload dirs (relative to plugin root): `agents/`, `skills/<name>/SKILL.md`, `commands/*.md`,
  `hooks/hooks.json`.
- `${CLAUDE_PLUGIN_ROOT}` = absolute path to the plugin's install dir. Valid in hook/mcp/lsp commands
  **and** in skill/agent frontmatter+body. **Ephemeral** — path changes on update; old version kept ~7
  days. Do NOT write persistent state there. `${CLAUDE_PLUGIN_DATA}` is the persistent sibling.
- **Plugin agents ignore only `hooks`, `mcpServers`, `permissionMode`.** They DO support `model`,
  `effort`, `tools`, `disallowedTools`, `skills`, `memory`, `isolation` (worktree). Our 6 agents use
  none of the three ignored fields (audit done — see below), so they move losslessly.
- **Plugin hooks MERGE with** project (`settings.json`) hooks; both fire. → the migration MUST remove
  the engine hook declarations from a deployment's `settings.json`, or every hook runs twice.
- Marketplace: `.claude-plugin/marketplace.json` (or `marketplace.json`). Schema: `name`, `owner`,
  `plugins:[{name, source, version?}]`. `source` may be a **relative in-repo path** (`./plugin`) or a
  GitHub URL. Same repo may host both marketplace and plugin.
- Install/upgrade: `/plugin marketplace add James-Lloyd/lean-agent-harness` → `/plugin install
  <name>@<marketplace>` → `/plugin update <name>`. Update pulls the newer manifest `version`.
- Namespacing: **agents** are scoped (`plugin:agent`); **skills/commands are NOT** scoped — name
  collisions resolve by priority (user > project > plugin > local). Our command names (`work`, `plan`,
  `review`…) are generic → collision risk if a host project defines its own. Mitigation: see Decision D.

## Agent frontmatter audit (the task's explicit prerequisite) — PASS
All 6 `.claude/agents/*.md` use only `name/description/tools/effort/model` (+ `memory:project` and
`isolation:worktree` on `generator`). **None** use `hooks`/`mcpServers`/`permissionMode`. `memory` and
`isolation` are supported in plugin agents. → agents move with zero behavior loss.

## The hard part — runner-script path model (root cause)
`loop.ps1`/`loop.sh`/`fleet.ps1`/`fleet.sh` today resolve **everything** off the script's own dir:
- `$PSScriptRoot` / `SCRIPT_DIR` → engine files: `lib/`, `harness.config.json`, `.runs/`,
  `.worktrees/`, `.checkpoint`, `.budget.json`.
- `$RepoRoot = Split-Path -Parent $PSScriptRoot` (`REPO_ROOT="$SCRIPT_DIR/.."`) → the **project root**
  for all git ops, and `cd $REPO_ROOT`.

Move the scripts into the (ephemeral) plugin dir and `$RepoRoot` = "parent of the plugin dir" points
**inside `~/.claude/plugins/`**, not the user's project. So the relocation must split two path classes:
- **Engine-relative** (travels with the script, resolve off script dir): `lib/`, `profiles/`,
  `templates/`, `harness.schema.json`. ✓ keep as-is.
- **Project-relative** (must resolve to the USER'S project, not the script dir): `harness.config.json`,
  `.runs/`, `.worktrees/`, `.checkpoint`, `.budget.json`, and `$RepoRoot` for git. → resolve via a new
  **project-root** discovery: explicit `-ProjectRoot`/`--project-root` arg, else `git rev-parse
  --show-toplevel` from CWD, else CWD. Config = `$ProjectRoot/harness/harness.config.json`; runtime
  under `$ProjectRoot/harness/`.

### Resulting split
- **Plugin (engine, versioned):** `agents/`, `skills/`, `commands/`, `hooks/` (+ node dispatcher),
  `engine/loop.ps1|.sh`, `engine/fleet.ps1|.sh`, `engine/lib/`, `engine/profiles/`, `engine/templates/`,
  `engine/harness.schema.json`, `.claude-plugin/plugin.json`.
- **Project (template half, per-repo):** `harness/harness.config.json` (+ gitignored runtime
  `harness/.runs`, `.worktrees`, `.checkpoint`, `.budget.json`), `CLAUDE.md`, `specs/`, `state/`,
  and thin invocation wrappers (Decision C).

## Decisions this plan pins down (recommendations — confirm at checkpoint)
**A. Config + runtime location.** Keep a project-side `harness/` holding ONLY `harness.config.json` +
gitignored runtime. Engine code moves to the plugin. (Least disruptive; satisfies "scaffold keeps
harness.config.json".) ✅ recommend.

**B. Project-root resolution.** `-ProjectRoot` arg → else `git rev-parse --show-toplevel` → else CWD.
✅ recommend.

**C. Loop invocation story (the redesign piece).** Humans/cron run `harness/loop.ps1` today; every doc
and command says so. Preserve that UX with a **thin project-side wrapper** `harness/loop.ps1` +
`loop.sh` (and fleet) that locates the plugin engine and dispatches with `-ProjectRoot <repo>`. This
keeps README/GUIDE/commands unchanged and shrinks the doc blast radius to near zero. The wrapper finds
the engine via `${CLAUDE_PLUGIN_ROOT}` when invoked by Claude, or a discoverable install path / env
var for bare-shell/cron. ✅ recommend (wrapper is the only new per-project file; `/harness-init`
generates it).

**D. Command name collisions.** Skills/commands aren't plugin-scoped. Options: (i) accept it (harness
owns these verbs in a harnessed repo), (ii) prefix engine commands. ✅ recommend (i) for now + a
ratchet note; revisit if a host project collides.

**E. DOGFOODING — the one genuinely open architectural fork.** This repo is BOTH the plugin *source*
and a *user* of the harness. Two ways to avoid maintaining two copies of ~30 engine files:
  - **E1 (staged, safer — recommend):** iteration keeps the dev repo's live `.claude/` + `harness/`
    working AS-IS, and ADDS the `plugin/` tree as the packaged engine + `marketplace.json` +
    `plugin.json` + migration docs. Verify by installing the plugin into a **throwaway project**.
    The dev repo does NOT yet self-install. A single authoritative source is restored in an
    immediately-following slice that flips the dev repo to consume its own plugin and deletes the
    in-repo `.claude/` engine copies. Temporary duplication, low blast radius, easy rollback.
  - **E2 (big-bang):** move engine to `plugin/` as the single source now; the dev repo dogfoods by
    installing its own plugin from a local `file://` marketplace; repo `.claude/` shrinks to
    project-local. Clean end-state, but risks breaking the dev repo's own SessionStart/hooks mid-refactor
    and is hard to verify in one green pass.

→ **Recommend E1.** It delivers every "done when" criterion (installable versioned plugin, hooks fire
cross-platform, verified install, migration path) while keeping the dev repo green and reversible, and
sequences the duplication-removal as its own reviewable step.

## Acceptance criteria (executable — from "done when")
1. `plugin/.claude-plugin/plugin.json` exists, valid JSON, `name` kebab-case, `version` semver (`0.1.0`).
2. `marketplace.json` at repo root, valid JSON, lists the plugin with a working `source`.
3. `plugin/hooks/hooks.json` + `hooks/run.mjs` dispatcher: on Windows spawns `powershell.exe -File
   <hook>.ps1`, on Unix `bash <hook>.sh`; forwards stdin; **preserves exit code** (a blocked
   destructive command still exits 2). Unit-tested on both branches.
4. Engine runner scripts run correctly from a plugin-style location against a separate project root:
   `loop.ps1 -DryRun -ProjectRoot <tmpproj>` resolves that project's config + writes runtime under it,
   with `$RepoRoot` = the project (NOT the plugin dir). Verified.
5. A **throwaway project** adds the marketplace, installs the plugin, and gets: the 12 commands, 6
   agents, skills, and hooks firing (destructive-block hook denies `rm -rf` end-to-end). Evidence
   captured under `state/evidence/<task-id>/`.
6. `docs/` migration guide: exact steps for a deployed project to (a) add marketplace +
   install, (b) **remove engine hook blocks from their `settings.json`** (anti-double-fire), (c)
   relocate to the project-side `harness/harness.config.json`-only layout, (d) `/plugin update` flow.
7. Existing gates stay green throughout: `run-tests.ps1` (67), `run-tests.sh` (63 w/ jq), fleet-queue
   tests (16+16). Any test that hard-codes `harness/loop.ps1` etc. is updated to the wrapper/engine path.

## EXECUTE — ordered work-packages (each ends gate-green; commit per WP)
WP1. **Plugin skeleton + payload copy (E1).** Create `plugin/.claude-plugin/plugin.json`,
`plugin/{agents,skills,commands,hooks}/` populated from `.claude/*`, `marketplace.json` at root.
No runner refactor yet. Gate: JSON validity + structure.

WP2. **Node hook dispatcher.** `plugin/hooks/run.mjs` + `plugin/hooks/hooks.json` wiring all 5 hooks
through it; copy the `.ps1`+`.sh` hook bodies into `plugin/hooks/`. Unit test both OS branches
(mock `os.platform`), assert exit-code + stdin passthrough. Gate: node test green + existing gates.

WP3. **Runner-script project-root refactor.** Add `-ProjectRoot`/`--project-root` (+ git-toplevel/CWD
fallback) to loop+fleet (both langs); route config + runtime + `$RepoRoot` through it; keep `lib/`
engine-relative. Update `harness/tests/*` to the new invocation. Gate: all four test suites green +
`-DryRun -ProjectRoot <tmp>` resolves correctly.

WP4. **Engine relocation + thin wrappers.** Move refactored scripts/lib/profiles/templates/schema into
`plugin/engine/`; generate project-side thin wrappers `harness/loop.ps1|.sh`, `harness/fleet.ps1|.sh`
that locate the engine and dispatch `-ProjectRoot`. Update `/harness-init` to emit wrappers +
config-only `harness/`. Gate: wrappers run the dry-run green; suites green.

WP5. **Marketplace/manifest polish + migration docs + throwaway-install verification.** Write the
migration guide (criterion 6); do the real throwaway-project install (criterion 5) and capture
evidence. Gate: evidence maps to acceptance criteria 1–7.

WP6. **Doc sweep.** Update README/GUIDE/ROADMAP (mark plugin item shipped) + any command/doc paths the
wrapper didn't preserve. Gate: no stale `harness/loop.ps1`-as-engine references; doctor passes.

## Out of scope (explicit)
- E2 dogfition flip (dev repo self-installing its own plugin + deleting in-repo engine copies) — the
  immediately-following slice, not this one.
- The `commands → skills/*/SKILL.md` migration (separate ROADMAP bullet).
- Actually migrating the live deployments (supervised op; docs only here).
- Publishing to any public/third-party marketplace.

## Verification / e2e
Windows box: full suites + node dispatcher test + `loop.ps1 -DryRun -ProjectRoot <tmp>` +
throwaway-project `/plugin install` with a real `rm -rf` block. Unix hook branch: dispatcher unit test
(can't run bash hooks natively here — note the gap; CI covers `.sh`).

## Risks / landmines
- New `.ps1`/`.mjs` files need correct encoding; PS 5.1 needs a UTF-8 BOM on `.ps1` (AGENT_NOTES).
- Node dispatcher must forward **stdin** (hooks read JSON on stdin) and **exit codes** verbatim.
- Config-hash pin + atomic run-id claim + worktree root all move to project-relative — re-verify the
  tamper-guard and fleet merge-queue tests specifically.
- Wrapper engine-discovery for bare-shell/cron is the fragile bit — dry-run it explicitly.
