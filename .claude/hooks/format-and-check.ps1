#!/usr/bin/env pwsh
# PostToolUse(Edit|Write) hook — run the FAST half of the gate for the COMPONENT that owns the changed
# file. In a multi-component repo (frontend/ + backend/ + ...) a .py edit under backend/ must be checked
# with backend's tools, not frontend's. We find the component whose `path` is the deepest prefix of the
# edited file and run only its cheap, deterministic steps (format + lint + typecheck) in its directory.
# "Silent success, verbose failure": say nothing on pass; on fail, exit 2 with the error on stderr so
# the fix lands directly in the model's context. Full tests / e2e run in the loop's gate, not per-edit.
$ErrorActionPreference = 'Stop'

$root = $env:CLAUDE_PROJECT_DIR; if (-not $root) { $root = (Get-Location).Path }
$root = $root.TrimEnd('\','/')

# Read the payload to learn which file changed (best-effort).
$changed = $null
try {
  $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
  $changed = [string]$payload.tool_input.file_path
} catch {}

$configPath = Join-Path $root 'harness/harness.config.json'
if (-not (Test-Path $configPath)) { exit 0 }   # not initialized yet — don't nag
$cfg = Get-Content $configPath -Raw | ConvertFrom-Json

# Resolve the changed file to a repo-relative, forward-slash path.
$rel = $null
if ($changed) {
  try { $rel = [System.IO.Path]::GetFullPath($changed) } catch { $rel = $changed }
  $rel = $rel -replace '\\','/'
  $rootFwd = $root -replace '\\','/'
  if ($rel.ToLower().StartsWith($rootFwd.ToLower())) { $rel = $rel.Substring($rootFwd.Length).TrimStart('/') }
}

# Pick the component whose path is the deepest prefix of the changed file. Fall back to all components
# if we couldn't determine the file (e.g. MultiEdit without a single path).
$components = @($cfg.components)
if (-not $components -or $components.Count -eq 0) { exit 0 }

$targets = @()
if ($rel) {
  $best = $null; $bestLen = -1
  foreach ($c in $components) {
    $p = ($c.path -replace '\\','/').TrimEnd('/')
    $isRoot = ($p -eq '.' -or $p -eq '')
    $match = $isRoot -or $rel.ToLower().StartsWith(($p + '/').ToLower()) -or $rel.ToLower() -eq $p.ToLower()
    if ($match) {
      $len = if ($isRoot) { 0 } else { $p.Length }
      if ($len -gt $bestLen) { $bestLen = $len; $best = $c }
    }
  }
  if ($best) { $targets = @($best) }
}
if ($targets.Count -eq 0) { $targets = $components }   # unknown file -> check everything (safe)

$failed = $false
$report = New-Object System.Text.StringBuilder
foreach ($c in $targets) {
  $dir = Join-Path $root ($c.path)
  if (-not (Test-Path $dir)) { continue }
  $fast = [ordered]@{ format = $c.gate.format; lint = $c.gate.lint; typecheck = $c.gate.typecheck }
  foreach ($name in $fast.Keys) {
    $cmd = $fast[$name]
    if ([string]::IsNullOrWhiteSpace([string]$cmd)) { continue }
    Push-Location $dir
    try { $out = & cmd /c $cmd 2>&1; $code = $LASTEXITCODE } finally { Pop-Location }
    if ($code -ne 0) {
      $failed = $true
      [void]$report.AppendLine("[$($c.name)] x $name failed (exit ${code}): $cmd")
      ($out | Select-Object -Last 25) | ForEach-Object { [void]$report.AppendLine("   $_") }
    }
  }
}

if ($failed) {
  [Console]::Error.WriteLine("Harness gate (fast) found problems in the change you just made. Fix them before continuing:")
  [Console]::Error.WriteLine($report.ToString())
  exit 2
}
exit 0   # silent success
