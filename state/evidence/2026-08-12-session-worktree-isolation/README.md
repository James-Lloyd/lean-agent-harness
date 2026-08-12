# Evidence — one session = one git worktree

User ask: *"update the harness so one session is one worktree, to prevent friction."* Researched
first (two subagents: harness-internals + native Claude Code), then built Phases 1+2; heavy
coordinator deferred. Design record: `docs/execution-plans/2026-08-12-session-worktree-isolation.md`.

## What changed
- `.claude/settings.json` — `worktree.baseRef: "fresh"` (each session's worktree branches from
  origin's default) + a note.
- `CLAUDE.md` — "Session isolation — one session = one worktree" section (the lever that makes the
  model `EnterWorktree` at session start) + the task-claim convention.
- `docs/principles/workflow.md` — "Concurrent sessions" section (claim + PR-landing discipline).
- `plugin/hooks/session-start.{ps1,sh}` — a banner nudge that fires ONLY on the main checkout,
  detected by `--git-dir` == `--git-common-dir` (they differ inside a linked worktree).

## Why this is mostly config+docs (from the research)
- Runtime already worktree-safe: `harness/.runs`, `.checkpoint`, `.budget.json` resolve under each
  worktree's own project root and are gitignored; run-ids use an atomic mkdir-mutex.
- Native Claude Code resolves `.claude/settings.json`, permissions, plugins, and `.git/hooks` through
  a worktree to the main checkout, and BLOCKS edits to the main checkout while in a worktree. So the
  plugin, guard hooks, and the pre-commit privacy guard all apply inside a worktree for free.
- No CLI flag auto-worktrees every session (the desktop app does). The endorsed pattern is a CLAUDE.md
  instruction → model calls `EnterWorktree`; a SessionStart *hook* cannot (hooks are shell, the tool is
  model-driven) — hence the nudge, not an auto-enter.

## Verification
- `run-tests-ps.txt` — PowerShell 5.1: **234 / 0** (unchanged — no engine logic touched).
- `run-tests-bash.txt` — bash: **224 / 0**.
- `hook-nudge-test.txt` — the nudge detection, both directions:
  - MAIN CHECKOUT (branch, not a linked worktree): **1** nudge line (fires).
  - INSIDE A LINKED WORKTREE (`git worktree add`): **0** nudge lines (correctly silent).
  Confirms `--git-dir` == `--git-common-dir` distinguishes the main checkout from a worktree on the
  bash twin; the PS twin uses the identical logic.

(Suite logs carry absolute paths from the gate's own failure-path tests; normalized to `<repo>`/
`<home>` per the repo's privacy discipline before commit.)

## Deferred
A cross-worktree claim/lease via a pushed ref + serialized merge-back of combined state — only if
same-task collisions actually happen in practice.
