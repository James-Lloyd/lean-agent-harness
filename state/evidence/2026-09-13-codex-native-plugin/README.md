# Codex native plugin evidence — 2026-09-13

Scope: plugin 0.5.0 on Codex CLI 0.154.0 and Claude Code 2.1.268, Windows 11.

## Results

1. `node plugin/scripts/validate-openai-plugin.mjs` passed the portable, Codex, and Claude manifest
   agreement; modern and legacy marketplaces; four-command Codex hook manifest; all 21 discoverable
   skills (15 native Codex entry points); six dual-cache wrappers with real cache-only execution;
   concise root `AGENTS.md`; synchronized command adapters; and the user-hook install/check,
   cross-migration, and foreign-marker refusal contract.
2. The plugin creator validator passed `plugin/`; the skill creator validator passed all 21 plugin
   skill directories; Claude Code validated both `plugin/` and `.claude-plugin/marketplace.json`.
3. The exact tree's root gate passed both twins: **PowerShell 440 passed / 0 failed** and **Bash 433
   passed / 0 failed**. This includes both engine suites and the package validator.
4. Codex installed `lean-agent-harness@lean-agent-harness` at version 0.5.0. The probe invoked the
   activation installer from that installed cache, its `--check` returned fresh, and all four emitted
   commands targeted that cache root. A fresh `codex exec`, with Claude absent from its `PATH`,
   explicitly invoked `$harness-init` and `$harness-work`; it read both installed skills, the shared
   adapter, and both canonical commands, then selected `CODEX_PLUGIN_MODE` without invoking Claude.
   See `probe-results.txt` (summary) and `session-results.txt` (full scrubbed transcript).
5. Codex 0.154.0 did **not** discover the plugin-scoped `hooks/hooks.json`: before user-level
   activation, `/hooks` reported zero installed and zero active entries for every event. This was
   repeated with the documented portable extension, `.codex-plugin` hook field, and conventional
   root `hooks/hooks.json`; the package retains the standard manifest for hosts/future CLIs that
   implement it.
6. The first compatibility install exposed a second live defect: Codex rejected the historical
   `_generated_by` top-level key as unknown and skipped the whole user hook file. The installer and
   both legacy generator twins now encode ownership in the schema-supported `description` field and
   emit only `description` plus `hooks`. Both activation paths accept the exact historical generator
   marker and each other's current description, while refusing a foreign `_generated_by` value.
7. The interactive `/hooks` review table reported PreToolUse 2/2 installed/active, PostToolUse 1/1,
   and SessionStart 1/1 for the compatibility manifest. After the path changed to the installed cache,
   the final headless proof used `--dangerously-bypass-hook-trust`; its transcript recorded
   `hook: SessionStart Completed` and `hook: PreToolUse Blocked` for a real
   `cmd /d /s /c rd /s/q <sentinel>` call. The sentinel survived; the probe's positive control ran
   the same command outside the hook runner and removed it.
8. The first fresh-context review returned FIX-THEN-SHIP with four blockers, three should-fixes, and
   one nit; all were resolved. The scoped follow-up found no remaining findings and returned
   **VERDICT: SHIP** (`review-round2.md`).

## Re-run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\state\evidence\2026-09-13-codex-native-plugin\probe.ps1
```

The model arm requires the plugin installed/enabled, the user hooks activated and reviewed, and a
logged-in Codex CLI. `-SkipModel` runs only the free package, install-record, and dispatcher checks.
The probe writes through its own username scrubber and confines the disposable deletion target to
this evidence directory.
