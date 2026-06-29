#!/usr/bin/env bash
# gate.sh — the verification gate (bash mirror of gate.ps1).
# Harness defines WHEN; each component's gate (+ a cross-cutting root gate) defines WHAT. null => skip.
# Multi-component aware: each component runs in its own dir; root gate runs from repo root last.
# Silent success, verbose failure. Sets GATE_FAILED_STEP="<component>:<step>" on failure.
GATE_FAILED_STEP=""

_gate_step() {  # $1 name  $2 cmd  $3 workdir
  local name="$1" cmd="$2" workdir="$3"
  { [ "$cmd" = "null" ] || [ -z "$cmd" ]; } && return 0
  echo "  - $name : $cmd"
  local out; out="$(cd "$workdir" && bash -lc "$cmd" 2>&1)" && return 0
  echo "    x $name failed in $workdir:"
  echo "$out" | tail -n 40 | sed 's/^/      /'
  return 1
}

# Run one gate object given a jq path prefix (e.g. '.components[0].gate' or '.gate') in $2 workdir, label $3.
_gate_set() {  # $1 config  $2 jqpath  $3 workdir  $4 label
  local config="$1" jqpath="$2" workdir="$3" label="$4" name cmd
  for name in format lint typecheck build test e2e; do
    cmd="$(jq -r "${jqpath}.${name} // empty" "$config")"
    if ! _gate_step "$name" "$cmd" "$workdir"; then GATE_FAILED_STEP="${label}:${name}"; return 1; fi
  done
  return 0
}

run_gate() {  # $1 = config path ; $REPO_ROOT must be set ; sets GATE_FAILED_STEP on failure
  local config="$1" n i name path label
  n="$(jq -r '.components | length' "$config" 2>/dev/null || echo 0)"
  if [ "$n" = "0" ] || [ "$n" = "null" ]; then
    _gate_set "$config" ".gate" "$REPO_ROOT" "root" || return 1
    return 0
  fi
  i=0
  while [ "$i" -lt "$n" ]; do
    name="$(jq -r ".components[$i].name" "$config")"
    path="$(jq -r ".components[$i].path" "$config")"
    echo "  [$name] gate ($path)"
    if [ ! -d "$REPO_ROOT/$path" ]; then echo "  ! component '$name' path missing: $path"; i=$((i+1)); continue; fi
    _gate_set "$config" ".components[$i].gate" "$REPO_ROOT/$path" "$name" || return 1
    i=$((i+1))
  done
  # cross-cutting root gate, if any non-null step ((.gate // {}) guards a null/absent gate)
  if [ "$(jq -r '[(.gate // {}) | to_entries[] | select(.key != "_comment") | .value] | map(select(. != null and . != "")) | length' "$config")" != "0" ]; then
    echo "  [root] cross-cutting gate"
    _gate_set "$config" ".gate" "$REPO_ROOT" "root(cross-cutting)" || return 1
  fi
  return 0
}
