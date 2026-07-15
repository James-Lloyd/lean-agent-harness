# Evidence — Cross-vendor S2 (usage-limit predicate + generalized codex lib)

Task: fix_plan "Cross-vendor S2". Plan: `docs/execution-plans/2026-07-14-cross-vendor-per-phase-model-routing.md` §4c / §7.2.
Captured 2026-07-14 on the staged (HEAD 729207f + staged S2) tree, verified independently by the orchestrator (not the generator's self-report).

## Gate — all four suites GREEN

| Suite | Result |
|-------|--------|
| PowerShell `run-tests.ps1` (authoritative) | **99 passed, 0 failed** (baseline 80 + 19 new) |
| PowerShell `fleet-queue-test.ps1` | **16 passed, 0 failed** |
| bash `run-tests.sh` (jq 1.7.1 on PATH) | **90 passed, 0 failed** (baseline 76 + 14 new) |
| bash `fleet-queue-test.sh` | **16 passed, 0 failed** |

## Twins byte-identical (E1 duplication invariant)

`git diff --no-index harness/lib/<f> plugin/engine/lib/<f>` empty for all six:
gate.ps1, gate.sh, invoke-codex.ps1, invoke-codex.sh, review-codex.ps1, review-codex.sh.

## Acceptance criteria → evidence

- **`Test-UsageLimitError($output,$exitCode)` in `lib/gate.*` (+twins), vendor-neutral markers, with tests** →
  `usage_limit_error` in gate.sh; markers `usage limit / rate limit / quota / overloaded / too many requests / HTTP 429`
  (429 scoped to http/status/error/code context to avoid false positives). Positive+negative tests in both runners.
- **`lib/invoke-codex.*` renamed from review-codex, back-compat shim** → invoke-codex.{ps1,sh} hold the API; review-codex.{ps1,sh}
  are shims that `source`/dot the new file. loop.ps1/loop.sh/fleet.* untouched — they source the shim and still call
  `Invoke-CodexReview`/`codex_review` (read-only wrappers). No wiring changed (S3 does that).
- **`-Mode read-only|workspace-write` selecting the sandbox flag; arg assembly tested for BOTH modes via a pure builder** →
  `Get-CodexArgs`/`codex_args` pure builder; tests assert read-only→`--sandbox read-only`, workspace-write→`--sandbox workspace-write`,
  shared `--ask-for-approval never`, global flags before `exec`, model/effort passthrough, no-model omits `-m`.
- **Both runners green** → see table.

## Notes
- No behavior change to any existing call site (the shim preserves every prior entry point).
- bash suite requires jq on PATH via POSIX path form (`/c/...`, not `C:/...`) — git-bash PATH lookup only searches POSIX-form entries.
