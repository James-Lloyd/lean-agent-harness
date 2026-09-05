#!/usr/bin/env bash
# loop-review-test.sh - integration test for the loop's REVIEW POINT with a SECOND reviewer (bash side;
# design-doc 002 D4). Live-fires harness/loop.sh in a throwaway repo with a stub claude
# (HARNESS_CLAUDE_CMD) whose behaviour branches on the --model the dispatcher passes:
#   impl-x      the implementer: writes a file and ticks the plan item (so the gate goes green + commits)
#   primary-rev the primary reviewer: always VERDICT: SHIP
#   second-rev  the second reviewer: VERDICT: SHIP | VERDICT: REJECT | a usage-limit failure, per $SECOND_MODE
# Three runs assert the contract: SHIP requires BOTH judges; a REJECT from the second stops the loop with
# a handoff naming it; an unavailable/capped second reviewer FAILS CLOSED (no fallback - a substitute
# model is not the configured second opinion); both verdicts land in the ledger; the harness-reviewed
# watermark advances only when both ship. Requires jq + git; skips cleanly without jq.
#   Run:  bash harness/tests/loop-review-test.sh
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "(skipping loop review test - jq not installed)"; exit 0; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_SRC="$(cd "$HERE/../.." && pwd)"
export HARNESS_ENGINE="$HARNESS_SRC/plugin/engine"
WORK="$(mktemp -d)"
cleanup() { cd /; rm -rf "$WORK"; }
trap cleanup EXIT

pass=0; fail=0
ok() { if [ "$1" = "1" ]; then pass=$((pass+1)); echo "  ok  $2"; else fail=$((fail+1)); echo "  FAIL $2"; fi; }

# Stub claude lives OUTSIDE the repos (an untracked file inside would fail the clean-tree preflight).
cat > "$WORK/stub-claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null   # drain the piped prompt
model=""; effort=""; prev=""
for a in "$@"; do [ "$prev" = "--model" ] && model="$a"; [ "$prev" = "--effort" ] && effort="$a"; prev="$a"; done
[ -n "${STUB_ARGV_LOG:-}" ] && printf '%s effort=%s\n' "$model" "$effort" >> "$STUB_ARGV_LOG"
case "$model" in
  impl-x)
    mkdir -p out && echo "built" > out/a.txt
    sed -i.bak 's/^- \[ \] build thing/- [x] build thing/' state/fix_plan.md && rm -f state/fix_plan.md.bak
    echo "implemented"; exit 0;;
  primary-rev)
    echo "Reviewed the batch; nothing blocker-grade."; echo "VERDICT: SHIP"; exit 0;;
  second-rev)
    case "${SECOND_MODE:-reject}" in
      ship)   echo "Second opinion: agree."; echo "VERDICT: SHIP"; exit 0;;
      cap)    echo "Error: monthly usage limit reached"; exit 1;;
      *)      echo "Second opinion: found a blocker the first judge missed."; echo "VERDICT: REJECT"; exit 0;;
    esac;;
  *) echo "stub: unexpected model '$model'" >&2; exit 1;;
esac
STUB
chmod +x "$WORK/stub-claude"

make_repo() {  # $1 dir ; a throwaway harness project whose review phase has a second reviewer
  local T="$1"; mkdir -p "$T"; cd "$T"
  git init -q -b main
  git config core.autocrlf false
  git config user.email loop-test@example.com
  git config user.name "Loop Test"
  cp -r "$HARNESS_SRC/harness" .
  rm -rf harness/.runs harness/.worktrees
  mkdir -p state
  cat > harness/harness.config.json <<'JSON'
{
  "project": { "type": "greenfield", "baseline": { "established": false, "ref": null } },
  "models": {
    "implement": { "model": "impl-x", "fallback": null },
    "review":    { "model": "primary-rev", "fallback": null, "second": { "model": "second-rev", "effort": "high" } }
  },
  "autonomy": { "mode": "auto", "maxIterations": 1, "maxTurnsPerIteration": 10, "tokenBudget": null, "meterTokens": false, "skipPermissions": false,
                "checkpoints": { "planApproval": false, "beforeRiskyOps": false, "everyNIterations": 0 } },
  "loop": { "promptFile": "PROMPT.md", "planFile": "state/fix_plan.md", "progressFile": "state/PROGRESS.md",
            "oneItemPerIteration": true, "autoRollbackOnRed": true, "commitOnGreen": true, "tagOnGreen": false, "stopWhenPlanEmpty": true },
  "verification": { "requireE2EEvidence": false, "reviewEveryNIterations": 1, "evaluator": { "enabled": false } },
  "components": [ { "name": "root", "path": ".", "gate": { "format": null, "lint": null, "typecheck": null, "build": null, "test": "exit 0", "e2e": null } } ],
  "gate": { "format": null, "lint": null, "typecheck": null, "build": null, "test": null, "e2e": null }
}
JSON
  printf '## Tasks\n- [ ] build thing\n' > state/fix_plan.md
  printf '{ "version": 2, "tasks": [] }\n' > state/tasks.json
  echo "- init" > state/PROGRESS.md
  echo "do the top task" > PROMPT.md
  printf 'harness/.runs/\nharness/.worktrees/\nstate/handoff.md\n' > .gitignore
  git add -A && git commit -q -m "init"
}

