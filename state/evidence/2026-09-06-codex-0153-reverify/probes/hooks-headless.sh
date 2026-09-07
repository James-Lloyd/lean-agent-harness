#!/usr/bin/env bash
# C2: is the PROJECT .codex/hooks.json loaded under headless `codex exec` on 0.153.4?
# Run in the TRUSTED worktree (trust is prefix-based from c:\users\<you>\repos\<repo>), with and
# without --dangerously-bypass-hook-trust. Look for Codex's own `hook:` transcript lines AND for a
# side effect only our hook can produce (a marker file written by a recording hook).
set -u
P="$1"
MARK="$P/.codex/hook-fired.log"
rm -f "$MARK"

# A recording hook that ALWAYS allows, but leaves a trace. Replaces the generated commands so we are
# testing "does the project file load", not "does block-destructive work".
REC="$P/.codex/record-hook.mjs"
cat > "$REC" <<'JS'
import fs from 'node:fs';
let d = ''; process.stdin.on('data', c => d += c);
process.stdin.on('end', () => {
  let ev = 'unknown';
  try { ev = (JSON.parse(d).hook_event_name) || 'unknown'; } catch {}
  fs.appendFileSync(process.env.HOOK_MARK, `fired ${ev}\n`);
  process.stdout.write('{}');
  process.exit(0);
});
JS

BAK="$(mktemp)"; cp "$P/.codex/hooks.json" "$BAK"
trap 'cp "$BAK" "$P/.codex/hooks.json"; rm -f "$BAK" "$REC"' EXIT

node -e '
const fs=require("fs");
const p=process.argv[1], rec=process.argv[2], mark=process.argv[3];
const j=JSON.parse(fs.readFileSync(p,"utf8"));
const cmd=`node "${rec}"`;
for (const ev of Object.keys(j.hooks)) for (const g of j.hooks[ev]) for (const h of g.hooks) h.command=cmd;
fs.writeFileSync(p, JSON.stringify(j,null,2));
' "$P/.codex/hooks.json" "$REC" "$MARK"

probe() {  # $1 label, rest args
  local label="$1"; shift
  rm -f "$MARK"
  local out
  out="$( (cd "$P" && HOOK_MARK="$MARK" codex exec --sandbox read-only "$@" \
          "Run the shell command: echo hello-from-codex . Then reply DONE." 2>&1 </dev/null) )"
  local hooklines fired toolcalls
  hooklines="$(printf '%s' "$out" | grep -cE '^hook:')"
  fired="$( [ -f "$MARK" ] && tr '\n' ' ' < "$MARK" || echo '<none>')"
  # POSITIVE CONTROL, in the script rather than in prose: a zero above is only meaningful if the run
  # actually made a tool call. Without this column the probe emits a bare uncontrolled negative, and
  # "hooks did not fire" is indistinguishable from "nothing ever asked to run a command".
  toolcalls="$(printf '%s' "$out" | grep -cE 'succeeded in|exited [0-9]+ in')"
  printf '  %-34s codex `hook:` lines=%-3s tool-calls=%-3s our hook fired: %s\n' \
    "$label" "$hooklines" "$toolcalls" "$fired"
  [ "$toolcalls" = 0 ] && printf '    !! NO TOOL CALL — this row proves nothing about hooks\n'
  return 0
}

echo "project (trusted): $P"
echo "hooks.json commands rewritten to a recording hook that always allows"
echo
probe "headless, no flag"
probe "headless, +bypass-hook-trust" --dangerously-bypass-hook-trust
