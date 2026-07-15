#!/usr/bin/env bash
# fleet-queue-test.sh — integration test for the fleet runner's MERGE QUEUE (bash side).
# Live-fires harness/fleet.sh in a throwaway repo with a stub claude (HARNESS_CLAUDE_CMD),
# asserting the queue's core outcomes: parallel spawn, worker exit capture, worker commit,
# squash-merge, gate on the combined state, runner-owned recording (tasks.json/PROGRESS),
# cleanup of merged branches — and the tamper-park path (a worker editing harness/ must never land).
# Requires jq + git; skips cleanly without jq (same policy as run-tests.sh's jq-gated cases).
#   Run:  bash harness/tests/fleet-queue-test.sh
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "(skipping fleet queue test — jq not installed)"; exit 0; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_SRC="$(cd "$HERE/../.." && pwd)"
# harness/fleet.sh is now a thin WRAPPER that dispatches to the plugin engine; pin it to this repo's own
# plugin/engine so the copied wrapper resolves the engine without relying on $CLAUDE_PLUGIN_ROOT.
export HARNESS_ENGINE="$HARNESS_SRC/plugin/engine"
WORK="$(mktemp -d)"
cleanup() { cd /; rm -rf "$WORK"; }
trap cleanup EXIT
T="$WORK/repo"
mkdir -p "$T"; cd "$T"

git init -q -b main
git config core.autocrlf false
git config user.email fleet-test@example.com
git config user.name "Fleet Test"

cp -r "$HARNESS_SRC/harness" .
rm -rf harness/.runs harness/.worktrees
mkdir -p state
cat > harness/harness.config.json <<'JSON'
{
  "project": { "type": "greenfield", "baseline": { "established": false, "ref": null } },
  "models": { "implement": { "model": "primary-x", "fallback": "fallback-x" } },
  "autonomy": { "mode": "supervised", "maxIterations": 5, "maxTurnsPerIteration": 10, "tokenBudget": null, "meterTokens": false, "skipPermissions": false },
  "parallel": { "maxWorkers": 5, "workerMaxTurns": 10, "workerTimeoutSeconds": 120 },
  "components": [ { "name": "root", "path": ".", "gate": { "format": null, "lint": null, "typecheck": null, "build": null, "test": "exit 0", "e2e": null } } ],
  "gate": { "format": null, "lint": null, "typecheck": null, "build": null, "test": null, "e2e": null }
}
JSON
cat > state/tasks.json <<'JSON'
{ "version": 2, "tasks": [
  { "id": "T-A", "category": "functional", "component": "root", "description": "build module A", "steps": ["write a/out.txt"], "acceptance": "a/out.txt exists", "files": ["a/"], "status": "todo", "evidence": "", "passes": false },
  { "id": "T-B", "category": "functional", "component": "root", "description": "build module B", "steps": ["write b/out.txt"], "acceptance": "b/out.txt exists", "files": ["b/"], "status": "todo", "evidence": "", "passes": false },
  { "id": "T-CRASH", "category": "functional", "component": "root", "description": "worker that crashes", "steps": ["exit non-zero"], "acceptance": "n/a", "files": ["c/"], "status": "todo", "evidence": "", "passes": false },
  { "id": "T-EVIL", "category": "functional", "component": "root", "description": "tamper attempt", "steps": ["edit harness engine"], "acceptance": "n/a", "files": ["evil/"], "status": "todo", "evidence": "", "passes": false },
  { "id": "T-FB", "category": "functional", "component": "root", "description": "build via fallback", "steps": ["write fb/out.txt"], "acceptance": "fb/out.txt exists", "files": ["fb/"], "status": "todo", "evidence": "", "passes": false }
] }
JSON
echo "- init" > state/PROGRESS.md
printf 'harness/.runs/\nharness/.worktrees/\nFLEET_NOTES.md\nstate/handoff.md\n' > .gitignore
git add -A && git commit -q -m "init"

