<#
  gate.ps1 — the verification gate.
  The harness defines WHEN the gate runs; the stack profile (merged into config.gate) defines WHAT
  each step is. A null step is skipped. "Silent success, verbose failure": we only surface output
  on failure so the loop's context isn't flooded with green noise.
#>

function Invoke-GateStep([string]$name, [string]$cmd) {
  if ([string]::IsNullOrWhiteSpace($cmd)) { return $true }   # null/absent = skip
  Write-Host "  • $name : $cmd" -ForegroundColor DarkGray
  $out = & cmd /c $cmd 2>&1            # run via shell so npm/pytest/cargo etc. resolve
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    Write-Host "    ✗ $name failed (exit $code):" -ForegroundColor Red
    $out | Select-Object -Last 40 | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
    return $false
  }
  return $true
}

function Invoke-Gate {
  param([Parameter(Mandatory)] $Gate)
  # Order matters: cheapest/fastest first (fail fast, keep quality left).
  $steps = [ordered]@{
    format    = $Gate.format
    lint      = $Gate.lint
    typecheck = $Gate.typecheck
    build     = $Gate.build
    test      = $Gate.test
    e2e       = $Gate.e2e
  }
  foreach ($name in $steps.Keys) {
    if (-not (Invoke-GateStep $name $steps[$name])) {
      return [pscustomobject]@{ Passed = $false; FailedStep = $name }
    }
  }
  return [pscustomobject]@{ Passed = $true; FailedStep = $null }
}
