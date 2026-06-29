#!/usr/bin/env bash
# gate.sh — the verification gate (bash mirror of gate.ps1).
# Harness defines WHEN; the stack profile (merged into config.gate) defines WHAT. null => skip.
# Silent success, verbose failure: only surface output when a step fails.
GATE_FAILED_STEP=""

_gate_step() {  # $1 name  $2 cmd
  local name="$1" cmd="$2"
  [ "$cmd" = "null" ] || [ -z "$cmd" ] && return 0
  echo "  • $name : $cmd"
  local out; out="$(bash -lc "$cmd" 2>&1)" && return 0
  echo "    ✗ $name failed:"
  echo "$out" | tail -n 40 | sed 's/^/      /'
  return 1
}

run_gate() {  # $1 = config path ; sets GATE_FAILED_STEP on failure
  local config="$1" name cmd
  # cheapest first: format -> lint -> typecheck -> build -> test -> e2e
  for name in format lint typecheck build test e2e; do
    cmd="$(jq -r ".gate.$name" "$config")"
    if ! _gate_step "$name" "$cmd"; then GATE_FAILED_STEP="$name"; return 1; fi
  done
  return 0
}
