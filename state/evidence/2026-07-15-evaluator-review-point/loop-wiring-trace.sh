#!/usr/bin/env bash
# Evidence (2): the evaluator call sits at the loop's periodic review point, and an evaluator FAIL breaks
# the loop (review-stop) while a PASS advances the watermark. We execute the EXACT green-branch decision
# block copied verbatim from plugin/engine/loop.sh, driving it with a stub periodic_review (returns SHIP)
# and a periodic_evaluation that routes a rubric sheet through the REAL evaluator_verdict from gate.sh.
# No live model — the decision logic and the parser are real; only the two phase invocations are stubbed.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/plugin/engine/lib/gate.sh"   # real evaluator_verdict

echo "### 0. Proof the call sits AT the review point (source lines from loop.sh):"
grep -nE 'REVIEW_EVERY_N.*-gt 0|periodic_review |periodic_evaluation |EVAL_ENABLED. = .true|review-stop|REVIEW_BASE=' \
  "$ROOT/plugin/engine/loop.sh" | sed -n '1,12p'
echo

# --- stubs standing in for the two phase invocations (loop globals they read) ---
EVAL_FAILBELOW=7
ledger() { echo "     ledger => $1"; }
periodic_review() { echo "  🧑‍⚖️  [stub] fresh-context review => SHIP"; return 0; }   # reviewer SHIPs
# periodic_evaluation mirrors the real function's verdict handling: pipe $SHEET through the REAL parser.
periodic_evaluation() {
  local v; v="$(printf '%s\n' "$SHEET" | evaluator_verdict "$EVAL_FAILBELOW")"
  echo "  🧮  [stub-driven, REAL parser] evaluator_verdict => $v"
  [ "$v" = "PASS" ] && return 0 || return 1
}

# The green-branch decision block, copied verbatim from loop.sh (GREEN_COUNT%REVIEW_EVERY_N==0 already true).
run_review_point() {
  REVIEW_EVERY_N=1; GREEN_COUNT=1; i=42; REVIEW_BASE="BASE"
  git() { echo "NEWHEAD"; }   # local shadow so REVIEW_BASE advance is observable without a real repo
  if [ "$REVIEW_EVERY_N" -gt 0 ] && [ "true" = "true" ] && [ $((GREEN_COUNT % REVIEW_EVERY_N)) -eq 0 ]; then
    if periodic_review "$REVIEW_BASE" "RUN" "$i"; then review_ok=0; else review_ok=1; fi
    if [ "$review_ok" -eq 0 ] && [ "$EVAL_ENABLED" = "true" ]; then
      if periodic_evaluation "$REVIEW_BASE" "RUN" "$i"; then review_ok=0; else review_ok=1; fi
    fi
    if [ "$review_ok" -eq 0 ]; then
      REVIEW_BASE="$(git rev-parse HEAD)"; echo "  ==> OUTCOME: watermark ADVANCED to $REVIEW_BASE (loop CONTINUES)"
    else
      ledger "{\"iter\":$i,\"result\":\"review-stop\"}"; echo "  ==> OUTCOME: review-stop, BREAK (loop STOPS for a human)"
    fi
  fi
  unset -f git
}

echo "### 1. evaluator ENABLED, sub-threshold sheet (Robustness 5/10) — expect STOP:"
EVAL_ENABLED=true
SHEET=$'VERDICT: PASS\n1. Correctness 8/10\n4. Robustness 5/10'
run_review_point
echo

echo "### 2. evaluator ENABLED, clean sheet (all >= 7) — expect CONTINUE:"
EVAL_ENABLED=true
SHEET=$'VERDICT: PASS\n1. Correctness 9/10\n4. Robustness 8/10'
run_review_point
echo

echo "### 3. evaluator DISABLED — evaluator never runs, review SHIP advances (unchanged behavior):"
EVAL_ENABLED=false
SHEET=$'(evaluator not consulted)'
run_review_point
