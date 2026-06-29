---
description: One-time interview that turns this generic harness into a project-specific one.
argument-hint: (no args — it interviews you)
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, Skill, Agent
---

# /harness-init — make this harness yours

You are initializing the harness for a brand-new project. This runs **once**. Your job: interview the
human, detect the environment, and replace every `{{PLACEHOLDER}}` with real values so the harness is
concrete and the loop can run. Be thorough but fast — ask in batches, infer what you safely can.

> Principle: a harness is a set of bets about what the model can't do alone. The interview's purpose
> is to record the few facts that make every later session cheaper — the map, the stack, the gate, the
> guardrails. Keep what you write *short* (map, not manual). Do not over-populate; the ratchet adds the
> rest later from real failures.

## Step 1 — Detect before you ask
Run the `stack-detect` skill (or do it inline): inspect the repo for lockfiles, manifests, configs,
and source globs. Form a hypothesis about language(s), package manager, runtime, test runner, and
build tool. Also detect the OS (`$IsWindows` / `uname`) so you can wire the right hooks.

If the repo is empty (greenfield), say so — you'll set the stack from the interview instead.

## Step 2 — Interview (use AskUserQuestion, batched)
Ask only what you couldn't confidently detect. Cover:
1. **Project identity** — name, one-line description, domain/market, who the users are.
2. **What it is** — app type (web app / API / CLI / library / data pipeline / mobile / firmware / …),
   and the single most important outcome it must deliver.
3. **Stack confirmation** — confirm/correct your detected languages, package manager, runtime,
   test runner, build, and (if web) how to run it locally. If greenfield, choose them now, biasing
   toward harnessable defaults (strong typing, clear module boundaries, an opinionated framework).
4. **The gate** — the exact commands for `format`, `lint`, `typecheck`, `build`, `test`, `e2e`
   (any may be "none"). This is the most important thing you collect — the gate is the harness.
5. **End-to-end verification** — how does a human confirm a change actually works? (browser, a CLI
   invocation, an API call, a device, a screenshot.) This becomes the e2e step + `e2e-evidence` skill.
6. **Autonomy preference** — supervised (default) or auto; iteration cap; token/cost budget; whether
   unattended skip-permissions runs are ever allowed.
7. **Hard constraints / guardrails** — anything destructive or off-limits specific to this project
   (prod data, money movement, deploy targets, compliance).

## Step 3 — Write the configuration
With answers in hand:
- **`harness/harness.config.json`** — set `autonomy.*`, `gate.*` (the real commands), `stack.*`,
  `verification.*`. If a profile in `harness/profiles/` matches, reference it by name; if not, copy
  `_template.json` to `harness/profiles/<stack>.json`, fill it, and reference that.
- **`CLAUDE.md`** — replace every `{{PLACEHOLDER}}`: name, description, domain, stack summary, run/
  build/test commands, entry points, and the gate block. Leave the ratchet section empty (it grows
  from failures). Keep the whole file ≤ ~100 lines — trim, don't pad.
- **`AGENT_NOTES.md`** — fill the run/build/test commands and any known environment quirks.
- **`.claude/settings.json`** — if OS is **not** Windows, rewrite the three hook commands from
  `pwsh -NoProfile -ExecutionPolicy Bypass -File ".../<hook>.ps1"` to
  `bash "${CLAUDE_PROJECT_DIR}/.claude/hooks/<hook>.sh"`. On Windows, leave as-is. Tighten the
  `permissions.ask`/`deny` lists for any project-specific guardrails from Step 2.7.

## Step 4 — Scaffold the working state
- Create `specs/README.md` if missing and, with the human, draft an initial `specs/000-overview.md`
  capturing the core requirements (this is the immutable source of truth — get it roughly right).
- Seed `state/fix_plan.md` with a first few prioritized items (or leave the template if they'll use
  `/plan`). Seed `state/tasks.json` from the template. Leave `state/PROGRESS.md` ready to append.
- Ensure `.gitignore` lists this stack's build/dep artifacts (uncomment/add the relevant lines).

## Step 5 — Verify the harness itself
- Dry-run the loop without invoking the model: `powershell harness/loop.ps1 -DryRun` on Windows
  (`pwsh` on PowerShell 7), or `bash harness/loop.sh --dry-run` on Unix.
- Run the gate commands once manually to confirm they exist and exit 0 on a clean tree. If any is
  wrong, fix the config. **Do not finish with a gate that doesn't actually run.**
- Confirm `git` is initialized (the loop needs it for checkpoints). If not, offer to `git init` and
  make the first commit.

## Step 6 — Report
Summarize, concisely: project identity, chosen stack + profile, the exact gate, autonomy settings,
where state lives, and the 3–4 commands the human will use day to day (`/plan`, `/loop`, `/review`,
`/ratchet`). Tell them the harness is v0.1 by design and grows via `/ratchet`.

Then delete nothing — but note that `/harness-init` shouldn't be run again unless re-initializing.
