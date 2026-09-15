# HEADLESS-VERIFICATION-BOUND-001 — bound model-side checks

- Status: active
- Task: `HEADLESS-VERIFICATION-BOUND-001`
- Component: root (headless loop contract)
- Reference baseline at `c1da842`: PowerShell 441/0, Bash 434/0 via
  `node harness/tests/gate.mjs`

## Why

Two supervised Codex iterations reached the 900-second and 1,800-second watchdogs. The supervisor
observed the intended edit and child verification processes, but the old logger discarded all partial
model output. `CODEX-TIMEOUT-TRANSCRIPT-001` now preserves that output, so this sprint can test—not
assume—the hypothesis that `PROMPT.md` makes the model replay the complete project gate before the
runner executes the same authoritative gate.

The loop already invokes the implement phase first and `Invoke-ProjectGate`/`run_gate` second. This
sprint bounds only the model-side checks. The runner's complete component and root gate remains the
acceptance authority.

## Sprint contract: bounded in-model verification

### Scope (this sprint)

- Capture a supervised, real Codex diagnostic iteration with the current prompt and durable phase
  logging. `node state/evidence/HEADLESS-VERIFICATION-BOUND-001/run-canary.mjs pre` creates an isolated
  worktree at a recorded `origin/main` ref, makes the next queue item (the bounded overnight-guide
  correction) the top open canary task, routes one iteration to Codex with no fallback, pins the branch
  engine via `HARNESS_ENGINE`, and lowers only the throwaway config's diagnostic watchdog to 300 seconds.
- Use the transcript to identify the last completed model action and elapsed phase milestones. Change
  the headless prompt contract only if the transcript proves that model-side complete-gate work is the
  timeout contributor. If the transcript disproves the prompt-only diagnosis, stop and obtain a new
  sprint contract before changing any other behavior.
- If the hypothesis is proved, make the advisory headless prompt contract precise: after editing, the
  implementer may issue at most two `exec` verification events; each event must request a tool timeout
  no greater than 120 seconds; compound commands count as one event but must share that one timeout;
  background/detached verification is forbidden; and no event may execute or delegate to any effective
  configured component/root gate command. Reading, searching for, or comparing that command solely as
  quoted data is allowed. A timed-out or unavailable targeted check must be reported
  in the transcript; it must not be hidden or converted into success.
- Preserve the runner's existing post-model tamper check and complete
  `Invoke-ProjectGate`/`run_gate` call. Add twin regression coverage that distinguishes bounded
  model-side checks from the runner-authoritative gate.
- Re-run a real Codex iteration on an isolated canary after the change. The implement phase must
  return inside the unchanged 900-second production watchdog, and the same outer loop invocation must
  then run the repository's complete PowerShell and Bash self-test twins.

### Out of scope

- Raising `models.codex.timeoutSeconds`, removing the watchdog, skipping a configured gate step, or
  treating model-reported verification as runner evidence.
- Shipping the overnight-guide correction, completing Overnight Stage 1b, enabling the evaluator, or
  changing the dry-run banner.
- General prompt optimization, model-routing changes, token-budget tuning, or claiming a universal
  performance guarantee from one supervised run.
- Mechanically enforcing the advisory two-event contract inside the model's tool runtime. This sprint
  proves the prompt text and one real compliant trace; the runner's complete gate, not model obedience,
  remains the fail-closed correctness boundary.
- Editing immutable `specs/`, weakening/deleting tests, or committing canary-only mutations from the
  throwaway worktree/repository.

### Definition of done (every box must be ticked)

- [ ] A pre-change real Codex diagnostic transcript is durable through either normal return or the
      watchdog verdict and names the last completed action; the canary record contains start/end UTC,
      elapsed milliseconds from Node's monotonic clock, start/end refs, and final cleanliness.
- [ ] Complete-gate duplication is proved only if the transcript has an `exec` event containing the
      effective configured command read from `components[].gate`/root `gate`, and the event consumes
      at least 60 seconds (20% of the 300-second diagnostic phase). A completed event uses Codex's
      reported duration. An event active at watchdog expiry qualifies only when the monotonic sidecar
      first observed its `exec` line by 240,000 ms and observed no matching result before 300,000 ms.
      Otherwise the sprint stops for a revised contract; mere test-like child activity is not proof.
