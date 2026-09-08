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
  `git commit -F <file>`. As of 2026-09-08 the bash twin also carries the PowerShell/cmd.exe forms
  the `.ps1` always had, so the trigger list now includes `Remove-Item` with `-Recurse`/`-Force`,
  `rd`/`rmdir` and the cmd.exe delete switches (in ANY flag order), and
  `Format-Volume`/`Clear-Disk`/`Clear-Content` — on POSIX as well as Windows. Prose that merely
  quotes one of those switches is denied on both twins; that one is deliberate parity, not a bug.
  A POSIX path whose first segment starts with the switch letter (`rmdir /srv/cache`, `rd /storage`)
  is NOT denied — it was, briefly, and that over-block is the subject of the 2026-09-08 ratchet
  (`state/evidence/2026-09-08-guard-hook-twin-gap/`).
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
- [2026-09-05 · re-confirmed on 0.153.4, 2026-09-06] Under headless `codex exec` the project `.codex/hooks.json` is NEVER loaded, even with the
  project trusted and `--dangerously-bypass-hook-trust`; only `~/.codex/hooks.json` (codex-setup `--user`) and inline
  `-c 'hooks.PreToolUse=[{matcher="Bash",hooks=[{type="command",command="node \"<run.mjs>\" --codex <hook>",timeout=30}]}]'`
  fire — and only with the bypass flag or prior `/hooks` trust. The inline form is the zero-side-effect way to probe.
- [2026-09-05] Codex ignores a hook's exit code 2 (logs `PreToolUse Failed`, runs the command); it blocks only on the
  JSON `permissionDecision: deny` on stdout with exit 0 — hence `run.mjs --codex`. Verify a denial by the command NOT
  running (`hook: PreToolUse Blocked` in the transcript), never by the hook's exit code.
- [2026-09-05] The npm Codex CLI binary is `node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/*/bin/codex.exe`
  (not the `codex-code-mode-host.exe` beside it); `grep -a -o` for field names settles docs-vs-installed drift fast
  (0.144.3 has `AgentRoleToml` but no `default_subagent_model`). On **0.144.3** an unknown TOML key was a FATAL,
  silent config-load error that dropped the whole project `.codex/` layer. **Do not generalise that to the
  installed CLI**: on 0.153.4 `[agents] enabled = true` no longer errors (2026-09-06 re-verification), and the
  evidence cannot separate "unknown keys are now tolerated" from "`agents.enabled` became a real key" — only a
  syntactically invalid file was confirmed still fatal. Load-test generated config against the INSTALLED version
  with a one-line `codex exec`, every time; and note the load only happens at all for a TRUSTED project.
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
- [2026-09-06 · SUPERSEDED 2026-09-06 by the conversion] This note used to say the
  `printf '%s' "$x" | grep -q` fail-open *still lives* in `block-destructive.sh` / `protect-specs.sh`,
  that the hooks are safe only because none of them sets `pipefail`, and that the conversion was a
  pending `fix_plan` item. All three stopped being true when the 16 sites were converted to
  here-strings — see `plugin/engine/AGENTS.md` for the current rule. It also offered the wrong safety
  net: the ">64 KiB payload must still exit 2" assertion it pointed at was a SINGLE-line fixture, and
  a single line cannot reproduce the failure (grep must read a whole line before it can match, so it
  consumes all 200 KB, printf finishes writing, and no SIGPIPE happens). It passed against the broken
  hook too. Kept as a marker rather than deleted because it is the text that seeded the stale claim,
  and because the *pattern* is the lesson: when you close a task, the note that justified it is the
  surface most likely left asserting the defect still exists.
- [2026-09-06] `state/PROGRESS.md` and the `<!-- DONE ... -->` annotations in `fix_plan.md` are an
  APPEND-ONLY LOG: a gate count in them is a fact about the run that happened, not a value to keep
  current. A repo-wide `sed -i 's/fleet-queue 31\/0/34\/0/'` to update this batch's line silently
  rewrote four 2026-09-04 entries that were correct as written. Scope the pattern to the line you mean
  (`sed -i '/DONE 2026-09-06/ s/.../.../'`) and read `git diff` before committing — the corruption is
  invisible in the file, and only shows up as a diff touching dates you never worked on.
- [2026-09-07] **Probing a foreign tool: the oracle must be able to fail, and silence is only evidence
  next to a control that speaks.** The question "does Codex auto-discover `.codex/agents/*.toml`" cannot
  be answered with a well-formed role file, because a file that loaded and a file that was never read
  both look like nothing happening. It is answered with a DELIBERATELY MALFORMED one: the loader's own
  error names the path it read. Same shape as the guard-probe rule from 2026-09-06 — a probe that
  cannot discriminate is not a probe. Two things fell out of doing it that way. A malformed role file
  is a WARNING, not a fatal — unlike the V3 `config.toml` defects it degrades silently and does not
  take the layer down. And an enumeration is not proof of use: asked to name its roles with no
  project `.codex/` at all, the model still produced a plausible name, so the only sound evidence
  that a role RUNS is a token that exists nowhere but inside that role's own instructions coming
  back from a spawn.
- [2026-09-07] **A filtered view cannot prove silence — and this is the second time, one day apart.**
  The 2026-09-06 note says a `grep`-narrowed transcript cannot support "no warning was printed". The
  very next session asserted, in six surfaces, that `codex doctor` is blind to a malformed agent role
  — from a probe that piped doctor through `sed -n '1,30p'`. Doctor reports it fine, as a
  `startup warning` field at line 121. The claim died only because a fresh-context reviewer refused
  an assertion whose cited file did not contain it. Reading the ratchet is not the same as applying
  it: the guard that actually worked was structural (cite the file and line, or do not write the
  claim), not memory.
- [2026-09-07] **`cmd | grep -q … || echo "(none)"` lies under `set -o pipefail` when `cmd` exits
  non-zero.** The pipeline's status becomes the failure, so the `||` fallback fires even though grep
  MATCHED — printing the match and "(none found)" underneath it. Hit twice in one session: once as a
  review finding on `grep … || echo "(none - roles are undeclared)"` firing over a MISSING file, and
  once by hand an hour later, on `codex doctor` (which exits non-zero on its auth check) piped into
  grep. Capture into a variable first, then assert on the variable. Assert that the file exists
  before spending a model call on what it contains.
- [2026-09-07] **Never pipe a probe script through `head`.** Run 1 of the role-discovery probe was
  piped `| tee results.txt | head -120`; head closed the pipe at line 120, tee took SIGPIPE, and the
  script died two arms early — with a zero-ish exit and a results file that looked merely short. Same
  SIGPIPE family as the guard-hook fail-open, self-inflicted this time. Redirect to a file and read the
  file. Doubly so when each arm is a real model call: a truncated run costs the tokens and keeps none
  of the answer.
- [2026-09-07] A bare `harness/codex-setup.sh` inside a worktree dies with "lean-agent-harness engine
  not found" — nothing auto-sets `HARNESS_ENGINE`, so the wrapper falls through to the
  `~/.claude/plugins` cache, which on this machine is **0.2.9 (2026-08-12)** and predates codex-setup
  entirely. Export `HARNESS_ENGINE=<worktree>/plugin/engine` first, as the suites do. The E2-flip note
  called this out for `loop.ps1`; it applies to every wrapper.
