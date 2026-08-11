# AGENT_NOTES.md — the amnesiac's notebook

Brief, factual entries a fresh-context agent needs to be productive in *this* repo. Keep it terse —
it's loaded often; `/gc` compacts it. Engine-internal rules (PS 5.1, twin parity, dispatcher
invariants) live in `plugin/engine/CLAUDE.md`, not here.

## How to run / build / test
<!-- /harness-init fills one block per component (mirroring the CLAUDE.md components table); a
     single-root project has one block. Correct these the moment reality differs. -->
- **{{COMPONENT_NAME}}** (`{{COMPONENT_PATH}}` — run these in that directory):
  - Run: `{{COMPONENT_RUN}}` · Build: `{{COMPONENT_BUILD}}` · Test: `{{COMPONENT_TEST}}`
  - Format / lint / typecheck: `{{FORMAT_COMMAND}}` / `{{LINT_COMMAND}}` / `{{TYPECHECK_COMMAND}}`

This repo (harness dev): suites source the engine from `HARNESS_ENGINE` — set it to
`<repo>/plugin/engine` to test live in-repo edits (else you get the stale installed-plugin cache).
PowerShell 5.1: `powershell harness/tests/run-tests.ps1`; bash needs `jq` on PATH
(WinGet package dir). Fleet e2e: `harness/tests/fleet-queue-test.{ps1,sh}`.

## Environment quirks
- The block-destructive PreToolUse hook scans the whole Bash command line — a commit message that
  *mentions* a trigger phrase (`reset --hard`, …) gets blocked. Write the message to a file and use
  `git commit -F <file>`.
- Local `.git/hooks/pre-commit` privacy guard blocks private project names / personal email from
  entering this PUBLIC repo — write clean.
- One agent session per working tree — two concurrent sessions on one repo collide.
- The auto-mode classifier blocks the AGENT from editing `.claude/settings.json` to remove/weaken
  guard hooks — a human must hand-edit; guard-strengthening and comment edits pass.

## Learnings (append when a loop discovers something; /gc dedupes)
- [2026-07-13] Codex CLI: global flags (`--sandbox`, `--ask-for-approval`) go BEFORE the `exec`
  subcommand. `codex exec` has no --max-turns/--timeout — the harness wraps it in a watchdog
  (`models.codex.timeoutSeconds`). `codex login status` false-negatives under Azure/custom providers.
  codex-cli is installed + authed (chatgpt) on this machine; read-only review path is live-fire-proven,
  the workspace-write path is deliberately still untested — first real write run should be supervised.
- [2026-07-13] Fleet workers must NOT edit `state/` files or AGENT_NOTES.md — the fleet runner records
  after each merge; parallel edits to shared files guarantee merge-queue conflicts.
- [2026-07-13] Run dirs under `harness/.runs/` are CLAIMED at allocation (mkdir-as-mutex) — a run dir
  existing does not mean the run produced output.
- [2026-07-14] loop/fleet resolve the PROJECT root from `-ProjectRoot`/`--project-root` → git
  top-level of CWD → CWD. Invoking a raw engine script by absolute path from another directory
  targets the wrong root — `cd` in first or pass `-ProjectRoot` (the thin `harness/` wrappers already
  do this).
- [2026-07-14] bash `invoke_phase` must be called DIRECTLY, never in `$(...)` — a subshell drops its
  `INVOKE_PHASE_*` return globals.
- [2026-07-14] Capture evidence test counts on the EXACT tree being committed (HEAD + staged),
  re-running after any rebase/merge-back — pre-merge counts can be stale.
- [2026-07-15] codex review reads EVERY source file (~100k tokens, can exceed the 2-min foreground
  cap) — dispatch with `run_in_background`; transcripts are gitignored.
- [2026-07-26] Prompt surfaces must not carry thinking-trigger phrases, instruction self-repetition,
  or blanket "fan out subagents" encouragement — Claude-5-generation models control depth via effort,
  follow an instruction stated once, and over-delegate when encouraged. Structural judges
  (fresh-context reviewer/evaluator, fail-closed verdicts, the gate) are NOT the "over-verification"
  the Opus 5 docs warn about — that guidance targets self-re-checking. Keep the judges.
  Details: docs/execution-plans/2026-07-26-claude5-context-refresh.md; docs/principles/sources.md rows 8–9.
- [2026-08-08] `jq.exe` under Git Bash emits CRLF, which silently breaks config-derived globs (fail-OPEN,
  invisible in Linux-only CI). Engine-internal, so the rule lives with the engine: `plugin/engine/CLAUDE.md`.
