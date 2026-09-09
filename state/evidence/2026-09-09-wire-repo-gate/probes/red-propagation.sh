#!/usr/bin/env bash
# Arm 4 — the point of wiring the gate is that a RED suite turns the GATE red. Prove it, with a
# positive control, on a scratch copy of gate.mjs beside stub twins (seconds, no real suite run).
#
#   RED   : both stub twins exit 1  -> gate.mjs exits 1 and prints "GATE: RED"
#   RED-A : only the .ps1 twin fails -> still 1 (one red twin is enough)
#   RED-B : only the .sh twin fails  -> still 1
#   GREEN : both stub twins exit 0  -> gate.mjs exits 0 and prints "GATE: green"
#
# The GREEN case is the positive control: without it, a gate.mjs that failed for an unrelated reason
# (a crash, a missing interpreter) would make every RED case pass and prove nothing.
#
#   Run from the repo root:  bash state/evidence/2026-09-09-wire-repo-gate/probes/red-propagation.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
LOG="$(cd "$HERE/.." && pwd)/red-propagation.txt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
rc=0

run_case() {  # $1 label  $2 ps-exit  $3 sh-exit  $4 expected-gate-exit
  local label="$1" psx="$2" shx="$3" want="$4"
  local d; d="$(mktemp -d)"
  cp "$ROOT/harness/tests/gate.mjs" "$d/gate.mjs"
  printf '%s\n' '#!/usr/bin/env bash' "echo '  stub bash twin'; exit $shx" > "$d/run-tests.sh"
  printf '%s\r\n' "Write-Host '  stub ps twin'" "exit $psx" > "$d/run-tests.ps1"
  local out got
  out="$(node "$d/gate.mjs" 2>&1)"; got=$?
  if [ "$got" = "$want" ]; then echo "  ok   $label -> exit $got (expected $want)"; else echo "  FAIL $label -> exit $got (expected $want)"; rc=1; fi
  printf '%s\n' "$out" | grep -aE '^(GATE|!!!)' | sed 's/^/       /'
  rm -rf "$d"
}

echo "### arm 4: red propagation through the dispatcher (stub twins)"
run_case "GREEN  (both twins pass) [positive control]" 0 0 0
run_case "RED    (both twins fail)"                    1 1 1
run_case "RED-A  (only .ps1 fails)"                    1 0 1
run_case "RED-B  (only .sh fails)"                     0 1 1


# --- the half-grade path (added after fresh-context review) --------------------------------------
# The engine prints a gate command's output ONLY when it exits non-zero, so on a green half-graded
# run the !!! UNGRADED TWIN banner is captured and discarded. HARNESS_GATE_STRICT=1 exists to make
# that reach a caller that reads only the exit code. Force the half-grade the way AGENTS.md
# 2026-09-06 requires — by controlling the ENVIRONMENT the lookup uses, not by editing the code —
# and give it a positive control, because "no banner" and "the probe never ran" look identical.
#
# On Windows findBash probes %ProgramFiles%, %ProgramFiles(x86)%, %LOCALAPPDATA% and `git
# --exec-path`. Point all three at an empty dir and drop git from PATH (System32 stays, so `where`
# and powershell.exe still resolve) and Git Bash becomes unfindable — with the .ps1 twin still run.
half_grade_case() {  # $1 label  $2 strict(0|1)  $3 expected-exit  $4 expect-banner(yes|no)  $5 nogitbash(yes|no)
  local label="$1" strict="$2" want="$3" wantban="$4" nogit="$5"
  local d empty out got ban
  d="$(mktemp -d)"; empty="$(mktemp -d)"
  cp "$ROOT/harness/tests/gate.mjs" "$d/gate.mjs"
  printf '%s\n' '#!/usr/bin/env bash' "echo '  stub bash twin'; exit 0" > "$d/run-tests.sh"
  printf '%s\r\n' "Write-Host '  stub ps twin'" "exit 0" > "$d/run-tests.ps1"
  # Both arms go through force-env.mjs so the only difference between them is the doctored
  # environment, not the launcher (see that file for why `env ProgramFiles=…` cannot do this).
  out="$(node "$HERE/force-env.mjs" "$d/gate.mjs" "$strict" "$([ "$nogit" = yes ] && echo 1 || echo 0)" 2>&1)"; got=$?
  ban=no; printf '%s\n' "$out" | grep -q 'UNGRADED TWIN' && ban=yes
  if [ "$got" = "$want" ] && [ "$ban" = "$wantban" ]; then echo "  ok   $label -> exit $got, banner=$ban"
  else echo "  FAIL $label -> exit $got (expected $want), banner=$ban (expected $wantban)"; rc=1; fi
  printf '%s\n' "$out" | grep -aE '^(GATE|!!! UNGRADED)' | sed 's/^/       /'
  rm -rf "$d" "$empty"
}

echo
echo "### half-grade: an ungraded twin is loud, and fatal only under HARNESS_GATE_STRICT=1"
half_grade_case "CONTROL (Git Bash present, both twins graded)" 0 0 no  no
half_grade_case "no Git Bash, lenient (default)"                0 0 yes yes
half_grade_case "no Git Bash, HARNESS_GATE_STRICT=1"            1 1 yes yes

echo
[ "$rc" = "0" ] && echo "RESULT: arm 4 GREEN" || echo "RESULT: arm 4 RED"
# Let the tee drain before the scrub rewrites the file underneath it.
exec 1>&- 2>&-; wait
node "$HERE/scrub.mjs" "$LOG" >/dev/null
exit "$rc"
