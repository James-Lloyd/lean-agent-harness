#!/usr/bin/env bash
# budget.sh — best-effort token accounting so an unattended loop can't run away (mirror of budget.ps1).
_BUDGET_FILE="$SCRIPT_DIR/.budget.json"

loop_run_id() {
  local runs="$SCRIPT_DIR/.runs"
  [ -d "$runs" ] || { echo "run-001"; return; }
  printf 'run-%03d' "$(( $(find "$runs" -maxdepth 1 -type d | wc -l) ))"
}

_budget_spent() {
  [ -f "$_BUDGET_FILE" ] && jq -r '.tokensSpent // 0' "$_BUDGET_FILE" || echo 0
}

update_budget_from_log() {  # $1 logfile
  local spent=0
  if [ -f "$1" ]; then
    spent="$(grep -oE '[0-9][0-9,]*[[:space:]]*tokens' "$1" | grep -oE '[0-9,]+' | tr -d ',' | sort -n | tail -1 || true)"
  fi
  [ -z "$spent" ] || [ "$spent" -le 0 ] 2>/dev/null && spent=15000   # conservative fallback
  local total=$(( $(_budget_spent) + spent ))
  echo "{\"tokensSpent\": $total}" > "$_BUDGET_FILE"
  printf '  📊 tokens this run: ~%s\n' "$total"
}

budget_exceeded() {  # $1 cap
  [ "$1" = "null" ] && return 1
  [ "$(_budget_spent)" -ge "$1" ]
}
