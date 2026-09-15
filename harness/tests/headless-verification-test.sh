#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PROMPT_PATH="${1:-$ROOT/PROMPT.md}"
normalized="$(tr '\r\n\t' '   ' < "$PROMPT_PATH" | sed -E 's/[[:space:]]+/ /g')"
passed=0
failed=0

check() {
  local name="$1" pattern="$2" mode="${3:-present}"
  local found=0
  grep -Fq -- "$pattern" <<< "$normalized" && found=1 || true
  if { [ "$mode" = present ] && [ "$found" -eq 1 ]; } || { [ "$mode" = absent ] && [ "$found" -eq 0 ]; }; then
    echo "  ok  $name"; passed=$((passed+1))
  else
    echo "  FAIL $name"; failed=$((failed+1))
  fi
}

check 'caps model-side verification at two shell commands' 'at most two shell verification commands'
check 'requests a per-command tool timeout no greater than 120 seconds' 'tool timeout no greater than 120 seconds'
check 'forbids background or detached verification' 'Never start verification in the background or as a detached process'
check 'forbids the model from invoking configured complete gates' 'Never invoke a configured complete component or root gate command'
check 'allows a configured gate command only as quoted comparison or search data' 'Reading, searching for, or comparing the configured command as quoted data is allowed'
check 'forbids direct and delegated gate execution' 'executing it directly or through a shell, script, function, subprocess, or wrapper is not'
check 'keeps failed or timed-out targeted checks visible' 'report it plainly in the transcript; do not hide it or convert it into success'
check 'names the runner complete gate as the authority' 'Only that runner gate can make the iteration green'
check 'removes the old model-side complete-gate requirement' "The changed component's gate, then the cross-cutting root gate, all pass" absent

printf '\nRESULT: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
