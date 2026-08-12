# Session isolation: one session = one git worktree

_Approved 2026-08-12 (James). Phases 1+2 built together; the heavy coordinator deferred._

## Problem

The standing rule was "one agent session per repo" — two live sessions on one working tree + index
clobber each other. The sharpest failure: a checkpoint `git reset --hard` / `clean -fd` in one
session's loop discards the other's uncommitted edits; a real incident produced "mysterious
deletions" and divergent commits on one branch. We want concurrent sessions to be **safe**, not
merely forbidden.

## What research established (2026-08-12)

Two things make this mostly a config + docs change, not a build:

1. **The runtime layer already assumes worktrees.** `harness/.runs/`, `.checkpoint`, `.budget.json`
   resolve under each worktree's own project root (`git rev-parse --show-toplevel`) and are gitignored,
   so they isolate per worktree naturally; run-ids use an atomic mkdir-mutex. `checkpoint.ps1` already
   recommends running on a dedicated branch or worktree.
2. **Claude Code's native worktree support cooperates.** `.claude/settings.json`, permissions, and
   project-scope plugins all resolve *through* a worktree to the main checkout; `.git/hooks` is shared.
   So the plugin, the five guard hooks, and the local `.git/hooks/pre-commit` privacy guard all apply
   inside a worktree with no per-worktree install (which matters — installing hooks is classifier-gated
   to a human). While in a worktree, Claude Code *blocks* edits/writes/bash targeting the main checkout.

There is **no CLI flag** that auto-worktrees every session (the desktop app does it automatically).
The endorsed pattern is a **CLAUDE.md instruction** that directs the model to `EnterWorktree` at
session start — a SessionStart *hook* cannot do it (hooks are shell; `EnterWorktree` is a model tool).

## The one real problem: the shared task queue

`state/fix_plan.md` + `state/tasks.json` are git-tracked and shared-by-design (one prioritized stack).
A per-session worktree branches from `main`, so both sessions start on the *identical* top task, and
native isolation forbids writing the main checkout's queue from inside a worktree — so a "live shared
queue" fights the design. The fleet's up-front partitioner + serialized merge queue is task-scoped and
single-orchestrator; it does **not** transfer to human-driven, multi-session work.

## Decisions

- **`worktree.baseRef: "fresh"`** (`.claude/settings.json`) — each session branches from origin's
  default (clean tree matching the remote). Chosen over `head` because we PR-and-merge everything, so
  local `main` == `origin/main`, and `fresh` is the more predictable, hygienic start.
- **Embrace the fork; land via PR.** Each session's code *and* its `fix_plan.md`/`tasks.json`/
  `PROGRESS.md` edits land through a PR to `main`. Merging reconciles the state; two PRs ticking the
  *same* `fix_plan.md` lines conflict **visibly** — the safe backstop against a missed claim.
- **Task-claim convention, not a coordinator.** Point each session at a distinct task; its first commit
  **stamps the task line with the branch** (`- [ ] (wip: <branch>) <task>`) so a double-grab is textually
  unique and the two PRs are guaranteed to conflict at merge — a bare identical `[x]` tick would
  3-way-merge silently and both could land (the hole the stamp closes; surfaced in review). For one
  operator running a handful of sessions, disjoint assignment + the branch stamp is the mechanism; a
  pushed-ref lease is the escalation *if* same-task collisions actually happen — ratcheted then, not
  pre-built.

## What shipped

- `.claude/settings.json` — `worktree.baseRef: "fresh"` + a note.
- `CLAUDE.md` — "Session isolation" section (enter a worktree at session start; the claim convention).
- `docs/principles/workflow.md` — "Concurrent sessions" section (claim + PR-landing discipline).
- `plugin/hooks/session-start.{ps1,sh}` — a banner nudge that fires only on the main checkout
  (`--git-dir` == `--git-common-dir`), reminding the session to enter a worktree.
- Memory: the `one-session-per-repo` learning reframed to "one session = one worktree" (the
  guard-hook-self-edit learning is unaffected and kept).

## Deferred (not built)

A cross-worktree claim/lease via a pushed ref, and any serialized merge-back of combined state with a
gate on the merged tree. Only warranted if concurrent sessions on genuinely independent tasks stop
being enough in practice.
