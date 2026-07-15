# Overnight unattended runs (local)

`autonomy.mode: auto` lets the loop work the plan **unattended** — a fresh headless `claude` per
iteration, gate → commit on green, roll back on red, no human at the keyboard. This doc is the operator
recipe for running that overnight on your own machine: a **config preset**, a **scheduler recipe**
(Windows Task Scheduler / cron), and the **morning routine** that makes the night auditable after the
fact. It is the *local* half; the GitHub Actions nightly runner is Overnight Stage 2 (see
[`ROADMAP.md`](../ROADMAP.md) and `state/fix_plan.md`).

> **Auto ⇒ sandbox.** An unattended run should execute inside a recognized isolation profile — see
> [`docs/sandboxing.md`](sandboxing.md). The loop prints a loud warning when `auto` runs outside one. The
> destructive-command deny-list is defense-in-depth, **not** a sandbox.

## The preset

Set these in [`harness/harness.config.json`](../harness/harness.config.json). Every field already exists
and is enforced by the engine (`harness.schema.json` is the field reference); this preset just composes
them for an overnight session. Only the changed keys are shown — leave the rest of your config intact.

```jsonc
{
  "autonomy": {
    "mode": "auto",              // unattended: checkpoints become no-ops, the loop never blocks for input
    "maxIterations": 12,         // HARD runaway bound — a night's worth of tasks; raise/lower to taste
    "maxTurnsPerIteration": 40,  // per-iteration turn cap (the other hard bound on a runaway)
    "tokenBudget": 2000000,      // per-run soft cap; the loop stops when the estimate/meter crosses it
    "meterTokens": true,         // read REAL usage from the model's JSON output -> tokenBudget is a close cap
    "skipPermissions": false,    // KEEP false: the permission deny/ask layer stays alive (see allowlist note)
    "checkpoints": { "planApproval": true, "beforeRiskyOps": true, "everyNIterations": 0 }
  },
  "loop": {
    "commitOnGreen": true,       // each green iteration is a commit — the ledger + git log are your audit trail
    "autoRollbackOnRed": true,   // a red iteration is git-reset so the tree is never left broken
    "tagOnGreen": true,
    "stopWhenPlanEmpty": true    // stop cleanly when state/fix_plan.md has no open items
  },
  "verification": {
    "reviewEveryNIterations": 3, // every 3 GREEN iterations a fresh-context reviewer audits the batch, fail-closed
    "evaluator": { "enabled": true, "rubric": "docs/principles/evaluator-rubric.md", "failBelow": 7 }
  }
}
```

**Why each knob:**

| Knob | Why it's in the overnight preset |
|------|----------------------------------|
| `mode: auto` | Runs unattended — `Confirm-Checkpoint` returns immediately, so nothing hangs waiting for a keypress. |
| `maxIterations` + `maxTurnsPerIteration` | The two **hard** runaway bounds. `tokenBudget` is soft (an estimate unless `meterTokens`); these are not. |
| `meterTokens: true` + `tokenBudget` | With metering on, the loop invokes with `--output-format json` and reads real `usage`, so `tokenBudget` is a close per-run cap instead of a ~15k/iteration estimate. Size the budget from a typical iteration × `maxIterations` with headroom. Trade-off: `iter-N.log` is JSON, not streamed text. |
| `skipPermissions: false` | Keeps the permission layer (deny/ask rules + the destructive-command hook) with teeth. `true` voids it entirely and is only safe **inside a real sandbox** — see below. |
| `reviewEveryNIterations: 3` | Puts "doer ≠ judge" into the unattended path: a READ-ONLY fresh-context reviewer scores every 3rd green batch and **fails closed** — a REJECT (or a crash/truncation) writes `state/handoff.md` and **stops the loop** for your morning triage. Requires `commitOnGreen`. |
| `evaluator.enabled: true` | Augments that same review point: after the reviewer SHIPs, a read-only evaluate-phase judge scores the batch against the rubric; any criterion below `failBelow` stops the loop like a REJECT. Optional — drop it for a lighter gate. |
| `commitOnGreen` + `autoRollbackOnRed` | Green = a commit you can inspect; red = an automatic rollback so you never wake to a broken tree. |
| `stopWhenPlanEmpty` | The loop exits when the plan is exhausted rather than spinning. |

