#!/usr/bin/env bash
# Does the JSON permissionDecision=deny output actually block a tool call on Codex 0.144.3? Inline hook, matcher Bash.
set -u
W="<repo>"
S="<scratchpad>"
OUT="$S/deny-hook-seen.jsonl"; : > "$OUT"
PRE="hooks.PreToolUse=[{matcher=\"Bash\",hooks=[{type=\"command\",command=\"node \\\"$S/deny-hook.mjs\\\" \\\"$OUT\\\"\",timeout=30}]}]"
start=$(date +%s)
printf '%s' "$(cat "$S/probe-prompt.txt")" | codex --sandbox read-only --ask-for-approval never -c 'features.hooks=true' -c 'model_reasoning_effort="low"' --dangerously-bypass-hook-trust -c "$PRE" exec - --cd "$W" --skip-git-repo-check --output-last-message "$S/probe-deny-last.txt" > "$S/probe-deny-codex.log" 2>&1
rc=$?; end=$(date +%s)
echo "=== codex exec rc=$rc seconds=$((end-start)) ==="
echo "=== hook saw ==="; cat "$OUT"
echo "=== hook / block lines ==="
grep -n "^hook:\|BLOCKED\|denied\|deny\|Error loading" "$S/probe-deny-codex.log" | head -20 | cut -c1-240
echo "=== final message ==="; cat "$S/probe-deny-last.txt" 2>/dev/null; echo