# Stub claude lives OUTSIDE the repo (an untracked file inside would fail the clean-tree preflight).
# It reads the prompt from stdin and the --model arg the dispatcher passes; it writes into its ownership
# dir; the T-EVIL worker tampers with a protected path (harness/) — the queue must park it; and T-FB's
# PRIMARY model hits a usage limit, so the worker must reset + retry on the FALLBACK model.
cat > "$WORK/stub-claude" <<'STUB'
#!/usr/bin/env bash
prompt="$(cat)"
model=""; prev=""
for a in "$@"; do [ "$prev" = "--model" ] && model="$a"; prev="$a"; done
dir="$(printf '%s' "$prompt" | sed -n 's/^  - \([a-z]*\/\)$/\1/p' | head -1)"
if [ "$dir" = "c/" ]; then
  exit 1   # the crash path: the runner must record THIS code, not mis-park as a timeout (ratchet)
elif [ "$dir" = "fb/" ]; then
  # PRIMARY emits a usage-limit marker + nonzero exit; the dispatcher must reset + retry on the FALLBACK
  # model, which builds normally. "built by fallback" content only exists if the fallback ran.
  if [ "$model" = "primary-x" ]; then echo "Error: Claude usage limit reached"; exit 1; fi
  mkdir -p fb && echo "built by fallback" > fb/out.txt
elif [ "$dir" = "evil/" ]; then
  echo "tampered" >> harness/loop.sh
  mkdir -p evil && echo x > evil/out.txt
else
  mkdir -p "$dir" && echo "built by worker" > "${dir}out.txt"
fi
exit 0
STUB
chmod +x "$WORK/stub-claude"

echo "fleet queue: live-fire with stub claude (merge, record, tamper-park)"
HARNESS_CLAUDE_CMD="$WORK/stub-claude" bash harness/fleet.sh --max 5 >/dev/null 2>&1 || true

pass=0; fail=0
ok() { if [ "$1" = "1" ]; then pass=$((pass+1)); echo "  ok  $2"; else fail=$((fail+1)); echo "  FAIL $2"; fi; }
ok "$([ -f a/out.txt ] && echo 1 || echo 0)"  "T-A output merged to main tree"
ok "$([ -f b/out.txt ] && echo 1 || echo 0)"  "T-B output merged to main tree"
ok "$([ ! -f evil/out.txt ] && echo 1 || echo 0)" "T-EVIL work did NOT land"
ok "$(git log --oneline | grep -q 'fleet(T-A)' && echo 1 || echo 0)" "T-A merge commit exists"
ok "$(git log --oneline | grep -q 'fleet(T-B)' && echo 1 || echo 0)" "T-B merge commit exists"
ok "$(git log --oneline | grep -q 'fleet(T-EVIL)' && echo 0 || echo 1)" "no T-EVIL commit"
ok "$([ "$(jq -r '.tasks[] | select(.id=="T-A") | .status' state/tasks.json)" = "validated" ] && echo 1 || echo 0)" "T-A recorded validated"
ok "$([ "$(jq -r '.tasks[] | select(.id=="T-B") | .passes' state/tasks.json)" = "true" ] && echo 1 || echo 0)" "T-B passes=true"
ok "$([ "$(jq -r '.tasks[] | select(.id=="T-EVIL") | .status' state/tasks.json)" = "todo" ] && echo 1 || echo 0)" "T-EVIL still todo"
ok "$(grep -q '"task":"T-EVIL","result":"parked"' harness/.runs/run-001/fleet-ledger.jsonl 2>/dev/null && echo 1 || echo 0)" "T-EVIL parked in ledger"
ok "$(grep '"task":"T-CRASH"' harness/.runs/run-001/fleet-ledger.jsonl 2>/dev/null | grep -q 'exited 1' && echo 1 || echo 0)" "T-CRASH parked with its real exit code (not mis-parked as timeout)"
ok "$([ ! -d c ] && echo 1 || echo 0)" "T-CRASH work did not land"
ok "$(grep -q 'protected path' state/handoff.md 2>/dev/null && echo 1 || echo 0)" "tamper surfaced in handoff.md"
ok "$(git branch --list 'fleet/*' | grep -q 'T-EVIL' && echo 1 || echo 0)" "T-EVIL branch kept for inspection"
ok "$(git branch --list 'fleet/*' | grep -q 'T-A' && echo 0 || echo 1)" "T-A branch cleaned up"
ok "$([ -z "$(git status --porcelain -uno)" ] && echo 1 || echo 0)" "tracked tree clean after fleet"

