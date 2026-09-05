#!/usr/bin/env bash
# V5 step (1): the SECOND reviewer, driven through the real engine dispatcher (invoke_phase, read-only,
# vendor = codex), exactly as loop.sh's second_review() does — values resolved from the worktree config.
set -u
W="<repo>"
CFG="$W/harness/harness.config.json"
S="<scratchpad>"
export HARNESS_ENGINE="$W/plugin/engine"
# shellcheck source=/dev/null
source "$W/plugin/engine/lib/gate.sh"
# shellcheck source=/dev/null
source "$W/plugin/engine/lib/invoke-codex.sh"
# shellcheck source=/dev/null
source "$W/plugin/engine/lib/dispatch.sh"

REVIEW_SECOND="$(phase_second_model "$CFG" review)"
REVIEW_SECOND_EFFORT="$(phase_second_effort "$CFG" review)"
REVIEW_CODEX_MODEL="$(phase_codex_model "$CFG" review)"
REVIEW_CODEX_EFFORT="$(phase_codex_effort "$CFG" review)"
CODEX_AUTH="$(jq -r '.models.codex.auth // "chatgpt"' "$CFG")"
CODEX_TIMEOUT="$(jq -r '.models.codex.timeoutSeconds // 900' "$CFG")"
echo "second=$REVIEW_SECOND effort=$REVIEW_SECOND_EFFORT codex_model=$REVIEW_CODEX_MODEL codex_effort=$REVIEW_CODEX_EFFORT auth=$CODEX_AUTH timeout=$CODEX_TIMEOUT"
echo "codex_args would be:"; codex_args read-only "$W" "<lastmsg>" "$REVIEW_CODEX_MODEL" "$REVIEW_CODEX_EFFORT" | tr '\n' ' '; echo

prompt="$(cat "$S/review-prompt.txt")"
log="$S/review-second-codex.log"
out="$S/review-second-codex.out"
INVOKE_PHASE_EFFORT="$REVIEW_SECOND_EFFORT"; INVOKE_PHASE_FALLBACK_EFFORT=""
start=$(date +%s)
if invoke_phase read-only "$prompt" "$W" "$log" "$REVIEW_SECOND" "" "" 20 "$CODEX_AUTH" "$REVIEW_CODEX_MODEL" "$REVIEW_CODEX_EFFORT" "$CODEX_TIMEOUT" > "$out"; then rc=0; else rc=$?; fi
end=$(date +%s)
echo "rc=$rc path=${INVOKE_PHASE_PATH:-} usedFallback=${INVOKE_PHASE_USED_FALLBACK:-} reason=${INVOKE_PHASE_REASON:-} seconds=$((end-start))"
v="$(review_verdict < "$out")"
echo "parsed verdict=$v"
echo "=== final message (from --output-last-message) ==="
cat "$out"
echo "=== tree after judge ==="
git -C "$W" status --short
