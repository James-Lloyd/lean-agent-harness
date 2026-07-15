<!--
  This is the ROOT CONTEXT MAP. It is a navigation map, not a manual.
  RULES FOR THIS FILE (the ratchet discipline):
    • Keep it under ~100 lines. It competes for the model's attention with the actual task.
    • Point to docs/ and nested CLAUDE.md files; do NOT inline full specs or style guides.
    • Every line in "Project rules" must trace to a real failure (added via /ratchet) or a hard
      constraint. Delete rules that no longer earn their place.
    • `/harness-init` fills the {{PLACEHOLDERS}} below. Until then they are intentionally blank.
-->

# {{PROJECT_NAME}}

{{ONE_LINE_DESCRIPTION}}

## What this is
- **Domain / market:** {{DOMAIN}}
- **Type:** {{PROJECT_TYPE}}  <!-- greenfield (build from scratch) | brownfield (existing code — respect it; see brownfield-safety skill) -->
- **Shape:** {{PROJECT_SHAPE}}  <!-- e.g. "single Node app" or "headless: frontend/ (Next.js) + backend/ (FastAPI)" -->

## Components (the buildable units)
Each component has its own stack, gate, and (for non-trivial ones) its own nested `CLAUDE.md`. The
harness runs each component's gate in its own directory; see `harness/harness.config.json` → `components`.

| Component | Path | Stack | Run | Test |
|-----------|------|-------|-----|------|
| {{COMPONENT_NAME}} | `{{COMPONENT_PATH}}` | {{COMPONENT_STACK}} | `{{COMPONENT_RUN}}` | `{{COMPONENT_TEST}}` |
<!-- one row per component; a single-root project has exactly one row with path `.` -->

Cross-cutting (e.g. an e2e that exercises the components together): {{ROOT_E2E}}

## Where things live (the map)
- `specs/` — **immutable** requirements. Source of truth. Read first; never rewrite.
- `docs/architecture/` — how the system fits together. Read before structural changes.
- `docs/design-docs/` — decisions already made and *why*. Don't relitigate them.
- `docs/execution-plans/` — versioned plans + progress logs for in-flight work.
- `docs/technical-debt/` — known issues. Check before "discovering" one.
- `docs/principles/` — engineering norms / golden principles for this repo.
- `state/` — live work state: `tasks.json` (manifest), `fix_plan.md` (priority stack),
  `PROGRESS.md` (session log), `handoff.md` (context-reset handoff), `evidence/` (e2e proof per task).
- `AGENT_NOTES.md` — run/build gotchas and learnings. **Append here when you learn something.**

## How to work here (the workflow: plan → execute → validate → review → record)
Full contract: [`docs/principles/workflow.md`](docs/principles/workflow.md). `/work` drives one task
through all phases; `/plan`, `/verify`, `/review` are the phases run individually (`/loop` is not a
phase — it runs one full iteration end-to-end). In short:
1. **Study first.** Read the relevant `specs/`, then the code, then `state/fix_plan.md`. Note which
   **component** the task touches and work in that directory.
   **Search the codebase before assuming something isn't implemented.** Think hard.
2. **One task per iteration.** Pick the highest-priority unfinished item from `state/fix_plan.md`.
3. **Implement fully.** No placeholders, no stubs, no "simple version for now."
4. **Verify — this is the gate.** Run the changed component's gate (format → lint → typecheck → build →
   test) and the cross-cutting root gate.
   Unit-green is not done: capture **end-to-end evidence** that it works as a user would see it.
