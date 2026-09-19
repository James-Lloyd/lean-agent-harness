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
  $candidates = foreach ($pluginsRoot in @((Join-Path $HOME '.codex/plugins/cache'), (Join-Path $HOME '.claude/plugins'))) {
    if (-not (Test-Path $pluginsRoot)) { continue }
    Get-ChildItem -Path $pluginsRoot -Recurse -Filter 'fleet.ps1' -ErrorAction SilentlyContinue |
      Where-Object { $_.Directory.Name -eq 'engine' -and $_.FullName -match 'lean-agent-harness' } |
      ForEach-Object {
        $version = [version]'0.0.0'
        try { $version = [version](($_.Directory.Parent.Name -split '[-+]')[0]) } catch { }
        [pscustomobject]@{ Path = $_.DirectoryName; Version = $version; Modified = $_.LastWriteTimeUtc }
      }
  }
  $hit = $candidates | Sort-Object -Property @{ Expression = 'Version'; Descending = $true }, @{ Expression = 'Modified'; Descending = $true } | Select-Object -First 1
  if ($hit) { return $hit.Path }
  throw "lean-agent-harness engine not found. Install the plugin (/plugin install lean-agent-harness) or set `$env:HARNESS_ENGINE to its engine/ dir."
}

$engine = Find-HarnessEngine
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $engine 'fleet.ps1') -ProjectRoot $projectRoot @args
exit $LASTEXITCODE
