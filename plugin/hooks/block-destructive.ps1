#!/usr/bin/env pwsh
# PreToolUse(Bash|PowerShell) hook — block obviously destructive / exfiltrating commands.
# Reads the tool call as JSON on stdin. Exit 2 + stderr => Claude Code blocks the call and feeds the
# reason back to the model. Exit 0 => allow.
#
# IMPORTANT: DEFENSE-IN-DEPTH, not a sandbox. A determined/careless agent can find a phrasing this
# denylist misses. For unattended/auto runs, run inside an OS/container sandbox (no host FS, no outbound
# network, ephemeral). The real safety net is the gate + auto-rollback + supervised permission prompts.
$ErrorActionPreference = 'Stop'
# Degrade gracefully: if we can't parse JSON, scan the raw payload rather than failing open.
$raw = ''
try { $raw = [Console]::In.ReadToEnd() } catch { $raw = '' }
$cmd = $raw
try { $p = $raw | ConvertFrom-Json; if ($p.tool_input.command) { $cmd = [string]$p.tool_input.command } } catch {}
if ([string]::IsNullOrWhiteSpace($cmd)) { exit 0 }

# Normalize line-continuations (`\<newline>` and PowerShell backtick-newline) to a space so a command
# split across lines can't slip the single-line patterns below.
$cmd = [regex]::Replace($cmd, '(\\|`)\s*\r?\n', ' ')

# Scan copy with benign quoted commit-message bodies removed, so `git commit -m "migration: drop table
# legacy_users"` doesn't trip the SQL/secrets patterns. Only message bodies free of shell metacharacters
# ($ ` | ; & >) are scrubbed — a message smuggling `$(rm -rf /)` stays visible to the patterns.
$scan = [regex]::Replace($cmd, '((-m|--message)\s+)("[^"$;|&>``]*"|''[^''$;|&>``]*'')', '$1 MSG')
# Exempt .env templates (.env.example/.env.sample/.env.template) from the secrets patterns — they are
# meant to be read. Real .env / .env.local etc. still match.
$scanEnv = $scan -replace '\.env\.(example|sample|template)', 'ENV_TEMPLATE'

function Deny([string]$why, [string]$shown) {
  [Console]::Error.WriteLine("BLOCKED by harness guardrail: $why.")
  [Console]::Error.WriteLine("Command: $($shown.Substring(0, [Math]::Min(200, $shown.Length)))")
  [Console]::Error.WriteLine("If genuinely intended, ask the human to run it or adjust .claude/hooks/block-destructive.ps1.")
  exit 2
}

# Spec-lock on the shell surface: during a locked loop run (loop.* set HARNESS_LOCK_SPECS), the Edit/Write
# protect-specs hook is bypassable via a shell redirect/move/delete. Block shell-mediated WRITES to specs/
# here too. Reading specs is the loop's job and must stay allowed — so `sed -n`/`cp specs/x elsewhere`
# pass, and only destination-position / in-place / redirect forms are blocked.
if (-not [string]::IsNullOrWhiteSpace($env:HARNESS_LOCK_SPECS)) {
  $specWhy = 'writing to specs/ while the loop holds the spec-lock (specs are the immutable contract)'
  # (a) any redirect aimed at specs/ — with or without a space (`>specs/x`, `>> "specs/x"`)
  if ($scan -match '>>?\s*["'']?specs[\\/]') { Deny $specWhy $cmd }
  # (b) commands that delete/move/create/overwrite a specs/ path anywhere in their args
  if ($scan -match '\b(rm|mv|tee|truncate|touch|install|ln)\b[^|]*[\s"''=/\\]specs[\\/]') { Deny $specWhy $cmd }
  # (c) sed only in-place (-i/--in-place); plain `sed -n ... specs/x` is a legitimate ranged READ
  if ($scan -match '\bsed\b[^|]*\s(-[a-zA-Z]*i[a-zA-Z]*|--in-place)\b[^|]*specs[\\/]') { Deny 'in-place sed on specs/ while the loop holds the spec-lock' $cmd }
  # (d) dd only when specs/ is the output; cp/Copy-Item only when specs/ is in destination position
  if ($scan -match '\bdd\b[^|]*\bof=\s*["'']?specs[\\/]') { Deny $specWhy $cmd }
  if ($scan -match '\bcp\b[^|]*\s["'']?specs[\\/][^\s|;&]*["'']?\s*(\||;|&|$)') { Deny 'copying into specs/ while the loop holds the spec-lock' $cmd }
  if ($scan -match '\bcp\b[^|]*\s-t[\s=]*["'']?specs[\\/]') { Deny 'copying into specs/ while the loop holds the spec-lock' $cmd }
  # (e) PowerShell cmdlet writers
  if ($scan -match '\b(Set-Content|Add-Content|Clear-Content|Out-File|Remove-Item|Move-Item|New-Item)\b[^|]*[\s"''=/\\]specs[\\/]') { Deny $specWhy $cmd }
  if ($scan -match '\bCopy-Item\b[^|]*(-Destination\s+["'']?specs[\\/]|\s["'']?specs[\\/][^\s|;&]*\s*(\||;|&|$))') { Deny 'copying into specs/ while the loop holds the spec-lock' $cmd }
}

