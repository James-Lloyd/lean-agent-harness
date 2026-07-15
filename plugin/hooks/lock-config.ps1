#!/usr/bin/env pwsh
# ConfigChange hook — veto settings/config changes DURING a locked loop run.
# The loop already pins harness/harness.config.json by hash (tamper => rollback + stop); this extends
# the same "don't rewrite your own gate/policy mid-run" protection to the settings surface at the
# platform level. Env-gated like the spec-lock: HARNESS_LOCK_SPECS is set only by loop.ps1/loop.sh, so
# interactive /harness-init and /update-config are unaffected. No stdin parsing needed — while the lock
# is held, NO config change is legitimate. Exit 2 + stderr => block.
$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::In.ReadToEnd() | Out-Null } catch {}
if ([string]::IsNullOrWhiteSpace($env:HARNESS_LOCK_SPECS)) { exit 0 }
[Console]::Error.WriteLine("BLOCKED by harness guardrail: configuration changes are frozen while the loop runs (HARNESS_LOCK_SPECS is set).")
[Console]::Error.WriteLine("The gate/policy must not be rewritten mid-run. If a config change is genuinely needed, stop the loop first and ask the human.")
exit 2
