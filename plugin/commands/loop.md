---
description: Run one supervised loop iteration in-session (the safe, interactive sibling of harness/loop.ps1).
argument-hint: (optional) "<focus or specific task id>"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion, Skill
---

# /loop — one supervised iteration, in this session

Optional focus: $ARGUMENTS

One iteration of `PROMPT.md`, in-session with checkpoints. For unattended runs use the shell loop:
`powershell harness/loop.ps1` / `bash harness/loop.sh`.

## Procedure
0. **Project type** — `config.project.type` = brownfield → load `brownfield-safety`, confirm the
   baseline is green, branch, characterization-test before changing untested behaviour.
1. **Study** — `CLAUDE.md`, the relevant `specs/`, `AGENT_NOTES.md`, `state/fix_plan.md`.
2. **Select ONE item** — the top unchecked item (or $ARGUMENTS; say why if you deviate).
   - **Checkpoint (`autonomy.checkpoints.planApproval`):** state item + approach in 2–3 lines, get a 👍.
3. **Implement** — check it isn't already done first; work in the owning component's directory;
   serialize builds/tests.
4. **Verify — the gate** — format → lint → typecheck → tests for what changed, then **end-to-end
   evidence** (`e2e-evidence` skill); unit-green is not done. Red → fix (never weaken a test) or
   revert and note the blocker in `fix_plan.md`.
   - **Checkpoint (`beforeRiskyOps`):** pause before any push/migration/deploy.
5. **Record** — the *why* in code/docs; learnings → `AGENT_NOTES.md`; tick `fix_plan.md`; in
   `state/tasks.json` set `status: "validated"` + `passes: true` + `evidence` (NOT `reviewed`/`done` —
   advancing past `validated` needs a fresh-context `/review`); add a `state/PROGRESS.md` line.
6. **Commit** — descriptive conventional message, tree green.

## After the iteration
Report what shipped, the evidence, what's next; ask whether to run another. Recommend `/review`
before trusting a batch — the doer is a biased judge. On SHIP, `/review` advances the reviewed tasks
and moves the `harness-reviewed` watermark.
