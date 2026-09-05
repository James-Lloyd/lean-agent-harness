#requires -Version 5.1
<#
  codex-setup.ps1 - generate the OpenAI Codex CLI surfaces for a harness project (PS twin of
  codex-setup.sh; behaviour and output bytes must match it - either twin may generate, either may -Check).
  Design-doc 002 D3: Codex reads `.codex/` in the repo, so the harness's guard hooks, phase agents and
  skills have to exist there in Codex's own formats - but the plugin lives in the per-machine cache, so
  the generated files carry ABSOLUTE local paths and must never be committed (ratchet 2026-07-30).
  Everything here is therefore GENERATED + GITIGNORED and re-runnable.

  Writes, under <project>/.codex/ :
    config.toml         [features] hooks=true; [[skills.config]] path=<plugin>/skills; [agents] defaults
    hooks.json          four of the five guard hooks through <plugin>/hooks/run.mjs (lock-config's
                        ConfigChange has no Codex event). protect-specs / format-and-check / session-start
                        run under matcher "*" (their bodies exit 0 on a payload without a file path).
                        block-destructive does NOT: when tool_input.command is absent it scans the WHOLE
                        payload ("fail toward scanning"), so under "*" a Codex EDIT whose patch text mentions
                        `rm -rf` would be falsely denied. It is emitted under -ShellMatcher (default: a
                        best-guess list of Codex shell tool names, UNVERIFIED until slice V5 observes a
                        real denial) - see docs/codex-setup.md.
    agents/<name>.toml  one per plugin agent: model/effort from the phase's effective codex settings,
                        sandbox_mode read-only for judges, developer_instructions = the agent body
    .harness-stamp.json plugin version + sha256 of the inputs, so -Check can detect staleness
  and appends `.codex/` to <project>/.gitignore if missing.

  Usage: codex-setup.ps1 -ProjectRoot <repo> [-Check] [-User] [-ShellMatcher <regex>]
    -Check  exit 0 if the generated set exists and matches the current inputs, 1 if missing/stale
    -User   ALSO write hooks.json to ~/.codex/hooks.json (override dir with $env:HARNESS_CODEX_HOME) - the
            only place repo hooks run under headless `codex exec` without --dangerously-bypass-hook-trust.
            MACHINE-WIDE: applies to every Codex project on this machine. Refuses to overwrite a
            hooks.json there that the harness did not generate.
    -ShellMatcher <regex>  the PreToolUse matcher for block-destructive (Codex shell tool name(s)).
            Default is a best guess; a wrong name means the hook never fires (fail-open for that one
            hook, never a false denial). Confirm in V5 and pin it.
#>
[CmdletBinding()]
param(
  [string] $ProjectRoot,
  [switch] $Check,
  [switch] $User,
  [string] $ShellMatcher = 'shell|exec_command|local_shell|command_execution'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$pluginRoot = Split-Path -Parent $PSScriptRoot
$hooksDir = Join-Path $pluginRoot 'hooks'; $skillsDir = Join-Path $pluginRoot 'skills'; $agentsDir = Join-Path $pluginRoot 'agents'

if (-not $ProjectRoot) {
  $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $top = (& git rev-parse --show-toplevel 2>$null | Select-Object -First 1) } catch { $top = $null }
  finally { $ErrorActionPreference = $prevEAP }
  if ($top) { $ProjectRoot = "$top".Trim() } else { $ProjectRoot = (Get-Location).Path }
}
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
$configPath = Join-Path $ProjectRoot 'harness/harness.config.json'
if (-not (Test-Path $configPath)) { [Console]::Error.WriteLine("Missing $configPath. Run /harness-init first."); exit 1 }
. (Join-Path $PSScriptRoot 'lib/gate.ps1')   # Get-Prop, Resolve-PhaseCodexCfg
$cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

$out = Join-Path $ProjectRoot '.codex'
$pluginVersion = 'unknown'
try { $pluginVersion = [string](Get-Prop (Get-Content -LiteralPath (Join-Path $pluginRoot '.claude-plugin/plugin.json') -Raw | ConvertFrom-Json) 'version'); if (-not $pluginVersion) { $pluginVersion = 'unknown' } } catch { }
$utf8 = New-Object System.Text.UTF8Encoding($false)   # no BOM: Codex/node read bytes verbatim

