#!/usr/bin/env pwsh
#requires -Version 5.1
<#
.SYNOPSIS
  The fleet runner: opt-in parallel execution of INDEPENDENT tasks across git worktrees, with a
  serialized merge queue. "Parallel generation, serialized integration."

.DESCRIPTION
  Picks up to parallel.maxWorkers tasks from state/tasks.json that are file-ownership-partitioned
  (non-empty `files` lists that don't overlap — see lib/fleet.ps1), snapshots HEAD as the batch base,
  builds each task with a headless `claude` worker in its own worktree/branch (fleet/<runId>/<taskId>),
  then integrates SERIALLY: squash-merge each branch onto the advancing main tree, re-run the FULL
  project gate on the combined state, commit on green, park on conflict/red/tamper. Parked branches
  are kept for a human; merged ones are cleaned up. Workers never commit and never touch state/ —
  the runner records (tasks.json -> validated, PROGRESS.md, the fleet ledger).

  This is deliberately NOT the default way to work: coding has fewer truly parallelizable tasks than
  it seems, and each worker costs real tokens. Use it for a batch of genuinely independent items.

.EXAMPLE
  powershell harness/fleet.ps1                 # batch of up to parallel.maxWorkers (default 3)
  powershell harness/fleet.ps1 -MaxWorkers 2
  powershell harness/fleet.ps1 -DryRun         # show the batch + worktrees; never invokes the model
#>
[CmdletBinding()]
param(
  [int] $MaxWorkers,
  [string] $ProjectRoot,
  [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# Engine off $PSScriptRoot; PROJECT (config, runtime, git, tasks.json) off $ProjectRoot — distinct once
# this engine ships from an installed plugin. -ProjectRoot wins; else git top-level; else current dir.
if (-not $ProjectRoot) {
  $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $top = (& git rev-parse --show-toplevel 2>$null | Select-Object -First 1) } catch { $top = $null }
  finally { $ErrorActionPreference = $prevEAP }
  if ($top) { $ProjectRoot = "$top".Trim() } else { $ProjectRoot = (Get-Location).Path }
}
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
$RepoRoot = $ProjectRoot
Set-Location $RepoRoot
$HarnessDir = Join-Path $ProjectRoot 'harness'   # per-project config + gitignored runtime (.runs, .worktrees)
$ConfigPath = Join-Path $HarnessDir 'harness.config.json'
if (-not (Test-Path $ConfigPath)) { throw "Missing $ConfigPath. Run /harness-init first." }
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

. (Join-Path $PSScriptRoot 'lib/gate.ps1')
. (Join-Path $PSScriptRoot 'lib/checkpoint.ps1')   # Assert-CleanGitTree
. (Join-Path $PSScriptRoot 'lib/budget.ps1')       # Get-LoopRunId (atomic run-dir claim)
. (Join-Path $PSScriptRoot 'lib/fleet.ps1')
. (Join-Path $PSScriptRoot 'lib/invoke-codex.ps1')   # codex invocation (Test-CodexAvailable, Invoke-Codex)
. (Join-Path $PSScriptRoot 'lib/dispatch.ps1')       # Invoke-Phase: primary->fallback dispatcher (workers re-source it in-job)

$parallelCfg   = Get-Prop $cfg 'parallel'
$maxWorkers    = Get-Prop $parallelCfg 'maxWorkers'; if (-not $maxWorkers) { $maxWorkers = 3 }
if ($PSBoundParameters.ContainsKey('MaxWorkers')) { $maxWorkers = $MaxWorkers }
$workerTurns   = Get-Prop $parallelCfg 'workerMaxTurns'
if (-not $workerTurns) { $workerTurns = Get-Prop $cfg.autonomy 'maxTurnsPerIteration' }
if (-not $workerTurns) { $workerTurns = 40 }
$workerTimeout = Get-Prop $parallelCfg 'workerTimeoutSeconds'; if (-not $workerTimeout) { $workerTimeout = 3600 }
$implementModel = Resolve-PhaseModel $cfg 'implement'
$implementFallback = Resolve-PhaseFallback $cfg 'implement'   # cross-vendor fallback (e.g. 'codex'); '' = none — parity with the loop
$codexCfg = Get-Prop (Get-Prop $cfg 'models') 'codex'
$claudeCmd = if ($env:HARNESS_CLAUDE_CMD) { $env:HARNESS_CLAUDE_CMD } else { 'claude' }   # injectable for stub-driven queue tests (parity: fleet.sh)

# --- preflight -------------------------------------------------------------------
Assert-CleanGitTree
$manifestPath = Join-Path $RepoRoot 'state/tasks.json'
if (-not (Test-Path $manifestPath)) { throw "Missing state/tasks.json — run /plan first." }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$batch = @(Select-FleetTasks -Manifest $manifest -MaxWorkers $maxWorkers)
if ($batch.Count -eq 0) {
  Write-Host "No fleet-eligible tasks. Eligible = status todo/planned AND a non-empty 'files' ownership" -ForegroundColor Yellow
  Write-Host "list in state/tasks.json that doesn't overlap another picked task. /plan declares ownership." -ForegroundColor Yellow
  return
}
if ($batch.Count -eq 1) {
  Write-Host "Only 1 independent task — a fleet buys nothing over /work or the loop. Running anyway costs" -ForegroundColor Yellow
  Write-Host "worktree overhead for no parallelism; consider /work. Continuing in 5s (Ctrl-C to stop)..." -ForegroundColor Yellow
  Start-Sleep -Seconds 5
}

$runId   = Get-LoopRunId -RunsDir (Join-Path $HarnessDir '.runs')
$runDir  = Join-Path $HarnessDir ('.runs/' + $runId)
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$ledger  = Join-Path $runDir 'fleet-ledger.jsonl'
function Write-FleetLedger($obj) { ($obj | ConvertTo-Json -Compress) | Add-Content -Path $ledger -Encoding utf8 }

$baseRef = (& git rev-parse HEAD).Trim()
$wtRoot  = Join-Path $HarnessDir '.worktrees'
New-Item -ItemType Directory -Force -Path $wtRoot | Out-Null

# Run git silenced and return its exit code. NEEDED under EAP=Stop on PS 5.1: git routinely writes
# progress to stderr ("Preparing worktree ..."), which gets wrapped in a NativeCommandError and
# thrown BEFORE the exit code is read — even when redirected to $null (same class of bug gate.ps1
# guards against for gate steps).
function _Git([string[]]$GitArgs) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & git @GitArgs *> $null; return $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
}

Write-Host "🚁 Fleet $runId | $($batch.Count) worker(s) (max $maxWorkers) | base $($baseRef.Substring(0,8)) | model=$(if ($implementModel) { $implementModel } else { 'inherit' })" -ForegroundColor Cyan
foreach ($t in $batch) {
  Write-Host ("   - {0}: {1}  [owns: {2}]" -f (Get-Prop $t 'id'), (Get-Prop $t 'description'), ((@(Get-Prop $t 'files')) -join ', ')) -ForegroundColor DarkGray
}

function New-WorkerPrompt($Task) {
  $files = (@(Get-Prop $Task 'files')) -join "`n  - "
  $steps = (@(Get-Prop $Task 'steps')) -join "`n  - "
  @"
You are ONE worker in a parallel fleet. Other agents are building other tasks in sibling worktrees
right now. Implement exactly ONE task, fully, in THIS worktree.

TASK $(Get-Prop $Task 'id') (component: $(Get-Prop $Task 'component')): $(Get-Prop $Task 'description')
Steps:
  - $steps
Acceptance: $(Get-Prop $Task 'acceptance')

FILE OWNERSHIP — you may create/modify files ONLY under:
  - $files
Everything else belongs to another agent. Touching a file outside your ownership causes a merge
conflict that voids your work. If the task genuinely requires an unowned file, STOP and write why to
FLEET_NOTES.md in the repo root instead.

Rules:
1. Study first: CLAUDE.md, the relevant specs/, AGENT_NOTES.md. Search before assuming.
2. Full implementation — no placeholders, no stubs. Never weaken or delete a test. specs/ is locked.
3. Before finishing, run your component's gate commands (harness/harness.config.json -> components):
   format -> lint -> typecheck -> build -> test. Leave the gate green in this worktree.
4. Do NOT run git commit. Do NOT edit state/ files, AGENT_NOTES.md, harness/, or .claude/ — the fleet
   runner records results after your branch merges (parallel edits to shared files guarantee
   conflicts, and the merge queue rejects policy-file changes outright).
5. If blocked or the task is ambiguous, write the question to FLEET_NOTES.md and stop — don't guess.
"@
}

# --- spawn workers ----------------------------------------------------------------
$workers = @()
foreach ($t in $batch) {
  $tid    = [string](Get-Prop $t 'id')
  $branch = "fleet/$runId/$tid"
  $wtPath = Join-Path $wtRoot "$runId-$tid"
  if ((_Git @('worktree', 'add', '-b', $branch, $wtPath, $baseRef)) -ne 0) { throw "git worktree add failed for $tid" }
  $logPath = Join-Path $runDir "fleet-$tid.log"
  if ($DryRun) {
    $dryModel = if ($implementModel) { " --model $implementModel" } else { '' }
    $dryFallback = if ($implementFallback) { " (fallback: $implementFallback)" } else { '' }
    Write-Host "[dry-run] would run in $wtPath : claude -p --max-turns $workerTurns$dryModel$dryFallback" -ForegroundColor DarkGray
    $workers += [pscustomobject]@{ Task = $t; Id = $tid; Branch = $branch; Path = $wtPath; Job = $null; Log = $logPath }
    continue
  }
  # Route the worker build through the SAME dispatcher the loop uses (Invoke-Phase, workspace-write): the
  # primary model runs, and ONLY on codex-unavailability or a usage-limit failure does it retry on the
  # fallback — resetting THIS worktree to the batch base ($baseRef) first (Set-Location $wt below, so the
  # write-phase reset runs inside the worktree, exactly like the loop). A fresh Start-Job runspace does NOT
  # inherit the parent's dot-sourced functions, so the job re-sources the libs itself. -Quiet: inside a job,
  # Out-Host output is replayed to the parent console at Receive-Job time and can't be redirected away — the
  # tee still writes $logPath, so the worker stays file-only (no transcript spam in the merge queue).
  $extra = @()
  if ($cfg.autonomy.mode -eq 'auto' -and (Get-Prop $cfg.autonomy 'skipPermissions')) { $extra += '--dangerously-skip-permissions' }
  $libDir = Join-Path $PSScriptRoot 'lib'
  $prompt = New-WorkerPrompt $t
  $job = Start-Job -ScriptBlock {
    param($libDir, $wt, $p, $log, $cmd, $primary, $fallback, $codexCfg, $baseRef, $turns, $extra)
    $ErrorActionPreference = 'Stop'; Set-StrictMode -Version Latest
    Set-Location $wt
    $env:HARNESS_LOCK_SPECS = '1'
    . (Join-Path $libDir 'gate.ps1')          # Get-Prop, Test-UsageLimitError
    . (Join-Path $libDir 'invoke-codex.ps1')  # Test-CodexAvailable, Invoke-Codex
    . (Join-Path $libDir 'dispatch.ps1')      # Invoke-Phase
    $ph = Invoke-Phase -Mode 'workspace-write' -Prompt $p -RepoRoot $wt -LogPath $log `
            -Primary $primary -Fallback $fallback -CodexCfg $codexCfg -ResetRef $baseRef `
            -MaxTurns $turns -ClaudeExtraArgs $extra -ClaudeCommand $cmd -Quiet
    if ($ph.Ok) { 0 } else { 1 }   # the job's only output object -> the merge queue reads it as the worker exit
  } -ArgumentList $libDir, $wtPath, $prompt, $logPath, $claudeCmd, $implementModel, $implementFallback, $codexCfg, $baseRef, $workerTurns, $extra
  $workers += [pscustomobject]@{ Task = $t; Id = $tid; Branch = $branch; Path = $wtPath; Job = $job; Log = $logPath }
  Write-Host "  ▶ worker $tid started in $wtPath" -ForegroundColor Cyan
}

if ($DryRun) {
  foreach ($w in $workers) { $null = _Git @('worktree', 'remove', '--force', $w.Path); $null = _Git @('branch', '-D', $w.Branch) }
  Write-Host "[dry-run] cleaned up worktrees. No model invoked." -ForegroundColor DarkGray
  return
}

$null = Wait-Job -Job @($workers | ForEach-Object { $_.Job }) -Timeout $workerTimeout

# --- serialized merge queue --------------------------------------------------------
# Paths whose change in a fleet branch is policy tampering, never a task: park the branch outright.
# Must cover everything the worker prompt promises is rejected: specs, the harness engine + config,
# ALL shared state (a worker marking other tasks done in tasks.json would otherwise merge and be
# persisted by the runner's own record step), the prompt, and the notes file.
$protected = @('specs/', 'harness/', 'state/', '.claude/', 'PROMPT.md', 'AGENT_NOTES.md')
$merged = @(); $parked = @()
function _Park($w, [string]$why) {
  Write-Host "  🅿 parked $($w.Id): $why (branch $($w.Branch) kept for inspection)" -ForegroundColor Yellow
  Write-FleetLedger @{ task = $w.Id; result = 'parked'; why = $why; branch = $w.Branch }
  $script:parked += , @{ w = $w; why = $why }
}

foreach ($w in $workers) {
  Write-Host "`n── merge queue: $($w.Id) ──" -ForegroundColor Cyan
  # Surface the worker's escalation channel whatever happens next (parked workers need it most).
  $notesFile = Join-Path $w.Path 'FLEET_NOTES.md'
  if (Test-Path $notesFile) {
    Add-Content -Path (Join-Path $RepoRoot 'state/handoff.md') -Encoding utf8 -Value `
      ("`n## Fleet $runId — notes from worker $($w.Id)`n" + (Get-Content $notesFile -Raw))
  }
  if ($w.Job.State -ne 'Completed') {
    Stop-Job $w.Job -ErrorAction SilentlyContinue
    _Park $w "worker did not finish within ${workerTimeout}s"
    continue
  }
  $workerExit = @(Receive-Job $w.Job -ErrorAction SilentlyContinue) | Select-Object -Last 1
  if ("$workerExit" -ne '0' -and "$workerExit" -ne '') {
    _Park $w "worker claude exited $workerExit (see $($w.Log))"
    continue
  }
  # Commit the worker's result inside its worktree (workers never commit themselves).
  $null = _Git @('-C', $w.Path, 'add', '-A')
  $staged = & git -C $w.Path diff --cached --name-only
  if (-not $staged) { _Park $w 'worker produced no changes'; continue }
  $bad = @($staged | Where-Object {
      $f = $_ -replace '\\', '/'
      # @() around the inner filter: a single match unwraps to a scalar and .Count throws under StrictMode.
      (@($protected | Where-Object { $f -like "$_*" -or $f -eq $_.TrimEnd('/') })).Count -gt 0
    })
  if ($bad.Count -gt 0) { _Park $w "touched protected path(s): $($bad -join ', ')" ; continue }
  # A silent commit failure turns every downstream record fail-open — check it or park (ratchet).
  if ((_Git @('-C', $w.Path, 'commit', '-m', "fleet($($w.Id)): worker build")) -ne 0) {
    _Park $w 'worker-worktree commit failed (identity/hooks?)'
    continue
  }
  # Squash-merge onto the CURRENT tree (which advances as earlier queue entries land) and re-run the
  # full gate on the combined state — locally-green is not queue-green.
  $preMerge = (& git rev-parse HEAD).Trim()
  if ((_Git @('merge', '--squash', $w.Branch)) -ne 0) {
    $null = _Git @('reset', '--hard', $preMerge); $null = _Git @('clean', '-fd')
    _Park $w 'merge conflict with earlier queue entries — rebase/rerun this task after the batch'
    continue
  }
  Write-Host "  🔬 gate on combined state..." -ForegroundColor Cyan
  $gateOk = $false
  try { $gateOk = (Invoke-ProjectGate -Config $cfg -RepoRoot $RepoRoot).Passed } catch { $gateOk = $false }
  if (-not $gateOk) {
    $null = _Git @('reset', '--hard', $preMerge); $null = _Git @('clean', '-fd')
    _Park $w 'gate red on the combined state'
    continue
  }
  # Stage gate side effects too (a format step may have rewritten files — same reason the loop's
  # Commit-Iteration does add -A after the gate), then commit CHECKED: a squash that nets to zero, a
  # hook, or a missing identity must park, not silently "merge" and mis-record.
  $null = _Git @('add', '-A')
  if ((_Git @('commit', '-m', "fleet($($w.Id)): $(Get-Prop $w.Task 'description')`n`nAutomated by harness/fleet ($runId). Gate green on combined state.`nCo-Authored-By: Claude <noreply@anthropic.com>")) -ne 0) {
    $null = _Git @('reset', '--hard', $preMerge); $null = _Git @('clean', '-fd')
    _Park $w 'merge commit failed (empty squash or commit hook/identity)'
    continue
  }
  Write-Host "  ✔ merged + committed $($w.Id)" -ForegroundColor Green
  Write-FleetLedger @{ task = $w.Id; result = 'merged'; commit = (& git rev-parse HEAD).Trim() }
  $merged += , $w
  # Record: advance the manifest (runner-owned; workers must not touch state/).
  $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
  foreach ($mt in @($m.tasks)) {
    if ((Get-Prop $mt 'id') -eq $w.Id) {
      # Add-Member -Force: safe whether or not the property exists (a hand-written manifest task
      # missing `passes` would make a plain assignment throw under StrictMode, mid-queue).
      $mt | Add-Member -NotePropertyName status   -NotePropertyValue 'validated' -Force
      $mt | Add-Member -NotePropertyName passes   -NotePropertyValue $true       -Force
      $mt | Add-Member -NotePropertyName evidence -NotePropertyValue "harness/.runs/$runId/fleet-$($w.Id).log" -Force
    }
  }
  $m | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding utf8
  Add-Content -Path (Join-Path $RepoRoot 'state/PROGRESS.md') -Value ("- {0} fleet {1}: merged {2} (gate green on combined state)" -f (Get-Date -Format 'yyyy-MM-dd'), $runId, $w.Id) -Encoding utf8
  $null = _Git @('add', 'state/tasks.json', 'state/PROGRESS.md')
  if ((_Git @('commit', '--amend', '--no-edit')) -ne 0) {
    # Amend failed: the merge commit stands, but the state record isn't in it. Leaving the files merely
    # STAGED is unsafe — a LATER queue entry's merge-conflict/gate-red `reset --hard` (+ `clean -fd`) would
    # silently discard them while the ledger already says 'merged'. Persist the intended record to the run
    # dir (under harness/.runs — gitignored, so BOTH reset --hard and clean -fd skip it), restore the tracked
    # files so nothing is left staged for a later reset to eat, and ledger it so the morning routine can
    # reconcile pending-record-* against the 'merged' lines.
    $pendRel = "harness/.runs/$runId/pending-record-$($w.Id)"
    $pend    = Join-Path $runDir "pending-record-$($w.Id)"
    New-Item -ItemType Directory -Force -Path $pend | Out-Null
    Copy-Item (Join-Path $RepoRoot 'state/tasks.json')  (Join-Path $pend 'tasks.json')  -Force
    Copy-Item (Join-Path $RepoRoot 'state/PROGRESS.md') (Join-Path $pend 'PROGRESS.md') -Force
    $null = _Git @('checkout', 'HEAD', '--', 'state/tasks.json', 'state/PROGRESS.md')
    Write-FleetLedger @{ task = $w.Id; result = 'record-deferred'; pending = $pendRel }
    Write-Host "  ! record amend failed — merge commit stands; pending record saved to $pendRel (reconcile by hand)" -ForegroundColor Yellow
  }
  # Cleanup only what merged; parked branches/worktrees stay for a human.
  $null = _Git @('worktree', 'remove', '--force', $w.Path)
  $null = _Git @('branch', '-D', $w.Branch)
}

foreach ($w in $workers) { Remove-Job $w.Job -Force -ErrorAction SilentlyContinue }

# Parked tasks stop a human, not silently: surface them in the handoff.
if ($parked.Count -gt 0) {
  $note = "`n## Needs human decision — fleet $runId parked $($parked.Count) task(s)`n"
  foreach ($p in $parked) { $note += "- $($p.w.Id): $($p.why) — branch $($p.w.Branch), worktree $($p.w.Path), log $($p.w.Log)`n" }
  Add-Content -Path (Join-Path $RepoRoot 'state/handoff.md') -Value $note -Encoding utf8
}

Write-Host "`n🏁 Fleet $runId done: $($merged.Count) merged, $($parked.Count) parked. Ledger: $ledger" -ForegroundColor Cyan
Write-Host "   Merged work sits at 'validated' — run /review (fresh context) before you trust it." -ForegroundColor DarkGray
