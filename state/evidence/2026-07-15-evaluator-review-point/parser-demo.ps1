# Evidence (1), PowerShell twin: Get-EvaluatorVerdict returns FAIL on a sub-threshold score and PASS on a
# clean sheet. Uses the REAL parser from plugin/engine/lib/gate.ps1 — no live model, no function stubs.
$ErrorActionPreference = 'Stop'
$root = (& git rev-parse --show-toplevel).Trim()
. (Join-Path $root 'plugin/engine/lib/gate.ps1')

$failBelow = 7   # = harness.config.json verification.evaluator.failBelow

$subthreshold = @"
VERDICT: PASS
1. Correctness   8/10 — meets the acceptance criteria
2. Evidence      9/10 — real end-to-end evidence captured
3. Guardrails    PASS  — none breached
4. Robustness    5/10 — only the happy path handled, no input validation
5. Fit & drift   8/10 — reuses existing helpers
6. Craft         n/a   — not user-visible
FIX LIST (if FAIL): loop.ps1:305 — validate the phase exit code — add a guard
"@

$clean = @"
VERDICT: PASS
1. Correctness   9/10 — all acceptance criteria met, edge cases handled
2. Evidence      9/10 — real end-to-end evidence demonstrates the behavior
3. Guardrails    PASS  — no tests weakened, no specs edited
4. Robustness    8/10 — inputs validated, failure modes sane
5. Fit & drift   8/10 — no drift, no duplicated helpers
6. Craft         n/a   — not user-visible
"@

Write-Host "=== sub-threshold sheet (Robustness 5/10, summary lies PASS) ==="
Write-Host $subthreshold
$v1 = Get-EvaluatorVerdict $subthreshold $failBelow
Write-Host "--- Get-EvaluatorVerdict $failBelow => $v1"
if ($v1 -ne 'FAIL') { throw "UNEXPECTED: wanted FAIL, got $v1" }

Write-Host ""
Write-Host "=== clean sheet (all criteria >= 7) ==="
Write-Host $clean
$v2 = Get-EvaluatorVerdict $clean $failBelow
Write-Host "--- Get-EvaluatorVerdict $failBelow => $v2"
if ($v2 -ne 'PASS') { throw "UNEXPECTED: wanted PASS, got $v2" }

Write-Host ""
Write-Host "RESULT: sub-threshold => $v1 (loop STOPS like a REJECT), clean => $v2 (loop CONTINUES). OK."
