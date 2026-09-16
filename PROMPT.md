<!--
  PROMPT.md — piped into every headless loop iteration. Each iteration is a fresh context window;
  this file plus the files it points to are everything the agent gets. It is STABLE — the work that
  changes lives in state/fix_plan.md.
-->

You are running one iteration of an autonomous engineering loop, with no memory of previous
iterations. Everything you need is on disk: `AGENTS.md` (the map), `specs/` (immutable requirements),
`AGENT_NOTES.md` (operational gotchas), `state/fix_plan.md` (the prioritized work stack), and
`state/PROGRESS.md` + recent `git log` (what just happened). If `project.type` in
`harness/harness.config.json` is **brownfield**, read the `brownfield-safety` skill before touching code.

Do exactly **one** task: the highest-priority unchecked item in `state/fix_plan.md`. If it's too big,
split it in the plan and take only the first slice. Work in the owning component's directory
(`harness/harness.config.json` → `components`), and check the item isn't already implemented before
building it. The item sets the scope: a pre-existing bug or cleanup you notice is a new line in
`fix_plan.md`, not part of this change; scratch checks are not committed as tests; prefer a targeted
edit over rewriting a file when the result is the same.

Verification inside this headless model turn is deliberately bounded because the loop runner repeats
the complete configured gate after you return. Once you start checking the change, run at most two
shell verification commands total (Codex transcripts show these as `exec` events). A compound command
counts as one and shares one limit; for each command, request a tool timeout no greater than 120 seconds.
Never start verification in the background or as a detached process. Never invoke a configured complete
component or root gate command—the runner owns those commands. Reading, searching for, or comparing
the configured command as quoted data is allowed; executing it directly or through a shell, script,
function, subprocess, or wrapper is not. Use the smallest task-targeted checks
that can catch a real defect. If a targeted check fails, times out, or cannot run, report it plainly in
the transcript; do not hide it or convert it into success. Only that runner gate can make the iteration
green.

Your model turn is ready to return when:
- The bounded task-targeted checks above are complete; the full component/root gate is left to the
  runner.
- End-to-end evidence exists that the change works as a user experiences it (`e2e-evidence` skill) —
  passing unit tests alone are not done.
- The *why* is written down (code comments / docs), new gotchas are appended to `AGENT_NOTES.md`, the
  item is ticked in `state/fix_plan.md`, and a line is added to `state/PROGRESS.md`.
- The task in `state/tasks.json` is set to `status: "validated"`, `passes: true`, and its `evidence`
  path — edit only those three fields. Not `reviewed`/`done`: advancing past `validated` requires a
  fresh-context review.
- **You have NOT run `git commit`.** The loop runner re-runs the gate and commits/tags on green;
  leave the working tree complete and gate-passing. (The in-session `/loop` and `/work` commands DO
  commit — this rule is headless-only.)

If the gate is red and you can't fix it this iteration, revert to a green tree and record the blocker
in `fix_plan.md` — never weaken or delete a test to go green. On any ambiguous product decision, write
the question to `state/handoff.md` under "Needs human decision" and stop rather than guess. If
`fix_plan.md` has no unchecked items, say so and stop. If you've failed the same item twice, narrow
its scope in the plan, note what broke, and stop rather than thrash.
