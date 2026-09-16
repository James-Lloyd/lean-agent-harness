# HEADLESS-VERIFICATION-BOUND-001 evidence

## Verdict

The before/after live proof establishes the measured cause and the shipped behavior. Before the
prompt change, Codex invoked the repository's complete configured gate and remained inside it until
the diagnostic watchdog killed the phase. After the prompt change, Codex returned after two bounded
targeted verification commands; the same loop invocation then ran the complete gate and passed both
self-test twins.

## Acceptance map

1. **The pre-change transcript is durable and identifies the timeout cause.** `pre/result.json:4-19`
   records UTC bounds, monotonic elapsed time, identical start/end refs, a clean final status, and all
   retained artifacts. `pre/timeline.jsonl:1991` records the effective configured gate invocation at
   62,316 ms. It has no terminal result before `pre/timeline.jsonl:2619`, where the 300-second watchdog
   verdict is retained at 356,781 ms. This exceeds the contract's 60-second causal discriminator.
2. **The prompt contract is explicit and mutation checked.** `PROMPT.md` limits post-edit checking to
   two shell verification commands, requests at most 120 seconds per command, prohibits background
   checks and direct or delegated complete-gate execution, permits the gate command only as quoted
   data, keeps targeted-check failures visible, and leaves green authority with the runner.
   `mutation/result.json:2-122` records two green controls and both runner twins rejecting all nine
   independently removed protections: 20 checks, zero failures.
3. **The post-change model phase returns within the production watchdog.** The first post-edit check
   fails visibly in `post/iter-1.log:1749-1769` after 4,896 ms. Codex corrects the check and the second
   command passes all 19 assertions in `post/iter-1.log:2142-2167` after 3,845 ms. The final model
   response is present by 459,424 ms in `post/timeline.jsonl:2366-2371`, below the unchanged 900-second
   watchdog. Those are the only two post-edit verification `exec` events, neither invokes or delegates
   to the configured gate, and neither starts background work.
4. **The runner remains the complete-gate authority.** Codex states that it did not run the complete
   gate in `post/timeline.jsonl:2371`. The outer process starts afterward at
   `post/outer-gate.txt:1`, passes PowerShell 441/0 at `:537` and Bash 434/0 at `:1038`, then exits zero
   at `:1042`. `post/ledger.jsonl:1` records `path=codex`, `result=green`, no fallback, and no runner
   commit.
5. **The canary is isolated and reproducible.** `post/environment.json` records base, fixture, and
   engine refs; the exact production gate; all fixture preflight controls; the 900-second watchdog;
   and Codex CLI 0.154.0. `post/result.json:12-25` records identical fixture start/end refs and retained
   artifacts. `post/cleanup.json` records successful temporary-directory removal. The reported status
   lists only the canary task's intended uncommitted result; none of those fixture changes appear in
   the shipping branch.

## Validation

- Prompt contract twins: PowerShell 9/0 and Bash 9/0.
- Independent prompt mutants: 20/0 checks in `mutation/result.json`.
- Live same-invocation gate: PowerShell 441/0 and Bash 434/0 in `post/outer-gate.txt`.
- Final branch gate: PowerShell 442/0 at `final-gate.txt:539`, Bash 435/0 at `:1042`, and the combined
  green verdict at `:1044`; the captured process exits zero at `:1046`.
- Independent review: round 1 found one path-scrubbing blocker; `review-round-1.md` records the fix.
  Fresh-context round 2 returned SHIP with no findings; see `review-round-2.md`.

The earlier `post-fixture-failure-1/` is retained because it caught a canary-only multiline-config
rewrite and routing-skill mismatch. The corrected post run uses the exact configured gate command and
passes its fixture preflight before starting Codex.
