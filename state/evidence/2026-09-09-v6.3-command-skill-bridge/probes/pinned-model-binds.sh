#!/usr/bin/env bash
# DOES THE PINNED CODEX MODEL ACTUALLY BIND?
#
# The config now pins every codex phase to a model that is NOT the CLI's current default (measured:
# the default moved to gpt-6-astra at ~17:00 UTC on 2026-09-09). A pin to a non-default model is
# exactly the shape that fails silently -- `codex exec` could accept `-m`, ignore it, and run the
# default, and every transcript would look fine unless someone read the header. That is this repo's
# 2026-09-09 ratchet ("a flag that PARSES is not a flag that BINDS") applied to the model flag.
#
# Driven through the SHIPPED resolvers and the SHIPPED arg builder over the REAL config -- never a
# hand-assembled argv (ratchet 2026-09-09).
#
# COST: 2 real codex calls. PROBE_SKIP_MODEL=1 skips them.
#   Run from the repo root:  bash state/evidence/2026-09-09-v6.3-command-skill-bridge/probes/pinned-model-binds.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${PROBE_OUT_DIR:-$(cd "$HERE/.." && pwd)}"
ROOT="$(cd "$HERE/../../../.." && pwd)"
if [ "${PROBE_SKIP_MODEL:-0}" = "1" ]; then echo "--   skipped (PROBE_SKIP_MODEL=1)"; exit 0; fi
LOG="$OUT/pinned-model-binds.txt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
rc=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; rc=1; }
note(){ echo "  ..   $1"; }

# shellcheck source=/dev/null
. "$ROOT/plugin/engine/lib/gate.sh"
# shellcheck source=/dev/null
. "$ROOT/plugin/engine/lib/invoke-codex.sh"
CFG="$ROOT/harness/harness.config.json"

PIN="$(phase_codex_model "$CFG" review)"
EFF="$(phase_codex_effort "$CFG" review)"
note "config pins review.codex.model = $PIN @ $EFF"
[ -n "$PIN" ] && [ "$PIN" != "null" ] || { echo "REFUSING: no pinned model in the config - nothing to verify"; exit 2; }

echo
echo "### arm 1: the CLI's CURRENT default (no -m), for contrast"
lm="$(mktemp)"
printf 'Reply with the single word OK.' | codex --sandbox read-only --ask-for-approval never exec - \
  --cd "$ROOT" --skip-git-repo-check --output-last-message "$lm" -c 'approval_policy="never"' \
  > "$OUT/pinned-default.log" 2>&1
rm -f "$lm"
DEF="$(grep -m1 -E '^model:' "$OUT/pinned-default.log" | tr -d '\r' | sed 's/^model: //')"
note "CLI default today: $DEF"

echo
echo "### arm 2: the SHIPPED builder, with the config's pin"
# invoke_codex is what second_review/Invoke-SecondReview call; nothing here is typed by hand.
MSG="$(invoke_codex read-only 'Reply with the single word OK.' "$ROOT" "$OUT/pinned-model.log" \
        "$PIN" "$EFF" "$(jq -r '.models.codex.timeoutSeconds // 900' "$CFG")" 2>&1)"
IRC=$?
note "invoke_codex rc=$IRC final=[$(printf '%s' "$MSG" | tr -d '\r' | head -c 40)]"
# THE EXIT CODE IS PART OF THE ASSERTION, not a note. Measured on gpt-6-luna: codex prints the
# REQUESTED model in the session header and only then fails with HTTP 400 ("not supported when using
# Codex with a ChatGPT account"). So a header match alone passes on a model that cannot run - which
# is exactly what this arm existed to rule out. The first version of this probe captured rc and only
# printed it.
[ "$IRC" -eq 0 ] && ok "the pinned run actually SUCCEEDED (exit 0) - the header is not a lone witness" \
                 || bad "the pinned run FAILED (exit $IRC) - the header echoes the request, so the pin is NOT usable"
GOT="$(grep -m1 -E '^model:' "$OUT/pinned-model.log" | tr -d '\r' | sed 's/^model: //')"
GOTE="$(grep -m1 -E '^reasoning effort:' "$OUT/pinned-model.log" | tr -d '\r' | sed 's/^reasoning effort: //')"
note "header reports: model=$GOT effort=$GOTE"

[ -n "$GOT" ] && ok "the transcript carries a model header to assert on" || bad "no model header - the assertions below are vacuous"
if [ "$GOT" = "$PIN" ]; then
  ok "THE PIN BINDS - codex ran the configured $PIN, not its default"
else
  bad "THE PIN DID NOT BIND - configured $PIN, codex ran $GOT (a silent substitution)"
fi
[ "$GOTE" = "$EFF" ] && ok "the pinned depth bound too ($EFF)" || bad "effort is $GOTE, configured $EFF"
# The contrast is what makes arm 2 a measurement rather than a coincidence: if the pin equals the
# CLI default, the arm cannot tell binding from doing nothing.
if [ "$PIN" = "$DEF" ]; then
  note "NOTE: the pin currently EQUALS the CLI default, so this arm cannot distinguish binding from"
  note "      inheriting. Re-run it after the default next moves, or pin something else to prove it."
else
  ok "the pin differs from the CLI default ($PIN vs $DEF), so binding is genuinely demonstrated"
fi

echo
echo "### result: $([ $rc -eq 0 ] && echo PASS || echo FAIL)"
cd "$ROOT" || exit 1
exec 1>&- 2>&-; wait
node "$HERE/scrub.mjs" "$LOG" "$OUT/pinned-default.log" "$OUT/pinned-model.log" >/dev/null 2>&1
me="$(id -un 2>/dev/null || echo __no_such_user__)"
for f in "$LOG" "$OUT/pinned-default.log" "$OUT/pinned-model.log"; do
  [ -f "$f" ] || continue
  if grep -qi "users[/\\\\]\+$me" "$f"; then echo "FAIL scrubber left the OS username in $f" >&2; rc=1; fi
done
exit $rc
