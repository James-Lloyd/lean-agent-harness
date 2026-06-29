#!/usr/bin/env pwsh
# SessionStart hook — orient a fresh context fast. stdout is injected into the session as context.
# Keep it SHORT (a few lines): branch, top open task, last progress entry, any pending human decision.
# This is the "quickly understand the state of work when starting with a fresh context window" move.
$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::In.ReadToEnd() | Out-Null } catch {}

$root = $env:CLAUDE_PROJECT_DIR; if (-not $root) { $root = (Get-Location).Path }
function rel($p) { Join-Path $root $p }

$lines = @()
$branch = (& git -C $root rev-parse --abbrev-ref HEAD 2>$null)
if ($branch) { $lines += "branch: $branch" }

$plan = rel 'state/fix_plan.md'
if (Test-Path $plan) {
  $open = @(Select-String -Path $plan -Pattern '^\s*[-*]\s+\[ \]' )
  $lines += "open tasks: $($open.Count)"
  if ($open.Count -gt 0) { $lines += "next up: " + ($open[0].Line.Trim() -replace '^[-*]\s+\[ \]\s*','') }
}

$progress = rel 'state/PROGRESS.md'
if (Test-Path $progress) {
  $last = Get-Content $progress | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 1
  if ($last) { $lines += "last progress: $($last.Trim())" }
}

$handoff = rel 'state/handoff.md'
if (Test-Path $handoff) {
  $needs = Select-String -Path $handoff -Pattern 'Needs human decision' -Quiet
  if ($needs) { $lines += "⚠ handoff.md has an unresolved 'Needs human decision' — read it before working." }
}

if ($lines.Count -gt 0) {
  Write-Output "Harness state ::"
  $lines | ForEach-Object { Write-Output "  - $_" }
  Write-Output "Read CLAUDE.md for the map. One task per iteration; verify before done."
}
exit 0
