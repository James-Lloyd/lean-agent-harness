#!/usr/bin/env pwsh
#requires -Version 5.1
<#
.SYNOPSIS
  The configurable autonomy loop (Ralph-style, with guardrails).

.DESCRIPTION
  Stateless loop, stateful files. Each iteration pipes PROMPT.md into a fresh `claude` headless
  session, then runs the verification gate. Green => commit (+tag). Red (or a gate error, or config
  tampering) => roll back so the tree is never left broken. Bounded by maxIterations, a per-iteration
  --max-turns, and a best-effort tokenBudget. Supervised pauses at checkpoints; auto runs unattended.

  Config: harness/harness.config.json  (see harness.schema.json for fields)

  Runs commands through cmd on Windows and bash elsewhere, so this works under pwsh on Unix too.
  Do NOT edit the working tree while the loop runs — rollback uses `git reset --hard`/`git clean -fd`.

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
if ($PSBoundParameters.ContainsKey('MaxIterations')) { $cfg.autonomy.maxIterations = $MaxIterations }

. (Join-Path $PSScriptRoot 'lib/gate.ps1')        # also provides Get-Prop (StrictMode-safe accessor)
. (Join-Path $PSScriptRoot 'lib/checkpoint.ps1')
. (Join-Path $PSScriptRoot 'lib/budget.ps1')

$runId  = Get-LoopRunId
$runDir = Join-Path $PSScriptRoot ('.runs/' + $runId)
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$ledgerPath = Join-Path $runDir 'ledger.jsonl'
Reset-Budget   # tokenBudget is a per-run cap, not a lifetime counter

# Tamper-pin: the agent must not rewrite its own gate/policy. We hash the config at start and abort an
# iteration whose run changed it (settings.json also denies writes to it; this is the belt to that braces).
function Get-ConfigHash { (Get-FileHash $ConfigPath -Algorithm SHA256).Hash }
$configHash0 = Get-ConfigHash

function Write-Ledger($obj) { ($obj | ConvertTo-Json -Compress) | Add-Content -Path $ledgerPath -Encoding utf8 }

function Confirm-Checkpoint([string]$label) {
  if ($cfg.autonomy.mode -eq 'auto') { return $true }   # auto never blocks
  Write-Host "`n⏸  Checkpoint: $label" -ForegroundColor Yellow
  $ans = Read-Host "   Continue? [y/N]"
  return ($ans -match '^(y|yes)$')
}

function Get-OpenItemCount {
  $plan = Join-Path $RepoRoot $cfg.loop.planFile
  if (-not (Test-Path $plan)) { return 0 }
  return @(Select-String -Path $plan -Pattern '^\s*[-*]\s+\[ \]' -ErrorAction SilentlyContinue).Count
}

# Periodic inferential judge: spawn a fresh-context reviewer over every commit since $Base (the last
# review watermark, or the run's starting HEAD). "doer != judge", wired into the unattended loop.
# Hardened: (1) the reviewer runs READ-ONLY (--disallowedTools + a hard reset afterward) so a judge can
# never mutate the artifact it's judging and slip past the gate; (2) it FAILS CLOSED — only an explicit
# VERDICT: SHIP continues the loop; REJECT, a truncated run, a crash, or an empty result all stop for a
# human. NOTE (honest limitation): this review is DIFF-ONLY — it can read code + git but is not granted
# the tools to run the app, so it can't gather fresh e2e evidence itself (see ROADMAP).
# Returns $true to continue; $false to stop the loop for human attention.
function Invoke-PeriodicReview {
  param([string]$Base, [string]$RunDir, [int]$Iter)
  $head = "$(& git rev-parse HEAD)".Trim()
  if ($Base -eq $head) { Write-Host "  (periodic review: no new commits since last review)" -ForegroundColor DarkGray; return $true }
  Write-Host "🧑‍⚖️  Periodic fresh-context review of commits $(_Short $Base)..$(_Short $head)..." -ForegroundColor Cyan
  $reviewPrompt = @"
You are a FRESH-CONTEXT REVIEWER (the harness 'reviewer' role — see .claude/agents/reviewer.md). You
have NO memory of how this code was written; judge only the artifact. You are READ-ONLY — do not edit,
write, or commit anything.

1. Inspect the batch:  git log --oneline $Base..HEAD   and   git diff $Base..HEAD
2. Judge it against specs/ (acceptance criteria) and docs/principles/ (golden principles): correctness
   vs spec, evidence quality, guardrails (no weakened/deleted tests, no edited specs, no destructive
   ops/secrets), architectural drift, needless complexity.
3. List findings as  file:line — problem — concrete fix.

Finish with EXACTLY ONE final line and nothing after it:
VERDICT: SHIP     (the batch is sound)
VERDICT: REJECT   (anything is wrong — default to REJECT when unsure)
"@
  $reviewLog = Join-Path $RunDir ("review-after-$Iter.log")
  $reviewArgs = @('-p', $reviewPrompt, '--max-turns', '20', '--disallowedTools', 'Edit Write MultiEdit NotebookEdit')
  $out = ''; $invokeOk = $true
  try { $out = (& claude @reviewArgs *>&1 | Tee-Object -FilePath $reviewLog | Out-String) }
  catch { $invokeOk = $false; $out = "$_" }
  # A judge must not mutate the artifact: restore the tree to exactly the reviewed HEAD, no matter what.
  & git reset --hard $head *> $null
  & git clean -fd *> $null
  if (-not $invokeOk) {
    Write-Host "  ! review invocation failed — failing closed (stopping for human)." -ForegroundColor Red
    Write-Reject-Handoff -Reason 'review could not run' -Base $Base -Head $head -Iter $Iter -Log $reviewLog
    return $false
  }
  if ($out -match 'VERDICT:\s*SHIP') { Write-Host "  🟢 Periodic review: SHIP." -ForegroundColor Green; return $true }
  $reason = if ($out -match 'VERDICT:\s*REJECT') { 'REJECT' } else { 'no clear SHIP verdict (fail-closed)' }
  Write-Host "  🔴 Periodic review: $reason. Stopping for human attention." -ForegroundColor Red
  Write-Reject-Handoff -Reason $reason -Base $Base -Head $head -Iter $Iter -Log $reviewLog
  return $false
}

