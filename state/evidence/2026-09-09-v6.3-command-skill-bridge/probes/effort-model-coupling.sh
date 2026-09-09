#!/usr/bin/env bash
# Does passing `-c model_reasoning_effort` CHANGE WHICH MODEL Codex runs?
#
# Noticed while setting per-phase Codex defaults: across 21 committed transcripts from 2026-09-09,
# every run that went through the harness engine reported `model: gpt-5.6-sol` and every run invoked
# by hand in a probe reported `model: gpt-6-astra`. The engine's distinguishing flag is
# `-c model_reasoning_effort="<level>"`. If that flag selects the model, then the harness has been
# quietly running a different model from the CLI default, and every per-phase `reasoningEffort` we are
# about to write carries a model change with it.
#
# Same cwd, same prompt, same sandbox/approval flags; the ONLY difference is the effort override.
# Assert the CLI's own header, never the argv (ratchet 2026-09-09).
#
# COST: 3 real codex calls. PROBE_SKIP_MODEL=1 skips them.
#   Run from the repo root:  bash state/evidence/2026-09-09-v6.3-command-skill-bridge/probes/effort-model-coupling.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${PROBE_OUT_DIR:-$(cd "$HERE/.." && pwd)}"
ROOT="$(cd "$HERE/../../../.." && pwd)"
if [ "${PROBE_SKIP_MODEL:-0}" = "1" ]; then echo "--   skipped (PROBE_SKIP_MODEL=1)"; exit 0; fi
LOG="$OUT/effort-model-coupling.txt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
rc=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; rc=1; }
note(){ echo "  ..   $1"; }

# The project config must not contribute a model or effort of its own, or the arms are not isolated.
CFG="$ROOT/.codex/config.toml"
if [ -f "$CFG" ] && grep -qE '^(model|model_reasoning_effort)[[:space:]]*=' "$CFG"; then
  echo "REFUSING: $CFG sets model/effort at top level; this probe cannot isolate the flag"; exit 2
fi
note "project config contributes no top-level model/effort - arms are isolated"

run() {  # $1 label  $2... extra flags
  local label="$1"; shift
  local lg="$OUT/effort-coupling-$label.log"; local lm; lm="$(mktemp)"
  printf 'Reply with the single word OK.' | codex --sandbox read-only --ask-for-approval never exec - \
    --cd "$ROOT" --skip-git-repo-check --output-last-message "$lm" \
    -c 'approval_policy="never"' "$@" > "$lg" 2>&1
  rm -f "$lm"
  local m e
  m="$(grep -m1 -E '^model:' "$lg" | tr -d '\r')"
  e="$(grep -m1 -E '^reasoning effort:' "$lg" | tr -d '\r')"
  echo "$m | $e"
}

echo "### arm 1: NO effort override (the bare CLI default)"
A1="$(run bare)"; note "$A1"
echo "### arm 2: WITH -c model_reasoning_effort=\"high\" (what the harness engine passes)"
A2="$(run high -c 'model_reasoning_effort="high"')"; note "$A2"
echo "### arm 3: WITH -c model_reasoning_effort=\"low\" (a different level, same flag)"
A3="$(run low -c 'model_reasoning_effort="low"')"; note "$A3"
echo

M1="${A1%% |*}"; M2="${A2%% |*}"; M3="${A3%% |*}"
[ -n "$M1" ] && [ -n "$M2" ] && ok "all arms produced a header to compare" || bad "a header was missing - the comparison is vacuous"
if [ "$M1" = "$M2" ] && [ "$M2" = "$M3" ]; then
  ok "the effort flag does NOT change the model (all three: $M1)"
  echo "COUPLING=none  model=$M1" > "$OUT/effort-coupling-verdict.txt"
  note "=> the 21-transcript split has some other cause; per-phase reasoningEffort is safe to set."
else
  bad "THE EFFORT FLAG CHANGES THE MODEL - bare='$M1' high='$M2' low='$M3'"
  echo "COUPLING=yes  bare=$M1 high=$M2 low=$M3" > "$OUT/effort-coupling-verdict.txt"
  note "=> every per-phase reasoningEffort silently carries a model change; the config must PIN"
  note "   models explicitly rather than relying on the CLI default."
fi

echo
echo "### result: $([ $rc -eq 0 ] && echo PASS || echo FAIL)  (either verdict is a finding; FAIL means coupling was found)"
cd "$ROOT" || exit 1
exec 1>&- 2>&-; wait
node "$HERE/scrub.mjs" "$LOG" "$OUT/effort-coupling-bare.log" "$OUT/effort-coupling-high.log" "$OUT/effort-coupling-low.log" >/dev/null 2>&1
me="$(id -un 2>/dev/null || echo __no_such_user__)"
for f in "$LOG" "$OUT/effort-coupling-bare.log" "$OUT/effort-coupling-high.log" "$OUT/effort-coupling-low.log"; do
  [ -f "$f" ] || continue
  if grep -qi "users[/\\\\]\+$me" "$f"; then echo "FAIL scrubber left the OS username in $f" >&2; rc=1; fi
done
exit $rc
