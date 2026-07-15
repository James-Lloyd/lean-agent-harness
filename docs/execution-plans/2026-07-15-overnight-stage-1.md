# Overnight Stage 1: local unattended run recipe — execution plan

_Authored 2026-07-15. Task: `state/fix_plan.md` → "Overnight Stage 1: local unattended run recipe".
Component: `root` (docs + `state/` records; **no engine code**). Expands a one-line intent (approval
comment) into a spec + sprint contract, per the handoff's "needs a real PLAN phase first" note._

## Problem
The loop already ships every mechanism an unattended overnight run needs — `autonomy.mode: auto`,
`meterTokens`+`tokenBudget` (exact vs estimate), `verification.reviewEveryNIterations` (a fresh-context
reviewer + optional evaluator at the review point, fail-closed), the `skipPermissions`/allowlist
reminder, the `Test-Sandboxed` guard, auto-rollback, the config-tamper pin, and a per-run
`ledger.jsonl`. What's missing is the **operator layer**: a single documented **preset** that composes
those knobs safely, a **Task Scheduler / cron recipe** to fire the loop while you sleep, and a
**morning routine** (read the ledger → `/review`) so an unattended night is auditable after the fact.
Without that, the pieces exist but nobody can run an overnight session confidently.

This is **Stage 1** of the overnight roadmap; Stage 2 (`fix_plan.md`) is the GitHub Actions nightly
runner + Issues intake. Stage 1 is the *local* recipe.

## Key finding (why the recipe itself is docs — scope amended by the As-built note below)
Every knob the done-condition names is **already implemented and tested** in `plugin/engine/loop.*`:
- `autonomy.mode: auto` — unattended; `Confirm-Checkpoint` is a no-op so it never blocks (`loop.ps1:84`).
- `meterTokens` → `--output-format json` + real `usage` parse; `tokenBudget` becomes an exact per-run
  cap (else ~15k/iter estimate) — `budget.ps1`, `loop.ps1:389`.
- `verification.reviewEveryNIterations` → `Invoke-PeriodicReview` (+ `Invoke-PeriodicEvaluation` when
  `evaluator.enabled`), both READ-ONLY and fail-closed, stopping the loop + writing `handoff.md` on a
  non-SHIP/non-PASS — `loop.ps1:427`.
- `skipPermissions:false` + the allowlist reminder — `loop.ps1:311`; sandbox guard — `loop.ps1:322`.
- `ledger.jsonl` per run under `harness/.runs/<runId>/` — `loop.ps1:70,81`.

So Stage 1 adds **no engine surface**. It is a human-facing guide + records, exactly like the S5–S7
docs slices. Building new mechanism here would be the wrong altitude.

## Sprint contract: Overnight Stage 1 (local unattended run recipe)

### Scope (this sprint = Stage 1a, the codeable half)
- **`docs/overnight.md`** — the operator guide, mirroring `docs/sandboxing.md`'s shape. It contains:
  1. **The preset** — a copy-paste `harness.config.json` block with the WHY for each knob (auto mode;
     `meterTokens:true` + a concrete `tokenBudget`; `maxIterations` as the hard runaway bound;
     `skipPermissions:false` + the **allowlist requirement** for the gate commands; `reviewEveryNIterations:3`;
     `commitOnGreen`/`autoRollbackOnRed`/`stopWhenPlanEmpty`; the optional `evaluator.enabled`).
  2. **Sandbox tie-in** — auto ⇒ run inside a recognized sandbox; cross-link `docs/sandboxing.md` and the
     `HARNESS_SANDBOX` contract (the loop warns otherwise).
  3. **Fleet note** — fleet only for tasks with non-overlapping `files` ownership; the plain loop is the
     overnight default (review bandwidth binds before compute).
  4. **The recipe** — Windows **Task Scheduler** (`schtasks`) and Linux/WSL2 **cron** copy-paste, covering
     the non-interactive-env gotchas: working directory, `HARNESS_ENGINE` pinning, auth/token availability
     to the scheduled process, and log redirection.
  5. **The morning routine** — how to read `harness/.runs/<runId>/ledger.jsonl` (every `result` type and
     what it means), check `state/handoff.md` for a `review-stop`, then run `/review` over the batch.
  6. **Preflight checklist** — the boxes to tick before you schedule a night.
- **Cross-links**: a pointer from `README.md`'s "For unattended runs" block and a `ROADMAP.md` line so the
  doc is discoverable.
- **Records**: `state/fix_plan.md` split (see below), `AGENT_NOTES.md` learning, `state/PROGRESS.md` line.

