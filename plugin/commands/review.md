---
description: Independent, fresh-context QA of the current diff. The doer must not be the judge.
argument-hint: (optional) "<git ref or path to scope the review>"
allowed-tools: Read, Edit, Bash, Glob, Grep, Agent, Skill
---

# /review — fresh-context, skeptical review

Scope: $ARGUMENTS (default: **all** unreviewed work — committed since the review base *plus*
uncommitted changes, so a review can't miss the committed part of the change set)

Run an **independent** review. The whole point is that this judgment is *not* contaminated by the
reasoning that produced the code. Route it per `harness.config.json` → `models.review`:
- **`"codex"`** (cross-vendor judge — different training lineage, doesn't share Claude's blind
  spots): probe availability first — `codex --version`, then `codex login status` exit 0 (auth
  `chatgpt`) or `CODEX_API_KEY` set (auth `api-key`). If available, run it READ-ONLY via Bash
  (global flags before the subcommand; `models.codex` supplies model/effort):
  ```
  codex --sandbox read-only --ask-for-approval never exec - --cd <repo-root> --skip-git-repo-check
  ```
  piping in a prompt of: the step-3 checklist + the relevant `specs/` criteria + the BASE ref (codex
  runs `git diff` itself) + the ship/fix-then-ship/reject output contract. If unavailable, say which
  probe failed and **fall back to the `reviewer` subagent** (its frontmatter pins
  `models.reviewFallback`). Codex ran read-only, but still `git status` afterward and revert anything
  unexpected — a judge must not mutate what it judges.
- **any Claude model / unset**: delegate to a fresh `reviewer` subagent (via `Agent`) so it reasons
  from the diff, not from this conversation's history.

## Procedure
1. Determine the diff. If $ARGUMENTS gives a ref/path, use it. Otherwise resolve the review BASE —
   don't use a bare `git diff` (that misses committed hunks):
   ```
   BASE=$(git merge-base HEAD main 2>/dev/null || git rev-parse HEAD~1)
   ```
   (Substitute your repo's default branch for `main` if different.) **If BASE == HEAD** — you're ON
   the default branch with everything committed, e.g. right after a loop run that committed each
   iteration — the merge-base diff is empty and reviewing it would silently ship an unreviewed batch.
   Fall back to the review watermark: `BASE=$(git rev-parse harness-reviewed 2>/dev/null)` (the tag the
   loop's periodic reviewer and this command move on every SHIP). If that tag is also missing or equals
   HEAD and there is no uncommitted work, **stop and ask the human for a range** — never review an
   empty diff and call it ship.
   Then: `git diff "$BASE"` (committed work + staged + unstaged). List the changed files.
2. Spawn a **`reviewer`** subagent with: the diff, the relevant `specs/` acceptance criteria, and
   `docs/principles/`. Instruct it to be skeptical and to **default to "not done" when unsure** —
   confirm, don't praise — but to report **only correctness/requirement/evidence/guardrail gaps**,
   not invented improvements ("no findings" is a valid outcome).
3. The reviewer checks, in priority order:
   - **Correctness** — does it meet the spec's acceptance criteria? Edge cases, error paths.
   - **Evidence** — is there real end-to-end evidence, or only passing unit tests? Unit-green ≠ done.
     If the only proof is unit tests, that's a finding — demand a real invocation/screenshot/log.
   - **Guardrails** — were tests weakened/removed? Specs edited? Destructive ops? Secrets touched?
   - **Drift** — does it match the architecture (`docs/architecture/`) and golden principles? Dead
     code, duplicated helpers, layering violations.
   - **Reuse/simplicity** — anything reinventing an existing utility, or needlessly complex.
4. If a `code-review` skill/plugin is installed (it is not part of this harness), optionally run it as
   a second, tool-driven sensor.

## Output
A verdict: **ship** / **fix-then-ship** / **reject**, with a concise findings list (file:line, the
problem, the fix). For anything that's a *recurring* class of mistake, suggest a one-line `/ratchet`
rule so the harness learns from it. Do not edit code here — review only; hand fixes back to `/loop`.

## On SHIP — record it (the transition past `validated` has no other owner on the /plan → /loop path)
- Advance every task in the reviewed batch that sits at `"validated"` in `state/tasks.json`: set
  `status` to `"reviewed"`, and — when invoked standalone (loop/PROMPT already ticked the plan and
  recorded evidence) — straight on to `"done"`. When invoked from `/work`, leave it at `"reviewed"`;
  `/work`'s RECORD phase owns `reviewed → done`. Edit ONLY `status` — never `description`/`acceptance`.
- Move the watermark: `git tag -f harness-reviewed HEAD` — the next /review starts from here.
On **reject** / **fix-then-ship**: touch nothing; statuses stay at `validated` until the fixes land
and a fresh /review ships them.