### The allowlist requirement (do not skip)

With `skipPermissions: false`, the headless child **auto-denies any Bash command not in
`.claude/settings.json` → `permissions.allow`** — there is no human to approve a prompt. If your
project's **gate commands** (test / build / lint / e2e) are not allowlisted, the agent can't run Phase 3
of `PROMPT.md` and burns iterations editing blind. `/harness-init` appends them; the loop also prints a
reminder at startup. Confirm they're present **before** you schedule a night. (If your gate is empty — as
in this harness's own root component — the deterministic safety net is just rollback + the periodic
review; the review is then doing the heavy lifting, so keep `reviewEveryNIterations` low.)

### Fleet only for independent tasks

The overnight default is the **plain loop** — one task per iteration, serialized. The parallel **fleet**
(`harness/fleet.*`) is opt-in and only parallelizes tasks whose `files` ownership in `state/tasks.json`
**doesn't overlap**; it lands them through a serialized merge queue. Review bandwidth binds before
compute, so reach for the fleet only when you have several genuinely independent tasks queued. It has no
automated periodic-review point (it defers `/review` to a human), so audit its batches in the morning.

## The scheduler recipe

The loop wrapper (`harness/loop.ps1` / `.sh`) computes its own project root from its path, so the
scheduler's working directory doesn't matter. What **does** matter: the scheduled process must (a) have
the `claude` CLI on `PATH` with your auth available, (b) find the plugin engine, and (c) send its console
output somewhere you can read it.

> **Engine discovery.** The wrapper resolves `$HARNESS_ENGINE` → `$CLAUDE_PLUGIN_ROOT/engine` →
> newest `~/.claude/plugins/…/engine`. A scheduled task has **no** `CLAUDE_PLUGIN_ROOT` (that's set only
> inside Claude Code), so it falls back to the installed-plugin cache — stable and fine. To pin a specific
> engine (e.g. live in-repo edits), set `HARNESS_ENGINE` in the scheduled command.

> **Auth in a non-interactive session.** The scheduler runs without your interactive shell. Run the task
> **as your own user** (not SYSTEM) so the `claude` subscription/token credentials in your profile are
> visible, and confirm `claude` resolves on the task's `PATH`.

### Windows — Task Scheduler

Register a one-shot task that fires tonight at 23:00, running as you, redirecting console output to a log:

```powershell
schtasks /create /tn "harness-overnight" /sc ONCE /st 23:00 /ru "$env:USERNAME" /it `
  /tr "powershell -NoProfile -ExecutionPolicy Bypass -Command `"& { & 'C:\path\to\repo\harness\loop.ps1' -Mode auto } *> 'C:\path\to\repo\harness\overnight-console.log'`""
```

- `/ru "$env:USERNAME" /it` — run as you, with your profile (so `claude` auth resolves). `/it` = only
  when you're logged on; drop it and supply `/rp` for run-whether-or-not-logged-on (stores your password).
