# AGENT_NOTES.md — the amnesiac's notebook

Brief, factual entries a fresh-context agent needs to be productive in *this* repo. Keep it terse —
it's loaded often; `/gc` compacts it. Engine-internal rules (PS 5.1, twin parity, dispatcher
invariants) live in `plugin/engine/AGENTS.md`, not here.

## How to run / build / test
<!-- /harness-init fills one block per component (mirroring the AGENTS.md components table); a
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
  invisible in Linux-only CI). Engine-internal, so the rule lives with the engine: `plugin/engine/AGENTS.md`.
- [2026-09-04] Permission-prompt load is mostly NOT an allowlist gap. Across 50 recent sessions, ~45% of
  Bash calls began `cd <path> && …` (a `cd` in a compound command defeats the read-only auto-allow and
  prompts) and ~13% were `node`/`python` heredocs (an interpreter can never be allowlisted). Use absolute
  paths and the Read/Grep/Glob tools instead; rule recorded in AGENTS.md "How to work". Separately, the
  user-level Claude settings file carried ~200 KB of mojibake in its auto-mode context strings (an em
  dash re-encoded through cp1252 ~10x) that the auto-mode classifier re-read on every call — keep
  settings strings ASCII; the classifier also blocks shell writes to that file, so a human runs the repair.
- [2026-09-04] Headless `--effort` is now plumbed (dispatch.* Claude arm, from `models.<phase>.effort` /
  `fallbackEffort`). Only `low|medium|high|xhigh|max` become a flag — `minimal` is codex-only and is
  silently omitted, so a `minimal` on a Claude phase runs at the model default, not at minimal.
- [2026-09-04] The block-destructive hook's secrets-read pattern matches `.env` as a SUBSTRING, so a
  `cat >> notes.md <<EOF` whose body mentions `autoMode.environment` is denied as "reading secrets".
  Append prose through the Edit tool, or keep `.env`-shaped words out of heredoc bodies.
- [2026-09-05] `codex exec` prints two `ERROR codex_models_manager … 401 Unauthorized … token_expired` lines at
  start-up and then runs normally — that is the models-list cache refresh, not the session. `codex login status`
  (what `codex_available` probes) and the exit code are the signals the dispatcher keys on; do not read a 401 in
  the transcript as a usage-limit or unavailable trigger.
- [2026-09-05] The auto-mode permission classifier refuses to run a script that carries Codex
  `--dangerously-bypass-hook-trust` (the flag a headless `codex exec` needs to honour a repo `.codex/hooks.json`
  without persisting trust), even against a nonexistent scratch path in a read-only sandbox. A Codex hook probe is
  therefore a human-run step: stage the script in the evidence dir and hand James the Git Bash command line.
- [2026-09-05] Inside a worktree session the isolation hook also refuses a reviewer SUBAGENT's `powershell`
  invocations, so a Windows judge can re-run the bash twin live but not the PS twin; CI covers PS. It likewise
  refuses inline `source`/`export` — put multi-step shell in a scratchpad script and run `bash <script>`.
- [2026-09-05] Under headless `codex exec` (0.144.3) the project `.codex/hooks.json` is NEVER loaded, even with the
  project trusted and `--dangerously-bypass-hook-trust`; only `~/.codex/hooks.json` (codex-setup `--user`) and inline
  `-c 'hooks.PreToolUse=[{matcher="Bash",hooks=[{type="command",command="node \"<run.mjs>\" --codex <hook>",timeout=30}]}]'`
  fire — and only with the bypass flag or prior `/hooks` trust. The inline form is the zero-side-effect way to probe.
- [2026-09-05] Codex ignores a hook's exit code 2 (logs `PreToolUse Failed`, runs the command); it blocks only on the
  JSON `permissionDecision: deny` on stdout with exit 0 — hence `run.mjs --codex`. Verify a denial by the command NOT
  running (`hook: PreToolUse Blocked` in the transcript), never by the hook's exit code.
- [2026-09-05] The npm Codex CLI binary is `node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/*/bin/codex.exe`
  (not the `codex-code-mode-host.exe` beside it); `grep -a -o` for field names settles docs-vs-installed drift fast
  (0.144.3 has `AgentRoleToml` but no `default_subagent_model`). An unknown TOML key is a FATAL, silent config-load
  error that drops the whole project `.codex/` layer — load-test generated config with a one-line `codex exec`.
- [2026-09-05] `state/handoff.md` is GITIGNORED and therefore per-worktree: a handoff written inside a
  worktree cannot land in its PR and dies when the worktree is removed, leaving the next session to read a
  stale one from the main checkout. Finish a worktree session by copying it across with a plain `cp` (the
  file is untracked, so the worktree guard permits the write). `git status` calling the tree clean after you
  edited it is the tell.
- [2026-09-06] Dogfooding a classifier on a REAL range finds what unit fixtures cannot. `/promote`'s
  money rule passed every unit test and reported no money vocabulary at all in a real 167 KiB diff:
  `printf '%s' "$text" | grep -q` loses the match to SIGPIPE under `set -o pipefail` once the text
  passes the 64 KiB pipe buffer (`PIPESTATUS=(141 0)` — grep matched, printf died, pipefail returned
  141). Fixtures under 64 KiB never reach the failure. When a predicate guards something that matters,
  run it over a real input before believing the suite. Also: on this repo almost every range is HIGH
  by design — `RISK_SELF_GOVERN_GLOBS` pins any change to the harness's own policy/guardrail/CI files
  — so a LOW sample for a promotion dogfood has to be a commit that touches none of its own controls.