- [ ] The shipped headless prompt states the advisory two-`exec`/120-second grammar, prohibits
      background checks and effective configured gate commands, and keeps failed/timed-out targeted
      checks visible. Mirrored prompt-contract tests fail when each protection is independently
      removed.
- [ ] Existing loop tests prove the runner still calls the complete project gate after a successful
      implement phase and fails/rolls back on a red outer gate; no configured gate step is skipped.
- [ ] A post-change real Codex implement phase returns in less than 900 seconds. Its transcript has no
      more than two post-edit verification `exec` events, each reports at most 120 seconds, contains no
      execution of the effective configured gate command (directly or through a shell, script,
      function, subprocess, or wrapper) and launches no background verification. A quoted data-only
      comparison/search is permitted; the canary record
      reports monotonic elapsed milliseconds and the transcript identifies command outcomes.
- [ ] That same real loop iteration advances to the outer gate, whose retained output reports
      PowerShell and Bash complete-suite counts with zero failures. The ledger records `path=codex`
      and `result=green`.
- [ ] The canary begins and ends from recorded commits, all temporary routing/task changes are absent
      from the shipping diff, and no model-only commit is mistaken for the final reviewed change.
- [ ] End-to-end evidence under `state/evidence/HEADLESS-VERIFICATION-BOUND-001/` maps every criterion
      to exact result files and line numbers, with machine paths scrubbed before commit.
- [ ] The final root gate is green via `node harness/tests/gate.mjs`, `state/fix_plan.md` and
      `state/tasks.json` record validation, `state/PROGRESS.md` records both twin counts, and an
      independent fresh-context review returns `SHIP`.

### How success is verified

1. Before changing behavior, run
   `node state/evidence/HEADLESS-VERIFICATION-BOUND-001/run-canary.mjs pre`. The driver records the
   exact fixture/task/config diff, effective gate command, branch-engine path, CLI version, start/end
   UTC, `performance.now()` elapsed milliseconds, refs, status, phase transcript, loop stdout/stderr,
   and ledger. While the model runs, it polls the durable iteration log every 100 ms and records each
   newly observed line with `performance.now()` elapsed milliseconds in `pre/timeline.jsonl`.
   Adjudicate only literal Codex `exec` blocks and their `succeeded in ...` durations. An unterminated
   configured-gate block is causal only when its timestamped `exec` line appears by 240,000 ms and no
   result line appears before the 300,000 ms watchdog, proving at least 60 seconds of gate occupancy.
2. Add `harness/tests/headless-verification-test.ps1` and
   `harness/tests/headless-verification-test.sh`. Require positive assertions for the exact two-event,
   120-second, no-background, no-effective-gate, visible-failure, and runner-authority clauses. Run:
   `powershell -NoProfile -ExecutionPolicy Bypass -File harness/tests/headless-verification-test.ps1`
   and `bash harness/tests/headless-verification-test.sh`.
3. Run the existing loop regression twins with a local model stub whose successful implement returns
   before a deliberately red outer gate. Assert the gate runs and rollback still occurs.
4. Run `node state/evidence/HEADLESS-VERIFICATION-BOUND-001/run-canary.mjs post` against the same
   recorded base/task fixture and task, replacing the prompt under test and restoring the normal
   900-second watchdog. The pre-run's output-redirection suffix is removed because it made the
   repository's gate-wiring assertion treat the suffix as a path. Keep the effective command exactly
   `node harness/tests/gate.mjs`; capture that process's stdout/stderr by passing a canary-only Node
   preload through `NODE_OPTIONS`. The preload activates only when `process.argv[1]` resolves to
   `harness/tests/gate.mjs`, tees bytes without changing exit behavior, and records process start/end.
   Retain that output from the one loop invocation; do not substitute a separately run green gate.
5. Run `node harness/tests/headless-verification-mutation.mjs --out
   state/evidence/HEADLESS-VERIFICATION-BOUND-001/mutation`; it builds independent temporary prompt
   mutants for each clause, requires the unmodified PS/Bash controls to pass, and requires both twins
   to reject every mutant. Then run package validation if a packaged surface changed and finally
   `node harness/tests/gate.mjs`. Compare exact twin counts to the baseline and explain increases.
