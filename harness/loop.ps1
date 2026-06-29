#!/usr/bin/env pwsh
#requires -Version 5.1
<#
.SYNOPSIS
  The configurable autonomy loop (Ralph-style, with guardrails).

.DESCRIPTION
  Stateless loop, stateful files. Each iteration pipes PROMPT.md into a fresh `claude` headless
  session, then runs the verification gate. Green => commit (+tag). Red => roll back so the tree is
  never left broken. Bounded by maxIterations and tokenBudget. In supervised mode it pauses at
  checkpoints; in auto mode it runs unattended.

  Config: harness/harness.config.json  (see harness.schema.json for fields)

.EXAMPLE
  powershell harness/loop.ps1                            # Windows PowerShell 5.1
  powershell harness/loop.ps1 -Mode auto -MaxIterations 50
  powershell harness/loop.ps1 -DryRun   # show what it would do; never invokes the model
  # On PowerShell 7 or Unix, use `pwsh harness/loop.ps1` instead.
#>
[CmdletBinding()]
param(
  [ValidateSet('supervised', 'auto')] [string] $Mode,
  [int] $MaxIterations,
  [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- locate repo root & config -------------------------------------------------
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot
$ConfigPath = Join-Path $PSScriptRoot 'harness.config.json'
if (-not (Test-Path $ConfigPath)) { throw "Missing $ConfigPath. Run /harness-init first." }
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# CLI overrides win over config file
if ($Mode)          { $cfg.autonomy.mode = $Mode }
if ($MaxIterations) { $cfg.autonomy.maxIterations = $MaxIterations }

. (Join-Path $PSScriptRoot 'lib/gate.ps1')
. (Join-Path $PSScriptRoot 'lib/checkpoint.ps1')
. (Join-Path $PSScriptRoot 'lib/budget.ps1')

$runDir = Join-Path $PSScriptRoot ('.runs/' + (Get-LoopRunId))
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

function Confirm-Checkpoint([string]$label) {
  # In auto mode, never block. In supervised mode, ask.
  if ($cfg.autonomy.mode -eq 'auto') { return $true }
  Write-Host "`n⏸  Checkpoint: $label" -ForegroundColor Yellow
  $ans = Read-Host "   Continue? [y/N]"
  return ($ans -match '^(y|yes)$')
}

function Get-OpenItemCount {
  $plan = Join-Path $RepoRoot $cfg.loop.planFile
  if (-not (Test-Path $plan)) { return 0 }
  # Count unchecked markdown checkboxes: "- [ ]"
  return @(Select-String -Path $plan -Pattern '^\s*[-*]\s+\[ \]' -ErrorAction SilentlyContinue).Count
}

# --- preflight -----------------------------------------------------------------
Assert-CleanGitTree   # from checkpoint.ps1 — refuse to start on a dirty tree
# Project type (StrictMode-safe access; default greenfield for older configs).
$projType = 'greenfield'
if (($cfg.PSObject.Properties.Name -contains 'project') -and $cfg.project) { $projType = $cfg.project.type }
Write-Host "🔧 Harness loop | type=$projType | mode=$($cfg.autonomy.mode) | maxIter=$($cfg.autonomy.maxIterations) | budget=$($cfg.autonomy.tokenBudget)" -ForegroundColor Cyan

if ($projType -eq 'brownfield') {
  # Brownfield needs a known-good baseline so rollback can tell your breakage from pre-existing failures.
  $baselineOk = $false
  if ($cfg.project -and ($cfg.project.PSObject.Properties.Name -contains 'baseline') -and $cfg.project.baseline) {
    $baselineOk = [bool]$cfg.project.baseline.established
  }
  if (-not $baselineOk) {
    Write-Host "⚠️  Brownfield project with NO established green baseline. Run /onboard first." -ForegroundColor Yellow
    if (-not (Confirm-Checkpoint "Continue without an established baseline?")) { return }
  }
  if ($cfg.autonomy.mode -eq 'auto') {
    Write-Host "⚠️  AUTO mode on a BROWNFIELD codebase. The auto-loop is designed for greenfield; on existing" -ForegroundColor Red
    Write-Host "    code it risks wide, subtle regressions. Supervised + small isolated tasks is recommended." -ForegroundColor Red
    if (-not (Confirm-Checkpoint "Run full-auto on an existing codebase anyway?")) { return }
  }
}

if ($cfg.autonomy.mode -eq 'auto' -and $cfg.autonomy.skipPermissions) {
  Write-Host "⚠️  AUTO + skipPermissions: the model runs UNATTENDED with permission prompts disabled." -ForegroundColor Red
  Write-Host "    Safety rests entirely on the gate, auto-rollback, and the PreToolUse block-hook." -ForegroundColor Red
  if (-not (Confirm-Checkpoint "Proceed with unattended skip-permissions run?")) { return }
}

$prompt = Get-Content (Join-Path $RepoRoot $cfg.loop.promptFile) -Raw
$i = 0
while ($i -lt $cfg.autonomy.maxIterations) {
  $i++
  if ($cfg.loop.stopWhenPlanEmpty -and (Get-OpenItemCount) -eq 0) {
    Write-Host "✅ fix_plan.md has no open items. Nothing to do — stopping." -ForegroundColor Green
    break
  }
  if ($null -ne $cfg.autonomy.tokenBudget -and (Test-BudgetExceeded $cfg.autonomy.tokenBudget)) {
    Write-Host "💸 Token budget exhausted — stopping." -ForegroundColor Yellow
    break
  }
  $nEvery = $cfg.autonomy.checkpoints.everyNIterations
  if ($nEvery -gt 0 -and ($i % $nEvery) -eq 0) {
    if (-not (Confirm-Checkpoint "Reached iteration $i")) { break }
  }

  Write-Host "`n──────── iteration $i / $($cfg.autonomy.maxIterations) ────────" -ForegroundColor Cyan
  $iterLog = Join-Path $runDir ("iter-$i.log")

  if ($DryRun) {
    Write-Host "[dry-run] would invoke: claude -p (PROMPT.md) ; then run the gate." -ForegroundColor DarkGray
    break
  }

  New-Checkpoint -Label "pre-iter-$i"   # stash a restore point

  # --- invoke the model headlessly on a fresh context ---
  $claudeArgs = @('-p', $prompt)
  if ($cfg.autonomy.mode -eq 'auto' -and $cfg.autonomy.skipPermissions) {
    $claudeArgs += '--dangerously-skip-permissions'
  }
  try {
    & claude @claudeArgs *>&1 | Tee-Object -FilePath $iterLog
  } catch {
    Write-Host "❌ claude invocation failed: $_" -ForegroundColor Red
    Restore-Checkpoint; continue
  }
  Update-BudgetFromLog -LogPath $iterLog   # best-effort token accounting

  # --- the gate (all components in their own dirs, then the cross-cutting root gate) ---
  Write-Host "🔬 Running verification gate..." -ForegroundColor Cyan
  $gateResult = Invoke-ProjectGate -Config $cfg -RepoRoot $RepoRoot
  if ($gateResult.Passed) {
    Write-Host "🟢 Gate green." -ForegroundColor Green
    if ($cfg.loop.commitOnGreen) { Commit-Iteration -Index $i }
    if ($cfg.loop.tagOnGreen)    { Tag-Iteration -Index $i }
    Clear-Checkpoint
  } else {
    Write-Host "🔴 Gate red: [$($gateResult.Component)] $($gateResult.FailedStep). " -ForegroundColor Red
    if ($cfg.loop.autoRollbackOnRed) {
      Write-Host "↩  Rolling back to keep the tree green." -ForegroundColor Yellow
      Restore-Checkpoint
    } else {
      Write-Host "   autoRollbackOnRed=false — leaving the tree as-is for inspection. Stopping." -ForegroundColor Yellow
      break
    }
  }
}

Write-Host "`n🏁 Loop finished after $i iteration(s). Logs: $runDir" -ForegroundColor Cyan
Write-Host "   Next: run /review for a fresh-context QA pass before you trust this." -ForegroundColor DarkGray
