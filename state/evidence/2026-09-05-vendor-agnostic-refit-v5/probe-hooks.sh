#!/usr/bin/env bash
# V5 step (2): observe a REAL Codex hook denial + pin the payload field names / shell tool name.
# Adds a payload-recorder hook beside the generated ones (in the gitignored, regenerable .codex/),
# runs one headless codex exec with hook trust bypassed for THIS invocation only, then regenerates.
set -u
W="<repo>"
S="<scratchpad>"
export HARNESS_ENGINE="$W/plugin/engine"
REC="node \"$S/record-hook.mjs\""
OUT="$S/hook-payloads.jsonl"
: > "$OUT"

# 1. add the recorder (matcher * on PreToolUse / PostToolUse / SessionStart / UserPromptSubmit / Stop)
cp "$W/.codex/hooks.json" "$S/hooks.generated.json"
jq --arg rec "$REC" --arg out "$OUT" '
  def r($l): {matcher:"*", hooks:[{type:"command", command:($rec+" "+$l+" \""+$out+"\""), timeout:30}]};
  .hooks.PreToolUse  += [r("PreToolUse")]  |
  .hooks.PostToolUse += [r("PostToolUse")] |
  .hooks.SessionStart += [r("SessionStart")] |
  .hooks.UserPromptSubmit = [r("UserPromptSubmit")] |
  .hooks.Stop = [r("Stop")]
' "$S/hooks.generated.json" > "$S/hooks.probe.json"
cp "$S/hooks.probe.json" "$W/.codex/hooks.json"
echo "=== probe hooks.json events ==="; jq -c '.hooks | to_entries[] | {event:.key, matchers:[.value[].matcher]}' "$W/.codex/hooks.json"

# 2. one headless run, hooks explicitly enabled + trusted for this invocation only, read-only sandbox
start=$(date +%s)
printf '%s' "$(cat "$S/probe-prompt.txt")" | codex --sandbox read-only --ask-for-approval never -c 'features.hooks=true' -c 'model_reasoning_effort="low"' --dangerously-bypass-hook-trust exec - --cd "$W" --skip-git-repo-check --output-last-message "$S/probe-last.txt" > "$S/probe-codex.log" 2>&1
rc=$?
end=$(date +%s)
echo "=== codex exec rc=$rc seconds=$((end-start)) ==="

# 3. what did the hooks see?
echo "=== recorded hook events (label / tool_name / payload keys) ==="
jq -c '{label, tool_name:(.payload.tool_name // null), event:(.payload.hook_event_name // null), keys:((.payload|objects|keys) // (.payload|type))}' "$OUT" 2>/dev/null
echo "=== full PreToolUse payloads ==="
jq -c 'select(.label=="PreToolUse") | .payload' "$OUT" 2>/dev/null
echo "=== BLOCKED / hook lines in codex transcript ==="
grep -n -i "blocked\|hook\|session-start\|Harness state\|denied\|exit code 2\|rc=2" "$S/probe-codex.log" | head -40
echo "=== codex final message ==="
cat "$S/probe-last.txt"
echo
echo "=== tail of transcript ==="
tail -40 "$S/probe-codex.log"

# 4. restore the generated hooks.json (recorder removed) and confirm fresh
bash "$W/harness/codex-setup.sh" >/dev/null 2>&1
bash "$W/harness/codex-setup.sh" --check
echo "=== git status ==="; git -C "$W" status --short
