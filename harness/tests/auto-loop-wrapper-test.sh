#!/usr/bin/env bash
# Bash twin: live no-commit preservation, truthful warnings, and cache-version wrapper resolution.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)"; ENGINE="${HARNESS_TEST_ENGINE:-$SRC/plugin/engine}"; WORK="$(mktemp -d)"
cleanup() { cd /; rm -rf "$WORK"; }; trap cleanup EXIT
pass=0; fail=0
ok() { if [ "$1" = 1 ]; then pass=$((pass+1)); echo "  ok  $2"; else fail=$((fail+1)); echo "  FAIL $2"; fi; }
new_repo() {
  local repo="$1" commit="$2" implement_model="${3:-test-model}"
  mkdir -p "$repo/harness" "$repo/state"; cp "$SRC/harness/loop.sh" "$repo/harness/loop.sh"
  cat > "$repo/harness/harness.config.json" <<JSON
{
  "project":{"type":"greenfield","baseline":{"established":false,"ref":null}},
  "models":{"implement":{"model":"$implement_model","fallback":null},"review":{"model":"test-model","fallback":null},"evaluate":{"model":"test-model","fallback":null},"codex":{"auth":"chatgpt","timeoutSeconds":30}},
  "autonomy":{"mode":"auto","maxIterations":3,"maxTurnsPerIteration":2,"tokenBudget":null,"meterTokens":false,"skipPermissions":false,"checkpoints":{"planApproval":false,"beforeRiskyOps":false,"everyNIterations":0}},
  "loop":{"promptFile":"PROMPT.md","planFile":"state/fix_plan.md","progressFile":"state/PROGRESS.md","oneItemPerIteration":true,"autoRollbackOnRed":true,"commitOnGreen":$commit,"tagOnGreen":true,"stopWhenPlanEmpty":true},
  "verification":{"requireE2EEvidence":true,"reviewEveryNIterations":0,"evaluator":{"enabled":false}},
  "components":[{"name":"root","path":".","gate":{"format":null,"lint":null,"typecheck":null,"build":null,"test":"true","e2e":null}}],
  "gate":{"format":null,"lint":null,"typecheck":null,"build":null,"test":null,"e2e":null}
}
JSON
  printf '## Tasks\n- [ ] first\n- [ ] second\n' > "$repo/state/fix_plan.md"
  printf '%s\n' '- init' > "$repo/state/PROGRESS.md"; printf 'make one safe change\n' > "$repo/PROMPT.md"
  printf original > "$repo/tracked.txt"; printf 'harness/.runs/\n' > "$repo/.gitignore"
  (cd "$repo" && git init -q -b main && git config core.autocrlf false && git config user.email harness-test@example.com && git config user.name 'Harness Test' && git add -A && git commit -q -m init)
}

STUB="$WORK/claude-stub"
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
if [ -f "$HARNESS_TEST_COUNTER" ]; then n=$(( $(cat "$HARNESS_TEST_COUNTER") + 1 )); else n=1; fi
printf '%s' "$n" > "$HARNESS_TEST_COUNTER"
if [ "$n" -eq 1 ]; then printf green-one > tracked.txt; else printf ' ' >> harness/harness.config.json; fi
echo "stub invocation $n"
STUB
chmod +x "$STUB"
REPO="$WORK/no-commit"; COUNTER="$WORK/count.txt"; new_repo "$REPO" false
(cd "$REPO" && HARNESS_CLAUDE_CMD="$STUB" HARNESS_ENGINE="$ENGINE" HARNESS_SANDBOX=1 HARNESS_TEST_COUNTER="$COUNTER" bash harness/loop.sh --mode auto > "$WORK/no-commit.out" 2>&1)
ledger="$REPO/harness/.runs/run-001/ledger.jsonl"
ok "$([ "$(cat "$COUNTER")" = 1 ] && echo 1 || echo 0)" 'no-commit loop invokes the model exactly once'
ok "$([ "$(cat "$REPO/tracked.txt")" = green-one ] && echo 1 || echo 0)" 'first green uncommitted change survives'
ok "$([ "$(grep -cF '"result":"green"' "$ledger")" -eq 1 ] && grep -qF '"committed":false' "$ledger" && echo 1 || echo 0)" 'ledger records one green uncommitted iteration'
ok "$([ -z "$(git -C "$REPO" tag --list)" ] && echo 1 || echo 0)" 'no green tag points at the pre-iteration HEAD'
ok "$(grep -qF 'leave the green changes uncommitted for a human to review' "$WORK/no-commit.out" && echo 1 || echo 0)" 'no-commit warning tells the truth'
ok "$(grep -qF 'preserving the green uncommitted changes' "$WORK/no-commit.out" && echo 1 || echo 0)" 'loop explains the safe stop boundary'

