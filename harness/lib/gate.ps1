<#
  gate.ps1 — the verification gate.
  The harness defines WHEN the gate runs; the stack profile (merged into each component's gate) defines
  WHAT each step is. A null/absent step is skipped. "Silent success, verbose failure": we only surface
  output on failure so the loop's context isn't flooded with green noise.

  Multi-component aware: each component's gate runs in that component's own directory; a cross-cutting
  root gate (config.gate) then runs from the repo root. Any failure short-circuits and is reported with
  the component + step that failed.

  Robustness notes:
   - StrictMode-safe property access (a gate object may legitimately omit keys — the schema allows it,
     and /harness-prune may trim config). Missing key => treated as null => skipped, never a crash.
   - Cross-platform: gate commands run through cmd on Windows and bash elsewhere, so loop.ps1 works
     under pwsh on Unix too (not just Windows PowerShell).
#>

# StrictMode-safe: return a property's value or $null if the property is absent.
function Get-Prop($obj, [string]$name) {
  if ($null -eq $obj) { return $null }
  $p = $obj.PSObject.Properties[$name]
  if ($p) { return $p.Value } else { return $null }
}

function Invoke-GateStep([string]$name, [string]$cmd, [string]$workDir) {
  if ([string]::IsNullOrWhiteSpace([string]$cmd)) { return $true }   # null/absent = skip
  Write-Host "  - $name : $cmd" -ForegroundColor DarkGray
  Push-Location $workDir
  # CRITICAL: drop $ErrorActionPreference to 'Continue' around the native call. The caller runs under
  # 'Stop', where a native command that writes to STDERR — even on exit 0 (pytest/eslint/pnpm progress
  # and deprecation lines are routine) — gets wrapped in a NativeCommandError and raised as terminating
  # BEFORE $LASTEXITCODE is read. That would misclassify a green step as a gate error and roll it back.
  $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    if ($env:OS -eq 'Windows_NT') { $out = & cmd /c $cmd 2>&1 }       # Windows shell
    else                          { $out = & bash -lc $cmd 2>&1 }     # pwsh on Unix/macOS/CI
    $code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $prevEAP; Pop-Location }
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
    format    = (Get-Prop $Gate 'format')
    lint      = (Get-Prop $Gate 'lint')
    typecheck = (Get-Prop $Gate 'typecheck')
    build     = (Get-Prop $Gate 'build')
    test      = (Get-Prop $Gate 'test')
    e2e       = (Get-Prop $Gate 'e2e')
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
  $components = @(Get-Prop $Config 'components')
  $rootGate = Get-Prop $Config 'gate'
  if (-not $components -or $components.Count -eq 0) {
    # Back-compat: no components defined — treat top-level gate as a single root component.
    return (Invoke-Gate -Gate $rootGate -WorkingDir $RepoRoot -Label 'root')
  }
  foreach ($c in $components) {
    $cPath = [string](Get-Prop $c 'path'); if (-not $cPath) { $cPath = '.' }
    $cName = [string](Get-Prop $c 'name'); if (-not $cName) { $cName = $cPath }
    $dir = Join-Path $RepoRoot $cPath
    if (-not (Test-Path $dir)) { Write-Host "  ! component '$cName' path missing: $dir" -ForegroundColor Yellow; continue }
    Write-Host "  [$cName] gate ($cPath)" -ForegroundColor Cyan
    $r = Invoke-Gate -Gate (Get-Prop $c 'gate') -WorkingDir $dir -Label $cName
    if (-not $r.Passed) { return $r }
  }
  # Cross-cutting root gate (usually just e2e for multi-component projects).
  if ($rootGate) {
    $hasAny = @($rootGate.PSObject.Properties | Where-Object { $_.Name -ne '_comment' -and $_.Value }).Count -gt 0
    if ($hasAny) {
      Write-Host "  [root] cross-cutting gate" -ForegroundColor Cyan
      $r = Invoke-Gate -Gate $rootGate -WorkingDir $RepoRoot -Label 'root(cross-cutting)'
      if (-not $r.Passed) { return $r }
    }
  }
  return [pscustomobject]@{ Passed = $true; FailedStep = $null; Component = $null }
}
