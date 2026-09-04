#requires -Version 5.1
<#
  Thin wrapper - dispatches to the lean-agent-harness plugin ENGINE's codex-setup.ps1, passing THIS repo
  as -ProjectRoot. Generated into <project>/harness/codex-setup.ps1 by /harness-init. The generator ships
  inside the installed plugin; this shim only locates it, so `powershell harness/codex-setup.ps1` works
  from a bare terminal (where $env:CLAUDE_PLUGIN_ROOT is NOT set). Re-run after every
  `/plugin update lean-agent-harness` and after any routing change (the output embeds the plugin path).

  Engine discovery order: $env:HARNESS_ENGINE, then $env:CLAUDE_PLUGIN_ROOT/engine, then the newest
  lean-agent-harness engine under ~/.claude/plugins.
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
  $pluginsRoot = Join-Path $HOME '.claude/plugins'
  if (Test-Path $pluginsRoot) {
    $hit = Get-ChildItem -Path $pluginsRoot -Recurse -Filter 'codex-setup.ps1' -ErrorAction SilentlyContinue |
      Where-Object { $_.Directory.Name -eq 'engine' -and $_.FullName -match 'lean-agent-harness' } |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hit) { return $hit.DirectoryName }
  }
  throw "lean-agent-harness engine not found. Install the plugin (/plugin install lean-agent-harness) or set `$env:HARNESS_ENGINE to its engine/ dir."
}

$engine = Find-HarnessEngine
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $engine 'codex-setup.ps1') -ProjectRoot $projectRoot @args
exit $LASTEXITCODE
