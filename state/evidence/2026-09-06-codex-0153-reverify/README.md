# Codex CLI 0.153.4 — re-verification of the V5 live-fire findings (2026-09-06)

The four facts the Codex integration is built on were all measured against **0.144.3** in slice V5
(2026-09-05). The installed CLI is now **0.153.4**. The engine's own rule — *"a generated config for a
foreign tool is load-tested against the INSTALLED tool version before its emitter's tests are
believed"* — makes those findings unverified until re-run, and V3 is the standing reminder of what
happens otherwise: text-green and live-dead for a whole slice.

Nothing was written to `~/.codex`. Trust came from the `[projects.'c:\users\<you>\repos\<repo>']`
entry already present (it is **prefix-based**, so the worktree inherits it); hooks were supplied
inline with `-c`. Raw output: `results.txt`. Re-runnable probes: `probes/`.

## Verdict: three hold, one changed, one new

| # | V5 finding (0.144.3) | 0.153.4 | Action |
|---|---|---|---|
| C1a | `[[skills.config]]` requires `enabled`; omitting it is fatal | **HOLDS** — `Error loading config.toml: missing field 'enabled'` | none; generator already emits it |
| C1b | `[agents] enabled = true` is fatal (`expected struct AgentRoleToml`) | **CHANGED — `enabled = true` now accepted, no error.** `default_subagent_*` was *not* re-sent, so nothing here says whether unknown keys in general are now tolerated | none needed; generator omits `[agents]`, which is valid on both. Doc must say *why* it is omitted is now compatibility, not necessity |
| C2 | project `.codex/hooks.json` never loads under headless `exec` | **HOLDS** — 0 hook lines, 0 side effects, trusted *and* `--dangerously-bypass-hook-trust` | none |
| C3 | exit 2 is not a denial; JSON `permissionDecision:"deny"` is | **HOLDS** — exit 2 → `Failed` and the command **ran**; JSON deny → `Blocked` | none; `run.mjs --codex` still correct |
| C4 | `tool_name` is `Bash`; payload shape as recorded | **HOLDS** — identical key set, still `Bash` | none; `--shell-matcher Bash` default stands |
| — | *(not in V5)* | **NEW: Codex ships its own command policy** | document it |

So the shipped generator needs **no code change** for 0.153.4. That is the useful answer, and it is
worth more than it sounds: it was not knowable without running this.

## The correction that matters most

My first pass concluded *"the project `.codex/config.toml` is not read at all on 0.153.4"* — invalid
TOML produced no error and a `model` override was ignored. That was **wrong**, and wrong in the
dangerous direction (it would have justified deleting a working feature). The project was simply
**untrusted**: `/tmp/cxproj` is not under any `[projects.…]` entry. Repeating it in the trusted
worktree produced a parse error immediately.

Two traps in that, both now recorded:

* **Inline `-c projects.'…'.trust_level="trusted"` does not confer trust.** Only a persisted entry in
  `~/.codex/config.toml` does. A control in the same invocation (`-c model="gpt-5-codex"`) *did* take
  effect, so `-c` was working — the trust key specifically is ignored. Without that control I would
  have read "no error" as "not read" a second time.
* **An untrusted project skips its whole `.codex/` layer with no diagnostic.** Asserted first from a
  `grep`-filtered probe, which *cannot prove absence* — a `warning:` line would never have reached the
  output. Re-run unfiltered after review (`results.txt` §5): the full transcript really does contain
  nothing about the project config, the trust state, or the parse failure. The claim survived; the
  method that produced it did not, and is now a ratchet.
* **`codex doctor` cannot tell you which state you are in — but it is not blind either.** With a
  *valid* project config its Configuration section is identical trusted or untrusted, naming only
  `~/.codex/config.toml` (`results.txt` §6). With a *broken* one it fails loudly — `✗ config could not
  be loaded` — but never names the offending file; `codex exec` does. The first draft of this document
  said flatly that doctor "cannot tell the two states apart", which overstated it, and had no recorded
  output behind it at all.

This is the same shape as the defect this batch's predecessor ratcheted: a negative result that is
really "the code never ran". Both probes now carry positive controls.

## Two destructive probes that could not discriminate

Worth recording because each *looked* like a passing guard:

1. `rm -rf <dir>` — on Windows Codex executes through `powershell.exe`, where `rm` is `Remove-Item`
   and `-rf` is not a parameter. The command fails on syntax; the sentinel survives; it reads exactly
   like a successful block.
2. `Remove-Item -Recurse -Force <dir>` — rejected by **Codex's own policy** before execution
   (`CreateProcess … rejected: blocked by policy`). Again the sentinel survives, again for a reason
   that has nothing to do with the harness hook.

C3 was therefore settled with a *harmless* command whose text matches the denylist
(`echo "DROP TABLE probe_marker_42"`), which isolates the denial mechanism from destructiveness and
lets the control actually run. **A guard test whose control cannot perform the action proves nothing.**

## A twin gap this turned up (pre-existing, not a 0.153.4 regression)

`block-destructive.ps1` carries four PowerShell-form patterns that `block-destructive.sh` does not:

```
Remove-Item … -(Recurse|Force)      (rd|rmdir) /s      del /[sq]      Format-Volume|Clear-Disk|Clear-Content
```

`run.mjs` dispatches `.ps1` on win32 and `.sh` elsewhere, so on Windows — where Codex actually issues
PowerShell — the guard is complete. On POSIX the `.sh` body is used, and an agent driving `pwsh`
(which the `.sh` spec-lock block already anticipates: *"the PowerShell tool can run on POSIX via
pwsh"*) could issue `Remove-Item -Recurse -Force` and match nothing in the always-on denylist. Filed
as a `fix_plan` item rather than fixed here — this branch is a verification pass, and widening it into
the most safety-critical file in the repo is exactly the mistake PR #16 avoided.

## What is still unverified

Unchanged from the V5 list, both belonging to the queued Codex-hooks follow-up:

* whether a `--user` install of the generated `~/.codex/hooks.json` (with its `_generated_by` /
  `_shell_matcher_note` top-level keys) fires — needs a machine-wide write;
* whether `.codex/agents/*.toml` are auto-discovered by a spawned Codex agent — `codex exec` does not
  spawn one, so this needs the `codex agents` path.
  **SETTLED 2026-09-07 → `state/evidence/2026-09-07-codex-agent-role-discovery/`. They are
  auto-discovered, and the method guess here was wrong: `codex agents --help` describes itself as
  "Browse all agent sessions on the shared local app-server daemon" (captured in that dir's
  `probes/results-round4.txt`), so it is not the path to running a role. A plain `codex exec` both
  surfaces the loader's warning and will spawn a discovered role on request.**