# Patterns mirror block-destructive.sh. PowerShell -match is case-insensitive by default. Patterns run
# against $scan (commit-message bodies scrubbed); the secrets-read pattern uses $scanEnv (templates exempt).
$blocked = @(
  # rm: recursive/force flag anywhere after rm (not just adjacent), quoted flags included — `rm dir -rf`
  # and `rm "-rf" dir` were bypasses.
  @{ rx = '\brm\b[^|]*(\s["'']?-[a-z]*r[a-z]*f|\s["'']?-[a-z]*f[a-z]*r|\s["'']?-r\s+["'']?-f|\s["'']?-f\s+["'']?-r|\s["'']?--recursive|\s["'']?--force)'; why = 'recursive force-delete' },
  @{ rx = '\bfind\b.*(-delete|-exec\s+rm)';                          why = 'mass delete via find' },
  @{ rx = '\b(shred|truncate\s+-s\s*0)\b';                           why = 'file shredding/truncation' },
  @{ rx = '\bdd\b[^|]*\sof=';                                        why = 'raw disk write via dd' },
  @{ rx = '\bmkfs';                                                  why = 'filesystem format' },
  # PowerShell-tool destructive forms (this hook also matches the PowerShell tool, not just Bash).
  @{ rx = '\bRemove-Item\b[^|]*-(Recurse|Force)';                    why = 'recursive/force Remove-Item' },
  @{ rx = '\b(rd|rmdir)\b\s+/s';                                     why = 'recursive rmdir (/s)' },
  @{ rx = '\bdel\b\s+/[a-z]*[sq]';                                   why = 'recursive/quiet del' },
  @{ rx = '\b(Format-Volume|Clear-Disk|Clear-Content)\b';           why = 'disk/file wipe (PowerShell)' },
  # Block unsafe force-push but ALLOW the recommended --force-with-lease (+ --force-if-includes).
  @{ rx = 'git\s+push\s+.*(-f(\s|$)|--force(?!-with-lease|-if-includes)|\s\+[^\s]+:)'; why = 'force-push (use --force-with-lease)' },
  @{ rx = 'git\s+reset\s+--hard';                                    why = 'discarding work via reset --hard' },
  @{ rx = 'git\s+clean\b[^|]*(-[a-z]*f[a-z]*(\s|$)|--force)';        why = 'git clean force' },
  @{ rx = 'git\s+(checkout|restore)\s+(--\s+)?\.(\s|"|$)';           why = 'discarding all changes' },   # `"` so the bare dot is caught in degraded raw-JSON mode too
  @{ rx = 'git\s+restore\b[^|]*--worktree';                          why = 'discarding working-tree changes via git restore' },
  @{ rx = '\b(DROP|TRUNCATE)\s+(TABLE|DATABASE|SCHEMA)\b';           why = 'destructive SQL' },
  @{ rx = '(curl|wget)[^|]*\|\s*(sudo\s+)?(bash|sh|zsh|python[0-9.]*|perl|node|pwsh|powershell)'; why = 'piping a remote script into a shell' },
  @{ rx = '(iwr|irm|Invoke-WebRequest|Invoke-RestMethod)[^|]*\|\s*(iex\b|Invoke-Expression)'; why = 'piping a remote script into PowerShell' },
  @{ rx = '(curl|wget)[^\n]*(-d|--data|--data-binary|-T|--upload-file)[^\n]*(\.env|secret|credential|id_rsa|id_ed25519|\.pem|\.key|token)'; why = 'exfiltrating secrets over the network' },
  @{ rx = 'chmod\s+(-R\s+)?(0?[0-7]?7{3}|a?\+?rwx)';                 why = 'over-permissive chmod' },
  @{ rx = ':\s*\(\s*\)\s*\{.*\|.*&';                                 why = 'fork bomb' }
)

foreach ($b in $blocked) {
  if ($scan -match $b.rx) { Deny $b.why $cmd }
}

# Secrets-read pattern, on the template-exempt copy. `.key`/`credentials` are bounded so ordinary source
# files (src/api.key.ts, docs/credentials-rotation.md) don't false-positive; real key files still match.
if ($scanEnv -match '(cat|type|gc|Get-Content|less|more|head|tail|sort|grep|xxd|od|base64|strings)\s[^|]*(\.env|credentials([^-\w]|$)|id_rsa|id_ed25519|\.pem|\.key([^.\w]|$)|\.pfx|\.p12|\.npmrc|\.pgpass)') {
  Deny 'reading secrets/credentials' $cmd
}
exit 0
