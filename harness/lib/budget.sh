#!/usr/bin/env bash
# budget.sh — best-effort token accounting so an unattended loop can't run away (mirror of budget.ps1).
# ESTIMATE, not exact metering: `claude -p` text mode rarely emits token counts, so we fall back to a
# per-iteration estimate. The hard runaway bound is maxIterations + per-iteration --max-turns. The tally
# is reset at the START of each run (reset_budget) so tokenBudget is a per-run cap, not a lifetime one.
_BUDGET_FILE="$SCRIPT_DIR/.budget.json"

loop_run_id() {
  local runs="$SCRIPT_DIR/.runs"
  [ -d "$runs" ] || { echo "run-001"; return; }
  printf 'run-%03d' "$(( $(find "$runs" -maxdepth 1 -type d | wc -l) ))"
}

_budget_spent() {
  [ -f "$_BUDGET_FILE" ] && jq -r '.tokensSpent // 0' "$_BUDGET_FILE" || echo 0
}

reset_budget() { echo '{"tokensSpent": 0}' > "$_BUDGET_FILE"; }

update_budget_from_log() {  # $1 logfile
  local spent="" total
  if [ -f "$1" ]; then
    # Prefer real usage if present (json input/output_tokens, summed); else any "<n> tokens".
    spent="$(grep -oE '"(input_tokens|output_tokens)"[[:space:]]*:[[:space:]]*[0-9]+' "$1" | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null || true)"
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
  [ "$(_budget_spent)" -ge "$1" ]
}
