# Operational smoke checks; no product source or configuration is changed.
param([string]$ProjectRoot = 'D:/Repos/harness')
$ErrorActionPreference = 'Stop'
$evidenceRoot = $PSScriptRoot
function Capture([string]$Name, [scriptblock]$Command) {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $output = (& $Command 2>&1 | Out-String)
  $code = $LASTEXITCODE
  $watch.Stop()
  $output = $output.Replace($env:USERPROFILE, '<home>').Replace($env:USERPROFILE.Replace('\','/'), '<home>')
  $output = $output.Replace($ProjectRoot, '<repo>').Replace($ProjectRoot.Replace('/','\'), '<repo>')
  $msysRoot = '/' + $ProjectRoot.Substring(0,1).ToLowerInvariant() + $ProjectRoot.Substring(2).Replace('\','/')
  $output = $output.Replace($msysRoot, '<repo>')
  $text = "exit=$code durationSeconds=$([math]::Round($watch.Elapsed.TotalSeconds,2))`n$output"
  [IO.File]::WriteAllText((Join-Path $evidenceRoot "$Name.txt"), $text)
  Write-Output "$Name exit=$code durationSeconds=$([math]::Round($watch.Elapsed.TotalSeconds,2))"
  if ($code -ne 0) { throw "$Name failed" }
}
Capture 'powershell-freshness' { & powershell -NoProfile -ExecutionPolicy Bypass -File "$ProjectRoot/harness/codex-setup.ps1" -Check }
Capture 'bash-freshness' { & 'C:/Program Files/Git/bin/bash.exe' "$ProjectRoot/harness/codex-setup.sh" --check }
Capture 'powershell-loop-dry-run' { & powershell -NoProfile -ExecutionPolicy Bypass -File "$ProjectRoot/harness/loop.ps1" -DryRun }
Capture 'bash-loop-dry-run' { & 'C:/Program Files/Git/bin/bash.exe' "$ProjectRoot/harness/loop.sh" --dry-run }
Capture 'package-validation' { & node "$ProjectRoot/plugin/scripts/validate-openai-plugin.mjs" }
