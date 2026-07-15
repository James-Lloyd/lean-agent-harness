# Cross-vendor S7 — docs + prune (evidence)

**Date:** 2026-07-15   **Baseline before:** `0ba6bb8` (PS 115 / bash 104 / fleet-queue 22)

## What shipped
Retired the dead `review-codex` back-compat shim (introduced S2 to bridge the rename `review-codex.* → invoke-codex.*`), plus docs.

Prune (18 files, +12 / −70):
- Repointed 4 `source .../lib/review-codex.*` → `lib/invoke-codex.*` in `loop.{sh,ps1}` + `fleet.{sh,ps1}` (× harness/ and plugin/engine/ twins = 8 edits).
- Deleted the 4 shim files `{harness,plugin/engine}/lib/review-codex.{sh,ps1}`.
- Dropped the read-only wrapper functions `codex_review` (bash) / `Invoke-CodexReview` (PS) + their header mentions from `invoke-codex.*` (× twins = 4 files).
- Trimmed the 3 shim-specific test assertions: `run-tests.sh` −1 (shim re-exposes API), `run-tests.ps1` −2 (shim loads Test-CodexAvailable/Invoke-Codex) −1 (Invoke-CodexReview exists).

Docs: execution-plan `2026-07-14-cross-vendor-per-phase-model-routing.md` gained §9 "As-built"; AGENT_NOTES + PROGRESS learnings appended.

## Why it was safe
No live caller reached the wrappers. The review path runs `loop`/`fleet` → `lib/dispatch.*` (`invoke_phase`/`Invoke-Phase`) → `invoke_codex`/`Invoke-Codex` **directly**. The `source review-codex.*` lines only pulled the codex API into scope, and the shim just re-sourced `invoke-codex.*` — so repointing at `invoke-codex.*` is behaviour-preserving. Post-edit `git grep 'review-codex|Invoke-CodexReview|codex_review'` over `harness/` + `plugin/engine/` = **0 hits**.

## Gate (all green)
| Suite | Result |
|-------|--------|
| `run-tests.ps1` | **112 / 0** (was 115; −3 shim assertions) |
| `run-tests.sh` (jq 1.8.2) | **103 / 0** (was 104; −1 shim assertion) |
| `fleet-queue-test.ps1` | **22 / 0** |
| `fleet-queue-test.sh` | **22 / 0** |
| `bash -n` (7 edited .sh) | clean |
| Twin identity (git blob hash, 6 engine pairs) | identical |

## Review (fresh context, cross-vendor)
Dispatched through the shipped `review` primary = **codex read-only** via `Invoke-Phase -Mode read-only`
(`Resolve-PhaseModel/Fallback` from config): **Ok=True, Path=codex, UsedFallback=False → VERDICT: SHIP**, no findings.
The reviewer independently confirmed: no stranded caller, source ordering preserved (invoke-codex before dispatch, incl. the PS fleet job runspace), twins identical, tests still source invoke-codex directly.
This run doubles as **e2e evidence**: the pruned `invoke-codex` lib executed end-to-end through the real dispatcher. See `review.log`.

## Note (process)
The `generator` subagent (`isolation: worktree`) was handed a worktree based on a **stale** commit `0d852c0` (~16 commits behind `main`, pre-S2). Every task premise was false against that HEAD; it correctly detected the mismatch, reverted cleanly, and escalated. Recovery: the prune was implemented **inline in the main tree** at `0ba6bb8`. Logged as an AGENT_NOTES learning + a ratchet candidate.

## Artifacts
- `diffstat.txt`, `staged.diff` — the change
- `review-prompt.txt`, `review-input.txt`, `review.log` — the codex read-only review
