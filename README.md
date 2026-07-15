# lean-agent-harness

A portable, tech-stack-agnostic engineering harness for AI coding agents (Claude Code first,
but the state lives in plain files so it survives a model/tool swap). Clone it into any project,
run `/harness-init`, and the AI works against checks — not blind trust.

> **Agent = Model + Harness.** The model is fixed for a given session; the harness is everything
> else — the constraints, guides, feedback loops, tooling, and state that channel a powerful but
> unpredictable model toward reliable output. This repo *is* that harness. You clone it per project
> and run `/harness-init` once to make it yours.

This harness is a synthesis of current best practice from Anthropic, OpenAI, Martin Fowler
(Birgitta Böckeler), Geoffrey Huntley's "Ralph" loop, Addy Osmani, and an ex-Meta L8's agentic
workflow. See [`docs/principles/sources.md`](docs/principles/sources.md) for the bibliography and
which idea came from where.

> **New to this? Read [`GUIDE.md`](GUIDE.md) first** — a plain-English, no-jargon walkthrough of what
> a harness is and how to set this one up in ~5 minutes. The rest of this README is the reference.

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
                 │   state/PROGRESS.md · AGENT_NOTES.md                     │
                 │   (state/handoff.md is transient — gitignored, per reset)│
                 └──────────────────────────────────────────────────────────┘
```

The loop is **stateless** (every iteration can start from a fresh context window); the **files are
stateful**. That is the whole trick to long-running work.

---

## Quickstart

```bash
# 1. Start your project from the template — this gives the SCAFFOLD you fill in:
#    CLAUDE.md, specs/, state/, harness/harness.config.json (the plugin does NOT ship these).
git clone <this-repo> my-project && cd my-project && rm -rf .git && git init

# 2. Add the reusable ENGINE as a plugin (commands, agents, skills, hooks, loop/fleet runners).
#    Versioned: `/plugin update` later pulls engine fixes without re-templating. Also how you
#    upgrade an already-harnessed project — see docs/plugin-migration.md.
/plugin marketplace add James-Lloyd/lean-agent-harness
/plugin install lean-agent-harness@lean-agent-harness

# 3. Run the one-time interview (in Claude Code) — fills the scaffold placeholders and, for a
#    plugin install, drops the thin harness/ runner wrappers in for you.
/harness-init