6. Grep `AGENT_NOTES.md` and `state/` for the task's own diagnosis and stale timeout claims, then run
   an independent fresh-context review over the final diff and evidence.

## Stop conditions

- If the diagnostic transcript does not prove complete-gate duplication, do not make the proposed
  prompt change; update this contract to the measured cause and obtain a fresh agreement first.
- If the post-change implement phase reaches 900 seconds, stop after the retained transcript. Do not
  increase the watchdog or retry an identical run.
- If the outer loop does not execute both complete twins, or any twin is red, the task is not done.
- If the canary cannot be isolated from the shipping branch, stop rather than risk committing its
  task/routing mutations.

## Expected files and interfaces

- Likely behavior: `PROMPT.md` (subject to the diagnostic result)
- Twin regression/e2e: `harness/tests/headless-verification-test.ps1`,
  `harness/tests/headless-verification-test.sh`, and
  `harness/tests/headless-verification-mutation.mjs`
- Evidence: `state/evidence/HEADLESS-VERIFICATION-BOUND-001/`
- Record phase: `state/fix_plan.md`, `state/tasks.json`, `state/PROGRESS.md`, and `AGENT_NOTES.md` only
  if the measured result teaches a durable operational lesson

The externally visible loop contract remains: a model invocation cannot make an iteration green.
Only the runner's configured complete gate can do that.

## Diagnostic result and contract amendment — 2026-09-15

The first driver launch failed before Codex because Node could not resolve the Windows `codex`
launcher; it is retained as `pre-driver-failure-1/`. The corrected launcher reached Codex. Its
configured gate `exec` appeared at 62,316 ms (`pre/timeline.jsonl:1991`), remained without a terminal
result through 300,000 ms, and the retained watchdog appeared at 356,781 ms (`:2619`). Polls proved
the gate continued through PowerShell and into Bash (`:2018-2019`, `:2396`, `:2544-2546`). The
accepted >=60-second discriminator is therefore met: duplicate full-gate work is measured, not a
supervisor hypothesis.

The output-redirection suffix used for pre-run capture also made the gate-wiring assertion red because
that assertion treats everything after `node` as the script path. This does not invalidate the causal
measurement—the full gate remained active for minutes—but it cannot be used for the post-run green
criterion. Step 4 is amended to restore the byte-for-byte production gate command and capture through
a canary-only Node preload. No corrected pre-run is needed; no shipping behavior beyond `PROMPT.md`
is authorized by this amendment.

The first post-change attempt returned from Codex after 181,105 ms and complied with the bounded
verification contract, but its runner gate was red. The failure was in the throwaway fixture, not the
shipping prompt: the driver rewrote `harness.config.json` with multiline JSON, while the Bash routing
pin intentionally reads each compact phase object from one line; it also changed the implement route
without mirroring that temporary value into the routing skill paired to the config by both twin gates.
The failed attempt is retained as `post-fixture-failure-1/`, including its red ledger and gate output.

The canary driver is amended to preserve the shipped compact config layout, mirror only its temporary
`implement=codex` route into the canary's routing-skill row, and fail a preflight unless the exact gate
command, compact route fields, and paired skill row agree. The capture preload also marks the outer
gate process tree and ignores Node's `--check` mode, so syntax checks and synthetic nested `gate.mjs`
tests remain ordinary activity rather than additional outer-process markers. One corrected post-run is
authorized because the fixture is
materially different; an identical retry or a watchdog increase remains forbidden. These are
canary-only changes and do not expand the shipping behavior beyond `PROMPT.md`.

The transcript exposed one wording ambiguity before retry: a targeted docs check compared the exact
gate command as a quoted string without executing it. The earlier word `contain` would reject that safe
readback even though the shipping prompt prohibits invocation. The contract now permits quoted
data-only reading/search/comparison and continues to prohibit direct or delegated execution through a
shell, script, function, subprocess, or wrapper. Both sides are pinned in the paired prompt tests and
their independent mutants. This clarification preserves the runner's exclusive gate authority.
