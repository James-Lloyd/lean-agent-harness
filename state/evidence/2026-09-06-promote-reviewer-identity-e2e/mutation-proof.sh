#!/usr/bin/env bash
# Mutation proof for the SIGPIPE fix: show that the new >64 KiB assertions are load-bearing.
#
# It does not edit the shipped lib. It sources risk.sh, then REDEFINES money_signal with the exact
# pre-fix body (`printf '%s' "$text" | grep -q`) and re-classifies the same fixture, so the two
# implementations can be compared side by side under the `set -o pipefail` the real callers use.
set -uo pipefail

REPO="$(git rev-parse --show-toplevel)"
ENGINE="${HARNESS_ENGINE:-$REPO/plugin/engine}"
. "$ENGINE/lib/risk.sh"

CFG="$(mktemp)"
cat > "$CFG" <<'JSON'
{ "promotion": { "enabled": true,
  "staging": { "branch": "staging", "autoMergeAtOrBelow": "low" },
  "prod": { "branch": "main", "autoMerge": false },
  "alwaysHuman": ["**/payments/**"],
  "moneySignals": ["price", "refund", "tax"],
  "criteria": { "maxChangedLines": 1000 },
  "preconditions": { "gateGreen": true, "reviewShip": true, "e2eEvidence": true } } }
JSON

RF="$(mktemp)"; RA="$(mktemp)"
printf 'src/util.ts\n' > "$RF"
# The money word goes FIRST, then 200 KiB of filler. Order is load-bearing: `grep -q` exits the moment
# it matches, so an EARLY match leaves printf with ~200 KiB still to write -> SIGPIPE -> pipefail 141.
# Put the word at the END instead and grep must read everything before matching, printf finishes
# cleanly, and the buggy implementation returns the RIGHT answer. A regression test for this defect is
# only load-bearing if the match is early and the filler is long.
{ printf 'const p = price * 2\n'; head -c 200000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$RA"
echo "fixture: $(wc -c < "$RA") bytes of added text, one money word ('price') at the START"
echo "pipefail is $(set -o | grep pipefail | awk '{print $2}')"
echo

echo "--- FIXED (shipped): here-string, no pipe ---"
tier="$(deterministic_risk "$CFG" 10 "$RF" "$RA")"
echo "  tier     : ${tier%%|*}"
echo "  reasons  : ${tier#*|}"
echo "  decision : $(promotion_decision "$CFG" staging "${tier%%|*}" "${tier%%|*}" 1 1 1 1)"
echo

echo "--- MUTANT (pre-fix): printf | grep -q ---"
money_signal() {  # the exact body this batch replaced
  local text="$1" term="$2" esc
  [ -n "$text" ] && [ -n "$term" ] || return 1
  esc="$(printf '%s' "$term" | sed -e 's/[.[\*^$()+?{}|\\]/\\&/g' -e 's/\]/\\]/g')"
  printf '%s' "$text" | grep -qiE "(^|[^A-Za-z0-9])${esc}"
}
tier="$(deterministic_risk "$CFG" 10 "$RF" "$RA")"
echo "  tier     : ${tier%%|*}"
echo "  reasons  : ${tier#*|}"
echo "  decision : $(promotion_decision "$CFG" staging "${tier%%|*}" "${tier%%|*}" 1 1 1 1)"
echo
echo "The mutant classifies a money diff LOW and returns AUTO — the money rule failed OPEN."
echo "Same fixture under 64 KiB (fits the pipe buffer, so the mutant looks fine):"
printf 'const p = price * 2\n' > "$RA"
tier="$(deterministic_risk "$CFG" 10 "$RF" "$RA")"
echo "  mutant on a SMALL fixture: tier=${tier%%|*}  <- why every unit test stayed green"

rm -f "$CFG" "$RF" "$RA"
