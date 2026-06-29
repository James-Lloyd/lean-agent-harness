#!/usr/bin/env pwsh
# PreToolUse(Bash) hook — block obviously destructive / exfiltrating commands.
# Reads the tool call as JSON on stdin. Exit 2 + stderr message => Claude Code blocks the call and
# feeds the reason back to the model. Exit 0 => allow. This is a guardrail, not a sandbox: it stops
# the well-known footguns so an autonomous loop can't nuke the repo or leak secrets.
$ErrorActionPreference = 'Stop'
try {
  $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
  $cmd = [string]$payload.tool_input.command
} catch { exit 0 }   # if we can't parse, don't block

if ([string]::IsNullOrWhiteSpace($cmd)) { exit 0 }

# Patterns that should never run unattended. Tuned to avoid false positives on normal work.
$blocked = @(
  @{ rx = 'rm\s+-rf?\s+(/|~|\.\s*$|\*)';           why = 'recursive force-delete of a broad path' },
  @{ rx = 'git\s+push\s+.*--force(?!-with-lease)';  why = 'force-push (use --force-with-lease, and only when asked)' },
  @{ rx = 'git\s+reset\s+--hard\s+HEAD~';           why = 'discarding committed work' },
  @{ rx = '\b(DROP|TRUNCATE)\s+(TABLE|DATABASE|SCHEMA)\b'; why = 'destructive SQL' },
  @{ rx = ':\s*\(\s*\)\s*\{.*\|.*&\s*\}\s*;';       why = 'fork bomb' },
  @{ rx = 'curl[^|]*\|\s*(sudo\s+)?(bash|sh|pwsh)'; why = 'piping a remote script straight into a shell' },
  @{ rx = '(cat|type|Get-Content).*(\.env|credentials|id_rsa|\.pem)'; why = 'reading secrets/credentials' },
  @{ rx = 'chmod\s+-R\s+777';                       why = 'world-writable recursive chmod' }
)

foreach ($b in $blocked) {
  if ($cmd -match $b.rx) {
    [Console]::Error.WriteLine("BLOCKED by harness guardrail: $($b.why).")
    [Console]::Error.WriteLine("Command: $cmd")
    [Console]::Error.WriteLine("If this is genuinely intended, ask the human to run it or adjust .claude/hooks/block-destructive.ps1.")
    exit 2
  }
}
exit 0