COMMIT_REPO="$WORK/commit"; new_repo "$COMMIT_REPO" true
(cd "$COMMIT_REPO" && HARNESS_SANDBOX=1 bash "$ENGINE/loop.sh" --project-root "$COMMIT_REPO" --dry-run > "$WORK/commit.out" 2>&1)
ok "$(grep -qF 'commit after the configured non-e2e gate passes' "$WORK/commit.out" && echo 1 || echo 0)" 'commit-enabled warning tells the truth'

FAKE_PROFILE="$WORK/profile"; CONSUMER="$WORK/consumer"; mkdir -p "$CONSUMER/harness"
CODEX_REPO="$WORK/codex-dry-run"; new_repo "$CODEX_REPO" true codex
(cd "$CODEX_REPO" && HARNESS_SANDBOX=1 bash "$ENGINE/loop.sh" --project-root "$CODEX_REPO" --dry-run > "$WORK/codex.out" 2>&1)
ok "$(grep -qF 'codex --sandbox workspace-write --ask-for-approval never exec -' "$WORK/codex.out" && echo 1 || echo 0)" 'Codex dry-run previews the workspace-write Codex CLI path'
ok "$(! grep -qF 'claude -p' "$WORK/codex.out" && echo 1 || echo 0)" 'Codex dry-run does not claim Claude will invoke model codex'

cp "$ENGINE/wrappers/loop.sh" "$CONSUMER/harness/loop.sh"
for entry in '0.5.1 .claude' '0.5.3 .codex'; do
  set -- $entry; v="$1"; cache_root="$2"
  dir="$FAKE_PROFILE/$cache_root/plugins/cache/lean-agent-harness/lean-agent-harness/$v/engine"; mkdir -p "$dir"
  printf '#!/usr/bin/env bash\necho WRAPPER_VERSION=%s\n' "$v" > "$dir/loop.sh"; chmod +x "$dir/loop.sh"
done
touch -t 203001010000 "$FAKE_PROFILE/.claude/plugins/cache/lean-agent-harness/lean-agent-harness/0.5.1/engine/loop.sh"
HOME="$FAKE_PROFILE" bash "$CONSUMER/harness/loop.sh" > "$WORK/wrapper.out" 2>&1
ok "$(grep -qF 'WRAPPER_VERSION=0.5.3' "$WORK/wrapper.out" && echo 1 || echo 0)" 'wrapper selects newer Codex-cache version despite Claude-cache timestamp'
dir="$FAKE_PROFILE/.claude/plugins/cache/lean-agent-harness/lean-agent-harness/0.5.4/engine"; mkdir -p "$dir"
printf '#!/usr/bin/env bash\necho WRAPPER_VERSION=0.5.4\n' > "$dir/loop.sh"; chmod +x "$dir/loop.sh"
touch -t 203101010000 "$FAKE_PROFILE/.codex/plugins/cache/lean-agent-harness/lean-agent-harness/0.5.3/engine/loop.sh"
HOME="$FAKE_PROFILE" bash "$CONSUMER/harness/loop.sh" > "$WORK/wrapper-claude.out" 2>&1
ok "$(grep -qF 'WRAPPER_VERSION=0.5.4' "$WORK/wrapper-claude.out" && echo 1 || echo 0)" 'wrapper selects newer Claude-cache version despite Codex-cache timestamp'

echo "AUTO LOOP + WRAPPER RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
