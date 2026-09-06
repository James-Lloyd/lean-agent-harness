<#
  Mutation proof for the strict promotion flags (fix_plan: "Make Get-PromotionDecision's four boolean
  params strict, matching the sh twin").

  It does not edit the shipped lib. It copies risk.ps1, restores the pre-fix `[bool]` annotations on
  the four gate flags in the copy, and drives BOTH through the same table of argument values, so the
  divergence is visible side by side.

  Usage:  powershell -NoProfile -File mutation-proof.ps1 -RepoRoot <path to repo root>
#>
param([Parameter(Mandatory=$true)][string]$RepoRoot)

$shipped = Join-Path $RepoRoot 'plugin/engine/lib/risk.ps1'
$work    = Join-Path ([System.IO.Path]::GetTempPath()) ("strictflags-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $work | Out-Null
$mutant  = Join-Path $work 'risk-mutant.ps1'

$strict = '        $GateGreen = $false, $ReviewShip = $false, $E2EEvidence = $false,
        $ReviewerConfigured = $false)'
$prefix = '        [bool]$GateGreen = $false, [bool]$ReviewShip = $false, [bool]$E2EEvidence = $false,
        [bool]$ReviewerConfigured = $false)'

$src = Get-Content $shipped -Raw
if (-not $src.Contains($strict)) { throw "shipped risk.ps1 no longer has the strict (untyped) param block - update this proof" }
Set-Content -Path $mutant -Value ($src.Replace($strict, $prefix)) -Encoding utf8

# The probe body, written once and run against each lib in its own process (both define the same
# function names, so they cannot share a session).
$probe = Join-Path $work 'probe.ps1'
Set-Content -Path $probe -Encoding utf8 -Value @'
param([Parameter(Mandatory=$true)][string]$Lib)
. $Lib
$cfg = @"
{ "promotion": {
  "enabled": true,
  "staging": { "branch": "staging", "autoMergeAtOrBelow": "low" },
  "prod": { "branch": "main", "autoMerge": false },
  "alwaysHuman": ["**/payments/**"],
  "moneySignals": ["price", "tax"],
  "criteria": { "maxChangedLines": 1000 },
  "preconditions": { "gateGreen": true, "reviewShip": true, "e2eEvidence": true } } }
"@ | ConvertFrom-Json
function Try1($label, $r) {
  try {
    $d = (Get-PromotionDecision -Config $cfg -Environment 'staging' -DeterministicTier 'LOW' -ClassifierTier 'LOW' `
            -GateGreen $true -ReviewShip $true -E2EEvidence $true -ReviewerConfigured $r -ErrorAction Stop).Decision
    Write-Host ("  {0,-32} -> {1}" -f $label, $d)
  } catch {
    Write-Host ("  {0,-32} -> BINDING ERROR (exception, not a decision)" -f $label)
  }
}
Write-Host ("  host: PowerShell " + $PSVersionTable.PSVersion)
Try1 'reviewer = $true   (bool)'   $true
Try1 'reviewer = $false  (bool)'   $false
Try1 'reviewer = 0       (int)'    0
Try1 'reviewer = 1       (int)'    1
Try1 'reviewer = 2       (int)'    2
Try1 'reviewer = -1      (int)'    (-1)
Try1 'reviewer = 0.5     (double)' 0.5
Try1 'reviewer = "0"     (string)' '0'
Try1 'reviewer = "1"     (string)' '1'
Try1 'reviewer = $null'            $null
Try1 'reviewer = @{}     (hash)'   @{}
'@

Write-Host "=== MUTANT: the pre-fix [bool] annotations ==="
& powershell -NoProfile -File $probe -Lib $mutant 2>$null
Write-Host ""
Write-Host "=== SHIPPED: untyped params narrowed by Test-RiskStrictTrue ==="
& powershell -NoProfile -File $probe -Lib $shipped 2>$null
Write-Host ""
Write-Host "The mutant returns AUTO for 1, 2, -1 and 0.5 -- every nonzero NUMBER opens the last gate"
Write-Host "before auto-merge, where the sh twin (only the exact string '1' passes) returns HUMAN."
Write-Host "Strings are a BINDING ERROR on the mutant, not the silent AUTO the fix_plan entry claimed."

Remove-Item -Recurse -Force $work
