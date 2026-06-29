# Harness philosophy

The ideas this harness is built on, and why each file exists. Read this once; it explains the *shape*
of everything else. (Bibliography: [`sources.md`](./sources.md).)

## 1. Agent = Model + Harness
The model is fixed within a session. Everything that makes it reliable — constraints, guides, feedback,
tooling, state — is the harness. "A decent model with a great harness beats a great model with a bad
harness." Most agent failures are harness gaps, not model gaps. So we invest here.

## 2. Two halves: guides and sensors (you need both)
- **Guides (feedforward)** steer *before* the agent acts: `CLAUDE.md`, `specs/`, skills, types, LSP.
  Feedforward-only encodes rules that are never validated.
- **Sensors (feedback)** observe *after* it acts: format, lint, typecheck, tests, fresh-context review.
  Feedback-only lets the same mistake repeat.
Sensors come in two costs: **computational** (deterministic, fast, cheap — run on every change) and
**inferential** (LLM judgment — slower, run when it earns its cost). Keep quality "left": cheapest
checks earliest.

## 3. The ratchet
Every rule must trace to a real failure. Speculative "best practices" become a graveyard of stale rules
that crowd out the task. `CLAUDE.md` stays a **map, not a manual** (≤ ~100 lines). You add rules via
`/ratchet` *after* something breaks, and you delete rules that stop earning their attention. The
harness is shaped by *your* failure history — it is a living system, not a one-time setup.

## 4. Stateless loop, stateful files
Long-running work fails when state lives in the conversation, because context windows fill and reset.
So we externalize **everything** to durable files: `specs/` (immutable truth), `state/fix_plan.md`
(mutable task stack), `state/tasks.json` (machine-readable manifest), `state/PROGRESS.md` (log),
`AGENT_NOTES.md` (learnings), and git (journal + undo). Any iteration can start from a fresh context
and reconstruct where things stand. *Anything the agent can't read at runtime does not exist.*

## 5. One task per iteration
Incrementalism beats heroics. One fully-implemented task per loop keeps context clean and changes
reviewable, and it stops the agent from declaring premature victory across a sprawling change.

## 6. Fan out reads, serialize the gate
Parallelize the cheap, non-mutating work (search, analysis, review). Serialize the one thing that must
not race — building and testing — to a single runner. Read-heavy fan-out; write/verify bottleneck.

## 7. Doer ≠ judge
An agent grading its own work skews positive. Verification happens in a **fresh context** (the
`reviewer`/`evaluator` subagents, or `/review`), reasoning from the diff and the spec — not from the
reasoning that produced the code. For quality-sensitive work, the evaluator scores against hard,
pre-agreed thresholds (a **sprint contract**) and fails the sprint on any miss.

## 8. Unit-green is not done
Passing unit tests routinely coexists with a broken product. We demand **end-to-end evidence** — a real
invocation, a screenshot, a log — tied to a spec's acceptance criteria, before anything is "done".

## 9. Configurable autonomy, always guarded
Autonomy is a dial from supervised (checkpoints for approval) to full-auto (unattended Ralph-style
loop). Every setting on that dial keeps the same guardrails: iteration caps, a token/cost budget,
git checkpoint + **auto-rollback on a red gate** (a failed iteration never leaves a broken tree), and a
PreToolUse hook that blocks destructive commands. Greenfield or well-isolated subsystems are the safe
home for high autonomy; existing codebases get tighter supervision and mandatory fresh-context review.

## 10. Portable by construction
State is plain files + git. No proprietary auto-memory, no lock-in. You can swap the model or the tool
(`AGENTS.md` points other agents at the same context) and the harness still works. That portability is
also insurance: re-examine the harness on every new model and strip pieces that are no longer
load-bearing — the best harness is the smallest one that still gets the quality you need.

## 11. Greenfield and brownfield are different jobs
The harness adapts to whether you're building from scratch or changing an existing system
(`config.project.type`).

- **Greenfield** — you *establish* the world: choose a harnessable stack (strong typing, clear
  boundaries), write specs first, and you can run higher autonomy. The empty scaffold is your baseline.
- **Brownfield** — you *inherit* a working system with users and assumptions, and your prime directive
  is **no regressions**. So: `/onboard` first to map the architecture, discover the gate from existing
  CI/scripts (don't invent one), and **establish a green baseline** — without a known-good starting
  point, auto-rollback can't tell your breakage from pre-existing failures. Then change small, on a
  branch, writing a **characterization test before touching untested behaviour** (lock current
  behaviour, then move). Respect existing conventions instead of imposing new ones. Default to
  supervised: the unattended auto-loop is a greenfield technique — on existing code it invites wide,
  subtle regressions, so it warns and requires explicit opt-in. The `brownfield-safety` skill carries
  the full discipline.
