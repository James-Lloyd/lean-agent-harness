---
description: Run one supervised loop iteration in-session (the safe, interactive sibling of harness/loop.ps1).
argument-hint: (optional) "<focus or specific task id>"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion, Skill
---

# /loop — one supervised iteration, in this session

Optional focus: $ARGUMENTS

This is the **in-session, supervised** form of the loop. It does exactly one iteration of `PROMPT.md`
with checkpoints, so you (the human) stay in the driver's seat. For unattended/full-auto runs, use the
shell loop instead: `powershell harness/loop.ps1` (or `pwsh` on PS7) / `bash harness/loop.sh`.

## Procedure (follow PROMPT.md's phases, with these checkpoints)
1. **Study** — read `CLAUDE.md`, the relevant `specs/`, `AGENT_NOTES.md`, and `state/fix_plan.md`.
2. **Select ONE item** — the highest-priority unchecked item (or the one in $ARGUMENTS). If you
   intend a different one than the top of the stack, say which and why.
   - **Checkpoint (if config `autonomy.checkpoints.planApproval`):** state the item and your approach
     in 2–3 lines and get a 👍 before writing code.
3. **Search before implementing** — fan out read-only `Agent` searches; don't assume it's missing.
4. **Implement fully** — no placeholders. Serialize any build/test runs (one at a time).
5. **Verify — the gate** — run format → lint → typecheck → tests for what you changed. Then capture
   **end-to-end evidence** (use the `e2e-evidence` skill). Unit-green is not done.
   - If red: fix the code; never weaken a test. If you can't fix it this turn, revert and note the
     blocker in `state/fix_plan.md`.
   - **Checkpoint (if `autonomy.checkpoints.beforeRiskyOps`):** pause before any push/migration/deploy.
6. **Record** — capture *why* in code/docs; append learnings to `AGENT_NOTES.md`; tick the item in
   `state/fix_plan.md`; in `state/tasks.json` advance the task's `status` (to `done`, or `reviewed` if a
   separate review is still pending) **and** set `passes: true` and the `evidence` path — don't leave
   `status` at `todo` while flipping `passes` (the workflow keys off `status`); add a line to `state/PROGRESS.md`.
7. **Commit** — descriptive conventional message. Leave the tree green.

## After the iteration
Report: what shipped, the evidence, what's next. Ask whether to run another iteration. Recommend a
`/review` (fresh-context QA) before trusting a batch of iterations — you wrote this code, so you're a
biased judge of it.