### Split — this sprint delivers 1a; 1b is the human tail
The done-condition has a wall-clock, human-in-the-loop tail ("**one real overnight run** ... supervised
-after-the-fact") that is not a coding step. Per PROMPT.md Phase 1 ("if the item is too big, split it and
take the first slice") and the handoff's pre-authorized split, `fix_plan.md` splits into:
- **[x] Stage 1a** — the preset + recipe + morning routine doc (this sprint).
- **[ ] Stage 1b** — James runs one real overnight session with the preset, then we inspect the ledger +
  `/review` together the next morning. This is also the **live-fire** for the two still-untested paths
  (codex *write* path; a real evaluate-phase judge scoring a real batch) — a supervise-first follow-up.

### Out of scope
- **No engine code / new tests** — every knob already exists and is covered by the suites. A partial
  config file can't ship as a loadable "preset" (the config has no overlay mechanism), so the preset is a
  documented block, not a new file.
- **Not** flipping the live `harness/harness.config.json` to `auto` — the dev repo stays supervised; the
  preset is applied by the operator (Stage 1b), demonstrated against a throwaway temp config for evidence.
- Stage 2 (GitHub Actions nightly + Issues intake) — its own `fix_plan.md` item.
- A brittle importable Task Scheduler **XML** — a `schtasks` command line is more robust and version-
  independent; the recipe uses that.

### Definition of done (every box must be ticked)
- [ ] `docs/overnight.md` exists with all six sections above; the preset block is valid JSON and every
      field it names matches `harness.schema.json` (no invented knobs).
- [ ] The preset correctly requires the gate commands in `.claude/settings.json` `permissions.allow`
      whenever `skipPermissions:false` (the doc states this and shows where), matching `loop.ps1:311`.
- [ ] The recipe gives a working Windows `schtasks` command AND a Linux/WSL2 cron line, each noting
      working-dir, `HARNESS_ENGINE`, auth-in-scheduled-env, and log redirection.
- [ ] The morning routine enumerates every `ledger.jsonl` `result` value the engine emits
      (`green`, `red`, `review`, `review-stop`, `invoke-error`, `gate-error`, `config-tampered`) — verified
      against `loop.{ps1,sh}`, not invented.
- [ ] `README.md` + `ROADMAP.md` cross-link the new doc.
- [ ] `fix_plan.md` split into 1a (ticked) + 1b (open), with 1b flagged supervise-first.
- [ ] E2E evidence under `state/evidence/2026-07-15-overnight-stage-1/`: a `loop --dry-run` (and/or a
      short real run) against a **temp** repo carrying the documented preset, showing the startup banner
      reflects the preset (`mode=auto`, `budget=<N>`, model routing) and the sandbox + allowlist reminders
      fire — proving the documented preset is real and wired as described.
- [ ] Gate green: both self-test suites pass (the validation-discovered parse fix added an "engine hygiene"
      parse-check block → counts rose to PS 143 / bash 134; see the As-built note. Fleet-queue 22 ×2 unchanged).
- [ ] No specs edited; no tests weakened; live `harness.config.json` unchanged.

### How success is verified
```
# 1. Doc facts are real, not invented:
#    - every preset field ∈ harness.schema.json
#    - every ledger result value ∈ loop.{ps1,sh}
# 2. E2E — temp repo with the preset, dry-run the loop:
powershell <engine>/loop.ps1 -ProjectRoot <tempRepo> -Mode auto -DryRun
#    -> banner shows mode=auto + budget=<N>; sandbox warning + allowlist reminder present
# 3. Regression — suites unchanged and green:
powershell harness/tests/run-tests.ps1     # prior baseline, 0 fail
bash       harness/tests/run-tests.sh      # (jq on PATH) prior baseline, 0 fail
```

### Fresh-context review
Per `config.models.review` = **codex** (read-only via `Invoke-Phase`), with the `reviewer` subagent
(fable) as the Claude fallback. Reviewed for accuracy (no invented knobs / ledger values / schema drift)
and guardrail integrity.

## As-built note (amends the "no engine code" scope)
The plan scoped this docs-only, but the VALIDATE dry-run e2e surfaced a **real engine bug** that had to
be fixed for the recipe to be truthful (the doc tells Windows users to run `powershell harness/loop.ps1`):
`plugin/engine/loop.ps1` **failed to parse under Windows PowerShell 5.1** — a here-string `$FailBelow:`
was read as a scope-qualified variable, so the loop could not run at all (shipped in the unpushed
evaluator commit `8a3a032`; invisible to the suite because it never parsed the entry scripts). Fix:
`${FailBelow}:` + an "engine hygiene" parse-check added to **both** suites (`[Parser]::ParseFile` / `bash
-n`; +11 assertions each). Recorded as a CLAUDE.md ratchet + AGENT_NOTES learning.

The fresh-context codex review then returned **FIX-THEN-SHIP** with 3 findings (schtasks redirect to a
not-yet-existing `.runs`; the ledger one-liner splitting into two args → `Join-Path`; this record's
"DOCS ONLY" framing) — all fixed and re-verified.
