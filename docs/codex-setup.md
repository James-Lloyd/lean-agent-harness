# Running the harness under OpenAI Codex CLI — `codex-setup`

**Read this first — verified live against Codex CLI 0.144.3 (slice V5, 2026-09-05,
`state/evidence/2026-09-05-vendor-agnostic-refit-v5/`).**

**Five of those claims were re-measured against 0.153.4** (2026-09-06,
`state/evidence/2026-09-06-codex-0153-reverify/`): four hold, and the `[agents]` fatality **changed**.
The generator needed no code change. **Not re-run on 0.153.4** — so still carrying V5's evidence
only: the user-level hook path and its `--dangerously-bypass-hook-trust` requirement, `--user`'s
tolerance of the `_generated_by` / `_shell_matcher_note` keys, and the `--check` digest. Nothing was
written to `~/.codex` in the re-verification, so the user-level path could not have been exercised.
**Agent-TOML discovery left that list on 2026-09-07** — measured on 0.153.4, see "Agent roles" below. Which claim rests on which version is spelled out in the 0.153.4 section below.

> **Trust is the precondition for everything project-level.** An **untrusted** project skips its whole
> `.codex/` layer with no diagnostic of any kind — verified against a full unfiltered transcript, not
> a grep. Trust means a persisted `[projects.'<lowercase windows path>'] trust_level = "trusted"` in
> `~/.codex/config.toml`; it is **prefix-based** (a worktree inherits its repo's entry), and an inline
> `-c projects.'…'.trust_level="trusted"` does **not** work.
>
> `codex doctor` will not tell you which state you are in: with a *valid* project config its
> Configuration section is byte-identical trusted or untrusted, naming only `~/.codex/config.toml`.
> It does fail loudly on a *broken* project config (`✗ config could not be loaded`) but never names
> the offending file — `codex exec` does. So if the generated `.codex/` appears to do nothing, check
> trust before suspecting the file.

- Under headless `codex exec` the repository's `.codex/hooks.json` is **never loaded** — not with
  `[projects.'<path>'] trust_level = "trusted"`, not with `--dangerously-bypass-hook-trust`, not both
  (three file shapes tried, zero events). Only the user-level `~/.codex/hooks.json` (what `--user`
  writes) and inline `-c hooks.<Event>=[…]` overrides fire. For a headless run, install with `--user`;
  the project file is for interactive sessions, where `/hooks` reviews and trusts it.
- Even user-level hooks run headlessly only with `--dangerously-bypass-hook-trust` (per invocation)
  or after an interactive `/hooks` review has persisted trust for the hook's hash. Otherwise Codex skips
  them silently. The engine's codex arm (`lib/invoke-codex.*`) does NOT pass the bypass flag.
- **Codex does not treat exit code 2 as a denial.** A hook that exits 2 with a stderr reason is logged
  `hook: PreToolUse Failed` and the tool call **proceeds** (fail-open — observed with a real `rm -rf`).
  Only the JSON decision on stdout, exit 0, blocks:
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"…"}}`
  (transcript: `hook: PreToolUse Blocked`, model sees `Command blocked by PreToolUse hook: …`).
  `run.mjs --codex <hook>` performs that translation and the generator emits every hook command with it.
- A headless run without hooks is guarded only by Codex's own sandbox (`--sandbox read-only|workspace-write`),
  the harness gate, and `autoRollbackOnRed` — exactly what the codex arm relied on before V3. Decide
  which you are running before you rely on a hook.

## What it generates (design-doc 002, D3)

`harness/codex-setup.{ps1,sh}` (a thin wrapper over the plugin engine's `codex-setup.*`) writes a
**machine-local, gitignored** `.codex/` into the project:

| File | Content | Why generated, not committed |
|---|---|---|
| `.codex/config.toml` | `[features] hooks = true`; `[[skills.config]] path = <plugin>/skills` + `enabled = true` so Codex reads the harness skills (Agent Skills standard). **No `[agents]` block**: verified live on Codex 0.144.3 (slice V5), `[agents]` is a table of agent *roles* there, so the `enabled`/`default_subagent_*` keys V3 emitted were rejected as a malformed role — and any config-load error kills the *whole* `.codex/` layer silently (the run continues on `~/.codex/config.toml` alone). **0.153.4 accepts `[agents] enabled = true`** (re-verified 2026-09-06; `default_subagent_*` was **not** re-sent, and per `AGENT_NOTES.md` that field did not exist in the 0.144.3 binary at all), so omitting the block is now a compatibility choice rather than a necessity: one artifact stays valid on both. Per-agent model/effort lives in `agents/<name>.toml` | the plugin lives in the per-machine cache (`~/.claude/plugins/…`), so the path is absolute and local — a committed absolute path dies on the next device (ratchet 2026-07-30) |
| `.codex/hooks.json` | four of the five harness guard hooks routed through the same `run.mjs` dispatcher and hook bodies Claude Code uses: `protect-specs`, `format-and-check`, `session-start` under matcher `*`; `block-destructive` under the **shell-tool matcher** only (`--shell-matcher`, see below). `lock-config` has no Codex event (`ConfigChange`) | same absolute-path reason |
| `.codex/agents/<name>.toml` | one Codex custom agent per plugin agent: `model`/`model_reasoning_effort` from that phase's **effective** codex settings (`models.<phase>.codex{}` over `models.codex`), `sandbox_mode = "read-only"` for the judges (reviewer, evaluator, risk-classifier, explorer) and `"workspace-write"` for the writers, `developer_instructions` = the agent's body | the body is plugin content: regenerate on `/plugin update` rather than fork it |
| `.codex/.harness-stamp.json` | plugin version + a sha256 of every input (config, hook manifest, agent files, plugin root) | lets `--check` say **fresh / STALE / NOT generated** deterministically; `/harness-doctor` check 12 runs it |

It also appends `.codex/` to the project's `.gitignore` if missing.

## Commands

```
bash harness/codex-setup.sh              # generate / regenerate
bash harness/codex-setup.sh --check      # exit 0 fresh, 1 stale or missing (doctor check 12)
bash harness/codex-setup.sh --user       # also install hooks to ~/.codex/hooks.json (the ONLY file headless exec loads; MACHINE-WIDE)
bash harness/codex-setup.sh --shell-matcher 'Bash'    # override block-destructive's tool matcher (default Bash, recorded live in V5)
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

