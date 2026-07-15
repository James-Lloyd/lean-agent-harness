# Fleet record-amend hardening — evidence

**Task (fix_plan):** Fleet record-amend failure leaves tasks.json/PROGRESS staged; a later queue
entry's gate-red reset silently discards them while the ledger says merged — done when: pending
record is stashed/written to the run dir instead of left staged (re-review finding 2, non-blocking).

## What changed
`plugin/engine/fleet.{ps1,sh}` (sole engine source, twin logic): on a failed `git commit --amend`
(the step that folds state/tasks.json + state/PROGRESS.md into the merge commit), instead of leaving
the files staged, the runner now:
  1. copies the intended record to `harness/.runs/<runId>/pending-record-<id>/{tasks.json,PROGRESS.md}`
     (under harness/.runs — gitignored, so BOTH `reset --hard` and `clean -fd` skip it),
  2. `git checkout HEAD -- state/tasks.json state/PROGRESS.md` so nothing is left staged for a later
     queue entry's reset to silently discard,
  3. writes a `record-deferred` ledger line so the morning routine can reconcile against `merged`.

## End-to-end evidence (live-fire, both runners)
New scenario 2 in `harness/tests/fleet-queue-test.{ps1,sh}` live-fires the REAL fleet through the exact
bug path: a pre-commit hook fails the runner's main-tree commits, so T-OK's record amend fails
(deferred to the run dir) and T-BOOM's merge commit fails → triggers the `reset --hard`+`clean -fd`
that used to eat T-OK's record. Asserts the pending record lands in the run dir, the ledger says both
`merged` and `record-deferred`, the working tree is NOT left staged, and the record SURVIVES T-BOOM's
reset.

Results:
- fleet-queue-test.ps1: 31 passed, 0 failed  (was 22; +9 new)
- fleet-queue-test.sh : 31 passed, 0 failed  (was 22; +9 new)
- run-tests.ps1 : 143 passed, 0 failed  (unchanged; engine parse-check confirms fleet.ps1 parses)
- run-tests.sh  : 134 passed, 0 failed  (unchanged; engine parse-check confirms fleet.sh parses)

## Review
Fresh-context reviewer subagent (the fable-pinned run hit a Fable-5 usage cap mid-review → re-spawned
with model:opus per the CLAUDE.md ratchet). Verdict: **SHIP** — verified the run dir is reset-proof
(`.gitignore` + reset/clean semantics), the copy-before-restore ordering is correct, the happy path is
untouched, and the new scenario genuinely exercises the discard path (not a tautology). One **Low**
parity finding, fixed: the sh twin's `git checkout HEAD -- …` runs under `set -euo pipefail`, so it
needed `|| true` (the graceful-degradation branch must not abort the whole queue on a nonzero restore;
the ps1 twin's `_Git` already swallows the exit code). Re-ran bash after the fix: fleet-queue 31/0,
run-tests 134/0.
