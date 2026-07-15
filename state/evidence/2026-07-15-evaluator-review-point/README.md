# Evidence — Run the evaluator at the loop's periodic review point (2026-07-15)

Acceptance criterion (from `docs/execution-plans/2026-07-15-evaluator-at-review-point.md`):
> `verification.evaluator.enabled` also gates the **unattended loop** — the rubric
> (`docs/principles/evaluator-rubric.md`) is scored at **each review point**, and **any below-threshold
> criterion stops the loop like a REJECT**.

All artifacts below use the REAL parser (`Get-EvaluatorVerdict` / `evaluator_verdict` in
`plugin/engine/lib/gate.*`) and the REAL green-branch decision block from `loop.*`. No live model is
invoked — only the two phase invocations (reviewer + evaluator) are stubbed in the wiring trace, and the
evaluator stub routes its verdict through the real parser.

## (1) Parser: FAIL on a sub-threshold score, PASS on a clean sheet
The core of "any below-threshold criterion stops the loop": a per-criterion `N/10` below `failBelow=7`
returns FAIL **even when the model's summary line said `VERDICT: PASS`** (belt-and-braces threshold scan).

- `parser-demo.sh` → `parser-demo.out.txt` — bash `evaluator_verdict 7`:
  sub-threshold sheet (Robustness 5/10, summary lies PASS) => **FAIL**; clean sheet (all >= 7) => **PASS**.
- `parser-demo.ps1` → `parser-demo.ps1.out.txt` — PowerShell `Get-EvaluatorVerdict … 7`: same **FAIL / PASS**
  (em-dashes render garbled in the console transcript — cosmetic encoding only; the verdicts are correct).

Also covered as unit tests next to the existing "review verdict" tests (7 cases each runner):
`harness/tests/run-tests.ps1` (suite 132/0) and `harness/tests/run-tests.sh` (suite 123/0).

## (2) Loop wiring: the eval call sits AT the review point, and a FAIL breaks the loop
- `loop-wiring-trace.sh` → `loop-wiring-trace.out.txt`:
  - Section 0 greps `plugin/engine/loop.sh` to show the call site — `periodic_evaluation` runs only after
    `periodic_review` returns SHIP (`review_ok -eq 0`) and only when `EVAL_ENABLED = true`, inside the same
    `REVIEW_EVERY_N > 0 … GREEN_COUNT % REVIEW_EVERY_N == 0` guard; a non-PASS falls through to the
    `review-stop` ledger + `break`.
  - Section 1 (enabled + sub-threshold sheet) => `evaluator_verdict FAIL` => **review-stop, BREAK** (loop
    STOPS for a human) — the acceptance criterion.
  - Section 2 (enabled + clean sheet) => `evaluator_verdict PASS` => watermark **ADVANCES** (loop CONTINUES).
  - Section 3 (disabled) => evaluator never consulted; review SHIP advances (pre-existing behavior preserved).
- `preflight-dryrun.out.txt` — a real `loop.sh --dry-run` on a throwaway repo whose config sets
  `verification.evaluator.enabled=true` with `reviewEveryNIterations=0`, proving the preflight resolves the
  evaluator config and fires the honest guard ("enabled … but reviewEveryNIterations <= 0 … will never run").

## Suite baselines (all green after this change)
| Suite | Before | After |
|-------|--------|-------|
| `harness/tests/run-tests.ps1` | 125/0 | **132/0** (+7 evaluator-verdict) |
| `harness/tests/fleet-queue-test.ps1` | 22/0 | **22/0** |
| `harness/tests/run-tests.sh` | 116/0 | **123/0** (+7 evaluator-verdict) |
| `harness/tests/fleet-queue-test.sh` | 22/0 | **22/0** |

## Reproduce
```
# parsers
bash   state/evidence/2026-07-15-evaluator-review-point/parser-demo.sh
powershell -File state/evidence/2026-07-15-evaluator-review-point/parser-demo.ps1
# wiring
bash   state/evidence/2026-07-15-evaluator-review-point/loop-wiring-trace.sh
# suites (bash suites need jq on PATH)
powershell harness/tests/run-tests.ps1 ; powershell harness/tests/fleet-queue-test.ps1
bash harness/tests/run-tests.sh ; bash harness/tests/fleet-queue-test.sh
```
