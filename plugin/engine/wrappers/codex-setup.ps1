#requires -Version 5.1
<#
  Thin wrapper - dispatches to the lean-agent-harness plugin ENGINE's codex-setup.ps1, passing THIS repo
  as -ProjectRoot. Generated into <project>/harness/codex-setup.ps1 by /harness-init. The generator ships
  inside the installed plugin; this shim only locates it, so `powershell harness/codex-setup.ps1` works
  from a bare terminal (where $env:CLAUDE_PLUGIN_ROOT is NOT set). Re-run after every
  `/plugin update lean-agent-harness` and after any routing change (the output embeds the plugin path).
  Also run /harness-doctor after each update and replace all six wrappers from the installed package
  if it reports wrapper drift.

  Engine discovery order: $env:HARNESS_ENGINE, then $env:CLAUDE_PLUGIN_ROOT/engine, then the newest
  lean-agent-harness engine under the Codex or Claude plugin cache.
#>
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot   # <repo>/harness/codex-setup.ps1 -> <repo>

function Find-HarnessEngine {
  if ($env:HARNESS_ENGINE -and (Test-Path (Join-Path $env:HARNESS_ENGINE 'codex-setup.ps1'))) {
    return (Resolve-Path $env:HARNESS_ENGINE).Path
  }
  if ($env:CLAUDE_PLUGIN_ROOT -and (Test-Path (Join-Path $env:CLAUDE_PLUGIN_ROOT 'engine/codex-setup.ps1'))) {
    return (Resolve-Path (Join-Path $env:CLAUDE_PLUGIN_ROOT 'engine')).Path
  }
  $candidates = foreach ($pluginsRoot in @((Join-Path $HOME '.codex/plugins/cache'), (Join-Path $HOME '.claude/plugins'))) {
    if (-not (Test-Path $pluginsRoot)) { continue }
    Get-ChildItem -Path $pluginsRoot -Recurse -Filter 'codex-setup.ps1' -ErrorAction SilentlyContinue |
      Where-Object { $_.Directory.Name -eq 'engine' -and $_.FullName -match 'lean-agent-harness' } |
      ForEach-Object {
        $versionText = $_.Directory.Parent.Name
        if ($versionText -match '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
          try {
            $version = [version]$versionText
            [pscustomobject]@{ Path = $_.DirectoryName; Version = $version; Modified = $_.LastWriteTimeUtc }
          } catch { }
        }
      }
  }
  $hit = $candidates | Sort-Object -Property @{ Expression = 'Version'; Descending = $true }, @{ Expression = 'Modified'; Descending = $true } | Select-Object -First 1
  if ($hit) { return $hit.Path }
  throw "lean-agent-harness engine not found. Install the plugin (/plugin install lean-agent-harness) or set `$env:HARNESS_ENGINE to its engine/ dir."
}

$engine = Find-HarnessEngine
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $engine 'codex-setup.ps1') -ProjectRoot $projectRoot @args
exit $LASTEXITCODE
