<#
  budget.ps1 — best-effort token accounting so an unattended loop can't run away.

  IMPORTANT: this is an ESTIMATE, not exact metering. `claude -p` in text mode does not reliably emit
  token counts, so when none are found we fall back to a per-iteration estimate. Treat `tokenBudget` as
  a soft cap that bounds rough spend; the HARD bound on a runaway is `autonomy.maxIterations` plus the
  per-iteration `--max-turns` passed to claude. The tally is reset at the START of each run (see
  Reset-Budget) so the cap is per-run, not a lifetime counter.
#>

# PS 5.1-safe path build (3-arg Join-Path is 6+ only): lib/ -> harness/ -> .budget.json
$script:BudgetFile = Join-Path (Split-Path $PSScriptRoot -Parent) '.budget.json'

function Get-LoopRunId {
  # No Date.now in some contexts; use an incrementing id from existing run dirs.
  $runsDir = Join-Path (Split-Path $PSScriptRoot -Parent) '.runs'
  if (-not (Test-Path $runsDir)) { return 'run-001' }
  $n = @(Get-ChildItem $runsDir -Directory -ErrorAction SilentlyContinue).Count + 1
  return ('run-{0:D3}' -f $n)
}

function Get-Budget {
  # Degrade on a missing/corrupt ledger rather than aborting the whole loop under StrictMode/Stop.
  if (Test-Path $script:BudgetFile) {
    try { return Get-Content $script:BudgetFile -Raw | ConvertFrom-Json } catch { }
  }
  return [pscustomobject]@{ tokensSpent = 0 }
}

function Save-Budget($b) { $b | ConvertTo-Json | Set-Content -Path $script:BudgetFile -Encoding utf8 }

# Reset the tally at the START of each run — tokenBudget is a per-run cap, not a lifetime counter.
function Reset-Budget { Save-Budget ([pscustomobject]@{ tokensSpent = 0 }) }

function Update-BudgetFromLog([string]$LogPath) {
  $b = Get-Budget
  $spent = 0
  if (Test-Path $LogPath) {
    $text = Get-Content $LogPath -Raw -ErrorAction SilentlyContinue
    # Prefer real usage if the output carries it (json: "output_tokens": N). Take the MAX of each field,
    # not the sum: --output-format json can repeat the same counts in a per-model `modelUsage` breakdown
    # alongside the aggregate `usage`, so summing every match double-counts. Max ≈ the aggregate total.
    $inM  = [regex]::Matches($text, '"input_tokens"\s*:\s*(\d+)')
    $outM = [regex]::Matches($text, '"output_tokens"\s*:\s*(\d+)')
    if ($inM.Count -gt 0 -or $outM.Count -gt 0) {
      $maxIn  = if ($inM.Count)  { ($inM  | ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Maximum).Maximum } else { 0 }
      $maxOut = if ($outM.Count) { ($outM | ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Maximum).Maximum } else { 0 }
      $spent = $maxIn + $maxOut
    } else {
      # Else any "<n> tokens" figure (take the max seen).
      $tm = [regex]::Matches($text, '(\d[\d,]*)\s*tokens')
      if ($tm.Count -gt 0) { $spent = ($tm | ForEach-Object { [int]($_.Groups[1].Value -replace ',','') } | Measure-Object -Maximum).Maximum }
    }
  }
  if ($spent -le 0) { $spent = 15000 }   # conservative per-iteration ESTIMATE when no count is found
  $b.tokensSpent = [int]$b.tokensSpent + [int]$spent
  Save-Budget $b
  Write-Host ("  📊 est. tokens this run: ~{0:N0}" -f $b.tokensSpent) -ForegroundColor DarkGray
}

function Test-BudgetExceeded([int]$Cap) {
  if (-not $Cap) { return $false }
  return ([int](Get-Budget).tokensSpent -ge $Cap)
}
