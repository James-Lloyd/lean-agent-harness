# Evidence — headless `--effort` plumbing + Fable 5.1 routing pin (2026-09-04)

Branch `worktree-feat+fable-5-1-routing-effort`, commit c77e3b9 (+ this evidence commit). Plugin 0.3.0.

## User-visible behaviour: the headless loop now dispatches the declared effort

Both loop twins were dry-run from the worktree with `HARNESS_ENGINE` pointed at the edited engine
(not the installed plugin cache), against the shipped `harness/harness.config.json`
(`implement = { model: claude-opus-5, effort: high }`). Each printed the exact command line it
would pipe `PROMPT.md` into.

`bash harness/loop.sh --dry-run`:

```
[dry-run] would pipe PROMPT.md into: claude -p --max-turns 40 --model claude-opus-5 --effort high ; then run the gate.
```

`powershell harness/loop.ps1 -DryRun` (Windows PowerShell 5.1):

```
[dry-run] would pipe PROMPT.md into: claude -p --max-turns 40 --model claude-opus-5 --effort high ; then run the gate.
```

Before this change the same line ended at `--model claude-opus-5` — the headless phase ran at the
model's default depth regardless of what the config declared.

## Deterministic flag-assembly proof (stub `claude`, no real model)

`harness/tests/run-tests.sh` block "dispatch: invoke_phase fallback trigger", cases 7a–7g, and
`run-tests.ps1` cases 8a–8g. The stub logs `<model>=<effort>` per invocation:

| case | primary / fallback | effort / fallbackEffort | observed |
|---|---|---|---|
| 7a/8a | `e-ok` | `high` / – | `e-ok=high` |
| 7b/8b | `e-usage` (usage-limited) → `e-fb` | `high` / `medium` | `e-usage=high`, `e-fb=medium` |
| 7c/8c | `e-usage` → `e-fb2` | `xhigh` / – | `e-fb2=xhigh` (inherits) |
| 7d/8d | `e-none` | – / – | `e-none=(none)` (no flag) |
| 7e/8e | `e-min` | `minimal` / – | `e-min=(none)` (codex-only level omitted) |
| 7f/8f | `e-max` | `max` / – | `e-max=max` |
| 7g/8g | `claude_effort_legal` / `Test-ClaudeEffortLegal` | – | xhigh yes; minimal, empty, `High` no |

Resolver accessors (`phase_effort` etc.) have 6 assertions per twin in the "model routing" block.

## Gate on the final tree

| Suite | Result |
|---|---|
| bash `harness/tests/run-tests.sh` | 237 passed, 0 failed |
| PS 5.1 `harness/tests/run-tests.ps1` | 247 passed, 0 failed |
| bash `fleet-queue-test.sh` | 31 passed, 0 failed |
| PS 5.1 `fleet-queue-test.ps1` | 31 passed, 0 failed |
| pwsh | not installed on this box — CI job `harness-selftest` covers it |

## Routing pin — surfaces changed together

`harness/harness.config.json`, `.claude/settings.json`, `plugin/agents/{planner,reviewer,evaluator,risk-classifier}.md`,
`plugin/skills/model-routing/SKILL.md`, `plugin/commands/work.md`, `plugin/commands/harness-doctor.md`,
`plugin/engine/harness.schema.json`. Post-edit sweep (`grep` for `claude-fable-5` without `-1`,
`claude-opus-4-8`, "routes `--model` only", effort enums without `max`) returned nothing outside
`state/PROGRESS.md`, `state/fix_plan.md` history and `docs/execution-plans/`.

Fresh-context review: reviewer agent on `claude-fable-5-1`; verdict recorded in the evidence commit message.
