#!/usr/bin/env bash
# The configurable autonomy loop (Ralph-style, with guardrails) — POSIX/bash mirror of loop.ps1.
# Stateless loop, stateful files: each iteration pipes PROMPT.md into a fresh headless `claude`,
# then runs the verification gate. Green => commit (+tag). Red (or gate error / config tampering) =>
# roll back. Bounded by maxIterations, a per-iteration --max-turns, and a best-effort tokenBudget.
# Supervised pauses at checkpoints; auto runs unattended.
#
# Usage: bash harness/loop.sh [--mode supervised|auto] [--max N] [--dry-run]
# Requires: bash, git, jq, and the `claude` CLI.  Do NOT edit the tree while it runs (rollback is hard).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
CONFIG="$SCRIPT_DIR/harness.config.json"
[ -f "$CONFIG" ] || { echo "Missing $CONFIG. Run /harness-init first."; exit 1; }
command -v jq >/dev/null || { echo "jq is required for the bash loop (brew/apt install jq)."; exit 1; }

# shellcheck source=lib/gate.sh
source "$SCRIPT_DIR/lib/gate.sh"
source "$SCRIPT_DIR/lib/checkpoint.sh"
source "$SCRIPT_DIR/lib/budget.sh"

cfg() { jq -r "$1" "$CONFIG"; }

MODE="$(cfg '.autonomy.mode')"
MAX_ITER="$(cfg '.autonomy.maxIterations')"
TOKEN_BUDGET="$(cfg '.autonomy.tokenBudget')"
SKIP_PERMS="$(cfg '.autonomy.skipPermissions')"
EVERY_N="$(cfg '.autonomy.checkpoints.everyNIterations')"; [ "$EVERY_N" = "null" ] && EVERY_N=0
MAX_TURNS="$(cfg '.autonomy.maxTurnsPerIteration')"; { [ "$MAX_TURNS" = "null" ] || [ -z "$MAX_TURNS" ]; } && MAX_TURNS=40
REVIEW_EVERY_N="$(cfg '.verification.reviewEveryNIterations')"; { [ "$REVIEW_EVERY_N" = "null" ] || [ -z "$REVIEW_EVERY_N" ]; } && REVIEW_EVERY_N=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2;;
    --max)  MAX_ITER="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    *) echo "unknown arg: $1"; exit 1;;
  esac
done

