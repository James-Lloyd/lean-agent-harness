<#
  fleet.ps1 (lib) — pure logic for the fleet runner (harness/fleet.ps1): which tasks may run in
  parallel. Lives in lib so the self-tests exercise it; mirror of fleet.sh.

  The rule (from the 2026-07-13 execution plan): parallel tasks must be FILE-OWNERSHIP-PARTITIONED.
  A task is fleet-eligible only if it declares a non-empty `files` ownership list in state/tasks.json;
  two tasks whose ownership overlaps (same path, or one inside the other) NEVER run in the same batch —
  overlapping work runs sequentially instead. Conflict avoidance beats conflict resolution.
  Requires Get-Prop from lib/gate.ps1 (source that first).
#>

# Normalize an ownership entry for comparison: forward slashes, strip a trailing glob (/* or /**) and
# trailing slashes, case-fold (Windows paths are case-insensitive).
function _Normalize-FleetPath([string]$p) {
  $p = "$p" -replace '\\', '/'
  $p = $p -replace '/\*\*?$', ''
  $p = $p.TrimEnd('/')
  return $p.ToLowerInvariant()
}

# Do two ownership lists overlap? Overlap = any pair is equal, or one path lies inside the other.
# FAIL-CLOSED: an empty/blank entry counts as overlapping everything (a task that owns "" owns the
# world — it must not be parallelized).
function Test-FleetOverlap($FilesA, $FilesB) {
  foreach ($a in @($FilesA)) {
    $na = _Normalize-FleetPath $a
    if (-not $na) { return $true }
    foreach ($b in @($FilesB)) {
      $nb = _Normalize-FleetPath $b
      if (-not $nb) { return $true }
      if ($na -eq $nb) { return $true }
      if ($na.StartsWith($nb + '/')) { return $true }
      if ($nb.StartsWith($na + '/')) { return $true }
    }
  }
  return $false
}

# Pick the batch: walk tasks in manifest (= priority) order; take a task if it is `todo`/`planned`,
# declares non-empty `files` ownership, and doesn't overlap anything already picked; stop at $MaxWorkers.
# Tasks without ownership are silently ineligible — the planner declares ownership; the fleet never
# guesses it.
function Select-FleetTasks {
  param($Manifest, [int]$MaxWorkers = 3)
  $picked = @()
  foreach ($t in @(Get-Prop $Manifest 'tasks')) {
    if ($picked.Count -ge $MaxWorkers) { break }
    $status = [string](Get-Prop $t 'status')
    if (@('todo', 'planned') -notcontains $status) { continue }
    # Double @(): a one-element pipeline result unwraps to a scalar, and .Count on a scalar throws
    # under StrictMode Latest in PS 5.1.
    $files = @(@(Get-Prop $t 'files') | Where-Object { $_ })
    if ($files.Count -eq 0) { continue }
    $overlaps = $false
    foreach ($p in $picked) {
      if (Test-FleetOverlap $files @(Get-Prop $p 'files')) { $overlaps = $true; break }
    }
    if (-not $overlaps) { $picked += , $t }
  }
  # Emit items, not a wrapped array: `return ,$picked` hands a single-task batch back as Object[]
  # (callers see one element whose properties are all empty). Callers wrap with @().
  return $picked
}
