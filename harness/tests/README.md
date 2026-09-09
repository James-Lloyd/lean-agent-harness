# Harness self-tests

The harness tests its own fiddly logic — because "test the harness" is one of the principles it preaches
(Fowler), and because this logic (the multi-component gate router, the destructive-command denylist, the
budget, the plan counter) is exactly the kind of code that breaks silently. These tests have already
caught real bugs (a denylist delimiter collision, a `grep -c` double-count).

Self-contained — no Pester/bats dependency — so they run anywhere, including CI.

```bash
# Both twins, either platform — this is what the repo's own gate runs
node harness/tests/gate.mjs

# …or one twin directly:
powershell -NoProfile -ExecutionPolicy Bypass -File harness/tests/run-tests.ps1   # Windows
bash harness/tests/run-tests.sh                                                   # Linux / macOS (needs jq)
```

`gate.mjs` is this repo's wired gate step (`harness/harness.config.json` →
`components[0].gate.test`), so `/verify` and the loop's `autoRollbackOnRed` grade the real suites
rather than an empty command set. It is JavaScript rather than a `.sh`/`.ps1` twin pair because a
gate step is **one string** that the engine hands to `cmd /c` on Windows and `bash -lc` on Unix:
cmd.exe rejects a forward-slash script path, `powershell` doesn't exist on Linux, and — measured —
under `cmd /c` a bare `bash` resolves to **WSL's** `C:\Windows\System32\bash.exe`, a different OS
entirely (`state/evidence/2026-09-09-wire-repo-gate/`). `node` is on PATH under both shells and is
already a harness dependency (`plugin/hooks/run.mjs`). It runs the platform's native twin
**fail-closed**; on Windows it adds the `.sh` twin when Git Bash can be found on disk (never by a
`PATH` lookup). On POSIX it deliberately does *not* attempt the `.ps1` twin — a decision, not a
measurement: that suite does pick its host (`pwsh` vs `powershell`), but nothing has ever run it off
Windows, so a red from it would say nothing about the change under test.

Any ungraded twin prints a loud `UNGRADED TWIN` banner. Note where that banner is actually seen: the
engine's gate step prints a command's output **only when it exits non-zero**, so under
`loop`/`fleet` a green half-graded run looks like any other green. Set `HARNESS_GATE_STRICT=1` to
make an ungraded twin exit non-zero instead.

Both exit non-zero on any failure. A ready-to-activate CI workflow is in [`ci/`](../../ci/) — copy it
into `.github/workflows/` to run these on every push/PR.

## What's covered
- **Gate**: StrictMode-safe tolerance of gate objects with missing keys (a `/harness-prune` hazard);
  pass/fail; multi-component execution + failure attribution (`component:step`).
- **Denylist hook**: blocks the bypass variants the review found (`rm -fr`, `git push -f`,
  `find -delete`, `git reset --hard <sha>`, secret reads); allows normal commands.
- **Budget**: per-run reset (it was a lifetime counter); run-id allocation claims its dir atomically.
- **Plan counter**: `grep -c` emits a single clean count for empty and non-empty plans.
- **Model routing**: `config.models.<phase>` resolution, incl. trimmed-config inherit behavior.
- **Codex reviewer**: the availability probe that drives the claude fallback.
- **Gate wiring**: this repo's own `components[0].gate.test` is non-null, launches via `node` (the
  only cross-shell spelling), names a script that exists, and `gate.mjs` parses and keeps its
  Windows bash lookup off `PATH` — so the wiring can't quietly revert to all-null.
- **Fleet**: ownership-overlap + batch selection (unit, in `run-tests.*`), and a separate
  **merge-queue integration test** (`fleet-queue-test.ps1` / `.sh`) that live-fires the fleet runner
  in a throwaway repo with a stub claude (`HARNESS_CLAUDE_CMD`) and asserts merge, recording, cleanup,
  and the tamper-park guardrail end-to-end.

When `/ratchet` traces a failure to harness logic, add a case here so it can't regress.
