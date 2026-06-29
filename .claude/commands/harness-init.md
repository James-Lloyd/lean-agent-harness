---
description: One-time interview that turns this generic harness into a project-specific one.
argument-hint: (no args — it interviews you)
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, Skill, Agent
---

# /harness-init — make this harness yours

You are initializing the harness for a project — either **greenfield** (built from scratch) or
**brownfield** (an existing codebase). This runs **once**. Your job: interview the human, detect the
environment, and replace every `{{PLACEHOLDER}}` with real values so the harness is concrete and the
loop can run. Be thorough but fast — ask in batches, infer what you safely can.

> Principle: a harness is a set of bets about what the model can't do alone. The interview's purpose
> is to record the few facts that make every later session cheaper — the map, the stack, the gate, the
> guardrails. Keep what you write *short* (map, not manual). Do not over-populate; the ratchet adds the
> rest later from real failures.

## Step 0 — Greenfield or brownfield? (decide this first — it changes everything)
Inspect the repo: existing source files, a populated git history, lockfiles, CI config?
- **Empty / near-empty, no real history → greenfield.** You will *establish* the stack, write specs
  first, `git init` if needed, and higher autonomy is acceptable.
- **Existing code with history → brownfield.** You must *understand and respect* it before changing
  anything. **Run `/onboard`** (or the equivalent inline): map the architecture, discover the gate from
  existing CI/scripts, establish a green baseline, and capture conventions. Read the `brownfield-safety`
  skill. Brownfield defaults to **supervised** autonomy and small, isolated work.

Confirm your guess with the human, then set `project.type` accordingly. Don't proceed until this is settled.

## Step 1 — Detect the shape
Run the `stack-detect` skill (or do it inline). Determine the **project shape**:
- Look for manifests/lockfiles in **immediate subdirectories**, not just the root. Many projects are
  headless — a root folder holding `frontend/` + `backend/` (or more), each its own sub-repo with its
  own root files, stack, and build/test commands.
- **One root manifest** → a single component (`path: "."`). **Subdir manifests / workspaces** → one
  component per sub-repo. Decide the component list now; it shapes everything downstream.

Then, per component, hypothesize language / package manager / runtime / test runner / build tool. Also
detect the OS (`$IsWindows` / `uname`) so you can wire the right hooks. For **brownfield**, prefer the
gate commands you *find* in CI/scripts over ones you'd choose.

## Step 2 — Interview (use AskUserQuestion, batched)
Ask only what you couldn't confidently detect. Cover:
1. **Project identity** — name, one-line description, domain/market, who the users are.
2. **What it is** — app type (web app / API / CLI / library / data pipeline / mobile / firmware / …),
   and the single most important outcome it must deliver.
3. **Shape & components** — confirm whether it's single-root or multi-component (e.g. `frontend/` +
   `backend/`). For **each** component confirm/correct: directory path, languages, package manager,
   runtime, test runner, build, and how to run it locally. If greenfield, choose them now, biasing
   toward harnessable defaults (strong typing, clear module boundaries, an opinionated framework).
4. **The gate(s)** — the exact `format`/`lint`/`typecheck`/`build`/`test` commands **for each
   component** (any may be "none"), plus any **cross-cutting e2e** that exercises the components
   together (→ the root `gate`). This is the most important thing you collect — the gate is the harness.
5. **End-to-end verification** — how does a human confirm a change actually works? (browser, a CLI
   invocation, an API call, a device, a screenshot.) This becomes the e2e step + `e2e-evidence` skill.
6. **Autonomy preference** — supervised (default) or auto; iteration cap; token/cost budget; whether
   unattended skip-permissions runs are ever allowed.
7. **Hard constraints / guardrails** — anything destructive or off-limits specific to this project
   (prod data, money movement, deploy targets, compliance).

## Step 3 — Write the configuration
With answers in hand:
- **`harness/harness.config.json`** — set `project.type` (greenfield/brownfield), `autonomy.*`
  (default `supervised` for brownfield), `workflow.*`, `verification.*`, and build the **`components[]`**
  array (one entry per component: `name`, `path`, `profile`, `languages`, `packageManager`, `commands`,
  and its `gate` with real commands). Put any cross-cutting e2e in the top-level `gate`. For each
  component's stack, reference a matching `harness/profiles/<stack>.json` or copy `_template.json`.
- **`CLAUDE.md`** — replace every `{{PLACEHOLDER}}`: name, description, domain, project shape, the
  **Components table** (one row per component), the gate block, and entry points. Leave the ratchet
  section empty (it grows from failures). Keep the file ≤ ~100 lines — trim, don't pad.
- **Nested `CLAUDE.md`** — for each non-trivial component, copy `harness/templates/component-CLAUDE.md`
  into that component's directory (e.g. `frontend/CLAUDE.md`) and fill it. Skip for a single-root project.
- **`AGENT_NOTES.md`** — fill the run/build/test commands and any known environment quirks.
- **`.claude/settings.json`** — the shipped hook commands use `powershell …<hook>.ps1` (Windows). If OS
  is **not** Windows, rewrite the three hook commands to `bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/<hook>.sh"`
  (or `pwsh …` if you standardize on PowerShell 7). On Windows, leave as-is. Tighten the
  `permissions.ask`/`deny` lists for any project-specific guardrails from Step 2.7.

## Step 4 — Scaffold the working state
- **Greenfield:** create `specs/README.md` if missing and, with the human, draft `specs/000-overview.md`
  capturing the core requirements first (the immutable source of truth — get it roughly right).
- **Brownfield:** `/onboard` already wrote `docs/architecture/` and captured conventions into
  `docs/principles/golden-principles.md`. Write "as-built" specs **only** for the area about to change,
  not the whole legacy system. Log any pre-existing broken gate steps to `docs/technical-debt/`.
- Seed `state/fix_plan.md` with a first few prioritized items (or leave the template if they'll use
  `/plan`). Seed `state/tasks.json` from the template. Leave `state/PROGRESS.md` ready to append.
- Ensure `.gitignore` lists this stack's build/dep artifacts (uncomment/add the relevant lines).

## Step 5 — Verify the harness itself
- Dry-run the loop without invoking the model: `powershell harness/loop.ps1 -DryRun` on Windows
  (`pwsh` on PowerShell 7), or `bash harness/loop.sh --dry-run` on Unix.
- Run **each component's** gate commands once, from that component's directory, to confirm they exist
  and exit 0 (plus any cross-cutting root gate). If any is wrong, fix the config. **Do not finish with a
  gate that doesn't actually run.**
- **Establish the baseline:**
  - *Greenfield:* confirm `git` is initialized (the loop needs it for checkpoints); if not, `git init`
    and make the first commit. The empty/scaffold state is your baseline.
  - *Brownfield:* the discovered gate must be **green** on the untouched code. Run it; if green, set
    `project.baseline.established = true` and `baseline.ref` to the current commit. If parts are already
    red, catalogue them as pre-existing (don't silently fix) and quarantine those steps so future
    rollbacks aren't blamed on them. Never finish with an unknown baseline.

## Step 6 — Report
Summarize, concisely: project identity, chosen stack + profile, the exact gate, autonomy settings,
where state lives, and the 3–4 commands the human will use day to day (`/plan`, `/loop`, `/review`,
`/ratchet`). Tell them the harness is v0.1 by design and grows via `/ratchet`.

Then delete nothing here — but tell the human that once they're happy the setup is right, **`/harness-prune`**
will strip the now-unnecessary teaching scaffolding (instructional comments, `examples/`, unused
profiles) so less noise competes for the model's attention each session. Note that `/harness-init`
shouldn't be run again unless re-initializing.
