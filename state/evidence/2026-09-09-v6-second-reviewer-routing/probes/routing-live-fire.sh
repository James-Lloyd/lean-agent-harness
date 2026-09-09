#!/usr/bin/env bash
# V6.1 — prove that routing `models.review.second` to codex in THIS repo's real config actually
# reaches the Codex CLI with the model and depth the config declares, and that the CLI's OWN header
# reports the effective state (ratchet 2026-09-09: a flag that PARSES is not a flag that BINDS —
# assert the tool's report, never the argv you handed it).
#
# Every arm drives the SHIPPED resolvers and the SHIPPED arg builder over the REAL
# harness/harness.config.json. Nothing here is hand-assembled (ratchet 2026-09-09).
#
# COST: arm C makes ONE real codex call. PROBE_SKIP_MODEL=1 suppresses it; arms A, B and D are free.
# $PROBE_OUT_DIR redirects every file this writes (so a stubbed run cannot overwrite real evidence).
#
#   Run from the repo root:  bash state/evidence/2026-09-09-v6-second-reviewer-routing/probes/routing-live-fire.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${PROBE_OUT_DIR:-$(cd "$HERE/.." && pwd)}"
ROOT="$(cd "$HERE/../../../.." && pwd)"
RAW="$(mktemp)"
LOG="$OUT/routing-live-fire.txt"
SKIP="${PROBE_SKIP_MODEL:-0}"
rc=0
ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; rc=1; }
skip() { echo "  --   $1 (PROBE_SKIP_MODEL=1)"; }

# Write raw first, scrub into place at the end — the OS username must never reach state/evidence/
# through a later cleanup step (ratchet 2026-09-09).
exec > >(tee "$RAW") 2>&1

# shellcheck source=/dev/null
. "$ROOT/plugin/engine/lib/gate.sh"
# shellcheck source=/dev/null
. "$ROOT/plugin/engine/lib/invoke-codex.sh"

CFG="$ROOT/harness/harness.config.json"
echo "### environment"
echo "    codex : $(codex --version 2>&1 | tr -d '\r')"
echo "    auth  : $(codex login status 2>&1 | head -1 | tr -d '\r')"
echo "    config: harness/harness.config.json (the real one, not a fixture)"
echo

# --- A: the shipped resolvers, over the real config (free) ---------------------------------------
echo "### arm A: what the engine resolves for the review phase (free)"
A_SECOND="$(phase_second_model "$CFG" review)"
A_SECOND_EFFORT="$(phase_second_effort "$CFG" review)"
A_CODEX_MODEL="$(phase_codex_model "$CFG" review)"
A_CODEX_EFFORT="$(phase_codex_effort "$CFG" review)"
A_PRIMARY="$(phase_model "$CFG" review)"
echo "    review.model          = $A_PRIMARY"
echo "    review.second.model   = $A_SECOND    (effort $A_SECOND_EFFORT)"
echo "    resolved codex model  = [$A_CODEX_MODEL]   (empty = float on the CLI default, by config)"
echo "    resolved codex effort = $A_CODEX_EFFORT"
[ "$A_SECOND" = "codex" ] && ok "second reviewer routes to codex" || bad "second reviewer is [$A_SECOND], expected codex"
[ "$A_CODEX_EFFORT" = "high" ] && ok "codex depth resolves to high" || bad "codex depth is [$A_CODEX_EFFORT]"
# The whole point of the doc fix in this change: review.codex is READ even though review.model and
# review.fallback are both Claude. If the resolver ever stops reading it, this goes red.
[ "$A_PRIMARY" != "codex" ] && ok "primary reviewer is still Claude ($A_PRIMARY) — doer != judge, and review.codex is read anyway" \
  || bad "primary reviewer became codex; this slice routes the SECOND judge only"
echo

# --- B: negative control — the resolvers can report the OTHER answer (free) -----------------------
# Ratchet 2026-09-09: a probe that reports a verdict must be shown reporting the other one.
echo "### arm B: negative control — a config with no second reviewer (free)"
FIX="$(mktemp)"
jq 'del(.models.review.second) | .models.review.codex.reasoningEffort = "low"' "$CFG" > "$FIX"
B_SECOND="$(phase_second_model "$FIX" review)"
B_EFFORT="$(phase_codex_effort "$FIX" review)"
echo "    fixture review.second.model = [$B_SECOND]   codex effort = [$B_EFFORT]"
[ -z "$B_SECOND" ] && ok "no second reviewer resolves to empty (arm A's check can fail)" || bad "expected empty, got [$B_SECOND]"
[ "$B_EFFORT" = "low" ] && ok "per-phase codex effort wins over the global block (arm A's check can fail)" || bad "expected low, got [$B_EFFORT]"
rm -f "$FIX"
echo

