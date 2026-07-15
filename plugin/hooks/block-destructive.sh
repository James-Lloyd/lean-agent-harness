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

# Normalize line-continuations (`\<newline>`, PowerShell backtick-newline, CRLF) to a space so a
# multi-line command can't slip the single-line patterns. Pure bash on purpose: the previous GNU-sed
# label idiom (':a;N;$!ba') errors out on BSD/macOS sed, which left cmd EMPTY and the whole hook
# fail-open on exactly the platform /harness-init swaps to the .sh hooks.
cmd="${cmd//$'\r'/}"
cmd="${cmd//\\$'\n'/ }"
cmd="${cmd//\`$'\n'/ }"

# Scan copy with benign quoted commit-message bodies removed, so `git commit -m "migration: drop table
# legacy_users"` doesn't trip the SQL/secrets patterns. Only message bodies free of shell metacharacters
# ($ ` | ; & >) are scrubbed — a message smuggling `$(rm -rf /)` stays visible to the patterns.
# Portable sed (plain s///, no labels); on any sed failure fall back to the unscrubbed command.
scan="$(printf '%s' "$cmd" | sed -E 's/(-m|--message)[[:space:]]+("[^"$;|&>`]*"|'\''[^'\''$;|&>`]*'\'')/\1 MSG/g' 2>/dev/null)" || scan="$cmd"
[ -n "$scan" ] || scan="$cmd"
# Exempt .env templates (.env.example/.env.sample/.env.template) from the secrets patterns — they are
# meant to be read. Real .env / .env.local etc. still match.
scan_env="${scan//.env.example/ENV_TEMPLATE}"
scan_env="${scan_env//.env.sample/ENV_TEMPLATE}"
scan_env="${scan_env//.env.template/ENV_TEMPLATE}"

deny() {  # $1 = why
  echo "BLOCKED by harness guardrail: $1." >&2
  echo "Command: ${cmd:0:200}" >&2
  echo "If genuinely intended, ask the human to run it or adjust .claude/hooks/block-destructive.sh." >&2
  exit 2
}

# Spec-lock on the shell surface: during a locked loop run the Edit/Write protect-specs hook is
# bypassable via a shell redirect/move/delete, so block shell-mediated WRITES to specs/ here too.
# Reading specs is the loop's job and must stay allowed — so `sed -n`/`cp specs/x elsewhere` pass, and
# only destination-position / in-place / redirect forms are blocked.
if [ -n "${HARNESS_LOCK_SPECS:-}" ]; then
  # (a) any redirect aimed at specs/ — with or without a space (`>specs/x`, `>> "specs/x"`)
  printf '%s' "$scan" | grep -iEq '>>?[[:space:]]*["'\'']?specs/' \
    && deny "writing to specs/ while the loop holds the spec-lock (specs are the immutable contract)"
  # (b) commands that delete/move/create/overwrite a specs/ path anywhere in their args
  printf '%s' "$scan" | grep -iEq '\b(rm|mv|tee|truncate|touch|install|ln)\b[^|]*[[:space:]"'\''=/]specs/' \
    && deny "writing to specs/ while the loop holds the spec-lock (specs are the immutable contract)"
  # (c) sed only in-place (-i/--in-place); plain `sed -n ... specs/x` is a legitimate ranged READ
  printf '%s' "$scan" | grep -iEq '\bsed\b[^|]*[[:space:]](-[a-zA-Z]*i[a-zA-Z]*|--in-place)\b[^|]*specs/' \
    && deny "in-place sed on specs/ while the loop holds the spec-lock"
  # (d) dd only when specs/ is the output; cp/Copy-Item only when specs/ is in destination position
  printf '%s' "$scan" | grep -iEq '\bdd\b[^|]*\bof=[[:space:]]*["'\'']?specs/' \
    && deny "writing to specs/ while the loop holds the spec-lock (specs are the immutable contract)"
  printf '%s' "$scan" | grep -iEq '\bcp\b[^|]*[[:space:]]["'\'']?specs/[^[:space:]|;&]*["'\'']?[[:space:]]*(\||;|&|$)' \
    && deny "copying into specs/ while the loop holds the spec-lock"
  printf '%s' "$scan" | grep -iEq '\bcp\b[^|]*[[:space:]]-t[[:space:]=]*["'\'']?specs/' \
    && deny "copying into specs/ while the loop holds the spec-lock"
  # (e) PowerShell cmdlet writers (the PowerShell tool can run on POSIX via pwsh)
  printf '%s' "$scan" | grep -iEq '\b(Set-Content|Add-Content|Clear-Content|Out-File|Remove-Item|Move-Item|New-Item)\b[^|]*[[:space:]"'\''=/]specs[/\\]' \
    && deny "writing to specs/ while the loop holds the spec-lock (specs are the immutable contract)"
  printf '%s' "$scan" | grep -iEq '\bCopy-Item\b[^|]*(-Destination[[:space:]]+["'\'']?specs[/\\]|[[:space:]]["'\'']?specs[/\\][^[:space:]|;&]*[[:space:]]*(\||;|&|$))' \
    && deny "copying into specs/ while the loop holds the spec-lock"
fi

# Case-insensitive (grep -iE) so lowercase SQL etc. is caught. "regex@@why" pairs — @@ delimiter so the
# alternation pipes inside the regexes aren't mistaken for the separator. Patterns run against $scan
# (commit-message bodies scrubbed); the secrets-read pattern runs against $scan_env (templates exempt).
declare -a pats=(
  '\brm\b[^|]*([[:space:]]["'\'']?-[a-z]*r[a-z]*f|[[:space:]]["'\'']?-[a-z]*f[a-z]*r|[[:space:]]["'\'']?-r[[:space:]]+["'\'']?-f|[[:space:]]["'\'']?-f[[:space:]]+["'\'']?-r|[[:space:]]["'\'']?--recursive|[[:space:]]["'\'']?--force)@@recursive force-delete'
  '\bfind\b.*(-delete|-exec[[:space:]]+rm)@@mass delete via find'
  '\b(shred|truncate[[:space:]]+-s[[:space:]]*0)\b@@file shredding/truncation'
  '\bdd\b[^|]*[[:space:]]of=@@raw disk write via dd'
  '\bmkfs@@filesystem format'
  'git[[:space:]]+push[[:space:]].*(-f([[:space:]]|$)|--force([[:space:]]|$|[^-])|[[:space:]]\+[^[:space:]]+:)@@force-push (use --force-with-lease)'
  'git[[:space:]]+reset[[:space:]]+--hard@@discarding work via reset --hard'
  'git[[:space:]]+clean\b[^|]*(-[a-z]*f[a-z]*([[:space:]]|$)|--force)@@git clean force'
  'git[[:space:]]+(checkout|restore)[[:space:]]+(--[[:space:]]+)?\.([[:space:]"]|$)@@discarding all changes'
  'git[[:space:]]+restore\b[^|]*--worktree@@discarding working-tree changes via git restore'
  '(DROP|TRUNCATE)[[:space:]]+(TABLE|DATABASE|SCHEMA)@@destructive SQL'
  '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|python[0-9.]*|perl|node|pwsh|powershell)@@piping a remote script into a shell'
  '(iwr|irm|invoke-webrequest|invoke-restmethod)[^|]*\|[[:space:]]*(iex([^a-zA-Z0-9_]|$)|invoke-expression)@@piping a remote script into PowerShell'
  '(curl|wget)[^\n]*(-d|--data|--data-binary|-T|--upload-file)[^\n]*(\.env|secret|credential|id_rsa|id_ed25519|\.pem|\.key|token)@@exfiltrating secrets over the network'
  'chmod[[:space:]]+(-R[[:space:]]+)?(0?[0-7]?7{3}|a?\+?rwx)@@over-permissive chmod'
  ':[[:space:]]*\([[:space:]]*\)[[:space:]]*\{.*\|.*&@@fork bomb'
)

for entry in "${pats[@]}"; do
  rx="${entry%%@@*}"; why="${entry##*@@}"
  if printf '%s' "$scan" | grep -iEq "$rx"; then deny "$why"; fi
done

# Secrets-read pattern, on the template-exempt copy. `.key`/`credentials` are bounded so ordinary source
# files (src/api.key.ts, docs/credentials-rotation.md) don't false-positive; real key files still match.
if printf '%s' "$scan_env" | grep -iEq '(cat|less|more|head|tail|sort|grep|xxd|od|base64|strings|gc|get-content|type)[[:space:]][^|]*(\.env|credentials([^-a-zA-Z0-9_]|$)|id_rsa|id_ed25519|\.pem|\.key([^.a-zA-Z0-9]|$)|\.pfx|\.p12|\.npmrc|\.pgpass)'; then
  deny "reading secrets/credentials"
fi
exit 0
