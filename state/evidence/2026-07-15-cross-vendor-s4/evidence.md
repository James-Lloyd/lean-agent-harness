# Cross-vendor S4 — fleet workers → shared dispatcher (evidence)

Date: 2026-07-15
Task: route fleet workers (`fleet.ps1`/`fleet.sh` + `plugin/engine/` twins) through the shared
`Invoke-Phase`/`invoke_phase` dispatcher (mode = workspace-write) so a fleet worker gets the loop's
primary→fallback behavior; add a `-Quiet` switch to `lib/dispatch.ps1` (Start-Job transcript
suppression); add stub-fallback + dry-run assertions to `fleet-queue-test.{ps1,sh}`.

## Worktree note
This worktree branch was based on `0d852c0` (pre cross-vendor S1–S3). Fast-forwarded it to `main`
(`245b723`) — which contains the S3 dispatcher this task builds on — via `git merge --ff-only main`
(clean tree, pure fast-forward). All work is on top of that.

## Files changed (9)
- harness/lib/dispatch.ps1        — `-Quiet` switch on Invoke-ClaudePhase + Invoke-Phase (Out-Host→Out-Null)
- harness/fleet.ps1               — source dispatcher libs; resolve implementFallback + codexCfg; worker Start-Job re-sources libs and calls Invoke-Phase -Quiet; dry-run echo mentions fallback
- harness/fleet.sh                — source dispatcher libs; resolve IMPLEMENT_FALLBACK + CODEX_*; worker subshell calls invoke_phase directly; dry-run echo mentions fallback
- plugin/engine/lib/dispatch.ps1  — byte-identical twin
- plugin/engine/fleet.ps1         — byte-identical twin
- plugin/engine/fleet.sh          — byte-identical twin
- harness/tests/fleet-queue-test.ps1 — T-FB fallback task + model-aware stub + fallback + dry-run assertions
- harness/tests/fleet-queue-test.sh  — same, bash mirror
- harness/tests/run-tests.ps1     — one focused `-Quiet` unit case (case 7) on the dispatch block

`harness/lib/dispatch.sh` intentionally UNCHANGED (bash subshells inherit sourced functions; no
host-noise issue), so its twin stays byte-identical.

## Gate results (all 0 failed)
PowerShell (authoritative):
- `powershell -NoProfile -File harness/tests/run-tests.ps1`        → RESULT: 115 passed, 0 failed  (113 baseline + 2 new `-Quiet`)
- `powershell -NoProfile -File harness/tests/fleet-queue-test.ps1` → FLEET QUEUE RESULT: 22 passed, 0 failed  (16 baseline + 3 fallback + 3 dry-run)

Bash (jq 1.7.1 supplied on PATH from session scratchpad; POSIX path form):
- `bash harness/tests/run-tests.sh`        → RESULT: 104 passed, 0 failed  (baseline; no bash `-Quiet` concept, run-tests.sh untouched)
- `bash harness/tests/fleet-queue-test.sh` → FLEET QUEUE RESULT: 22 passed, 0 failed  (16 baseline + 3 fallback + 3 dry-run)

## New end-to-end assertions (both runners)
Stub-fallback: config `models.implement = {model:"primary-x", fallback:"fallback-x"}`; the T-FB worker's
PRIMARY model emits a usage-limit marker + nonzero exit, the dispatcher resets the worktree to the batch
base and retries on the FALLBACK model, which writes `fb/out.txt` with content `built by fallback`. The
worker's output MERGES and is recorded `validated`. (Content check proves the fallback arm ran, not just
that some model built the file.)
Dry-run: `-DryRun`/`--dry-run` runs a sentinel stub that would write a file if invoked; asserts the
sentinel is absent (no model invoked) and that fleet branch/worktree counts are unchanged (no leftovers),
while still exercising real select+add+cleanup (T-CRASH/T-EVIL remain todo after the live-fire).

## Twin parity (git diff --no-index — all EMPTY)
- harness/fleet.ps1        vs plugin/engine/fleet.ps1        → EMPTY
- harness/fleet.sh         vs plugin/engine/fleet.sh         → EMPTY
- harness/lib/dispatch.ps1 vs plugin/engine/lib/dispatch.ps1 → EMPTY
- harness/lib/dispatch.sh  vs plugin/engine/lib/dispatch.sh  → EMPTY (unchanged)
`.ps1` twins retain the UTF-8 BOM (`ef bb bf`). `.sh` = LF.
