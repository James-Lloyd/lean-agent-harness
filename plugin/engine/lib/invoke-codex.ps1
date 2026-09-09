<#
  invoke-codex.ps1 — cross-vendor codex invocation for any routed phase. When a phase routes to
  "codex", the harness runs it through the OpenAI Codex CLI (a different training lineage — the
  Amp-Oracle pattern). Generalized in S2 from the review-only path: -Mode selects the sandbox, so the
  same lib serves READ-ONLY judge phases (review/evaluate) and WORKSPACE-WRITE writer phases
  (implement/plan/docs).

  Safety properties (mirror invoke-codex.sh):
   - SANDBOX per mode: 'read-only' for judge phases (`--sandbox read-only`), 'workspace-write' for
     writer phases (`--sandbox workspace-write`; the mutated tree flows through the gate +
     autoRollbackOnRed, which are the safety net - a write phase is NOT belt-and-braces reset, that
     would discard the build).
     THE SANDBOX ALONE DOES NOT HOLD, MEASURED. On codex-cli 0.153.4 the read-only sandbox let an
     apply_patch through and the judge WROTE A FILE, because the approval policy was still
     `on-request`: `codex exec` rejects --ask-for-approval outright, and passed globally it parses
     without binding. With `-c approval_policy="never"` (now emitted after `exec`) the identical
     write was refused. Two consequences worth keeping: the caller's post-review hard reset is not
     ornamental - it is what protected the tree while this was broken - and any future change to the
     approval/sandbox args must be re-live-fired, not reasoned about.
     Evidence: state/evidence/2026-09-09-codex-invoke-live-fire/.
   - EXTERNAL WATCHDOG: codex exec has NO --max-turns/--timeout of its own, so the invocation runs
     in a background job bounded by models.codex.timeoutSeconds (default 900). Expiry stops the job
     and the caller fails closed (no verdict => stop for a human). Caveat: stopping the job can
     orphan the codex child process on Windows; rare (watchdog expiry only) and it holds no locks.
   - OUTPUT from --output-last-message (final message text only), parsed by the same fail-closed
     Get-ReviewVerdict as the claude path. Exit codes are never trusted as verdicts.
#>

# Is codex usable right now? Returns @{ Available; Reason }. Auth 'chatgpt' probes `codex login
# status` (exit 0 = signed in; known false-negative with Azure/custom model providers — if you hit
# that, point that phase at a claude model instead). Auth 'api-key' requires CODEX_API_KEY.
# $CodexCommand is injectable so the self-tests can exercise both branches without codex installed.
function Test-CodexAvailable {
  param([string]$Auth = 'chatgpt', [string]$CodexCommand = 'codex')
  if (-not (Get-Command $CodexCommand -ErrorAction SilentlyContinue)) {
    return [pscustomobject]@{ Available = $false; Reason = 'codex CLI not found' }
  }
  if ($Auth -eq 'api-key') {
    if (-not $env:CODEX_API_KEY) { return [pscustomobject]@{ Available = $false; Reason = 'CODEX_API_KEY not set' } }
    return [pscustomobject]@{ Available = $true; Reason = '' }
  }
  $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & $CodexCommand login status *> $null; $ok = ($LASTEXITCODE -eq 0) }
  catch { $ok = $false }
  finally { $ErrorActionPreference = $prevEAP }
  if (-not $ok) { return [pscustomobject]@{ Available = $false; Reason = 'codex not signed in (run: codex login)' } }
  return [pscustomobject]@{ Available = $true; Reason = '' }
}

