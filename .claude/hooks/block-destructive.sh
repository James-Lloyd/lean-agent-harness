#!/usr/bin/env bash
# PreToolUse(Bash) hook — block obviously destructive / exfiltrating commands (mirror of .ps1).
# Exit 2 + stderr => Claude Code blocks the call and feeds the reason back. Exit 0 => allow.
#
# IMPORTANT: this is DEFENSE-IN-DEPTH, not a sandbox. A determined or careless agent can still find a
# phrasing this denylist misses. For unattended/auto runs, run inside an OS/container sandbox (no host
# FS, no outbound network, ephemeral) — do not rely on this hook alone. The real safety net is the gate
# + auto-rollback + (in supervised mode) the permission prompts.
payload="$(cat)"
# Extract the command if jq is present; otherwise DEGRADE to scanning the raw payload (so we still catch
# the patterns rather than silently allowing everything). If jq is present but yields nothing (malformed
# / unexpected shape), fall back to scanning the raw payload too — fail toward scanning, not open.
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  [ -z "$cmd" ] && cmd="$payload"
else
  cmd="$payload"
fi
[ -z "$cmd" ] && exit 0

# Normalize line-continuations (`\<newline>`) to a space so a multi-line command can't slip the patterns.
cmd="$(printf '%s' "$cmd" | sed -E ':a;N;$!ba;s/\\\n/ /g')"

deny() {  # $1 = why
  echo "BLOCKED by harness guardrail: $1." >&2
  echo "Command: ${cmd:0:200}" >&2
  echo "If genuinely intended, ask the human to run it or adjust .claude/hooks/block-destructive.sh." >&2
  exit 2
}

# Spec-lock on the shell surface: during a locked loop run the Edit/Write protect-specs hook is
# bypassable via a shell redirect/move/delete, so block shell-mediated writes to specs/ here too.
if [ -n "${HARNESS_LOCK_SPECS:-}" ]; then
  if printf '%s' "$cmd" | grep -iEq '(>>?|\b(rm|mv|cp|sed|tee|truncate|dd|install|ln)\b)[^|]*[[:space:]"'"'"'=/]specs/'; then
    deny "writing to specs/ while the loop holds the spec-lock (specs are the immutable contract)"
  fi
fi

# Case-insensitive (grep -iE) so lowercase SQL etc. is caught. "regex@@why" pairs — @@ delimiter so the
# alternation pipes inside the regexes aren't mistaken for the separator.
declare -a pats=(
  '\brm\b[^|]*([[:space:]]-[a-z]*r[a-z]*f|[[:space:]]-[a-z]*f[a-z]*r|[[:space:]]-r[[:space:]]+-f|[[:space:]]-f[[:space:]]+-r|[[:space:]]--recursive|[[:space:]]--force)@@recursive force-delete'
  '\bfind\b.*(-delete|-exec[[:space:]]+rm)@@mass delete via find'
  '\b(shred|truncate[[:space:]]+-s[[:space:]]*0)\b@@file shredding/truncation'
  '\bdd\b[^|]*[[:space:]]of=@@raw disk write via dd'
  '\bmkfs@@filesystem format'
  'git[[:space:]]+push[[:space:]].*(-f([[:space:]]|$)|--force([[:space:]]|$|[^-])|[[:space:]]\+[^[:space:]]+:)@@force-push (use --force-with-lease)'
  'git[[:space:]]+reset[[:space:]]+--hard@@discarding work via reset --hard'
  'git[[:space:]]+clean[[:space:]]+-[a-z]*f@@git clean force'
  'git[[:space:]]+checkout[[:space:]]+--[[:space:]]+\.@@discarding all changes'
  '(DROP|TRUNCATE)[[:space:]]+(TABLE|DATABASE|SCHEMA)@@destructive SQL'
  '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|python[0-9.]*|perl|node|pwsh|powershell)@@piping a remote script into a shell'
  '(curl|wget)[^\n]*(-d|--data|--data-binary|-T|--upload-file)[^\n]*(\.env|secret|credential|id_rsa|id_ed25519|\.pem|\.key|token)@@exfiltrating secrets over the network'
  '(cat|less|more|head|tail|sort|grep|xxd|od|base64|strings|gc|get-content|type)[[:space:]][^|]*(\.env|credentials|id_rsa|id_ed25519|\.pem|\.key|\.pfx|\.p12|\.npmrc|\.pgpass)@@reading secrets/credentials'
  'chmod[[:space:]]+(-R[[:space:]]+)?(0?[0-7]?7{3}|a?\+?rwx)@@over-permissive chmod'
  ':[[:space:]]*\([[:space:]]*\)[[:space:]]*\{.*\|.*&@@fork bomb'
)

for entry in "${pats[@]}"; do
  rx="${entry%%@@*}"; why="${entry##*@@}"
  if printf '%s' "$cmd" | grep -iEq "$rx"; then deny "$why"; fi
done
exit 0
