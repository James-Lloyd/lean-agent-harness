---
description: Independent, fresh-context QA of the current diff. The doer must not be the judge.
argument-hint: (optional) "<git ref or path to scope the review>"
allowed-tools: Read, Edit, Bash, Glob, Grep, Agent, Skill
---

# /review — fresh-context, skeptical review

Scope: $ARGUMENTS (default: **all** unreviewed work — committed since the review base *plus*
uncommitted changes)

Run an **independent** review, uncontaminated by the reasoning that produced the code. Route per
`harness.config.json` → `models.review`:
- **`"codex"`** (cross-vendor judge — different training lineage): probe availability
  (`codex --version`, then `codex login status` exit 0 or `CODEX_API_KEY` set). If available, run it
  READ-ONLY via Bash (global flags before the subcommand; `models.codex` supplies model/effort):
  ```
  codex --sandbox read-only --ask-for-approval never exec - --cd <repo-root> --skip-git-repo-check
  ```
  piping in: the checklist below + the relevant `specs/` criteria + the BASE ref + the
  ship/fix-then-ship/reject output contract. If unavailable, say which probe failed and fall back to
  the `reviewer` subagent (pinned to `models.review.fallback`). Afterward `git status` and revert
  anything unexpected — a judge must not mutate what it judges.
- **any Claude model / unset** → delegate to a fresh `reviewer` subagent (via `Agent`).

## Procedure
1. Determine the diff. If $ARGUMENTS gives a ref/path, use it. Otherwise resolve the review BASE —
   never a bare `git diff` (it misses committed hunks):
   `BASE=$(git merge-base HEAD main 2>/dev/null || git rev-parse HEAD~1)`.
   **If BASE == HEAD** (on the default branch, all committed — e.g. after a loop run) fall back to
   the watermark: `BASE=$(git rev-parse harness-reviewed 2>/dev/null)`. If that too is missing/equal
   and there's no uncommitted work, **stop and ask the human for a range** — never review an empty
   diff and call it ship. Then `git diff "$BASE"` and list the changed files.
2. Hand the judge: the diff, the relevant `specs/` acceptance criteria, and `docs/principles/` —
   plus, on a re-review round, the prior findings and their resolutions (it then scopes to the fix
   delta + a regression check; settled points are not re-litigated). It checks, in priority order:
   **correctness vs spec** (edge cases, error paths) · **real e2e evidence** (unit-green ≠ done —
   missing evidence is a finding) · **guardrails** (weakened tests, edited specs, destructive ops,
   secrets — hard fail) · **drift** vs architecture/principles · **reuse/simplicity** — and
   classifies every finding **blocker / should-fix / nit** (blocker = violates a stated spec
   requirement, breaks an interface contract, loses data, opens a security hole, or fails a test).
   It must not raise issues untraceable to a spec requirement or a correctness, security, or
   data-integrity failure; "no findings — ship" is valid.
3. If a `code-review` skill/plugin is installed, optionally run it as a second sensor.

## Output
**ship / fix-then-ship / reject** + findings (`file:line — severity — problem — fix`). The verdict
gates on **blockers only**: zero blockers = ship, even with should-fixes/nits logged. Suggest a
`/ratchet` rule for any recurring failure class. Review only — hand fixes back.

## On SHIP — record it (no other owner on the /plan → /loop path)
- Advance every reviewed task sitting at `"validated"` in `state/tasks.json` to `"reviewed"` — and,
  when invoked standalone (not from `/work`), straight to `"done"`. Edit ONLY `status`.
- Move the watermark: `git tag -f harness-reviewed HEAD`.
On **reject** / **fix-then-ship**: touch nothing; statuses stay `validated` until fixes land and a
fresh /review ships them.
