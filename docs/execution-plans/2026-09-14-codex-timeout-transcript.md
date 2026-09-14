# CODEX-TIMEOUT-TRANSCRIPT-001 — preserve watchdog-killed Codex output

- Status: planned
- Task: `CODEX-TIMEOUT-TRANSCRIPT-001`
- Component: root (shared Claude/Codex engine)
- Baseline at `cb8d652`: PowerShell 440/0, Bash 433/0 via `node harness/tests/gate.mjs`

## Why

The 2026-09-12 overnight preflight proved that the loop selects Codex, times out fail-closed, and
rolls back. It also exposed that `Invoke-Codex` on PowerShell buffers the child transcript inside a
background job. When the watchdog stops that job, the buffered output is discarded and the phase log
is replaced by the watchdog sentence. The Bash twin already streams the child directly to its phase
log and appends the watchdog sentence.

## Sprint contract: timeout transcript durability

### Scope (this sprint)

- Make `plugin/engine/lib/invoke-codex.ps1` write combined Codex stdout/stderr to `LogPath` while the
  background job is running, then append the existing watchdog verdict after a timeout.
- Preserve the public `Invoke-Codex` result shape and all success, failure, sandbox, approval-policy,
  model, effort, and final-message behavior.
- Pin the same observable timeout contract in `plugin/engine/lib/invoke-codex.sh`; change Bash behavior
  only if the executable regression exposes a parity gap.
- Add deterministic stub coverage and a stub-driven loop proof. Bump every shipped plugin manifest
  that carries the package version in the same change.

### Out of scope

- Changing `models.codex.timeoutSeconds`, removing the watchdog, or changing fallback policy.
- Preventing the documented Windows orphan-child possibility after `Stop-Job`.
- Changing the later task's in-model verification policy or the overnight guide.
- Editing immutable `specs/`, invoking a paid model, or refreshing machine-wide plugin caches.

### Definition of done (every box must be ticked)

- [ ] A PowerShell stub emits `partial-before-timeout`, remains alive past a one-second watchdog, and
      `Invoke-Codex` returns `Ok=false`; its phase log contains the early marker followed by the exact
      watchdog verdict and excludes output scheduled after the kill.
- [ ] The equivalent Bash stub returns the watchdog failure code and its phase log has the same
      ordered early-output-plus-verdict contract.
- [ ] Stub-driven real `loop.ps1` and `loop.sh` invocations route implement to Codex, create a tracked
      worktree change before timing out, record `invoke-error`, restore the exact pre-iteration commit,
      and retain both the early marker and watchdog verdict in the durable iteration log.
- [ ] A mutation check reintroduces delayed/discarded transcript capture independently in each twin;
      the targeted regression fails for the missing early marker while its positive controls pass.
- [ ] Existing successful and ordinary failing Codex paths remain green, and no tests are weakened.
- [ ] All plugin version surfaces agree on the next patch version and package validation passes.
- [ ] End-to-end evidence under `state/evidence/CODEX-TIMEOUT-TRANSCRIPT-001/` maps each criterion to
      concrete result files and line numbers.
- [ ] Root gate green: `node harness/tests/gate.mjs` reports both twin counts with zero failures.

### How success is verified

1. Run the new timeout regression directly under Windows PowerShell 5.1 and Git Bash. Each test uses
   an injected local stub, a one-second timeout, and no network or model tokens.
2. Run the stub-driven loop proof for both engine twins and inspect commit identity, ledger result,
   worktree cleanliness, and iteration-log ordering.
3. Run the mutation script against temporary copies of both implementations. Require the unmodified
   controls to pass and both delayed-capture mutants to fail specifically on transcript preservation.
4. Run `node plugin/scripts/validate-openai-plugin.mjs` and grep all plugin manifests for version
   agreement.
5. Run `node harness/tests/gate.mjs` outside the restricted sandbox on this Windows host, because Git
   Bash's installed `jq` executable is inaccessible inside the sandbox.

## Implementation brief (fresh-context handoff)

1. Before changing engine code, add the deterministic timeout regression. Confirm the PowerShell arm
   fails on the missing early marker and the Bash arm passes, characterizing the existing asymmetry.
2. In `Invoke-Codex`, pass `LogPath` into the `Start-Job` script block and redirect the native
   invocation's combined output to that file inside the job. The job must emit only its exit proxy.
   On normal completion, read the durable log to populate `Output`; on timeout, stop the job and append
   the watchdog sentence without replacing prior bytes. Keep no-BOM prompt handling and final-message
   precedence unchanged.
3. Reconcile comments and regression coverage in `invoke-codex.sh`. Its `timeout ... > "$log" 2>&1`
   plus append is the intended twin behavior.
4. Build the real-loop stub proof around the existing synthetic loop-test conventions. The stub must
   answer `login status`, mutate only its temporary repo, flush an early log marker, and sleep past the
   watchdog. Assert rollback and the durable ledger/log, not merely the helper's return value.
5. Add a temporary-copy mutation runner for both twins, retain its outputs as evidence, bump the patch
   version across `plugin/plugin.json`, `.claude-plugin/plugin.json`, and `.codex-plugin/plugin.json`,
   and update generated-version assertions only where validation proves they are package-coupled.

## Files and interfaces

- Behavior: `plugin/engine/lib/invoke-codex.ps1`, `plugin/engine/lib/invoke-codex.sh`
- Regression/e2e: `harness/tests/` (new focused timeout twins plus root-suite wiring if needed)
- Package contract: `plugin/plugin.json`, `plugin/.claude-plugin/plugin.json`,
  `plugin/.codex-plugin/plugin.json`, and directly coupled validation assertions
- Evidence: `state/evidence/CODEX-TIMEOUT-TRANSCRIPT-001/`
- Record phase only: `state/fix_plan.md`, `state/tasks.json`, `state/PROGRESS.md`, `AGENT_NOTES.md`

`Invoke-Codex` / `invoke_codex` signatures and their caller-visible success/failure semantics are not
changed. The only intended behavior change is durability of already-produced output on watchdog expiry.
