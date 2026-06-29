# specs/

The **immutable source of truth** for requirements. Agents read this first and **never rewrite it** —
it's the contract. Changes to requirements come from the human (or a `/plan` session you approve), not
from an autonomous loop deciding the spec was inconvenient.

Why immutable matters: in a memory-less loop, the spec is the only fixed reference point. If the agent
could edit it to match whatever it built, "done" would mean nothing. Keep it stable; keep it honest.

## Conventions
- One concern per file, numbered for order: `NNN-<slug>.md` (`000-overview.md` is the project overview).
- Every spec ends with **executable, falsifiable acceptance criteria** — the bar the gate and the
  evaluator hold work to. Prefer measurable ("returns 201 + Location header", "p95 < 200ms") over prose.
- If a requirement genuinely changes, the human edits the spec deliberately and notes the change; the
  plan and tasks then follow.

See [`000-overview.md`](./000-overview.md) for the starting template.
