#!/usr/bin/env bash
# dispatch.sh — vendor-neutral phase dispatcher (S3; bash mirror of dispatch.ps1). Runs a phase through
# a PRIMARY model and, ONLY on pre-invocation codex-unavailability or a usage/limit-flagged failure,
# retries once on a FALLBACK candidate (claude<->codex); fail-closed on exhaustion. Depends on gate.sh
# (usage_limit_error) and invoke-codex.sh (codex_available, invoke_codex), which loop.sh sources first.
#
# bash can't return a struct: stdout = the phase output, return 0 = success / nonzero = failure, and
# three globals carry the metadata:
#   INVOKE_PHASE_PATH          codex|claude|""   which vendor produced the result ("" on exhaustion)
#   INVOKE_PHASE_USED_FALLBACK 0|1               whether the fallback candidate produced/attempted it
#   INVOKE_PHASE_REASON        ""|invoke-failed|exhausted
# Extra claude args come via a caller-set array INVOKE_PHASE_CLAUDE_ARGS (guarded for the unset/empty case
# under set -u). bash 3.2 / BSD-grep safe.
#
# Discipline (CLAUDE.md ratchet + parent plan §1/§3b/§4c — mirror of dispatch.ps1):
#  - USAGE-LIMIT ONLY ON FAILURE. usage_limit_error is consulted ONLY on a nonzero result; a SUCCESS is
#    returned immediately and NEVER re-examined for usage markers.
#  - SCOPED FALLBACK. Advance to the fallback ONLY on (a) codex-unavailability or (b) a usage-limit
#    failure. A generic non-usage failure returns as failure (invoke-failed) WITHOUT trying the fallback.
#  - WRITE-PHASE RESET. In workspace-write mode, hard-reset to <reset_ref> BEFORE a fallback candidate;
#    never before the primary, never in read-only. A successful write phase is NOT reset (gate +
#    autoRollbackOnRed are the safety net).

# invoke_phase <mode> <prompt> <root> <log> <primary> <fallback> <reset_ref> <max_turns> <codex_auth>
#              <codex_model> <codex_effort> <codex_timeout> [claude_cmd] [codex_cmd]
invoke_phase() {
  local mode="$1" prompt="$2" root="$3" log="$4" primary="$5" fallback="$6" reset_ref="$7" \
        max_turns="${8:-40}" codex_auth="${9:-chatgpt}" codex_model="${10:-}" codex_effort="${11:-}" \
        codex_timeout="${12:-900}" claude_cmd="${13:-${HARNESS_CLAUDE_CMD:-claude}}" codex_cmd="${14:-codex}"
  INVOKE_PHASE_PATH=""; INVOKE_PHASE_USED_FALLBACK=0; INVOKE_PHASE_REASON=""
  local candidates
  candidates=("$primary")
  [ -n "$fallback" ] && candidates+=("$fallback")
  local n="${#candidates[@]}" idx=0 cand is_fallback vendor out rc last_out=""
  while [ "$idx" -lt "$n" ]; do
    cand="${candidates[$idx]}"
    if [ "$idx" -gt 0 ]; then is_fallback=1; else is_fallback=0; fi
    if [ "$is_fallback" = "1" ] && [ "$mode" = "workspace-write" ] && [ -n "$reset_ref" ]; then
      # A usage-limited primary may have left a partial tree; reset to base before the fallback retry.
      git reset --hard "$reset_ref" >/dev/null 2>&1 || true
      git clean -fd >/dev/null 2>&1 || true
    fi
    if [ "$cand" = "codex" ]; then
      vendor="codex"
      if ! codex_available "$codex_auth" "$codex_cmd" >/dev/null 2>&1; then
        last_out="codex unavailable"; idx=$((idx+1)); continue   # (a) advance
      fi
      if out="$(invoke_codex "$mode" "$prompt" "$root" "$log" "$codex_model" "$codex_effort" "$codex_timeout" "$codex_cmd")"; then rc=0; else rc=$?; fi
    else
      vendor="claude"
      local cargs
      cargs=(-p --max-turns "$max_turns")
      # Guard the extra-args array for the unset/empty case under set -u (bash 3.2: ${arr+x} tests arr[0]).
      if [ -n "${INVOKE_PHASE_CLAUDE_ARGS+x}" ]; then cargs+=("${INVOKE_PHASE_CLAUDE_ARGS[@]}"); fi
      [ -n "$cand" ] && cargs+=(--model "$cand")
      # Accepted capture idiom (parity with periodic_review): buffered; pipefail surfaces claude's rc.
      if out="$(printf '%s' "$prompt" | "$claude_cmd" "${cargs[@]}" 2>&1 | tee "$log")"; then rc=0; else rc=$?; fi
    fi
    if [ "$rc" -eq 0 ]; then
      # SUCCESS: return immediately — never re-examine a success for usage markers (ratchet).
      INVOKE_PHASE_PATH="$vendor"; INVOKE_PHASE_USED_FALLBACK="$is_fallback"; INVOKE_PHASE_REASON=""
      printf '%s' "$out"; return 0
    fi
    last_out="$out"
    if usage_limit_error "$out"; then idx=$((idx+1)); continue; fi   # (b) usage-limit failure -> advance
    # Generic (non-usage) failure: stop here, DON'T advance to the fallback.
    INVOKE_PHASE_PATH="$vendor"; INVOKE_PHASE_USED_FALLBACK="$is_fallback"; INVOKE_PHASE_REASON="invoke-failed"
    printf '%s' "$out"; return 1
  done
  # Every candidate was unavailable or usage-limited: fail closed.
  INVOKE_PHASE_PATH=""
  if [ "$n" -gt 1 ]; then INVOKE_PHASE_USED_FALLBACK=1; else INVOKE_PHASE_USED_FALLBACK=0; fi
  INVOKE_PHASE_REASON="exhausted"
  printf '%s' "$last_out"; return 1
}
