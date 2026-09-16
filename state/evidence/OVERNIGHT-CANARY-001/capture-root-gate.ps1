param(
  [string]$OutputDir = $PSScriptRoot,
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$evidenceRoot = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $evidenceRoot '..\..\..')).Path
$outputRoot = [IO.Path]::GetFullPath($OutputDir)
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null
$captureHook = Join-Path $evidenceRoot 'gate-capture.cjs'
$homePath = [Environment]::GetFolderPath('UserProfile')
$userName = Split-Path -Leaf $homePath

function New-FlexiblePathPattern([string]$Path) {
  $normalized = $Path.Replace('\', '/')
  if ($normalized -notmatch '^([A-Za-z]):/(.+)$') {
    throw "Expected an absolute drive path, got: $Path"
  }
  $drive = [regex]::Escape($Matches[1])
  $separator = '[/\\]+'
  $tail = $Matches[2].Split('/') | Where-Object { $_ } | ForEach-Object { [regex]::Escape($_) }
  return '(?i)(?:{0}:|{1}{0}){1}{2}' -f $drive, $separator, ($tail -join $separator)
}

function ConvertTo-ScrubbedEvidence([string]$Text) {
  $patterns = @(
    @{ Pattern = New-FlexiblePathPattern $repoRoot; Token = '<REPO>' },
    @{ Pattern = New-FlexiblePathPattern $homePath; Token = '<HOME>' }
  )
  do {
    $before = $Text
    foreach ($entry in $patterns) {
      $Text = [regex]::Replace($Text, $entry.Pattern, $entry.Token)
    }
  } while ($Text -ne $before)
  return $Text -replace '[ \t]+(?=\r?\n|$)', ''
}

function ConvertTo-LegacyScrubbedEvidence([string]$Text) {
  return $Text.Replace($repoRoot, '<REPO>')
}

function Assert-NoUserPath([string]$Path, [string]$Text) {
  if ([regex]::IsMatch($Text, [regex]::Escape($userName), 'IgnoreCase')) {
    throw "Unscrubbed username remains in $Path"
  }
  Push-Location (Split-Path -Parent $Path)
  try {
    $grepOutput = & git grep --no-index -a -n -F -e $userName -- (Split-Path -Leaf $Path) 2>&1
    $grepExit = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  if ($grepExit -eq 0) {
    throw "Binary-inclusive git grep found an unsanitized username in $Path`: $grepOutput"
  }
  if ($grepExit -gt 1) {
    throw "Binary-inclusive git grep failed with exit $grepExit`: $grepOutput"
  }
}

if ($SelfTest) {
  $repoForward = $repoRoot.Replace('\', '/')
  $repoMsys = '/' + $repoForward.Substring(0, 1).ToLowerInvariant() + $repoForward.Substring(2)
  $homeForward = $homePath.Replace('\', '/')
  $homeMsys = '/' + $homeForward.Substring(0, 1).ToLowerInvariant() + $homeForward.Substring(2)
  $fixtures = [ordered]@{
    'native repo path' = $repoRoot
    'forward-slash repo path' = $repoForward
    'doubled-backslash repo path' = $repoRoot.Replace('\', '\\')
    'doubled-forward-slash repo path' = $repoForward.Replace('/', '//')
    'MSYS repo path' = $repoMsys
    'doubled-separator MSYS repo path' = $repoMsys.Replace('/', '//')
    'mixed-separator repo path' = $repoRoot.Replace('\', '//')
    'doubled-separator MSYS home path' = $homeMsys.Replace('/', '//')
  }
  $legacyMutants = [ordered]@{
    'legacy mutant caught by doubled-backslash path' = $repoRoot.Replace('\', '\\')
    'legacy mutant caught by doubled-forward-slash path' = $repoForward.Replace('/', '//')
    'legacy mutant caught by doubled-separator MSYS path' = $repoMsys.Replace('/', '//')
    'legacy mutant caught by mixed-separator path' = $repoRoot.Replace('\', '//')
  }
  $outputOverride = if ($outputRoot -ne [IO.Path]::GetFullPath($evidenceRoot)) { ' -OutputDir <OUTPUT_DIR>' } else { '' }
  $lines = @("COMMAND: powershell -NoProfile -ExecutionPolicy Bypass -File state/evidence/OVERNIGHT-CANARY-001/capture-root-gate.ps1 -SelfTest$outputOverride")
  $failed = 0
  foreach ($fixture in $fixtures.GetEnumerator()) {
    $scrubbed = ConvertTo-ScrubbedEvidence "before $($fixture.Value) after"
    $passed = $scrubbed -notmatch [regex]::Escape($userName) -and $scrubbed -match '<(?:REPO|HOME)>'
    if (-not $passed) { $failed++ }
    $lines += "  $(if ($passed) { 'ok' } else { 'not ok' })  $($fixture.Key)"
  }
  foreach ($mutant in $legacyMutants.GetEnumerator()) {
    $mutantInput = "before $($mutant.Value) after"
    $legacyOutput = [string](ConvertTo-LegacyScrubbedEvidence $mutantInput)
    $caught = $legacyOutput -ceq $mutantInput
    if (-not $caught) { $failed++ }
    $lines += "  $(if ($caught) { 'ok' } else { 'not ok' })  $($mutant.Key)"
  }
  $lines += ''
  $total = $fixtures.Count + $legacyMutants.Count
  $lines += "RESULT: $($total - $failed) passed, $failed failed"
  $lines += "EXIT_CODE: $(if ($failed -eq 0) { 0 } else { 1 })"
  $lines += ''
  $selfTestOutput = ($lines -join "`n")
  $selfTestPath = Join-Path $outputRoot 'scrubber-check.txt'
  Set-Content -LiteralPath $selfTestPath -Value $selfTestOutput -NoNewline -Encoding utf8
  Assert-NoUserPath $selfTestPath $selfTestOutput
  Write-Output $selfTestOutput
  exit $(if ($failed -eq 0) { 0 } else { 1 })
}

$capture = Join-Path $outputRoot 'root-gate.txt'
$previousCapture = $env:HARNESS_GATE_CAPTURE
$previousActive = $env:HARNESS_GATE_CAPTURE_ACTIVE
$previousNodeOptions = $env:NODE_OPTIONS

Set-Content -LiteralPath $capture -Value '' -NoNewline -Encoding utf8
$env:HARNESS_GATE_CAPTURE = $capture
$env:HARNESS_GATE_CAPTURE_ACTIVE = $null
$env:NODE_OPTIONS = "--require=$captureHook"

Push-Location $repoRoot
try {
  & node harness/tests/gate.mjs
  $gateExit = $LASTEXITCODE
} finally {
  Pop-Location
  $env:HARNESS_GATE_CAPTURE = $previousCapture
  $env:HARNESS_GATE_CAPTURE_ACTIVE = $previousActive
  $env:NODE_OPTIONS = $previousNodeOptions
}

$content = ConvertTo-ScrubbedEvidence (Get-Content -LiteralPath $capture -Raw)
Set-Content -LiteralPath $capture -Value $content -NoNewline -Encoding utf8
Assert-NoUserPath $capture $content

exit $gateExit
