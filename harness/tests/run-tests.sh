#!/usr/bin/env bash
# run-tests.sh — self-tests for the harness's bash logic (mirror of run-tests.ps1).
# Self-contained. jq-dependent tests (the gate, budget) are skipped if jq is absent and run fully in CI.
# Exit 0 = all pass, exit 1 = a failure.
#   Run:  bash harness/tests/run-tests.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$HERE/.." && pwd)/lib"
HOOKS="$(cd "$HERE/../.." && pwd)/.claude/hooks"
PASS=0; FAIL=0
ok()  { if [ "$1" = "1" ]; then PASS=$((PASS+1)); echo "  ok  $2"; else FAIL=$((FAIL+1)); echo "  FAIL $2"; fi; }

echo "plan counter: grep -c emits a single clean count (the bug fix)"
tmp="$(mktemp)"
printf '%s\n' '- [ ] one' '- [x] done' '<!-- - [ ] commented -->' '- [ ] two' > "$tmp"
n="$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[ \]' "$tmp" || true)"; n="${n:-0}"
ok "$([ "$n" = "2" ] && echo 1 || echo 0)" "counts 2 open items, single line (got '$n')"
: > "$tmp"   # empty plan
e="$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[ \]' "$tmp" || true)"; e="${e:-0}"
ok "$([ "$e" = "0" ] && echo 1 || echo 0)" "empty plan => 0 (no double line) (got '$e')"
rm -f "$tmp"

echo "block-destructive hook: blocks dangerous, allows safe"
hookrc() {  # $1 = command (no quotes/backslashes in our test inputs) ; echoes hook exit code
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" \
    | bash "$HOOKS/block-destructive.sh" >/dev/null 2>&1; echo $?
}
rmfr='rm -fr build'; pushf='git push -f origin main'; finddel='find . -delete'
resetx='git reset --hard abc1234'; grepsec='grep x .env'
ok "$([ "$(hookrc "$rmfr")"   = "2" ] && echo 1 || echo 0)" "blocks rm -fr (flag order)"
ok "$([ "$(hookrc "$pushf")"  = "2" ] && echo 1 || echo 0)" "blocks git push -f (short flag)"
ok "$([ "$(hookrc "$finddel")" = "2" ] && echo 1 || echo 0)" "blocks find -delete"
ok "$([ "$(hookrc "$resetx")" = "2" ] && echo 1 || echo 0)" "blocks git reset --hard <sha>"
ok "$([ "$(hookrc "$grepsec")" = "2" ] && echo 1 || echo 0)" "blocks secret read via grep"
ok "$([ "$(hookrc 'git status')"      = "0" ] && echo 1 || echo 0)" "allows git status"
ok "$([ "$(hookrc 'npm test')"        = "0" ] && echo 1 || echo 0)" "allows npm test"
ok "$([ "$(hookrc 'git push origin feature')" = "0" ] && echo 1 || echo 0)" "allows normal git push"

if command -v jq >/dev/null 2>&1; then
  echo "gate (jq present): multi-component pass + failure attribution"
  SCRIPT_DIR="$(cd "$HERE/.." && pwd)"; REPO_ROOT="$SCRIPT_DIR/.."
  # shellcheck source=../lib/gate.sh
  source "$LIB/gate.sh"; source "$LIB/budget.sh"
  passcfg="$(mktemp)"; cat > "$passcfg" <<'JSON'
{ "components":[ {"name":"frontend","path":".","gate":{"format":"true","test":"true"}},
                 {"name":"backend","path":".","gate":{"format":"true","test":"true"}} ],
  "gate":{"e2e":"true"} }
JSON
  if run_gate "$passcfg"; then ok 1 "multi-component all-green passes"; else ok 0 "multi-component all-green passes"; fi
  failcfg="$(mktemp)"; cat > "$failcfg" <<'JSON'
{ "components":[ {"name":"frontend","path":".","gate":{"format":"true"}},
                 {"name":"backend","path":".","gate":{"format":"true","lint":"false"}} ],
  "gate":{} }
JSON
  if run_gate "$failcfg"; then ok 0 "failure attributed to backend:lint"; else ok "$([ "$GATE_FAILED_STEP" = "backend:lint" ] && echo 1 || echo 0)" "failure attributed to backend:lint (got '$GATE_FAILED_STEP')"; fi
  reset_budget; ok "$([ "$(_budget_spent)" = "0" ] && echo 1 || echo 0)" "budget resets to 0"
  rm -f "$passcfg" "$failcfg"
else
  echo "  (skipping jq-dependent gate/budget tests — jq not installed)"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
