# Engine (loop / fleet / lib) — local rules

Every `.ps1` here has a `.sh` twin; a change lands in both or not at all. Primary Windows runtime is
PowerShell **5.1**. The test suites parse-check every top-level entry script (`[Parser]::ParseFile` /
`bash -n`) — keep new entry scripts in that net.

Hard-won rules (each traces to a real shipped failure):
- **PS 5.1 `${Var}:`** — in any double-quoted string/here-string, `$Var` immediately followed by `:`
  is scope/drive syntax and a parse error for the *whole file*. Write `${Var}:`.
- **`Start-Job` = fresh runspace** — re-source the libs inside the job (pass the lib dir via
  `-ArgumentList`; `$PSScriptRoot` differs inside) and use a quiet output path (`Out-Null`, never
  `Out-Host`, which replays at `Receive-Job` and cannot be suppressed). Assign phase results to a
  var so they don't leak into the job output stream; emit only the 0/1 exit proxy the caller reads.
- **sh parity under `set -e`** — where the ps1 twin routes git through the exit-swallowing `_Git` in
  an error/degradation branch, the raw sh git call needs `|| true`, or sh aborts where ps1 tolerates.
- **Dispatcher invariants** (`lib/dispatch.*`) — a per-phase `fallback` fires ONLY on a failed
  invocation, even when the resolved primary is `''` (inherit ambient); the usage-limit sniffer
  (`Test-UsageLimitError`/`usage_limit_error`) is consulted ONLY on failure, never to overturn a
  success — the markers are substrings, and a good build whose output mentions "quota"/"429" must
  not be reset and retried.
- **Multi-judge review point** — when a gate has N sequential judges (reviewer + evaluator), any
  externally-visible "passed" marker (the `harness-reviewed` tag) advances only after the LAST judge
  passes — the tag lives in the caller's both-passed branch, not inside `Invoke-PeriodicReview`.
- **A backgrounded bash subshell that must record its exit code needs `set +e` inside** — inherited
  errexit kills it on the nonzero exit before the `echo $?` line runs.
- **An automated runner never discards a `git commit` exit code** — check it or park the branch; a
  silent commit failure turns every downstream record fail-open.
- **Sandbox detection** (`Test-Sandboxed`/`is_sandboxed`) — container env markers are PRESENCE
  markers, not truthy (`$container` holds a runtime *name*): test set-ness, not value. And a
  "no markers ⇒ not sandboxed" negative test is host-dependent — branch the assertion on host
  bareness or it fails inside the very container this feature ships.
- **Pin config types in `harness.schema.json`** when both twins compare a value (e.g. `failBelow` is
  `integer`) — the two shells do not coerce identically, and a divergence can fail open.
- **`harness/.runs/` is reset-proof by construction** (gitignored ⇒ `reset --hard` and `clean -fd`
  both skip it) — park anything that must survive a rollback there, never in the index.
- **Embedded judge prompts exist in both twins** (loop.ps1/loop.sh, fleet.ps1/fleet.sh) and their
  verdict parsers are fail-closed on the last `VERDICT:` line — edit both copies and keep the output
  contract intact.
