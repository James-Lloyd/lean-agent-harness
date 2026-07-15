#!/usr/bin/env bash
# invoke-codex.sh — cross-vendor codex invocation for any routed phase (bash mirror of invoke-codex.ps1).
# When a phase routes to "codex", the harness runs it through the OpenAI Codex CLI (different training
# lineage — the Amp-Oracle pattern). Generalized in S2 from the review-only path: a <mode> arg selects
# the sandbox, so the same lib serves READ-ONLY judge phases (review/evaluate) and WORKSPACE-WRITE
# writer phases (implement/plan/docs).
#
# Safety properties:
#  - SANDBOX per mode: 'read-only' for judge phases (`--sandbox read-only`; the caller also hard-resets
#    the tree — a judge must never mutate what it judges), 'workspace-write' for writer phases (the
#    mutated tree flows through the gate + autoRollbackOnRed, which are the safety net — a write phase
#    is NOT belt-and-braces reset, that would discard the build).
#  - EXTERNAL WATCHDOG: codex exec has NO --max-turns/--timeout of its own; we wrap it in coreutils
#    `timeout` when available (exit 124 on expiry). Without `timeout` (stock macOS) the run is
#    unbounded — install coreutils, or the run relies on codex finishing on its own.
#  - OUTPUT from --output-last-message (final message text only), parsed by the caller's fail-closed
#    review_verdict. Exit codes are never trusted as verdicts.

# codex_available <auth> [cmd] — exit 0 if usable; on failure echoes the reason and exits 1.
# Auth 'chatgpt' probes `codex login status` (exit 0 = signed in; known false-negative with
# Azure/custom providers — point that phase at a claude model instead if you hit that).
# Auth 'api-key' requires CODEX_API_KEY. [cmd] is injectable for the self-tests.
codex_available() {
  local auth="${1:-chatgpt}" cmd="${2:-codex}"
  command -v "$cmd" >/dev/null 2>&1 || { echo "codex CLI not found"; return 1; }
  if [ "$auth" = "api-key" ]; then
    [ -n "${CODEX_API_KEY:-}" ] || { echo "CODEX_API_KEY not set"; return 1; }
    return 0
  fi
  "$cmd" login status >/dev/null 2>&1 || { echo "codex not signed in (run: codex login)"; return 1; }
}

# Pure arg-builder (mirror of Get-CodexArgs): one arg per line so a caller can read them back intact
# even when a value contains spaces. Mode selects --sandbox (read-only judge vs workspace-write writer).
codex_args() {  # $1 mode  $2 root  $3 lastmsg  $4 model  $5 effort
  local mode="$1" root="$2" lastmsg="$3" model="${4:-}" effort="${5:-}"
  printf '%s\n' --sandbox "$mode" --ask-for-approval never \
    exec - --cd "$root" --skip-git-repo-check --output-last-message "$lastmsg"
  if [ -n "$model" ]  && [ "$model" != "null" ];  then printf '%s\n' -m "$model"; fi
  if [ -n "$effort" ] && [ "$effort" != "null" ]; then printf '%s\n' -c "model_reasoning_effort=\"$effort\""; fi
}

# invoke_codex <mode> <prompt> <root> <log> <model> <effort> <timeout_s> [cmd] — echoes the
# final-message text on stdout; full transcript goes to <log>. Returns codex's exit code (124 =
# watchdog kill). model/effort may be "" or "null" (= codex defaults). [cmd] injectable for tests.
invoke_codex() {
  local mode="$1" prompt="$2" root="$3" log="$4" model="${5:-}" effort="${6:-}" tmo="${7:-900}" cmd="${8:-codex}"
  local lastmsg rc; lastmsg="$(mktemp)"
  local args=(); while IFS= read -r _a; do args+=("$_a"); done < <(codex_args "$mode" "$root" "$lastmsg" "$model" "$effort")
  if command -v timeout >/dev/null 2>&1; then
    printf '%s' "$prompt" | timeout "$tmo" "$cmd" "${args[@]}" > "$log" 2>&1; rc=$?
    [ "$rc" -eq 124 ] && printf '%s\n' "[codex timed out after ${tmo}s — watchdog kill, failing closed]" >> "$log"
  else
    printf '%s' "$prompt" | "$cmd" "${args[@]}" > "$log" 2>&1; rc=$?
  fi
  cat "$lastmsg" 2>/dev/null; rm -f "$lastmsg"; return "$rc"
}
