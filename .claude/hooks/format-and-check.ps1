#!/usr/bin/env pwsh
# PostToolUse(Edit|Write) hook — run the FAST half of the gate after a file change.
# "Silent success, verbose failure": say nothing on pass; on fail, exit 2 and write the error to
# stderr so the fix lands directly in the model's context ("positive prompt injection").
# We run only the cheap, deterministic steps here (format + lint + typecheck). Full tests / e2e run
# in the loop's gate, not on every keystroke — keep quality left, but keep edits fast.
$ErrorActionPreference = 'Stop'

# Read (and ignore) stdin payload; we act on config, not the specific file, for stack-neutrality.
try { [Console]::In.ReadToEnd() | Out-Null } catch {}

$root = $env:CLAUDE_PROJECT_DIR
if (-not $root) { $root = (Get-Location).Path }
$configPath = Join-Path $root 'harness/harness.config.json'
if (-not (Test-Path $configPath)) { exit 0 }   # not initialized yet — don't nag
$cfg = Get-Content $configPath -Raw | ConvertFrom-Json

$fast = [ordered]@{ format = $cfg.gate.format; lint = $cfg.gate.lint; typecheck = $cfg.gate.typecheck }
$failed = $false
$report = New-Object System.Text.StringBuilder

foreach ($name in $fast.Keys) {
  $cmd = $fast[$name]
  if ([string]::IsNullOrWhiteSpace([string]$cmd)) { continue }
  Push-Location $root
  $out = & cmd /c $cmd 2>&1
  $code = $LASTEXITCODE
  Pop-Location
  if ($code -ne 0) {
    $failed = $true
    [void]$report.AppendLine("✗ $name failed (exit ${code}): $cmd")
    ($out | Select-Object -Last 25) | ForEach-Object { [void]$report.AppendLine("   $_") }
  }
}

if ($failed) {
  [Console]::Error.WriteLine("Harness gate (fast) found problems in the change you just made. Fix them before continuing:")
  [Console]::Error.WriteLine($report.ToString())
  exit 2
}
exit 0   # silent success
