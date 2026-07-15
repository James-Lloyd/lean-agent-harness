#requires -Version 5.1
<#
.SYNOPSIS
  Migrate an existing copied-in harness onto the lean-agent-harness plugin without losing project
  customizations (ratcheted denylists, project-authored skills/agents, tuned config).

.DESCRIPTION
  Classifies every engine-ish file in a deployed repo against the installed plugin's version:
    IDENTICAL    — byte-match (CRLF/LF + BOM normalized) to the plugin => safe to remove.
    DIFFERS      — counterpart exists but content differs => KEEP + show a short diff (your ratchet,
                   or a newer plugin version — a human decides).
    PROJECT-ONLY — no plugin counterpart => KEEP (yours).
  The tool NEVER deletes a file whose content the plugin does not already provide verbatim, so no
  ratchet and no local edit can be lost. Default = report only. -Apply performs the (git-reversible)
  cleanup: remove IDENTICAL engine files, strip the duplicate engine hook wiring from settings.json,
  install the 4 thin runner wrappers, and write harness/MIGRATION-REPORT.md.

.EXAMPLE
  powershell -File engine/migrate.ps1                 # report only, against the CWD's repo
  powershell -File engine/migrate.ps1 -Apply          # perform the migration
  powershell -File engine/migrate.ps1 -Apply -ReplaceRunners   # also swap differing runners for wrappers
#>
[CmdletBinding()]
param(
  [string] $ProjectRoot,
  [switch] $Apply,
  [switch] $ReplaceRunners,
  [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- locate the plugin payload & the project -----------------------------------
# migrate.ps1 sits in <pluginRoot>/engine/, so the plugin payload (agents/commands/skills/hooks) is the
# script dir's SIBLING; engine files (lib/profiles/templates/wrappers) live under the script dir itself.
$EngineDir  = $PSScriptRoot
$PluginRoot = Split-Path -Parent $PSScriptRoot

# Project root discovery mirrors loop.ps1: -ProjectRoot wins; else the git top-level; else the CWD.
if (-not $ProjectRoot) {
  $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $top = (& git rev-parse --show-toplevel 2>$null | Select-Object -First 1) } catch { $top = $null }
  finally { $ErrorActionPreference = $prevEAP }
  if ($top) { $ProjectRoot = "$top".Trim() } else { $ProjectRoot = (Get-Location).Path }
}
$ProjectRoot = (Resolve-Path $ProjectRoot).Path

# The 5 engine hooks (repo won't carry the plugin's run.mjs / hooks.json).
$EngineHookNames = @('block-destructive', 'format-and-check', 'lock-config', 'protect-specs', 'session-start')
$RunnerNames = @('loop.ps1', 'loop.sh', 'fleet.ps1', 'fleet.sh')

# --- helpers -------------------------------------------------------------------
function Get-NormalizedText([string]$path) {
  # Strip a leading UTF-8 BOM and normalize line endings so a CRLF-vs-LF checkout difference (not a
  # customization) doesn't read as DIFFERS.
  $bytes = [System.IO.File]::ReadAllBytes($path)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    if ($bytes.Length -gt 3) { $bytes = $bytes[3..($bytes.Length - 1)] } else { $bytes = @() }
  }
  $text = [System.Text.Encoding]::UTF8.GetString($bytes)
  return ($text -replace "`r`n", "`n" -replace "`r", "`n")
}

function Test-Identical([string]$a, [string]$b) {
  if (-not (Test-Path -LiteralPath $a) -or -not (Test-Path -LiteralPath $b)) { return $false }
  return ((Get-NormalizedText $a) -ceq (Get-NormalizedText $b))
}

