#!/usr/bin/env bash
# Deterministic Bash twin of codex-timeout-test.ps1. No model or network is used.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)"
ENGINE="$SRC/plugin/engine"
INVOKE_LIB="${1:-$ENGINE/lib/invoke-codex.sh}"
TIMEOUT_ONLY="${CODEX_TIMEOUT_TEST_TIMEOUT_ONLY:-0}"
EVIDENCE="${CODEX_TIMEOUT_EVIDENCE_DIR:-}"
[ -n "$EVIDENCE" ] && mkdir -p "$EVIDENCE"
# shellcheck source=../../plugin/engine/lib/invoke-codex.sh
source "$INVOKE_LIB"
WORK="$(mktemp -d)"
cleanup() { cd /; rm -rf "$WORK"; }
trap cleanup EXIT
pass=0; fail=0
ok() { if [ "$1" = 1 ]; then pass=$((pass+1)); echo "  ok  $2"; else fail=$((fail+1)); echo "  FAIL $2"; fi; }

STUB="$WORK/stub-codex"
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then exit 0; fi
cat >/dev/null
last=""; root=""; prev=""
for arg in "$@"; do
  [ "$prev" = --output-last-message ] && last="$arg"
  [ "$prev" = --cd ] && root="$arg"
  prev="$arg"
done
case "${CODEX_TIMEOUT_STUB_MODE:-timeout}" in
  success) echo ordinary-success; [ -n "$last" ] && printf final-success > "$last"; exit 0;;
  failure) echo ordinary-failure >&2; exit 7;;
  *)
    [ -n "$root" ] && [ -f "$root/tracked.txt" ] && printf changed-before-timeout > "$root/tracked.txt"
    echo partial-before-timeout
    sleep 4
    echo output-after-kill;;
esac
STUB
chmod +x "$STUB"
watchdog='[codex timed out after 1s — watchdog kill, failing closed]'
# Warm the MSYS process image before the deliberately tight one-second budget. The real loop does the
# same through `codex login status`; without this, a cold Windows bash startup can consume the budget
# before the stub reaches its first echo, testing host startup latency rather than log durability.
"$STUB" login status

echo 'codex timeout helper: preserves output produced before the watchdog kill'
export CODEX_TIMEOUT_STUB_MODE=timeout
log="$WORK/helper-timeout.log"
if invoke_codex workspace-write 'test prompt' "$WORK" "$log" '' '' 1 "$STUB" >/dev/null; then rc=0; else rc=$?; fi
text="$(cat "$log" 2>/dev/null || true)"
early="$(grep -nF partial-before-timeout "$log" 2>/dev/null | head -1 | cut -d: -f1 || true)"
watch="$(grep -nF "$watchdog" "$log" 2>/dev/null | head -1 | cut -d: -f1 || true)"
ok "$([ "$rc" -eq 124 ] && echo 1 || echo 0)" 'timeout returns watchdog failure code 124'
ok "$([ -n "$early" ] && echo 1 || echo 0)" 'timeout log keeps partial-before-timeout'
ok "$([ -n "$early" ] && [ -n "$watch" ] && [ "$watch" -gt "$early" ] && echo 1 || echo 0)" 'watchdog verdict follows the early marker exactly'
ok "$(! grep -qF output-after-kill "$log" 2>/dev/null && echo 1 || echo 0)" 'timeout log excludes output scheduled after the kill'
[ -n "$EVIDENCE" ] && cp "$log" "$EVIDENCE/helper-timeout.log"

