<!--
  ROOT CONTEXT MAP — a navigation map, not a manual. Keep it under ~100 lines: it competes for the
  model's attention with the actual task. Point to docs/ and nested CLAUDE.md files; never inline
  full specs or style guides. Every "Project rules" line must trace to a real failure (added via
  /ratchet) — delete rules that stop earning their place. /harness-init fills the {{PLACEHOLDERS}}.
-->

# {{PROJECT_NAME}}

{{ONE_LINE_DESCRIPTION}}

## What this is
- **Domain / market:** {{DOMAIN}}
- **Type:** {{PROJECT_TYPE}}  <!-- greenfield | brownfield (existing code — respect it; see brownfield-safety skill) -->
- **Shape:** {{PROJECT_SHAPE}}  <!-- e.g. "single Node app" or "headless: frontend/ (Next.js) + backend/ (FastAPI)" -->

## Components (the buildable units)
Each has its own stack, gate, and (for non-trivial ones) a nested `CLAUDE.md`. The harness runs each
component's gate in its own directory; see `harness/harness.config.json` → `components`.

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

## How to work here (plan → execute → validate → review → record)
Full contract: [`docs/principles/workflow.md`](docs/principles/workflow.md). `/work` drives one task
through all phases; `/plan`, `/verify`, `/review` run phases individually; `/loop` runs one full
iteration end-to-end. In short:
1. **Study first.** Read the relevant `specs/`, then the code, then `state/fix_plan.md`; work in the
   owning component's directory. **Search the codebase before assuming something isn't implemented.**
2. **One task per iteration** — the highest-priority unfinished item in `state/fix_plan.md`.
3. **Implement fully.** No placeholders, no stubs, no "simple version for now."
4. **Verify — this is the gate.** Run the changed component's gate and the cross-cutting root gate.
   Unit-green is not done: capture **end-to-end evidence** as a user would see it.
5. **Checkpoint.** Commit when green (exception: in the headless loop the RUNNER commits —
   PROMPT.md's no-commit rule wins there). Roll back a red tree, don't patch over it.
6. **Record.** Tick the item in `state/fix_plan.md`; note *why* for the next (amnesiac) loop.
7. **Reset, don't compact.** At task boundaries: `/handoff` then `/clear` — state lives in files and
   the SessionStart hook re-orients a fresh window. `/compact` is the mid-task emergency tool only.

## Verification gate (must pass before "done")
Per component (commands run in its directory), then the cross-cutting root gate. Exact commands live
in `harness/harness.config.json`. For `{{COMPONENT_NAME}}`:
```
{{FORMAT_COMMAND}}
{{LINT_COMMAND}}
{{TYPECHECK_COMMAND}}
{{BUILD_COMMAND}}
{{TEST_COMMAND}}
{{E2E_COMMAND}}
```
(Multi-component projects: one block per component — the config is the source of truth.) The
PostToolUse hook auto-runs the fast subset (format/lint/typecheck) on edit, routed to the component
that owns the changed file — failures come back with the fix in the message.

## Guardrails (hard constraints)
- **Do not** weaken or delete tests to make a build pass. Fix the code or escalate.
- **Do not** run destructive commands (`rm -rf`, `git push --force`, `DROP TABLE`, secrets exfil).
  The PreToolUse hook blocks the obvious ones; don't try to route around it.
- **Do not** edit anything under `specs/` — it is the contract; propose changes to the human.
  (`/plan`, `/onboard`, and `/harness-init` may author NEW specs with the human's approval; rewriting
  an existing spec to make work "pass" is never legitimate.)
- **Escalate ambiguous product decisions** to the human rather than guessing. Ask for the *why*.
- Review code in a **fresh context** (`/review` or the `reviewer` subagent), never self-grade.

## Project rules (the ratchet — grows only from real failures)
<!-- Add entries via /ratchet. Format: "- [YYYY-MM-DD] <rule>  — because <the failure it prevents>" -->
- [2026-07-14] Consult output-sniffing predicates (usage/limit markers) ONLY on a FAILED invocation
  (not-ok / nonzero exit), never to overturn a SUCCESS — the markers are substring-based, so a
  successful write-phase build whose text merely mentions "overloaded"/"quota"/"429" would be reset to
  base and retried on the fallback, silently discarding a good build (S2 review near-miss).
- [2026-07-14] A configured per-phase `fallback` is reached ONLY on a failed invocation, even when the
  resolved `Primary` is '' (inherit ambient) — it is never the happy-path model; a reviewer pinned
  purely via legacy `reviewFallback` (with `review` unset) runs on the ambient model on the happy path
  (S3 review — narrow, disclosed; the migrated `{model,fallback}` config avoids it).
- [2026-07-14] Do not pin a fresh-context judge (`reviewer`/`evaluator` subagent) to a model tier that
  can hit its own usage cap mid-review — when it dies with "reached your <model> limit", re-spawn it
  with a `model:` override to finish — because the S3 review actually failed this way (Fable-pinned
  reviewer knocked out by a Fable-5 usage limit). Subagent-level fallback is a later slice.
- [2026-07-15] Engine code that runs a phase inside a PowerShell `Start-Job` must (a) re-source its
  libs INSIDE the job — a fresh runspace inherits no dot-sourced functions (pass the lib dir via
  `-ArgumentList`; `$PSScriptRoot` differs inside) — and (b) use a quiet (`Out-Null`) output path,
  never `Out-Host`, which is replayed to the parent console at `Receive-Job` and CANNOT be suppressed
  by any stream redirect. Assign the phase result to a var so it doesn't leak into the job output
  stream; emit only the `0/1` exit proxy the caller reads (S4 fleet worker; de-risked live first).
- [2026-07-15] A delegated `isolation: worktree` agent can be checked out on an ANCESTOR of `main`,
  not its tip — before squash-merging, the orchestrator MUST compare the worktree's base to `HEAD`
  and, if they differ, prove every file the agent touched is byte-identical between base and tip
  (`git diff --quiet <base> HEAD -- <file>`); the agent itself must sanity-check its HEAD against the
  task's premises and escalate on mismatch — a stale base silently builds on old content for any file
  that moved, and a blind squash would merge that regression (recurred S7 + sandboxing; both caught).
- [2026-07-15] In a PS double-quoted string/here-string, `$Var` immediately followed by `:` (e.g.
  `failBelow=$FailBelow:`) is a PARSE error under Windows PowerShell 5.1 (`$name:` is scope/drive
  syntax) — the ENTIRE script fails to parse; write `${Var}:`. AND the self-test suite must
  PARSE-CHECK every top-level engine entry script (`[Parser]::ParseFile` / `bash -n`) — a suite that
  only dot-sources `lib/*` ships a here-string syntax error green: `loop.ps1` shipped
  unrunnable-under-5.1 past a fully green suite (132/0), caught only by an Overnight-Stage-1 dry-run.
- [2026-07-26] When correcting a stale fact (path, count, field name) in any prompt surface, grep the
  whole repo for that same fact before closing — it recurs in sibling surfaces (harness-doctor was
  fixed to five hooks while harness-init still said four; caught in fresh-context review).

## Nested context
Larger subsystems may have their own `CLAUDE.md` next to their code. When working in a subsystem,
read its local map too.
