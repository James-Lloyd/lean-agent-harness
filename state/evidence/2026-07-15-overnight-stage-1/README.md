# Evidence — Overnight Stage 1a (local unattended run recipe)

Task: `state/fix_plan.md` → "Overnight Stage 1a: local unattended run recipe".
Plan: `docs/execution-plans/2026-07-15-overnight-stage-1.md`. Date: 2026-07-15.

## What shipped
- **`docs/overnight.md`** — the operator recipe: the config preset (WHY per knob + the allowlist
  requirement + fleet note), the sandbox tie-in, the Windows `schtasks` + Linux/WSL2 cron recipe, the
  morning routine (read `ledger.jsonl` → `/review`), and a preflight checklist.
- Cross-links from `README.md` (unattended-runs block) and `ROADMAP.md` (new "Unattended overnight runs").
- `state/fix_plan.md` split into 1a (this, ticked) + 1b (one real overnight run, supervise-first).

## Bug found + fixed during VALIDATE (prerequisite for a truthful recipe)
The dry-run e2e surfaced a **real parse error** in the shipped engine that made the loop unrunnable on
the recipe's primary Windows runtime:

- **`plugin/engine/loop.ps1:203`** — inside the `$evalPrompt` here-string, `failBelow=$FailBelow:` was
  parsed by **Windows PowerShell 5.1** as a scope-qualified variable (`$FailBelow:` → "':' not followed
  by a valid variable name"). Effect: `loop.ps1` **failed to parse** under 5.1 — it could not run at all.
  Shipped in the unpushed evaluator commit `8a3a032`.
- **Why the suite missed it:** `run-tests.ps1` dot-sources `lib/*.ps1` and runs functions but never
  *parses* the top-level entry scripts, so a here-string syntax error was invisible.
- **Fix:** delimit the variable — `failBelow=${FailBelow}:` (renders identically: `failBelow=7: ...`).
- **Regression net added (both runners):** an "engine hygiene" block that parses every engine script —
  `run-tests.ps1` via `[Parser]::ParseFile`, `run-tests.sh` via `bash -n` — so a broken entry script
  fails the gate from now on.

Proof the fix is real (Windows PowerShell 5.1.26100):
```
# before: ParseFile(loop.ps1) -> 1 error at line 203  (see the CLAUDE.md ratchet)
# after : ParseFile(loop.ps1) -> 0 errors ; rendered "failBelow=7: ANY criterion below 7 => the sprint FAILS."
```

## E2E — the documented preset behaves as documented
A throwaway temp repo carrying the exact `docs/overnight.md` preset (`mode:auto`, `meterTokens:true`,
`tokenBudget:2000000`, `reviewEveryNIterations:3`, `evaluator.enabled:true`, `skipPermissions:false`),
dry-run against the live engine. The live `harness.config.json` was NOT modified.

```
powershell plugin/engine/loop.ps1 -ProjectRoot <tempRepo> -Mode auto -DryRun
```
- **`dryrun-preset-console.log`** (HARNESS_SANDBOX unset): banner reads
  `mode=auto | maxIter=12 | maxTurns=40 | model=opus | budget=2000000` — the preset, resolved; the
  e2e-evidence warning, the allowlist reminder, AND the sandbox warning all fire. exit 0.
- **`dryrun-preset-sandboxed-console.log`** (HARNESS_SANDBOX=1): identical banner, sandbox warning
  **absent** (proving the sandbox tie-in). exit 0.

## Gate — all four suites green (sourced from plugin/engine)
```
powershell harness/tests/run-tests.ps1        -> 143 passed, 0 failed   (132 baseline + 11 parse-checks)
bash       harness/tests/run-tests.sh         -> 134 passed, 0 failed   (123 baseline + 11 parse-checks)
powershell harness/tests/fleet-queue-test.ps1 ->  22 passed, 0 failed
bash       harness/tests/fleet-queue-test.sh  ->  22 passed, 0 failed
```
No tests weakened; no specs edited; live `harness.config.json` unchanged.

## Fresh-context review — 4 rounds, FIX-THEN-SHIP → SHIP
`config.models.review` = **codex** read-only via `Invoke-Phase` (Ok=True, Path=codex, UsedFallback=False
every round). Each round's verdict is in the committed `review*-status.txt` file here (the source of
truth). The full codex transcripts (`review*.log`, ~230–300 KB each) were session-local and are
**gitignored** — not committed for size. Findings raised and fixed, round by round:
- Round 1 (`review-status.txt` = REJECT): 3 findings —
  1. `docs/overnight.md` schtasks redirect targeted `harness\.runs\...`, which PowerShell opens **before**
     the loop creates `.runs\` → task fails at startup. Fixed: redirect to the always-present `harness\` parent.
  2. `docs/overnight.md` ledger one-liner `(...).FullName\ledger.jsonl` parses as **two args**, not a path
     (codex verified via `ParseInput`). Fixed: `Join-Path (...).FullName 'ledger.jsonl'` (verified emits the
     ledger line against a real `.runs`).
  3. the record said "DOCS ONLY" while the change also fixes `loop.ps1` + both suites. Fixed: disclosed.
- Round 2 (`review-2-status.txt` = REJECT): 2 record-consistency findings — a residual "DOCS-ONLY" claim in
  `AGENT_NOTES.md`, and an evidence line that forward-referenced a verdict file not yet written. Fixed:
  corrected the AGENT_NOTES phrasing and rewrote this section to stop asserting an unreached verdict.
- Round 3 (`review-3-status.txt` = REJECT): 1 correctness finding — the morning-routine ledger table listed
  `review`/`evaluate` verdicts without `NONE`, but the fail-closed parsers
  (`Get-ReviewVerdict`/`Get-EvaluatorVerdict`) emit `NONE` and the loop writes it into the ledger
  (`loop.ps1:157,232`). Fixed: added `NONE` (+ clarified `ERROR`) to both rows and the triage sentence.
- Round 4 (`review-4-status.txt` = **SHIP**, no findings): confirmed.

The deliverable (docs/overnight.md, the loop.ps1 fix, the two parse-check test blocks) was also verified
correct deterministically, independently of the verdict — see the sections above.
