#!/usr/bin/env bash
# Evidence (1): evaluator_verdict returns FAIL on a sub-threshold score and PASS on a clean sheet.
# Uses the REAL parser from plugin/engine/lib/gate.sh — no live model, no stubs of the function itself.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/plugin/engine/lib/gate.sh"

FAILBELOW=7   # = harness.config.json verification.evaluator.failBelow

# A realistic FULL rubric sheet whose summary line LIES "PASS" but Robustness is 5/10 (< 7).
read -r -d '' SUBTHRESHOLD <<'EOF' || true
VERDICT: PASS
1. Correctness   8/10 — meets the acceptance criteria
2. Evidence      9/10 — real end-to-end evidence captured
3. Guardrails    PASS  — none breached
4. Robustness    5/10 — only the happy path handled, no input validation
5. Fit & drift   8/10 — reuses existing helpers
6. Craft         n/a   — not user-visible
FIX LIST (if FAIL): loop.sh:266 — validate the phase exit code — add a guard
EOF

# A clean sheet: every applicable criterion >= 7, and a genuine PASS summary.
read -r -d '' CLEAN <<'EOF' || true
VERDICT: PASS
1. Correctness   9/10 — all acceptance criteria met, edge cases handled
2. Evidence      9/10 — real end-to-end evidence demonstrates the behavior
3. Guardrails    PASS  — no tests weakened, no specs edited
4. Robustness    8/10 — inputs validated, failure modes sane
5. Fit & drift   8/10 — no drift, no duplicated helpers
6. Craft         n/a   — not user-visible
EOF

echo "=== sub-threshold sheet (Robustness 5/10, summary lies PASS) ==="
printf '%s\n' "$SUBTHRESHOLD"
echo "--- evaluator_verdict $FAILBELOW =>"
V1="$(printf '%s\n' "$SUBTHRESHOLD" | evaluator_verdict "$FAILBELOW")"
echo "$V1"
[ "$V1" = "FAIL" ] || { echo "UNEXPECTED: wanted FAIL"; exit 1; }

echo
echo "=== clean sheet (all criteria >= 7) ==="
printf '%s\n' "$CLEAN"
echo "--- evaluator_verdict $FAILBELOW =>"
V2="$(printf '%s\n' "$CLEAN" | evaluator_verdict "$FAILBELOW")"
echo "$V2"
[ "$V2" = "PASS" ] || { echo "UNEXPECTED: wanted PASS"; exit 1; }

echo
echo "RESULT: sub-threshold => $V1 (loop STOPS like a REJECT), clean => $V2 (loop CONTINUES). OK."
