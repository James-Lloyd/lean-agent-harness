#!/usr/bin/env pwsh
#requires -Version 5.1
<#
  fleet-queue-test.ps1 — integration test for the fleet runner's MERGE QUEUE (PS side; mirror of
  fleet-queue-test.sh). Live-fires harness/fleet.ps1 in a throwaway repo with a stub claude
  (HARNESS_CLAUDE_CMD), asserting the queue's core outcomes: parallel job spawn, worker exit capture,
  worker commit, squash-merge, gate on the combined state, runner-owned recording, cleanup of merged
  branches — and the tamper-park path (a worker editing harness/ must never land).
  Requires only git. Run:  powershell harness/tests/fleet-queue-test.ps1
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Split-Path -Parent (Split-Path -Parent $here)
# harness/fleet.ps1 is now a thin WRAPPER that dispatches to the plugin engine; pin it to this repo's
# own plugin/engine so the copied wrapper resolves the engine without relying on $CLAUDE_PLUGIN_ROOT.
$env:HARNESS_ENGINE = Join-Path $src 'plugin/engine'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("fleet-qt-" + [System.IO.Path]::GetRandomFileName())
$T    = Join-Path $work 'repo'
New-Item -ItemType Directory -Force -Path $T | Out-Null
$origLoc = Get-Location
try {
  Set-Location $T
  git init -q -b main
  git config core.autocrlf false
  git config user.email fleet-test@example.com
  git config user.name "Fleet Test"

  Copy-Item (Join-Path $src 'harness') . -Recurse
  Remove-Item (Join-Path $T 'harness\.runs'), (Join-Path $T 'harness\.worktrees') -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path (Join-Path $T 'state') | Out-Null
  @'
{
  "project": { "type": "greenfield", "baseline": { "established": false, "ref": null } },
  "models": { "implement": { "model": "primary-x", "fallback": "fallback-x" } },
  "autonomy": { "mode": "supervised", "maxIterations": 5, "maxTurnsPerIteration": 10, "tokenBudget": null, "meterTokens": false, "skipPermissions": false },
  "parallel": { "maxWorkers": 5, "workerMaxTurns": 10, "workerTimeoutSeconds": 180 },
  "components": [ { "name": "root", "path": ".", "gate": { "format": null, "lint": null, "typecheck": null, "build": null, "test": "exit 0", "e2e": null } } ],
  "gate": { "format": null, "lint": null, "typecheck": null, "build": null, "test": null, "e2e": null }
}
'@ | Set-Content 'harness\harness.config.json' -Encoding utf8
  @'
{ "version": 2, "tasks": [
  { "id": "T-A", "category": "functional", "component": "root", "description": "build module A", "steps": ["write a/out.txt"], "acceptance": "a/out.txt exists", "files": ["a/"], "status": "todo", "evidence": "", "passes": false },
  { "id": "T-B", "category": "functional", "component": "root", "description": "build module B", "steps": ["write b/out.txt"], "acceptance": "b/out.txt exists", "files": ["b/"], "status": "todo", "evidence": "", "passes": false },
  { "id": "T-CRASH", "category": "functional", "component": "root", "description": "worker that crashes", "steps": ["exit non-zero"], "acceptance": "n/a", "files": ["c/"], "status": "todo", "evidence": "", "passes": false },
  { "id": "T-EVIL", "category": "functional", "component": "root", "description": "tamper attempt", "steps": ["edit harness engine"], "acceptance": "n/a", "files": ["evil/"], "status": "todo", "evidence": "", "passes": false },
  { "id": "T-FB", "category": "functional", "component": "root", "description": "build via fallback", "steps": ["write fb/out.txt"], "acceptance": "fb/out.txt exists", "files": ["fb/"], "status": "todo", "evidence": "", "passes": false }
] }
'@ | Set-Content 'state\tasks.json' -Encoding utf8
  "- init" | Set-Content 'state\PROGRESS.md' -Encoding utf8
  "harness/.runs/`nharness/.worktrees/`nFLEET_NOTES.md`nstate/handoff.md" | Set-Content '.gitignore' -Encoding ascii
  git add -A; git commit -q -m "init"

  # Stub claude OUTSIDE the repo (an untracked file inside would fail the clean-tree preflight):
  # parses its ownership dir from the piped prompt AND the --model arg the dispatcher passes; the T-EVIL
  # worker tampers with harness/, and T-FB's PRIMARY model hits a usage limit so the worker must fall back.
  $stub = Join-Path $work 'stub-claude.ps1'
  @'
$prompt = ($input | Out-String)
$model = ''
for ($k = 0; $k -lt $args.Count; $k++) { if ($args[$k] -eq '--model' -and ($k + 1) -lt $args.Count) { $model = [string]$args[$k + 1] } }
$dir = ''
if ($prompt -match '(?m)^  - ([a-z]+/)\s*$') { $dir = $Matches[1] }
if ($dir -eq 'c/') {
  exit 1   # the crash path: the runner must record THIS code, not mis-park as a timeout (ratchet)
}
if ($dir -eq 'fb/') {
  # The PRIMARY model emits a usage-limit marker + nonzero exit; the dispatcher must reset + retry on the
  # FALLBACK model, which builds normally. If the worker ignored the fallback, fb/out.txt would never exist.
  if ($model -eq 'primary-x') { Write-Output 'Error: Claude usage limit reached'; exit 1 }
  New-Item -ItemType Directory -Force -Path 'fb' | Out-Null
  'built by fallback' | Set-Content 'fb/out.txt'
  exit 0
}
if ($dir -eq 'evil/') {
  Add-Content -Path 'harness/loop.ps1' -Value 'tampered'
  New-Item -ItemType Directory -Force -Path 'evil' | Out-Null
  'x' | Set-Content 'evil/out.txt'
} elseif ($dir) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  'built by worker' | Set-Content (Join-Path $dir 'out.txt')
}
exit 0
'@ | Set-Content $stub -Encoding ascii

  Write-Host "fleet queue: live-fire with stub claude (merge, record, tamper-park)"
  $env:HARNESS_CLAUDE_CMD = $stub
  try { & (Join-Path $T 'harness\fleet.ps1') *> $null } catch { } finally { Remove-Item Env:HARNESS_CLAUDE_CMD -ErrorAction SilentlyContinue }

  $script:pass = 0; $script:fail = 0
  function ok($name, $cond) { if ($cond) { $script:pass++; Write-Host "  ok  $name" } else { $script:fail++; Write-Host "  FAIL $name" } }
  $tasks  = (Get-Content 'state\tasks.json' -Raw | ConvertFrom-Json).tasks
  $log    = git log --oneline | Out-String
  $ledger = ''
  $ledgerPath = 'harness\.runs\run-001\fleet-ledger.jsonl'
  if (Test-Path $ledgerPath) { $ledger = Get-Content $ledgerPath -Raw }
  ok "T-A output merged to main tree"  (Test-Path 'a\out.txt')
  ok "T-B output merged to main tree"  (Test-Path 'b\out.txt')
  ok "T-EVIL work did NOT land"        (-not (Test-Path 'evil\out.txt'))
  ok "T-A merge commit exists"         ($log -match 'fleet\(T-A\)')
  ok "T-B merge commit exists"         ($log -match 'fleet\(T-B\)')
  ok "no T-EVIL commit"                ($log -notmatch 'fleet\(T-EVIL\)')
  ok "T-A recorded validated"          (($tasks | Where-Object id -eq 'T-A').status -eq 'validated')
  ok "T-B passes=true"                 (($tasks | Where-Object id -eq 'T-B').passes -eq $true)
  ok "T-EVIL still todo"               (($tasks | Where-Object id -eq 'T-EVIL').status -eq 'todo')
  ok "T-EVIL parked in ledger"         ($ledger -match '"T-EVIL"' -and $ledger -match 'parked')
  ok "T-CRASH parked with its real exit code" (($ledger -split "`n" | Where-Object { $_ -match '"T-CRASH"' }) -match 'exited 1')
  ok "T-CRASH work did not land"       (-not (Test-Path 'c'))
  ok "tamper surfaced in handoff.md"   ((Test-Path 'state\handoff.md') -and ((Get-Content 'state\handoff.md' -Raw) -match 'protected path'))
  ok "T-EVIL branch kept"              ((git branch --list 'fleet/*' | Out-String) -match 'T-EVIL')
  ok "T-A branch cleaned up"           ((git branch --list 'fleet/*' | Out-String) -notmatch 'T-A')
  ok "tracked tree clean after fleet"  (-not (git status --porcelain -uno))

  # Cross-vendor fallback (S4): T-FB's primary model was usage-limited, so the worker fell back and its
  # output landed. "built by fallback" content is only written on the fallback arm — proof the worker
  # inherits the loop's primary->fallback dispatch, not just that some model built the file.
  $fbBuilt = (Test-Path 'fb\out.txt') -and ((Get-Content 'fb\out.txt' -Raw).Trim() -eq 'built by fallback')
  ok "T-FB built by the FALLBACK model" $fbBuilt
  ok "T-FB merge commit exists"         ($log -match 'fleet\(T-FB\)')
  ok "T-FB recorded validated"          (($tasks | Where-Object id -eq 'T-FB').status -eq 'validated')

  # Dry-run (S4): -DryRun must invoke NO model and leave NO new fleet worktrees/branches. The stub writes
  # a sentinel if ever run; the run leaves T-CRASH/T-EVIL todo, so dry-run does select+add+cleanup real
  # worktrees — exercising the cleanup path, not a no-op.
  $sentinel = Join-Path $work 'dry-sentinel.txt'
  $dryStub  = Join-Path $work 'stub-dry.ps1'
  @"
