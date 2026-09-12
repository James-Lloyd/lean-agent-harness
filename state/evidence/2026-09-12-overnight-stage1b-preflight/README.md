# Overnight Stage 1b supervised preflight — 2026-09-12

## Outcome

PARTIAL, safely blocked after two failed attempts. The real Codex workspace-write path was reached and
made the intended documentation edit, but it never returned before the phase watchdog. Both attempts
failed closed and restored their exact pre-iteration commits. The periodic reviewer and evaluator were
therefore not invoked, and the full overnight task is not complete.

## Preflight

- Claude Code 2.1.268 was authenticated through Claude.ai.
- Codex CLI 0.154.0 was authenticated through ChatGPT.
- `codex-setup.ps1` generated plugin 0.4.4's seven roles and twenty command/reference skills.
- Temporary canary route: implement = Codex @ high, fallback Opus 5 @ high; one Fable 5.1 reviewer;
  Fable evaluator enabled; one iteration; real token metering; 250,000-token cap; permissions enabled.
- Exact preflight gate under that route: PowerShell 436 passed / 0 failed; Bash 429 / 0.
- Docker was installed but its daemon was not running. Native Windows is not a supported isolation
  profile, so the run was explicitly supervised and the normal sandbox warning was retained.

## Attempt 1 — run-002

- Watchdog: 900 seconds.
- Codex made the intended `docs/overnight.md` correction and entered the full twin gate.
- Durable ledger: `{"path":"codex","result":"invoke-error","usedFallback":false,"reason":"invoke-failed","iter":1}`.
- Durable phase log: `[codex timed out after 900s — watchdog kill, failing closed]`.
- The loop restored checkpoint `b44b14d8`.

## Attempt 2 — run-003

- Only the measured watchdog changed: 1,800 seconds.
- Codex again made the same scoped correction and ran verification.
- The ledger recorded the same Codex `invoke-error` / `invoke-failed` result.
- Phase log: `[codex timed out after 1800s — watchdog kill, failing closed]`.
- The loop restored checkpoint `1a5177ea`.

The raw run directories are gitignored machine-local artifacts under `harness/.runs/run-002` and
`run-003`. This file records their complete verdict-bearing lines without a local absolute path.

## Adjudication

The rollback, timeout, and vendor-path behavior passed live. Green advancement, periodic review, and
evaluation did not. Increasing the watchdog again would repeat the same architecture: the model spends
its phase allowance running the full twin gate, then the runner intends to run that full gate again.
The next task narrows the headless contract so the model performs bounded targeted checks and the outer
runner remains the single authoritative full-gate owner. Normal Opus/supervised defaults were restored.
