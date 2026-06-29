#!/usr/bin/env bash
# The configurable autonomy loop (Ralph-style, with guardrails) — POSIX/bash mirror of loop.ps1.
# Stateless loop, stateful files: each iteration pipes PROMPT.md into a fresh headless `claude`,
# then runs the verification gate. Green => commit (+tag). Red => roll back. Bounded by
# maxIterations and tokenBudget. Supervised pauses at checkpoints; auto runs unattended.
#
# Usage: bash harness/loop.sh [--mode supervised|auto] [--max N] [--dry-run]
# Requires: bash, git, jq, and the `claude` CLI.
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
EVERY_N="$(cfg '.autonomy.checkpoints.everyNIterations')"
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
  local plan; plan="$(cfg '.loop.planFile')"
  [ -f "$plan" ] || { echo 0; return; }
  grep -cE '^[[:space:]]*[-*][[:space:]]+\[ \]' "$plan" || echo 0
}

RUN_DIR="$SCRIPT_DIR/.runs/$(loop_run_id)"
mkdir -p "$RUN_DIR"

assert_clean_git_tree
echo "🔧 Harness loop | mode=$MODE | maxIter=$MAX_ITER | budget=$TOKEN_BUDGET"
if [ "$MODE" = "auto" ] && [ "$SKIP_PERMS" = "true" ]; then
  echo "⚠️  AUTO + skipPermissions: model runs UNATTENDED with permission prompts disabled."
  echo "    Safety rests on the gate, auto-rollback, and the PreToolUse block-hook."
  confirm_checkpoint "Proceed with unattended skip-permissions run?" || exit 0
fi

PROMPT="$(cat "$(cfg '.loop.promptFile')")"
i=0
while [ "$i" -lt "$MAX_ITER" ]; do
  i=$((i+1))
  if [ "$(cfg '.loop.stopWhenPlanEmpty')" = "true" ] && [ "$(open_item_count)" -eq 0 ]; then
    echo "✅ fix_plan.md has no open items — stopping."; break
  fi
  if [ "$TOKEN_BUDGET" != "null" ] && budget_exceeded "$TOKEN_BUDGET"; then
    echo "💸 Token budget exhausted — stopping."; break
  fi
  if [ "$EVERY_N" -gt 0 ] && [ $((i % EVERY_N)) -eq 0 ]; then
    confirm_checkpoint "Reached iteration $i" || break
  fi

  echo "──────── iteration $i / $MAX_ITER ────────"
  ITER_LOG="$RUN_DIR/iter-$i.log"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] would invoke: claude -p (PROMPT.md) ; then run the gate."; break
  fi

  new_checkpoint "pre-iter-$i"
  CLAUDE_ARGS=(-p "$PROMPT")
  if [ "$MODE" = "auto" ] && [ "$SKIP_PERMS" = "true" ]; then CLAUDE_ARGS+=(--dangerously-skip-permissions); fi
  if ! claude "${CLAUDE_ARGS[@]}" 2>&1 | tee "$ITER_LOG"; then
    echo "❌ claude invocation failed"; restore_checkpoint; continue
  fi
  update_budget_from_log "$ITER_LOG"

  echo "🔬 Running verification gate..."
  if run_gate "$CONFIG"; then
    echo "🟢 Gate green."
    [ "$(cfg '.loop.commitOnGreen')" = "true" ] && commit_iteration "$i"
    [ "$(cfg '.loop.tagOnGreen')" = "true" ]    && tag_iteration "$i"
    clear_checkpoint
  else
    echo "🔴 Gate red: $GATE_FAILED_STEP"
    if [ "$(cfg '.loop.autoRollbackOnRed')" = "true" ]; then
      echo "↩  Rolling back to keep the tree green."; restore_checkpoint
    else
      echo "   autoRollbackOnRed=false — leaving tree for inspection. Stopping."; break
    fi
  fi
done

echo "🏁 Loop finished after $i iteration(s). Logs: $RUN_DIR"
echo "   Next: run /review for a fresh-context QA pass before you trust this."
