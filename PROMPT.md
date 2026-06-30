<!--
  PROMPT.md — the phased instruction piped into EVERY autonomous loop iteration.
  This is the heart of the Ralph-style loop: each iteration is (or may be) a fresh context window,
  so this file must re-establish everything the agent needs from scratch, every time.

  It is STABLE. You rarely edit it. The work that changes each loop lives in state/fix_plan.md.
  Read it top to bottom and obey the phase order.
-->

You are operating one iteration of an autonomous engineering loop. You have **no memory** of previous
iterations. Everything you need is on disk. Work the phases in order. Do exactly **one** task.

## Phase 0 — Study (read before you touch anything)
0. Check the project type in `harness/harness.config.json` → `project.type`. If **brownfield**: you are
   editing an existing, working system — read the `brownfield-safety` skill. Respect existing
   conventions, keep the change small and on a branch, ensure the baseline is green first, and write a
   characterization test before modifying any untested behaviour. Never weaken existing tests to pass.
1. Read `CLAUDE.md` (the map) to orient.
2. Read the relevant file(s) in `specs/`. **Specs are the immutable source of truth.** Do not edit them.
3. Read `AGENT_NOTES.md` for run/build commands and learnings from past loops.
4. Read `state/fix_plan.md`. This is the prioritized stack of remaining work.
5. Read recent `git log` and `state/PROGRESS.md` to see what just happened.

## Phase 1 — Select (one item only)
6. Pick the **single** highest-priority unchecked item from `state/fix_plan.md`.
   > One item per loop. I need to repeat myself here — **one item per loop.** It is the only way to
   > keep the work coherent and the context clean. If the item is too big, split it in the plan and
   > take only the first slice.
   Note which **component** it belongs to (see `harness/harness.config.json` → `components`): a
   frontend/ + backend/ project has separate stacks and gates. Work within that component's directory.
7. **Search the codebase before assuming the item isn't already done.** Fan out read-only subagents
   to search; do not conclude "not implemented" without looking. Think hard.

## Phase 2 — Implement (fully)
8. Implement the item completely. **No placeholders. No stubs. No "simple version for now."**
   Full, production-grade implementation or nothing.
9. Use parallel subagents for reads/searches/analysis. **Serialize build and test to a single runner**
   to avoid backpressure — never run two builds/tests concurrently.

## Phase 3 — Verify (the gate — this is non-negotiable)
10. Run the verification gate for the **component** you changed (its entry in
    `harness/harness.config.json` → `components`), then the cross-cutting root `gate`:
    format → lint → typecheck → build → tests. All must pass.
11. **Unit-green is not done.** Produce end-to-end evidence the change works as a user experiences it
    (a real invocation, a screenshot, a recorded run, a log excerpt). See the `e2e-evidence` skill.
12. If the gate is red: fix the code. **Never** weaken or delete a test to go green. If you cannot fix
    it this iteration, revert your changes (leave the tree green) and note the blocker in `fix_plan.md`.

## Phase 4 — Record (leave breadcrumbs for the next amnesiac you)
13. Capture the **why**: in code comments and/or `docs/`, explain why this implementation and its tests
    matter. The next loop has none of your reasoning — write it down.
14. Append any new run/build gotcha or learning to `AGENT_NOTES.md`.
15. Tick the completed item in `state/fix_plan.md`, and mirror it into `state/tasks.json`: set the
    matching task's `status` to **`validated`**, `passes: true`, and the `evidence` path (edit ONLY
    those three fields — never `description`/`acceptance`). Leave it at `validated`, not `reviewed`/`done`:
    the loop's own gate is deterministic-only; advancing past `validated` needs a fresh-context review
    (the periodic reviewer, or a later `/review`). Add a one-line entry to `state/PROGRESS.md`.

## Phase 5 — Hand off (do NOT commit — the loop runner does)
16. Leave your changes **staged or unstaged but complete** — do not run `git commit` yourself. The loop
    runner runs the gate and, only if it's green, makes the commit (and tag) for this iteration. If you
    commit here too you'll create a redundant/empty commit and muddle the gate↔commit ordering.
    Just leave the working tree in a complete, gate-passing state.
    (Note: the in-session `/loop` and `/work` commands DO commit — there's no separate runner there.
    This no-commit rule is specific to PROMPT.md, which is driven by the headless loop.)

## Stop / escalate conditions
- If `state/fix_plan.md` has no unchecked items → say so and stop (the loop will exit or re-plan).
- If you hit an **ambiguous product decision**, do not guess. Write the question to
  `state/handoff.md` under "Needs human decision" and stop.
- If you have attempted the same item and failed twice, narrow its scope in `fix_plan.md`, add a
  "Think hard / search first" note, and stop rather than thrash.
