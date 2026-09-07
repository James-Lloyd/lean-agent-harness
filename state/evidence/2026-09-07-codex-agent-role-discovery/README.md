# Codex `.codex/agents/*.toml` — auto-discovered? (CLI 0.153.4, 2026-09-07)

Closes half of the `fix_plan` item "Codex hooks follow-up": *"one transcript shows a generated agent
role in use"*. The other half (a `--user` install of the generated `~/.codex/hooks.json`) is **not**
done — see "Still open" below, which also records the cheaper way to do it.

## Verdict

**`.codex/agents/*.toml` is a discovered directory, not a manifest.** A role file needs no entry in
`config.toml`. The harness generator emits seven role files and no `[agents]` block, and a real
`codex exec` session named all seven as roles it can spawn. **The generator needs no change.**

## What was measured

Environment: `codex-cli 0.153.4`, project = a worktree under `c:\users\<you>\repos\<repo>`, which is
trusted by prefix through the existing `[projects.…]` entry (arm 0 asserts this; without trust Codex
skips the whole `.codex/` layer and every arm would read as "not discovered" for the wrong reason).
Nothing was written to `~/.codex`. Every arm is one real model call.

| Arm | Setup | Result | What it settles |
|---|---|---|---|
| A | Role **declared** in `config.toml`, `config_file` → a missing file | `warning: Ignoring malformed agent role definition: agents.probeA.config_file must point to an existing file at …` | Positive control: the project config layer **is** read, and the loader has a voice |
| B | **Malformed** role file in `.codex/agents/`, declared **nowhere** | `warning: Ignoring malformed agent role definition: agent role file at …\probeB.toml must define \`developer_instructions\`` | **The finding.** The loader read a file it was never pointed at ⇒ the directory is auto-discovered |
| C | The **same** malformed file, now declared via `config_file` | *no warning at all* | Content is validated on the discovery path, not the declaration path |
| D | Well-formed role, declared | Session listed `probeD` | Roles reach the model — but D was both well-formed *and* declared, so it does not isolate discovery |
| E | Well-formed role, **undeclared** (the shape codex-setup emits) | Session listed `probeE`, `default`, `explorer`, `worker` | Discovery alone makes a role **visible and spawnable** |
| F | The **real** generated set (`harness/codex-setup.sh`, plugin 0.3.9) | Session listed `doc-gardener`, `evaluator`, `explorer`, `generator`, `planner`, `reviewer`, `risk-classifier`, `default`, `worker` | The clause the fix_plan item asks for |

Raw output: `probes/results-raw.txt` (arms 0/A–D), `probes/results-visible.txt` (E, and F's first
failed attempt), `probes/results-visible-real.txt` (F). Probes are re-runnable but each one is a real
`codex exec` call — do not loop them.

## Method note — why a *malformed* file

A well-formed role that is silently ignored and one that loaded look identical from outside. The
oracle has to be a file the loader will complain about, so its own error names the path it read. Arms
A and C are the controls that prove the oracle fires in this environment; without them arm B's
warning could be read as noise and arm E's success as the model confabulating a plausible name.

## Three things worth keeping

1. **`codex doctor` cannot see this.** The same broken role produced the warning under `codex exec`
   and *nothing* under `codex doctor`, whose Notes said only `config loaded`. Second time doctor has
   failed to answer "is my `.codex/` doing anything" — the first was 2026-09-06.
2. **A malformed role is a warning, not a fatal.** The session ran to completion and answered
   normally. Unlike the V3 `config.toml` defects (which killed the whole project layer), a bad role
   file degrades silently: the role is simply absent, and only the warning line says so.
3. **`[agents.<name>]` in `config.toml` is a separate, weaker mechanism.** `AgentRoleToml` takes
   `description`, `config_file`, `nickname_candidates`. A missing `config_file` warns; a *malformed*
   declared file does not (arm C). The harness does not use declarations and, on this evidence,
   should not start.

## Two self-inflicted process failures in this run

Recorded because both are cheaper to read than to repeat, and both are in `AGENT_NOTES.md`:

- **Run 1 died to SIGPIPE.** The script was piped `| tee results.txt | head -120`; head closed the
  pipe, tee took the signal, and the script stopped two arms early with a results file that just
  looked short. Same family as the guard-hook fail-open this repo ratcheted twice — self-inflicted
  this time, and it wasted the model calls it had already paid for.
- **Arm F's first attempt never reached Codex.** `harness/codex-setup.sh` exited with
  `lean-agent-harness engine not found`: nothing auto-sets `HARNESS_ENGINE` for a bare wrapper call,
  so it fell through to the `~/.claude/plugins` cache — **0.2.9, from 2026-08-12**, which predates
  codex-setup entirely. Re-run with `HARNESS_ENGINE=<worktree>/plugin/engine`
  (`probes/role-visible-real.sh`).

## Path scrubbing

The transcripts are full of machine-local home paths, which this public repo's pre-commit guard
blocks. `probes/scrub-paths.sh` normalizes them to `<you>`/`<repo>`; `probes/scrub-proof.sh` asserts
it actually substitutes. That proof exists because the scrubber was rewritten mid-run — the first
version carried the home path as a literal, which made the scrubber itself unstageable — and by then
the files were already clean, so the rewrite printed `scrubbed` three times having changed nothing.
The proof planted a dirty fixture and immediately found a real defect: the rewrite derived the repo
name from `git rev-parse`, so a copy running in a temp dir died with `fatal: not a git repository`.
It now derives from the script's own path, with env overrides for the proof. A tool that silently
does nothing looks exactly like a tool that works.

## Still open — the `--user` hooks half

Not done here: whether a `--user` install of the generated `~/.codex/hooks.json`, with its
`_generated_by` and `_shell_matcher_note` top-level keys, fires `hook: SessionStart`.

It does **not** need the machine-wide write that has blocked it twice. `CODEX_HOME` redirects the
entire user-level layer. Measured with `CODEX_HOME` pointed at an empty directory: `codex doctor`
reported every user-level path (config, log dir, all five SQLite DBs) under the new home, and the only
failure was `✗ auth  no Codex credentials were found`. So the probe is: a throwaway home + the
generated `hooks.json` + credentials, then one `codex exec`, with the real `~/.codex` untouched.

Two constraints for whoever runs it. The throwaway home needs credentials — a copied `auth.json`, or
an API key through a supported auth env var; **copying a live token into a scratch directory is the
operator's call, not the agent's**, which is why this run stopped here. And the home must not sit
under the system temp dir, which draws `Refusing to create helper binaries under temporary dir`.
