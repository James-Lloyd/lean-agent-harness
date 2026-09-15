# Installed plugin cache refresh

Date: 2026-09-15

Branch: `codex/refresh-installed-plugin-cache`

Repository plugin version: `0.5.1`

## Verdict

The real Claude Code plugin updater moved the user-scoped `lean-agent-harness` installation from
`0.2.9` to `0.5.1`. The active install, cached manifest, source manifest, and installed commit now
agree. A second invocation returned `up_to_date` at `0.5.1`, so the update path is idempotently clean.

The separately scoped `0.4.1` local installs for another repository were deliberately preserved;
`--scope user` is the scope named by the queued task and by the updater's default behavior.

## Real CLI flow

Command (the executable was addressed by its absolute npm path because it was not on this session's
PATH):

```text
claude plugin update lean-agent-harness@lean-agent-harness --scope user --yes --json
```

First run: exit 0, `updateOutcome=updated`, `oldVersion=0.2.9`, `newVersion=0.5.1`.
See `update-transition.json`.

Second run: exit 0, `updateOutcome=up_to_date`, `oldVersion=0.5.1`, `newVersion=0.5.1`.
See `update-idempotence.json`.

`claude plugin list` then reported the user plugin enabled at `0.5.1`.
`installed_plugins.json` pointed the user entry at the `0.5.1` cache and recorded repository commit
`0b24c3a817f924422fb10fa77cd2a14673fbab09`. The cached manifest also declares `0.5.1`; the real
`claude plugin validate` command exited 0. See `installed-state.txt`.

## Harness doctor checklist

- ✅ 1 Config and plugin schema parse; the self-tests pin their load-bearing agreement. The cached
  `0.5.1` plugin manifest passes Claude Code's native validator.
- ℹ️ 2 The shipped-template placeholders in root `AGENTS.md`, `AGENT_NOTES.md`, and
  `specs/000-overview.md` remain by design, as the existing queue note records. Import-shim assertions
  pass.
- ✅ 3 The single root component path exists with no overlap.
- ✅ 4 The repository gate's PowerShell twin passed 441/0 and its Bash twin passed 434/0 on this tree.
- ✅ 5 The cached plugin has exactly five `.ps1` and five `.sh` hook scripts, both host manifests, and
  `run.mjs`; project settings contain no duplicate hook wiring.
- ✅ 6 `powershell harness/loop.ps1 -DryRun` exited 0 and reached `would pipe PROMPT.md ... then run
  the gate`.
- ✅ 7 Harness self-tests passed: PowerShell 441/0; Bash 434/0.
- ℹ️ 8 Baseline integrity is not applicable because this template declares `project.type=greenfield`.
- ✅ 9 Autonomy is supervised; the auto-mode warnings do not apply.
- ✅ 10 Session/settings routing agrees (`claude-fable-5-1`, medium); one independent Fable reviewer
  is configured and no phase routes to Codex. The routing assertions pass in both twins.
- ⚠️ 11 Promotion is disabled. The pre-existing `staging` branch is absent and both stored `gh`
  identities currently report invalid tokens; neither affects this cache refresh or enables promotion.
- ℹ️ 12 No phase routes to Codex and the fresh worktree initially had no `.codex/`, so generated Codex
  surface freshness is not applicable.

Supplemental version-skew check: ✅ the active user install is `0.5.1`, equal to the source manifest;
no active `0.2.9` entry remains. The old immutable cache directory may remain as updater-owned history,
but `installed_plugins.json` and `plugin list` no longer select it.

Claude Code's platform-native `claude doctor` also exited 0 with `No installation issues found`; see
`platform-doctor.txt`. It separately noted that this non-interactive shell lacks active claude.ai
subscription authentication, which did not affect the local plugin update or validation.

## Gate note

The first elevated aggregate run produced PowerShell 441/0 and Bash 433/1: only the
`harness-codex-activate` ownership migration assertion was red. Its adjacent historical-marker and
foreign-marker controls passed. The real script path was then reproduced against the exact owned
description and passed, rewriting it to the generated `0.5.1` marker with all three hook events.
A clean Bash twin rerun passed 434/0, including that assertion and both controls. See
`ownership-migration-repro.txt`.

## Acceptance mapping

- Cache is no longer actively `0.2.9`: proven by the transition result, active installed state, and
  idempotent second update.
- Doctor's version-skew warning clears: proven by source/cache/active version equality at `0.5.1` and
  native plugin validation. Other pre-existing doctor advisories are listed above and are unrelated.

## Review

Independent fresh-context verdict: **SHIP**. The reviewer logged one non-blocking process should-fix:
this task was selected out of queue order because a truncated whole-file read hid earlier unchecked
items. The refresh itself remains complete and correct. The prevention rule is recorded in
`AGENT_NOTES.md`; work resumes at the true top unchecked item next.
