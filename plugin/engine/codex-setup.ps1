#requires -Version 5.1
<#
  codex-setup.ps1 - generate the OpenAI Codex CLI surfaces for a harness project (PS twin of
  codex-setup.sh; behaviour and output bytes must match it - either twin may generate, either may -Check).
  Design-doc 002 D3: Codex reads `.codex/` in the repo, so the harness's guard hooks, phase agents and
  skills have to exist there in Codex's own formats - but the plugin lives in the per-machine cache, so
  the generated files carry ABSOLUTE local paths and must never be committed (ratchet 2026-07-30).
  Everything here is therefore GENERATED + GITIGNORED and re-runnable.

  Writes, under <project>/.codex/ :
    config.toml         [features] hooks=true; [[skills.config]] path=<plugin>/skills + enabled=true (NO
                        [agents] block: in Codex 0.144.3 that table holds agent roles, and unknown keys
                        under it are a FATAL config-load error - verified live in slice V5)
    hooks.json          four of the five guard hooks through <plugin>/hooks/run.mjs (lock-config's
                        ConfigChange has no Codex event). protect-specs / format-and-check / session-start
                        run under matcher "*" (their bodies exit 0 on a payload without a file path).
                        block-destructive does NOT: when tool_input.command is absent it scans the WHOLE
                        payload ("fail toward scanning"), so under "*" a Codex EDIT whose patch text mentions
                        `rm -rf` would be falsely denied. It is emitted under -ShellMatcher (default
                        "Bash": the tool_name Codex 0.144.3 sends for shell commands, recorded live in
                        slice V5) - see docs/codex-setup.md.
    agents/<name>.toml  one per plugin agent: model/effort from the phase's effective codex settings,
                        sandbox_mode read-only for judges, developer_instructions = the agent body
    .harness-stamp.json plugin version + sha256 of the inputs, so -Check can detect staleness
  and, under <project>/.agents/skills/ :
    <name>/SKILL.md     every harness COMMAND as a Codex skill (`harness-<command>`) plus the plugin's
                        reference skills. This is the ONLY skill location `codex exec` reads - the
                        config.toml [[skills.config]] stanza is inert for exec (measured 0.153.4,
                        state/evidence/2026-09-09-v6.3-command-skill-bridge/). Dirs carrying a
                        .harness-generated marker are ours to replace; anything else is left alone.
  and appends `.codex/` and `.agents/` to <project>/.gitignore if missing.

  Usage: codex-setup.ps1 -ProjectRoot <repo> [-Check] [-User] [-ShellMatcher <regex>]
    -Check  exit 0 if the generated set exists and matches the current inputs, 1 if missing/stale
    -User   ALSO write hooks.json to ~/.codex/hooks.json (override dir with $env:HARNESS_CODEX_HOME) - the
            ONLY file headless `codex exec` loads hooks from (V5: the project file is never loaded
            headlessly); it still needs `/hooks` trust once, or --dangerously-bypass-hook-trust per run.
            MACHINE-WIDE: applies to every Codex project on this machine. Refuses to overwrite a
            hooks.json there that the harness did not generate.
    -ShellMatcher <regex>  the PreToolUse matcher for block-destructive (Codex shell tool name(s)).
            Default "Bash" was recorded from a real payload in V5; a wrong name means the hook never
            fires (fail-open for that one hook, never a false denial). Re-record on a Codex upgrade.
