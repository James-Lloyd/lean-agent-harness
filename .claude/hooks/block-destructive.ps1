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

function Deny([string]$why, [string]$shown) {
  [Console]::Error.WriteLine("BLOCKED by harness guardrail: $why.")
  [Console]::Error.WriteLine("Command: $($shown.Substring(0, [Math]::Min(200, $shown.Length)))")
  [Console]::Error.WriteLine("If genuinely intended, ask the human to run it or adjust .claude/hooks/block-destructive.ps1.")
  exit 2
}

# Spec-lock on the shell surface: during a locked loop run (loop.* set HARNESS_LOCK_SPECS), the Edit/Write
# protect-specs hook is bypassable via a shell redirect/move/delete. Block shell-mediated writes to specs/
# here too. Heuristic (specs are the contract; mutating them mid-run is never legitimate).
if (-not [string]::IsNullOrWhiteSpace($env:HARNESS_LOCK_SPECS)) {
  if ($cmd -match '(>>?|\b(rm|mv|cp|sed|tee|truncate|dd|install|ln)\b|\b(Set-Content|Add-Content|Clear-Content|Out-File|Remove-Item|Move-Item|Copy-Item|New-Item)\b)[^|]*[\s"''=/\\]specs[\\/]') {
    Deny 'writing to specs/ while the loop holds the spec-lock (specs are the immutable contract)' $cmd
  }
}

# Patterns mirror block-destructive.sh. PowerShell -match is case-insensitive by default.
$blocked = @(
  # rm: recursive/force flag anywhere after rm (not just adjacent) — `rm dir -rf` was a bypass.
  @{ rx = '\brm\b[^|]*(\s-[a-z]*r[a-z]*f|\s-[a-z]*f[a-z]*r|\s-r\s+-f|\s-f\s+-r|\s--recursive|\s--force)'; why = 'recursive force-delete' },
  @{ rx = '\bfind\b.*(-delete|-exec\s+rm)';                          why = 'mass delete via find' },
  @{ rx = '\b(shred|truncate\s+-s\s*0)\b';                           why = 'file shredding/truncation' },
  @{ rx = '\bdd\b[^|]*\sof=';                                        why = 'raw disk write via dd' },
  @{ rx = '\bmkfs';                                                  why = 'filesystem format' },
  # PowerShell-tool destructive forms (this hook also matches the PowerShell tool, not just Bash).
  @{ rx = '\bRemove-Item\b[^|]*-(Recurse|Force)';                    why = 'recursive/force Remove-Item' },
  @{ rx = '\b(rd|rmdir)\b\s+/s';                                     why = 'recursive rmdir (/s)' },
  @{ rx = '\bdel\b\s+/[a-z]*[sq]';                                   why = 'recursive/quiet del' },
  @{ rx = '\b(Format-Volume|Clear-Disk|Clear-Content)\b';           why = 'disk/file wipe (PowerShell)' },
  # --force(?!-with-lease): block the unsafe forms but ALLOW the recommended --force-with-lease.
  @{ rx = 'git\s+push\s+.*(-f(\s|$)|--force(?!-with-lease)|\s\+[^\s]+:)'; why = 'force-push (use --force-with-lease)' },
  @{ rx = 'git\s+reset\s+--hard';                                    why = 'discarding work via reset --hard' },
  @{ rx = 'git\s+clean\s+-[a-z]*f';                                  why = 'git clean force' },
  @{ rx = 'git\s+checkout\s+--\s+\.';                                why = 'discarding all changes' },
  @{ rx = '\b(DROP|TRUNCATE)\s+(TABLE|DATABASE|SCHEMA)\b';           why = 'destructive SQL' },
  @{ rx = '(curl|wget)[^|]*\|\s*(sudo\s+)?(bash|sh|zsh|python[0-9.]*|perl|node|pwsh|powershell)'; why = 'piping a remote script into a shell' },
  @{ rx = '(curl|wget)[^\n]*(-d|--data|--data-binary|-T|--upload-file)[^\n]*(\.env|secret|credential|id_rsa|id_ed25519|\.pem|\.key|token)'; why = 'exfiltrating secrets over the network' },
  @{ rx = '(cat|type|gc|Get-Content|less|more|head|tail|sort|grep|xxd|od|base64|strings)\s[^|]*(\.env|credentials|id_rsa|id_ed25519|\.pem|\.key|\.pfx|\.p12|\.npmrc|\.pgpass)'; why = 'reading secrets/credentials' },
  @{ rx = 'chmod\s+(-R\s+)?(0?[0-7]?7{3}|a?\+?rwx)';                 why = 'over-permissive chmod' },
  @{ rx = ':\s*\(\s*\)\s*\{.*\|.*&';                                 why = 'fork bomb' }
)

foreach ($b in $blocked) {
  if ($cmd -match $b.rx) { Deny $b.why $cmd }
}
exit 0
