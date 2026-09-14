#requires -Version 5.1
<#
  Deterministic timeout-transcript regression and real-loop rollback proof for Invoke-Codex.
  No model or network is used: a local stub writes one early line, mutates a tracked file, then
  remains alive beyond a one-second watchdog. -TimeoutOnly is used by the mutation runner.
#>
[CmdletBinding()]
param(
  [string]$InvokeLib = '',
  [string]$EvidenceDir = '',
  [switch]$TimeoutOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Split-Path -Parent (Split-Path -Parent $here)
$engine = Join-Path $src 'plugin/engine'
if (-not $InvokeLib) { $InvokeLib = Join-Path $engine 'lib/invoke-codex.ps1' }
if ($EvidenceDir) {
  $EvidenceDir = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $EvidenceDir))
  New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
}
. (Join-Path $engine 'lib/gate.ps1')
. $InvokeLib

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-timeout-' + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $work | Out-Null
$pass = 0; $fail = 0
function ok([string]$Name, $Condition) {
  if ($Condition) { $script:pass++; Write-Host "  ok  $Name" }
  else { $script:fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
}
function Write-Utf8NoBom([string]$Path, [string]$Text) {
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

$stub = Join-Path $work 'stub-codex.ps1'
Write-Utf8NoBom $stub @'
if ($args.Count -ge 2 -and $args[0] -eq 'login' -and $args[1] -eq 'status') { exit 0 }
$null = $input | Out-String
$last = ''; $root = ''
for ($i = 0; $i -lt $args.Count; $i++) {
  if ($args[$i] -eq '--output-last-message' -and ($i + 1) -lt $args.Count) { $last = [string]$args[$i + 1] }
  if ($args[$i] -eq '--cd' -and ($i + 1) -lt $args.Count) { $root = [string]$args[$i + 1] }
}
switch ($env:CODEX_TIMEOUT_STUB_MODE) {
  'success' {
    Write-Output 'ordinary-success'
    if ($last) { [IO.File]::WriteAllText($last, 'final-success') }
    exit 0
  }
  'failure' { Write-Error 'ordinary-failure'; exit 7 }
  default {
    if ($root -and (Test-Path (Join-Path $root 'tracked.txt'))) {
      [IO.File]::WriteAllText((Join-Path $root 'tracked.txt'), 'changed-before-timeout')
    }
    Write-Output 'partial-before-timeout'
    Start-Sleep -Seconds 4
    Write-Output 'output-after-kill'
  }
}
'@
$stubCmd = Join-Path $work 'codex.cmd'
[IO.File]::WriteAllText($stubCmd, @'
@echo off
if "%~1"=="login" exit /b 0
> "%CODEX_TIMEOUT_TRACKED%" <nul set /p "=changed-before-timeout"
echo partial-before-timeout
ping -n 6 127.0.0.1 >nul
echo output-after-kill
'@, [Text.Encoding]::ASCII)

$watchdog = '[codex timed out after 1s ' + [char]0x2014 + ' watchdog kill, failing closed]'
$cfg = [pscustomobject]@{ timeoutSeconds = 1; model = $null; reasoningEffort = $null }
try {
  Write-Host 'codex timeout helper: preserves output produced before the watchdog kill'
  # Warm Start-Job/PowerShell before the deliberately tight one-second budget. On a cold, loaded
  # Windows host job-process startup can consume the entire second before the stub runs; the real
  # loop separately warms the Codex executable with `login status` before Invoke-Codex.
  $env:CODEX_TIMEOUT_STUB_MODE = 'success'
  $warmCfg = [pscustomobject]@{ timeoutSeconds = 30; model = $null; reasoningEffort = $null }
  $warmLog = Join-Path $work 'warmup.log'
  $warm = Invoke-Codex -Mode read-only -Prompt 'warmup' -RepoRoot $work -LogPath $warmLog -CodexCfg $warmCfg -CodexCommand $stub
  $env:CODEX_TIMEOUT_STUB_MODE = 'timeout'
  $log = Join-Path $work 'helper-timeout.log'
  $result = Invoke-Codex -Mode workspace-write -Prompt 'test prompt' -RepoRoot $work -LogPath $log -CodexCfg $cfg -CodexCommand $stub
  $text = if (Test-Path $log) { Get-Content -LiteralPath $log -Raw -Encoding UTF8 } else { '' }
  $earlyAt = $text.IndexOf('partial-before-timeout', [StringComparison]::Ordinal)
  $watchAt = $text.IndexOf($watchdog, [StringComparison]::Ordinal)
  ok 'timeout returns Ok=false' (-not $result.Ok)
  ok 'timeout log keeps partial-before-timeout' ($earlyAt -ge 0)
  ok 'watchdog verdict follows the early marker exactly' ($earlyAt -ge 0 -and $watchAt -gt $earlyAt -and $text.Contains($watchdog))
  ok 'timeout log excludes output scheduled after the kill' (-not $text.Contains('output-after-kill'))
  if ($EvidenceDir) { Copy-Item -LiteralPath $log -Destination (Join-Path $EvidenceDir 'helper-timeout.log') }

  if (-not $TimeoutOnly) {
    Write-Host 'codex ordinary paths: success/failure result shape stays intact'
    ok 'ordinary success stays Ok=true and prefers final-message output' ($warm.Ok -and $warm.Output -eq 'final-success')
    ok 'ordinary success transcript is durable' ((Get-Content -LiteralPath $warmLog -Raw -Encoding UTF8).Contains('ordinary-success'))
    $env:CODEX_TIMEOUT_STUB_MODE = 'failure'
    $failureLog = Join-Path $work 'helper-failure.log'
    $failure = Invoke-Codex -Mode read-only -Prompt 'test prompt' -RepoRoot $work -LogPath $failureLog -CodexCfg $warmCfg -CodexCommand $stub
    $failureText = Get-Content -LiteralPath $failureLog -Raw -Encoding UTF8
    ok 'ordinary failure stays Ok=false' (-not $failure.Ok)
    ok 'ordinary failure keeps stderr and exit annotation' ($failureText.Contains('ordinary-failure') -and $failureText.Contains('[codex exited 7]'))

    Write-Host 'codex timeout loop: invoke-error rolls back while the durable run log survives'
    $repo = Join-Path $work 'repo'
    New-Item -ItemType Directory -Force -Path (Join-Path $repo 'harness'), (Join-Path $repo 'state') | Out-Null
    Copy-Item (Join-Path $src 'harness/loop.ps1') (Join-Path $repo 'harness/loop.ps1')
    Write-Utf8NoBom (Join-Path $repo 'harness/harness.config.json') @'
{
  "project": { "type": "greenfield", "baseline": { "established": false, "ref": null } },
  "models": {
    "implement": { "model": "codex", "fallback": null },
    "review": { "model": "review-unused", "fallback": null },
    "evaluate": { "model": "evaluate-unused", "fallback": null },
    "codex": { "model": null, "reasoningEffort": "high", "auth": "chatgpt", "timeoutSeconds": 1 }
  },
  "autonomy": { "mode": "auto", "maxIterations": 1, "maxTurnsPerIteration": 2, "tokenBudget": null, "meterTokens": false, "skipPermissions": false,
    "checkpoints": { "planApproval": false, "beforeRiskyOps": false, "everyNIterations": 0 } },
  "loop": { "promptFile": "PROMPT.md", "planFile": "state/fix_plan.md", "progressFile": "state/PROGRESS.md",
    "oneItemPerIteration": true, "autoRollbackOnRed": true, "commitOnGreen": false, "tagOnGreen": false, "stopWhenPlanEmpty": true },
  "verification": { "requireE2EEvidence": false, "reviewEveryNIterations": 0, "evaluator": { "enabled": false } },
  "components": [ { "name": "root", "path": ".", "gate": { "format": null, "lint": null, "typecheck": null, "build": null, "test": "exit 0", "e2e": null } } ],
  "gate": { "format": null, "lint": null, "typecheck": null, "build": null, "test": null, "e2e": null }
}
'@
    Write-Utf8NoBom (Join-Path $repo 'state/fix_plan.md') "## Tasks`n- [ ] timeout thing`n"
    Write-Utf8NoBom (Join-Path $repo 'state/tasks.json') "{ `"version`": 2, `"tasks`": [] }`n"
    Write-Utf8NoBom (Join-Path $repo 'state/PROGRESS.md') "- init`n"
    Write-Utf8NoBom (Join-Path $repo 'PROMPT.md') "exercise timeout`n"
    Write-Utf8NoBom (Join-Path $repo 'tracked.txt') 'original'
    Write-Utf8NoBom (Join-Path $repo '.gitignore') "harness/.runs/`nharness/.worktrees/`nstate/handoff.md`n"
    Push-Location $repo
    try {
      & git init -q -b main; & git config core.autocrlf false; & git config user.email timeout-test@example.com; & git config user.name 'Timeout Test'
      & git add -A; & git commit -q -m init
      $base = "$(& git rev-parse HEAD)".Trim()
      $oldPath = $env:PATH; $oldEngine = $env:HARNESS_ENGINE; $oldSandbox = $env:HARNESS_SANDBOX; $oldTracked = $env:CODEX_TIMEOUT_TRACKED
      $env:PATH = "$work;$oldPath"; $env:HARNESS_ENGINE = $engine; $env:HARNESS_SANDBOX = '1'; $env:CODEX_TIMEOUT_STUB_MODE = 'timeout'; $env:CODEX_TIMEOUT_TRACKED = (Join-Path $repo 'tracked.txt')
      $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      try { $loopOut = (& powershell -NoProfile -ExecutionPolicy Bypass -File 'harness/loop.ps1' -Mode auto -MaxIterations 1 2>&1 | Out-String) }
      finally {
        $ErrorActionPreference = $prevEap
        $env:PATH = $oldPath
        if ($null -ne $oldEngine) { $env:HARNESS_ENGINE = $oldEngine } else { Remove-Item Env:HARNESS_ENGINE -ErrorAction SilentlyContinue }
        if ($null -ne $oldSandbox) { $env:HARNESS_SANDBOX = $oldSandbox } else { Remove-Item Env:HARNESS_SANDBOX -ErrorAction SilentlyContinue }
        if ($null -ne $oldTracked) { $env:CODEX_TIMEOUT_TRACKED = $oldTracked } else { Remove-Item Env:CODEX_TIMEOUT_TRACKED -ErrorAction SilentlyContinue }
      }
      $head = "$(& git rev-parse HEAD)".Trim(); $status = "$(& git status --porcelain)"
      $ledger = Get-Content -LiteralPath 'harness/.runs/run-001/ledger.jsonl' -Raw
      $iterText = Get-Content -LiteralPath 'harness/.runs/run-001/iter-1.log' -Raw -Encoding UTF8
      $loopEarly = $iterText.IndexOf('partial-before-timeout', [StringComparison]::Ordinal)
      $loopWatch = $iterText.IndexOf($watchdog, [StringComparison]::Ordinal)
      ok 'loop records invoke-error for the Codex route' ($ledger.Contains('"result":"invoke-error"') -and $ledger.Contains('"path":"codex"') -and $ledger.Contains('"reason":"invoke-failed"'))
      ok 'loop restores the exact pre-iteration commit' ($head -eq $base)
      ok 'loop restores the tracked file and leaves the worktree clean' ((Get-Content -LiteralPath 'tracked.txt' -Raw) -eq 'original' -and -not $status)
      ok 'durable iteration log keeps early marker before watchdog verdict' ($loopEarly -ge 0 -and $loopWatch -gt $loopEarly)
      ok 'durable iteration log excludes output scheduled after the kill' (-not $iterText.Contains('output-after-kill'))
      if ($EvidenceDir) {
        Copy-Item -LiteralPath 'harness/.runs/run-001/ledger.jsonl' -Destination (Join-Path $EvidenceDir 'loop-ledger.jsonl')
        Copy-Item -LiteralPath 'harness/.runs/run-001/iter-1.log' -Destination (Join-Path $EvidenceDir 'loop-iter-1.log')
        $scrubbedLoopOut = $loopOut.Replace($work, '<TMP>').Replace($src, '<REPO>').Replace($env:USERPROFILE, '<HOME>')
        Write-Utf8NoBom (Join-Path $EvidenceDir 'loop-result.txt') ("BASE=$base`nHEAD=$head`nSTATUS=$status`nTRACKED=$(Get-Content -LiteralPath 'tracked.txt' -Raw)`n$scrubbedLoopOut")
      }
    } finally { Pop-Location }
  }
} finally {
  Remove-Item Env:CODEX_TIMEOUT_STUB_MODE -ErrorAction SilentlyContinue
  if ($work.StartsWith([System.IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
  }
}
Write-Host ''
Write-Host "CODEX TIMEOUT RESULT: $pass passed, $fail failed"
if ($EvidenceDir) { Write-Utf8NoBom (Join-Path $EvidenceDir 'test-result.txt') "PASSED=$pass`nFAILED=$fail`n" }
if ($fail -gt 0) { exit 1 }
