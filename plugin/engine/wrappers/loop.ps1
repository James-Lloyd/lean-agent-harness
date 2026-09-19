#requires -Version 5.1
<#
  Thin wrapper — dispatches to the lean-agent-harness plugin ENGINE, passing THIS repo as -ProjectRoot.

  Generated into <project>/harness/loop.ps1 by /harness-init. The real loop ships inside the installed
  plugin; this 20-line shim only locates it, so `powershell harness/loop.ps1 ...` keeps working from a
  bare terminal or cron — where $env:CLAUDE_PLUGIN_ROOT is NOT set (it exists only inside Claude Code).

  Engine discovery order:
    1. $env:HARNESS_ENGINE            (absolute path to the plugin's engine/ dir — set this to pin it)
    2. $env:CLAUDE_PLUGIN_ROOT/engine (when invoked from within Claude Code)
    3. a search under the Codex and Claude plugin caches for the installed engine
  Upgrade the engine with `/plugin update lean-agent-harness`; this wrapper does not change.
#>
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot   # <repo>/harness/loop.ps1 -> <repo>

function Find-HarnessEngine {
  if ($env:HARNESS_ENGINE -and (Test-Path (Join-Path $env:HARNESS_ENGINE 'loop.ps1'))) {
    return (Resolve-Path $env:HARNESS_ENGINE).Path
  }
  if ($env:CLAUDE_PLUGIN_ROOT -and (Test-Path (Join-Path $env:CLAUDE_PLUGIN_ROOT 'engine/loop.ps1'))) {
    return (Resolve-Path (Join-Path $env:CLAUDE_PLUGIN_ROOT 'engine')).Path
  }
  $candidates = foreach ($pluginsRoot in @((Join-Path $HOME '.codex/plugins/cache'), (Join-Path $HOME '.claude/plugins'))) {
    if (-not (Test-Path $pluginsRoot)) { continue }
    Get-ChildItem -Path $pluginsRoot -Recurse -Filter 'loop.ps1' -ErrorAction SilentlyContinue |
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
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $engine 'loop.ps1') -ProjectRoot $projectRoot @args
exit $LASTEXITCODE
