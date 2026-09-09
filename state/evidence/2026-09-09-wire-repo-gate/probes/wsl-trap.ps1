#requires -Version 5.1
<#
  Arm 0 - the measured fact that made the gate command a .mjs and not a .sh.

  The engine runs a gate command through `cmd /c` on Windows (plugin/engine/lib/gate.ps1,
  Invoke-GateStep). Inside cmd.exe, `bash` is NOT Git Bash: Git Bash is only on PATH inside a Git
  Bash session. What cmd.exe resolves is WSL's C:\Windows\System32\bash.exe. On a box without WSL
  that is a hard failure; on a box WITH WSL it would silently run the suite in another OS, against
  another filesystem view - worse than failing.

  The rejected candidate was `bash harness/tests/gate.sh`. That file was never committed, so this
  probe exercises the launcher alone (`bash -c` with a trivial command): the failure happens before
  any script is read, which is the point - the interpreter is the wrong program.

  Writes its own output file and scrubs the username out of it.

  Run from the repo root:  powershell -NoProfile -ExecutionPolicy Bypass -File state/evidence/2026-09-09-wire-repo-gate/probes/wsl-trap.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$probes = Split-Path -Parent $MyInvocation.MyCommand.Path
$outFile = Join-Path (Split-Path -Parent $probes) 'wsl-trap.txt'
$lines = New-Object System.Collections.ArrayList
function say($s) { foreach ($l in @($s)) { [void]$lines.Add([string]$l); Write-Host $l } }

say "### what bash resolves to inside cmd.exe (the shell the Windows gate uses)"
say (& cmd /c "where bash 2>&1")
say "    where-exit=$LASTEXITCODE"
say ""
say "### the rejected gate command's launcher, run exactly as gate.ps1 would run it"
say (& cmd /c "bash -c ""echo from-bash"" 2>&1")
say "    exit=$LASTEXITCODE"
say ""
say "### control: the same lookup from inside Git Bash finds Git's own bash, and it works"
$gitBash = Join-Path ${env:ProgramFiles} 'Git\bin\bash.exe'
if (Test-Path $gitBash) { say (& $gitBash -c "command -v bash; uname -s; echo from-bash") }
else { say "    (Git Bash not at $gitBash)" }
say ""
say "### and the accepted command's launcher IS visible to cmd.exe"
say (& cmd /c "where node 2>&1")
say "    where-exit=$LASTEXITCODE"
say (& cmd /c "node -e ""console.log('from-node')"" 2>&1")
say "    exit=$LASTEXITCODE"

$lines | Set-Content -Path $outFile -Encoding UTF8
& node (Join-Path $probes 'scrub.mjs') $outFile | Out-Null
