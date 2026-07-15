#requires -Version 5.1
<#
  migrate-test.ps1 — end-to-end self-test for engine/migrate.ps1 (acceptance criterion 2). Builds a
  synthetic copied-in harness in a temp dir carrying one of each class, runs the report then --apply,
  and asserts the ratchet + project skill survive, IDENTICAL files are removed, settings.json is
  surgically stripped, and the runner wrappers land. Self-contained; exit 0 = pass, 1 = fail.

  Run:  powershell -NoProfile -ExecutionPolicy Bypass -File harness/tests/migrate-test.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot   = Split-Path (Split-Path $here -Parent) -Parent
$pluginRoot = Join-Path $repoRoot 'plugin'
$engineDir  = Join-Path $pluginRoot 'engine'
$migrate    = Join-Path $engineDir 'migrate.ps1'
$psHost     = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }

$script:pass = 0; $script:fail = 0
function ok($name, $cond) {
  if ($cond) { $script:pass++; Write-Host "  ok  $name" -ForegroundColor Green }
  else       { $script:fail++; Write-Host "  FAIL $name" -ForegroundColor Red }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("migrate-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
function New-Dir($p) { New-Item -ItemType Directory -Force -Path $p | Out-Null }

try {
  New-Dir $tmp
  New-Dir (Join-Path $tmp '.claude/agents')
  New-Dir (Join-Path $tmp '.claude/commands')
  New-Dir (Join-Path $tmp '.claude/skills/proj-thing')
  New-Dir (Join-Path $tmp '.claude/hooks')
  New-Dir (Join-Path $tmp 'harness/lib')
  New-Dir (Join-Path $tmp 'state')
  New-Dir (Join-Path $tmp 'specs')

  # --- IDENTICAL: copy plugin files verbatim ---
  Copy-Item (Join-Path $pluginRoot 'agents/explorer.md')          (Join-Path $tmp '.claude/agents/explorer.md')
  Copy-Item (Join-Path $pluginRoot 'commands/handoff.md')         (Join-Path $tmp '.claude/commands/handoff.md')
  New-Dir (Join-Path $tmp '.claude/skills/e2e-evidence')
  Copy-Item (Join-Path $pluginRoot 'skills/e2e-evidence/SKILL.md') (Join-Path $tmp '.claude/skills/e2e-evidence/SKILL.md')
  Copy-Item (Join-Path $pluginRoot 'hooks/protect-specs.ps1')     (Join-Path $tmp '.claude/hooks/protect-specs.ps1')
  Copy-Item (Join-Path $pluginRoot 'hooks/block-destructive.sh')  (Join-Path $tmp '.claude/hooks/block-destructive.sh')
  Copy-Item (Join-Path $pluginRoot 'engine/lib/gate.ps1')         (Join-Path $tmp 'harness/lib/gate.ps1')
  Copy-Item (Join-Path $pluginRoot 'engine/harness.schema.json')  (Join-Path $tmp 'harness/harness.schema.json')

  # --- DIFFERS: a ratcheted block-destructive.ps1 (copy, then append a denylist pattern) ---
  $bdPath = Join-Path $tmp '.claude/hooks/block-destructive.ps1'
  Copy-Item (Join-Path $pluginRoot 'hooks/block-destructive.ps1') $bdPath
  Add-Content -LiteralPath $bdPath -Value "# RATCHET: block 'terraform destroy' (added by this project)"
  $bdMutated = [System.IO.File]::ReadAllBytes($bdPath)

  # --- PROJECT-ONLY: a project-authored skill ---
  Set-Content -LiteralPath (Join-Path $tmp '.claude/skills/proj-thing/SKILL.md') -Value "# proj-thing`nA project-authored skill with no plugin counterpart." -Encoding utf8

  # --- PROJECT-ONLY hook whose filename EMBEDS an engine hook name (finding 3 decoy) ---
  Set-Content -LiteralPath (Join-Path $tmp '.claude/hooks/my-block-destructive.sh') -Value "#!/usr/bin/env bash`n# project-owned hook — must NOT be stripped as 'block-destructive'" -Encoding utf8

  # --- Runners: DIFFERS copies of the engine scripts (become wrappers with --replace-runners) ---
  foreach ($rn in @('loop.ps1', 'loop.sh', 'fleet.ps1', 'fleet.sh')) {
    $dst = Join-Path $tmp "harness/$rn"
    Copy-Item (Join-Path $engineDir $rn) $dst
    Add-Content -LiteralPath $dst -Value "# local tweak $rn"
  }

  # --- Never-touched scaffold ---
  $cfgJson = '{ "autonomy": { "mode": "supervised" }, "verification": {} }'
  Set-Content -LiteralPath (Join-Path $tmp 'harness/harness.config.json') -Value $cfgJson -Encoding utf8
  Set-Content -LiteralPath (Join-Path $tmp 'CLAUDE.md')      -Value "# Project map (must not be touched)" -Encoding utf8
  Set-Content -LiteralPath (Join-Path $tmp 'AGENT_NOTES.md') -Value "# notes (must not be touched)"       -Encoding utf8
  Set-Content -LiteralPath (Join-Path $tmp 'state/PROGRESS.md') -Value "log"  -Encoding utf8
  Set-Content -LiteralPath (Join-Path $tmp 'specs/000.md')      -Value "spec" -Encoding utf8
  $cfgBytes    = [System.IO.File]::ReadAllBytes((Join-Path $tmp 'harness/harness.config.json'))
  $claudeBytes = [System.IO.File]::ReadAllBytes((Join-Path $tmp 'CLAUDE.md'))
  $notesBytes  = [System.IO.File]::ReadAllBytes((Join-Path $tmp 'AGENT_NOTES.md'))
  $specBytes   = [System.IO.File]::ReadAllBytes((Join-Path $tmp 'specs/000.md'))

  # --- settings.json: all 5 engine hooks + one project hook + model + permissions ---
  $settingsJson = @'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "model": "opus",
  "permissions": {
    "allow": ["Read", "Edit", "Write"],
    "deny": ["Read(./**/.env)"]
  },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash|PowerShell", "hooks": [ { "type": "command", "command": "powershell -File \"${CLAUDE_PROJECT_DIR}/.claude/hooks/block-destructive.ps1\"", "timeout": 30 } ] },
      { "matcher": "Edit|Write|MultiEdit|NotebookEdit", "hooks": [ { "type": "command", "command": "powershell -File \"${CLAUDE_PROJECT_DIR}/.claude/hooks/protect-specs.ps1\"", "timeout": 30 } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/project-notify.sh\"", "timeout": 10 } ] },
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/my-block-destructive.sh\"", "timeout": 10 } ] }
    ],
    "PostToolUse": [
      { "matcher": "Edit|Write|MultiEdit|NotebookEdit", "hooks": [ { "type": "command", "command": "powershell -File \"${CLAUDE_PROJECT_DIR}/.claude/hooks/format-and-check.ps1\"", "timeout": 120 } ] }
    ],
    "ConfigChange": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "powershell -File \"${CLAUDE_PROJECT_DIR}/.claude/hooks/lock-config.ps1\"", "timeout": 15 } ] }
    ],
    "SessionStart": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "powershell -File \"${CLAUDE_PROJECT_DIR}/.claude/hooks/session-start.ps1\"", "timeout": 30 } ] }
    ]
  }
}
'@
  $settingsPath = Join-Path $tmp '.claude/settings.json'
  [System.IO.File]::WriteAllText($settingsPath, $settingsJson, (New-Object System.Text.UTF8Encoding($false)))

  # === REPORT (no flags): classifies, writes nothing ===
  Write-Host "migrate: report (no flags)"
  $out = (& $psHost -NoProfile -ExecutionPolicy Bypass -File $migrate -ProjectRoot $tmp 2>&1 | Out-String)
  $rc = $LASTEXITCODE
  ok "report exits 0" ($rc -eq 0)
  ok "report shows IDENTICAL class"    ($out -match 'IDENTICAL')
  ok "report shows DIFFERS class"      ($out -match 'DIFFERS')
  ok "report shows PROJECT-ONLY class" ($out -match 'PROJECT-ONLY')
  ok "report names the ratcheted hook" ($out -match 'block-destructive\.ps1')
  ok "report names the project skill"  ($out -match 'proj-thing')
  ok "report wrote nothing (IDENTICAL file still present)" (Test-Path (Join-Path $tmp 'harness/lib/gate.ps1'))
  ok "report wrote no MIGRATION-REPORT.md" (-not (Test-Path (Join-Path $tmp 'harness/MIGRATION-REPORT.md')))

  # === APPLY without -Force on a NON-git target must REFUSE (finding 4) ===
  Write-Host "migrate: --apply on non-git without -Force (must refuse)"
  # The child writes the refusal to stderr; under EAP=Stop that surfaces as a terminating
  # NativeCommandError in THIS script, so drop to Continue around the expected-to-fail call.
  $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $null = (& $psHost -NoProfile -ExecutionPolicy Bypass -File $migrate -ProjectRoot $tmp -Apply 2>&1 | Out-String)
  $noForceRc = $LASTEXITCODE
  $ErrorActionPreference = $prevEAP
  ok "non-git --apply without -Force exits non-zero" ($noForceRc -ne 0)
  ok "non-git --apply without -Force changed nothing" (Test-Path (Join-Path $tmp 'harness/lib/gate.ps1'))

  # === APPLY ===
  Write-Host "migrate: --apply --replace-runners --force"
  $out2 = (& $psHost -NoProfile -ExecutionPolicy Bypass -File $migrate -ProjectRoot $tmp -Apply -ReplaceRunners -Force 2>&1 | Out-String)
  $rc2 = $LASTEXITCODE
  ok "apply exits 0" ($rc2 -eq 0)

  # Preservations
  ok "ratcheted block-destructive.ps1 still present" (Test-Path $bdPath)
  $bdAfter = if (Test-Path $bdPath) { [System.IO.File]::ReadAllBytes($bdPath) } else { @() }
  ok "ratcheted hook is byte-for-byte UNCHANGED" (($bdAfter.Length -eq $bdMutated.Length) -and (-not (Compare-Object $bdAfter $bdMutated)))
  ok "project skill proj-thing/SKILL.md still present" (Test-Path (Join-Path $tmp '.claude/skills/proj-thing/SKILL.md'))

  # Removals (IDENTICAL)
  ok "IDENTICAL harness/lib/gate.ps1 removed"       (-not (Test-Path (Join-Path $tmp 'harness/lib/gate.ps1')))
  ok "IDENTICAL .claude/agents/explorer.md removed" (-not (Test-Path (Join-Path $tmp '.claude/agents/explorer.md')))
  ok "IDENTICAL protect-specs.ps1 removed"          (-not (Test-Path (Join-Path $tmp '.claude/hooks/protect-specs.ps1')))
  ok "IDENTICAL harness.schema.json removed"        (-not (Test-Path (Join-Path $tmp 'harness/harness.schema.json')))
  ok "emptied harness/lib dir pruned"               (-not (Test-Path (Join-Path $tmp 'harness/lib')))
  ok "skills dir kept (proj-thing survives)"        (Test-Path (Join-Path $tmp '.claude/skills'))

  # settings.json surgery
  $sAfterRaw = Get-Content -LiteralPath $settingsPath -Raw
  $sAfter    = $sAfterRaw | ConvertFrom-Json
  ok "settings.json still valid JSON"               ($null -ne $sAfter)
  # block-destructive.ps1 is DIFFERS-kept (ratchet) => its wiring MUST be kept so the ratchet keeps firing.
  ok "settings KEEPS block-destructive wiring (DIFFERS-kept ratchet)" ($sAfterRaw -match 'block-destructive\.ps1')
  ok "settings lost protect-specs wiring (IDENTICAL removed)"         ($sAfterRaw -notmatch 'protect-specs')
  ok "settings lost format-and-check wiring"        ($sAfterRaw -notmatch 'format-and-check')
  ok "settings lost lock-config wiring"             ($sAfterRaw -notmatch 'lock-config')
  ok "settings lost session-start wiring"           ($sAfterRaw -notmatch 'session-start')
  ok "settings KEEPS the project-specific hook"     ($sAfterRaw -match 'project-notify')
  # finding 3: a project hook whose name embeds an engine hook name must NOT be stripped.
  ok "settings KEEPS my-block-destructive wiring (left-boundary)" ($sAfterRaw -match 'my-block-destructive')
  ok "project hook file my-block-destructive.sh kept"            (Test-Path (Join-Path $tmp '.claude/hooks/my-block-destructive.sh'))
  ok "settings KEEPS model=opus"                    ($sAfter.model -eq 'opus')
  ok "settings KEEPS permissions.allow"             ($null -ne $sAfter.permissions -and ($sAfter.permissions.allow -contains 'Read'))
  ok "emptied hook events pruned (no PostToolUse)"  (-not ($sAfter.hooks.PSObject.Properties['PostToolUse']))
  ok "PreToolUse survives (project hook)"           ($null -ne $sAfter.hooks.PSObject.Properties['PreToolUse'])

  # Runner wrappers
  $wrapperOk = $true; $bakOk = $true
  foreach ($rn in @('loop.ps1', 'loop.sh', 'fleet.ps1', 'fleet.sh')) {
    $rp = Join-Path $tmp "harness/$rn"
    if (-not (Test-Path $rp) -or ((Get-Content -LiteralPath $rp -Raw) -notmatch 'HARNESS_ENGINE')) { $wrapperOk = $false }
    if (-not (Test-Path (Join-Path $tmp "harness/$rn.pre-plugin.bak"))) { $bakOk = $false }
  }
  ok "all 4 runners replaced by wrappers" $wrapperOk
  ok "all 4 runners backed up to .pre-plugin.bak" $bakOk

  # Never-touched scaffold
  ok "harness.config.json untouched" (-not (Compare-Object ([System.IO.File]::ReadAllBytes((Join-Path $tmp 'harness/harness.config.json'))) $cfgBytes))
  ok "CLAUDE.md untouched"           (-not (Compare-Object ([System.IO.File]::ReadAllBytes((Join-Path $tmp 'CLAUDE.md'))) $claudeBytes))
  ok "AGENT_NOTES.md untouched"      (-not (Compare-Object ([System.IO.File]::ReadAllBytes((Join-Path $tmp 'AGENT_NOTES.md'))) $notesBytes))
  ok "specs/ untouched"              (-not (Compare-Object ([System.IO.File]::ReadAllBytes((Join-Path $tmp 'specs/000.md'))) $specBytes))

  # Report file
  $reportPath = Join-Path $tmp 'harness/MIGRATION-REPORT.md'
  ok "MIGRATION-REPORT.md written" (Test-Path $reportPath)
  $rep = if (Test-Path $reportPath) { Get-Content -LiteralPath $reportPath -Raw } else { '' }
  ok "report lists Removed / DIFFERS / PROJECT-ONLY" (($rep -match 'Removed') -and ($rep -match 'DIFFERS') -and ($rep -match 'PROJECT-ONLY'))
  ok "report warns the customized hook's wiring was KEPT" ($rep -match 'WARN' -and $rep -match 'block-destructive')
}
finally {
  if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
