# Codex hook activation freshness ratchet

## Failure class

A trusted, harness-owned `~/.codex/hooks.json` can remain visible and active in `/hooks` after a
plugin update while its absolute command still points at a deleted cache version. Displayed hook
state is therefore not sufficient evidence that the guard can execute.

## End-to-end proof

Run:

```text
node state/evidence/CODEX-HOOK-ACTIVATION-RATCHET-001/run-checks.mjs
node state/evidence/CODEX-HOOK-ACTIVATION-RATCHET-001/capture-gate.mjs
```

The first command drives the real `install-codex-hooks.mjs` CLI against a disposable user manifest.
It installs and checks a fresh manifest, rewrites one command to a cache target that does not exist,
observes non-zero plus `STALE`, reactivates, and observes fresh again. The result is 13 passed / 0
failed (`result.json:4-5`); the stale and repaired outcomes are recorded at `result.json:18-35`.

The same result proves the doctor contract, both shell regression pins, three removal mutants, and
all three 0.5.2 manifest surfaces (`result.json:38-70`). The package validator independently performs
the stale-to-fresh transition in `plugin/scripts/validate-openai-plugin.mjs:145-169`.

The second command runs the configured root gate and scrubs private paths before writing its output.
The transcript records PowerShell 446/0 at `gate.txt:543`, Bash 439/0 at `gate.txt:1051`, and the
combined green verdict at `gate.txt:1053`.

## Acceptance map

- Doctor runs the installed activation check for a harness-owned user manifest, independently of
  model routing: `plugin/commands/harness-doctor.md:260-275`.
- Stale is red, the exact activation repair is named, and foreign ownership is not overwritten:
  `plugin/commands/harness-doctor.md:269-280`.
- PowerShell and Bash pin the same four clauses: `harness/tests/run-tests.ps1:1298-1301` and
  `harness/tests/run-tests.sh:1262-1265`.
- The disposable real-CLI transition and mutants pass: `result.json:18-65`.
- Plugin versions agree at 0.5.2: `result.json:68-70`.
- Full root gate is green in both twins: `gate.txt:543`, `gate.txt:1051`, `gate.txt:1053`.
- Evidence privacy is fail-closed and idempotent: `capture-gate.mjs:38-73` and
  `privacy-sweep.json:2-5`. An independent `git grep --untracked -a` account-name sweep returned
  zero matches after capture.

## Review

Fresh-context review round 1 returned FIX-THEN-SHIP because the first gate transcript exposed local
paths. The capture path was made self-scrubbing and fail-closed, the transcript was regenerated, and
the independent binary-inclusive sweep returned zero matches. Re-review returned SHIP with no
remaining findings (`review.txt`).

## Scope note

The machine's currently installed plugin remains 0.5.1 and its activated hooks are fresh. This branch
ships the doctor ratchet as plugin 0.5.2; after that package is installed, `$harness-codex-activate`
must be run again so the user manifest points at the new cache version.
