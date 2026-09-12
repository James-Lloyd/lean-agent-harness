# Single-review default — 2026-09-12

## Decision

This repo uses one independent fresh-context reviewer. The active config does not contain
`models.review.second`. The engine retains the optional second-reviewer route for explicit experiments,
but it is not a completion requirement or the recommended default.

The active workflow routing is:

| Workflow phase | Route | Effort |
|---|---|---|
| Plan | `claude-fable-5-1`; fallback `claude-opus-5` | high; fallback high |
| Execute | `claude-opus-5`; no fallback | high |
| Validate | deterministic component + root gates | n/a |
| Review | `claude-fable-5-1`; fallback `claude-opus-5` | high; fallback medium |
| Record | session/orchestrator `claude-fable-5-1` | medium |

Auxiliary routes remain explore/docs = Haiku @ low and evaluate = Fable 5.1 @ high with Opus 5 @ medium fallback.

## User-visible proof

`harness/tests/loop-review-test.ps1` and `.sh` each drive the real loop with a stubbed model dispatcher.
The added single-review scenario proves that one primary SHIP:

- advances to completion and writes the `harness-reviewed` watermark at HEAD;
- records the primary `review` ledger row but no `review-second` row;
- never invokes the configured second-model sentinel; and
- creates no second-review transcript.

Results: PowerShell loop-review 22 passed, 0 failed; Bash loop-review 22 passed, 0 failed.

## Full gate

Command: `node harness/tests/gate.mjs`

- PowerShell self-test: 436 passed, 0 failed.
- Bash self-test: 429 passed, 0 failed.
- Final verdict: `GATE: green (both twins)`.

The first sandboxed invocation could not write the isolated worktree's temporary `.budget.json`; the
same shipped command was rerun with scoped worktree write access and completed green. That was an
execution-environment failure, not a product failure.

## Independent review

A fresh-context reviewer returned FIX-THEN-SHIP with two blockers and one should-fix relevant to closure:

- the latest `state/PROGRESS.md` entry still claimed cross-vendor second-review routing was on;
- harness-doctor still described that optional route as the recommended first Codex use; and
- the active-config assertion accepted `second: null` instead of requiring exact key absence.

All three were corrected. The generic read-only Codex permission remains because it is required when
Codex is deliberately selected as the primary reviewer under the headless Claude orchestrator; it does
not activate a second review. The follow-up fresh-context verdict was SHIP with no remaining blockers,
should-fixes, or nits.