function Write-Reject-Handoff {
  param([string]$Reason, [string]$Base, [string]$Head, [int]$Iter, [string]$Log)
  $note = "`n## Needs human decision — periodic review: $Reason ($(_Short $Base)..$(_Short $Head), iter $Iter)`n" +
          "The fresh-context reviewer did not return SHIP. Findings: $Log. Inspect before continuing the loop.`n"
  Add-Content -Path (Join-Path $RepoRoot 'state/handoff.md') -Value $note -Encoding utf8
}

# Does any gate (component or root) define an e2e step? Used to warn honestly about unit-green commits.
function Test-AnyE2E {
  $comps = @(Get-Prop $cfg 'components')
  foreach ($c in $comps) { if (Get-Prop (Get-Prop $c 'gate') 'e2e') { return $true } }
  if (Get-Prop (Get-Prop $cfg 'gate') 'e2e') { return $true }
  return $false
}

# --- preflight -----------------------------------------------------------------
Assert-CleanGitTree   # refuse to start on a dirty tree / no-HEAD repo
$projType = 'greenfield'
if (($cfg.PSObject.Properties.Name -contains 'project') -and $cfg.project) { $projType = $cfg.project.type }
$maxTurns = Get-Prop $cfg.autonomy 'maxTurnsPerIteration'; if (-not $maxTurns) { $maxTurns = 40 }
$reviewEveryN = Get-Prop (Get-Prop $cfg 'verification') 'reviewEveryNIterations'; if (-not $reviewEveryN) { $reviewEveryN = 0 }
Write-Host "🔧 Harness loop | type=$projType | mode=$($cfg.autonomy.mode) | maxIter=$($cfg.autonomy.maxIterations) | maxTurns=$maxTurns | budget=$($cfg.autonomy.tokenBudget)" -ForegroundColor Cyan

if ($cfg.autonomy.mode -eq 'auto' -and (Get-Prop $cfg.verification 'requireE2EEvidence') -and -not (Test-AnyE2E)) {
  Write-Host "⚠️  auto mode + requireE2EEvidence, but no e2e gate step is configured. The loop will commit on" -ForegroundColor Yellow
  Write-Host "    unit-green only. Add an e2e command to a component/root gate, or run /review periodically." -ForegroundColor Yellow
}