- `*> …console.log` — captures the startup banner + warnings + per-iteration streaming. The structured
  **ledger** and per-iteration logs are written separately under `harness\.runs\<runId>\` regardless.
- To pin the engine, prepend `$env:HARNESS_ENGINE='C:\path\to\repo\plugin\engine'; ` inside
  the `& { … }` block. Delete the task afterward: `schtasks /delete /tn "harness-overnight" /f`.

### Linux / WSL2 — cron

```cron
# crontab -e  — fire nightly at 23:00
0 23 * * * cd /home/you/harness && HARNESS_SANDBOX=1 HARNESS_ENGINE="$PWD/plugin/engine" PATH="$HOME/.local/bin:$PATH" bash harness/loop.sh --mode auto >> "$HOME/harness-overnight.log" 2>&1
```

- **`HARNESS_SANDBOX=1`** — WSL2 is **not** auto-detected as a sandbox (shared kernel, `/mnt/c` reach), so
  opt in explicitly, and clone the repo into the WSL-native FS first (see `docs/sandboxing.md`, Profile B).
- `PATH=…` — cron's env is minimal; make sure `claude` and `jq` (the bash gate resolvers need jq) are
  reachable. `HOME` is set by cron, so the `claude` credentials dir is found.
- `>> …log 2>&1` — captures console output; the ledger still lands under `harness/.runs/<runId>/`.

## The morning routine

An overnight run is only trustworthy if you audit it the next morning. Three steps:

**1. Read the ledger.** Each run appends JSONL to `harness/.runs/<runId>/ledger.jsonl` (newest run =
highest `run-NNN`). One object per event:

```powershell
Get-Content (Join-Path (Get-ChildItem harness\.runs -Directory | Sort-Object Name | Select-Object -Last 1).FullName 'ledger.jsonl')
```
```bash
cat "$(ls -d harness/.runs/run-* | sort -V | tail -1)/ledger.jsonl"   # or pipe through: jq -c .
```

Every `result` value the engine emits, and what it means:

| `result` | Meaning |
|----------|---------|
| `green` | Iteration passed the gate and was committed (`path` = which vendor ran; `usedFallback` if the fallback fired). |
| `red` | Gate failed at `failedStep`; the iteration was rolled back (tree stayed green). |
| `review` | Periodic fresh-context review ran; `verdict` = `SHIP` / `REJECT` / `NONE` / `ERROR` (`NONE` = no clear verdict parsed → fail-closed stop; `ERROR` = the review invocation itself failed). |
| `evaluate` | Periodic evaluator scored the batch (when `evaluator.enabled`); `verdict` = `PASS` / `FAIL` / `NONE` / `ERROR` (`NONE`/`ERROR` fail closed, same as `review`). |
| `review-stop` | A judge did not clear the batch — **the loop stopped here** for you. Read `state/handoff.md`. |
| `invoke-error` | The model invocation itself failed (`reason`); the iteration was rolled back. |
| `config-tampered` | `harness.config.json` changed mid-iteration (gate/policy tamper pin) — rolled back and **stopped**. |
| `gate-error` | *(PowerShell runner)* the gate threw rather than returning red — rolled back. |

A clean night ends with `green` rows and a `stopWhenPlanEmpty` exit or a `review`/`evaluate` `SHIP`/`PASS`.
Any `review-stop`, `config-tampered`, `invoke-error`, `gate-error`, or a `REJECT` / `FAIL` / `NONE` / `ERROR`
verdict is your triage signal (`NONE`/`ERROR` mean the judge couldn't render a clean verdict and the loop
stopped fail-closed — treat them exactly like a `REJECT`).

**2. Check the handoff.** A stopped loop appends a `## Needs human decision — periodic review: …` section
to `state/handoff.md` naming the batch range and the findings log
(`harness/.runs/<runId>/review-after-N.log` or `evaluate-after-N.log`). Read it before continuing.

**3. Run `/review`.** Even on a clean night, do a fresh-context QA pass over what landed —
`git log --oneline <last harness-reviewed tag>..HEAD` shows the batch; `/review` judges it independently
of the loop that produced it. Only after that do you trust the night's work.

## Preflight checklist

Before you schedule a night, tick every box:

- [ ] Gate commands (test/build/lint/e2e) are in `.claude/settings.json` → `permissions.allow`
      (`skipPermissions: false` auto-denies anything else).
- [ ] The run executes inside a recognized sandbox, or you've accepted the warning (`docs/sandboxing.md`;
      set `HARNESS_SANDBOX=1` for WSL2).
- [ ] `state/fix_plan.md` holds well-scoped, ready-to-run tasks at the top (the loop takes them top-down,
      one per iteration).
- [ ] `maxIterations` and `tokenBudget` are sized for the night (with `meterTokens: true`).
- [ ] The tree is **clean** — the loop refuses to start on a dirty tree, and rollback uses
      `git reset --hard` / `git clean -fd`, so don't leave uncommitted work in the tree.
- [ ] `claude` (and `jq` on the bash path) resolve on the **scheduled** process's `PATH`, running as your
      user so auth is available.
- [ ] You know where the console log and `harness/.runs/<runId>/` will land, and you'll run the morning
      routine.