#>
[CmdletBinding()]
param(
  [string] $ProjectRoot,
  [switch] $Check,
  [switch] $User,
  # Pinned in slice V5 from a recorded Codex 0.144.3 PreToolUse payload: shell commands arrive as
  # tool_name "Bash" with tool_input.command (Codex mirrors Claude Code's hook contract). Was a guess.
  [string] $ShellMatcher = 'Bash'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$pluginRoot = Split-Path -Parent $PSScriptRoot
$hooksDir = Join-Path $pluginRoot 'hooks'; $skillsDir = Join-Path $pluginRoot 'skills'; $agentsDir = Join-Path $pluginRoot 'agents'
$cmdsDir  = Join-Path $pluginRoot 'commands'   # source of the command->skill bridge (design-doc 002 V6)

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
function Ordinal-Files([string]$dir, [string]$filter) {
  $files = @(Get-ChildItem -LiteralPath $dir -Filter $filter -ErrorAction SilentlyContinue)
  $names = New-Object System.Collections.ArrayList
  foreach ($f in $files) { [void]$names.Add($f.Name) }
  $names.Sort([System.StringComparer]::Ordinal)
  return @($names | ForEach-Object { $n = $_; $files | Where-Object { $_.Name -ceq $n } | Select-Object -First 1 })
}
# Plugin skill dirs in ordinal order by DIRECTORY name — the .sh twin sorts the `<dir>/SKILL.md` glob,
# whose ordering is decided by the directory component, and hashes `## <dirname>` before each body.
function Skill-Files {
  $dirs = @(Get-ChildItem -LiteralPath $skillsDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') -PathType Leaf })
  $names = New-Object System.Collections.ArrayList
  foreach ($d in $dirs) { [void]$names.Add($d.Name) }
  $names.Sort([System.StringComparer]::Ordinal)
  return @($names | ForEach-Object { $n = $_; $dirs | Where-Object { $_.Name -ceq $n } | Select-Object -First 1 })
}
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
  # The generated .agents/skills/ set is derived from the commands and the plugin skills, so a change
  # to either must read STALE. Order and separators mirror the .sh twin byte for byte.
  foreach ($f in (Ordinal-Files $cmdsDir '*.md')) {
    $w.Write($utf8.GetBytes("## $($f.Name)`n"))
    $w.Write([System.IO.File]::ReadAllBytes($f.FullName))
  }
  foreach ($d in (Skill-Files)) {
    $w.Write($utf8.GetBytes("## $($d.Name)`n"))
    $w.Write([System.IO.File]::ReadAllBytes((Join-Path $d.FullName 'SKILL.md')))
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
  # The .agents/skills/ bridge lives OUTSIDE $out, so the gate above cannot see it (mirror of the .sh
  # twin): without this, deleting the whole bridge still reported `fresh`, and /harness-doctor 12 runs
  # exactly this check.
  $wantSkills = @(Get-ChildItem -LiteralPath $cmdsDir -Filter *.md -ErrorAction SilentlyContinue).Count +
                @(Get-ChildItem -LiteralPath $skillsDir -Directory -ErrorAction SilentlyContinue |
                  Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') -PathType Leaf }).Count
  $haveSkills = @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot '.agents/skills') -Directory -ErrorAction SilentlyContinue |
                  Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') -PathType Leaf }).Count
  if ($haveSkills -eq 0) {
    Write-Output 'codex-setup: NOT generated (.agents/skills is missing - run harness/codex-setup.ps1)'; exit 1
  } elseif ($haveSkills -lt $wantSkills) {
    Write-Output "codex-setup: STALE (.agents/skills has $haveSkills of $wantSkills skills; re-run harness/codex-setup.ps1)"; exit 1
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
# Emit ONLY keys the installed Codex CLI is known to load (verified live against 0.144.3, slice V5): a
# [[skills.config]] entry REQUIRES `enabled` (missing => fatal "missing field `enabled`" and the whole
# .codex/ layer is dead), and [agents] is a table of agent ROLES there - `enabled = true` /
# `default_subagent_*` under it are parsed as a role and rejected ("expected struct AgentRoleToml").
# The per-agent model/effort already lives in agents/<name>.toml, so no global block. Mirror of the sh twin.
$toml = "# $genNote`n`n[features]`nhooks = true`n`n[[skills.config]]`npath = `"$(TomlBasic (Fwd $skillsDir))`"`nenabled = true`n"
Write-NoBom (Join-Path $out 'config.toml') $toml

# hooks.json - mirror of plugin/hooks/hooks.json with absolute commands; ConfigChange has no Codex event.
$runMjs = Fwd (Join-Path $hooksDir 'run.mjs')
# --codex: Codex ignores a hook's exit code 2 (logged "Failed", call proceeds - fail-open, observed live in
# V5); the dispatcher's codex mode translates exit 2 + stderr into the JSON permissionDecision Codex blocks on.
function HookCmd([string]$h) { return ('node "{0}" --codex {1}' -f $runMjs, $h) }
# block-destructive is scoped to the shell tool matcher (see header): under "*" its whole-payload
# fallback scan would deny edits whose text merely mentions a denylisted command.
$hooks = [ordered]@{
  _generated_by = $genNote
  _shell_matcher_note = 'block-destructive fires only for tools matching this regex; default Bash = the tool_name Codex 0.144.3 sends for shell commands (recorded live in slice V5, docs/codex-setup.md)'
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
# .agents/skills/ - THE ONLY SKILL LOCATION CODEX EXEC ACTUALLY READS (mirror of the .sh twin).
# Measured 2026-09-09 on codex-cli 0.153.4 with a canary token present in exactly one file
# (state/evidence/2026-09-09-v6.3-command-skill-bridge/): a skill under `.agents/skills/<name>/` is
# discovered and used without being named in the prompt, while the identical file behind a
# `[[skills.config]] path` entry is never reached. Emits the plugin's reference skills verbatim, plus
# every harness COMMAND as a skill - the command->skill bridge (design-doc 002 slice V6).
$skillsOut = Join-Path $ProjectRoot '.agents/skills'
$script:skillCollisions = 0
[void](New-Item -ItemType Directory -Force -Path $skillsOut)
# Wipe only what WE generated, so a hand-written skill beside ours survives a re-run.
foreach ($d in @(Get-ChildItem -LiteralPath $skillsOut -Directory -ErrorAction SilentlyContinue)) {
  if (Test-Path -LiteralPath (Join-Path $d.FullName '.harness-generated') -PathType Leaf) {
    # Delete only the two files WE wrote, then the dir if it is now empty - the .sh twin's behaviour.
    # A recursive force-delete here is not twin-equivalent: anything a user left inside a generated
    # skill dir (notes, a scripts/ folder) survives on Linux and vanished on Windows.
    Remove-Item -LiteralPath (Join-Path $d.FullName '.harness-generated') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $d.FullName 'SKILL.md') -Force -ErrorAction SilentlyContinue
    if (-not @(Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue).Count) {
      Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
    }
  }
}
function Strip-Frontmatter([string]$path) {
  $lines = [System.IO.File]::ReadAllLines($path); $n = 0; $started = $false
  $body = New-Object System.Collections.ArrayList
  foreach ($ln in $lines) {
    if ($ln -match '^---\s*$') { $n++; if ($n -le 2) { continue } }
    if ($n -lt 2) { continue }
    if (-not $started -and $ln.Trim() -eq '') { continue }
    $started = $true; [void]$body.Add($ln)
  }
  while ($body.Count -gt 0 -and $body[$body.Count - 1].Trim() -eq '') { $body.RemoveAt($body.Count - 1) }
  return ($body -join "`n")
}
function Emit-Skill([string]$name, [string]$desc, [string]$bodyText, [string]$preamble) {
  $sd = Join-Path $skillsOut $name
  # A hand-written skill of the same name is skipped, not overwritten (mirror of the .sh twin):
  # overwriting would also stamp it .harness-generated, making it a wipe target for every future run.
  if ((Test-Path -LiteralPath (Join-Path $sd 'SKILL.md') -PathType Leaf) -and
      -not (Test-Path -LiteralPath (Join-Path $sd '.harness-generated') -PathType Leaf)) {
    [Console]::Error.WriteLine("codex-setup: SKIPPING $name - a hand-written skill of that name already exists (rename it to let the harness generate this one)")
    $script:skillCollisions++
    return
  }
  [void](New-Item -ItemType Directory -Force -Path $sd)
  $t = "---`nname: $name`ndescription: $desc`n---`n`n<!-- $genNote -->`n`n"
  if ($preamble) { $t += "$preamble`n`n" }
  $t += "$bodyText`n"
  Write-NoBom (Join-Path $sd 'SKILL.md') $t
  Write-NoBom (Join-Path $sd '.harness-generated') ''
}
foreach ($d in (Skill-Files)) {
  $sf = Join-Path $d.FullName 'SKILL.md'
  $sname = ''; $sdesc = ''
  foreach ($ln in [System.IO.File]::ReadAllLines($sf)) {
    if (-not $sname -and $ln -match '^name:\s*(.+)$')        { $sname = $Matches[1] }
    if (-not $sdesc -and $ln -match '^description:\s*(.+)$') { $sdesc = $Matches[1] }
  }
  if (-not $sname) { $sname = $d.Name }
  Emit-Skill $sname $sdesc (Strip-Frontmatter $sf) ''
}
$cmdPreamble = '**You are running under the OpenAI Codex CLI, not Claude Code.** This is a harness command translated into a skill. Read `AGENTS.md` at the repo root for the project map (Codex reads it natively; Claude Code gets the same content plus a short Claude-specific section through `CLAUDE.md`). Translations that apply throughout the text below: a **slash command** (`/work`, `/review`, and so on) is another skill in this same directory named `harness-<command>` - except for a command whose own name already begins `harness-`, which keeps it (`/harness-doctor` is the skill `harness-doctor`, never `harness-harness-doctor`); invoke one by reading it, not by typing the slash form, which does not exist here. **`$ARGUMENTS`** is whatever the operator asked for in their own words - substitute it, or take the command''s stated default when they gave none. **`${CLAUDE_PLUGIN_ROOT}`** does not expand under Codex; the same engine scripts are reachable through this repo''s own `harness/` wrappers (`harness/loop.sh`, `harness/codex-setup.sh`, and so on). A **subagent** named in the text (`generator`, `reviewer`, `planner`, `explorer`, `evaluator`, `doc-gardener`) has a Codex role definition under `.codex/agents/<name>.toml` carrying that phase''s model, reasoning effort and sandbox; where the text says to spawn one, either delegate to that role or do the work yourself under its rules and its sandbox - and keep the harness''s own rule that the doer is never the judge. **`allowed-tools` frontmatter, `model:` frontmatter and their drift checks are Claude-Code-only and do not apply.** Everything else - the phase order, the gates, the guardrails, the output contract - applies unchanged.'
foreach ($f in (Ordinal-Files $cmdsDir '*.md')) {
  $cname = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
  $cdesc = ''
  foreach ($ln in [System.IO.File]::ReadAllLines($f.FullName)) {
    if ($ln -match '^description:\s*(.+)$') { $cdesc = $Matches[1]; break }
  }
  if (-not $cdesc) { $cdesc = "The harness's /$cname command, translated for Codex." }
  # `harness-doctor.md` etc. already carry the prefix; don't emit `harness-harness-doctor`.
  $sname = if ($cname.StartsWith('harness-')) { $cname } else { "harness-$cname" }
  Emit-Skill $sname $cdesc (Strip-Frontmatter $f.FullName) $cmdPreamble
}
$skillCount = @(Get-ChildItem -LiteralPath $skillsOut -Directory -ErrorAction SilentlyContinue).Count

$stampObj = [ordered]@{ pluginVersion = $pluginVersion; inputsHash = (Get-InputsHash); pluginRoot = (Fwd $pluginRoot); generatedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
Write-NoBom (Join-Path $out '.harness-stamp.json') (($stampObj | ConvertTo-Json) + "`n")

# .gitignore - the generated set carries machine-local absolute paths: never commit it.
$gi = Join-Path $ProjectRoot '.gitignore'
$giLines = if (Test-Path $gi) { @(Get-Content -LiteralPath $gi) } else { @() }
if (-not ($giLines -ccontains '.codex/')) {
  # AppendAllText with the no-BOM encoding: Add-Content -Encoding utf8 would splice a BOM mid-file on 5.1.
  [System.IO.File]::AppendAllText($gi, "`n# OpenAI Codex CLI surfaces generated by harness/codex-setup.* (machine-local absolute paths):`n.codex/`n", $utf8)
}
# .agents/ gets its own guard: a repo set up before the bridge shipped already has the `.codex/` line,
# so a combined check would never append this one. `-ccontains` is case-sensitive, matching the .sh
# twin's `grep -qx`. Re-read the file: the block above may have just appended to it.
$giLines2 = if (Test-Path $gi) { @(Get-Content -LiteralPath $gi) } else { @() }
if (-not ($giLines2 -ccontains '.agents/')) {
  # Leading newline unless the file already ends with one - see the .sh twin: the `.codex/` block's
  # leading `\n` is not inherited by this one, and without this guard a .gitignore with no trailing
  # newline gets `.codex/.agents/`, un-ignoring both.
  $needsNl = $false
  if (Test-Path -LiteralPath $gi -PathType Leaf) {
    $bytes = [System.IO.File]::ReadAllBytes($gi)
    if ($bytes.Length -gt 0 -and $bytes[$bytes.Length - 1] -ne 0x0A) { $needsNl = $true }
  }
  if ($needsNl) { [System.IO.File]::AppendAllText($gi, "`n", $utf8) }
  [System.IO.File]::AppendAllText($gi, ".agents/`n", $utf8)
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
Write-Output "codex-setup: wrote $skillsOut ($skillCount skills - the harness commands as harness-<name>, plus the reference skills)"
Write-Output "NOTE: .agents/skills/ is where 'codex exec' actually finds skills; the config.toml [[skills.config]] stanza does NOT deliver them (measured 0.153.4) - docs/codex-setup.md"
Write-Output "NOTE: under headless 'codex exec' the repo's .codex/hooks.json is NEVER loaded (Codex 0.144.3, slice V5) - use -User (~/.codex/hooks.json) plus /hooks trust or --dangerously-bypass-hook-trust; the project file serves interactive sessions - docs/codex-setup.md"
exit 0
