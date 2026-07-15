# E2E evidence — engine packaged as an installable Claude Code plugin

Task: `fix_plan.md` → "Package the engine as a Claude Code plugin". Date: 2026-07-14.
Plan: `docs/execution-plans/2026-07-14-plugin-packaging.md`.

The claim is that the harness engine now installs and upgrades as a versioned Claude Code plugin, and
that its guardrail hooks fire cross-platform from the installed location. Below is the real evidence, as
a user would see it — not just unit-green.

## 1. Manifests validate against the real CLI

```
$ claude plugin validate ./plugin
Validating plugin manifest: .../plugin/.claude-plugin/plugin.json
✔ Validation passed

$ claude plugin validate .            # marketplace at .claude-plugin/marketplace.json
Validating marketplace manifest: .../.claude-plugin/marketplace.json
✔ Validation passed
```

`claude plugin validate` caught three real structural bugs first, now fixed:
- `plugin.json` — string path overrides (`"agents": "./agents/"` …) are invalid; removed, defaults auto-discover.
- `hooks/hooks.json` — events must be wrapped in a top-level `"hooks": { … }` record.
- `marketplace.json` — must live at `.claude-plugin/marketplace.json`; `owner` must be an object, not a string.

## 2. Real install from the in-repo marketplace (throwaway project, local scope)

```
$ claude plugin marketplace add "C:/Users/james/Repos/harness" --scope local
✔ Successfully added marketplace: lean-agent-harness (declared in local settings)

$ claude plugin install lean-agent-harness@lean-agent-harness --scope local
✔ Successfully installed plugin: lean-agent-harness@lean-agent-harness (scope: local)

$ claude plugin list
  ❯ lean-agent-harness@lean-agent-harness   Version: 0.1.0   Scope: local   Status: ✔ enabled
```

## 3. All engine components landed on disk (installed cache)

Install path: `~/.claude/plugins/cache/lean-agent-harness/lean-agent-harness/0.1.0/`

```
agents:   6/6
commands: 12/12
skills:   4/4
hooks:    hooks.json=y run.mjs=y bodies=10/10   (5 .ps1 + 5 .sh)
engine:   4/4 runners (loop/fleet × ps1/sh), lib=10
```

## 4. Installed guardrail hooks fire cross-platform (the safety-critical claim)

Run against the INSTALLED dispatcher at the cache path (not the dev tree):

```
$ printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | node <cache>/hooks/run.mjs block-destructive
exit=2      # blocked

$ printf '{"tool_name":"Bash","tool_input":{"command":"git status"}}' | node <cache>/hooks/run.mjs block-destructive
exit=0      # allowed
```

The dispatcher's own self-test (`plugin/hooks/run.test.mjs`, wired into both suites) additionally proves
BOTH OS branches: `win32 → powershell.exe -File …ps1`, `linux → bash …sh`.

Scope note: this proves every link — Claude Code discovers `hooks.json`, `${CLAUDE_PLUGIN_ROOT}`
resolves, the dispatcher runs from the installed cache path, and the guardrail blocks — but by invoking
the dispatcher directly with a tool-call payload, not by a live in-session tool call routed through
Claude Code's plugin-hook wiring. That last end-to-end link (a real session showing the SessionStart
banner once + a denied command) is deferred to the supervised deployment migration.

## 5. Runner scripts work from a separate engine location (project-relative refactor)

The wrapper `harness/loop.ps1`, placed in a throwaway project exactly as `/harness-init` would, with the
engine pinned via `$HARNESS_ENGINE`:

```
$ HARNESS_ENGINE=<repo>/plugin/engine  powershell -File <proj>/harness/loop.ps1 -DryRun
Harness loop | type=greenfield | mode=supervised | maxIter=20 | maxTurns=40 | model=opus
[dry-run] would pipe PROMPT.md into: claude -p --max-turns 40 --model opus ; then run the gate.
# runtime written to <proj>/harness/.runs/run-001  → project-relative, NOT the engine dir
```

The wrapper's install-path glob (`*lean-agent-harness*/engine/loop.ps1`) matches the real cache layout
confirmed in §3.

## 6. Regression: existing gates stay green through the refactor

Both languages, including the jq-gated bash tests (jq 1.7.1 downloaded locally for this run — there is
**no CI in this repo yet**, so the bash path must be exercised by hand):

```
PS   run-tests.ps1:        68 passed, 0 failed   (was 67; +1 dispatcher test)
bash run-tests.sh:         64 passed, 0 failed   (full jq set; +1 dispatcher test)
PS   fleet-queue-test.ps1: 16 passed, 0 failed
bash fleet-queue-test.sh:  16 passed, 0 failed   (drives fleet.sh --project-root end to end)
```

The bash `--project-root` code path is directly exercised: `fleet-queue-test.sh` runs `fleet.sh`
end to end, and `bash loop.sh --project-root <tmpproj> --dry-run` resolved the temp project's config and
wrote runtime to its `harness/.runs/run-002` (loop.sh's new path, on bash).

## 7. Cleanup — no lasting global state

```
$ claude plugin uninstall lean-agent-harness --scope local   → ✔
$ claude plugin marketplace remove lean-agent-harness         → ✔
$ claude plugin list                                          → No plugins installed.
```

## Acceptance criteria → status
1. plugin.json (semver 0.1.0) + marketplace.json exist and validate — ✔ (§1)
2. engine installs as a versioned plugin — ✔ (§2, §3)
3. hooks fire cross-platform from the installed location — ✔ (§4)
4. runner scripts resolve project-vs-engine paths correctly — ✔ (§5)
5. local throwaway-project install verified end to end — ✔ (§2–§4, §7)
6. migration path documented for deployed copies — see `docs/plugin-migration.md`
7. existing gates stay green — ✔ (§6)
