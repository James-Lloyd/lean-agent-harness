<#
  gate.ps1 — the verification gate.
  The harness defines WHEN the gate runs; the stack profile (merged into each component's gate) defines
  WHAT each step is. A null/absent step is skipped. "Silent success, verbose failure": we only surface
  output on failure so the loop's context isn't flooded with green noise.

  Multi-component aware: each component's gate runs in that component's own directory; a cross-cutting
  root gate (config.gate) then runs from the repo root. Any failure short-circuits and is reported with
  the component + step that failed.

  Robustness notes:
   - StrictMode-safe property access (a gate object may legitimately omit keys — the schema allows it,
     and /harness-prune may trim config). Missing key => treated as null => skipped, never a crash.
   - Cross-platform: gate commands run through cmd on Windows and bash elsewhere, so loop.ps1 works
     under pwsh on Unix too (not just Windows PowerShell).
#>

# StrictMode-safe: return a property's value or $null if the property is absent.
function Get-Prop($obj, [string]$name) {
  if ($null -eq $obj) { return $null }
  $p = $obj.PSObject.Properties[$name]
  if ($p) { return $p.Value } else { return $null }
}

# Parse a fresh-context reviewer's verdict from its output: SHIP | REJECT | NONE. FAIL-CLOSED on
# purpose: only the LAST line that STARTS with VERDICT: counts — a preamble mentioning "VERDICT: SHIP"
# mid-reasoning ("I cannot give VERDICT: SHIP") must never pass a batch. Lives here (not in loop.ps1)
# so the self-tests can exercise it.
function Get-ReviewVerdict([string]$Text) {
  if (-not $Text) { return 'NONE' }
  $line = @($Text -split "`r?`n" | Where-Object { $_ -match '^\s*VERDICT:' }) | Select-Object -Last 1
  if (-not $line) { return 'NONE' }
  if ($line -match '^\s*VERDICT:\s*SHIP(\s|$)')   { return 'SHIP' }
  if ($line -match '^\s*VERDICT:\s*REJECT(\s|$)') { return 'REJECT' }
  return 'NONE'
}

# Per-phase model routing: resolve config.models.<phase> to its PRIMARY model string (trimmed), or ''
# when null/absent (= inherit the CLI's ambient default — the pre-routing behavior, and what a config
# trimmed by /harness-prune degrades to). Tolerant of BOTH shapes: the new nested {model, fallback}
# object AND the legacy flat 'phase':'alias' string (so deployed configs keep working). Callers in
# loop/fleet still read the PRIMARY through this, so their behavior is unchanged by the migration.
# SPECIAL CASE: the pseudo-phase 'reviewFallback' (still asked for by the review path) resolves to
# review.fallback (nested) or the legacy top-level models.reviewFallback. Lives here (not in loop.ps1)
# so the self-tests exercise it; mirror of phase_model in gate.sh.
function Resolve-PhaseModel($Config, [string]$Phase) {
  $models = Get-Prop $Config 'models'
  if ($Phase -eq 'reviewFallback') {
    $review = Get-Prop $models 'review'
    if ($null -ne $review -and $review -isnot [string]) {
      $rf = Get-Prop $review 'fallback'
      if ($null -ne $rf) { return ("$rf").Trim() }
    }
    $legacy = Get-Prop $models 'reviewFallback'
    if ($null -ne $legacy) { return ("$legacy").Trim() }
    return ''
  }
  $m = Get-Prop $models $Phase
  if ($null -eq $m) { return '' }
  if ($m -is [string]) { return $m.Trim() }        # legacy flat form
  $primary = Get-Prop $m 'model'                    # nested {model, fallback}
  if ($null -eq $primary) { return '' }
  return ("$primary").Trim()
}

# Per-phase FALLBACK model: resolve config.models.<phase>.fallback to a model string (trimmed), or ''
# when there is none. Tolerant of both shapes: the nested {model, fallback} object returns its .fallback;
# a legacy flat string has no per-phase fallback. Mirror of phase_fallback in gate.sh.
# SPECIAL CASE review (S1b): must be SYMMETRIC with Resolve-PhaseModel('reviewFallback') — resolve to
# review.fallback if non-null, ELSE the legacy top-level models.reviewFallback if non-null, ELSE '' — for
# the nested-null, flat-string, AND absent-review shapes alike. Without this, a mixed config (nested
# review:{model,fallback:null} + legacy top-level reviewFallback) had the two accessors disagree.
function Resolve-PhaseFallback($Config, [string]$Phase) {
  $models = Get-Prop $Config 'models'
  $m = Get-Prop $models $Phase
  if ($Phase -eq 'review') {
    if ($null -ne $m -and $m -isnot [string]) {      # nested review.fallback wins when non-null
      $fb = Get-Prop $m 'fallback'
      if ($null -ne $fb) { return ("$fb").Trim() }
    }
    $legacy = Get-Prop $models 'reviewFallback'      # else the legacy top-level (symmetry with reviewFallback pseudo-phase)
    if ($null -ne $legacy) { return ("$legacy").Trim() }
    return ''
  }
  if ($null -eq $m) { return '' }
  if ($m -is [string]) { return '' }                 # legacy flat form has no per-phase fallback
  $fb = Get-Prop $m 'fallback'                        # nested {model, fallback}
  if ($null -eq $fb) { return '' }
  return ("$fb").Trim()
}

# Vendor-neutral usage/limit detector for the fallback dispatcher (S3 wires it; here it is a
# standalone, unit-tested predicate). Detection is OUTPUT-based today: no vendor publishes a stable
# rate-limit *exit code* we can trust, so $ExitCode is accepted for forward-compat (S3's dispatcher
# passes it) but not yet decisive. Markers are matched case-insensitively. The bare "429" marker is
# scoped to an http/status/error/code context so a stray "429 tokens" in normal output can't trigger
# a false fallback (which, once wired to a WRITE phase, would discard a good build).
function Test-UsageLimitError {
  param([string]$Output, $ExitCode = $null)
  if ([string]::IsNullOrEmpty($Output)) { return $false }
  if ($Output -imatch 'usage[ _-]?limit|rate[ _-]?limit|quota|overloaded|too many requests') { return $true }
  if ($Output -imatch '(http|status|error|code)[^\r\n0-9]{0,6}429') { return $true }
  return $false
}

# Sandbox detection for unattended `auto` runs. Mirror of is_sandboxed in gate.sh; lives here (not in
# loop.ps1) so the self-tests can exercise it. Contract: the env var HARNESS_SANDBOX is the EXPLICIT,
# cross-platform signal and ALWAYS wins when it is SET — truthy (1/true/yes, case-insensitive) =>
# sandboxed; anything else (0/false/no/empty) => NOT sandboxed, even inside a container. Only when
# HARNESS_SANDBOX is UNSET do we auto-detect common container markers (ANY present => sandboxed).
# Returns [bool]. On Windows the /proc and /.dockerenv probes simply won't match — the PS runner is the
# host case and the env var is the portable contract.
function Test-Sandboxed {
  $explicit = [Environment]::GetEnvironmentVariable('HARNESS_SANDBOX')   # $null when unset, '' when set-empty
  if ($null -ne $explicit) {
    # Exact case-insensitive match, NO trimming — parity with bash (which does not trim), so a stray
    # " true " resolves identically on both runners. Contract blesses only exact 1/true/yes.
    return (@('1','true','yes') -contains $explicit.ToLowerInvariant())
  }
  if (Test-Path '/.dockerenv') { return $true }                          # docker
  if (Test-Path '/run/.containerenv') { return $true }                   # podman
  # Marker env vars are PRESENCE markers: a runtime SETS them to signal itself, so any one being set
  # (even to empty) => sandboxed. GetEnvironmentVariable returns $null only when UNSET ('' when set-empty),
  # so `$null -ne` is the set-ness test — matches bash ${VAR+x}. `container` holds a runtime NAME, not a bool.
  if ($null -ne [Environment]::GetEnvironmentVariable('CODESPACES'))        { return $true }   # GitHub Codespaces
  if ($null -ne [Environment]::GetEnvironmentVariable('REMOTE_CONTAINERS')) { return $true }   # VS Code dev containers
  if ($null -ne [Environment]::GetEnvironmentVariable('DEVCONTAINER'))      { return $true }   # devcontainer spec
  if ($null -ne [Environment]::GetEnvironmentVariable('container'))         { return $true }   # systemd-nspawn / podman
  if (Test-Path '/proc/1/cgroup') {
    try {
      $cg = Get-Content '/proc/1/cgroup' -Raw -ErrorAction SilentlyContinue
      if ($cg -match 'docker|containerd|lxc|kubepods') { return $true }
    } catch {}
  }
  return $false
}

function Invoke-GateStep([string]$name, [string]$cmd, [string]$workDir) {
  if ([string]::IsNullOrWhiteSpace([string]$cmd)) { return $true }   # null/absent = skip
  Write-Host "  - $name : $cmd" -ForegroundColor DarkGray
  Push-Location $workDir
  # CRITICAL: drop $ErrorActionPreference to 'Continue' around the native call. The caller runs under
  # 'Stop', where a native command that writes to STDERR — even on exit 0 (pytest/eslint/pnpm progress
  # and deprecation lines are routine) — gets wrapped in a NativeCommandError and raised as terminating
  # BEFORE $LASTEXITCODE is read. That would misclassify a green step as a gate error and roll it back.
  $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    if ($env:OS -eq 'Windows_NT') { $out = & cmd /c $cmd 2>&1 }       # Windows shell
    else                          { $out = & bash -lc $cmd 2>&1 }     # pwsh on Unix/macOS/CI
    $code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $prevEAP; Pop-Location }
  if ($code -ne 0) {
    Write-Host "    x $name failed (exit $code) in $workDir :" -ForegroundColor Red
    $out | Select-Object -Last 40 | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
    return $false
  }
  return $true
}

