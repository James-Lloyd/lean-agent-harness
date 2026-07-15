# E2E evidence — model routing + fleet (2026-07-13)

## Loop model routing (real dry-run, PS 5.1)
```
🔧 Harness loop | type=greenfield | mode=supervised | maxIter=20 | maxTurns=40 | model=opus | budget=
[dry-run] would pipe PROMPT.md into: claude -p --max-turns 40 --model opus ; then run the gate.
```
`--model opus` = `config.models.implement`, resolved via `Resolve-PhaseModel`. Run dir `run-021`
claimed atomically; per-run `.checkpoint`/`.budget.json` created inside it.

## Fleet dry-run (real worktree lifecycle, PS 5.1)
```
🚁 Fleet run-023 | 1 worker(s) (max 3) | base cb9c25d9 | model=opus
   - EXAMPLE-001: Example task — ...  [owns: src/example/]
[dry-run] would run in ...\harness\.worktrees\run-023-EXAMPLE-001 : claude -p --max-turns 40 --model opus
[dry-run] cleaned up worktrees. No model invoked.
```
Worktree + branch created from base snapshot and fully cleaned up; tree clean after.

## Fleet merge-queue live-fire (stub claude, BOTH runners)
Committed as repeatable integration tests: `harness/tests/fleet-queue-test.ps1` / `.sh`
(throwaway repo, 3 parallel workers via `HARNESS_CLAUDE_CMD` stub, one of which tampers with
`harness/loop.*`). Results this session:

- bash (`fleet.sh`, jq 1.7.1): **14/14** — T-A and T-B merged through the queue with gate re-run on
  each combined state, statuses recorded `validated`/`passes:true` by the runner, merged branches
  cleaned; T-EVIL **parked** ("touched protected path(s)"), its work absent from main, branch kept,
  reason ledgered and surfaced in `state/handoff.md`; tracked tree clean at exit.
- PowerShell 5.1 (`fleet.ps1`): **14/14** — same outcomes. (First run caught a real StrictMode
  scalar-`.Count` bug in the tamper check — fixed, which is the point of live-firing.)

## Self-test suites
- PowerShell: **67/67** (model routing 5, codex probe 3, fleet overlap/selection 8, run-id claim 2,
  plus all pre-existing).
- bash with jq on PATH: **63/63** (the jq-gated fleet/phase_model/run-id/gate/budget cases executed,
  not skipped). Without jq: 34/34 with the documented skips.

## Not yet live-fired (tracked in state/fix_plan.md)
- The codex *invoke* path against a real installed codex CLI (availability probe + fallback are
  tested; flag placement/`--output-last-message` parse verified against docs only).
- A fleet batch driven by real claude workers on a real project.