## What V5 verified live (Codex CLI 0.144.3, 2026-09-05) — and what is still assumed

- **Tool name and payload — VERIFIED.** A recorded PreToolUse payload: `{"session_id","turn_id",
  "transcript_path","cwd","hook_event_name":"PreToolUse","model","permission_mode","tool_name":"Bash",
  "tool_input":{"command":"…"},"tool_use_id":"exec-…"}` — Codex mirrors Claude Code's hook contract, so
  shell commands arrive as **`Bash`** (the docs also name `Edit`/`Write` for `apply_patch` edits) and
  `block-destructive`'s `.tool_input.command` read is correct. `--shell-matcher` therefore defaults to
  `Bash`. Why it is still not under `*`: when `tool_input.command` is absent the hook deliberately **scans
  the whole payload** ("fail toward scanning"), so under `*` a Codex *edit* whose patch text merely
  mentions `rm -rf`, `DROP TABLE` or `.env` would be denied with a misleading "BLOCKED" — proven with a
  destructive-literal probe (rc=2), which a benign probe never reaches.
- **Denial mechanism — VERIFIED (and it was wrong before V5).** Exit code 2 does not block under Codex
  (see the first section); the JSON `permissionDecision: "deny"` output does. `run.mjs --codex` translates.
- **Project-level `.codex/hooks.json` under headless `exec` — VERIFIED not loaded** (first section).
  `--user` is the headless path; the harness's own codex arm never passes the bypass flag, so a loop run
  under Codex relies on `--sandbox` + gate + rollback unless the user-level hooks have been trusted once
  interactively.
- **`config.toml` schema — VERIFIED, two V3 keys were fatal.** *(The `[agents]` half of this bullet
  **changed on 0.153.4** — see the re-verification section below; the `[[skills.config]]` half still
  holds.)* `[[skills.config]]` requires `enabled`
  (missing ⇒ `Error loading config.toml: missing field 'enabled'`), and `[agents]` is a table of agent
  roles (`enabled = true` / `default_subagent_*` ⇒ `expected struct AgentRoleToml`). Either error kills the
  entire project `.codex/` layer silently — the run continues on `~/.codex/config.toml` alone, which is
  why the V3 tests (which never loaded the file in Codex) stayed green. Newer Codex docs list
  `agents.enabled`/`agents.default_subagent_*`; 0.144.3 does not accept them, so the generator emits only
  what the oldest supported CLI loads. **Any generated config for a foreign tool must be load-tested
  against the installed tool before its tests are believed** — `codex exec` with a one-line prompt does it.
