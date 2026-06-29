<#
  budget.ps1 — best-effort token/cost accounting so an unattended loop can't run away.
  We persist a small JSON tally in harness/.budget.json and stop the loop when the configured
  tokenBudget is exceeded. Token counts are parsed from the headless claude output on a best-effort
  basis; if they can't be parsed we fall back to a per-iteration estimate so the cap still bites.
#>

# PS 5.1-safe path build (3-arg Join-Path is 6+ only): lib/ -> harness/ -> .budget.json
$script:BudgetFile = Join-Path (Split-Path $PSScriptRoot -Parent) '.budget.json'

function Get-LoopRunId {
  # No Date.now in some contexts; use git-friendly incrementing id from existing runs.
  $runsDir = Join-Path (Split-Path $PSScriptRoot -Parent) '.runs'
  if (-not (Test-Path $runsDir)) { return 'run-001' }
  $n = @(Get-ChildItem $runsDir -Directory -ErrorAction SilentlyContinue).Count + 1
  return ('run-{0:D3}' -f $n)
}

function Get-Budget {
  if (Test-Path $script:BudgetFile) { return Get-Content $script:BudgetFile -Raw | ConvertFrom-Json }
  return [pscustomobject]@{ tokensSpent = 0 }
}

function Save-Budget($b) { $b | ConvertTo-Json | Set-Content -Path $script:BudgetFile -Encoding utf8 }

function Update-BudgetFromLog([string]$LogPath) {
  $b = Get-Budget
  $spent = 0
  if (Test-Path $LogPath) {
    # Look for a token figure in the headless output; tolerate absence.
    $m = Select-String -Path $LogPath -Pattern '(\d[\d,]*)\s*tokens' -AllMatches -ErrorAction SilentlyContinue
    if ($m) { $spent = ($m.Matches | ForEach-Object { [int]($_.Groups[1].Value -replace ',','') } | Measure-Object -Maximum).Maximum }
  }
  if ($spent -le 0) { $spent = 15000 }   # conservative per-iteration fallback estimate
  $b.tokensSpent = [int]$b.tokensSpent + [int]$spent
  Save-Budget $b
  Write-Host ("  📊 tokens this run: ~{0:N0}" -f $b.tokensSpent) -ForegroundColor DarkGray
}

function Test-BudgetExceeded([int]$Cap) {
  if (-not $Cap) { return $false }
  return ([int](Get-Budget).tokensSpent -ge $Cap)
}
