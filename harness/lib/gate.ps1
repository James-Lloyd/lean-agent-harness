<#
  gate.ps1 — the verification gate.
  The harness defines WHEN the gate runs; the stack profile (merged into each component's gate) defines
  WHAT each step is. A null step is skipped. "Silent success, verbose failure": we only surface output
  on failure so the loop's context isn't flooded with green noise.

  Multi-component aware: each component's gate runs in that component's own directory; a cross-cutting
  root gate (config.gate) then runs from the repo root. Any failure short-circuits and is reported with
  the component + step that failed.
#>

function Invoke-GateStep([string]$name, [string]$cmd, [string]$workDir) {
  if ([string]::IsNullOrWhiteSpace([string]$cmd)) { return $true }   # null/absent = skip
  Write-Host "  - $name : $cmd" -ForegroundColor DarkGray
  Push-Location $workDir
  try { $out = & cmd /c $cmd 2>&1; $code = $LASTEXITCODE } finally { Pop-Location }
  if ($code -ne 0) {
    Write-Host "    x $name failed (exit $code) in $workDir :" -ForegroundColor Red
    $out | Select-Object -Last 40 | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
    return $false
  }
  return $true
}

# Run one gate object (format->lint->typecheck->build->test->e2e) in $WorkingDir, labelled $Label.
function Invoke-Gate {
  param([Parameter(Mandatory)] $Gate, [string]$WorkingDir = (Get-Location).Path, [string]$Label = '')
  $steps = [ordered]@{
    format = $Gate.format; lint = $Gate.lint; typecheck = $Gate.typecheck
    build = $Gate.build;   test = $Gate.test; e2e = $Gate.e2e
  }
  foreach ($name in $steps.Keys) {
    if (-not (Invoke-GateStep $name $steps[$name] $WorkingDir)) {
      return [pscustomobject]@{ Passed = $false; FailedStep = $name; Component = $Label }
    }
  }
  return [pscustomobject]@{ Passed = $true; FailedStep = $null; Component = $Label }
}

# Run the WHOLE project gate: every component (in its own dir) then the root cross-cutting gate.
function Invoke-ProjectGate {
  param([Parameter(Mandatory)] $Config, [string]$RepoRoot = (Get-Location).Path)
  $components = @($Config.components)
  if (-not $components -or $components.Count -eq 0) {
    # Back-compat: no components defined — treat top-level gate as a single root component.
    $components = @([pscustomobject]@{ name = 'root'; path = '.'; gate = $Config.gate })
    $Config = [pscustomobject]@{ components = $components; gate = $null }
  }
  foreach ($c in $components) {
    $dir = Join-Path $RepoRoot $c.path
    if (-not (Test-Path $dir)) { Write-Host "  ! component '$($c.name)' path missing: $dir" -ForegroundColor Yellow; continue }
    Write-Host "  [$($c.name)] gate ($($c.path))" -ForegroundColor Cyan
    $r = Invoke-Gate -Gate $c.gate -WorkingDir $dir -Label $c.name
    if (-not $r.Passed) { return $r }
  }
  # Cross-cutting root gate (usually just e2e for multi-component projects).
  if ($Config.gate) {
    $hasAny = @($Config.gate.PSObject.Properties | Where-Object { $_.Name -ne '_comment' -and $_.Value }).Count -gt 0
    if ($hasAny) {
      Write-Host "  [root] cross-cutting gate" -ForegroundColor Cyan
      $r = Invoke-Gate -Gate $Config.gate -WorkingDir $RepoRoot -Label 'root(cross-cutting)'
      if (-not $r.Passed) { return $r }
    }
  }
  return [pscustomobject]@{ Passed = $true; FailedStep = $null; Component = $null }
}
