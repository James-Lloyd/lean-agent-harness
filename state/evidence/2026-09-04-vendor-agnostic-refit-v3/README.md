# Evidence — vendor-agnostic refit V3: generated, gitignored Codex surfaces (2026-09-04)

Branch `worktree-feat+vendor-refit-v3-codex-setup` (stacked on V2, PR #12), plugin 0.3.3,
design-doc `docs/design-docs/002-vendor-agnostic-routing.md` D3.

## User-visible behaviour: one command gives Codex the harness's hooks, agents and skills

Real run of both twins against THIS worktree (the harness dev repo, single-vendor config, so the
agents inherit no codex model and float on the CLI default):

```
$ bash plugin/engine/codex-setup.sh --project-root <worktree>
codex-setup: wrote <worktree>/.codex (config.toml, hooks.json, 7 agents) for plugin 0.3.3
NOTE: under headless 'codex exec' the repo's .codex/hooks.json is skipped until the repo is trusted (or --user / --dangerously-bypass-hook-trust) - docs/codex-setup.md

$ powershell plugin/engine/codex-setup.ps1 -ProjectRoot <worktree> -Check
codex-setup: fresh (plugin 0.3.3)          # PS validates the bash-generated set: digest parity
$ powershell plugin/engine/codex-setup.ps1 -ProjectRoot <worktree>
codex-setup: wrote <worktree>\.codex (config.toml, hooks.json, 7 agents) for plugin 0.3.3
$ bash plugin/engine/codex-setup.sh --project-root <worktree> --check
codex-setup: fresh (plugin 0.3.3)          # bash validates the PS-generated set: parity both ways
$ HARNESS_ENGINE=<worktree>/plugin/engine bash harness/codex-setup.sh --check
codex-setup: fresh (plugin 0.3.3)          # the harness/ wrapper dispatches to the engine
```

Generated `config.toml` (paths are native `C:/…`, produced by `cygpath -m` under Git Bash — an earlier
draft emitted MSYS `/c/…` which Codex, a native binary, cannot resolve):

```toml
[features]
hooks = true

[[skills.config]]
path = "C:/Users/<u>/Repos/harness/.claude/worktrees/feat+vendor-refit-v3-codex-setup/plugin/skills"

[agents]
enabled = true
```

Generated `hooks.json`: `PreToolUse` → `block-destructive` under the shell-tool matcher
(`shell|exec_command|local_shell|command_execution`, a best guess recorded as `_shell_matcher_note`) and
`protect-specs` under `*`; `PostToolUse` → `format-and-check`; `SessionStart` → `session-start`; every command is
`node "<plugin>/hooks/run.mjs" <hook>`. No `ConfigChange` (no Codex event). `agents/reviewer.toml`:
`sandbox_mode = "read-only"`, `developer_instructions = '''…'''` = the agent body with frontmatter
stripped; `generator.toml`: `sandbox_mode = "workspace-write"`.

`.gitignore` gained exactly one `.codex/` line (idempotent on re-run).

## Which hooks may run under matcher `*` — proven with a DENYLISTED payload, not a benign one

The first draft put all four hooks under `*` on the strength of benign probes (`{"tool_input":{"cmd":"ls"}}`
→ rc 0). The fresh-context reviewer rejected that: `block-destructive` deliberately scans the **whole
payload** when `tool_input.command` is absent ("fail toward scanning"), so a Codex *edit* whose patch
text merely mentions a denylisted command would be denied. Reproduced with a destructive literal:

```
$ printf '{"tool_name":"apply_patch","tool_input":{"patch":"+ echo do not run rm -rf / here"}}' \
    | bash plugin/hooks/block-destructive.sh ; echo rc=$?
BLOCKED by harness guardrail: recursive force-delete.  -> rc=2   (false denial of an EDIT under *)
$ printf '<same payload>' | bash plugin/hooks/protect-specs.sh ; echo rc=$?     -> rc=0   (safe under *)
$ printf '{}' | node plugin/hooks/run.mjs format-and-check ; echo rc=$?          -> rc=0   (safe under *)
```

Design after the fix: `protect-specs`, `format-and-check`, `session-start` under `*`; `block-destructive`
only under `--shell-matcher` (default `shell|exec_command|local_shell|command_execution`, a best guess
at Codex's shell tool names, recorded in the file as `_shell_matcher_note`). A wrong name means that hook
never fires — fail-open for shell commands under Codex, never a false denial — and V5 pins the real
name. Both suites now assert the scoping and carry the destructive-literal probe (rc 2 / rc 0); the
lesson is a ratchet line in `AGENTS.md`.

## Gate on the final tree

| Suite | Result |
|---|---|
| bash `harness/tests/run-tests.sh` | 282 passed, 0 failed (256 + 24 codex-setup + 2 parse) |
| PS 5.1 `harness/tests/run-tests.ps1` | 292 passed, 0 failed (266 + 24 + 2) |
| bash `fleet-queue-test.sh` | 31 passed, 0 failed |
| PS 5.1 `fleet-queue-test.ps1` | 31 passed, 0 failed |
| pwsh | not installed on this box — CI job `harness-selftest` covers it |

New assertions (24 per twin): generate exits 0; config.toml hooks on + skills path + agents defaults +
native path; hooks.json four commands through run.mjs, `block-destructive` under the shell-tool matcher
and NOT `*`, the other three under `*`, `--shell-matcher` pins it, no ConfigChange, JSON arrays intact (PS);
the destructive-literal probe (block-destructive rc 2 / protect-specs rc 0); one TOML per plugin agent;
reviewer per-phase model/effort + read-only; generator workspace-write + global model; body as TOML literal
with frontmatter stripped; `.gitignore` exactly once, idempotent, and CRLF-safe; `--check` fresh → 0,
STALE → 1 after an input edit, NOT generated → 1 when absent; `--user` writes into `HARNESS_CODEX_HOME`
and refuses to overwrite a non-harness hooks.json; cross-twin `--check` (each suite validates the other
twin's output). The suites' parse nets picked up the two new engine scripts and the two new wrappers.

## Fresh-context review

Reviewer agent on `claude-fable-5-1`: first pass **REJECT** on the matcher-`*` blocker above (plus quoting,
CRLF, wrapper-count, parity-test and wording should-fixes, all applied); second pass **SHIP** with two
should-fixes (stale draft facts in state/evidence, an unlisted assumption about unknown top-level keys in
hooks.json), both applied in the same commit.
