# Execution plan — Run the evaluator at the loop's periodic review point

_Authored 2026-07-15. Task from `state/fix_plan.md`: "Run the evaluator at the loop's periodic
review point (ROADMAP 'Inferential safeguards')". Self-contained: EXECUTE reads only this artifact._

## Goal / acceptance criteria (the done-condition, verbatim)
`verification.evaluator.enabled` also gates the **unattended loop** — the rubric
(`docs/principles/evaluator-rubric.md`) is scored at **each review point**, and **any below-threshold
criterion stops the loop like a REJECT**.

## Where this hooks in
The loop's periodic review point is `Invoke-PeriodicReview` (loop.ps1 ~L108) / `periodic_review`
(loop.sh ~L102), fired every `verification.reviewEveryNIterations` GREEN committed iterations from the
loop's green branch (loop.ps1 ~L341 / loop.sh ~L291). The fleet has **no** automated in-loop review
(it defers `/review` to a human — fleet.ps1 L299), so it is **out of scope**.

Design: the evaluator **augments the existing review point** — it does not create a new cadence. When
`evaluator.enabled` is true, after the fresh-context reviewer returns SHIP the loop also runs the
evaluator over the SAME `base..HEAD` batch; a FAIL (or no clear verdict, or any sub-threshold score)
stops the loop exactly like a REJECT (reject-handoff + ledger + break). Because it augments the review
point, it inherits its preconditions: `reviewEveryNIterations > 0` and `loop.commitOnGreen`.

## Files to touch (both engine twins stay capability-equivalent)
1. **`plugin/engine/lib/gate.ps1`** — add `Get-EvaluatorVerdict([string]$Text, [int]$FailBelow)`
   → `'PASS' | 'FAIL' | 'NONE'`. Fail-closed:
   - No text / no line matching `^\s*VERDICT:` → `NONE`.
   - Take the **last** `VERDICT:` line (mirror `Get-ReviewVerdict`): `PASS` → tentative PASS,
     `FAIL` → `FAIL`, anything else → `NONE`.
   - **Belt-and-braces threshold enforcement:** scan the whole text for `(\d+)\s*/\s*10`; if ANY
     captured number `< FailBelow`, return `FAIL` even if the summary line said PASS. This is what
     makes "any below-threshold criterion stops the loop" true in code, not just trusted from the
     model's own summary. (Over-matching a stray `N/10` in prose only ever produces a FALSE FAIL,
     which stops for a human — the safe, fail-closed direction; documented in the function comment.)
   - Return PASS only when verdict==PASS AND no sub-threshold score.
2. **`plugin/engine/lib/gate.sh`** — mirror as `evaluator_verdict()` reading stdin, arg `$1` =
   failBelow. Same fail-closed semantics using `grep -E`/`tail -1` + an awk/grep scan of `[0-9]+/10`.
3. **`plugin/engine/loop.ps1`**:
   - Preflight: resolve `$evalEnabled` (`verification.evaluator.enabled`, default false via Get-Prop),
     `$evalRoute = Resolve-PhaseModel $cfg 'evaluate'`, `$evalFallback = Resolve-PhaseFallback $cfg
     'evaluate'`, `$evalRubric` (default `docs/principles/evaluator-rubric.md`), `$evalFailBelow`
     (default 7).
   - Honest guard (mirrors the existing e2e/skipPermissions warnings): if `$evalEnabled` but
     `$reviewEveryN -le 0`, WARN that the evaluator won't run because there is no review point.
   - New `Invoke-PeriodicEvaluation` (shape parallels `Invoke-PeriodicReview`): builds a read-only
     evaluator prompt (read the rubric, inspect `git log/diff base..HEAD`, check specs/ acceptance
     criteria + `state/evidence/`, exercise evidence read-only, output EXACTLY the rubric format
     ending in `VERDICT: PASS|FAIL` applying the hard `failBelow` threshold), routes through
     `Invoke-Phase -Mode 'read-only'` with `-Primary $evalRoute -Fallback $evalFallback`, the same
     `--disallowedTools Edit Write MultiEdit NotebookEdit` + post-run hard reset as the reviewer,
     parses with `Get-EvaluatorVerdict $out $evalFailBelow`, ledgers `result='evaluate'`, and on
     non-PASS writes the reject-handoff (reuse `Write-Reject-Handoff` with an eval reason) + returns
     `$false`.
   - Green branch: after `Invoke-PeriodicReview` returns true, if `$evalEnabled` run
     `Invoke-PeriodicEvaluation`; advance the watermark only if BOTH pass, else ledger `review-stop`
     and break (restructure the existing if/else into `$ok = review; if ($ok -and $eval) { $ok = eval };
     if ($ok) {advance} else {break}`).
4. **`plugin/engine/loop.sh`** — mirror: resolve `EVAL_ENABLED/EVAL_ROUTE/EVAL_FALLBACK/EVAL_RUBRIC/
   EVAL_FAILBELOW`, warn-if-no-review-point, `periodic_evaluation()` calling `invoke_phase read-only`,
   parse via `evaluator_verdict`, same green-branch restructure.
5. **`harness/tests/run-tests.ps1`** + **`harness/tests/run-tests.sh`** — unit tests for the new
   verdict parser (see below). No live model call.
6. **Docs**: schema `verification.evaluator.enabled` description (say it gates the loop review point,
   requires reviewEveryNIterations>0); a one-line note in `evaluator-rubric.md` that the loop consumes
   the `VERDICT: PASS|FAIL` line + per-criterion `N/10` scores; `AGENT_NOTES.md` learning; PROGRESS.

## Test assertions (both runners)
- `PASS` when verdict PASS and all scores ≥ threshold: `"1. Correctness 8/10\nVERDICT: PASS"` + failBelow 7 → PASS.
- Sub-threshold score overrides a PASS summary: `"3. Robustness 5/10\nVERDICT: PASS"` + 7 → FAIL.
- Explicit `VERDICT: FAIL` → FAIL.
- No VERDICT line → NONE (fail-closed).
- Empty text → NONE.
- Mid-sentence `VERDICT: PASS` (not line-anchored) → NONE.
- `7/10` at threshold 7 is NOT below (strict `<`) → PASS.

## Out of scope
- Fleet merge-queue (no automated review point there).
- Changing the default `evaluator.enabled` (stays false — opt-in).
- The evaluator's own model tier / rubric content (uses config `evaluate` route = fable, failBelow=7).

## Verify (green baseline — must stay green)
`powershell harness/tests/run-tests.ps1` → 125/0 (+ new eval tests); `… fleet-queue-test.ps1` → 22/0.
Bash (jq on PATH): `bash harness/tests/run-tests.sh` → 116/0 (+ new); `… fleet-queue-test.sh` → 22/0.
E2E: a scripted end-to-end demonstrating the parser + a dry-run/stub showing the loop stops on a FAIL
verdict, captured under `state/evidence/2026-07-15-evaluator-review-point/`.
