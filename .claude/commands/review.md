---
description: Independent, fresh-context QA of the current diff. The doer must not be the judge.
argument-hint: (optional) "<git ref or path to scope the review>"
allowed-tools: Read, Bash, Glob, Grep, Agent, Skill
---

# /review — fresh-context, skeptical review

Scope: $ARGUMENTS (default: the working diff vs. the base branch)

Run an **independent** review. The whole point is that this judgment is *not* contaminated by the
reasoning that produced the code. Delegate the actual review to a fresh `reviewer` subagent (via
`Agent`) so it reasons from the diff, not from this conversation's history.

## Procedure
1. Determine the diff: `git diff` (or against the ref in $ARGUMENTS). List changed files.
2. Spawn a **`reviewer`** subagent with: the diff, the relevant `specs/` acceptance criteria, and
   `docs/principles/`. Instruct it to be skeptical and to **default to "not done" when unsure** —
   confirm, don't praise.
3. The reviewer checks, in priority order:
   - **Correctness** — does it meet the spec's acceptance criteria? Edge cases, error paths.
   - **Evidence** — is there real end-to-end evidence, or only passing unit tests? Unit-green ≠ done.
     If the only proof is unit tests, that's a finding — demand a real invocation/screenshot/log.
   - **Guardrails** — were tests weakened/removed? Specs edited? Destructive ops? Secrets touched?
   - **Drift** — does it match the architecture (`docs/architecture/`) and golden principles? Dead
     code, duplicated helpers, layering violations.
   - **Reuse/simplicity** — anything reinventing an existing utility, or needlessly complex.
4. Optionally run the project's own `code-review` skill as a second, tool-driven sensor.

## Output
A verdict: **ship** / **fix-then-ship** / **reject**, with a concise findings list (file:line, the
problem, the fix). For anything that's a *recurring* class of mistake, suggest a one-line `/ratchet`
rule so the harness learns from it. Do not edit code here — review only; hand fixes back to `/loop`.