function Get-Rel([string]$path) {
  $p = $path.Substring($ProjectRoot.Length).TrimStart('\', '/')
  return ($p -replace '\\', '/')
}

function Get-ShortDiff([string]$pluginPath, [string]$repoPath, [int]$max = 10) {
  $p = (Get-NormalizedText $pluginPath) -split "`n"
  $r = (Get-NormalizedText $repoPath)  -split "`n"
  $d = @(Compare-Object -ReferenceObject $p -DifferenceObject $r)
  $out = @()
  foreach ($x in ($d | Select-Object -First $max)) {
    $mark = if ($x.SideIndicator -eq '<=') { 'plugin' } else { 'yours ' }
    $out += ("      [{0}] {1}" -f $mark, $x.InputObject)
  }
  if ($d.Count -gt $max) { $out += ("      ... (+{0} more differing lines)" -f ($d.Count - $max)) }
  return ($out -join "`n")
}

function Get-EngineHookRef([string]$command) {
  # Return the engine-hook basename a settings.json command references, or $null.
  if (-not $command) { return $null }
  foreach ($b in $EngineHookNames) {
    $esc = [regex]::Escape($b)
    # Left boundary (?<!...) so a project hook like my-block-destructive.sh / pre-session-start.sh is
    # NOT matched as the engine hook it embeds — else its wiring would be stripped silently.
    if ($command -match ("(?i)(?<![A-Za-z0-9_.-])" + $esc + "\.(ps1|sh)\b")) { return $b }
    if ($command -match ("(?i)run\.mjs[`"']?\s+(?<![A-Za-z0-9_.-])" + $esc + "\b")) { return $b }
  }
  return $null
}

function Get-ReferencedHookFile([string]$command) {
  # Return the engine-hook FILE (basename+ext, e.g. block-destructive.ps1) a command references, else
  # $null. Used to decide strip-vs-keep by whether THAT file was removed — .ps1 and .sh of one hook can
  # have different fates (one IDENTICAL-removed, the other DIFFERS-kept), so basename alone is wrong.
  if (-not $command) { return $null }
  foreach ($b in $EngineHookNames) {
    $esc = [regex]::Escape($b)
    $m = [regex]::Match($command, "(?i)(?<![A-Za-z0-9_.-])(" + $esc + "\.(ps1|sh))\b")
    if ($m.Success) { return $m.Groups[1].Value }
  }
  return $null
}

function Remove-EmptyDirs([string]$dir, [bool]$removeSelf) {
  if (-not (Test-Path -LiteralPath $dir)) { return }
  foreach ($sub in @(Get-ChildItem -LiteralPath $dir -Directory -Force)) {
    Remove-EmptyDirs $sub.FullName $true
  }
  if ($removeSelf) {
    if (@(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0) { Remove-Item -LiteralPath $dir -Force }
  }
}

# --- build the classification --------------------------------------------------
$mappings = @(
  @{ RepoDir = (Join-Path $ProjectRoot '.claude/agents');    PluginDir = (Join-Path $PluginRoot 'agents');           Ext = @('.md') },
  @{ RepoDir = (Join-Path $ProjectRoot '.claude/commands');  PluginDir = (Join-Path $PluginRoot 'commands');         Ext = @('.md') },
  @{ RepoDir = (Join-Path $ProjectRoot '.claude/skills');    PluginDir = (Join-Path $PluginRoot 'skills');           Ext = @() },
  @{ RepoDir = (Join-Path $ProjectRoot '.claude/hooks');     PluginDir = (Join-Path $PluginRoot 'hooks');            Ext = @('.ps1', '.sh') },
  @{ RepoDir = (Join-Path $ProjectRoot 'harness/lib');       PluginDir = (Join-Path $PluginRoot 'engine/lib');       Ext = @() },
  @{ RepoDir = (Join-Path $ProjectRoot 'harness/profiles');  PluginDir = (Join-Path $PluginRoot 'engine/profiles');  Ext = @() },
  @{ RepoDir = (Join-Path $ProjectRoot 'harness/templates'); PluginDir = (Join-Path $PluginRoot 'engine/templates'); Ext = @() }
)

$items = @()
function Add-Item([string]$repoPath, [string]$pluginPath) {
  $class = if (-not (Test-Path -LiteralPath $pluginPath)) { 'PROJECT-ONLY' }
           elseif (Test-Identical $repoPath $pluginPath)  { 'IDENTICAL' }
           else                                           { 'DIFFERS' }
  $script:items += [pscustomobject]@{
    RepoPath   = $repoPath
    PluginPath = $pluginPath
    Display    = (Get-Rel $repoPath)
    Class      = $class
  }
}

foreach ($m in $mappings) {
  if (-not (Test-Path -LiteralPath $m.RepoDir)) { continue }
  $files = @(Get-ChildItem -LiteralPath $m.RepoDir -Recurse -File -Force)
  foreach ($f in $files) {
    if ($m.Ext.Count -gt 0 -and ($m.Ext -notcontains $f.Extension.ToLower())) { continue }
    $rel = $f.FullName.Substring($m.RepoDir.Length).TrimStart('\', '/')
    Add-Item $f.FullName (Join-Path $m.PluginDir $rel)
  }
}

# Single-file mapping: harness/harness.schema.json -> engine/harness.schema.json
$repoSchema = Join-Path $ProjectRoot 'harness/harness.schema.json'
if (Test-Path -LiteralPath $repoSchema) {
  Add-Item $repoSchema (Join-Path $PluginRoot 'engine/harness.schema.json')
}

# Runners (special-case: replaced by wrappers, never plain-removed).
$runners = @()
foreach ($rn in $RunnerNames) {
  $repoR = Join-Path $ProjectRoot ('harness/' + $rn)
  if (-not (Test-Path -LiteralPath $repoR)) { continue }
  $engineR = Join-Path $EngineDir $rn
  $ident = Test-Identical $repoR $engineR
  $shouldReplace = $ident -or [bool]$ReplaceRunners
  $reason = if ($ident) { 'identical to engine -> thin wrapper (auto)' }
            elseif ($ReplaceRunners) { 'differs -> thin wrapper (-ReplaceRunners)' }
            else { 'differs -> KEPT (pass -ReplaceRunners to swap for a wrapper)' }
  $runners += [pscustomobject]@{
    Name = $rn; RepoPath = $repoR; WrapperPath = (Join-Path $EngineDir ('wrappers/' + $rn))
    Identical = $ident; Replace = $shouldReplace; Reason = $reason
  }
}

# --- print the classification report (always) ----------------------------------
$identical   = @($items | Where-Object { $_.Class -eq 'IDENTICAL' })
$differs     = @($items | Where-Object { $_.Class -eq 'DIFFERS' })
$projectOnly = @($items | Where-Object { $_.Class -eq 'PROJECT-ONLY' })

Write-Host ""
Write-Host "harness-migrate — plugin: $PluginRoot"
Write-Host "                  project: $ProjectRoot"
Write-Host ""
Write-Host ("IDENTICAL to plugin (safe to remove) — {0} file(s):" -f $identical.Count)
foreach ($i in $identical) { Write-Host ("  - {0}" -f $i.Display) }
Write-Host ""
Write-Host ("DIFFERS (KEPT for review — your ratchet, or a newer plugin version) — {0} file(s):" -f $differs.Count)
foreach ($i in $differs) {
  Write-Host ("  ~ {0}" -f $i.Display)
  Write-Host (Get-ShortDiff $i.PluginPath $i.RepoPath)
}
Write-Host ""
Write-Host ("PROJECT-ONLY (KEPT — yours) — {0} file(s):" -f $projectOnly.Count)
foreach ($i in $projectOnly) { Write-Host ("  + {0}" -f $i.Display) }
Write-Host ""
Write-Host "Runners (harness/loop.*, harness/fleet.*):"
foreach ($r in $runners) { Write-Host ("  * {0}: {1}" -f $r.Name, $r.Reason) }
Write-Host ""

if (-not $Apply) {
  Write-Host "Report only — nothing was written. Re-run with -Apply to perform the migration."
  Write-Host "(-Apply removes IDENTICAL files, strips duplicate hook wiring, installs runner wrappers,"
  Write-Host " and writes harness/MIGRATION-REPORT.md — all reversible via git.)"
  exit 0
}

# --- APPLY ---------------------------------------------------------------------
# 1. Guard the tree. A non-git target has no `git checkout` undo (only runner .bak backups), so refuse
#    unless -Force; a git target must be clean so the migration lands as one reviewable diff.
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { $st = & git -C $ProjectRoot status --porcelain 2>$null } catch { $st = $null }
$rc = $LASTEXITCODE
$ErrorActionPreference = $prevEAP
$isGit = ($rc -eq 0)
if (-not $Force) {
  if (-not $isGit) {
    [Console]::Error.WriteLine("Target is not a git repository, so -Apply deletions would NOT be reversible. Pass -Force to proceed anyway (only runner .pre-plugin.bak backups are kept).")
    exit 1
  }
  if ($st) {
    [Console]::Error.WriteLine("Working tree is not clean. Commit or stash first so the migration is a single reviewable diff, or pass -Force.")
    exit 1
  }
}

# 2. Remove IDENTICAL engine files + prune emptied dirs.
$removed = @()
foreach ($i in $identical) {
  Remove-Item -LiteralPath $i.RepoPath -Force
  $removed += $i.Display
}
foreach ($pr in @('.claude/agents', '.claude/commands', '.claude/skills', '.claude/hooks', 'harness/lib', 'harness/profiles', 'harness/templates')) {
  Remove-EmptyDirs (Join-Path $ProjectRoot $pr) $true
}

# 3. Strip engine hook wiring from .claude/settings.json — but ONLY for hooks whose FILE we removed
#    (IDENTICAL). A DIFFERS-kept hook KEEPS its wiring so its ratcheted rule keeps firing (harmlessly
#    redundant with the plugin's stock hook for a denylist); silently un-wiring a customized guardrail
#    and only warning would disable it during the exact window an autonomous loop is running.
$settingsEdits = @()
$warnings = @()
$settingsPath = Join-Path $ProjectRoot '.claude/settings.json'
if (Test-Path -LiteralPath $settingsPath) {
  $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
  $stripped = @()
  $keptWired = @()
  if ($settings.PSObject.Properties['hooks'] -and $settings.hooks) {
    $hooks = $settings.hooks
    foreach ($ev in @($hooks.PSObject.Properties.Name)) {
      $newGroups = @()
      foreach ($g in @($hooks.$ev)) {
        if ($g.PSObject.Properties['hooks']) {
          $kept = @()
          foreach ($h in @($g.hooks)) {
            $cmd     = if ($h.PSObject.Properties['command']) { $h.command } else { $null }
            $ref     = Get-EngineHookRef $cmd
            $refFile = Get-ReferencedHookFile $cmd
            # Strip the wiring only if the referenced hook FILE is now absent (IDENTICAL-removed, or a
            # dangling reference the plugin now supplies). A DIFFERS-kept file still on disk KEEPS its
            # wiring so the ratchet keeps firing.
            $fileRemoved = $refFile -and (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot (".claude/hooks/" + $refFile))))
            if ($ref -and $fileRemoved) { $stripped += $ref }
            else { $kept += $h; if ($ref) { $keptWired += $ref } }
          }
          if ($kept.Count -gt 0) { $g.hooks = @($kept); $newGroups += $g }
        } else {
          $newGroups += $g
        }
      }
      if ($newGroups.Count -gt 0) { $hooks.$ev = @($newGroups) }
      else { $hooks.PSObject.Properties.Remove($ev) }
    }
    if (@($hooks.PSObject.Properties.Name).Count -eq 0) { $settings.PSObject.Properties.Remove('hooks') }
  }
  $stripped   = @($stripped | Select-Object -Unique)
  $keptWired  = @($keptWired | Select-Object -Unique)
  if ($stripped.Count -gt 0) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $json = ($settings | ConvertTo-Json -Depth 32)
    [System.IO.File]::WriteAllText($settingsPath, $json, $utf8NoBom)
    foreach ($s in $stripped) { $settingsEdits += ("stripped engine hook wiring (file removed): {0}" -f $s) }
  }
  # For a DIFFERS-kept hook we deliberately KEEP the wiring so the ratchet keeps firing; tell the human
  # it now runs alongside the plugin's stock hook (harmless for a denylist) and should be ported + de-duped.
  $differsHookNames = @($differs | Where-Object { $_.Display -match '(^|/)\.claude/hooks/' } |
    ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.RepoPath) } | Select-Object -Unique)
  foreach ($s in $keptWired) {
    if ($differsHookNames -contains $s) {
      $warnings += ("KEPT the wiring for your customized .claude/hooks/{0}.* so it keeps firing — it now runs alongside the plugin's stock {0}. Port your change into the plugin, then remove the local copy + its wiring when ready." -f $s)
    }
  }
}

