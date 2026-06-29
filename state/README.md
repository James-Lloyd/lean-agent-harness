# state/

The live, mutable working memory of the loop. These files are how a fresh context window knows where
things stand. They are committed (they *are* the memory) — except `handoff.md`, which is regenerated
each reset and gitignored.

| File | Role | Who writes it |
|------|------|----------------|
| `fix_plan.md` | The prioritized task **stack** (checkbox list). The loop pulls the top unchecked item. | `/plan`, then ticked by `/loop` |
| `tasks.json` | The machine-readable **manifest** mirroring the plan. Granular; agent edits only `passes`. | `/plan`, then `passes:true` by `/loop` |
| `PROGRESS.md` | Append-only **session log** — one line per meaningful step. | every iteration |
| `handoff.md` | Compact structured **handoff** for a context reset (gitignored, transient). | `/handoff` |
| `evidence/` | Captured **end-to-end evidence** (screenshots/logs/output) per task. | `/verify`, `e2e-evidence` skill |

Rule: the plan (`fix_plan.md`) and manifest (`tasks.json`) must agree. `tasks.json` is JSON on purpose
— the model is less likely to inappropriately rewrite a JSON manifest than a Markdown file, which makes
it a sturdier guardrail against premature "done."

Each task in `tasks.json` carries a **`status`** that advances through the workflow lifecycle
(`todo → planned → in_progress → validated → reviewed → done`) and a **`component`** naming which
buildable unit it belongs to. `/work` advances the status; a failed phase sends it back, never forward.
See [`../docs/principles/workflow.md`](../docs/principles/workflow.md).
