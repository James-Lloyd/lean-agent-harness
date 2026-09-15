#requires -Version 5.1
[CmdletBinding()]
param([string] $PromptPath)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (-not $PromptPath) { $PromptPath = Join-Path $root 'PROMPT.md' }
$text = Get-Content -Raw -LiteralPath $PromptPath
$normalized = $text -replace '\s+', ' '
$script:passed = 0
$script:failed = 0

function Test-Contract([string]$name, [bool]$condition) {
  if ($condition) { Write-Host "  ok  $name"; $script:passed++ }
  else { Write-Host "  FAIL $name"; $script:failed++ }
}

Test-Contract 'caps model-side verification at two shell commands' `
  ($normalized -cmatch 'at most two shell verification commands')
Test-Contract 'requests a per-command tool timeout no greater than 120 seconds' `
  ($normalized -cmatch 'tool timeout no greater than 120 seconds')
Test-Contract 'forbids background or detached verification' `
  ($normalized -cmatch 'Never start verification in the background or as a detached process')
Test-Contract 'forbids the model from invoking configured complete gates' `
  ($normalized -cmatch 'Never invoke a configured complete component or root gate command')
Test-Contract 'allows a configured gate command only as quoted comparison or search data' `
  ($normalized -cmatch 'Reading, searching for, or comparing the configured command as quoted data is allowed')
Test-Contract 'forbids direct and delegated gate execution' `
  ($normalized -cmatch 'executing it directly or through a shell, script, function, subprocess, or wrapper is not')
Test-Contract 'keeps failed or timed-out targeted checks visible' `
  ($normalized -cmatch 'report it plainly in the transcript; do not hide it or convert it into success')
Test-Contract 'names the runner complete gate as the authority' `
  ($normalized -cmatch "Only that runner gate can make the iteration green")
Test-Contract 'removes the old model-side complete-gate requirement' `
  (-not ($normalized -cmatch "The changed component's gate, then the cross-cutting root gate, all pass"))

Write-Host "`nRESULT: $($script:passed) passed, $($script:failed) failed"
if ($script:failed -gt 0) { exit 1 }