# Pure arg-builder — the single source of truth for codex's argv, unit-tested directly (no codex
# install, no watchdog). Mode selects the sandbox: 'read-only' for judge phases (never mutate what
# you judge), 'workspace-write' for implement/plan/docs (mutate the tree; the gate + autoRollbackOnRed
# are the safety net — see plan §3b). Global flags go BEFORE `exec`: measured on 0.153.4, `codex exec`
# rejects `--ask-for-approval` outright (exit 2), while `--sandbox` is accepted in both slots and does
# propagate from the global one. The approval POLICY, however, only binds via `-c` after `exec` — see below.
function Get-CodexArgs {
  param(
    [Parameter(Mandatory)][ValidateSet('read-only','workspace-write')][string]$Mode,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$LastMessagePath,
    [string]$Model, [string]$Effort
  )
  # THE APPROVAL POLICY MUST GO THROUGH -c, NOT THE FLAG - ON THIS VERSION. Measured on codex-cli
  # 0.153.4 (state/evidence/2026-09-09-codex-invoke-live-fire/): `codex exec` REJECTS
  # --ask-for-approval outright ("unexpected argument", exit 2), so the flag can only be passed
  # globally - where on 0.153.4 it PARSES BUT DOES NOT TAKE EFFECT: every exec transcript header in
  # that dir reads `approval: on-request`. With on-request and no human to ask, a READ-ONLY judge's
  # apply_patch went through and mutated the tree; `-c approval_policy="never"` flips the header to
  # `approval: never` and the same write is refused, while workspace-write still writes.
  # THE GLOBAL FLAG IS KEPT BECAUSE IT DID BIND ON 0.144.3 - see
  # state/evidence/2026-07-14-cross-vendor-s3/live-codex-readonly.log, whose header reads
  # `approval: never` with only the global flag passed. So this is a version regression, not a
  # permanent property, and both spellings are pinned by the suites' arg-order assertions.
  $a = @('--sandbox', $Mode, '--ask-for-approval', 'never',
         'exec', '-', '--cd', $RepoRoot, '--skip-git-repo-check',
         '--output-last-message', $LastMessagePath,
         '-c', 'approval_policy="never"')
  if ($Model)  { $a += @('-m', "$Model") }
  if ($Effort) { $a += @('-c', ('model_reasoning_effort="{0}"' -f $Effort)) }
  # Emit the argv elements to the pipeline (not ,$a): every caller collects with @(...), and argv always
  # has many elements, so unrolling yields a flat array — ,$a would nest it one level deep inside @().
  return $a
}

# Run one codex invocation in $Mode. Returns @{ Ok = bool; Output = string }: Output is the final
# assistant message (the verdict text for a judge phase) when codex wrote one, else the full log tail.
# Full transcript goes to $LogPath either way. -Mode selects read-only (judge) vs workspace-write (writer).
function Invoke-Codex {
  param(
    [Parameter(Mandatory)][ValidateSet('read-only','workspace-write')][string]$Mode,
    [Parameter(Mandatory)][string]$Prompt,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$LogPath,
    $CodexCfg,                                   # effective codex settings for the phase (Resolve-PhaseCodexCfg: the phase's codex{} over models.codex; may be $null — all defaults)
    [string]$CodexCommand = 'codex'
  )
  $model   = Get-Prop $CodexCfg 'model'
  $effort  = Get-Prop $CodexCfg 'reasoningEffort'
  $timeout = Get-Prop $CodexCfg 'timeoutSeconds'; if (-not $timeout) { $timeout = 900 }
  $stamp      = [System.IO.Path]::GetRandomFileName()
  $promptFile = Join-Path ([System.IO.Path]::GetTempPath()) "codex-prompt-$stamp.txt"
  $lastMsg    = Join-Path ([System.IO.Path]::GetTempPath()) "codex-verdict-$stamp.txt"
  # No-BOM UTF-8: codex reads stdin bytes verbatim; a BOM would prepend junk to the prompt.
  [System.IO.File]::WriteAllText($promptFile, $Prompt, (New-Object System.Text.UTF8Encoding($false)))
  $codexArgs = @(Get-CodexArgs -Mode $Mode -RepoRoot $RepoRoot -LastMessagePath $lastMsg -Model "$model" -Effort "$effort")
  # Background job as the watchdog: `& codex` inside the job resolves npm's .cmd shim correctly
  # (System.Diagnostics.Process would not), and Wait-Job gives us the timeout.
  $job = Start-Job -ScriptBlock {
    param($pf, $cmd, $argList)
    $out = (Get-Content -LiteralPath $pf -Raw | & $cmd @argList 2>&1 | Out-String)
    [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE }
  } -ArgumentList $promptFile, $CodexCommand, $codexArgs
  $ok = $false; $out = ''
  try {
    if (Wait-Job $job -Timeout $timeout) {
      $res = Receive-Job $job
      $out = "$($res.Out)"
      $ok = ($res.Exit -eq 0)
      if (-not $ok) { $out += "`n[codex exited $($res.Exit)]" }
    } else {
      Stop-Job $job -ErrorAction SilentlyContinue
      $out = "[codex timed out after ${timeout}s — watchdog kill, failing closed]"
    }
  } finally {
    Remove-Job $job -Force -ErrorAction SilentlyContinue
  }
  Set-Content -Path $LogPath -Value $out -Encoding utf8
  # Prefer the final-message file: it is exactly the reviewer's closing text (where the VERDICT
  # protocol puts the verdict), immune to transcript noise.
  $final = ''
  if (Test-Path $lastMsg) { $final = (Get-Content -LiteralPath $lastMsg -Raw -ErrorAction SilentlyContinue) }
  Remove-Item $promptFile, $lastMsg -ErrorAction SilentlyContinue
  if ($final) { return [pscustomobject]@{ Ok = $ok; Output = "$final" } }
  return [pscustomobject]@{ Ok = $ok; Output = $out }
}