# Run one gate object (format->lint->typecheck->build->test->e2e) in $WorkingDir, labelled $Label.
function Invoke-Gate {
  param([Parameter(Mandatory)] $Gate, [string]$WorkingDir = (Get-Location).Path, [string]$Label = '')
  $steps = [ordered]@{
    format    = (Get-Prop $Gate 'format')
    lint      = (Get-Prop $Gate 'lint')
    typecheck = (Get-Prop $Gate 'typecheck')
    build     = (Get-Prop $Gate 'build')
    test      = (Get-Prop $Gate 'test')
    e2e       = (Get-Prop $Gate 'e2e')
  }
  foreach ($name in $steps.Keys) {
    if (-not (Invoke-GateStep $name $steps[$name] $WorkingDir)) {
      return [pscustomobject]@{ Passed = $false; FailedStep = $name; Component = $Label }
    }
  }
  return [pscustomobject]@{ Passed = $true; FailedStep = $null; Component = $Label }
}

# Run the WHOLE project gate: every component (in its own dir) then the root cross-cutting gate.
function Invoke-ProjectGate {
  param([Parameter(Mandatory)] $Config, [string]$RepoRoot = (Get-Location).Path)
  $components = @(Get-Prop $Config 'components')
  $rootGate = Get-Prop $Config 'gate'
  if (-not $components -or $components.Count -eq 0) {
    # Back-compat: no components defined — treat top-level gate as a single root component.
    return (Invoke-Gate -Gate $rootGate -WorkingDir $RepoRoot -Label 'root')
  }
  foreach ($c in $components) {
    $cPath = [string](Get-Prop $c 'path'); if (-not $cPath) { $cPath = '.' }
    $cName = [string](Get-Prop $c 'name'); if (-not $cName) { $cName = $cPath }
    $dir = Join-Path $RepoRoot $cPath
    if (-not (Test-Path $dir)) {
      # FAIL, don't skip: a configured component whose directory is missing is config drift, and a
      # skipped gate would report green without running anything (fail-open).
      Write-Host "  x component '$cName' path missing: $dir" -ForegroundColor Red
      return [pscustomobject]@{ Passed = $false; FailedStep = 'path-missing'; Component = $cName }
    }
    Write-Host "  [$cName] gate ($cPath)" -ForegroundColor Cyan
    $r = Invoke-Gate -Gate (Get-Prop $c 'gate') -WorkingDir $dir -Label $cName
    if (-not $r.Passed) { return $r }
  }
  # Cross-cutting root gate (usually just e2e for multi-component projects).
  if ($rootGate) {
    $hasAny = @($rootGate.PSObject.Properties | Where-Object { $_.Name -ne '_comment' -and $_.Value }).Count -gt 0
    if ($hasAny) {
      Write-Host "  [root] cross-cutting gate" -ForegroundColor Cyan
      $r = Invoke-Gate -Gate $rootGate -WorkingDir $RepoRoot -Label 'root(cross-cutting)'
      if (-not $r.Passed) { return $r }
    }
  }
  return [pscustomobject]@{ Passed = $true; FailedStep = $null; Component = $null }
}
