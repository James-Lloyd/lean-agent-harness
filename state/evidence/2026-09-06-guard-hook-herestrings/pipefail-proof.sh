#!/usr/bin/env bash
# Proof for fix_plan: "Convert the remaining `printf '%s' "$x" | grep -q` sites ... to here-strings".
#
# It does not edit the shipped hook. It builds a MUTANT by reversing the conversion on the one site
# that matches `rm -rf` (the `pats` loop), then runs both through a real oversized payload with
# `set -euo pipefail` injected -- the hardening that was, until this change, a silent disarm.
#
# Usage: bash pipefail-proof.sh <repo root>
set -u
ROOT="$1"
HOOK="$ROOT/plugin/hooks/block-destructive.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- 1. no live site still matches through a pipe -----------------------------------------------
echo "=== live \`printf | grep\` sites remaining under plugin/hooks/ ==="
if grep -rn "printf '%s'.*| *grep" "$ROOT"/plugin/hooks/*.sh; then
  echo "  ^ UNCONVERTED SITES FOUND"
else
  echo "  none"
fi
echo

# --- 2. the fixture -----------------------------------------------------------------------------
# BOTH conditions are required to reproduce the fail-open, and a fixture missing either one passes
# against the broken code:
#   (i)  the match sorts FIRST, so grep can exit while printf is still writing;
#   (ii) the bulk follows a NEWLINE -- grep cannot match until it has read a complete line, so a
#        single 200 KB line forces it to read everything and printf never takes SIGPIPE.
{ printf 'rm -rf /\n'
  awk 'BEGIN{for(i=0;i<4000;i++) printf "filler line %d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i}'
} > "$WORK/cmd.txt"
jq -n --rawfile c "$WORK/cmd.txt" '{tool_name:"Bash", tool_input:{command:$c}}' > "$WORK/pay.json"

# a single-line control of the same size, to show why the original fixture proved nothing
{ printf 'rm -rf / ; '; head -c 200000 /dev/zero | tr '\0' 'x'; } > "$WORK/cmd1.txt"
jq -n --rawfile c "$WORK/cmd1.txt" '{tool_name:"Bash", tool_input:{command:$c}}' > "$WORK/pay1.json"

# --- 3. the mutant: reverse the conversion on the pats-loop site ---------------------------------
sed 's#if grep -iEq "\$rx" <<< "\$scan"; then#if printf '"'"'%s'"'"' "$scan" | grep -iEq "$rx"; then#' \
  "$HOOK" > "$WORK/mutant.sh"
if ! grep -q 'printf .%s. "\$scan" | grep -iEq "\$rx"' "$WORK/mutant.sh"; then
  echo "FATAL: the mutant did not apply - the shipped hook no longer has the expected here-string site"
  exit 1
fi

pf() { { head -1 "$1"; echo 'set -euo pipefail'; tail -n +2 "$1"; } > "$1.pf"; echo "$1.pf"; }
rc() { bash "$1" < "$2" >/dev/null 2>&1; echo $?; }

cp "$HOOK" "$WORK/shipped.sh"
echo "=== exit codes  (2 = DENIED, guard fired | 0 = ALLOWED, guard failed OPEN) ==="
printf '  %-38s %-10s %s\n' 'payload / hook' 'MUTANT' 'SHIPPED'
printf '  %-38s %-10s %s\n' 'multi-line 195 KB, hook as-is' \
  "$(rc "$WORK/mutant.sh" "$WORK/pay.json")"  "$(rc "$WORK/shipped.sh" "$WORK/pay.json")"
printf '  %-38s %-10s %s\n' "multi-line 195 KB, +pipefail" \
  "$(rc "$(pf "$WORK/mutant.sh")" "$WORK/pay.json")" "$(rc "$(pf "$WORK/shipped.sh")" "$WORK/pay.json")"
printf '  %-38s %-10s %s\n' "SINGLE-line 200 KB, +pipefail" \
  "$(rc "$(pf "$WORK/mutant.sh")" "$WORK/pay1.json")" "$(rc "$(pf "$WORK/shipped.sh")" "$WORK/pay1.json")"
echo
echo "Row 2 is the defect: the mutant ALLOWS a real 'rm -rf /'. Row 1 shows why it was latent rather"
echo "than live (the hooks set no shell options). Row 3 shows why the fixture shipped in PR #16 could"
echo "not have caught it: on one line grep must read all 200 KB before it can match, so printf never"
echo "takes SIGPIPE and the broken hook denies correctly."
