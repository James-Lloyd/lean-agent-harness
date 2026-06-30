---
description: Re-runnable health check — validate the harness config, gate, hooks, and baseline are still real and consistent.
argument-hint: (no args)
allowed-tools: Read, Bash, Glob, Grep
---

# /harness-doctor — is the harness still wired correctly?

`/harness-init` verifies the setup **once**. But config gets edited, scripts get renamed, a new model
lands, a stack moves — and the harness silently rots. This command re-checks the load-bearing wiring on
demand. It is **read-only**: it diagnoses and reports; it does not fix (it proposes fixes). Run it after
editing `harness.config.json`, after a stack/tooling change, after a model upgrade, or any time the loop
behaves oddly.

## Checks (report each as ✅ / ⚠️ / ❌, with the specific finding and fix)

1. **Config parses & matches the schema.** `harness/harness.config.json` is valid JSON and conforms to
   `harness/harness.schema.json` (required fields present; enums valid; types right). Flag unknown keys.
   Use a **BOM-tolerant** parser (`jq`/PowerShell `ConvertFrom-Json` are fine; `node`'s `JSON.parse`
   chokes on the UTF-8 BOM the config may carry — don't report a false "invalid JSON").

2. **No un-filled placeholders.** Grep the always-loaded files (`CLAUDE.md`, any nested component
   `CLAUDE.md`, `AGENT_NOTES.md`, `PROMPT.md`, `harness.config.json`) for `{{...}}` — any remaining means
   `/harness-init` didn't finish.

3. **Components are real.** Each `config.components[].path` exists. The edit-hook's deepest-prefix routing
   has no ambiguous overlaps (two components can't both own the same file unambiguously).

4. **Every gate command resolves and exits 0 on the untouched tree.** For each component (in its own
   directory) and the cross-cutting root gate, run each non-null `format/lint/typecheck/build/test/e2e`
   command. A gate step that errors (command not found, non-zero on clean code) is a ❌ — the gate is the
   harness; a broken gate is worse than none. (This is the same check `/harness-init` step 5 does, made
   repeatable.) Skip `e2e` if it needs a running service the doctor can't stand up — say so explicitly.

5. **Hooks exist and match the OS.** The three/four hook scripts referenced in `.claude/settings.json`
   exist, and the wired command flavor matches the platform (`powershell …ps1` on Windows;
   `bash …sh`/`pwsh` elsewhere). Both `.ps1` and `.sh` mirrors are present for portability.

6. **Loop dry-run is clean.** Run `powershell harness/loop.ps1 -DryRun` (Windows) or
   `bash harness/loop.sh --dry-run` (Unix) and confirm it reaches "would invoke" without erroring.

7. **Self-tests pass.** Run `harness/tests/run-tests.{ps1,sh}` for the current platform. These guard the
   harness's own logic (gate routing, denylist, budget, spec-lock).

8. **Baseline integrity (brownfield).** If `project.type == brownfield`: `project.baseline.established`
   is true and `baseline.ref` resolves to a real commit. Warn if `HEAD` has drifted far from it (the
   baseline may be stale and worth re-establishing via `/onboard`).

9. **Autonomy sanity.** If `mode == auto`: warn when `skipPermissions == true` without a documented
   sandbox; when `requireE2EEvidence == true` but no component/root gate defines an `e2e` step; and when
   `reviewEveryNIterations == 0` (the unattended loop will run the deterministic gate with no inferential
   judge — fine, but say so).

## Output
A short checklist (one line per check, ✅/⚠️/❌ + the finding) and, at the end, the single most important
thing to fix if anything is red. Recommend `/ratchet` for any failure class that should never recur.