# Cross-vendor fallback (S4): T-FB's primary model was usage-limited, so the worker fell back and its
# output landed. "built by fallback" content is only written on the fallback arm — proof the worker
# inherits the loop's primary->fallback dispatch, not just that some model built the file.
ok "$([ "$(cat fb/out.txt 2>/dev/null)" = "built by fallback" ] && echo 1 || echo 0)" "T-FB built by the FALLBACK model"
ok "$(git log --oneline | grep -q 'fleet(T-FB)' && echo 1 || echo 0)" "T-FB merge commit exists"
ok "$([ "$(jq -r '.tasks[] | select(.id=="T-FB") | .status' state/tasks.json)" = "validated" ] && echo 1 || echo 0)" "T-FB recorded validated"

# Dry-run (S4): --dry-run must invoke NO model and leave NO new fleet worktrees/branches. The stub writes
# a sentinel if ever run; the run leaves T-CRASH/T-EVIL todo, so dry-run does select+add+cleanup real
# worktrees — exercising the cleanup path, not a no-op.
sentinel="$WORK/dry-sentinel"
cat > "$WORK/stub-dry" <<STUB
#!/usr/bin/env bash
echo invoked > "$sentinel"
exit 0
STUB
chmod +x "$WORK/stub-dry"
branches_before="$(git branch --list 'fleet/*' | wc -l)"
wt_before="$(git worktree list | wc -l)"
HARNESS_CLAUDE_CMD="$WORK/stub-dry" bash harness/fleet.sh --max 5 --dry-run >/dev/null 2>&1 || true
ok "$([ ! -f "$sentinel" ] && echo 1 || echo 0)" "dry-run invoked no model"
ok "$([ "$branches_before" = "$(git branch --list 'fleet/*' | wc -l)" ] && echo 1 || echo 0)" "dry-run left no new fleet branches"
ok "$([ "$wt_before" = "$(git worktree list | wc -l)" ] && echo 1 || echo 0)" "dry-run left no new worktrees"

