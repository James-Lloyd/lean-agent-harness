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
  [string] $ProjectRoot,
  [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Prompts are piped to `claude` via STDIN (see the invocation notes below). Under Windows PowerShell 5.1
# the default $OutputEncoding for native pipes is ASCII — pin UTF-8 so PROMPT.md's non-ASCII survives.
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# --- locate engine, project root & config -------------------------------------
# Engine files (this script + lib/) resolve off $PSScriptRoot. PROJECT files (config, runtime, git)
# resolve off $ProjectRoot — a DISTINCT location once this engine ships from an installed plugin dir.
# Discovery: -ProjectRoot wins; else the git top-level of the current dir; else the current dir. In the
# in-repo layout the two roots coincide (harness/ sits one level under the repo), so paths are unchanged.
if (-not $ProjectRoot) {
  $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $top = (& git rev-parse --show-toplevel 2>$null | Select-Object -First 1) } catch { $top = $null }
  finally { $ErrorActionPreference = $prevEAP }
  if ($top) { $ProjectRoot = "$top".Trim() } else { $ProjectRoot = (Get-Location).Path }
}
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
$RepoRoot = $ProjectRoot
Set-Location $RepoRoot
$HarnessDir = Join-Path $ProjectRoot 'harness'   # per-project config + gitignored runtime (.runs, etc.)
$ConfigPath = Join-Path $HarnessDir 'harness.config.json'
if (-not (Test-Path $ConfigPath)) { throw "Missing $ConfigPath. Run /harness-init first." }
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# CLI overrides win over config file
if ($Mode)          { $cfg.autonomy.mode = $Mode }
if ($PSBoundParameters.ContainsKey('MaxIterations')) { $cfg.autonomy.maxIterations = $MaxIterations }

. (Join-Path $PSScriptRoot 'lib/gate.ps1')        # also provides Get-Prop (StrictMode-safe accessor)
. (Join-Path $PSScriptRoot 'lib/checkpoint.ps1')
. (Join-Path $PSScriptRoot 'lib/budget.ps1')
. (Join-Path $PSScriptRoot 'lib/invoke-codex.ps1')   # codex invocation (Test-CodexAvailable, Invoke-Codex) — dispatch.ps1 builds on it
. (Join-Path $PSScriptRoot 'lib/dispatch.ps1')       # Invoke-Phase: primary->fallback dispatcher (after gate + invoke-codex)

$runId  = Get-LoopRunId -RunsDir (Join-Path $HarnessDir '.runs')   # atomically claims <project>/harness/.runs/<runId>/ (mkdir-as-mutex)
$runDir = Join-Path $HarnessDir ('.runs/' + $runId)
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$ledgerPath = Join-Path $runDir 'ledger.jsonl'
# Per-run state files: two concurrent runs must not share a rollback ref or a budget tally.
Set-CheckpointFile (Join-Path $runDir '.checkpoint')
Set-BudgetFile     (Join-Path $runDir '.budget.json')
Reset-Budget   # tokenBudget is a per-run cap, not a lifetime counter

# Tamper-pin: the agent must not rewrite its own gate/policy. We hash the config at start and abort an
# iteration whose run changed it (settings.json also denies writes to it; this is the belt to that braces).
function Get-ConfigHash { (Get-FileHash $ConfigPath -Algorithm SHA256).Hash }
$configHash0 = Get-ConfigHash

function Write-Ledger($obj) { ($obj | ConvertTo-Json -Compress) | Add-Content -Path $ledgerPath -Encoding utf8 }

function Confirm-Checkpoint([string]$label) {
  if ($cfg.autonomy.mode -eq 'auto') { return $true }   # auto never blocks
  Write-Host "`n⏸  Checkpoint: $label" -ForegroundColor Yellow
  # Read-Host throws under -NonInteractive / closed stdin — treat that as "no" (stop cleanly), matching
  # loop.sh's /dev/tty-EOF fallback, instead of dying mid-run with an unhandled exception.
  $ans = ''
  try { $ans = Read-Host "   Continue? [y/N]" } catch { Write-Host "   (non-interactive: treating as No)" -ForegroundColor DarkGray; return $false }
  return ($ans -match '^(y|yes)$')
}

