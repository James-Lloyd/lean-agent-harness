# Evidence — activate GitHub Actions self-test CI

**Task:** Add CI (GitHub Actions) that runs `run-tests.{ps1,sh}` + `fleet-queue-test.{ps1,sh}` with jq on
every push. Done when the bash `--project-root` path is exercised automatically (previously only when jq
was installed by hand); closes the review's "evidence cited CI that doesn't exist" finding.

## What shipped
- `.github/workflows/harness-selftest.yml` — activated copy of the reviewed template
  `ci/github-harness-selftest.yml`. Diff is **header-only**; all 3 jobs / all steps byte-identical.
- `ci/README.md` — added a "Status: activated" note (points back to `ci/` as the template source of truth).

## Why activation satisfies "the bash --project-root path is exercised automatically"
The Linux job (`selftest-linux`) installs jq, then runs:
- `bash harness/tests/run-tests.sh` → at its tail calls `migrate-test.sh`, which invokes
  `engine/migrate.sh --project-root <tmp>` (3×: report, --apply no-force, --apply --replace-runners --force).
- `bash harness/tests/fleet-queue-test.sh` → drives `harness/fleet.sh` (the thin wrapper), which
  `exec bash "$ENGINE/fleet.sh" --project-root "$PROJECT_ROOT" …`.
Both require jq, so before this CI they only ran when a human put jq on PATH. Now they run on every push/PR.
`run-tests.sh` defaults `HARNESS_ENGINE` to the checked-out `$REPO_ROOT/plugin/engine`, and
`fleet-queue-test.sh` sets `HARNESS_ENGINE` itself — so no CI env wiring is required.

## Local proof — every command the CI runs is green (jq 1.8.2 on PATH)

### selftest-linux (ubuntu-latest)
```
$ bash harness/tests/run-tests.sh
...
RESULT: 103 passed, 0 failed

$ bash harness/tests/fleet-queue-test.sh
...
FLEET QUEUE RESULT: 22 passed, 0 failed

$ for f in $(find . -name '*.sh' -not -path './.git/*'); do bash -n "$f"; done
all .sh parse OK
```
(matches the handoff baseline: bash 103/0, fleet-queue 22/0)

### Windows jobs (selftest-windows / selftest-windows-ps51)
Run `harness/tests/run-tests.ps1` (pwsh + PowerShell 5.1) and `fleet-queue-test.ps1` (5.1). Handoff
baseline for these on this machine: **PS 112/0, fleet-queue PS 22/0**. Not re-run in this evidence pass
(no source touched in either suite's inputs; CI executes them on GitHub's windows-latest runners).

### Workflow file validity
```
activated YAML valid. jobs: ['selftest-linux', 'selftest-windows', 'selftest-windows-ps51']
triggers: push / pull_request / workflow_dispatch
diff ci/github-harness-selftest.yml .github/workflows/harness-selftest.yml  → header comment only
```

## Remaining (human step — not agent-doable)
The workflow file needs a token carrying the GitHub `workflow` OAuth scope (or the web UI) to push —
`gh auth refresh -h github.com -s workflow` first, or add via GitHub UI. The green **CI run on GitHub**
(the final e2e proof) can only be observed after that push. All commands the run will execute are proven
green locally above.

## Fresh-context review (Phase 4)
Dispatched the shipped review primary = **codex read-only** via `Invoke-Phase`
(`Ok=True, Path=codex, UsedFallback=False`) — log: `review.log`, prompt: `review-prompt.txt`.
Verdict: **FIX-THEN-SHIP**, 1 finding:
- The `push` trigger was filtered to `branches: [main]`, but the criterion is "on every push". A push to
  a feature branch with no open PR wouldn't run CI.

**Fix applied** (both the template `ci/…` and the activated `.github/workflows/…`, kept in sync): removed
the `branches: [main]` filter so `push:` fires on all branches; kept `pull_request:` (covers fork PRs,
whose push events don't run in the base repo). Both files re-validated: parse OK, `push` filter = null
(all branches), jobs unchanged, diff still header-comment-only. The trigger change touches no test suite,
so the local green proof above stands. → SHIP.
