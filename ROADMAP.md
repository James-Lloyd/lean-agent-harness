# Roadmap

This harness is **v0.1** and honest about it. An adversarial four-lens review (functional, best-in-class,
coherence, safety) shaped this list. The items below are deliberately **not yet built** — they're the
gap between "strong" and "best-in-class." Each says what's true today so nothing here reads as a claim
the code doesn't back. (Ratchet them in as real use demands.)

## Inferential safeguards in the *auto* loop
- **Now wired (opt-in):** `verification.reviewEveryNIterations` (default 0 = off). When > 0, the loop
  spawns a fresh-context **reviewer** headless over the last N commits every N green iterations; a
  *REJECT* verdict records the finding to `state/handoff.md` and stops the loop for a human. This puts
  "doer ≠ judge" into the unattended path, not just supervised `/work`·`/review`.
- **Still deterministic-by-default:** with `reviewEveryNIterations = 0` the loop runs only the gate then
  commits (as before). The loop still can't *manufacture* judgment between review points.
- **Planned next:** also run the skeptical **evaluator** (rubric thresholds) at the review point, and
  auto-revert the rejected batch rather than only stopping. For now a *reject* halts for human triage.

## Real token metering
- **Now wired (opt-in):** `autonomy.meterTokens` (default false). When true the loop invokes the model
  with `--output-format json` and the budget parser reads real `usage` (input+output tokens), making
  `tokenBudget` an **exact** cap. Trade-off: the per-iteration log is JSON, not streamed text.
- **Default (meterTokens=false):** `tokenBudget` is a per-run **estimate** (~15k/iteration fallback);
  the hard runaway bounds remain `maxIterations` + `maxTurnsPerIteration`.
- **Planned:** roll cost (`total_cost_usd`) into the ledger and a per-run summary.

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
- **Known gap:** the `block-destructive` hook is wired to the **`Bash`** matcher only. If a runtime also
  exposes another shell tool (e.g. a PowerShell tool on Windows), destructive commands issued through
  *that* tool bypass the denylist. Stock Claude Code uses `Bash`, so this only bites on runtimes that add
  a second shell tool — but it's a reason not to rely on the hook alone.
- **Planned:** a documented container/VM profile (no host FS, no outbound network, ephemeral, secrets via
  env) as the supported way to run `auto` + `skipPermissions`; and per-shell-tool matchers for the hook.

## "Re-examine the harness on every new model"
- **Today:** stated as a principle, no artifact.
- **Planned:** a short `docs/principles/model-upgrade-checklist.md` — what to strip/re-test when a new
  model lands (the harness is a set of bets about model weaknesses; some expire).
