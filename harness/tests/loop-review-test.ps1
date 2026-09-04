#requires -Version 5.1
<#
  loop-review-test.ps1 - integration test for the loop's REVIEW POINT with a SECOND reviewer (PS side;
  mirror of loop-review-test.sh; design-doc 002 D4). Live-fires harness/loop.ps1 in a throwaway repo with a
  stub claude (HARNESS_CLAUDE_CMD) whose behaviour branches on the --model the dispatcher passes:
    impl-x      the implementer: writes a file and ticks the plan item (gate green + commit)
    primary-rev the primary reviewer: always VERDICT: SHIP
    second-rev  the second reviewer: SHIP | REJECT | a usage-limit failure, per $env:SECOND_MODE
  Three runs assert: SHIP requires BOTH judges; a REJECT from the second stops the loop with a handoff
  naming it; a capped second reviewer FAILS CLOSED (no fallback); both verdicts land in the ledger; the
  harness-reviewed watermark advances only when both ship. Requires only git.
  Run:  powershell harness/tests/loop-review-test.ps1
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Split-Path -Parent (Split-Path -Parent $here)
$env:HARNESS_ENGINE = Join-Path $src 'plugin/engine'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("loop-rt-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $work | Out-Null
$origLoc = Get-Location
$pass = 0; $fail = 0
function ok([string]$name, $cond) { if ($cond) { $script:pass++; Write-Host "  ok  $name" } else { $script:fail++; Write-Host "  FAIL $name" -ForegroundColor Red } }

# Stub claude OUTSIDE the repos (an untracked file inside would fail the clean-tree preflight).
$stub = Join-Path $work 'stub-claude.ps1'
@'
$null = $input | Out-String
$model = ''; $effort = ''
for ($k = 0; $k -lt $args.Count; $k++) {
  if ($args[$k] -eq '--model'  -and ($k + 1) -lt $args.Count) { $model  = [string]$args[$k + 1] }
  if ($args[$k] -eq '--effort' -and ($k + 1) -lt $args.Count) { $effort = [string]$args[$k + 1] }
}
if ($env:STUB_ARGV_LOG) { Add-Content -Path $env:STUB_ARGV_LOG -Value "$model effort=$effort" }
switch ($model) {
  'impl-x' {
    New-Item -ItemType Directory -Force -Path 'out' | Out-Null
    'built' | Set-Content 'out/a.txt'
    $plan = Get-Content 'state/fix_plan.md' -Raw
    [System.IO.File]::WriteAllText((Join-Path (Get-Location) 'state/fix_plan.md'), $plan.Replace('- [ ] build thing', '- [x] build thing'), (New-Object System.Text.UTF8Encoding($false)))
    Write-Output 'implemented'; exit 0
  }
  'primary-rev' { Write-Output 'Reviewed the batch; nothing blocker-grade.'; Write-Output 'VERDICT: SHIP'; exit 0 }
  'second-rev' {
    $mode = if ($env:SECOND_MODE) { $env:SECOND_MODE } else { 'reject' }
    if ($mode -eq 'ship') { Write-Output 'Second opinion: agree.'; Write-Output 'VERDICT: SHIP'; exit 0 }
    if ($mode -eq 'cap')  { Write-Output 'Error: monthly usage limit reached'; exit 1 }
    Write-Output 'Second opinion: found a blocker the first judge missed.'; Write-Output 'VERDICT: REJECT'; exit 0
  }
  default { [Console]::Error.WriteLine("stub: unexpected model '$model'"); exit 1 }
}
'@ | Set-Content $stub -Encoding utf8

function New-Repo([string]$T) {
  New-Item -ItemType Directory -Force -Path $T | Out-Null
  Set-Location $T
  git init -q -b main
  git config core.autocrlf false
  git config user.email loop-test@example.com
  git config user.name "Loop Test"
  Copy-Item (Join-Path $src 'harness') . -Recurse
  Remove-Item (Join-Path $T 'harness\.runs'), (Join-Path $T 'harness\.worktrees') -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path (Join-Path $T 'state') | Out-Null
  @'
{
  "project": { "type": "greenfield", "baseline": { "established": false, "ref": null } },
  "models": {
    "implement": { "model": "impl-x", "fallback": null },
    "review":    { "model": "primary-rev", "fallback": null, "second": { "model": "second-rev", "effort": "high" } }
  },
  "autonomy": { "mode": "auto", "maxIterations": 1, "maxTurnsPerIteration": 10, "tokenBudget": null, "meterTokens": false, "skipPermissions": false,
                "checkpoints": { "planApproval": false, "beforeRiskyOps": false, "everyNIterations": 0 } },
  "loop": { "promptFile": "PROMPT.md", "planFile": "state/fix_plan.md", "progressFile": "state/PROGRESS.md",
            "oneItemPerIteration": true, "autoRollbackOnRed": true, "commitOnGreen": true, "tagOnGreen": false, "stopWhenPlanEmpty": true },
  "verification": { "requireE2EEvidence": false, "reviewEveryNIterations": 1, "evaluator": { "enabled": false } },
  "components": [ { "name": "root", "path": ".", "gate": { "format": null, "lint": null, "typecheck": null, "build": null, "test": "exit 0", "e2e": null } } ],
  "gate": { "format": null, "lint": null, "typecheck": null, "build": null, "test": null, "e2e": null }
}
'@ | Set-Content 'harness\harness.config.json' -Encoding utf8
  "## Tasks`n- [ ] build thing" | Set-Content 'state\fix_plan.md' -Encoding utf8
  '{ "version": 2, "tasks": [] }' | Set-Content 'state\tasks.json' -Encoding utf8
  "- init" | Set-Content 'state\PROGRESS.md' -Encoding utf8
  "do the top task" | Set-Content 'PROMPT.md' -Encoding utf8
  "harness/.runs/`nharness/.worktrees/`nstate/handoff.md" | Set-Content '.gitignore' -Encoding ascii
  git add -A; git commit -q -m "init"
}
function Run-Loop([string]$mode) {
  $env:SECOND_MODE = $mode; $env:HARNESS_CLAUDE_CMD = $stub; $env:STUB_ARGV_LOG = (Join-Path $work "argv-$mode.log")
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $script:loopOut = (& powershell -NoProfile -ExecutionPolicy Bypass -File 'harness\loop.ps1' -Mode auto -MaxIterations 1 2>&1 | Out-String) }
  finally { $ErrorActionPreference = $prev; Remove-Item Env:SECOND_MODE, Env:HARNESS_CLAUDE_CMD, Env:STUB_ARGV_LOG -ErrorAction SilentlyContinue }
}
function Ledger-Rows { if (Test-Path 'harness\.runs\run-001\ledger.jsonl') { @(Get-Content 'harness\.runs\run-001\ledger.jsonl' | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() } }
function Row([string]$result) { @(Ledger-Rows | Where-Object { $_.result -eq $result }) }
function Handoff { if (Test-Path 'state\handoff.md') { Get-Content 'state\handoff.md' -Raw } else { '' } }

try {
  Write-Host "loop review point: second reviewer REJECT stops the loop (SHIP requires both)"
  New-Repo (Join-Path $work 'reject'); Run-Loop 'reject'
  $r1 = @(Row 'review'); $s1 = @(Row 'review-second')
  ok "ledger: primary reviewer SHIP"                          ($r1.Count -eq 1 -and $r1[0].verdict -eq 'SHIP' -and $r1[0].path -eq 'claude')
  ok "ledger: second reviewer REJECT, model recorded"         ($s1.Count -eq 1 -and $s1[0].verdict -eq 'REJECT' -and $s1[0].model -eq 'second-rev')
  ok "ledger: loop stopped at the review point"               (@(Row 'review-stop').Count -eq 1)
  ok "handoff names the second reviewer's REJECT"             ((Handoff) -match 'second reviewer \(second-rev\): REJECT')
  ok "harness-reviewed watermark NOT advanced"                (-not (git tag -l harness-reviewed))
  ok "second reviewer transcript written"                     (Test-Path 'harness\.runs\run-001\review-second-after-1.log')
  ok "loop header names the second reviewer"                  ($loopOut -match 'review=primary-rev \+second=second-rev')
  ok "second.effort reaches the CLI (--effort high)"           (@(Get-Content (Join-Path $work 'argv-reject.log')) -ccontains 'second-rev effort=high')

  Write-Host "loop review point: both SHIP => watermark advances, no handoff"
  New-Repo (Join-Path $work 'ship'); Run-Loop 'ship'
  $s2 = @(Row 'review-second')
  ok "ledger: second reviewer SHIP"                           ($s2.Count -eq 1 -and $s2[0].verdict -eq 'SHIP')
  ok "ledger: no review-stop"                                 (@(Row 'review-stop').Count -eq 0)
  ok "harness-reviewed watermark == HEAD"                     ("$(git rev-parse harness-reviewed 2>$null)".Trim() -eq "$(git rev-parse HEAD)".Trim())
  ok "no handoff written"                                     (-not ((Handoff) -match 'Needs human decision'))

  Write-Host "loop review point: a capped second reviewer FAILS CLOSED (no fallback, no substitute model)"
  New-Repo (Join-Path $work 'cap'); Run-Loop 'cap'
  $s3 = @(Row 'review-second')
  ok "ledger: second reviewer ERROR"                          ($s3.Count -eq 1 -and $s3[0].verdict -eq 'ERROR')
  ok "handoff: second reviewer could not run"                 ((Handoff) -match 'second reviewer \(second-rev\) could not run')
  ok "watermark NOT advanced on a capped second reviewer"     (-not (git tag -l harness-reviewed))
  ok "exactly one second-review attempt (no retry on another model)" ($s3.Count -eq 1)
} finally {
  Set-Location $origLoc
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
Write-Host ""
Write-Host "LOOP REVIEW RESULT: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 } else { exit 0 }