if [ "$TIMEOUT_ONLY" != 1 ]; then
  echo 'codex ordinary paths: success/failure result shape stays intact'
  export CODEX_TIMEOUT_STUB_MODE=success
  success_log="$WORK/helper-success.log"
  if success_out="$(invoke_codex read-only 'test prompt' "$WORK" "$success_log" '' '' 30 "$STUB")"; then success_rc=0; else success_rc=$?; fi
  ok "$([ "$success_rc" -eq 0 ] && [ "$success_out" = final-success ] && echo 1 || echo 0)" 'ordinary success stays successful and prefers final-message output'
  ok "$(grep -qF ordinary-success "$success_log" && echo 1 || echo 0)" 'ordinary success transcript is durable'
  export CODEX_TIMEOUT_STUB_MODE=failure
  failure_log="$WORK/helper-failure.log"
  if invoke_codex read-only 'test prompt' "$WORK" "$failure_log" '' '' 30 "$STUB" >/dev/null; then failure_rc=0; else failure_rc=$?; fi
  ok "$([ "$failure_rc" -eq 7 ] && echo 1 || echo 0)" 'ordinary failure keeps its exit code'
  ok "$(grep -qF ordinary-failure "$failure_log" && echo 1 || echo 0)" 'ordinary failure keeps stderr'

  echo 'codex timeout loop: invoke-error rolls back while the durable run log survives'
  REPO="$WORK/repo"
  mkdir -p "$REPO/harness" "$REPO/state"
  cp "$SRC/harness/loop.sh" "$REPO/harness/loop.sh"
  cat > "$REPO/harness/harness.config.json" <<'JSON'
{
  "project": { "type": "greenfield", "baseline": { "established": false, "ref": null } },
  "models": {
    "implement": { "model": "codex", "fallback": null },
    "review": { "model": "review-unused", "fallback": null },
    "evaluate": { "model": "evaluate-unused", "fallback": null },
    "codex": { "model": null, "reasoningEffort": "high", "auth": "chatgpt", "timeoutSeconds": 1 }
  },
  "autonomy": { "mode": "auto", "maxIterations": 1, "maxTurnsPerIteration": 2, "tokenBudget": null, "meterTokens": false, "skipPermissions": false,
    "checkpoints": { "planApproval": false, "beforeRiskyOps": false, "everyNIterations": 0 } },
  "loop": { "promptFile": "PROMPT.md", "planFile": "state/fix_plan.md", "progressFile": "state/PROGRESS.md",
    "oneItemPerIteration": true, "autoRollbackOnRed": true, "commitOnGreen": false, "tagOnGreen": false, "stopWhenPlanEmpty": true },
  "verification": { "requireE2EEvidence": false, "reviewEveryNIterations": 0, "evaluator": { "enabled": false } },
  "components": [ { "name": "root", "path": ".", "gate": { "format": null, "lint": null, "typecheck": null, "build": null, "test": "exit 0", "e2e": null } } ],
  "gate": { "format": null, "lint": null, "typecheck": null, "build": null, "test": null, "e2e": null }
}
JSON
  printf '## Tasks\n- [ ] timeout thing\n' > "$REPO/state/fix_plan.md"
  printf '{ "version": 2, "tasks": [] }\n' > "$REPO/state/tasks.json"
  printf '%s\n' '- init' > "$REPO/state/PROGRESS.md"
  printf 'exercise timeout\n' > "$REPO/PROMPT.md"
  printf original > "$REPO/tracked.txt"
  printf 'harness/.runs/\nharness/.worktrees/\nstate/handoff.md\n' > "$REPO/.gitignore"
  cp "$STUB" "$WORK/codex"
  (
    cd "$REPO" || exit 1
    git init -q -b main
    git config core.autocrlf false
    git config user.email timeout-test@example.com
    git config user.name 'Timeout Test'
    git add -A && git commit -q -m init
    base="$(git rev-parse HEAD)"
    PATH="$WORK:$PATH" HARNESS_ENGINE="$ENGINE" HARNESS_SANDBOX=1 CODEX_TIMEOUT_STUB_MODE=timeout \
      bash harness/loop.sh --mode auto --max 1 > "$WORK/loop.out" 2>&1 || true
    head="$(git rev-parse HEAD)"; status="$(git status --porcelain)"
    ledger="$(cat harness/.runs/run-001/ledger.jsonl 2>/dev/null || true)"
    iter='harness/.runs/run-001/iter-1.log'
    loop_early="$(grep -nF partial-before-timeout "$iter" 2>/dev/null | head -1 | cut -d: -f1 || true)"
    loop_watch="$(grep -nF "$watchdog" "$iter" 2>/dev/null | head -1 | cut -d: -f1 || true)"
    ok "$(grep -qF '"result":"invoke-error"' <<< "$ledger" && grep -qF '"path":"codex"' <<< "$ledger" && grep -qF '"reason":"invoke-failed"' <<< "$ledger" && echo 1 || echo 0)" 'loop records invoke-error for the Codex route'
    ok "$([ "$head" = "$base" ] && echo 1 || echo 0)" 'loop restores the exact pre-iteration commit'
    ok "$([ "$(cat tracked.txt)" = original ] && [ -z "$status" ] && echo 1 || echo 0)" 'loop restores the tracked file and leaves the worktree clean'
    ok "$([ -n "$loop_early" ] && [ -n "$loop_watch" ] && [ "$loop_watch" -gt "$loop_early" ] && echo 1 || echo 0)" 'durable iteration log keeps early marker before watchdog verdict'
    ok "$(! grep -qF output-after-kill "$iter" 2>/dev/null && echo 1 || echo 0)" 'durable iteration log excludes output scheduled after the kill'
    if [ -n "$EVIDENCE" ]; then
      cp harness/.runs/run-001/ledger.jsonl "$EVIDENCE/loop-ledger.jsonl"
      cp "$iter" "$EVIDENCE/loop-iter-1.log"
      { printf 'BASE=%s\nHEAD=%s\nSTATUS=%s\nTRACKED=%s\n' "$base" "$head" "$status" "$(cat tracked.txt)"
        sed -e "s|$WORK|<TMP>|g" -e "s|$SRC|<REPO>|g" "$WORK/loop.out"
      } > "$EVIDENCE/loop-result.txt"
    fi
    printf '%s %s\n' "$pass" "$fail" > "$WORK/loop-counts"
  )
  read -r pass fail < "$WORK/loop-counts"
fi
unset CODEX_TIMEOUT_STUB_MODE
echo
echo "CODEX TIMEOUT RESULT: $pass passed, $fail failed"
[ -n "$EVIDENCE" ] && printf 'PASSED=%s\nFAILED=%s\n' "$pass" "$fail" > "$EVIDENCE/test-result.txt"
[ "$fail" -eq 0 ]