# 4. Install runner wrappers (special-case).
$wrappersInstalled = @()
$runnersKept = @()
foreach ($r in $runners) {
  if ($r.Replace -and (Test-Path -LiteralPath $r.WrapperPath)) {
    Copy-Item -LiteralPath $r.RepoPath -Destination ($r.RepoPath + '.pre-plugin.bak') -Force
    Copy-Item -LiteralPath $r.WrapperPath -Destination $r.RepoPath -Force
    $wrappersInstalled += $r.Name
  } else {
    $runnersKept += ("{0} — {1}" -f $r.Name, $r.Reason)
  }
}

# 5. Write MIGRATION-REPORT.md and print a summary.
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# Harness migration report")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("Plugin: ``$PluginRoot``  ")
[void]$sb.AppendLine("Project: ``$ProjectRoot``  ")
if ($isGit) {
  [void]$sb.AppendLine("Generated by ``migrate.ps1 -Apply`` — all changes are reversible via ``git``.")
} else {
  [void]$sb.AppendLine("Generated by ``migrate.ps1 -Apply -Force`` on a NON-git target — deletions are NOT reversible (only ``.pre-plugin.bak`` runner backups exist).")
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Removed (IDENTICAL to the plugin — {0})" -f $removed.Count)
if ($removed.Count -eq 0) { [void]$sb.AppendLine("_none_") } else { foreach ($x in $removed) { [void]$sb.AppendLine("- ``$x``") } }
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Kept — DIFFERS (review: your ratchet, or a newer plugin version — {0})" -f $differs.Count)
if ($differs.Count -eq 0) { [void]$sb.AppendLine("_none_") } else { foreach ($x in $differs) { [void]$sb.AppendLine("- ``$($x.Display)``") } }
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Kept — PROJECT-ONLY (yours — {0})" -f $projectOnly.Count)
if ($projectOnly.Count -eq 0) { [void]$sb.AppendLine("_none_") } else { foreach ($x in $projectOnly) { [void]$sb.AppendLine("- ``$($x.Display)``") } }
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## settings.json edits")
if ($settingsEdits.Count -eq 0) { [void]$sb.AppendLine("_none_") } else { foreach ($x in $settingsEdits) { [void]$sb.AppendLine("- $x") } }
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Runner wrappers installed")
if ($wrappersInstalled.Count -eq 0) { [void]$sb.AppendLine("_none_") } else { foreach ($x in $wrappersInstalled) { [void]$sb.AppendLine("- ``harness/$x`` (original backed up to ``harness/$x.pre-plugin.bak``)") } }
if ($runnersKept.Count -gt 0) {
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("Runners kept (not swapped):")
  foreach ($x in $runnersKept) { [void]$sb.AppendLine("- $x") }
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Manual next-steps")
foreach ($w in $warnings) { [void]$sb.AppendLine("- WARN: $w") }
[void]$sb.AppendLine("- Review every **DIFFERS** file: port a genuine customization (e.g. a ratcheted denylist) into the plugin or a project hook, then remove the local copy; if it is merely an older plugin version, delete the local copy.")
[void]$sb.AppendLine("- Confirm the ``.pre-plugin.bak`` runner backups can be deleted once the wrappers are verified.")
[void]$sb.AppendLine("- Review ``git diff`` and commit.")
$reportPath = Join-Path $ProjectRoot 'harness/MIGRATION-REPORT.md'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($reportPath, $sb.ToString(), $utf8NoBom)

Write-Host "Applied migration:"
Write-Host ("  removed {0} IDENTICAL file(s); kept {1} DIFFERS + {2} PROJECT-ONLY" -f $removed.Count, $differs.Count, $projectOnly.Count)
Write-Host ("  settings.json: {0} edit(s)" -f $settingsEdits.Count)
Write-Host ("  wrappers installed: {0}" -f ($(if ($wrappersInstalled.Count -gt 0) { $wrappersInstalled -join ', ' } else { 'none' })))
foreach ($w in $warnings) { Write-Host ("  WARN: {0}" -f $w) }
Write-Host ("  report: {0}" -f (Get-Rel $reportPath))
Write-Host ""
Write-Host "Review 'git diff', then commit."
exit 0
