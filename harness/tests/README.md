# Harness self-tests

The harness tests its own fiddly logic — because "test the harness" is one of the principles it preaches
(Fowler), and because this logic (the multi-component gate router, the destructive-command denylist, the
budget, the plan counter) is exactly the kind of code that breaks silently. These tests have already
caught real bugs (a denylist delimiter collision, a `grep -c` double-count).

Self-contained — no Pester/bats dependency — so they run anywhere, including CI.

```bash
# Windows (PowerShell)
powershell -NoProfile -ExecutionPolicy Bypass -File harness/tests/run-tests.ps1

# Linux / macOS (bash; jq-dependent gate tests need jq, else they're skipped)
bash harness/tests/run-tests.sh
```

Both exit non-zero on any failure. A ready-to-activate CI workflow is in [`ci/`](../../ci/) — copy it
into `.github/workflows/` to run these on every push/PR.

## What's covered
- **Gate**: StrictMode-safe tolerance of gate objects with missing keys (a `/harness-prune` hazard);
  pass/fail; multi-component execution + failure attribution (`component:step`).
- **Denylist hook**: blocks the bypass variants the review found (`rm -fr`, `git push -f`,
  `find -delete`, `git reset --hard <sha>`, secret reads); allows normal commands.
- **Budget**: per-run reset (it was a lifetime counter).
- **Plan counter**: `grep -c` emits a single clean count for empty and non-empty plans.

When `/ratchet` traces a failure to harness logic, add a case here so it can't regress.