run_loop() {  # $1 second mode ; runs one auto iteration with the stub claude
  SECOND_MODE="$1" STUB_ARGV_LOG="$WORK/argv-$1.log" HARNESS_CLAUDE_CMD="$WORK/stub-claude" bash harness/loop.sh --mode auto --max 1 > "$WORK/loop-$1.out" 2>&1 || true
}
ledger_has() { grep -q "$1" harness/.runs/run-001/ledger.jsonl 2>/dev/null; }

echo "loop review point: second reviewer REJECT stops the loop (SHIP requires both)"
make_repo "$WORK/reject"; run_loop reject
ok "$(ledger_has '"result":"review","path":"claude","model":"primary-rev","verdict":"SHIP"' && echo 1 || echo 0)" "ledger: primary reviewer SHIP, model recorded"
ok "$(ledger_has '"result":"review-second","path":"claude","model":"second-rev","verdict":"REJECT"' && echo 1 || echo 0)" "ledger: second reviewer REJECT, model recorded"
ok "$(ledger_has '"result":"review-stop"' && echo 1 || echo 0)"                                        "ledger: loop stopped at the review point"
ok "$(grep -q 'second reviewer (second-rev): REJECT' state/handoff.md 2>/dev/null && echo 1 || echo 0)" "handoff names the second reviewer's REJECT"
ok "$([ -z "$(git tag -l harness-reviewed)" ] && echo 1 || echo 0)"                                     "harness-reviewed watermark NOT advanced"
ok "$([ -f harness/.runs/run-001/review-second-after-1.log ] && echo 1 || echo 0)"                     "second reviewer transcript written"
ok "$(grep -q 'review=primary-rev +second=second-rev' "$WORK/loop-reject.out" && echo 1 || echo 0)"    "loop header names the second reviewer"
ok "$(grep -qx 'second-rev effort=high' "$WORK/argv-reject.log" && echo 1 || echo 0)"                    "second.effort reaches the CLI (--effort high)"

echo "loop review point: both SHIP => watermark advances, no handoff"
make_repo "$WORK/ship"; run_loop ship
ok "$(ledger_has '"result":"review-second","path":"claude","model":"second-rev","verdict":"SHIP"' && echo 1 || echo 0)" "ledger: second reviewer SHIP"
ok "$(ledger_has '"result":"review-stop"' && echo 0 || echo 1)"                                        "ledger: no review-stop"
ok "$([ "$(git rev-parse harness-reviewed 2>/dev/null)" = "$(git rev-parse HEAD)" ] && echo 1 || echo 0)" "harness-reviewed watermark == HEAD"
ok "$(grep -q 'Needs human decision' state/handoff.md 2>/dev/null && echo 0 || echo 1)"                "no handoff written"

echo "loop review point: a capped second reviewer FAILS CLOSED (no fallback, no substitute model)"
make_repo "$WORK/cap"; run_loop cap
ok "$(ledger_has '"result":"review-second","path":"claude","model":"second-rev","verdict":"ERROR"' && echo 1 || echo 0)" "ledger: second reviewer ERROR"
ok "$(grep -q 'second reviewer (second-rev) could not run' state/handoff.md 2>/dev/null && echo 1 || echo 0)" "handoff: second reviewer could not run"
ok "$([ -z "$(git tag -l harness-reviewed)" ] && echo 1 || echo 0)"                                     "watermark NOT advanced on a capped second reviewer"
ok "$(grep -c '"result":"review-second"' harness/.runs/run-001/ledger.jsonl | grep -qx 1 && echo 1 || echo 0)" "exactly one second-review attempt (no retry on another model)"

echo
echo "LOOP REVIEW RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
