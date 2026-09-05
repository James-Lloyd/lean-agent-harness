#!/usr/bin/env bash
# Bisect why .codex/hooks.json produces no events under codex exec 0.144.3 (trusted project, hooks on,
# hook-trust bypassed). Three variants of a recorder-only hooks.json; tiny prompt; ~30 s each.
set -u
W="<repo>"
S="<scratchpad>"
REC="node \"$S/record-hook.mjs\""
cp "$W/.codex/hooks.json" "$S/hooks.generated.json"

run_variant() {  # $1 name  $2 jq-filter producing the hooks.json
  local name="$1" filter="$2"
  local out="$S/hook-payloads-$name.jsonl"
  : > "$out"
  jq -n --arg rec "$REC" --arg out "$out" "$filter" > "$W/.codex/hooks.json"
  echo "===== variant $name: hooks.json ====="; cat "$W/.codex/hooks.json"
  printf '%s' 'Run exactly one shell command: echo hello-from-probe . Then reply with the single word DONE.' | \
    codex --sandbox read-only --ask-for-approval never -c 'features.hooks=true' -c 'model_reasoning_effort="low"' --dangerously-bypass-hook-trust exec - --cd "$W" --skip-git-repo-check --output-last-message "$S/probe-min-$name.txt" > "$S/probe-min-$name.log" 2>&1
  echo "rc=$? events_recorded=$(wc -l < "$out")"
  jq -c '{label, event:(.payload.hook_event_name // null), tool_name:(.payload.tool_name // null), keys:((.payload|objects|keys) // (.payload|type))}' "$out" 2>/dev/null | head -8
  grep -n -i "hook\|warning\|error" "$S/probe-min-$name.log" | grep -v "bypass-hook-trust" | head -6 | cut -c1-200
}

# v1: recorder only, NO matcher key at all, no unknown top-level keys
run_variant v1-nomatcher '{hooks:{PreToolUse:[{hooks:[{type:"command",command:($rec+" PreToolUse \""+$out+"\""),timeout:30}]}],SessionStart:[{hooks:[{type:"command",command:($rec+" SessionStart \""+$out+"\""),timeout:30}]}],UserPromptSubmit:[{hooks:[{type:"command",command:($rec+" UserPromptSubmit \""+$out+"\""),timeout:30}]}]}}'
# v2: same, matcher "*" (what codex-setup emits)
run_variant v2-star '{hooks:{PreToolUse:[{matcher:"*",hooks:[{type:"command",command:($rec+" PreToolUse \""+$out+"\""),timeout:30}]}],SessionStart:[{matcher:"*",hooks:[{type:"command",command:($rec+" SessionStart \""+$out+"\""),timeout:30}]}]}}'
# v3: v1 plus the two unknown top-level keys codex-setup emits
run_variant v3-underscore '{_generated_by:"probe",_shell_matcher_note:"probe",hooks:{PreToolUse:[{hooks:[{type:"command",command:($rec+" PreToolUse \""+$out+"\""),timeout:30}]}],SessionStart:[{hooks:[{type:"command",command:($rec+" SessionStart \""+$out+"\""),timeout:30}]}]}}'

cp "$S/hooks.generated.json" "$W/.codex/hooks.json"
echo "===== restored generated hooks.json ====="
