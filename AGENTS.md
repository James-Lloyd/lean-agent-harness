# {{PROJECT_NAME}}

{{ONE_LINE_DESCRIPTION}}

**Domain:** {{DOMAIN}} · **Type:** {{PROJECT_TYPE}} · **Shape:** {{PROJECT_SHAPE}}

## Components

Run each component gate in its own directory; see `harness/harness.config.json`.

| Component | Path | Stack | Test |
|-----------|------|-------|------|
| {{COMPONENT_NAME}} | `{{COMPONENT_PATH}}` | {{COMPONENT_STACK}} | `{{COMPONENT_TEST}}` |

## Context map

- `specs/` — immutable requirements and acceptance contracts.
- `docs/architecture/` + `docs/design-docs/` — structure and decisions.
- `docs/principles/workflow.md` — lifecycle driven by work, plan, verify, review, and loop.
- `docs/principles/agent-operating-history.md` — expanded ratchet history; consult for harness,
  foreign-tool, guard, probe, or evidence changes.
- `state/` — live queue, manifest, progress, handoff, and evidence.
- `plugin/` — shared Claude/Codex package; `plugin/engine/AGENTS.md` governs engine changes.
- `AGENT_NOTES.md` — operational gotchas; append only when a real lesson is learned.

## Workflow

Work one task at a time: the top unchecked item in `state/fix_plan.md`. Done means the affected
component gate and root gate pass and user-visible end-to-end evidence exists under `state/evidence/`.
Unit-green alone is not done. Commit green work; in the headless loop, `PROMPT.md` decides who commits.
Prefer a written handoff and fresh context at task boundaries.

Use one git worktree per interactive session, branched from the current `origin/main`, before editing.
As the first commit, claim the chosen task with `- [ ] (wip: <branch>) ...`; land through a PR to
`main`. Details: `docs/principles/workflow.md`.

## Guardrails

- Never weaken or delete a test to get green. Fix the code or escalate.
- Never edit `specs/`; propose product-contract changes to the human.
- Escalate ambiguous product decisions instead of guessing.
- The doer is not the judge: review in a genuinely fresh context.
- Do not bypass destructive-command hooks.
- Use absolute command paths instead of `cd ... &&`; inspect files without interpreter heredocs.

## Ratchet summary

- When changing a fact, grep every prompt, doc, twin, check, schema, skip predicate, and state record
  that can repeat it. A pointer is valid only after its target is verified.
- Keep PowerShell 5.1 and Bash engine twins behaviorally identical; follow `plugin/engine/AGENTS.md`.
- A config key must have a named consumer. Use full model IDs where generation matters.
- Bump the plugin version in the same diff as shipped engine behavior or package-contract changes.
- Prove foreign-tool behavior by making the real version load and act on emitted artifacts. Verify
  effective state, not accepted syntax or hand-built argv. Record result-file-and-line citations.
- Guard predicates need real inputs at real sizes, positive and negative controls, and pre-fix
  mutation proof that fails with a wrong value rather than an unrelated exception.
- A green headless iteration without a commit is a terminal run boundary: never checkpoint the same
  HEAD again while accepted uncommitted work exists. Cache wrappers rank semantic version before mtime.
- Probes support output-directory and cost-skip controls, scrub paths before writing evidence, and
  must demonstrate both verdicts. Cite measured durations, costs, and counts.
- Close a task only after grepping `AGENT_NOTES.md` and `state/` for its own why text; completed queue
  entries name their evidence directory and `PROGRESS.md` records both twin gate counts.