# --- helpers -------------------------------------------------------------------------------------
function Fwd([string]$p) { return $p.Replace('\', '/') }                       # native path, forward slashes (= cygpath -m)
function TomlBasic([string]$s) { return $s.Replace('\', '\\').Replace('"', '\"') }
function Write-NoBom([string]$path, [string]$text) { [System.IO.File]::WriteAllText($path, $text, $utf8) }
# Ordinal name order (= the .sh twin's LC_ALL=C sort), so the inputs digest agrees across twins.
function Agent-Files {
  $files = @(Get-ChildItem -LiteralPath $agentsDir -Filter *.md)
  $names = New-Object System.Collections.ArrayList
  foreach ($f in $files) { [void]$names.Add($f.Name) }
  $names.Sort([System.StringComparer]::Ordinal)
  return @($names | ForEach-Object { $n = $_; $files | Where-Object { $_.Name -ceq $n } | Select-Object -First 1 })
}
# Inputs hash: RAW bytes + ordinal file order, byte-identical to the .sh twin's digest.
function Get-InputsHash {
  $ms = New-Object System.IO.MemoryStream
  $w = New-Object System.IO.BinaryWriter($ms)
  $w.Write($utf8.GetBytes("plugin=$pluginVersion`nroot=$(Fwd $pluginRoot)`n"))
  $w.Write([System.IO.File]::ReadAllBytes($configPath))
  $w.Write([System.IO.File]::ReadAllBytes((Join-Path $hooksDir 'hooks.json')))
  foreach ($f in (Agent-Files)) {
    $w.Write($utf8.GetBytes("## $($f.Name)`n"))
    $w.Write([System.IO.File]::ReadAllBytes($f.FullName))
  }
  $w.Flush()
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $hash = $sha.ComputeHash($ms.ToArray())
  return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

# --- -Check ----------------------------------------------------------------------------------------
if ($Check) {
  $stamp = Join-Path $out '.harness-stamp.json'
  if (-not (Test-Path $stamp) -or -not (Test-Path (Join-Path $out 'config.toml')) -or -not (Test-Path (Join-Path $out 'hooks.json')) -or -not (Test-Path (Join-Path $out 'agents'))) {
    Write-Output 'codex-setup: NOT generated (run harness/codex-setup.ps1)'; exit 1
  }
  $st = Get-Content -LiteralPath $stamp -Raw | ConvertFrom-Json
  $want = Get-InputsHash; $have = [string](Get-Prop $st 'inputsHash')
  if ($want -ne $have) { Write-Output 'codex-setup: STALE (inputs changed since generation; re-run harness/codex-setup.ps1)'; exit 1 }
  Write-Output "codex-setup: fresh (plugin $(Get-Prop $st 'pluginVersion'))"; exit 0
}

# --- generate --------------------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path (Join-Path $out 'agents') | Out-Null
$genNote = "GENERATED by lean-agent-harness codex-setup (plugin $pluginVersion). Do not edit; re-run harness/codex-setup.* - see docs/codex-setup.md"

# config.toml
$g = Get-Prop (Get-Prop $cfg 'models') 'codex'
$gModel = [string](Get-Prop $g 'model'); $gEffort = [string](Get-Prop $g 'reasoningEffort')
$toml = "# $genNote`n`n[features]`nhooks = true`n`n[[skills.config]]`npath = `"$(TomlBasic (Fwd $skillsDir))`"`n`n[agents]`nenabled = true`n"
if ($gModel)  { $toml += "default_subagent_model = `"$(TomlBasic $gModel)`"`n" }
if ($gEffort) { $toml += "default_subagent_reasoning_effort = `"$(TomlBasic $gEffort)`"`n" }
Write-NoBom (Join-Path $out 'config.toml') $toml

# hooks.json - mirror of plugin/hooks/hooks.json with absolute commands; ConfigChange has no Codex event.
$runMjs = Fwd (Join-Path $hooksDir 'run.mjs')
function HookCmd([string]$h) { return ('node "{0}" {1}' -f $runMjs, $h) }
# block-destructive is scoped to the shell tool matcher (see header): under "*" its whole-payload
# fallback scan would deny edits whose text merely mentions a denylisted command.
$hooks = [ordered]@{
  _generated_by = $genNote
  _shell_matcher_note = 'block-destructive fires only for tools matching this regex; the default is a best guess at Codex shell tool names, unverified until a real denial is observed (docs/codex-setup.md)'
  hooks = [ordered]@{
    PreToolUse   = @(
                     [ordered]@{ matcher = $ShellMatcher; hooks = @([ordered]@{ type = 'command'; command = (HookCmd 'block-destructive'); timeout = 30 }) },
                     [ordered]@{ matcher = '*';           hooks = @([ordered]@{ type = 'command'; command = (HookCmd 'protect-specs');     timeout = 30 }) })
    PostToolUse  = @([ordered]@{ matcher = '*'; hooks = @([ordered]@{ type = 'command'; command = (HookCmd 'format-and-check'); timeout = 120 }) })
    SessionStart = @([ordered]@{ matcher = '*'; hooks = @([ordered]@{ type = 'command'; command = (HookCmd 'session-start');    timeout = 30 }) })
  }
}
Write-NoBom (Join-Path $out 'hooks.json') (($hooks | ConvertTo-Json -Depth 8) + "`n")

# agents/*.toml - one per plugin agent. Phase mapping + sandbox mirror the harness's doer/judge split.
function Agent-Phase([string]$n) { switch ($n) { 'planner' { 'plan' } 'generator' { 'implement' } 'reviewer' { 'review' } 'risk-classifier' { 'review' } 'evaluator' { 'evaluate' } 'explorer' { 'explore' } 'doc-gardener' { 'docs' } default { '' } } }
function Agent-Sandbox([string]$n) { if ($n -in @('reviewer', 'risk-classifier', 'evaluator', 'explorer')) { 'read-only' } else { 'workspace-write' } }
foreach ($f in (Agent-Files)) {
  $lines = [System.IO.File]::ReadAllLines($f.FullName)
  $name = ''; $desc = ''; $fences = 0; $body = New-Object System.Collections.Generic.List[string]; $started = $false
  foreach ($ln in $lines) {
    if ($fences -lt 2) {
      if ($ln -match '^---\s*$') { $fences++; continue }
      if ($ln -match '^name:\s*(.*)$' -and -not $name) { $name = $Matches[1].Trim() }
      if ($ln -match '^description:\s*(.*)$' -and -not $desc) { $desc = $Matches[1].Trim() }
      continue
    }
    if (-not $started -and $ln.Trim() -eq '') { continue }
    $started = $true; $body.Add($ln)
  }
  while ($body.Count -gt 0 -and $body[$body.Count - 1].Trim() -eq '') { $body.RemoveAt($body.Count - 1) }   # = the .sh twin's $(...) trailing-newline strip
  $bodyText = ($body -join "`n")
  if ($bodyText.Contains("'''")) { [Console]::Error.WriteLine("agent $name body contains ''' - cannot embed as a TOML literal string"); exit 1 }
  $phase = Agent-Phase $name
  $model = ''; $effort = ''
  if ($phase) { $pc = Resolve-PhaseCodexCfg $cfg $phase; $model = [string](Get-Prop $pc 'model'); $effort = [string](Get-Prop $pc 'reasoningEffort') }
  $t = "# $genNote`nname = `"$(TomlBasic $name)`"`ndescription = `"$(TomlBasic $desc)`"`n"
  if ($model)  { $t += "model = `"$(TomlBasic $model)`"`n" }
  if ($effort) { $t += "model_reasoning_effort = `"$(TomlBasic $effort)`"`n" }
  $preamble = 'Running under OpenAI Codex CLI: Claude-Code-specific references below (the Agent tool, slash commands, model: frontmatter and its drift checks) do not apply; the role, rules and output contract do.'
  $t += "sandbox_mode = `"$(Agent-Sandbox $name)`"`ndeveloper_instructions = '''`n$preamble`n`n$bodyText`n'''`n"
  Write-NoBom (Join-Path $out "agents/$name.toml") $t
}

# stamp
$stampObj = [ordered]@{ pluginVersion = $pluginVersion; inputsHash = (Get-InputsHash); pluginRoot = (Fwd $pluginRoot); generatedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
Write-NoBom (Join-Path $out '.harness-stamp.json') (($stampObj | ConvertTo-Json) + "`n")

# .gitignore - the generated set carries machine-local absolute paths: never commit it.
$gi = Join-Path $ProjectRoot '.gitignore'
$giLines = if (Test-Path $gi) { @(Get-Content -LiteralPath $gi) } else { @() }
if (-not ($giLines -ccontains '.codex/')) {
  # AppendAllText with the no-BOM encoding: Add-Content -Encoding utf8 would splice a BOM mid-file on 5.1.
  [System.IO.File]::AppendAllText($gi, "`n# OpenAI Codex CLI surfaces generated by harness/codex-setup.* (machine-local absolute paths):`n.codex/`n", $utf8)
}

# -User: hooks into ~/.codex/hooks.json (only place repo hooks run under headless `codex exec` untrusted)
if ($User) {
  $home_ = if ($env:HARNESS_CODEX_HOME) { $env:HARNESS_CODEX_HOME } else { Join-Path $HOME '.codex' }
  New-Item -ItemType Directory -Force -Path $home_ | Out-Null
  $dst = Join-Path $home_ 'hooks.json'
  if (Test-Path $dst) {
    $existing = $null; try { $existing = Get-Content -LiteralPath $dst -Raw | ConvertFrom-Json } catch { $existing = $null }
    if ($null -eq $existing -or $null -eq (Get-Prop $existing '_generated_by')) {
      [Console]::Error.WriteLine("refusing to overwrite ${dst}: not generated by the harness (merge it by hand)"); exit 1
    }
  }
  Copy-Item -LiteralPath (Join-Path $out 'hooks.json') -Destination $dst -Force
  Write-Output "wrote $dst"
}

$nAgents = @(Get-ChildItem -LiteralPath (Join-Path $out 'agents') -Filter *.toml).Count
Write-Output "codex-setup: wrote $out (config.toml, hooks.json, $nAgents agents) for plugin $pluginVersion"
Write-Output "NOTE: under headless 'codex exec' the repo's .codex/hooks.json is skipped until the repo is trusted (or -User / --dangerously-bypass-hook-trust) - docs/codex-setup.md"
exit 0