# 4. Work
/plan   "build the thing"   # decompose intent into specs + a task manifest
/work   # or a task id      # drive ONE task plan→execute→validate→review→record, with checkpoints
/loop                       # one full supervised iteration (study→implement→verify→record)
/review                     # fresh-context QA — independent review of the diff
/handoff                    # before a context reset — compact handoff for the next agent
/ratchet "what went wrong"  # record a failure as a new rule (the ratchet)
```

`/work` is the orchestrator — it runs the full **plan → execute → validate → review → record**
workflow for one task, pausing at each phase in supervised mode. See
[`docs/principles/workflow.md`](docs/principles/workflow.md). `/plan`, `/verify`, and `/review` are
individual phases you can also run by hand; `/loop` is not a phase — it runs one **full** iteration
(study→implement→verify→record), the same unit the unattended loop repeats.

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
| `plugin/` | The **`lean-agent-harness` plugin** — the single source of truth for the engine. Ships the commands, agents, skills, hooks (`plugin/hooks/`), and the loop/fleet engine + `lib`/`profiles`/`templates`/schema (`plugin/engine/`). This repo installs it from its own local marketplace (`.claude-plugin/marketplace.json`); deployed projects `/plugin install` + `/plugin update` it. |
| `.claude/commands/`, `.claude/agents/`, `.claude/skills/`, `.claude/hooks/` | **Provided by the installed plugin — not duplicated in-repo.** Commands (`harness-init`, `work`, `loop`, `review`, …); subagent roles (`planner`, `generator`, `explorer`, `evaluator`, `reviewer`, `doc-gardener`), each pinned to a per-phase model (the doer is never the judge); skills (`stack-detect`, `sprint-contract`, `e2e-evidence`, `brownfield-safety`); cross-platform hooks (`.ps1` primary + `.sh` mirror, dispatched by `run.mjs`). |
| `.claude/settings.json` | Permissions + env + session `model`. The hooks (format/lint/typecheck on edit, routed per component; block destructive bash; SessionStart orientation) are supplied by the plugin (`plugin/hooks/hooks.json`), not defined here. |
| `harness/harness.config.json` | Autonomy + workflow + per-phase **model routing** (`models`, incl. an optional cross-vendor Codex reviewer with claude fallback) + per-component gate config — the one file you tune per project. |
| `harness/loop.ps1` / `loop.sh`, `harness/fleet.ps1` / `fleet.sh` | Thin **wrappers** that locate the installed plugin engine (`$HARNESS_ENGINE` → `$CLAUDE_PLUGIN_ROOT/engine` → `~/.claude/plugins`) and dispatch to it, passing this repo as project root — so `powershell harness/loop.ps1 …` keeps working from a bare terminal or cron. The real loop / **opt-in parallel fleet** (independent tasks build in isolated worktrees, then land through a serialized merge queue that re-runs the full gate) ship in `plugin/engine/`. |
| `harness/tests/` | Self-tests for the harness's own logic (gate, denylist, budget) sourced from `plugin/engine` — run them locally or in CI. |
| `ci/` | Ready-to-activate CI workflow (copy into `.github/workflows/` to run self-tests on push/PR). |
| `docs/` | `architecture/`, `design-docs/`, `execution-plans/`, `technical-debt/`, `principles/`. The agent's long-term knowledge, version-controlled. |
| `specs/` | **Immutable** source of truth for requirements. The agent reads, never rewrites. |
| `state/` | Mutable runtime state: `tasks.json`, `fix_plan.md`, `PROGRESS.md` (committed — they *are* the memory); `handoff.md` is gitignored: a transient, per-working-copy note regenerated at each context reset. |
| `PROMPT.md` | The phased prompt piped into each loop iteration (study → select → implement → verify → record → hand off). |
| `AGENT_NOTES.md` | The amnesiac's notebook — run/build commands and hard-won learnings, appended by the loop. |

---

## Project shapes (single-root and multi-component)

A project is one or more **components**. A single app is one component (`path: "."`). A **headless**
project is several — e.g. `frontend/` (Next.js) + `backend/` (FastAPI), each with its own root files,
stack, and build/test commands:

```
my-project/
├── CLAUDE.md            # root map → points at each component
├── harness/             # one harness governs the whole project
├── specs/  state/  docs/
├── frontend/  ├─ package.json   └─ CLAUDE.md   # component: Node, its own gate
└── backend/   ├─ pyproject.toml └─ CLAUDE.md   # component: Python, its own gate
```

Each component declares its own gate in `harness/harness.config.json` → `components[]`, and the harness
runs that gate **in that component's directory**. The PostToolUse hook routes a changed file to the
component that owns it (a `.py` edit under `backend/` is checked with backend's tools). A cross-cutting
**root gate** holds the integration/e2e that exercises the components together. `/harness-init` detects
the shape and wires all of this — you don't manage two harnesses.

## Greenfield and brownfield

The harness handles both new and existing codebases — they're different jobs (`config.project.type`):

- **Greenfield** — `/harness-init` establishes the stack, writes specs first, `git init`s, and higher
  autonomy is fine. The empty scaffold is the baseline.
- **Brownfield** — `/harness-init` detects existing code and runs **`/onboard`**: it maps the
  architecture, **discovers the gate from your existing CI/scripts** (rather than inventing one),
  **establishes a green baseline** (so rollback can tell your breakage from pre-existing failures), and
  captures the conventions already in force. Work then defaults to **supervised**, small, on a branch,
  with a **characterization test before changing untested behaviour**. Full-auto on existing code warns
  and needs explicit opt-in (the auto-loop is a greenfield technique). See the `brownfield-safety` skill.

## The workflow (plan → execute → validate → review → record)

Every task advances through an explicit lifecycle, separating the doer from the judge at each step
(the Planner/Generator/Evaluator pattern). Each task's `status` in `state/tasks.json` tracks where it is:

```
 todo ──plan──▶ planned ──execute──▶ in_progress ──validate──▶ validated ──review──▶ reviewed ──record──▶ done
   │                                                                                                        ▲
   └──────────────────────────────── (a failed phase sends it back, never forward) ───────────────────────┘
```

Note the split: bulk `/plan` *seeds* the whole manifest at `todo`; the `todo → planned` transition is
made **per task by `/work`'s PLAN phase** as it picks each one up.

`/work` orchestrates all five phases for one task with checkpoints between them. `/loop` runs one
**full** iteration (study→implement→verify→record) — it's the per-iteration unit, not a single phase. In
**auto** mode the shell loop runs that same iteration (via `PROMPT.md`) unattended, one task at a time,
rolling back any iteration that fails the validate gate. Full contract:
[`docs/principles/workflow.md`](docs/principles/workflow.md).

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
9. **Configurable autonomy, deterministically guarded.** Iteration + per-iteration-turn caps, a
   best-effort token estimate, git auto-rollback, a config-tamper pin, and a destructive-command hook.
   Note the honesty: in **auto** mode the guard is the *deterministic* gate + rollback; the inferential
   judges (fresh-context review, evaluator) run in the supervised paths — see [`ROADMAP.md`](ROADMAP.md).
10. **Portable by construction.** Plain files + git, no proprietary memory; swap the model freely.
11. **It tests itself.** The harness's own logic has self-tests ([`harness/tests/`](harness/tests/)) run
    in CI — they've already caught real bugs.

---

## Slim it down after setup

The harness ships with teaching comments, examples, and reference profiles so it's self-explanatory.
Once `/harness-init` has made it yours, run **`/harness-prune`** to strip the now-dead scaffolding —
instructional comments in the always-loaded files (`CLAUDE.md`, `AGENT_NOTES.md`, `PROMPT.md`), the
`examples/` folder, and unused stack profiles. Less noise competing for the model's attention every
session, and it's a single revertible commit. ("Map, not manual" applies to the harness itself.)

## Status

This is **v0.1** — by design. A harness is a living system shaped by *your* failure history, not a
config you set once. Start here, then ratchet. See [`docs/principles/harness-philosophy.md`](docs/principles/harness-philosophy.md)
for the why and [`ROADMAP.md`](ROADMAP.md) for what's deliberately not built yet (an adversarial
four-lens review shaped that list).

## License

[MIT](LICENSE) © 2026 James Lloyd.
