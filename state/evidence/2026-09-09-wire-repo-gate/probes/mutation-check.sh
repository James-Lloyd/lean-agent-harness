#!/usr/bin/env bash
# Arm 5 — the new `gate wiring` assertions must FAIL against the PRE-FIX state (an all-null gate),
# and fail with a wrong VALUE rather than a stack trace (AGENTS.md 2026-09-06). Both twins.
#
# The block under test is EXTRACTED from run-tests.{sh,ps1} by marker, never transcribed — a
# transcription slip would make the check agree with itself (the 2026-09-08 differential's rule).
# It runs against a scratch tree whose only difference from this repo is the config's gate.test:
#   MUTANT  (gate.test = null, the shape harness-doctor found on 2026-09-07) -> must FAIL
#   CONTROL (gate.test = the wired command)                                  -> must PASS
# The CONTROL is what proves the extracted block can pass at all; without it, a block that failed for
# an unrelated reason (a bad path in the scratch tree, a missing node) would satisfy the MUTANT case
# and prove nothing.
#
#   Run from the repo root:  bash state/evidence/2026-09-09-wire-repo-gate/probes/mutation-check.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
LOG="$(cd "$HERE/.." && pwd)/mutation-check.txt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
rc=0

extract() {  # $1 file  $2 start-marker  $3 end-marker
  awk -v s="$2" -v e="$3" 'index($0,s)==1{f=1} index($0,e)==1{f=0} f' "$1"
}

SH_BLOCK="$(extract "$ROOT/harness/tests/run-tests.sh" 'echo "gate wiring:' 'echo "plugin: cross-platform hook dispatcher (node)"')"
PS_BLOCK="$(extract "$ROOT/harness/tests/run-tests.ps1" 'Write-Host "gate wiring:' 'Write-Host "plugin: cross-platform hook dispatcher (node)"')"
[ -n "$SH_BLOCK" ] && [ -n "$PS_BLOCK" ] || { echo "REFUSING: could not extract the gate-wiring block from both twins"; exit 2; }
# Refuse to run on a bad extraction: an awk range that silently caught half a block would make every
# case below agree with itself. Both twins must yield the same, non-zero number of assertions.
n_sh="$(printf '%s\n' "$SH_BLOCK" | grep -cE '^[[:space:]]*ok ')"
n_ps="$(printf '%s\n' "$PS_BLOCK" | grep -cE '^[[:space:]]*ok ')"
echo "extracted: sh $n_sh assertions, ps $n_ps assertions"
[ "$n_sh" -gt 0 ] && [ "$n_sh" = "$n_ps" ] || { echo "REFUSING: twin assertion counts differ or are zero (sh=$n_sh ps=$n_ps) — extraction or twin parity is broken"; exit 2; }

make_tree() {  # $1 dest  $2 jq program applied to the real config
  mkdir -p "$1/harness/tests"
  jq "$2" "$ROOT/harness/harness.config.json" > "$1/harness/harness.config.json"
  cp "$ROOT/harness/tests/gate.mjs" "$1/harness/tests/gate.mjs"
}

run_sh() {  # $1 tree -> echoes "pass fail"
  local d="$1"
  { echo 'PASS=0; FAIL=0'
    echo 'ok() { if [ "$1" = "1" ]; then PASS=$((PASS+1)); echo "  ok  $2"; else FAIL=$((FAIL+1)); echo "  FAIL $2"; fi; }'
    echo "HERE=\"$d/harness/tests\""
    printf '%s\n' "$SH_BLOCK"
    echo 'echo "COUNTS $PASS $FAIL"'
  } > "$d/block.sh"
  bash "$d/block.sh" 2>&1
}

