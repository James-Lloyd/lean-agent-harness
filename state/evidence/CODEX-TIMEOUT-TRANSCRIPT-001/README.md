# CODEX-TIMEOUT-TRANSCRIPT-001 evidence

All runs use local stubs, a one-second model watchdog, temporary git repositories, and no network or
model tokens. Machine and temporary paths in captured loop output are scrubbed as `<HOME>`, `<REPO>`,
and `<TMP>`.

## Timeout transcript durability

- PowerShell helper: `powershell/helper-timeout.log:1-2` records `partial-before-timeout` immediately
  before the exact watchdog verdict; `powershell/test-result.txt:1-2` records the final pass count.
- Bash helper: `bash/helper-timeout.log:1-2` records the identical ordered contract;
  `bash/test-result.txt:1-2` records the final pass count.
- Both helper logs contain only those two lines, proving the scheduled `output-after-kill` marker was
  not emitted after the watchdog.

## Real loop rollback

- `powershell/loop-ledger.jsonl:1` and `bash/loop-ledger.jsonl:1` record `invoke-error`,
  `reason=invoke-failed`, `path=codex`, and no fallback.
- `powershell/loop-result.txt:1-4` and `bash/loop-result.txt:1-4` show identical BASE/HEAD commits, an
  empty status, and the tracked file restored to `original`.
- `powershell/loop-iter-1.log:1-2` and `bash/loop-iter-1.log:1-2` retain the early marker followed by
  the watchdog verdict inside the reset-proof `.runs/` iteration log.

## Mutation and package contract

- `mutation/result.json:5-10` records both positive controls passing, both independent mutants being
  rejected, package validation passing, and manifest parity passing.
- `mutation/powershell-mutant.log:1-9` and `mutation/bash-mutant.log:1-9` show each delayed/discarded
  transcript mutant fail specifically at `timeout log keeps partial-before-timeout` with exit 1.
- `mutation/result.json:34-37` records `0.5.1` for the portable, Claude, and Codex manifests.
- `mutation/package-validation.log:1-3` records the real package validator result and exit 0.

## Commands

```text
powershell -NoProfile -ExecutionPolicy Bypass -File harness/tests/codex-timeout-test.ps1 -EvidenceDir state/evidence/CODEX-TIMEOUT-TRANSCRIPT-001/powershell
CODEX_TIMEOUT_EVIDENCE_DIR=/c/.../state/evidence/CODEX-TIMEOUT-TRANSCRIPT-001/bash bash harness/tests/codex-timeout-test.sh
node harness/tests/codex-timeout-mutation.mjs --out state/evidence/CODEX-TIMEOUT-TRANSCRIPT-001/mutation
node plugin/scripts/validate-openai-plugin.mjs
node harness/tests/gate.mjs
```

The final root-gate result is recorded separately after the full dual-twin run completes.
