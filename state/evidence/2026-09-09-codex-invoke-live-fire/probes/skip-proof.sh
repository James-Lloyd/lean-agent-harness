#!/usr/bin/env bash
# skip-proof — PROBE_SKIP_MODEL=1 must actually suppress the PAID calls in EVERY probe here, not just
# the ones whose author remembered (AGENTS.md 2026-09-07: a documented cost switch is honoured by
# every script the doc points at, proved with a stub on PATH plus a negative control).
#
# Method: put a fake `codex` first on PATH that records its argv and exits 1. Then
#   - with the switch ON, no probe may invoke `codex exec` (the paid subcommand). `codex --help`,
#     `codex --version` and `codex login status` are free and ARE expected — asserting "no codex at
#     all" would be the wrong claim, and would pass for the wrong reason.
#   - with the switch OFF, a probe MUST reach `codex exec` — the negative control, without which a
#     stub that is never called for an unrelated reason (a probe that dies early, a typo'd path)
#     reads exactly like a probe that honoured the switch.
#
# Calls no real model in either direction: the stub shadows the real CLI throughout — and note the
# stub is emitted as BOTH `codex` and `codex.cmd`, because Windows PowerShell will not execute an
# extensionless file, so a bash-only stub is invisible to the .ps1 probe and its "no paid call"
# result would be a lie (measured: the first version of this file let the PS probe reach the real
# CLI during its own negative control).
#
# It runs the probes from a COPY in a temp dir. Each probe derives its output directory from its own
# location, so running them in place would overwrite the real captured evidence with stub runs —
# which is exactly what the first version of this file did, destroying six result files.
#   Run from the repo root:  bash state/evidence/2026-09-09-codex-invoke-live-fire/probes/skip-proof.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# $PROBE_OUT_DIR redirects every output this script writes. skip-proof.sh sets it so a stub run
# cannot overwrite real captured evidence with a stub result (it did, once).
OUT="${PROBE_OUT_DIR:-$(cd "$HERE/.." && pwd)}"
ROOT="$(cd "$HERE/../../../.." && pwd)"
LOG="$(cd "$HERE/.." && pwd)/skip-proof.txt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
rc=0

# The probes run FROM THEIR REAL LOCATION (they resolve the repo root and the git blob relative to
# it, so a copy in a temp tree cannot work) with $PROBE_OUT_DIR pointed at a throwaway dir, so a stub
# run writes its results there instead of over the real evidence.
SANDBOX="$(mktemp -d)"
PROBES="$HERE"
export PROBE_OUT_DIR="$SANDBOX"

STUB="$(mktemp -d)"
HITS="$STUB/hits.txt"; : > "$HITS"
cat > "$STUB/codex" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HARNESS_STUB_HITS"
case " $* " in *" exec "*) echo "STUB CODEX: a PAID exec call was attempted" >&2; exit 1;; esac
# free subcommands answer plausibly so a probe's own free arms behave
case "${1:-}" in
  --version) echo "codex-cli 0.0.0-stub";;
  login)     echo "Logged in using ChatGPT";;
  --help)    echo "--sandbox --ask-for-approval --cd";;
  exec)      echo "--skip-git-repo-check --output-last-message --sandbox --cd";;
esac
exit 0
STUBEOF
chmod +x "$STUB/codex"
# The PowerShell-visible twin of the stub. Without it, `& codex` under PS 5.1 skips the extensionless
# file and finds the REAL npm shim further down PATH.
cat > "$STUB/codex.cmd" <<'CMDEOF'
@echo off
bash "%~dp0codex" %*
CMDEOF
export HARNESS_STUB_HITS="$HITS"

paid_calls() { grep -c ' exec ' "$HITS" 2>/dev/null | tr -d '\r'; }

run_probe() {  # $1 label  $2 skip(0|1)  $3.. command
  local label="$1" skip="$2"; shift 2
  : > "$HITS"
  ( export PATH="$STUB:$PATH"; export PROBE_SKIP_MODEL="$skip"; "$@" >/dev/null 2>&1 )
  local n; n="$(paid_calls)"; [ -n "$n" ] || n=0
  echo "$n"
}

echo "### switch ON: no probe may reach \`codex exec\`"
for p in live-fire.sh loop-review-codex.sh builder-differential.sh approval-matrix.sh; do
  n="$(run_probe "$p" 1 bash "$PROBES/$p")"
  if [ "$n" = "0" ]; then echo "  ok   $p made 0 paid calls"; else echo "  FAIL $p made $n paid call(s) with the switch ON"; rc=1; fi
done
n="$(run_probe ps-twin.ps1 1 powershell -NoProfile -ExecutionPolicy Bypass -File "$PROBES/ps-twin.ps1")"
if [ "$n" = "0" ]; then echo "  ok   ps-twin.ps1 made 0 paid calls"; else echo "  FAIL ps-twin.ps1 made $n paid call(s) with the switch ON"; rc=1; fi

echo
echo "### NEGATIVE CONTROL — switch OFF: the same probes MUST reach \`codex exec\`"
echo "     (otherwise every line above passes for the wrong reason)"
for p in builder-differential.sh approval-matrix.sh; do
  n="$(run_probe "$p" 0 bash "$PROBES/$p")"
  if [ "${n:-0}" -gt 0 ]; then echo "  ok   $p attempted $n paid call(s) when not suppressed"; else echo "  FAIL $p attempted none — the detector cannot accuse"; rc=1; fi
done
n="$(run_probe ps-twin.ps1 0 powershell -NoProfile -ExecutionPolicy Bypass -File "$PROBES/ps-twin.ps1")"
if [ "${n:-0}" -gt 0 ]; then echo "  ok   ps-twin.ps1 attempted $n paid call(s) when not suppressed"; else echo "  FAIL ps-twin.ps1 attempted none — the detector cannot accuse"; rc=1; fi

rm -rf "$STUB" "$SANDBOX"
echo
echo "RESULT: skip-proof $([ "$rc" = 0 ] && echo GREEN || echo RED)"
exec 1>&- 2>&-; wait
node "$HERE/scrub.mjs" "$LOG" >/dev/null 2>&1
exit "$rc"
