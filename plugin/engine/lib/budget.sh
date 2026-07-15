#!/usr/bin/env bash
# budget.sh — best-effort token accounting so an unattended loop can't run away (mirror of budget.ps1).
# ESTIMATE, not exact metering: `claude -p` text mode rarely emits token counts, so we fall back to a
# per-iteration estimate. The hard runaway bound is maxIterations + per-iteration --max-turns. The tally
# is reset at the START of each run (reset_budget) so tokenBudget is a per-run cap, not a lifetime one.
# Default is the legacy shared path; the loop re-points this into its own run dir (set_budget_file)
# so two concurrent runs (e.g. parallel worktrees sharing this harness dir) can't clobber tallies.
_BUDGET_FILE="$SCRIPT_DIR/.budget.json"

set_budget_file() { _BUDGET_FILE="$1"; }

loop_run_id() {
  # Incrementing id from the MAX existing run-NNN suffix, not a dir count: after deleting an old run
  # dir a count-based id collides with a surviving run (appending to its logs and force-retagging its
  # loop-run-NNN-* tags). Allocation CLAIMS the run dir atomically (mkdir-as-mutex): two runs starting
  # together race to create the same candidate; the loser gets the next number instead of sharing
  # logs/ledger/tags with the winner.
  local runs="${1:-$SCRIPT_DIR/.runs}" max=0 d n i cand   # $1 = runs dir (loop.sh passes the project's harness/.runs); default keeps the self-test's SCRIPT_DIR-based call working
  mkdir -p "$runs"
  for d in "$runs"/run-*; do
    [ -d "$d" ] || continue
    n="${d##*/run-}"
    case "$n" in ''|*[!0-9]*) continue;; esac
    n=$((10#$n))
    [ "$n" -gt "$max" ] && max="$n"
  done
  for (( i = max + 1; i <= max + 1000; i++ )); do
    cand="$(printf 'run-%03d' "$i")"
    if mkdir "$runs/$cand" 2>/dev/null; then printf '%s' "$cand"; return 0; fi
  done
  echo "Could not allocate a run id under $runs" >&2; return 1
}

_budget_spent() {
  [ -f "$_BUDGET_FILE" ] && jq -r '.tokensSpent // 0' "$_BUDGET_FILE" || echo 0
}

reset_budget() { echo '{"tokensSpent": 0}' > "$_BUDGET_FILE"; }

update_budget_from_log() {  # $1 logfile
  local spent="" total
  if [ -f "$1" ]; then
    # Prefer real usage if present (json input/output_tokens); else any "<n> tokens".
    # Take the MAX of each field (not the sum): --output-format json can repeat the same counts in a
    # per-model `modelUsage` breakdown alongside the aggregate `usage`, so summing double-counts.
    # Cache tokens too: cache reads/writes dominate real usage in long agentic sessions — ignoring
    # them under-meters by an order of magnitude and defeats tokenBudget as a runaway bound.
    local max_in max_out max_cc max_cr
    max_in="$(grep -oE '"input_tokens"[[:space:]]*:[[:space:]]*[0-9]+'  "$1" | grep -oE '[0-9]+' | sort -n | tail -1)"
    max_out="$(grep -oE '"output_tokens"[[:space:]]*:[[:space:]]*[0-9]+' "$1" | grep -oE '[0-9]+' | sort -n | tail -1)"
    max_cc="$(grep -oE '"cache_creation_input_tokens"[[:space:]]*:[[:space:]]*[0-9]+' "$1" | grep -oE '[0-9]+' | sort -n | tail -1)"
    max_cr="$(grep -oE '"cache_read_input_tokens"[[:space:]]*:[[:space:]]*[0-9]+'     "$1" | grep -oE '[0-9]+' | sort -n | tail -1)"
    spent="$(( ${max_in:-0} + ${max_out:-0} + ${max_cc:-0} + ${max_cr:-0} ))"
    if [ -z "$spent" ] || [ "$spent" -le 0 ] 2>/dev/null; then
      spent="$(grep -oE '[0-9][0-9,]*[[:space:]]*tokens' "$1" | grep -oE '[0-9,]+' | tr -d ',' | sort -n | tail -1 || true)"
    fi
  fi
  if [ -z "$spent" ] || ! [ "$spent" -gt 0 ] 2>/dev/null; then spent=15000; fi   # conservative estimate
  total=$(( $(_budget_spent) + spent ))
  echo "{\"tokensSpent\": $total}" > "$_BUDGET_FILE"
  printf '  📊 est. tokens this run: ~%s\n' "$total"
}

budget_exceeded() {  # $1 cap
  [ "$1" = "null" ] && return 1
  [ "$1" -le 0 ] 2>/dev/null && return 1   # 0 / negative = no cap (parity with budget.ps1's falsy check)
  [ "$(_budget_spent)" -ge "$1" ]
}
