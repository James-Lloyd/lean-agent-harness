# Harness

A portable, tech-stack-agnostic engineering harness for AI coding agents (Claude Code first,
but the state lives in plain files so it survives a model/tool swap).

> **Agent = Model + Harness.** The model is fixed for a given session; the harness is everything
> else — the constraints, guides, feedback loops, tooling, and state that channel a powerful but
> unpredictable model toward reliable output. This repo *is* that harness. You clone it per project
> and run `/harness-init` once to make it yours.

This harness is a synthesis of current best practice from Anthropic, OpenAI, Martin Fowler
(Birgitta Böckeler), Geoffrey Huntley's "Ralph" loop, Addy Osmani, and an ex-Meta L8's agentic
workflow. See [`docs/principles/sources.md`](docs/principles/sources.md) for the bibliography and
which idea came from where.

---

## The model in one diagram

```
                 ┌─────────────────────  THE HARNESS  ─────────────────────┐
                 │                                                          │
   you ──intent──┤  GUIDES (feedforward)            SENSORS (feedback)      │
                 │  steer BEFORE acting             observe AFTER acting    │
                 │  • CLAUDE.md (map, not manual)   • format / lint         │
                 │  • specs/  (immutable truth)     • typecheck             │
                 │  • skills/ (progressive disc.)   • tests (unit + e2e)    │
                 │  • LSP / types / docs/           • fresh-context review  │
                 │  • stack profile                 • evaluator (optional)  │
                 │           │                              │               │
                 │           ▼                              ▼               │
                 │        ┌────────────────  LOOP  ────────────────┐        │
                 │        │ study → plan → ONE task → implement →   │        │
                 │        │ verify (the gate) → checkpoint/commit → │        │
                 │        │ rollback on red → record learning → ↻   │        │
                 │        └─────────────────────────────────────────┘       │
                 │                          │                               │
                 │              STATE (durable, file-based):                │
                 │   git · state/tasks.json · state/fix_plan.md ·           │
                 │   state/PROGRESS.md · state/handoff.md · AGENT_NOTES.md   │
                 └──────────────────────────────────────────────────────────┘
```

The loop is **stateless** (every iteration can start from a fresh context window); the **files are
stateful**. That is the whole trick to long-running work.

---

## Quickstart

```bash
# 1. Get the harness into your new project
git clone <this-repo> my-project          # or: degit / copy the folder
cd my-project
rm -rf .git && git init                    # make it yours

# 2. Run the one-time interview (in Claude Code)
/harness-init

# 3. Work
/plan          "build the thing"           # decompose intent into specs + a task manifest
/loop          # supervised by default     # run the build loop with checkpoints
/review        # fresh-context QA          # independent review of the diff
/handoff       # before a context reset    # write a compact handoff for the next agent
/ratchet       "what went wrong"           # record a failure as a new rule (the ratchet)
```

For unattended runs:

```powershell
powershell harness/loop.ps1      # Windows (primary on this machine; use `pwsh` if on PowerShell 7)
bash       harness/loop.sh       # Linux / macOS / CI
```

The loop reads [`harness/harness.config.json`](harness/harness.config.json) for autonomy mode,
iteration/token caps, checkpoints, and the verification gate.

---

## What's in the box

| Path | What it is |
|------|------------|
| `CLAUDE.md` | The root **context map** (~100 lines, a navigation map — not a 1000-page manual). `/harness-init` fills it. |
| `AGENTS.md` | Portability shim → points other agents (Codex, opencode) at `CLAUDE.md`. No proprietary lock-in. |
| `.claude/commands/` | Slash commands: `harness-init`, `plan`, `loop`, `review`, `handoff`, `ratchet`, `verify`, `gc`. |
| `.claude/agents/` | Subagent roles: `planner`, `generator`, `evaluator`, `reviewer`, `doc-gardener`. The doer is never the judge. |
| `.claude/skills/` | Progressive-disclosure skills: `stack-detect`, `sprint-contract`, `evaluator-rubric`, `e2e-evidence`. |
| `.claude/settings.json` | Hooks (format/lint/typecheck on edit; block destructive bash) + permissions + env. |
| `.claude/hooks/` | Cross-platform hook scripts (`.ps1` primary, `.sh` mirror). |
| `harness/harness.config.json` | Autonomy + gate config — the one file you tune per project. |
| `harness/loop.ps1` / `loop.sh` | The configurable autonomy loop (supervised → full-auto) with guardrails. |
| `harness/lib/` | Shared loop primitives: checkpoint, rollback, budget, gate. |
| `harness/profiles/` | **Stack profiles** — pluggable bundles that tell the harness *what* `format`/`lint`/`test`/`build` mean for a given stack. This is what makes the core generic. |
| `docs/` | `architecture/`, `design-docs/`, `execution-plans/`, `technical-debt/`, `principles/`. The agent's long-term knowledge, version-controlled. |
| `specs/` | **Immutable** source of truth for requirements. The agent reads, never rewrites. |
| `state/` | Mutable runtime state: `tasks.json`, `fix_plan.md`, `PROGRESS.md`, `handoff.md`. |
| `PROMPT.md` | The phased prompt piped into each loop iteration (study → plan → implement → verify → record). |
| `AGENT_NOTES.md` | The amnesiac's notebook — run/build commands and hard-won learnings, appended by the loop. |

---

## Core principles (the non-negotiables this harness encodes)

1. **Map, not manual.** `CLAUDE.md` ≤ ~100 lines; it points to `docs/`, it doesn't inline everything.
   Attention is scarce — every line competes.
2. **The ratchet.** You only add a rule after a real failure. `/ratchet` is how. Speculative rules rot.
3. **Externalize state.** Anything not in a file the agent can read at runtime *does not exist*.
4. **One task per iteration.** Incrementalism beats heroics; it protects context quality.
5. **Guides *and* sensors.** Feedforward-only encodes unvalidated rules; feedback-only repeats mistakes.
6. **Doer ≠ judge.** Self-grading skews positive. Review in a **fresh context**.
7. **Unit-green ≠ done.** Demand end-to-end evidence (a screenshot, a recorded run, a real invocation).
8. **Silent success, verbose failure.** The gate says nothing on pass; on fail it injects the fix.
9. **Configurable autonomy, always guarded.** Iteration caps, token budget, auto-rollback, checkpoints.
10. **Portable by construction.** Plain files + git, no proprietary memory; swap the model freely.

---

## Status

This is **v0.1** — by design. A harness is a living system shaped by *your* failure history, not a
config you set once. Start here, then ratchet. See [`docs/principles/harness-philosophy.md`](docs/principles/harness-philosophy.md).
