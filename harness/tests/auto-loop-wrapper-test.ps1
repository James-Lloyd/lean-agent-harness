#requires -Version 5.1
# Live regression for no-commit loop preservation, truthful warnings, and cache-version wrapper resolution.
[CmdletBinding()]
param([string]$Engine = '')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Split-Path -Parent (Split-Path -Parent $here)
if (-not $Engine) { $Engine = Join-Path $src 'plugin/engine' }
$engine = (Resolve-Path $Engine).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('harness-auto-' + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $work | Out-Null
$pass = 0; $fail = 0
function ok([string]$Name, $Condition) { if ($Condition) { $script:pass++; Write-Host "  ok  $Name" } else { $script:fail++; Write-Host "  FAIL $Name" -ForegroundColor Red } }
function Write-Utf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false))) }
function New-TestRepo([string]$Path, [bool]$Commit) {
  New-Item -ItemType Directory -Force -Path (Join-Path $Path 'harness'), (Join-Path $Path 'state') | Out-Null
  Copy-Item (Join-Path $src 'harness/loop.ps1') (Join-Path $Path 'harness/loop.ps1')
  $flag = if ($Commit) { 'true' } else { 'false' }
  $json = (@'
{
  "project":{"type":"greenfield","baseline":{"established":false,"ref":null}},
  "models":{"implement":{"model":"test-model","fallback":null},"review":{"model":"test-model","fallback":null},"evaluate":{"model":"test-model","fallback":null},"codex":{"auth":"chatgpt","timeoutSeconds":30}},
  "autonomy":{"mode":"auto","maxIterations":3,"maxTurnsPerIteration":2,"tokenBudget":null,"meterTokens":false,"skipPermissions":false,"checkpoints":{"planApproval":false,"beforeRiskyOps":false,"everyNIterations":0}},
  "loop":{"promptFile":"PROMPT.md","planFile":"state/fix_plan.md","progressFile":"state/PROGRESS.md","oneItemPerIteration":true,"autoRollbackOnRed":true,"commitOnGreen":__COMMIT__,"tagOnGreen":true,"stopWhenPlanEmpty":true},
  "verification":{"requireE2EEvidence":true,"reviewEveryNIterations":0,"evaluator":{"enabled":false}},
  "components":[{"name":"root","path":".","gate":{"format":null,"lint":null,"typecheck":null,"build":null,"test":"exit 0","e2e":null}}],
  "gate":{"format":null,"lint":null,"typecheck":null,"build":null,"test":null,"e2e":null}
}
'@).Replace('__COMMIT__', $flag)
  Write-Utf8 (Join-Path $Path 'harness/harness.config.json') $json
  Write-Utf8 (Join-Path $Path 'state/fix_plan.md') "## Tasks`n- [ ] first`n- [ ] second`n"
  Write-Utf8 (Join-Path $Path 'state/PROGRESS.md') "- init`n"
  Write-Utf8 (Join-Path $Path 'PROMPT.md') "make one safe change`n"
  Write-Utf8 (Join-Path $Path 'tracked.txt') 'original'
  Write-Utf8 (Join-Path $Path '.gitignore') "harness/.runs/`n"
  Push-Location $Path
  try { & git init -q -b main; & git config core.autocrlf false; & git config user.email harness-test@example.com; & git config user.name 'Harness Test'; & git add -A; & git commit -q -m init } finally { Pop-Location }
}
try {
  $stub = Join-Path $work 'claude-stub.ps1'; $counter = Join-Path $work 'count.txt'
  Write-Utf8 $stub @'
$null = $input | Out-String
$n = if (Test-Path $env:HARNESS_TEST_COUNTER) { [int](Get-Content $env:HARNESS_TEST_COUNTER -Raw) + 1 } else { 1 }
[IO.File]::WriteAllText($env:HARNESS_TEST_COUNTER, "$n")
if ($n -eq 1) { [IO.File]::WriteAllText((Join-Path (Get-Location) 'tracked.txt'), 'green-one') }
else { Add-Content (Join-Path (Get-Location) 'harness/harness.config.json') ' ' }
Write-Output "stub invocation $n"
'@
  $repo = Join-Path $work 'no-commit'; New-TestRepo $repo $false
  Push-Location $repo
  $oldCmd=$env:HARNESS_CLAUDE_CMD; $oldEngine=$env:HARNESS_ENGINE; $oldSandbox=$env:HARNESS_SANDBOX; $oldCounter=$env:HARNESS_TEST_COUNTER
  try {
    $env:HARNESS_CLAUDE_CMD=$stub; $env:HARNESS_ENGINE=$engine; $env:HARNESS_SANDBOX='1'; $env:HARNESS_TEST_COUNTER=$counter
    $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File 'harness/loop.ps1' -Mode auto 2>&1 | Out-String)
  } finally {
    if ($null -ne $oldCmd) { $env:HARNESS_CLAUDE_CMD=$oldCmd } else { Remove-Item Env:HARNESS_CLAUDE_CMD -ErrorAction SilentlyContinue }
    if ($null -ne $oldEngine) { $env:HARNESS_ENGINE=$oldEngine } else { Remove-Item Env:HARNESS_ENGINE -ErrorAction SilentlyContinue }
    if ($null -ne $oldSandbox) { $env:HARNESS_SANDBOX=$oldSandbox } else { Remove-Item Env:HARNESS_SANDBOX -ErrorAction SilentlyContinue }
    if ($null -ne $oldCounter) { $env:HARNESS_TEST_COUNTER=$oldCounter } else { Remove-Item Env:HARNESS_TEST_COUNTER -ErrorAction SilentlyContinue }
    Pop-Location
  }
  $ledger = Get-Content (Join-Path $repo 'harness/.runs/run-001/ledger.jsonl') -Raw
  ok 'no-commit loop invokes the model exactly once' ((Get-Content $counter -Raw).Trim() -eq '1')
  ok 'first green uncommitted change survives' ((Get-Content (Join-Path $repo 'tracked.txt') -Raw) -eq 'green-one')
  ok 'ledger records one green uncommitted iteration' (($ledger -split "`n" | Where-Object { $_.Trim() }).Count -eq 1 -and $ledger.Contains('"committed":false'))
  ok 'no green tag points at the pre-iteration HEAD' (-not ((& git -C $repo tag --list | Out-String).Trim()))
  ok 'no-commit warning tells the truth' ($out.Contains('leave the green changes uncommitted for a human to review'))
  ok 'loop explains the safe stop boundary' ($out.Contains('preserving the green uncommitted changes'))

  $commitRepo = Join-Path $work 'commit'; New-TestRepo $commitRepo $true
  Push-Location $commitRepo
  try { $commitOut = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $engine 'loop.ps1') -ProjectRoot $commitRepo -DryRun 2>&1 | Out-String) } finally { Pop-Location }
  ok 'commit-enabled warning tells the truth' ($commitOut.Contains('commit after the configured non-e2e gate passes'))

  $fakeProfile = Join-Path $work 'profile'; $consumer = Join-Path $work 'consumer'
  New-Item -ItemType Directory -Force -Path (Join-Path $consumer 'harness') | Out-Null
  Copy-Item (Join-Path $engine 'wrappers/loop.ps1') (Join-Path $consumer 'harness/loop.ps1')
  foreach ($entry in @(@('0.5.1','.claude'), @('0.5.3','.codex'))) {
    $v = $entry[0]; $cacheRoot = $entry[1]
    $dir = Join-Path $fakeProfile "$cacheRoot/plugins/cache/lean-agent-harness/lean-agent-harness/$v/engine"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Write-Utf8 (Join-Path $dir 'loop.ps1') "Write-Output 'WRAPPER_VERSION=$v'`n"
  }
  $oldPath = Join-Path $fakeProfile '.claude/plugins/cache/lean-agent-harness/lean-agent-harness/0.5.1/engine/loop.ps1'
  [IO.File]::SetLastWriteTimeUtc($oldPath, [DateTime]::UtcNow.AddHours(1))
  $oldProfile=$env:USERPROFILE; $oldEngine=$env:HARNESS_ENGINE; $oldRoot=$env:CLAUDE_PLUGIN_ROOT
  try {
    $env:USERPROFILE=$fakeProfile
    Remove-Item Env:HARNESS_ENGINE,Env:CLAUDE_PLUGIN_ROOT -ErrorAction SilentlyContinue
    $wrapperOutCodex=(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $consumer 'harness/loop.ps1') 2>&1 | Out-String)
    $claudeNewest = Join-Path $fakeProfile '.claude/plugins/cache/lean-agent-harness/lean-agent-harness/0.5.4/engine'
    New-Item -ItemType Directory -Force -Path $claudeNewest | Out-Null
    Write-Utf8 (Join-Path $claudeNewest 'loop.ps1') "Write-Output 'WRAPPER_VERSION=0.5.4'`n"
    [IO.File]::SetLastWriteTimeUtc((Join-Path $fakeProfile '.codex/plugins/cache/lean-agent-harness/lean-agent-harness/0.5.3/engine/loop.ps1'), [DateTime]::UtcNow.AddHours(2))
    $wrapperOutClaude=(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $consumer 'harness/loop.ps1') 2>&1 | Out-String)
  } finally {
    $env:USERPROFILE=$oldProfile
    if ($null -ne $oldEngine) { $env:HARNESS_ENGINE=$oldEngine } else { Remove-Item Env:HARNESS_ENGINE -ErrorAction SilentlyContinue }
    if ($null -ne $oldRoot) { $env:CLAUDE_PLUGIN_ROOT=$oldRoot } else { Remove-Item Env:CLAUDE_PLUGIN_ROOT -ErrorAction SilentlyContinue }
  }
  ok 'wrapper selects newer Codex-cache version despite Claude-cache timestamp' ($wrapperOutCodex.Contains('WRAPPER_VERSION=0.5.3'))
  ok 'wrapper selects newer Claude-cache version despite Codex-cache timestamp' ($wrapperOutClaude.Contains('WRAPPER_VERSION=0.5.4'))
} finally {
  if ($work.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue }
}
Write-Host "AUTO LOOP + WRAPPER RESULT: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
