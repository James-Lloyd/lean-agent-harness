#!/usr/bin/env bash
# C3: does exit 2 block a Codex tool call on 0.153.4, or only the JSON permissionDecision:"deny"?
#
# Isolating the DENIAL MECHANISM from destructiveness: the probe command is a harmless `echo` whose
# TEXT matches block-destructive's `(DROP|TRUNCATE)\s+(TABLE|DATABASE|SCHEMA)` pattern. It runs fine
# under powershell and Codex's own policy has no reason to reject it, so the control can discriminate.
# Verdict is "did the command run" (its output appears), never the hook's exit code.
set -u
P="$1"
S="$(mktemp -d)"
RUNMJS="$(cygpath -m "$P/plugin/hooks/run.mjs")"
MARKER='DROP TABLE probe_marker_42'

cat > "$S/exit2.mjs" <<'JS'
let d=''; process.stdin.on('data',c=>d+=c);
process.stdin.on('end',()=>{ process.stderr.write("DENIED by probe hook\n"); process.exit(2); });
JS
EXIT2="$(cygpath -m "$S/exit2.mjs")"

cat > "$S/jsondeny.mjs" <<'JS'
let d=''; process.stdin.on('data',c=>d+=c);
process.stdin.on('end',()=>{
  process.stdout.write(JSON.stringify({hookSpecificOutput:{hookEventName:"PreToolUse",
    permissionDecision:"deny", permissionDecisionReason:"probe: denied by JSON decision"}}));
  process.exit(0);
});
JS
JSONDENY="$(cygpath -m "$S/jsondeny.mjs")"

PROMPT="Run exactly this shell command and report its output verbatim: echo \"$MARKER\""

go() {  # $1 label ; rest = extra codex args
  local label="$1"; shift
  local out ran
  out="$( (cd "$P" && codex exec --sandbox read-only --dangerously-bypass-hook-trust "$@" \
           "$PROMPT" 2>&1 </dev/null) )"
  # the command RAN if its output line appears in an exec result block
  if printf '%s' "$out" | grep -q "probe_marker_42"; then
    # distinguish "echoed by the model" from "actually executed": look for an exec result
    ran="$(printf '%s' "$out" | grep -cE 'succeeded in|exited [0-9]+ in')"
  else
    ran=0
  fi
  printf '  %-34s exec-results=%-3s  codex-hook-lines: %s\n' "$label" "$ran" \
    "$(printf '%s' "$out" | grep -E '^hook:' | tr '\n' ' ' | cut -c1-90)"
}

echo "probe command: echo \"$MARKER\"   (harmless; matches the destructive-SQL pattern)"
echo "  exec-results>0 = the tool call RAN (not blocked)"
echo
go "CONTROL: no hook"
go "hook exits 2 + stderr"              -c "hooks.PreToolUse=[{matcher=\"Bash\",hooks=[{type=\"command\",command=\"node \\\"$EXIT2\\\"\",timeout=30}]}]"
go "hook returns JSON deny"             -c "hooks.PreToolUse=[{matcher=\"Bash\",hooks=[{type=\"command\",command=\"node \\\"$JSONDENY\\\"\",timeout=30}]}]"
go "run.mjs --codex block-destructive"  -c "hooks.PreToolUse=[{matcher=\"Bash\",hooks=[{type=\"command\",command=\"node \\\"$RUNMJS\\\" --codex block-destructive\",timeout=30}]}]"