'invoked' | Set-Content -LiteralPath '$sentinel'
exit 0
"@ | Set-Content $dryStub -Encoding ascii
  $branchesBefore = @(git branch --list 'fleet/*').Count
  $wtBefore       = @(git worktree list).Count
  $env:HARNESS_CLAUDE_CMD = $dryStub
  try { & (Join-Path $T 'harness\fleet.ps1') -DryRun *> $null } catch { } finally { Remove-Item Env:HARNESS_CLAUDE_CMD -ErrorAction SilentlyContinue }
  ok "dry-run invoked no model"           (-not (Test-Path $sentinel))
  ok "dry-run left no new fleet branches" (@(git branch --list 'fleet/*').Count -eq $branchesBefore)
  ok "dry-run left no new worktrees"      (@(git worktree list).Count -eq $wtBefore)

  # ── Scenario 2: a record-amend failure preserves the pending record in the run dir ─────────────
  # Finding (fix_plan): when `git commit --amend` (folding tasks.json/PROGRESS into the merge commit)
  # FAILS, leaving the files merely STAGED lets a LATER queue entry's reset --hard + clean -fd silently
  # discard them while the ledger already said 'merged'. The fix persists the record to the gitignored
  # run dir (reset-proof) and restores the tree. A pre-commit hook fails the runner's MAIN-tree commits:
  # T-OK's amend (state/ staged) is deferred to the run dir; T-BOOM's merge commit (boom/ staged) fails
  # → triggering the very reset --hard + clean -fd that used to eat T-OK's record.
  $T2 = Join-Path $work 'repo2'
  New-Item -ItemType Directory -Force -Path $T2 | Out-Null
  Set-Location $T2
  git init -q -b main
  git config core.autocrlf false
  git config user.email fleet-test@example.com
  git config user.name "Fleet Test"
  Copy-Item (Join-Path $src 'harness') . -Recurse
  Remove-Item (Join-Path $T2 'harness\.runs'), (Join-Path $T2 'harness\.worktrees') -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path (Join-Path $T2 'state') | Out-Null
  @'
{
  "project": { "type": "greenfield", "baseline": { "established": false, "ref": null } },
  "models": { "implement": { "model": "primary-x", "fallback": "fallback-x" } },
  "autonomy": { "mode": "supervised", "maxIterations": 5, "maxTurnsPerIteration": 10, "tokenBudget": null, "meterTokens": false, "skipPermissions": false },
  "parallel": { "maxWorkers": 5, "workerMaxTurns": 10, "workerTimeoutSeconds": 180 },
  "components": [ { "name": "root", "path": ".", "gate": { "format": null, "lint": null, "typecheck": null, "build": null, "test": "exit 0", "e2e": null } } ],
  "gate": { "format": null, "lint": null, "typecheck": null, "build": null, "test": null, "e2e": null }
}
'@ | Set-Content 'harness\harness.config.json' -Encoding utf8
  @'
{ "version": 2, "tasks": [
  { "id": "T-OK", "category": "functional", "component": "root", "description": "build ok module", "steps": ["write ok/out.txt"], "acceptance": "ok/out.txt exists", "files": ["ok/"], "status": "todo", "evidence": "", "passes": false },
  { "id": "T-BOOM", "category": "functional", "component": "root", "description": "merge commit blocked by a hook", "steps": ["write boom/out.txt"], "acceptance": "boom/out.txt exists", "files": ["boom/"], "status": "todo", "evidence": "", "passes": false }
] }
'@ | Set-Content 'state\tasks.json' -Encoding utf8
  "- init" | Set-Content 'state\PROGRESS.md' -Encoding utf8
  "harness/.runs/`nharness/.worktrees/`nFLEET_NOTES.md`nstate/handoff.md" | Set-Content '.gitignore' -Encoding ascii
  git add -A; git commit -q -m "init"
  # Only the runner's MAIN-tree commits are blocked (a worker's own worktree commit has a toplevel under
  # .worktrees → always passes): a `state/` staged set is T-OK's record amend; a `boom/` staged set is
  # T-BOOM's merge commit. Both fail → the deferral + reset paths fire deterministically. Write LF-only,
  # no BOM — git-for-windows runs the hook through its bundled sh, which chokes on CR.
  $hook = "#!/bin/sh`ntop=`"`$(git rev-parse --show-toplevel)`"`ncase `"`$top`" in *.worktrees*) exit 0;; esac`ngit diff --cached --name-only | grep -qE '^(state/|boom/)' && exit 1`nexit 0`n"
  [System.IO.File]::WriteAllText((Join-Path $T2 '.git\hooks\pre-commit'), $hook)
  $stubOk = Join-Path $work 'stub-ok.ps1'
  @'
