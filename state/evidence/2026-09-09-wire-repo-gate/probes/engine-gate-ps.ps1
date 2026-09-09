#requires -Version 5.1
<#
  Arm 1 (Windows path): run the REPO'S OWN configured gate through the real engine
  (plugin/engine/lib/gate.ps1 -> Invoke-ProjectGate), which shells each gate command out through
  `cmd /c`. That cmd.exe hop is the branch the config string had to survive: a forward-slash script
  path is rejected there, and a bare `bash` resolves to WSL (see wsl-trap.ps1) - which is why the
  configured command is `node harness/tests/gate.mjs`.

  The arm carries its own NEGATIVE CONTROL: the same engine call against a config whose gate.test is
  a command that exits 1 must report Passed=False. Without it, `Passed=True` proves only that the
  probe can speak. (The first version of this file also read `if (-not $ok)` on the RESULT OBJECT,
  which is never true - a non-null object is truthy - so the arm exited 0 whatever the gate said.
  Caught in fresh-context review; the property is named explicitly now.)

  Writes its own output file and scrubs the username out of it before returning.

  Run from the repo root:  powershell -NoProfile -ExecutionPolicy Bypass -File state/evidence/2026-09-09-wire-repo-gate/probes/engine-gate-ps.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root   = (Get-Location).Path
$probes = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir = Split-Path -Parent $probes
$outFile = Join-Path $outDir 'engine-gate-ps.txt'
$lines = New-Object System.Collections.ArrayList
function say([string]$s) { [void]$lines.Add($s); Write-Host $s }

. "$root/plugin/engine/lib/gate.ps1"
$cfg = Get-Content "$root/harness/harness.config.json" -Raw | ConvertFrom-Json

say "### arm 1: the repo's configured gate through Invoke-ProjectGate (cmd /c)"
$sw = [Diagnostics.Stopwatch]::StartNew()
$ok = Invoke-ProjectGate -Config $cfg -RepoRoot $root
$sw.Stop()
say ("    Passed={0}  FailedStep='{1}'  Component='{2}'  elapsed={3}s" -f $ok.Passed, $ok.FailedStep, $ok.Component, [int]$sw.Elapsed.TotalSeconds)
$rc = if ($ok.Passed) { 0 } else { 1 }

say ""
say "### negative control: same engine call, gate.test replaced by a command that exits 1"
$bad = Get-Content "$root/harness/harness.config.json" -Raw | ConvertFrom-Json
$bad.components[0].gate.test = 'node -e "process.exit(1)"'
$ctl = Invoke-ProjectGate -Config $bad -RepoRoot $root
say ("    Passed={0}  FailedStep='{1}'  Component='{2}'" -f $ctl.Passed, $ctl.FailedStep, $ctl.Component)
if ($ctl.Passed) { say "    x CONTROL DID NOT GO RED - this arm cannot accuse; its green above means nothing"; $rc = 1 }
else             { say "    ok control went red, so the green above is a real verdict" }

say ""
say ("RESULT: arm 1 {0}" -f $(if ($rc -eq 0) { 'GREEN' } else { 'RED' }))
$lines | Set-Content -Path $outFile -Encoding UTF8
& node (Join-Path $probes 'scrub.mjs') $outFile | Out-Null
exit $rc