confirm_checkpoint() {  # $1 = label ; returns 0 to continue
  [ "$MODE" = "auto" ] && return 0
  printf '\n⏸  Checkpoint: %s\n   Continue? [y/N] ' "$1"
  read -r ans </dev/tty || ans=""
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

open_item_count() {
  local plan n; plan="$(cfg '.loop.planFile')"
  [ -f "$plan" ] || { echo 0; return; }
  # grep -c already prints 0 on no-match; `|| true` keeps set -e happy without a 2nd "0" line.
  n="$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[ \]' "$plan" || true)"
  echo "${n:-0}"
}

any_e2e() {  # 0 if any component or root gate defines an e2e step
  [ "$(jq -r '[(.components[]?.gate.e2e), .gate.e2e] | map(select(. != null and . != "")) | length' "$CONFIG")" != "0" ]
}

# Periodic inferential judge: every N green iterations spawn a fresh-context reviewer over the last N
# commits (ROADMAP "reviewEveryNIterations" — doer != judge wired into the unattended loop). Returns 0
# to continue, 1 if the reviewer REJECTED the batch (loop should stop for a human).
periodic_review() {  # $1 N  $2 run_dir  $3 iter
  local n="$1" run_dir="$2" iter="$3" base out reviewlog stamp prompt
  echo "🧑‍⚖️  Periodic fresh-context review of the last $n green iteration(s)..."
  base="$(git rev-parse "HEAD~$n" 2>/dev/null || true)"
  [ -z "$base" ] && base="$(git rev-list --max-parents=0 HEAD | head -1)"
  reviewlog="$run_dir/review-after-$iter.log"
  read -r -d '' prompt <<EOF || true
You are a FRESH-CONTEXT REVIEWER (the harness 'reviewer' role — see .claude/agents/reviewer.md). You
have NO memory of how this code was written; judge only the artifact. Do NOT edit any files.

1. Inspect the batch:  git log --oneline $base..HEAD   and   git diff $base..HEAD
2. Judge it against specs/ (acceptance criteria) and docs/principles/ (golden principles): correctness
   vs spec, REAL end-to-end evidence (not just unit tests), guardrails (no weakened/deleted tests, no
   edited specs, no destructive ops/secrets), architectural drift, needless complexity.
3. List findings as  file:line — problem — concrete fix.

Finish with EXACTLY ONE final line and nothing after it:
VERDICT: SHIP     (the batch is sound)
VERDICT: REJECT   (anything is wrong — default to REJECT when unsure)
EOF
  if ! out="$(claude -p "$prompt" --max-turns 20 2>&1 | tee "$reviewlog")"; then
    echo "  ! review invocation failed — continuing without a verdict."; return 0
  fi
  if printf '%s' "$out" | grep -qE 'VERDICT:[[:space:]]*REJECT'; then
    echo "  🔴 Periodic review REJECTED the batch. Stopping for human attention."
    stamp="$(git rev-parse --short HEAD)"
    printf '\n## Needs human decision — periodic review REJECT @ %s\nThe fresh-context reviewer rejected the last %s green iteration(s) (iter %s). Findings: %s. Inspect before continuing.\n' \
      "$stamp" "$n" "$iter" "$reviewlog" >> "$REPO_ROOT/state/handoff.md"
    return 1
  fi
  echo "  🟢 Periodic review: SHIP."
  return 0
}

RUN_ID="$(loop_run_id)"
RUN_DIR="$SCRIPT_DIR/.runs/$RUN_ID"
mkdir -p "$RUN_DIR"
LEDGER="$RUN_DIR/ledger.jsonl"
reset_budget   # per-run cap, not a lifetime counter
ledger() { printf '%s\n' "$1" >> "$LEDGER"; }
config_hash() { git hash-object "$CONFIG"; }
CONFIG_HASH0="$(config_hash)"

assert_clean_git_tree
PROJ_TYPE="$(cfg '.project.type')"; [ "$PROJ_TYPE" = "null" ] && PROJ_TYPE="greenfield"
echo "🔧 Harness loop | type=$PROJ_TYPE | mode=$MODE | maxIter=$MAX_ITER | maxTurns=$MAX_TURNS | budget=$TOKEN_BUDGET"

if [ "$MODE" = "auto" ] && [ "$(cfg '.verification.requireE2EEvidence')" = "true" ] && ! any_e2e; then
  echo "⚠️  auto mode + requireE2EEvidence, but no e2e gate step is configured. The loop will commit on"
  echo "    unit-green only. Add an e2e command to a component/root gate, or run /review periodically."
fi

if [ "$PROJ_TYPE" = "brownfield" ]; then
  if [ "$(cfg '.project.baseline.established')" != "true" ]; then
    echo "⚠️  Brownfield project with NO established green baseline. Run /onboard first."
    confirm_checkpoint "Continue without an established baseline?" || exit 0
  fi
  if [ "$MODE" = "auto" ]; then
    echo "⚠️  AUTO mode on a BROWNFIELD codebase. The auto-loop is designed for greenfield; on existing"
    echo "    code it risks wide, subtle regressions. Supervised + small isolated tasks is recommended."
    confirm_checkpoint "Run full-auto on an existing codebase anyway?" || exit 0
  fi
fi
if [ "$MODE" = "auto" ] && [ "$SKIP_PERMS" = "true" ]; then
  echo "⚠️  AUTO + skipPermissions: model runs UNATTENDED with permission prompts disabled."
  echo "    The deny-list (incl. secrets) is VOID in this mode — run inside a sandbox/container."
  confirm_checkpoint "Proceed with unattended skip-permissions run?" || exit 0
fi

# Lock specs/ for the run: the protect-specs PreToolUse hook (inherited by the headless claude child)
# blocks edits under specs/ while this is exported. The loop must never rewrite the contract.
export HARNESS_LOCK_SPECS=1

PROMPT="$(cat "$(cfg '.loop.promptFile')")"
i=0
GREEN_COUNT=0
while [ "$i" -lt "$MAX_ITER" ]; do
  i=$((i+1))
  if [ "$(cfg '.loop.stopWhenPlanEmpty')" = "true" ] && [ "$(open_item_count)" -eq 0 ]; then
    echo "✅ fix_plan.md has no open items — stopping."; break
  fi
  if [ "$TOKEN_BUDGET" != "null" ] && budget_exceeded "$TOKEN_BUDGET"; then
    echo "💸 Token budget (estimate) exhausted — stopping."; break
  fi
  if [ "$EVERY_N" -gt 0 ] && [ $((i % EVERY_N)) -eq 0 ]; then
    confirm_checkpoint "Reached iteration $i" || break
  fi

  echo "──────── iteration $i / $MAX_ITER ────────"
  ITER_LOG="$RUN_DIR/iter-$i.log"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would invoke: claude -p (PROMPT.md) --max-turns $MAX_TURNS ; then run the gate."; break
  fi

  new_checkpoint "pre-iter-$i"
  CLAUDE_ARGS=(-p "$PROMPT" --max-turns "$MAX_TURNS")
  if [ "$MODE" = "auto" ] && [ "$SKIP_PERMS" = "true" ]; then CLAUDE_ARGS+=(--dangerously-skip-permissions); fi
  if [ "$(cfg '.autonomy.meterTokens')" = "true" ]; then CLAUDE_ARGS+=(--output-format json); fi   # exact usage
  if ! claude "${CLAUDE_ARGS[@]}" 2>&1 | tee "$ITER_LOG"; then
    echo "❌ claude invocation failed"; ledger "{\"iter\":$i,\"result\":\"invoke-error\"}"; restore_checkpoint; continue
  fi
  update_budget_from_log "$ITER_LOG"

  if [ "$(config_hash)" != "$CONFIG_HASH0" ]; then
    echo "🛑 harness.config.json changed during the iteration (gate/policy tampering?). Rolling back and stopping."
    ledger "{\"iter\":$i,\"result\":\"config-tampered\"}"; restore_checkpoint; break
  fi

  echo "🔬 Running verification gate..."
  if run_gate "$CONFIG"; then
    echo "🟢 Gate green."
    [ "$(cfg '.loop.commitOnGreen')" = "true" ] && commit_iteration "$i"
    [ "$(cfg '.loop.tagOnGreen')" = "true" ]    && tag_iteration "$i" "$RUN_ID"
    clear_checkpoint
    ledger "{\"iter\":$i,\"result\":\"green\"}"
    GREEN_COUNT=$((GREEN_COUNT+1))
    # Inferential judge, wired in: every N green iterations a fresh-context reviewer audits the batch.
    if [ "$REVIEW_EVERY_N" -gt 0 ] && [ "$(cfg '.loop.commitOnGreen')" = "true" ] && [ $((GREEN_COUNT % REVIEW_EVERY_N)) -eq 0 ]; then
      if ! periodic_review "$REVIEW_EVERY_N" "$RUN_DIR" "$i"; then
        ledger "{\"iter\":$i,\"result\":\"review-reject\"}"; break
      fi
    fi
  else
    echo "🔴 Gate red: $GATE_FAILED_STEP"
    ledger "{\"iter\":$i,\"result\":\"red\",\"failedStep\":\"$GATE_FAILED_STEP\"}"
    if [ "$(cfg '.loop.autoRollbackOnRed')" = "true" ]; then
      echo "↩  Rolling back to keep the tree green."; restore_checkpoint
    else
      echo "   autoRollbackOnRed=false — leaving tree for inspection. Stopping."; break
    fi
  fi
done

echo "🏁 Loop finished after $i iteration(s). Logs + ledger: $RUN_DIR"
echo "   Next: run /review for a fresh-context QA pass before you trust this."
