# Overnight Stage 1b supervised preflight — 2026-09-12

## Outcome

PARTIAL, safely blocked after two failed attempts. The durable ledger proves the real Codex path was
selected; both invocations hit their phase watchdog, failed closed, and restored their exact
pre-iteration commits. During each run the supervisor observed the intended documentation diff and
child verification processes, but the timeout logger discarded Codex's buffered output, so those
activity details are observations rather than durable proof. The periodic reviewer and evaluator were
not invoked, and the full overnight task is not complete.

## Preflight

- Claude Code 2.1.268 was authenticated through Claude.ai.
- Codex CLI 0.154.0 was authenticated through ChatGPT.
- `codex-setup.ps1` generated plugin 0.4.4's seven roles and twenty command/reference skills.
- Temporary canary route: implement = Codex @ high, fallback Opus 5 @ high; one Fable 5.1 reviewer;
  Fable evaluator enabled; one iteration; real token metering; 250,000-token cap; permissions enabled.
- The supervising console showed the preflight gate green under that route. Its full output was not
  retained, so this evidence does not claim exact durable counts.
- Docker was installed but its daemon was not running. Native Windows is not a supported isolation
  profile, so the run was explicitly supervised and the normal sandbox warning was retained.

## Attempt 1 — run-002

- Watchdog: 900 seconds.
- Supervisor observation (not retained by the logger): the intended `docs/overnight.md` diff appeared
  and child verification processes ran before timeout.
- Durable ledger: [`run-002-ledger.jsonl`](run-002-ledger.jsonl), line 1.
- Durable phase log: [`run-002-iter-1.log`](run-002-iter-1.log), line 1.
- Rollback: [`rollback-reflog.txt`](rollback-reflog.txt), line 1, restores checkpoint `b44b14d8`.

## Attempt 2 — run-003

- Only the measured watchdog changed: 1,800 seconds.
- Supervisor observation (not retained by the logger): the same scoped diff and child verification
  processes appeared again.
- Ledger: [`run-003-ledger.jsonl`](run-003-ledger.jsonl), line 1.
- Phase log: [`run-003-iter-1.log`](run-003-iter-1.log), line 1.
- Rollback: [`rollback-reflog.txt`](rollback-reflog.txt), line 2, restores checkpoint `1a5177ea`.

The raw run directories are gitignored machine-local artifacts under `harness/.runs/run-002` and
`run-003`. The four files beside this README preserve their complete verdict-bearing lines without a
local absolute path. [`rollback-reflog.txt`](rollback-reflog.txt) preserves the two reset records that
were visible before the worktree was removed.

## Adjudication

The rollback, timeout, and vendor-path behavior passed live. Green advancement, periodic review, and
evaluation did not. The committed timeout logs expose a further defect: they preserve only the watchdog
sentence, not output produced before the kill, so they cannot prove what consumed the phase allowance.
The next task first fixes that evidence loss. Only then should the current supervisor hypothesis — that
in-model full-gate work duplicates the outer runner's authoritative gate — drive a verification-contract
change. Normal Opus/supervised defaults were restored.