$prompt = ($input | Out-String)
$dir = ''
if ($prompt -match '(?m)^  - ([a-z]+/)\s*$') { $dir = $Matches[1] }
if ($dir) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  'built by worker' | Set-Content (Join-Path $dir 'out.txt')
}
exit 0
'@ | Set-Content $stubOk -Encoding ascii

  Write-Host "fleet queue: record-amend failure preserves the pending record in the run dir"
  $env:HARNESS_CLAUDE_CMD = $stubOk
  try { & (Join-Path $T2 'harness\fleet.ps1') *> $null } catch { } finally { Remove-Item Env:HARNESS_CLAUDE_CMD -ErrorAction SilentlyContinue }

  $pend2   = 'harness\.runs\run-001\pending-record-T-OK'
  $ledger2 = ''
  $ledger2Path = 'harness\.runs\run-001\fleet-ledger.jsonl'
  if (Test-Path $ledger2Path) { $ledger2 = Get-Content $ledger2Path -Raw }
  $l2 = $ledger2 -split "`n"
  $pendStatus = if (Test-Path (Join-Path $pend2 'tasks.json')) { ((Get-Content (Join-Path $pend2 'tasks.json') -Raw | ConvertFrom-Json).tasks | Where-Object id -eq 'T-OK').status } else { '' }
  $wtStatus   = ((Get-Content 'state\tasks.json' -Raw | ConvertFrom-Json).tasks | Where-Object id -eq 'T-OK').status
  ok "amend-fail: pending record saved to the run dir"          (Test-Path (Join-Path $pend2 'tasks.json'))
  ok "pending tasks.json holds the intended (validated) record" ($pendStatus -eq 'validated')
  ok "pending PROGRESS.md holds the intended line"              ((Test-Path (Join-Path $pend2 'PROGRESS.md')) -and ((Get-Content (Join-Path $pend2 'PROGRESS.md') -Raw) -match 'merged T-OK'))
  ok "ledger says T-OK merged (the finding's premise)"         (($l2 | Where-Object { $_ -match '"task":"T-OK"' }) -match '"result":"merged"')
  ok "ledger records the deferral for reconciliation"          (($l2 | Where-Object { $_ -match '"task":"T-OK"' }) -match 'record-deferred')
  ok "T-OK merge commit still stands"                          ((git log --oneline | Out-String) -match 'fleet\(T-OK\)')
  ok "working tree NOT left staged (record restored to HEAD)"  ($wtStatus -eq 'todo')
  ok "T-BOOM parked — its merge-commit reset --hard fired"     (($l2 | Where-Object { $_ -match '"task":"T-BOOM"' }) -match 'parked')
  ok "pending record SURVIVED T-BOOM's reset --hard + clean -fd" (Test-Path (Join-Path $pend2 'tasks.json'))

  Write-Host ("FLEET QUEUE RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail)
  if ($script:fail -gt 0) { exit 1 }
  exit 0
} finally {
  Remove-Item Env:HARNESS_ENGINE -ErrorAction SilentlyContinue
  Set-Location $origLoc
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
