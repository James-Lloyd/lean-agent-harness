#!/usr/bin/env pwsh
# PreToolUse(Edit|Write|MultiEdit) hook — make specs/ immutable DURING an unattended loop run.
# Specs are the contract; the loop must never rewrite them to make work "pass". This mechanizes the
# CLAUDE.md/PROMPT.md prose guardrail in the one context where prose isn't enough (headless auto runs).
#
# Env-gated on purpose: only blocks when $env:HARNESS_LOCK_SPECS is set (loop.ps1/loop.sh set it before
# invoking the model). In interactive sessions the var is unset, so /plan, /harness-init, and /onboard —
# which legitimately author specs — are unaffected. Exit 2 + stderr => block; exit 0 => allow.
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($env:HARNESS_LOCK_SPECS)) { exit 0 }   # not in a locked loop run

$changed = $null
# NotebookEdit carries `notebook_path`, not `file_path` — fall back so specs/*.ipynb is covered too.
try {
  $p = [Console]::In.ReadToEnd() | ConvertFrom-Json
  $changed = [string]$p.tool_input.file_path
  if ([string]::IsNullOrWhiteSpace($changed)) { $changed = [string]$p.tool_input.notebook_path }
} catch {}
if ([string]::IsNullOrWhiteSpace($changed)) { exit 0 }

$root = $env:CLAUDE_PROJECT_DIR; if (-not $root) { $root = (Get-Location).Path }
$root = ($root -replace '\\','/').TrimEnd('/')
$rel = $changed
try { $rel = [System.IO.Path]::GetFullPath($changed) } catch {}
$rel = ($rel -replace '\\','/')
if ($rel.ToLower().StartsWith($root.ToLower() + '/')) { $rel = $rel.Substring($root.Length).TrimStart('/') }   # '/'-suffixed so a sibling dir sharing the prefix doesn't match

if ($rel -match '^(?i)specs/') {
  [Console]::Error.WriteLine("BLOCKED by harness guardrail: specs/ is immutable while the loop runs (HARNESS_LOCK_SPECS is set).")
  [Console]::Error.WriteLine("Specs are the contract - they describe what to build, not a place to record what you built. If a spec is wrong, stop and write the question to state/handoff.md under 'Needs human decision'.")
  exit 2
}
exit 0
