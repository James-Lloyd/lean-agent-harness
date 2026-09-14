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

## Independent validation — 2026-09-14

The VALIDATE verifier ran the complete root component gate exactly once, outside the restricted
Windows sandbox so Git Bash could execute its installed `jq`. The complete scrubbed stdout, exact
command, and exit code are in `root-gate.txt`.

| Sprint-contract criterion | Verdict | Concrete evidence |
|---|---|---|
| PowerShell timeout retains early output, then the exact verdict, excludes post-kill output, and returns failure | MET | `powershell/helper-timeout.log:1-2`; `powershell/test-result.txt:1-2`; targeted assertions are `harness/tests/codex-timeout-test.ps1:86-94` |
| Bash timeout has the equivalent failure-code and ordered-log contract | MET | `bash/helper-timeout.log:1-2`; `bash/test-result.txt:1-2`; targeted assertions are `harness/tests/codex-timeout-test.sh:50-58` |
| Real `loop.ps1` and `loop.sh` route to Codex, record `invoke-error`, restore commit/worktree/file state, and retain the ordered durable transcript | MET | `powershell/loop-ledger.jsonl:1`, `bash/loop-ledger.jsonl:1`; `powershell/loop-result.txt:1-4,18-23`, `bash/loop-result.txt:1-4,8-12`; both `loop-iter-1.log:1-2` artifacts |
| Independent delayed/discarded-capture mutants fail on the early marker while positive controls pass | MET | `mutation/result.json:5-8,14-31`; `mutation/powershell-control.log:2-9`, `mutation/bash-control.log:2-9`; both mutant logs fail the early-marker assertion at `:3` and exit 1 at `:9` |
| Successful and ordinary failing Codex paths remain green; no tests were weakened | MET | Both focused suites report 13/0 (`powershell/test-result.txt:1-2`, `bash/test-result.txt:1-2`); success/failure assertions are `harness/tests/codex-timeout-test.ps1:97-105` and `harness/tests/codex-timeout-test.sh:61-71`; the verifier's diff audit found test changes are additions only (425 added, 0 deleted), and the complete root suites are green at `root-gate.txt:540,1041` |
| All shipped manifest versions agree on the next patch and package validation passes | MET | `mutation/result.json:9-10,34-37`; `mutation/package-validation.log:1-3` |
| Evidence maps every criterion to concrete files and lines | MET | This table plus the focused mappings above; the root-gate command and exit code are `root-gate.txt:1-2` |
| Root gate is green with exact twin counts | MET | `root-gate.txt:540` records PowerShell 441/0; `root-gate.txt:1041` records Bash 434/0; `root-gate.txt:1043` records both twins green |

Overall VALIDATE verdict: **MET — 8/8 sprint-contract criteria.**