function Get-OpenItemCount {
  $planFile = Get-Prop (Get-Prop $cfg 'loop') 'planFile'; if (-not $planFile) { $planFile = 'state/fix_plan.md' }
  $plan = Join-Path $RepoRoot $planFile
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
  param([string]$Base, [string]$RunDir, [int]$Iter, [string]$Fallback, [string]$Route, $CodexCfg)
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
3. List findings as  file:line — problem — concrete fix. Report ONLY findings that affect correctness
   vs the spec, evidence integrity, or the guardrails. Do NOT manufacture style/architecture
   suggestions to justify the review — a reviewer told to find problems always will, and invented
   findings cause over-engineering churn. "No findings" is a valid outcome: SHIP it.

Finish with EXACTLY ONE final line and nothing after it:
VERDICT: SHIP     (the batch is sound)
VERDICT: REJECT   (anything is wrong — default to REJECT when unsure)
"@
  $reviewLog = Join-Path $RunDir ("review-after-$Iter.log")
  # Route the judge through the cross-vendor dispatcher (Invoke-Phase, READ-ONLY): -Primary is the
  # resolved review model (e.g. 'codex' => codex read-only sandbox; a claude alias => that reviewer; '' =>
  # inherit), -Fallback the S1b-symmetric claude reviewer model. Net effect: the review path now ALSO
  # falls back to the claude reviewer on a codex USAGE-LIMIT (not just pre-invocation unavailability),
  # while preserving the unavailable->claude path. Disallowed tools as SEPARATE args (a space-joined
  # string is one never-matching pattern); Bash stays enabled — the reviewer needs `git log`/`git diff`;
  # the hard reset below undoes any mutation. Prompt via STDIN (PS 5.1 mangles embedded quotes).
  $phase = Invoke-Phase -Mode 'read-only' -Prompt $reviewPrompt -RepoRoot $RepoRoot -LogPath $reviewLog `
                        -Primary $Route -Fallback $Fallback -CodexCfg $CodexCfg -MaxTurns 20 `
                        -ClaudeExtraArgs @('--disallowedTools', 'Edit', 'Write', 'MultiEdit', 'NotebookEdit')
  $reviewPath = if ($phase.Path) { $phase.Path } else { 'claude' }
  $invokeOk = [bool]$phase.Ok; $out = "$($phase.Output)"
  # A judge must not mutate the artifact: restore the tree to exactly the reviewed HEAD, no matter what.
  # (Codex ran in a read-only sandbox, but belt + braces — identical to the claude path.)
  & git reset --hard $head *> $null
  & git clean -fd *> $null
  if (-not $invokeOk) {
    Write-Host "  ! review invocation failed ($reviewPath) — failing closed (stopping for human)." -ForegroundColor Red
    Write-Ledger @{ iter = $Iter; result = 'review'; path = $reviewPath; verdict = 'ERROR' }
    Write-Reject-Handoff -Reason "review could not run ($reviewPath)" -Base $Base -Head $head -Iter $Iter -Log $reviewLog
    return $false
  }
  # Fail-closed verdict parse: only the LAST line starting with VERDICT: counts (Get-ReviewVerdict in
  # lib/gate.ps1). A preamble like "I cannot give VERDICT: SHIP" must never pass the batch.
  $verdict = Get-ReviewVerdict $out
  Write-Ledger @{ iter = $Iter; result = 'review'; path = $reviewPath; verdict = "$verdict" }
  if ($verdict -eq 'SHIP') {
    Write-Host "  🟢 Periodic review: SHIP." -ForegroundColor Green
    # NB: the harness-reviewed watermark tag is advanced by the CALLER, only after BOTH the reviewer AND
    # (when enabled) the evaluator pass — otherwise a reviewer-SHIP-then-evaluator-FAIL batch would be
    # tagged "reviewed" while the loop stops like a REJECT, hiding rejected work from a later /review.
    return $true
  }
  $reason = if ($verdict -eq 'REJECT') { 'REJECT' } else { 'no clear SHIP verdict (fail-closed)' }
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

# Periodic EVALUATION at the review point: when verification.evaluator.enabled, AFTER the fresh-context
# reviewer returns SHIP the loop also scores the SAME $Base..HEAD batch against the rubric. Shape parallels
# Invoke-PeriodicReview: READ-ONLY (--disallowedTools + a hard reset afterward) so the judge can't mutate
# what it judges, and FAILS CLOSED — only a clean PASS (verdict PASS AND every criterion >= failBelow via
# Get-EvaluatorVerdict) continues; a FAIL, no clear verdict, a truncated/crashed run, or ANY sub-threshold
# score stops the loop exactly like a REJECT (reject-handoff + ledger). Returns $true to continue; $false
# to stop the loop for human attention.
function Invoke-PeriodicEvaluation {
  param([string]$Base, [string]$RunDir, [int]$Iter, [string]$Route, [string]$Fallback, $CodexCfg,
        [string]$Rubric, [int]$FailBelow)
  $head = "$(& git rev-parse HEAD)".Trim()
  if ($Base -eq $head) { Write-Host "  (periodic evaluation: no new commits since last review)" -ForegroundColor DarkGray; return $true }
  Write-Host "🧮  Periodic evaluator scoring commits $(_Short $Base)..$(_Short $head) against $Rubric..." -ForegroundColor Cyan
  $evalPrompt = @"
You are a SKEPTICAL EVALUATOR (the harness 'evaluator' role — see .claude/agents/evaluator.md). You have
NO memory of how this code was written; judge only the artifact. You are READ-ONLY — do not edit, write,
or commit anything.

1. Read the scoring rubric at:  $Rubric
2. Inspect the batch:  git log --oneline $Base..HEAD   and   git diff $Base..HEAD
3. Check the work against specs/ (acceptance criteria) and the captured end-to-end evidence under
   state/evidence/. Exercise that evidence READ-ONLY where you can (read logs/outputs; run only
   non-mutating commands). A guardrail breach (weakened/deleted tests, edited specs, destructive ops,
   secrets) caps the sprint regardless of other scores.
4. Score EVERY applicable criterion 0-10 with a one-line justification, applying the hard threshold
   failBelow=${FailBelow}: ANY criterion below $FailBelow => the sprint FAILS.

Output EXACTLY the rubric's format — the per-criterion N/10 scores — and finish with EXACTLY ONE final
line and nothing after it:
VERDICT: PASS     (every applicable criterion scored >= $FailBelow, no guardrail breach)
VERDICT: FAIL     (any criterion below $FailBelow, any guardrail breach, or unsure)
"@
  $evalLog = Join-Path $RunDir ("evaluate-after-$Iter.log")
  # Route the judge through the cross-vendor dispatcher (Invoke-Phase, READ-ONLY) exactly like the reviewer:
  # -Primary the resolved evaluate model, -Fallback its claude fallback; disallowed write tools as SEPARATE
  # args; Bash stays enabled (the judge needs git log/diff + read-only evidence commands); the hard reset
  # below undoes any mutation. Prompt via STDIN (PS 5.1 mangles embedded quotes).
  $phase = Invoke-Phase -Mode 'read-only' -Prompt $evalPrompt -RepoRoot $RepoRoot -LogPath $evalLog `
                        -Primary $Route -Fallback $Fallback -CodexCfg $CodexCfg -MaxTurns 20 `
                        -ClaudeExtraArgs @('--disallowedTools', 'Edit', 'Write', 'MultiEdit', 'NotebookEdit')
  $evalPath = if ($phase.Path) { $phase.Path } else { 'claude' }
  $invokeOk = [bool]$phase.Ok; $out = "$($phase.Output)"
  # A judge must not mutate the artifact: restore the tree to exactly the evaluated HEAD, no matter what.
  & git reset --hard $head *> $null
  & git clean -fd *> $null
  if (-not $invokeOk) {
    Write-Host "  ! evaluator invocation failed ($evalPath) — failing closed (stopping for human)." -ForegroundColor Red
    Write-Ledger @{ iter = $Iter; result = 'evaluate'; path = $evalPath; verdict = 'ERROR' }
    Write-Reject-Handoff -Reason "evaluator could not run ($evalPath)" -Base $Base -Head $head -Iter $Iter -Log $evalLog
    return $false
  }
  # Fail-closed parse + belt-and-braces threshold scan (Get-EvaluatorVerdict in lib/gate.ps1): any
  # sub-threshold N/10 overrides a PASS summary.
  $verdict = Get-EvaluatorVerdict $out $FailBelow
  Write-Ledger @{ iter = $Iter; result = 'evaluate'; path = $evalPath; verdict = "$verdict" }
  if ($verdict -eq 'PASS') {
    Write-Host "  🟢 Periodic evaluation: PASS." -ForegroundColor Green
    return $true
  }
  $reason = if ($verdict -eq 'FAIL') { 'evaluator FAIL (below-threshold criterion)' } else { 'no clear PASS verdict (fail-closed)' }
  Write-Host "  🔴 Periodic evaluation: $reason. Stopping for human attention." -ForegroundColor Red
  Write-Reject-Handoff -Reason $reason -Base $Base -Head $head -Iter $Iter -Log $evalLog
  return $false
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
# Get-Prop throughout: a trimmed config (project without type, verification pruned) must degrade to
# defaults under StrictMode, not throw PropertyNotFoundException at preflight.
$projType = Get-Prop (Get-Prop $cfg 'project') 'type'; if (-not $projType) { $projType = 'greenfield' }
$maxTurns = Get-Prop $cfg.autonomy 'maxTurnsPerIteration'; if (-not $maxTurns) { $maxTurns = 40 }
$reviewEveryN = Get-Prop (Get-Prop $cfg 'verification') 'reviewEveryNIterations'; if (-not $reviewEveryN) { $reviewEveryN = 0 }
# Per-phase model routing (config.models). '' = inherit the ambient CLI default (pre-routing behavior).
$implementModel      = Resolve-PhaseModel $cfg 'implement'
$implementFallback   = Resolve-PhaseFallback $cfg 'implement'     # cross-vendor fallback (e.g. 'codex'); '' = none
$reviewRoute         = Resolve-PhaseModel $cfg 'review'            # 'codex' | claude alias/ID | ''
$reviewFallback      = Resolve-PhaseFallback $cfg 'review'         # S1b: symmetric with the reviewFallback pseudo-phase
# Evaluator-at-review-point: when enabled it augments the SAME periodic review point (below), scoring the
# batch against the rubric. Route/fallback resolve through the 'evaluate' phase; rubric/threshold read
# StrictMode-safe via Get-Prop so a trimmed config degrades to defaults instead of throwing.
$evalCfg             = Get-Prop (Get-Prop $cfg 'verification') 'evaluator'
$evalEnabled         = [bool](Get-Prop $evalCfg 'enabled')
$evalRoute           = Resolve-PhaseModel $cfg 'evaluate'          # 'fable' | codex | claude alias/ID | ''
$evalFallback        = Resolve-PhaseFallback $cfg 'evaluate'
$evalRubric          = Get-Prop $evalCfg 'rubric'; if (-not $evalRubric) { $evalRubric = 'docs/principles/evaluator-rubric.md' }
$evalFailBelow       = Get-Prop $evalCfg 'failBelow'; if ($null -eq $evalFailBelow) { $evalFailBelow = 7 }
$codexCfg            = Get-Prop (Get-Prop $cfg 'models') 'codex'
$modelLabel = if ($implementModel) { $implementModel } else { 'inherit' }
Write-Host "🔧 Harness loop | type=$projType | mode=$($cfg.autonomy.mode) | maxIter=$($cfg.autonomy.maxIterations) | maxTurns=$maxTurns | model=$modelLabel | budget=$($cfg.autonomy.tokenBudget)" -ForegroundColor Cyan

if ($cfg.autonomy.mode -eq 'auto' -and (Get-Prop (Get-Prop $cfg 'verification') 'requireE2EEvidence') -and -not (Test-AnyE2E)) {
  Write-Host "⚠️  auto mode + requireE2EEvidence, but no e2e gate step is configured. The loop will commit on" -ForegroundColor Yellow
  Write-Host "    unit-green only. Add an e2e command to a component/root gate, or run /review periodically." -ForegroundColor Yellow
}

# Honest guard (mirrors the e2e/skipPermissions warnings): the evaluator augments the periodic review
# point, which is gated on BOTH reviewEveryNIterations>0 AND loop.commitOnGreen — with either off it can
# never fire. Read commitOnGreen inline via Get-Prop ($commitOnGreen is resolved later, below).
$commitOnGreenPre = [bool](Get-Prop (Get-Prop $cfg 'loop') 'commitOnGreen')
if ($evalEnabled -and (($reviewEveryN -le 0) -or (-not $commitOnGreenPre))) {
  $why = if ($reviewEveryN -le 0) { 'reviewEveryNIterations <= 0' } else { 'loop.commitOnGreen is false' }
  Write-Host "⚠️  verification.evaluator.enabled is true but $why — the evaluator augments the periodic" -ForegroundColor Yellow
  Write-Host "    review point (needs reviewEveryNIterations>0 AND commitOnGreen), so it will never run." -ForegroundColor Yellow
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
} else {
  # Headless children can't answer permission prompts: any Bash command NOT in permissions.allow is
  # auto-denied, so if the gate commands aren't allowlisted the agent can't run Phase 3 of PROMPT.md
  # and burns iterations editing blind. /harness-init appends them; remind here in case it didn't.
  Write-Host "ℹ️  Headless runs auto-deny non-allowlisted commands. Ensure the gate commands (test/build/lint)" -ForegroundColor DarkGray
  Write-Host "    are in .claude/settings.json permissions.allow (/harness-init adds them)." -ForegroundColor DarkGray
}

# Sandbox guard: full-auto runs UNATTENDED. The destructive-command deny-list is defense-in-depth, not a
# sandbox, so honestly warn (not block — Confirm-Checkpoint is a no-op in auto by design) when auto runs
# outside a recognized isolation profile. Test-Sandboxed lives in lib/gate.ps1 (already dot-sourced above).
if ($cfg.autonomy.mode -eq 'auto' -and -not (Test-Sandboxed)) {
  Write-Host ""
  Write-Host "⚠️  AUTO mode but NOT in a recognized SANDBOX. This run is full-auto and UNATTENDED." -ForegroundColor Red
  Write-Host "    Unattended auto should run inside the documented isolation profile (container/devcontainer or" -ForegroundColor Red
  Write-Host "    WSL2-native FS), not directly on your host. The destructive-command deny-list is defense-in-" -ForegroundColor Red
  Write-Host "    depth, NOT a sandbox — and --dangerously-skip-permissions voids it entirely." -ForegroundColor Red
  Write-Host "    See docs/sandboxing.md. Mark a sandbox explicitly with:  `$env:HARNESS_SANDBOX = '1'" -ForegroundColor Red
  Write-Host ""
}

# Lock specs/ for the duration of the run: the protect-specs PreToolUse hook (inherited by the headless
# claude child) blocks edits under specs/ while this is set. The loop must never rewrite the contract.
$env:HARNESS_LOCK_SPECS = '1'

# Resolve optional loop/autonomy keys via Get-Prop so a trimmed config (e.g. after /harness-prune) can't
# crash the loop under StrictMode — it degrades to the same defaults loop.sh uses.
$loopCfg          = Get-Prop $cfg 'loop'
$promptFile       = Get-Prop $loopCfg 'promptFile'; if (-not $promptFile) { $promptFile = 'PROMPT.md' }
$stopWhenEmpty    = [bool](Get-Prop $loopCfg 'stopWhenPlanEmpty')
$commitOnGreen    = [bool](Get-Prop $loopCfg 'commitOnGreen')
$tagOnGreen       = [bool](Get-Prop $loopCfg 'tagOnGreen')
$autoRollback     = [bool](Get-Prop $loopCfg 'autoRollbackOnRed')
$tokenBudget      = Get-Prop $cfg.autonomy 'tokenBudget'
$everyNIterations = Get-Prop (Get-Prop $cfg.autonomy 'checkpoints') 'everyNIterations'; if (-not $everyNIterations) { $everyNIterations = 0 }

$prompt = Get-Content (Join-Path $RepoRoot $promptFile) -Raw
$i = 0
$greenCount = 0
$reviewBaseRef = "$(& git rev-parse HEAD)".Trim()   # periodic-review watermark: commits after this are unreviewed
while ($i -lt $cfg.autonomy.maxIterations) {
  $i++
  if ($stopWhenEmpty -and (Get-OpenItemCount) -eq 0) {
    Write-Host "✅ fix_plan.md has no open items. Nothing to do — stopping." -ForegroundColor Green
    break
  }
  if ($null -ne $tokenBudget -and (Test-BudgetExceeded $tokenBudget)) {
    Write-Host "💸 Token budget (estimate) exhausted — stopping." -ForegroundColor Yellow
    break
  }
  $nEvery = $everyNIterations
  if ($nEvery -gt 0 -and ($i % $nEvery) -eq 0) {
    if (-not (Confirm-Checkpoint "Reached iteration $i")) { break }
  }

  Write-Host "`n──────── iteration $i / $($cfg.autonomy.maxIterations) ────────" -ForegroundColor Cyan
  $iterLog = Join-Path $runDir ("iter-$i.log")

  if ($DryRun) {
    $dryModel = if ($implementModel) { " --model $implementModel" } else { '' }
    Write-Host "[dry-run] would pipe PROMPT.md into: claude -p --max-turns $maxTurns$dryModel ; then run the gate." -ForegroundColor DarkGray
    break
  }

  New-Checkpoint -Label "pre-iter-$i"

  # --- invoke the implement phase through the cross-vendor dispatcher (Invoke-Phase) ---
  # The prompt goes via STDIN (Windows PowerShell 5.1 corrupts embedded quotes in native args); the
  # dispatcher's claude arm pipes it in (the documented `cat file | claude -p` pattern) and Tee's the
  # transcript to $iterLog. Extra args mirror today's conditions: skip-permissions under auto+
  # skipPermissions, JSON output when metering. Do NOT add --bare — the loop DEPENDS on hook/CLAUDE.md/
  # skill discovery (CLI docs say --bare becomes the -p default later; pin/revisit then, see ROADMAP).
  # The dispatcher runs $implementModel (primary) and, ONLY on codex-unavailability or a usage-limit
  # failure, the $implementFallback — hard-resetting the tree to this iteration's base ($baseRef) before
  # a write-phase fallback (a usage-limited primary may have left a partial tree). A generic (non-usage)
  # failure returns as failure and is handled exactly as today: roll back + continue.
  $extra = @()
  if ($cfg.autonomy.mode -eq 'auto' -and (Get-Prop $cfg.autonomy 'skipPermissions')) { $extra += '--dangerously-skip-permissions' }
  if (Get-Prop $cfg.autonomy 'meterTokens') { $extra += @('--output-format', 'json') }   # exact usage
  $baseRef = "$(& git rev-parse HEAD)".Trim()   # clean tree here (New-Checkpoint asserts it): the fallback reset target
  $phase = Invoke-Phase -Mode 'workspace-write' -Prompt $prompt -RepoRoot $RepoRoot -LogPath $iterLog `
                        -Primary $implementModel -Fallback $implementFallback -CodexCfg $codexCfg `
                        -ResetRef $baseRef -MaxTurns $maxTurns -ClaudeExtraArgs $extra
  if (-not $phase.Ok) {
    $reason = if ($phase.Reason) { $phase.Reason } else { 'invoke-failed' }
    Write-Host "❌ implement phase failed (path=$($phase.Path); reason=$reason) — treating the iteration as failed." -ForegroundColor Red
    Write-Ledger @{ iter = $i; result = 'invoke-error'; reason = "$reason"; path = "$($phase.Path)"; usedFallback = [bool]$phase.UsedFallback }
    Restore-Checkpoint; continue
  }
  Update-BudgetFromLog -LogPath $iterLog   # the dispatcher wrote the transcript to $iterLog

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
    if ($commitOnGreen) { Commit-Iteration -Index $i }
    if ($tagOnGreen)    { Tag-Iteration -Index $i -RunId $runId }
    Clear-Checkpoint
    Write-Ledger @{ iter = $i; result = 'green'; committed = $commitOnGreen; path = "$($phase.Path)"; usedFallback = [bool]$phase.UsedFallback }
    $greenCount++
    # Inferential judge, wired in: every N green iterations a fresh-context reviewer audits the batch.
    if ($reviewEveryN -gt 0 -and $commitOnGreen -and ($greenCount % $reviewEveryN) -eq 0) {
      $ok = Invoke-PeriodicReview -Base $reviewBaseRef -RunDir $runDir -Iter $i -Fallback $reviewFallback -Route $reviewRoute -CodexCfg $codexCfg
      # The evaluator augments the SAME review point: when enabled, only after the reviewer SHIPs do we
      # also score the batch against the rubric. Advance the watermark only when BOTH pass; any
      # below-threshold criterion stops the loop like a REJECT (Invoke-PeriodicEvaluation writes the handoff).
      if ($ok -and $evalEnabled) {
        $ok = Invoke-PeriodicEvaluation -Base $reviewBaseRef -RunDir $runDir -Iter $i -Route $evalRoute -Fallback $evalFallback -CodexCfg $codexCfg -Rubric $evalRubric -FailBelow $evalFailBelow
      }
      if ($ok) {
        $reviewBaseRef = "$(& git rev-parse HEAD)".Trim()   # advance the watermark past the reviewed batch
        & git tag -f harness-reviewed $reviewBaseRef *> $null   # both judges passed: mark reviewed for a later /review
      } else {
        Write-Ledger @{ iter = $i; result = 'review-stop' }
        break
      }
    }
  } else {
    Write-Host "🔴 Gate red: [$($gateResult.Component)] $($gateResult.FailedStep)." -ForegroundColor Red
    Write-Ledger @{ iter = $i; result = 'red'; component = "$($gateResult.Component)"; failedStep = "$($gateResult.FailedStep)"; path = "$($phase.Path)"; usedFallback = [bool]$phase.UsedFallback }
    if ($autoRollback) {
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
