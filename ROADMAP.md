# Roadmap

This harness is **v0.1** and honest about it. An adversarial four-lens review (functional, best-in-class,
coherence, safety) shaped this list. The items below are deliberately **not yet built** — they're the
gap between "strong" and "best-in-class." Each says what's true today so nothing here reads as a claim
the code doesn't back. (Ratchet them in as real use demands.)

## Inferential safeguards in the *auto* loop
- **Today:** the unattended `loop.ps1`/`loop.sh` runs only the deterministic gate, then commits. The
  fresh-context **review** and the skeptical **evaluator** ("doer ≠ judge") run only in the supervised
  `/work`·`/review` paths. The loop warns when `requireE2EEvidence` is set but no e2e step exists, but
  it can't *manufacture* judgment.
- **Planned:** an opt-in `verification.reviewEveryNIterations` that spawns the `reviewer` (and optionally
  the `evaluator`) headless every N green iterations, failing the batch back to work on a *reject*.
- **Until then:** for long auto runs, run `/review` periodically by hand; configure a real `e2e` step.

## Real token metering
- **Today:** `tokenBudget` is a per-run **estimate** (claude `-p` text mode rarely emits counts; we fall
  back to ~15k/iteration). The hard runaway bounds are `maxIterations` + `maxTurnsPerIteration`.
- **Planned:** invoke with `--output-format json` and parse `usage` for exact per-iteration tokens/cost,
  making `tokenBudget` a true cap.

## LSP / diagnostics as a live sensor
- **Today:** profiles record `lsp.servers` as *informational*; the real mechanism is the `typecheck`
  gate step. "Prefer LSP over guessing" has no wiring.
- **Planned:** surface IDE/LSP diagnostics (e.g. `mcp__ide__getDiagnostics`) into `/verify` and the
  PostToolUse hook; ship a `.mcp.json` template.

## Parallel task execution across worktrees
- **Today:** read-only subagents fan out, but *task* execution is strictly sequential; the
  `brownfield-safety` skill mentions worktrees without a mechanism.
- **Planned:** a worktree-pool runner that executes independent tasks in parallel, each isolated, with a
  serialized merge/gate (the "fan out reads, serialize the gate" idea extended to writes).

## Observability beyond the run ledger
- **Today:** each run writes per-iteration `iter-N.log` + a JSONL `ledger.jsonl` (task result, failed
  step). No cost/latency rollup, no cross-run history.
- **Planned:** a run summary (durations, pass-rate, gate-step failure histogram) to debug and score long
  runs, and to feed an eval history.

## Sandboxing for unattended runs
- **Today:** the destructive-command hook is defense-in-depth and now covers far more (and fails closed
  on a denylist hit), but it is a denylist, not a sandbox; `--dangerously-skip-permissions` voids the
  permission deny-list entirely.
- **Planned:** a documented container/VM profile (no host FS, no outbound network, ephemeral, secrets via
  env) as the supported way to run `auto` + `skipPermissions`.

## "Re-examine the harness on every new model"
- **Today:** stated as a principle, no artifact.
- **Planned:** a short `docs/principles/model-upgrade-checklist.md` — what to strip/re-test when a new
  model lands (the harness is a set of bets about model weaknesses; some expire).
