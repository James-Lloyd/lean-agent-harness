# Phase model routing verification — 2026-09-29

## Generated Codex roles

Ran the real `plugin/engine/codex-setup.ps1 -ProjectRoot .` generator against this worktree. It exited 0 and reported plugin 0.5.4, seven agent TOMLs, and 21 generated skills. The Bash twin's `codex-setup.sh --project-root . --check` then reported `fresh` and exited 0. A read of the emitted role TOMLs, compared with `harness/harness.config.json`, produced:

| Role | Emitted model | Emitted effort | Config match |
|---|---|---|---|
| explorer | `gpt-6-luna` | `low` | yes |
| planner | `gpt-6-astra` | `high` | yes |
| generator | `gpt-6-sol` | `high` | yes |
| reviewer | `gpt-6-astra` | `high` | yes |
| evaluator | `gpt-6-astra` | `high` | yes |
| doc-gardener | `gpt-6-luna` | `low` | yes |

The actual `plugin/scripts/validate-openai-plugin.mjs` package validator exited 0: version 0.5.4, four hooks, 21 discoverable skills, and six dual-cache wrappers.

Codex CLI 0.159.0 completed a read-only `codex exec --strict-config` invocation in this worktree with exit 0. Two prompts requested an explorer subagent, but their JSON event streams contain no `spawn_agent` event. Their answers are therefore **not** evidence that Codex actually started the configured explorer role. The generated files and cross-twin freshness check are the evidence for this routing change; a direct role-spawn transcript remains unproven.

## Gates

`node harness/tests/gate.mjs` exited 0: PowerShell **451 passed, 0 failed**; Bash **444 passed, 0 failed**. The Bash gate used the same `jq` 1.8.2 executable copied to an allowed temporary directory because this sandbox denied execution from its WinGet install location. No harness source was changed for that environment issue.

The configured evaluator remains optional (`verification.evaluator.enabled: false`). It is a rubric judge after review, separate from the ambient Codex session model.

## Independent review

A fresh `codex exec review --uncommitted` process on `gpt-6-astra` at high effort returned: "No actionable regressions found." It independently reran the gate and observed PowerShell 451/0 and Bash 444/0. Its final note also called out the unverified direct role spawn above.
