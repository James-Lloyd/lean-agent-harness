#!/usr/bin/env bash
# Live-fire arms 2 and 3 for the wired repo gate. Run from the repo root:
#   bash state/evidence/2026-09-09-wire-repo-gate/probes/engine-gate-sh.sh
#
# Arm 2 — the dispatcher itself, run directly, FULL output kept (a filtered view cannot prove a twin
#         ran: AGENTS.md 2026-09-06). This is where the two RESULT lines are cited from. Its negative
#         control is arm 4 (red-propagation.sh), which drives the same dispatcher red on demand.
# Arm 3 — the engine's POSIX gate router: plugin/engine/lib/gate.sh -> run_gate, which shells the
#         configured gate command out through `bash -lc`. Carries its own negative control (a config
#         whose gate.test exits 1 must make run_gate return non-zero and name the failed step).
#
#         SCOPE, stated because the first version of this comment overclaimed: this exercises the
#         engine's POSIX ROUTER, not gate.mjs's POSIX branch. It runs under Git Bash on Windows, so
#         node still reports platform win32 and the dispatcher takes its Windows branch either way.
#         gate.mjs's actual POSIX branch is unexercised here — see the README's Residuals.
#
# Writes its own output files and scrubs the username out of them (AGENTS.md 2026-09-07).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"   # probes -> <dir> -> evidence -> state -> repo
cd "$ROOT" || exit 1
LOG="$OUT/engine-gate-sh.txt"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
rc=0

say "### ARM 2: node harness/tests/gate.mjs (direct, full output -> dispatcher-direct.txt)"
t0=$(date +%s)
node harness/tests/gate.mjs > "$OUT/dispatcher-direct.txt" 2>&1
a2=$?; t1=$(date +%s)
say "    exit=$a2  elapsed=$((t1-t0))s"
while IFS= read -r l; do say "    $l"; done < <(grep -aE '^(===|RESULT|GATE|!!!)' "$OUT/dispatcher-direct.txt")
[ "$a2" = "0" ] || rc=1

say ""
say "### ARM 3: run_gate from plugin/engine/lib/gate.sh (engine's POSIX router, bash -lc)"
# shellcheck source=/dev/null
. "$ROOT/plugin/engine/lib/gate.sh"
REPO_ROOT="$ROOT"
GATE_FAILED_STEP=""
t0=$(date +%s)
if run_gate "$ROOT/harness/harness.config.json" >> "$LOG" 2>&1; then a3=0; else a3=1; fi
t1=$(date +%s)
say "    exit=$a3  failed_step='${GATE_FAILED_STEP:-}'  elapsed=$((t1-t0))s"
[ "$a3" = "0" ] || rc=1

say ""
say "### arm 3 negative control: same router, gate.test replaced by a command that exits 1"
badcfg="$(mktemp)"
jq '.components[0].gate.test = "node -e \"process.exit(1)\""' "$ROOT/harness/harness.config.json" > "$badcfg"
GATE_FAILED_STEP=""
if run_gate "$badcfg" >> "$LOG" 2>&1; then ctl=0; else ctl=1; fi
say "    exit=$ctl  failed_step='${GATE_FAILED_STEP:-}'"
if [ "$ctl" = "1" ] && [ -n "${GATE_FAILED_STEP:-}" ]; then
  say "    ok control went red and named the step, so arm 3's green is a real verdict"
else
  say "    x CONTROL DID NOT GO RED — arm 3 cannot accuse; its green above means nothing"
  rc=1
fi
rm -f "$badcfg"

say ""
if [ "$rc" = "0" ]; then say "RESULT: arm2=$a2 arm3=$a3 control=$ctl -> GREEN"; else say "RESULT: arm2=$a2 arm3=$a3 control=$ctl -> RED"; fi
node "$HERE/scrub.mjs" "$LOG" "$OUT/dispatcher-direct.txt" >/dev/null
exit "$rc"
