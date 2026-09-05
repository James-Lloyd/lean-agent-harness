#!/usr/bin/env bash
# Does ANY hook fire under `codex exec` 0.144.3? Three sources, tiny prompt each (~30 s):
#  r1  hooks supplied inline via -c (no file discovery involved), node recorder
#  r2  hooks in ~/.codex/hooks.json (user level; created for the test, removed after), node recorder
#  r3  hooks inline via -c, command = cmd.exe echo (spawn test without node)
set -u
W="<repo>"
S="<scratchpad>"
REC="node \"$S/record-hook.mjs\""
PROMPT='Run exactly one shell command: echo hello-from-probe . Then reply with the single word DONE.'
common=(--sandbox read-only --ask-for-approval never -c 'features.hooks=true' -c 'model_reasoning_effort="low"' --dangerously-bypass-hook-trust)

run() {  # $1 name, rest = extra codex args (before exec)
  local name="$1"; shift
  printf '%s' "$PROMPT" | codex "${common[@]}" "$@" exec - --cd "$W" --skip-git-repo-check --output-last-message "$S/probe-cli-$name.txt" > "$S/probe-cli-$name.log" 2>&1
  echo "--- $name: rc=$?"
  grep -n -i "hook\|error\|warn" "$S/probe-cli-$name.log" | grep -v "bypass-hook-trust\|models cache" | head -8 | cut -c1-220
}

OUT1="$S/hook-payloads-r1.jsonl"; : > "$OUT1"
run r1-inline-node -c "hooks.SessionStart=[{hooks=[{type=\"command\",command=\"$REC SessionStart $OUT1\",timeout=30}]}]" -c "hooks.PreToolUse=[{hooks=[{type=\"command\",command=\"$REC PreToolUse $OUT1\",timeout=30}]}]"
echo "r1 events=$(wc -l < "$OUT1")"; jq -c '{label, event:(.payload.hook_event_name // null), tool_name:(.payload.tool_name // null)}' "$OUT1" 2>/dev/null | head -5

OUT2="$S/hook-payloads-r2.jsonl"; : > "$OUT2"
UH="$HOME/.codex/hooks.json"
if [ -f "$UH" ]; then echo "user hooks.json already exists - skipping r2"; else
  jq -n --arg rec "$REC" --arg out "$OUT2" '{hooks:{SessionStart:[{hooks:[{type:"command",command:($rec+" SessionStart \""+$out+"\""),timeout:30}]}],PreToolUse:[{hooks:[{type:"command",command:($rec+" PreToolUse \""+$out+"\""),timeout:30}]}]}}' > "$UH"
  run r2-userfile-node
  rm -f "$UH"; echo "user hooks.json removed: $([ -f "$UH" ] && echo NO || echo yes)"
  echo "r2 events=$(wc -l < "$OUT2")"; jq -c '{label, event:(.payload.hook_event_name // null), tool_name:(.payload.tool_name // null)}' "$OUT2" 2>/dev/null | head -5
fi

OUT3="$S/hook-payloads-r3.txt"; : > "$OUT3"
W3="$(cygpath -w "$OUT3" | sed 's/\\/\\\\/g')"
run r3-inline-cmd -c "hooks.SessionStart=[{hooks=[{type=\"command\",command=\"cmd /c echo SessionStart-fired>>\\\"$W3\\\"\",timeout=30}]}]"
echo "r3 file:"; cat "$OUT3"

echo "=== transcript of r1 (head) ==="; sed -n '1,14p' "$S/probe-cli-r1-inline-node.log" | cut -c1-200
