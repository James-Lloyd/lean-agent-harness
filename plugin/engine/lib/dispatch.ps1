<#
  dispatch.ps1 — vendor-neutral phase dispatcher (S3). Runs a phase through a PRIMARY model and, ONLY
  on pre-invocation codex-unavailability or a usage/limit-flagged failure, retries once on a FALLBACK
  candidate (claude<->codex). Fail-closed on exhaustion. This is the single chokepoint the loop's
  implement call and periodic reviewer route through; it depends on gate.ps1 (Test-UsageLimitError,
  Get-Prop) and invoke-codex.ps1 (Test-CodexAvailable, Invoke-Codex), which the loop sources first.

  Discipline (CLAUDE.md ratchet + parent plan §1/§3b/§4c — mirror of dispatch.sh):
   - USAGE-LIMIT ONLY ON FAILURE. Test-UsageLimitError is consulted ONLY on a not-ok result. A SUCCESS
     is returned immediately and is NEVER re-examined for usage markers — a good build/review whose text
     merely mentions "overloaded"/"quota"/"429" must not be reset and discarded.
   - SCOPED FALLBACK. The fallback candidate is tried ONLY on (a) pre-invocation codex-unavailability or
     (b) a failed invocation that Test-UsageLimitError flags. A generic non-usage failure returns as a
     failure (Reason='invoke-failed') WITHOUT trying the fallback — the caller handles it as today.
   - WRITE-PHASE RESET. In workspace-write mode, hard-reset the tree to $ResetRef BEFORE a fallback
     candidate (a usage-limited primary may have left a partial tree). NEVER before the primary, NEVER in
     read-only mode. A successful write phase is NOT belt-and-braces reset (that would discard the build);
     the gate + autoRollbackOnRed are its safety net.
#>

# Run one claude headless phase. Prompt via STDIN (Windows PowerShell 5.1 corrupts embedded quotes in
# native args). Live streaming preserved via Tee-Object to $LogPath (no Out-String on the live pipe),
# then the text is read back for .Output; when $LogPath is empty the file tee is skipped. Runs under
# EAP='Continue' so claude's routine stderr doesn't throw under the caller's 'Stop'; the native exit is
# read explicitly from $LASTEXITCODE (a non-zero exit is not an exception). $Model '' => omit --model.
function Invoke-ClaudePhase {
  param(
    [string]$Model = '',
    [Parameter(Mandatory)][string]$Prompt,
    [string]$LogPath = '',
    [int]$MaxTurns = 40,
    [string[]]$ExtraArgs = @(),
    [string]$ClaudeCommand = 'claude',
    [switch]$Quiet   # swap the live Out-Host passthrough for Out-Null (fleet workers run inside Start-Job)
  )
  $a = @('-p', '--max-turns', "$MaxTurns")
  if ($ExtraArgs -and $ExtraArgs.Count -gt 0) { $a += $ExtraArgs }
  if ($Model) { $a += @('--model', "$Model") }
  $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $exit = 0; $out = ''
  try {
    if ($LogPath) {
      # Tee to the log for live capture, then Out-Host so the passthrough streams to the console WITHOUT
      # becoming this function's return value (a bare Tee inside a function would leak its strings into
      # the returned object). Read the text back from the log for .Output.
      # -Quiet swaps Out-Host -> Out-Null: inside a Start-Job (fleet worker), Out-Host output is replayed
      # to the parent console at Receive-Job time and cannot be suppressed by a stream redirect — Out-Null
      # keeps the tee (log) but drops the console replay. $LASTEXITCODE + the log read are unaffected.
      if ($Quiet) { $Prompt | & $ClaudeCommand @a *>&1 | Tee-Object -FilePath $LogPath | Out-Null }
      else        { $Prompt | & $ClaudeCommand @a *>&1 | Tee-Object -FilePath $LogPath | Out-Host }
      $exit = $LASTEXITCODE
      $out = if (Test-Path $LogPath) { (Get-Content $LogPath -Raw) } else { '' }
    } else {
      $out = ($Prompt | & $ClaudeCommand @a *>&1 | Out-String)
      $exit = $LASTEXITCODE
    }
  } catch {
    $exit = 1; $out = "$_"
  } finally { $ErrorActionPreference = $prevEAP }
  if ($null -eq $exit) { $exit = 0 }   # a cmdlet-only pipeline (empty $LogPath edge) leaves $LASTEXITCODE null
  return [pscustomobject]@{ Ok = ($exit -eq 0); Output = "$out"; Exit = $exit }
}

