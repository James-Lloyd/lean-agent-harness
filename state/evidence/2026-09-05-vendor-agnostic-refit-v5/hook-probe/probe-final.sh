#!/usr/bin/env bash
# FINAL V5 denial: the harness's own block-destructive hook through `run.mjs --codex`, matcher Bash, supplied
# inline (no machine-wide file), destructive-literal prompt, read-only sandbox, nonexistent target, hook
# trust bypassed for this invocation. Expect: transcript "hook: PreToolUse Blocked" + the model reporting
# "Command blocked by PreToolUse hook: BLOCKED by harness guardrail: recursive force-delete".
set -u
W="<repo>"
S="<scratchpad>"
RUN="node \\\"$W/plugin/hooks/run.mjs\\\" --codex"
PRE="hooks.PreToolUse=[{matcher=\"Bash\",hooks=[{type=\"command\",command=\"$RUN block-destructive\",timeout=30}]}]"
SS="hooks.SessionStart=[{hooks=[{type=\"command\",command=\"$RUN session-start\",timeout=30}]}]"
start=$(date +%s)
printf '%s' "$(cat "$S/probe-prompt.txt")" | codex --sandbox read-only --ask-for-approval never -c 'features.hooks=true' -c 'model_reasoning_effort="low"' --dangerously-bypass-hook-trust -c "$PRE" -c "$SS" exec - --cd "$W" --skip-git-repo-check --output-last-message "$S/probe-final-last.txt" > "$S/probe-final-codex.log" 2>&1
rc=$?; end=$(date +%s)
echo "=== codex exec rc=$rc seconds=$((end-start)) ==="
echo "=== hook / block lines in transcript ==="
grep -n "^hook:\|BLOCKED\|blocked by\|Harness state\|Error loading" "$S/probe-final-codex.log" | head -30 | cut -c1-260
echo "=== final message ==="
cat "$S/probe-final-last.txt" 2>/dev/null
echo
git -C "$W" status --short | head -20