- **Digest across twins.** The `--check` stamp hashes raw inputs plus the plugin root path as each twin
  spells it (bash: logical `pwd` through `cygpath -m`; PS: `$PSScriptRoot`). A symlinked plugin cache or
  a differently-cased path can make one twin report STALE for the other's output — never a false
  *fresh*. Regenerate with the twin you run `--check` with.
- **Unknown top-level keys in `hooks.json` — still unverified for the generated file.** Codex's docs show a
  top-level `description` key beside `hooks`, so extra keys are probably tolerated, but the `--user` probe
  with the real generated file (which carries `_generated_by` and `_shell_matcher_note`) was not run in V5
  (a machine-wide write the session's permission classifier refused). If a `--user` install produces no
  `hook: SessionStart` line in a transcript, suspect these keys first.
  **This does not actually need a machine-wide write** — `CODEX_HOME` redirects the whole user-level
  layer, so a throwaway home holding the generated `hooks.json` exercises the same code path and leaves
  the real `~/.codex` untouched. Measured 2026-09-07 with `CODEX_HOME` set to an empty directory
  (`probes/results-round2.txt`, arm G2): `codex doctor` reported every user-level path under the new
  home — config, log dir, `auth.json`, and six SQLite databases — and the only failure was
  `✗ auth  no Codex credentials were found — Run codex login or provide an API key through a supported
  auth env var`. Two consequences for whoever runs it. The throwaway home needs credentials, so either
  a copied `auth.json` or that API key env var — **copying a live token into a scratch directory is the
  operator's call, not the agent's**. And it must not sit under the system temp dir: with the home under
  `%TEMP%`, Codex emits `Refusing to create helper binaries under temporary dir` and proceeds without
  PATH aliases (`probes/results-round3.txt`, arm H2). This is why the item is still open rather than blocked.
- **No `ConfigChange` event** in Codex; the harness's `lock-config` hook has no Codex twin. The loop's
  config hash pin still catches a mid-run config edit after the fact.
- **`.codex/agents/*.toml` — VERIFIED auto-discovered and visible** (0.153.4, 2026-09-07; see
  "Agent roles" below). The generated files need no `[agents]` declaration: dropping them in the
  directory is enough, and a real session names all seven of them as roles it can spawn.

## Re-verified on Codex CLI 0.153.4 (2026-09-06)

Full record: `state/evidence/2026-09-06-codex-0153-reverify/` (raw output in `results.txt`,
re-runnable probes in `probes/`). Nothing was written to `~/.codex`; trust came from the existing
`[projects.'c:\users\<you>\repos\<repo>']` entry and hooks were supplied inline with `-c`.

| V5 finding | 0.153.4 |
|---|---|
| `[[skills.config]]` requires `enabled` | **holds** — still `Error loading config.toml: missing field 'enabled'` |
| `[agents] enabled = true` is fatal | **changed — now accepted** |
| project `.codex/hooks.json` never loads headless | **holds** — 0 hook events, trusted *and* with `--dangerously-bypass-hook-trust` |
| exit 2 is not a denial; JSON `permissionDecision:"deny"` is | **holds** — exit 2 logged `Failed` and the command **ran**; JSON deny logged `Blocked` |
| `tool_name` is `Bash`, payload shape as recorded | **holds** — identical keys, still `Bash` (even though Codex executes via `powershell.exe` on Windows) |

**The generator needs no change for 0.153.4.** The `[agents]` omission is now a *compatibility*
choice rather than a necessity: 0.144.3 rejects the block, 0.153.4 accepts it, so emitting nothing
keeps one artifact valid on both. Per-agent model/effort continues to live in `agents/<name>.toml`.

**New on 0.153.4 — Codex has its own command policy.** `Remove-Item -Recurse -Force …` is refused
before execution (`CreateProcess … rejected: blocked by policy`), where 0.144.3 let a real recursive
delete run with our hook merely logging `Failed`. Do not mistake this for the harness guard: the
exit-2 fail-open is unchanged and still ours to translate. Note too that on Windows Codex runs shell
commands through `powershell.exe`, so a Unix-form `rm -rf` fails on syntax rather than being blocked —
a probe using it looks like a successful denial and proves nothing.

## Agent roles — verified on 0.153.4 (2026-09-07)

Full record: `state/evidence/2026-09-07-codex-agent-role-discovery/`. Nothing was written to
`~/.codex`; trust came from the existing `[projects.'c:\users\<you>\repos\<repo>']` entry, which is
prefix-based and so covers a worktree under it.

**`.codex/agents/*.toml` is a discovered directory, not a manifest.** A role file needs no entry in
`config.toml`: the generator emits seven files and no `[agents]` block, and a real `codex exec`
session listed all seven — `doc-gardener`, `evaluator`, `explorer`, `generator`, `planner`,
`reviewer`, `risk-classifier`. The generated shape is therefore correct as it stands and needs no
change.

**And a discovered role really runs.** A role file whose `developer_instructions` carry a token that
exists nowhere else on disk was spawned by name from a plain `codex exec` session, and the token came
back verbatim (`probes/results-round3.txt`). A returned name only proves the model can say a name.

**And the delivery mechanism is the loader, not a file read.** The first spawn arm did not forbid
file reads, so a parent that simply opened the role file would have produced the same transcript. The
control (`probes/results-round4b.txt`) separates them: with reads forbidden, the role in
`.codex/agents/` returns its token, and the **same file moved one directory over** to
`.codex/agents-off/` — still on disk, still readable — returns `NO-SUCH-ROLE`. Discovery is what
delivers the role.

*Do not read the surrounding names as a built-in role list.* Asked to enumerate its roles with no
project `.codex/` at all, the model answered `general-purpose` twice; in other arms it volunteered
`default`, `explorer` and `worker` with no such files present. The enumeration is partly
confabulated, so the load-bearing evidence is the loader's own warning and the spawn token, not the
list.

The oracle was a **deliberately malformed** role file, because a well-formed one that is silently
ignored looks exactly like one that loaded. A file carrying `name` and `description` but no
`developer_instructions`, sitting in `.codex/agents/` with nothing referring to it, produced:

```
warning: Ignoring malformed agent role definition: agent role file at
  ...\.codex\agents\probeB.toml must define `developer_instructions`
```

That is the loader reading a file it was never pointed at, which is the whole finding. Three things
about it are worth keeping:

- **`codex doctor` DOES report a broken role — and the first draft of this section said it did
  not.** Under the malformed-and-undeclared state, doctor carries the same text as a `startup
  warning` field deep in its Configuration section (line 121 of `probes/results-round2.txt`). The
  false claim came from reading only the first 30 lines of doctor's output — this repo's own ratchet
  that a filtered view cannot prove silence, reproduced a day after it was written. Doctor still
  does not raise it in the Notes summary at the top, so it is easy to miss, but it is not blind.
- **A malformed role is a warning, not a fatal.** The session ran to completion and answered
  normally. Unlike the V3 `config.toml` defects, a bad role file degrades silently — it does not take
  the `.codex/` layer down with it, and nothing but the warning line says the role is missing.
- **`[agents.<name>]` in `config.toml` is a separate, additive mechanism**, and a weaker one. It
  takes `description`, `config_file` and `nickname_candidates` — the three fields the installed
  binary's own deserializer names (`struct AgentRoleToml with 3 elements`, captured in
  `probes/results-round4.txt`); a `config_file` pointing at a missing
  path warns at load (`must point to an existing file at …`), but declaring the *malformed* file that
  way produced no warning at all — the content is validated on the discovery path, not the
  declaration path. The harness does not use declarations, and on this evidence should not start.

## What stays Claude-only

The harness's slash commands (`/work`, `/review`, …) are Claude Code commands. Under Codex you run the
headless loop (`harness/loop.*` with the phase routed to `codex`) or drive phases by hand with the
generated agents; a command-to-skill bridge is a later slice (design-doc 002, "Out of scope").
