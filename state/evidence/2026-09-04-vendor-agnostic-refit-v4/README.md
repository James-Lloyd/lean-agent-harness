# Evidence — vendor-agnostic refit V4: the second, read-only reviewer (2026-09-04)

Branch `worktree-feat+vendor-refit-v4-second-reviewer` (stacked on V3, PR #13), plugin 0.3.4,
design-doc `docs/design-docs/002-vendor-agnostic-routing.md` D4.

## User-visible behaviour: SHIP requires BOTH judges, and the second one has no fallback

New live-fire integration test pair `harness/tests/loop-review-test.{sh,ps1}` runs the REAL loop (via the
`harness/loop.*` wrappers → engine) in a throwaway repo with a stub `claude` that branches on the `--model`
the dispatcher passes: `impl-x` implements (writes a file, ticks the plan item), `primary-rev` always
SHIPs, `second-rev` SHIPs / REJECTs / hits a usage limit per `SECOND_MODE`. Config:
`review = { model: "primary-rev", second: { model: "second-rev", effort: "high" } }`, `reviewEveryNIterations: 1`.

Three real runs per twin, ledger (`harness/.runs/run-001/ledger.jsonl`) and handoff observed:

| scenario | ledger rows | handoff | `harness-reviewed` |
|---|---|---|---|
| second REJECTs | `green` → `review SHIP` → `review-second REJECT model=second-rev` → `review-stop` | "second reviewer (second-rev): REJECT" | not advanced |
| both SHIP | `green` → `review SHIP` → `review-second SHIP` | none | == HEAD |
| second capped (usage limit, exit 1) | `green` → `review SHIP` → `review-second ERROR` | "second reviewer (second-rev) could not run" | not advanced; exactly ONE second-review attempt (no fallback, no substitute model) |

The loop header now names the pair: `review=primary-rev +second=second-rev`. The second reviewer's
transcript lands in `review-second-after-<iter>.log`.

Bash ledger from the REJECT scenario (verbatim):

```
{"iter":1,"result":"green","path":"claude","usedFallback":false}
{"iter":1,"result":"review","path":"claude","verdict":"SHIP"}
{"iter":1,"result":"review-second","path":"claude","model":"second-rev","verdict":"REJECT"}
{"iter":1,"result":"review-stop"}
```

## A latent engine bug the live-fire caught (fixed in this slice)

The first bash run died silently right after the implement phase, before the gate. Cause: under the
loop's `set -euo pipefail`, `update_budget_from_log` in `lib/budget.sh` assigned
`max_in="$(grep … | sort | tail -1)"` — when the transcript has no JSON token counts (every
`meterTokens=false` run, i.e. the default), `grep` matches nothing, `pipefail` fails the pipeline, the
assignment fails, and errexit kills the loop. The existing unit test fed a log WITH counts, so it never
reached that branch. Fix: `|| true` on each extraction pipeline; regression assertions in both suites
(a no-count log survives `set -euo pipefail` / does not throw, and falls back to the 15000 estimate);
ratchet line in `plugin/engine/AGENTS.md`.

## Gate on the final tree

| Suite | Result |
|---|---|
| bash `harness/tests/run-tests.sh` | 289 passed, 0 failed (282 + 6 resolver + 1 budget regression) |
| PS 5.1 `harness/tests/run-tests.ps1` | 299 passed, 0 failed (292 + 6 + 1) |
| bash `loop-review-test.sh` (new) | 16 passed, 0 failed |
| PS 5.1 `loop-review-test.ps1` (new) | 16 passed, 0 failed |
| bash `fleet-queue-test.sh` | 31 passed, 0 failed |
| PS 5.1 `fleet-queue-test.ps1` | 31 passed, 0 failed |
| pwsh | not installed on this box — CI job `harness-selftest` covers it |

Both loop-review tests are wired into CI (`.github/workflows/harness-selftest.yml` and the
`ci/` template) beside the fleet-queue tests.

## Surfaces changed together

Engine: `lib/gate.sh` (`phase_second_model`, `phase_second_effort`), `lib/gate.ps1`
(`Resolve-PhaseSecondModel`, `Resolve-PhaseSecondEffort`), `loop.sh` (`second_review`), `loop.ps1`
(`Invoke-SecondReview`), `lib/budget.sh` (the fix). Contract: `harness.schema.json`
(`phaseRouting.second{model,effort}`), `/harness-doctor` 10(h), `model-routing` skill, `/review` step 3,
`plugin.json` 0.3.4. Tests: 6 resolver assertions per twin, 1 budget regression per twin, 16 live-fire
assertions per twin (incl. `second.effort` reaching the CLI as `--effort high`). Fresh-context review
findings applied: the second runs ONLY after the primary ships (all surfaces now say so), judge order
primary → second → evaluator stated everywhere, primary ledger row also records its model, an
unreachable codex second is labelled `codex` not `claude`, and `migrate.sh` had the same latent
no-match-grep-under-pipefail bug — fixed.

## Fresh-context review

Reviewer agent on `claude-fable-5-1`; verdict and applied findings recorded in the commit message.
