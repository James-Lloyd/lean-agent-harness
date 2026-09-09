#!/usr/bin/env bash
# Does a pin to an UNKNOWN model fail loudly, or silently fall back to the default?
#
# The config pins every codex phase to an explicit ID. That is only safe if a wrong or retired ID is
# LOUD -- if codex quietly substitutes its default, a typo'd pin would run the wrong model forever and
# every transcript would look fine. This is the same question as "a flag that parses is not a flag
# that binds", asked in the failure direction.
#
# It doubles as an ID check: pass a candidate ID as $1 and the arm reports whether it resolves.
#
# COST: 1 real codex call per ID tried. PROBE_SKIP_MODEL=1 skips it.
#   bash state/evidence/2026-09-09-v6.3-command-skill-bridge/probes/model-id-check.sh <model-id>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${PROBE_OUT_DIR:-$(cd "$HERE/.." && pwd)}"
ROOT="$(cd "$HERE/../../../.." && pwd)"
CAND="${1:-}"
[ -n "$CAND" ] || { echo "usage: model-id-check.sh <model-id>"; exit 2; }
if [ "${PROBE_SKIP_MODEL:-0}" = "1" ]; then echo "--   skipped (PROBE_SKIP_MODEL=1)"; exit 0; fi
LOG="$OUT/model-id-check-$CAND.txt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
rc=0

echo "### candidate model id: $CAND"
lg="$OUT/model-id-$CAND.log"
lm="$(mktemp)"
printf 'Reply with the single word OK.' | codex --sandbox read-only --ask-for-approval never exec - \
  --cd "$ROOT" --skip-git-repo-check --output-last-message "$lm" -c 'approval_policy="never"' \
  -m "$CAND" > "$lg" 2>&1
crc=$?
rm -f "$lm"
GOT="$(grep -m1 -E '^model:' "$lg" | tr -d '\r' | sed 's/^model: //')"
echo "    exit=$crc  header model=${GOT:-<none>}"
# THE HEADER IS NOT PROOF OF VALIDITY. Measured on gpt-6-luna: the session header printed
# `model: gpt-6-luna` and the run then died with HTTP 400 "not supported when using Codex with a
# ChatGPT account". Codex echoes the REQUESTED id in the header before it validates it, so a header
# match must be paired with a zero exit or the check passes on a model that cannot run.
if [ "$GOT" = "$CAND" ] && [ "$crc" -eq 0 ]; then
  echo "  ok   '$CAND' RESOLVES and RUNS (header matches, exit 0)"
  echo "VALID $CAND" > "$OUT/model-id-verdict-$CAND.txt"
elif [ "$GOT" = "$CAND" ]; then
  echo "  FAIL '$CAND' is echoed in the header but the run FAILED (exit $crc) - the id is not usable"
  echo "    the error:"
  grep -m2 -E '^(ERROR|warning):' "$lg" | sed 's/^/      /'
  echo "UNUSABLE $CAND (header echo, exit $crc)" > "$OUT/model-id-verdict-$CAND.txt"
  rc=1
elif [ -n "$GOT" ]; then
  echo "  FAIL SILENT SUBSTITUTION - asked for '$CAND', codex ran '$GOT'"
  echo "  ..   a wrong or retired pin would run the wrong model with no error. Pins cannot be trusted"
  echo "  ..   from the config alone; read the header back."
  echo "SUBSTITUTED $CAND -> $GOT" > "$OUT/model-id-verdict-$CAND.txt"
  rc=1
else
  echo "  ok   '$CAND' was REJECTED loudly (no session header; exit $crc) - a bad pin fails, it does not substitute"
  echo "    first lines of the error:"
  head -6 "$lg" | sed 's/^/      /'
  echo "INVALID $CAND" > "$OUT/model-id-verdict-$CAND.txt"
fi

cd "$ROOT" || exit 1
exec 1>&- 2>&-; wait
node "$HERE/scrub.mjs" "$LOG" "$lg" >/dev/null 2>&1
me="$(id -un 2>/dev/null || echo __no_such_user__)"
for f in "$LOG" "$lg"; do
  [ -f "$f" ] || continue
  if grep -qi "users[/\\\\]\+$me" "$f"; then echo "FAIL scrubber left the OS username in $f" >&2; rc=1; fi
done
exit $rc
