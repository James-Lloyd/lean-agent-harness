#!/usr/bin/env bash
# Re-runnable proof for the guard-hook twin gap (fix_plan item closed 2026-09-08).
#
# It carries BOTH arms, because the fix is only proven by the contrast:
#   ARM 1 (pre-fix)  — the .sh hook as it stood at the merge-base, which must ALLOW every case.
#   ARM 2 (post-fix) — the .sh hook in the working tree, which must DENY every case.
#   ARM 3 (twin)     — the .ps1 hook, which must agree with arm 2 case for case.
#
# Arm 1 is the discriminating one. Against the pre-fix hook these commands return 0 — a wrong
# VALUE (a real recursive delete is admitted), not an exception — which is what makes the new
# assertions a regression proof rather than a test of the regex syntax (AGENTS.md, 2026-09-06).
#
# Costs nothing and calls no model. Run from the repo root:
#   bash state/evidence/2026-09-08-guard-hook-twin-gap/probes/run-both-arms.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(git rev-parse --show-toplevel)"
hook="$repo/plugin/hooks/block-destructive.sh"
# Pinned to the PRE-FIX commit, not to a moving branch. `origin/main` was the pre-fix hook only until
# this change landed; defaulting to it would make arm 1 print nine DENIED lines after the merge and
# quietly turn the whole proof — and the committed results file — into a self-contradiction.
base="${BASE_REF:-1621ae7}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "=== ARM 1: pre-fix .sh (from $base) — every case must read ALLOWED ==="
if git -C "$repo" show "$base:plugin/hooks/block-destructive.sh" > "$tmp/prefix.sh" 2>/dev/null; then
  bash "$here/twin-gap-cases.sh" "$tmp/prefix.sh"
else
  echo "  (skipped: cannot resolve $base — set BASE_REF to a ref that predates the fix)"
fi

echo
echo "=== ARM 2: post-fix .sh (working tree) — the nine destructive cases must read DENIED ==="
bash "$here/twin-gap-cases.sh" "$hook"

echo
echo "=== ARM 2b: a NEW pattern at real size, with pipefail injected ==="
# AGENTS.md 2026-09-06: a guardrail predicate is not verified until it has run over a real input at
# real size. The four new patterns go through the same `grep -iEq <<< \"\$scan\"` loop as the rest, so
# they inherit the here-string form that replaced the SIGPIPE-prone `printf | grep`. Prove it rather
# than assume it: bulk AFTER a newline (grep cannot exit early until it has read a whole line), and a
# copy of the hook with `set -euo pipefail` injected so a pipeline would inherit printf's 141.
if command -v jq >/dev/null 2>&1; then
  ri="Remove""-Item"
  { printf '%s -Recurse -Force /\n' "$ri"
    awk 'BEGIN{for(i=0;i<4000;i++) printf "filler line %d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i}'
  } > "$tmp/big.txt"
  jq -n --rawfile c "$tmp/big.txt" '{tool_name:"Bash", tool_input:{command:$c}}' > "$tmp/big.json"
  { head -1 "$hook"; echo 'set -euo pipefail'; tail -n +2 "$hook"; } > "$tmp/pf.sh"
  bash "$hook"     < "$tmp/big.json" >/dev/null 2>&1; rc_plain=$?
  bash "$tmp/pf.sh" < "$tmp/big.json" >/dev/null 2>&1; rc_pf=$?
  printf '%-46s rc=%s  %s\n' "oversized multi-line, plain"   "$rc_plain" "$([ "$rc_plain" = 2 ] && echo DENIED || echo ALLOWED)"
  printf '%-46s rc=%s  %s\n' "oversized multi-line, pipefail" "$rc_pf"   "$([ "$rc_pf"    = 2 ] && echo DENIED || echo ALLOWED)"
  # NEGATIVE control: the same oversized shape carrying NO destructive text must come back ALLOWED,
  # or "DENIED" above would prove only that something in a 190 KB payload trips the guard. (Named
  # per this repo's usage, where a POSITIVE control is the arm that proves the oracle can speak.)
  { printf 'echo hello\n'
    awk 'BEGIN{for(i=0;i<4000;i++) printf "filler line %d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i}'
  } > "$tmp/benign.txt"
  jq -n --rawfile c "$tmp/benign.txt" '{tool_name:"Bash", tool_input:{command:$c}}' > "$tmp/benign.json"
  bash "$hook" < "$tmp/benign.json" >/dev/null 2>&1; rc_benign=$?
  printf '%-46s rc=%s  %s\n' "CONTROL: oversized, nothing destructive" "$rc_benign" "$([ "$rc_benign" = 2 ] && echo DENIED || echo ALLOWED)"
else
  echo "  (skipped: jq is needed to encode real newlines into the JSON payload)"
fi

echo
echo "=== ARM 3: the .ps1 twin — must agree with ARM 2 case for case ==="
ps1="$repo/plugin/hooks/block-destructive.ps1"
if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File "$here/twin-gap-cases.ps1" -Hook "$ps1"
elif command -v powershell >/dev/null 2>&1; then
  powershell -NoProfile -ExecutionPolicy Bypass -File "$here/twin-gap-cases.ps1" -Hook "$ps1"
else
  echo "  (skipped: no pwsh/powershell on PATH — arm 3 needs a PowerShell host)"
fi