# The dispatcher. Returns a result object (see below). See the file header for the discipline it honors.
function Invoke-Phase {
  param(
    [Parameter(Mandatory)][ValidateSet('read-only','workspace-write')][string]$Mode,
    [Parameter(Mandatory)][string]$Prompt,
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$LogPath = '',
    [string]$Primary = '',                 # '' = inherit the ambient claude default (pre-routing behavior)
    [string]$Fallback = '',                # '' = no fallback candidate
    $CodexCfg = $null,
    [string]$ResetRef = '',                # iteration base; only used before a write-phase fallback
    [int]$MaxTurns = 40,
    [string[]]$ClaudeExtraArgs = @(),
    [string]$ClaudeCommand = '',           # injectable for tests; else $env:HARNESS_CLAUDE_CMD ?? 'claude'
    [string]$CodexCommand = 'codex',       # injectable for tests
    [switch]$Quiet                         # fleet workers pass -Quiet so Start-Job doesn't replay the transcript
  )
  $claudeCmd = if ($ClaudeCommand) { $ClaudeCommand } elseif ($env:HARNESS_CLAUDE_CMD) { $env:HARNESS_CLAUDE_CMD } else { 'claude' }
  $auth = [string](Get-Prop $CodexCfg 'auth'); if (-not $auth) { $auth = 'chatgpt' }
  $candidates = @($Primary)
  if ($Fallback) { $candidates += $Fallback }
  $lastOut = ''
  for ($idx = 0; $idx -lt $candidates.Count; $idx++) {
    $cand = [string]$candidates[$idx]
    $isFallback = ($idx -gt 0)
    if ($isFallback -and $Mode -eq 'workspace-write' -and $ResetRef) {
      # A usage-limited primary may have left a partial tree; reset to base before the fallback retry.
      $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      try { & git reset --hard $ResetRef *> $null; & git clean -fd *> $null } finally { $ErrorActionPreference = $prevEAP }
    }
    if ($cand -eq 'codex') {
      $vendor = 'codex'
      $avail = Test-CodexAvailable -Auth $auth -CodexCommand $CodexCommand
      if (-not $avail.Available) { $lastOut = "codex unavailable: $($avail.Reason)"; continue }   # (a) advance
      $res = Invoke-Codex -Mode $Mode -Prompt $Prompt -RepoRoot $RepoRoot -LogPath $LogPath -CodexCfg $CodexCfg -CodexCommand $CodexCommand
    } else {
      $vendor = 'claude'
      $res = Invoke-ClaudePhase -Model $cand -Prompt $Prompt -LogPath $LogPath -MaxTurns $MaxTurns -ExtraArgs $ClaudeExtraArgs -ClaudeCommand $claudeCmd -Quiet:$Quiet
    }
    if ($res.Ok) {
      # SUCCESS: return immediately — never re-examine a success for usage markers (ratchet).
      return [pscustomobject]@{ Ok = $true; Output = "$($res.Output)"; Path = $vendor; UsedFallback = $isFallback; Reason = '' }
    }
    $lastOut = "$($res.Output)"
    if (Test-UsageLimitError $res.Output) { continue }   # (b) usage-limit failure -> advance to the fallback
    # Generic (non-usage) failure: stop here, DON'T advance to the fallback.
    return [pscustomobject]@{ Ok = $false; Output = "$($res.Output)"; Path = $vendor; UsedFallback = $isFallback; Reason = 'invoke-failed' }
  }
  # Every candidate was unavailable or usage-limited: fail closed.
  return [pscustomobject]@{ Ok = $false; Output = "$lastOut"; Path = $null; UsedFallback = ($candidates.Count -gt 1); Reason = 'exhausted' }
}
