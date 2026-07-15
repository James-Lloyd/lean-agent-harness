# Cross-vendor S6 — evidence

**Task:** rewrite `/harness-doctor` check 10 for the per-phase `{model,fallback}` schema, and add the
`/harness-init` per-phase model+fallback interview. Docs only; twins byte-identical.

## Files changed (4 = 2 surfaces × 2 twins)
- `.claude/commands/harness-doctor.md` ↔ `plugin/commands/harness-doctor.md` — check 10 rewrite.
- `.claude/commands/harness-init.md` ↔ `plugin/commands/harness-init.md` — Step-3 "Model routing" bullet.

## Check 10 now encodes (§4e of the execution plan), tolerant of the legacy flat + `reviewFallback` shapes:
- (a) value legality — every `model`/`fallback` is a known Claude alias/ID or the literal `codex`.
- (b) session — settings.json `model` == `session.model`, and `session.model` must be Claude (codex = ❌).
- (c) frontmatter — each agent `model:` == its phase's **primary** when Claude, ELSE (primary == codex)
  the phase's **Claude fallback**; the `reviewer`→`fable` branch under `review={codex,fable}`.
- (d) no `codex→codex` fallback (❌).
- (e) codex reachability ⚠️ (not ❌), reported for **every** codex-routed phase (model OR fallback == codex).

## `/harness-init` now: walks each phase choosing model+fallback from a §4a recommended-defaults table,
honoring session-must-be-Claude and no-`codex→codex`, and writes config.models + settings.json +
frontmatter together (frontmatter = primary-when-Claude, else the phase's Claude fallback).

## Verification
- Twin identity (authoritative — git index-blob hash): both surfaces IDENTICAL.
- `run-tests.ps1` → **115 passed / 0 failed**; `fleet-queue-test.ps1` → **22 / 0**.
- Docs-only (no `.sh`/engine touched) → bash suite (104/0) unaffected.

## Review (dogfooded the shipped `review` primary = codex, read-only)
`Invoke-Phase -Mode read-only -Primary codex -Fallback fable` → **Ok=True, Path=codex, UsedFallback=False**.
Verdict: **FIX-THEN-SHIP** — 1 Medium finding: init prose "any codex-routed phase silently runs on its
Claude arm" only holds for a codex-**primary** phase; a Claude-primary + codex-**fallback** phase
(`implement={opus,codex}`) instead loses its safety net and fails closed on a primary usage cap.
**Fixed** by splitting the wording. All other rules (a–e), legacy tolerance, and the `reviewer→fable`
mapping confirmed correct by the reviewer. Full transcript: `review.log`. Prompt: `review-prompt.md`.
Final diff: `staged.diff`.