run_ps() {  # $1 tree
  local d="$1"
  { echo 'Set-StrictMode -Version Latest'
    # Match the real suite's preamble: StrictMode + Stop, and the engine's gate.ps1 dot-sourced so
    # Get-Prop exists. Without the dot-source the first three assertions silently never RAN (they
    # died on a missing command) and the mutant looked green — the same "silence is not success"
    # trap this arm exists to close.
    echo '$ErrorActionPreference = "Stop"'
    echo ". '$(cygpath -w "$ROOT" 2>/dev/null || echo "$ROOT")\\plugin\\engine\\lib\\gate.ps1'"
    echo '$script:PASS = 0; $script:FAIL = 0'
    echo 'function ok([string]$msg, $cond) { if ($cond) { $script:PASS++; Write-Host "  ok  $msg" } else { $script:FAIL++; Write-Host "  FAIL $msg" } }'
    echo "\$here = '$(cygpath -w "$d" 2>/dev/null || echo "$d")\\harness\\tests'"
    printf '%s\n' "$PS_BLOCK"
    echo 'Write-Host "COUNTS $script:PASS $script:FAIL"'
  } > "$d/block.ps1"
  powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$d" 2>/dev/null || echo "$d")\\block.ps1" 2>&1
}

check() {  # $1 label  $2 runner  $3 tree  $4 expect: pass|fail  [$5 = substring the failure must name]
  local out counts p f
  out="$($2 "$3")"
  counts="$(printf '%s\n' "$out" | grep -a '^COUNTS' | tail -1)"
  p="$(echo "$counts" | awk '{print $2}')"; f="$(echo "$counts" | awk '{print $3}')"
  printf '%s\n' "$out" | grep -aE '^\s+(ok|FAIL) ' | sed 's/^/      /'
  if [ -z "$counts" ]; then echo "  FAIL $1 — block CRASHED (no COUNTS line); a stack trace is not a failing assertion"; rc=1; return; fi
  if [ "$4" = "fail" ] && [ "${f:-0}" -gt 0 ]; then
    if [ -n "${5:-}" ] && ! printf '%s\n' "$out" | grep -aE '^\s+FAIL ' | grep -qF "$5"; then
      echo "  FAIL $1 — $f failure(s), but none of them names '$5' (the wrong assertion caught it)"; rc=1; return
    fi
    echo "  ok   $1 — $f assertion(s) failed as required (pass=$p)${5:+, naming '$5'}"
  elif [ "$4" = "pass" ] && [ "${f:-0}" -eq 0 ] && [ "${p:-0}" -gt 0 ]; then echo "  ok   $1 — all $p assertions passed"
  else echo "  FAIL $1 — pass=$p fail=$f, expected $4"; rc=1; fi
}

for twin in sh ps; do
  echo
  echo "### ${twin} twin"
  mut="$(mktemp -d)"; ctl="$(mktemp -d)"; mjs="$(mktemp -d)"; nog="$(mktemp -d)"
  make_tree "$mut" '.components[0].gate.test = null'
  # A config that drops the gate OBJECT is the other plausible revert shape, and the one that used to
  # abort the whole PS suite on a missing-property error instead of failing these assertions.
  make_tree "$nog" 'del(.components[0].gate)'
  make_tree "$ctl" '.'
  # Third tree: config wired, but gate.mjs MUTATED so findBash looks bash up on PATH before its !WIN
  # guard — i.e. the WSL trap re-opened, the exact regression the last assertion claims to catch.
  # The first version of that assertion grepped the whole file for two tokens, which this mutant
  # still contains, so it passed; it is now position-based and this case is what proves it.
  make_tree "$mjs" '.'
  awk '{print} /^function findBash\(\) \{/ && !done {print "  const p = which(\047bash\047); if (p) return { exe: p };"; done=1}' \
      "$ROOT/harness/tests/gate.mjs" > "$mjs/harness/tests/gate.mjs"
  node --check "$mjs/harness/tests/gate.mjs" || { echo "REFUSING: the mutated gate.mjs does not parse — the mutant would fail for the wrong reason"; exit 2; }
  check "MUTANT  (gate.test = null)"        "run_$twin" "$mut" fail
  check "MUTANT  (gate object deleted)"     "run_$twin" "$nog" fail
  check "MUTANT  (gate.mjs WSL trap open)"  "run_$twin" "$mjs" fail "WSL trap"
  check "CONTROL (both intact)"             "run_$twin" "$ctl" pass
  rm -rf "$mut" "$ctl" "$mjs" "$nog"
done

echo
[ "$rc" = "0" ] && echo "RESULT: arm 5 GREEN" || echo "RESULT: arm 5 RED"
exec 1>&- 2>&-; wait
node "$HERE/scrub.mjs" "$LOG" >/dev/null
exit "$rc"