# --- C: live fire — the CLI's own header, from the SHIPPED builder (ONE PAID CALL) ----------------
echo "### arm C: what codex REPORTS its effective state to be (real call)"
TRANSCRIPT="$OUT/second-reviewer-transcript.log"
if [ "$SKIP" = "1" ]; then
  skip "arm C skipped"
else
  # Exactly the call second_review()/Invoke-SecondReview make: read-only, the review phase's codex
  # model and effort, the global timeout. Nothing typed by hand.
  MSG="$(invoke_codex read-only \
    'Reply with the single word ACK and nothing else. Do not read or write any files.' \
    "$ROOT" "$TRANSCRIPT" "$A_CODEX_MODEL" "$A_CODEX_EFFORT" "$(jq -r '.models.codex.timeoutSeconds // 900' "$CFG")" 2>&1)"
  crc=$?
  echo "    invoke_codex rc=$crc  final-message=[$(printf '%s' "$MSG" | tr -d '\r' | head -c 60)]"
  hdr() { grep -m1 -E "^$1:" "$TRANSCRIPT" 2>/dev/null | tr -d '\r'; }
  H_MODEL="$(hdr model)"; H_APPROVAL="$(hdr approval)"; H_SANDBOX="$(hdr sandbox)"
  H_EFFORT="$(grep -m1 -E '^reasoning effort:' "$TRANSCRIPT" 2>/dev/null | tr -d '\r')"
  echo "    header: $H_MODEL | $H_APPROVAL | $H_SANDBOX | $H_EFFORT"
  # Positive control: the header must actually be present, or every assertion below is vacuous.
  [ -n "$H_MODEL" ] && ok "the transcript carries a header to assert on" || bad "no header in the transcript — the assertions below would be vacuous"
  [ "$H_APPROVAL" = "approval: never" ] && ok "approval BINDS (never) — a read-only judge cannot escalate" || bad "approval header is [$H_APPROVAL], expected 'approval: never'"
  [ "$H_SANDBOX" = "sandbox: read-only" ] && ok "sandbox read-only" || bad "sandbox header is [$H_SANDBOX]"
  [ "$H_EFFORT" = "reasoning effort: high" ] && ok "the config's depth reached the CLI" || bad "effort header is [$H_EFFORT], expected high"
  echo "    EFFECTIVE MODEL (config pins none; this is the CLI default today): ${H_MODEL:-unknown}"
fi
echo

# --- D: the argv the shipped builder emits for this config (free) --------------------------------
echo "### arm D: the SHIPPED builder's argv for the second reviewer (free)"
mapfile -t ARGV < <(codex_args read-only "$ROOT" "/tmp/lastmsg" "$A_CODEX_MODEL" "$A_CODEX_EFFORT")
printf '    argv: %s\n' "${ARGV[*]}"
printf '%s\n' "${ARGV[@]}" | grep -qx -- '-c' && ok "carries -c overrides" || bad "no -c override in argv"
printf '%s\n' "${ARGV[@]}" | grep -qx 'model_reasoning_effort="high"' && ok "depth is passed as a -c override" || bad "model_reasoning_effort not in argv"
if [ -z "$A_CODEX_MODEL" ] || [ "$A_CODEX_MODEL" = "null" ]; then
  printf '%s\n' "${ARGV[@]}" | grep -qx -- '-m' && bad "-m emitted although the config pins no model" || ok "no -m — floats on the CLI default, as configured"
else
  printf '%s\n' "${ARGV[@]}" | grep -qx -- '-m' && ok "-m emitted for the pinned model" || bad "config pins $A_CODEX_MODEL but no -m in argv"
fi
echo

echo "### result: $([ $rc -eq 0 ] && echo PASS || echo FAIL)"
# Scrub the OS username out of everything this run produced, then land it. scrub.mjs rewrites FILES
# IN PLACE and takes paths, not stdin — piping it produces a one-line status file, which is how the
# first version of this probe destroyed its own log.
cp "$RAW" "$LOG"; rm -f "$RAW"
node "$HERE/scrub.mjs" "$LOG" ${TRANSCRIPT:+"$TRANSCRIPT"} >/dev/null 2>&1 || true
if grep -qi "users[/\\\\]\+$(id -un 2>/dev/null || echo __no_such_user__)" "$LOG"; then
  echo "  FAIL scrubber left the OS username in $LOG" >&2; rc=1
fi
exit $rc