5. **Checkpoint.** Commit with a descriptive message when green (exception: in the headless loop the
   RUNNER commits — PROMPT.md's no-commit rule wins there). Roll back a red tree, don't patch over it.
6. **Record.** Tick the item in `state/fix_plan.md`; note *why* in code/docs for the next (amnesiac) loop.
7. **Reset, don't compact.** At task boundaries: `/handoff` then `/clear` — state lives in files and
   the SessionStart hook re-orients a fresh window. `/compact` is the mid-task emergency tool only.

## Verification gate (must pass before "done")
The gate is **per component** (its commands run in that component's directory), then a cross-cutting
root gate. Exact commands live in `harness/harness.config.json`. For `{{COMPONENT_NAME}}`:
```
{{FORMAT_COMMAND}}
{{LINT_COMMAND}}
{{TYPECHECK_COMMAND}}
{{BUILD_COMMAND}}
{{TEST_COMMAND}}
{{E2E_COMMAND}}
```
(Multi-component projects: one such block per component — the config is the source of truth.)
The PostToolUse hook runs the fast subset (format/lint/typecheck) automatically on edit, **routed to
the component that owns the changed file**. Failures come back with the fix in the message — read them.

## Guardrails (hard constraints)
- **Do not** weaken or delete tests to make a build pass. Fix the code or escalate.
- **Do not** run destructive commands (`rm -rf`, `git push --force`, `DROP TABLE`, secrets exfil).
  The PreToolUse hook blocks the obvious ones; don't try to route around it.
- **Do not** edit anything under `specs/` — it is the contract. Propose changes to the human instead.
  (One carve-out: `/plan`, `/onboard`, and `/harness-init` may **author new specs with the human's
  approval**. Rewriting an existing spec to make work "pass" is never legitimate.)
- **Escalate ambiguous product decisions** to the human rather than guessing. Ask for the *why*.
- Review code in a **fresh context** (use `/review` or the `reviewer` subagent), never self-grade.

## Project rules (the ratchet — grows only from real failures)
<!-- Add entries via /ratchet. Format: "- [YYYY-MM-DD] <rule>  — because <the failure it prevents>" -->
- [2026-07-14] Output-sniffing predicates (e.g. usage/limit detection) must be consulted ONLY on a FAILED
  invocation (not-ok / nonzero exit), never to overturn a SUCCESS  — because the markers are substring-based,
  so a successful write-phase build whose text merely mentions "overloaded"/"quota"/"429" would be reset to
  base and retried on the fallback, silently discarding a good build (S2 review near-miss).
- [2026-07-14] When a phase's resolved `Primary` model is '' (inherit ambient) but a per-phase `fallback`
  IS configured, the fallback is reached ONLY on a failed invocation — it is NOT the happy-path model
  — because `Invoke-Phase` runs the primary first; a config that pinned a reviewer purely via legacy
  `reviewFallback` (with `review` unset) is therefore run on the ambient model on the happy path, not on
  `reviewFallback` (S3 review — narrow, disclosed; the migrated `{model,fallback}` config avoids it).
- [2026-07-14] Do not pin a fresh-context judge (`reviewer`/`evaluator` subagent) to a model tier that can
  hit its own usage cap mid-review — when it dies with "reached your <model> limit", re-spawn the subagent
  with a `model:` override to finish  — because the review actually failed to run this way (S3: the
  Fable-pinned reviewer was knocked out by a Fable-5 usage limit). Broader fix (subagent-level fallback)
  is a candidate for a later slice.
- [2026-07-15] Engine code that runs a phase inside a PowerShell `Start-Job` must (a) re-source its libs
  INSIDE the job — a Start-Job runs in a fresh runspace that does NOT inherit the parent's dot-sourced
  functions (pass the lib dir via `-ArgumentList`; `$PSScriptRoot` differs inside), and (b) use a quiet
  (`Out-Null`) output path, never `Out-Host` — because `Out-Host` produced inside a job is replayed to the
  parent console at `Receive-Job` and CANNOT be suppressed by any stream redirect (`6>$null`/`*>$null` all
  fail), so a worker's whole transcript would dump into the merge-queue console. Also assign the phase
  result to a var so its object doesn't leak into the job output stream; emit only the `0/1` exit proxy the
  caller reads (S4: the fleet worker's dispatcher wiring; de-risked with live experiments before building).
- [2026-07-15] A delegated `isolation: worktree` agent can be checked out on an ANCESTOR of `main`, not its
  tip — so before squash-merging its work the orchestrator MUST compare the worktree's base to `HEAD` and,
  if they differ, prove every file the agent touched is byte-identical between base and tip
  (`git diff --quiet <base> HEAD -- <file>`) before trusting the merge; the agent itself must sanity-check
  its HEAD against the task's premises and escalate on mismatch — because a stale base silently builds on
  old content for any file that moved, and a blind squash would merge that regression (recurred S7 +
  sandboxing; both caught, once by the generator, once by the orchestrator's pre-merge diff).
- [2026-07-15] A PowerShell double-quoted string / here-string with `$Var` immediately followed by `:`
  (e.g. `failBelow=$FailBelow:`) is a PARSE error under Windows PowerShell 5.1 — `$name:` is the scope/drive
  syntax (`$env:`/`$script:`), so the ENTIRE script fails to parse and cannot run at all; write `${Var}:`.
  AND the self-test suite must PARSE-CHECK every top-level engine entry script (loop/fleet/migrate/wrappers)
  — `[Parser]::ParseFile` (PS) / `bash -n` (bash) — because a suite that only dot-sources `lib/*` and runs
  functions never parses the entry scripts, so a here-string syntax error ships green: `loop.ps1` (the
  primary Windows entrypoint) shipped unrunnable-under-5.1 in the unpushed evaluator commit and a full green
  suite (132/0) never noticed — caught only by an Overnight-Stage-1 dry-run e2e, then netted by the new
  parse-check on both runners.

## Nested context
Larger subsystems may have their own `CLAUDE.md` next to their code (mirrors the one-map-per-package
pattern). When working in a subsystem, read its local map too.
