#!/usr/bin/env bash
# PreToolUse(Bash) hook — block destructive/exfiltrating commands (bash mirror of block-destructive.ps1).
# Exit 2 + stderr => Claude Code blocks the call and feeds the reason back. Exit 0 => allow.
payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0

declare -a pats=(
  'rm[[:space:]]+-rf?[[:space:]]+(/|~|\*|\.[[:space:]]*$)|recursive force-delete of a broad path'
  'git[[:space:]]+push[[:space:]].*--force([^-]|$)|force-push (use --force-with-lease)'
  'git[[:space:]]+reset[[:space:]]+--hard[[:space:]]+HEAD~|discarding committed work'
  '(DROP|TRUNCATE)[[:space:]]+(TABLE|DATABASE|SCHEMA)|destructive SQL'
  'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh)|piping a remote script into a shell'
  '(cat|less|head).*(\.env|credentials|id_rsa|\.pem)|reading secrets/credentials'
  'chmod[[:space:]]+-R[[:space:]]+777|world-writable recursive chmod'
  ':[[:space:]]*\([[:space:]]*\)[[:space:]]*\{.*\|.*&[[:space:]]*\}|fork bomb'
)

for entry in "${pats[@]}"; do
  rx="${entry%%|*}"; why="${entry#*|}"
  if printf '%s' "$cmd" | grep -Eq "$rx"; then
    echo "BLOCKED by harness guardrail: $why." >&2
    echo "Command: $cmd" >&2
    echo "If genuinely intended, ask the human to run it or adjust .claude/hooks/block-destructive.sh." >&2
    exit 2
  fi
done
exit 0
