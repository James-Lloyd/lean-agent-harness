#requires -Version 5.1
<#
  Thin wrapper — dispatches to the lean-agent-harness plugin ENGINE (fleet runner), passing THIS repo
  as -ProjectRoot. Generated into <project>/harness/fleet.ps1 by /harness-init. See harness/loop.ps1 in
  this project for the engine-discovery contract; upgrade with `/plugin update lean-agent-harness`.
#>
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot   # <repo>/harness/fleet.ps1 -> <repo>

function Find-HarnessEngine {
  if ($env:HARNESS_ENGINE -and (Test-Path (Join-Path $env:HARNESS_ENGINE 'fleet.ps1'))) {
    return (Resolve-Path $env:HARNESS_ENGINE).Path
  }
  if ($env:CLAUDE_PLUGIN_ROOT -and (Test-Path (Join-Path $env:CLAUDE_PLUGIN_ROOT 'engine/fleet.ps1'))) {
    return (Resolve-Path (Join-Path $env:CLAUDE_PLUGIN_ROOT 'engine')).Path
  }
  $pluginsRoot = Join-Path $HOME '.claude/plugins'
  if (Test-Path $pluginsRoot) {
    $hit = Get-ChildItem -Path $pluginsRoot -Recurse -Filter 'fleet.ps1' -ErrorAction SilentlyContinue |
      Where-Object { $_.Directory.Name -eq 'engine' -and $_.FullName -match 'lean-agent-harness' } |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hit) { return $hit.DirectoryName }
  }
  throw "lean-agent-harness engine not found. Install the plugin (/plugin install lean-agent-harness) or set `$env:HARNESS_ENGINE to its engine/ dir."
}

$engine = Find-HarnessEngine
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $engine 'fleet.ps1') -ProjectRoot $projectRoot @args
exit $LASTEXITCODE