# ── Scenario 2: a record-amend failure preserves the pending record in the run dir ─────────────
# Finding (fix_plan): when `git commit --amend` (folding tasks.json/PROGRESS into the merge commit)
# FAILS, leaving the files merely STAGED lets a LATER queue entry's reset --hard + clean -fd silently
# discard them while the ledger already said 'merged'. The fix persists the record to the gitignored
# run dir (reset-proof) and restores the tree. Here a pre-commit hook fails the runner's MAIN-tree
# commits: T-OK's amend (state/ staged) is deferred to the run dir; T-BOOM's merge commit (boom/ staged)
# fails → triggering the very reset --hard + clean -fd that used to eat T-OK's record.
T2="$WORK/repo2"; mkdir -p "$T2"; cd "$T2"
git init -q -b main
git config core.autocrlf false
git config user.email fleet-test@example.com
git config user.name "Fleet Test"
cp -r "$HARNESS_SRC/harness" .
rm -rf harness/.runs harness/.worktrees
mkdir -p state
cat > harness/harness.config.json <<'JSON'
{
  "project": { "type": "greenfield", "baseline": { "established": false, "ref": null } },
  "models": { "implement": { "model": "primary-x", "fallback": "fallback-x" } },
  "autonomy": { "mode": "supervised", "maxIterations": 5, "maxTurnsPerIteration": 10, "tokenBudget": null, "meterTokens": false, "skipPermissions": false },
  "parallel": { "maxWorkers": 5, "workerMaxTurns": 10, "workerTimeoutSeconds": 120 },
  "components": [ { "name": "root", "path": ".", "gate": { "format": null, "lint": null, "typecheck": null, "build": null, "test": "exit 0", "e2e": null } } ],
  "gate": { "format": null, "lint": null, "typecheck": null, "build": null, "test": null, "e2e": null }
}
JSON
cat > state/tasks.json <<'JSON'
{ "version": 2, "tasks": [
  { "id": "T-OK", "category": "functional", "component": "root", "description": "build ok module", "steps": ["write ok/out.txt"], "acceptance": "ok/out.txt exists", "files": ["ok/"], "status": "todo", "evidence": "", "passes": false },
  { "id": "T-BOOM", "category": "functional", "component": "root", "description": "merge commit blocked by a hook", "steps": ["write boom/out.txt"], "acceptance": "boom/out.txt exists", "files": ["boom/"], "status": "todo", "evidence": "", "passes": false }
] }
JSON
echo "- init" > state/PROGRESS.md
printf 'harness/.runs/\nharness/.worktrees/\nFLEET_NOTES.md\nstate/handoff.md\n' > .gitignore
git add -A && git commit -q -m "init"
# Only the runner's MAIN-tree commits are blocked (a worker's own worktree commit has a toplevel under
# .worktrees → always passes): a `state/` staged set is T-OK's record amend; a `boom/` staged set is
# T-BOOM's merge commit. Both fail → the deferral + reset paths fire deterministically.
cat > .git/hooks/pre-commit <<'HOOK'
#!/bin/sh
top="$(git rev-parse --show-toplevel)"
case "$top" in *.worktrees*) exit 0;; esac
git diff --cached --name-only | grep -qE '^(state/|boom/)' && exit 1
exit 0
HOOK
chmod +x .git/hooks/pre-commit
cat > "$WORK/stub-ok" <<'STUB'
#!/usr/bin/env bash
prompt="$(cat)"
dir="$(printf '%s' "$prompt" | sed -n 's/^  - \([a-z]*\/\)$/\1/p' | head -1)"
[ -n "$dir" ] && { mkdir -p "$dir" && echo "built by worker" > "${dir}out.txt"; }
exit 0
STUB
chmod +x "$WORK/stub-ok"

echo "fleet queue: record-amend failure preserves the pending record in the run dir"
HARNESS_CLAUDE_CMD="$WORK/stub-ok" bash harness/fleet.sh --max 5 >/dev/null 2>&1 || true

led2="harness/.runs/run-001/fleet-ledger.jsonl"
pend2="harness/.runs/run-001/pending-record-T-OK"
ok "$([ -f "$pend2/tasks.json" ] && echo 1 || echo 0)" "amend-fail: pending record saved to the run dir"
ok "$([ "$(jq -r '.tasks[] | select(.id=="T-OK") | .status' "$pend2/tasks.json" 2>/dev/null)" = "validated" ] && echo 1 || echo 0)" "pending tasks.json holds the intended (validated) record"
ok "$(grep -q 'merged T-OK' "$pend2/PROGRESS.md" 2>/dev/null && echo 1 || echo 0)" "pending PROGRESS.md holds the intended line"
ok "$(grep -q '"task":"T-OK","result":"merged"' "$led2" 2>/dev/null && echo 1 || echo 0)" "ledger says T-OK merged (the finding's premise)"
ok "$(grep -q '"task":"T-OK","result":"record-deferred"' "$led2" 2>/dev/null && echo 1 || echo 0)" "ledger records the deferral for morning reconciliation"
ok "$(git log --oneline | grep -q 'fleet(T-OK)' && echo 1 || echo 0)" "T-OK merge commit still stands"
ok "$([ "$(jq -r '.tasks[] | select(.id=="T-OK") | .status' state/tasks.json)" = "todo" ] && echo 1 || echo 0)" "working tree NOT left staged (record restored to HEAD)"
ok "$(grep '"task":"T-BOOM"' "$led2" 2>/dev/null | grep -q 'parked' && echo 1 || echo 0)" "T-BOOM parked — its merge-commit reset --hard fired"
ok "$([ -f "$pend2/tasks.json" ] && echo 1 || echo 0)" "pending record SURVIVED T-BOOM's reset --hard + clean -fd"

echo "FLEET QUEUE RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
