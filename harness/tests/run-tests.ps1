#!/usr/bin/env pwsh
#requires -Version 5.1
<#
  run-tests.ps1 — self-tests for the harness's own fiddly logic (the gate, the denylist hook, the
  budget). "Test the harness" (Fowler). Self-contained: no Pester dependency, so it runs anywhere,
  including CI. Exit 0 = all pass, exit 1 = a failure.

  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File harness/tests/run-tests.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Join-Path (Split-Path $here -Parent) 'lib'
$hookDir = Join-Path (Split-Path (Split-Path $here -Parent) -Parent) '.claude/hooks'
. (Join-Path $libDir 'gate.ps1')
. (Join-Path $libDir 'budget.ps1')

$script:pass = 0; $script:fail = 0
function ok($name, $cond) {
  if ($cond) { $script:pass++; Write-Host "  ok  $name" -ForegroundColor Green }
  else       { $script:fail++; Write-Host "  FAIL $name" -ForegroundColor Red }
}
function gate($f,$l,$t,$b,$te,$e) { [pscustomobject]@{ format=$f; lint=$l; typecheck=$t; build=$b; test=$te; e2e=$e } }

Write-Host "gate: StrictMode-safe missing-key tolerance"
# A gate object missing keys must NOT throw (schema allows it; /harness-prune may trim) — missing => skip.
$partial = [pscustomobject]@{ format = 'exit 0' }   # only one key present
$threw = $false
try { $r = Invoke-Gate -Gate $partial -WorkingDir $here -Label 't' } catch { $threw = $true }
ok "partial gate object does not throw" (-not $threw)
ok "partial gate object passes (missing steps skipped)" ($r.Passed -eq $true)

Write-Host "gate: pass / fail attribution"
$rp = Invoke-Gate -Gate (gate 'exit 0' 'exit 0' $null $null 'exit 0' $null) -WorkingDir $here -Label 'c'
ok "all-green gate passes" ($rp.Passed)
$rf = Invoke-Gate -Gate (gate 'exit 0' 'exit 5' $null $null $null $null) -WorkingDir $here -Label 'c'
ok "failing gate reports FailedStep=lint" ((-not $rf.Passed) -and $rf.FailedStep -eq 'lint')

Write-Host "gate: multi-component project gate + failure attribution"
$cfgPass = [pscustomobject]@{
  components = @(
    [pscustomobject]@{ name='frontend'; path='.'; gate=(gate 'exit 0' $null $null $null 'exit 0' $null) },
    [pscustomobject]@{ name='backend';  path='.'; gate=(gate 'exit 0' $null $null $null 'exit 0' $null) }
  )
  gate = [pscustomobject]@{ e2e='exit 0' }
}
ok "multi-component all-green passes" ((Invoke-ProjectGate -Config $cfgPass -RepoRoot $here).Passed)
$cfgFail = [pscustomobject]@{
  components = @(
    [pscustomobject]@{ name='frontend'; path='.'; gate=(gate 'exit 0' $null $null $null $null $null) },
    [pscustomobject]@{ name='backend';  path='.'; gate=(gate 'exit 0' 'exit 9' $null $null $null $null) }
  )
  gate = [pscustomobject]@{ }
}
$rpc = Invoke-ProjectGate -Config $cfgFail -RepoRoot $here
ok "multi-component failure attributed to backend:lint" ((-not $rpc.Passed) -and $rpc.Component -eq 'backend' -and $rpc.FailedStep -eq 'lint')

Write-Host "budget: per-run reset"
Reset-Budget
ok "budget resets to 0" ((Get-Budget).tokensSpent -eq 0)
ok "no cap => not exceeded" (-not (Test-BudgetExceeded 0))

Write-Host "block-destructive hook: blocks dangerous, allows safe"
$hook = Join-Path $hookDir 'block-destructive.ps1'
function hookExit($cmd) {
  # Local SilentlyContinue so the hook's stderr (on a block) isn't treated as a terminating error.
  $ErrorActionPreference = 'SilentlyContinue'
  $payload = @{ tool_name='Bash'; tool_input=@{ command=$cmd } } | ConvertTo-Json -Compress
  $payload | & powershell -NoProfile -ExecutionPolicy Bypass -File $hook 1>$null 2>$null
  return $LASTEXITCODE
}
# Build risky strings from fragments so the outer test harness/sandbox doesn't itself trip on them.
$rmfr   = 'rm' + ' -fr ' + 'build'           # flag-order variant the old regex missed
$pushf  = 'git push ' + '-f origin main'      # short force flag
$finddel= 'find . ' + '-delete'
$resetX = 'git reset ' + '--hard abc1234'     # arbitrary sha (old regex only caught HEAD~)
$grepsec= 'grep x ' + '.env'                  # secret read via grep (old regex only cat/type/gc)
ok "blocks rm -fr (flag order)"        ((hookExit $rmfr) -eq 2)
ok "blocks git push -f (short flag)"   ((hookExit $pushf) -eq 2)
ok "blocks find -delete"               ((hookExit $finddel) -eq 2)
ok "blocks git reset --hard <sha>"     ((hookExit $resetX) -eq 2)
ok "blocks secret read via grep"       ((hookExit $grepsec) -eq 2)
ok "allows git status"                 ((hookExit 'git status') -eq 0)
ok "allows npm test"                   ((hookExit 'npm test') -eq 0)
ok "allows normal git push"            ((hookExit 'git push origin feature') -eq 0)

Write-Host "protect-specs hook: locks specs/ only when HARNESS_LOCK_SPECS is set"
$specHook = Join-Path $hookDir 'protect-specs.ps1'
function specExit($path, $locked) {
  $ErrorActionPreference = 'SilentlyContinue'
  $old = $env:HARNESS_LOCK_SPECS
  if ($locked) { $env:HARNESS_LOCK_SPECS = '1' } else { Remove-Item Env:HARNESS_LOCK_SPECS -ErrorAction SilentlyContinue }
  $payload = @{ tool_name='Write'; tool_input=@{ file_path=$path } } | ConvertTo-Json -Compress
  try { $payload | & powershell -NoProfile -ExecutionPolicy Bypass -File $specHook 1>$null 2>$null }
  finally {
    if ($null -ne $old) { $env:HARNESS_LOCK_SPECS = $old } else { Remove-Item Env:HARNESS_LOCK_SPECS -ErrorAction SilentlyContinue }
  }
  return $LASTEXITCODE
}
ok "blocks specs/ write when locked"   ((specExit 'specs/000-overview.md' $true) -eq 2)
ok "allows non-spec write when locked" ((specExit 'src/app.ts' $true) -eq 0)
ok "allows specs/ write when unlocked" ((specExit 'specs/000-overview.md' $false) -eq 0)

Write-Host ""
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