if ($projType -eq 'brownfield') {
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

if ($cfg.autonomy.mode -eq 'auto' -and (Get-Prop $cfg.autonomy 'skipPermissions')) {
  Write-Host "⚠️  AUTO + skipPermissions: the model runs UNATTENDED with permission prompts disabled." -ForegroundColor Red
  Write-Host "    The deny-list (incl. secrets) is VOID in this mode — run inside a sandbox/container." -ForegroundColor Red
  if (-not (Confirm-Checkpoint "Proceed with unattended skip-permissions run?")) { return }
}

# Lock specs/ for the duration of the run: the protect-specs PreToolUse hook (inherited by the headless
# claude child) blocks edits under specs/ while this is set. The loop must never rewrite the contract.
$env:HARNESS_LOCK_SPECS = '1'

$prompt = Get-Content (Join-Path $RepoRoot $cfg.loop.promptFile) -Raw
$i = 0
$greenCount = 0
$reviewBaseRef = "$(& git rev-parse HEAD)".Trim()   # periodic-review watermark: commits after this are unreviewed
while ($i -lt $cfg.autonomy.maxIterations) {
  $i++
  if ($cfg.loop.stopWhenPlanEmpty -and (Get-OpenItemCount) -eq 0) {
    Write-Host "✅ fix_plan.md has no open items. Nothing to do — stopping." -ForegroundColor Green
    break
  }
  if ($null -ne $cfg.autonomy.tokenBudget -and (Test-BudgetExceeded $cfg.autonomy.tokenBudget)) {
    Write-Host "💸 Token budget (estimate) exhausted — stopping." -ForegroundColor Yellow
    break
  }
  $nEvery = $cfg.autonomy.checkpoints.everyNIterations
  if ($nEvery -gt 0 -and ($i % $nEvery) -eq 0) {
    if (-not (Confirm-Checkpoint "Reached iteration $i")) { break }
  }

  Write-Host "`n──────── iteration $i / $($cfg.autonomy.maxIterations) ────────" -ForegroundColor Cyan
  $iterLog = Join-Path $runDir ("iter-$i.log")

  if ($DryRun) {
    Write-Host "[dry-run] would invoke: claude -p (PROMPT.md) --max-turns $maxTurns ; then run the gate." -ForegroundColor DarkGray
    break
  }

  New-Checkpoint -Label "pre-iter-$i"

  # --- invoke the model headlessly on a fresh context ---
  $claudeArgs = @('-p', $prompt, '--max-turns', "$maxTurns")
  if ($cfg.autonomy.mode -eq 'auto' -and (Get-Prop $cfg.autonomy 'skipPermissions')) {
    $claudeArgs += '--dangerously-skip-permissions'
  }
  if (Get-Prop $cfg.autonomy 'meterTokens') { $claudeArgs += @('--output-format', 'json') }   # exact usage
  try {
    & claude @claudeArgs *>&1 | Tee-Object -FilePath $iterLog
  } catch {
    Write-Host "❌ claude invocation failed: $_" -ForegroundColor Red
    Write-Ledger @{ iter = $i; result = 'invoke-error'; error = "$_" }
    Restore-Checkpoint; continue
  }
  Update-BudgetFromLog -LogPath $iterLog

  # --- tamper check: the agent must not have rewritten its own gate/policy ---
  if ((Get-ConfigHash) -ne $configHash0) {
    Write-Host "🛑 harness.config.json changed during the iteration (gate/policy tampering?). Rolling back and stopping." -ForegroundColor Red
    Write-Ledger @{ iter = $i; result = 'config-tampered' }
    Restore-Checkpoint; break
  }

  # --- the gate (each component in its dir, then the cross-cutting root gate) ---
  Write-Host "🔬 Running verification gate..." -ForegroundColor Cyan
  try {
    $gateResult = Invoke-ProjectGate -Config $cfg -RepoRoot $RepoRoot
  } catch {
    Write-Host "❌ Gate errored: $_  — rolling back (never leave a broken tree)." -ForegroundColor Red
    Write-Ledger @{ iter = $i; result = 'gate-error'; error = "$_" }
    Restore-Checkpoint; continue
  }

  if ($gateResult.Passed) {
    Write-Host "🟢 Gate green." -ForegroundColor Green
    if ($cfg.loop.commitOnGreen) { Commit-Iteration -Index $i }
    if ($cfg.loop.tagOnGreen)    { Tag-Iteration -Index $i -RunId $runId }
    Clear-Checkpoint
    Write-Ledger @{ iter = $i; result = 'green'; committed = [bool]$cfg.loop.commitOnGreen }
    $greenCount++
    # Inferential judge, wired in: every N green iterations a fresh-context reviewer audits the batch.
    if ($reviewEveryN -gt 0 -and $cfg.loop.commitOnGreen -and ($greenCount % $reviewEveryN) -eq 0) {
      if (Invoke-PeriodicReview -Base $reviewBaseRef -RunDir $runDir -Iter $i) {
        $reviewBaseRef = "$(& git rev-parse HEAD)".Trim()   # advance the watermark past the reviewed batch
      } else {
        Write-Ledger @{ iter = $i; result = 'review-stop' }
        break
      }
    }
  } else {
    Write-Host "🔴 Gate red: [$($gateResult.Component)] $($gateResult.FailedStep)." -ForegroundColor Red
    Write-Ledger @{ iter = $i; result = 'red'; component = "$($gateResult.Component)"; failedStep = "$($gateResult.FailedStep)" }
    if ($cfg.loop.autoRollbackOnRed) {
      Write-Host "↩  Rolling back to keep the tree green." -ForegroundColor Yellow
      Restore-Checkpoint
    } else {
      Write-Host "   autoRollbackOnRed=false — leaving the tree as-is for inspection. Stopping." -ForegroundColor Yellow
      break
    }
  }
}

Remove-Item Env:HARNESS_LOCK_SPECS -ErrorAction SilentlyContinue   # don't leak the spec-lock if dot-sourced
Write-Host "`n🏁 Loop finished after $i iteration(s). Logs + ledger: $runDir" -ForegroundColor Cyan
Write-Host "   Next: run /review for a fresh-context QA pass before you trust this." -ForegroundColor DarkGray
