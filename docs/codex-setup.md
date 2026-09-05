# Running the harness under OpenAI Codex CLI — `codex-setup`

**Read this first: under headless `codex exec`, Codex skips a repository's `.codex/hooks.json` until the
repository has been trusted, or you pass `--dangerously-bypass-hook-trust`.** The guard hooks the harness
generates into `.codex/` therefore protect an *interactive* Codex session in a trusted repo, and a
headless run only when you either trust the repo first or install the hooks user-wide with `--user`
(`~/.codex/hooks.json`). A headless run without either is guarded only by Codex's own sandbox
(`--sandbox read-only|workspace-write`), the harness gate, and `autoRollbackOnRed` — exactly what the
engine's codex arm relied on before this slice. Decide which you are running before you rely on a hook.

## What it generates (design-doc 002, D3)

`harness/codex-setup.{ps1,sh}` (a thin wrapper over the plugin engine's `codex-setup.*`) writes a
**machine-local, gitignored** `.codex/` into the project:

| File | Content | Why generated, not committed |
|---|---|---|
| `.codex/config.toml` | `[features] hooks = true`; `[[skills.config]] path = <plugin>/skills` so Codex reads the harness skills (Agent Skills standard); `[agents]` defaults from the global `models.codex` block | the plugin lives in the per-machine cache (`~/.claude/plugins/…`), so the path is absolute and local — a committed absolute path dies on the next device (ratchet 2026-07-30) |
| `.codex/hooks.json` | four of the five harness guard hooks routed through the same `run.mjs` dispatcher and hook bodies Claude Code uses: `protect-specs`, `format-and-check`, `session-start` under matcher `*`; `block-destructive` under the **shell-tool matcher** only (`--shell-matcher`, see below). `lock-config` has no Codex event (`ConfigChange`) | same absolute-path reason |
| `.codex/agents/<name>.toml` | one Codex custom agent per plugin agent: `model`/`model_reasoning_effort` from that phase's **effective** codex settings (`models.<phase>.codex{}` over `models.codex`), `sandbox_mode = "read-only"` for the judges (reviewer, evaluator, risk-classifier, explorer) and `"workspace-write"` for the writers, `developer_instructions` = the agent's body | the body is plugin content: regenerate on `/plugin update` rather than fork it |
| `.codex/.harness-stamp.json` | plugin version + a sha256 of every input (config, hook manifest, agent files, plugin root) | lets `--check` say **fresh / STALE / NOT generated** deterministically; `/harness-doctor` check 12 runs it |

It also appends `.codex/` to the project's `.gitignore` if missing.

## Commands

```
bash harness/codex-setup.sh              # generate / regenerate
bash harness/codex-setup.sh --check      # exit 0 fresh, 1 stale or missing (doctor check 12)
bash harness/codex-setup.sh --user       # also install hooks to ~/.codex/hooks.json (headless-safe; MACHINE-WIDE)
bash harness/codex-setup.sh --shell-matcher 'shell'   # pin block-destructive to Codex's real shell tool name
powershell harness/codex-setup.ps1 [-Check] [-User] [-ShellMatcher <regex>]
```

`--user` is **machine-wide**: `~/.codex/hooks.json` applies to every Codex project on the machine, not
just this one. If a `/harness-migrate`d consumer lacks the `harness/codex-setup.*` wrappers, run the
engine script directly: `${CLAUDE_PLUGIN_ROOT}/engine/codex-setup.sh --project-root <repo>`.

Either twin may generate and either may `--check`: the stamp digest is computed over raw bytes in
ordinal file order, so both runtimes agree. **Re-run after** `/plugin update lean-agent-harness`
(the plugin path and version change), after any `models` edit, and after editing a plugin agent.
`--user` refuses to overwrite a `~/.codex/hooks.json` the harness did not generate (no `_generated_by`
key) — merge by hand in that case.

## Assumptions to verify live (slice V5)

- **Tool names, and why `block-destructive` is not under `*`.** Codex's tool names are not Claude
  Code's (`Bash`, `Edit`, …). `protect-specs`, `format-and-check` and `session-start` run under
  `matcher: "*"` because their bodies **allow** (exit 0) a payload without a file path — verified with
  foreign payloads. `block-destructive` is different: when `tool_input.command` is absent it deliberately
  **scans the whole payload** ("fail toward scanning"), so under `*` a Codex *edit* whose patch text
  merely mentions `rm -rf`, `DROP TABLE` or `.env` would be denied with a misleading "BLOCKED" — proven
  with a destructive-literal probe (rc=2), which a benign probe never reaches. It is therefore emitted
  only under `--shell-matcher` (default `shell|exec_command|local_shell|command_execution`, a **best
  guess** at Codex's shell tool names). A wrong name means that one hook never fires — fail-open for
  destructive shell commands under Codex, never a false denial. Until V5 observes a real Codex denial
  and pins the name, treat `block-destructive` under Codex as *absent*, and rely on `--sandbox`.
- **Digest across twins.** The `--check` stamp hashes raw inputs plus the plugin root path as each twin
  spells it (bash: logical `pwd` through `cygpath -m`; PS: `$PSScriptRoot`). A symlinked plugin cache or
  a differently-cased path can make one twin report STALE for the other's output — never a false
  *fresh*. Regenerate with the twin you run `--check` with.
- **Unknown top-level keys in `hooks.json`.** The generated file carries `_generated_by` (which the `--user`
  refusal logic relies on) and `_shell_matcher_note` beside `hooks`. Whether Codex's parser tolerates
  unknown top-level keys is **unverified**; if it rejects the file, *all four* hooks are silently absent.
  V5 checks this first: confirm `session-start` visibly fires before judging any denial.
- **No `ConfigChange` event** in Codex; the harness's `lock-config` hook has no Codex twin. The loop's
  config hash pin still catches a mid-run config edit after the fact.
- **Agent TOML keys** (`developer_instructions`, `model_reasoning_effort`, `sandbox_mode`) follow the
  Codex subagent docs as read on 2026-09-04; a Codex release that renames them shows up as Codex
  ignoring the agent — re-check on upgrade.

## What stays Claude-only

The harness's slash commands (`/work`, `/review`, …) are Claude Code commands. Under Codex you run the
headless loop (`harness/loop.*` with the phase routed to `codex`) or drive phases by hand with the
generated agents; a command-to-skill bridge is a later slice (design-doc 002, "Out of scope").
