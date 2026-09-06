#!/usr/bin/env bash
# C3/C4 without any machine-wide write: supply hooks INLINE via -c, which V5 recorded as one of the
# two paths that fire headlessly. Records the PreToolUse payload so we can read tool_name (C4).
set -u
P="$1"
S="$(mktemp -d)"
REC="$S/record.mjs"
OUT="$S/payloads.jsonl"

cat > "$REC" <<'JS'
import fs from 'node:fs';
let d=''; process.stdin.on('data',c=>d+=c);
process.stdin.on('end',()=>{
  fs.appendFileSync(process.env.REC_OUT, d.replace(/\s+$/,'') + '\n');
  process.stdout.write('{}');
  process.exit(0);
});
JS

# forward slashes for TOML, and escape for the -c value
recp="$(cygpath -m "$REC")"
cmd="node \\\"$recp\\\""

echo "recording hook: $recp"
echo

run() {  # $1 = label, $2 = the -c hooks value
  : > "$OUT"
  local out
  out="$( (cd "$P" && REC_OUT="$OUT" codex exec --sandbox read-only \
            -c "$2" \
            "Run the shell command: echo probe-marker . Then reply DONE." 2>&1 </dev/null) )"
  local n hooklines
  n="$( [ -s "$OUT" ] && grep -c '' "$OUT" || echo 0)"
  hooklines="$(printf '%s' "$out" | grep -cE '^hook:')"
  printf '  %-30s payloads=%-3s codex-hook-lines=%s\n' "$1" "$n" "$hooklines"
  if [ "$n" != 0 ]; then
    echo "    tool_name / event seen:"
    node -e '
      const fs=require("fs");
      for (const l of fs.readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean)) {
        try { const j=JSON.parse(l);
          console.log("      event=" + (j.hook_event_name||"?") + "  tool_name=" + JSON.stringify(j.tool_name));
        } catch { console.log("      <unparseable payload>"); }
      }' "$OUT"
  fi
}

# Both rows below run WITHOUT the bypass flag (the label used to say "+bypass" on a command that did
# not pass it -- it misdescribed itself on a re-run). The flag is added in the separate run further
# down, which is the only one that fires.
run "PreToolUse inline (no flag)"        "hooks.PreToolUse=[{matcher=\"*\",hooks=[{type=\"command\",command=\"$cmd\",timeout=30}]}]"
run "PreToolUse inline (no flag, again)" "hooks.PreToolUse=[{matcher=\"*\",hooks=[{type=\"command\",command=\"$cmd\",timeout=30}]}]"

: > "$OUT"
out="$( (cd "$P" && REC_OUT="$OUT" codex exec --sandbox read-only --dangerously-bypass-hook-trust \
        -c "hooks.PreToolUse=[{matcher=\"*\",hooks=[{type=\"command\",command=\"$cmd\",timeout=30}]}]" \
        "Run the shell command: echo probe-marker . Then reply DONE." 2>&1 </dev/null) )"
n="$( [ -s "$OUT" ] && grep -c '' "$OUT" || echo 0)"
printf '  %-30s payloads=%s  codex-hook-lines=%s\n' "with --dangerously-bypass" "$n" "$(printf '%s' "$out" | grep -cE '^hook:')"
if [ "$n" != 0 ]; then
  node -e '
    const fs=require("fs");
    for (const l of fs.readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean)) {
      try { const j=JSON.parse(l);
        console.log("      event=" + (j.hook_event_name||"?") + "  tool_name=" + JSON.stringify(j.tool_name) +
                    "  keys=" + Object.keys(j).join(","));
      } catch { console.log("      <unparseable>"); }
    }' "$OUT"
fi
echo
echo "payload file: $OUT"
