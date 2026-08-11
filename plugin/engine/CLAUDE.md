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
- **A "no markers ⇒ not sandboxed" negative test is host-dependent** — branch the assertion on host
  bareness or it fails inside the very container the feature ships in. (The positive half — container
  env markers are PRESENCE markers, not truthy — is pinned by the sandbox-predicate tests.)
- **`harness/.runs/` is reset-proof by construction** (gitignored ⇒ `reset --hard` and `clean -fd`
  both skip it) — park anything that must survive a rollback there, never in the index.
- **A MULTI-LINE `jq` read must be CR-stripped** (`| tr -d '\r'`, and `${v%$'\r'}` in `read` loops).
  `jq.exe` under Git Bash emits CRLF; `$(...)` strips only the *trailing* newline, so a scalar read
  (`phase_model`) is safe but every INTERIOR line of a list keeps its `\r`. A config-derived glob
  then compiles to a regex ending `.*\r$` and silently matches **nothing** — fail-OPEN, in
  `lib/risk.*` the one direction a classifier must never fail. CI runs bash on Linux only, so this
  is invisible there; it reproduces on a Windows dev box.
- **Non-ASCII belongs in comments, not in emitted STRINGS** — PS 5.1 reads a BOM-less `.ps1` as ANSI,
  so an em dash in a literal reaches the ledger, the audit record, or a PR comment as mojibake. The
  sh twin must use the same ASCII text or the twins are not capability-equivalent.
- **Embedded judge prompts exist in both twins** (loop.ps1/loop.sh, fleet.ps1/fleet.sh) and their
  verdict parsers are fail-closed on the last `VERDICT:` line — edit both copies and keep the output
  contract intact.
- **A verdict/tier parser is CASE-SENSITIVE in both twins, in the line SELECTION as well as the parse**
  — PS `-cmatch`, never `-match` (which is case-insensitive by default while the sh twin's `grep -E` is
  not). Two ways it bites, and the selection is the one people miss: with `-match` the two shells can
  pick a DIFFERENT "last verdict line" before parsing even starts. A judge invited to add a prose note
  emits `RISK: HIGH` then `risk: low would be wrong here`, and the case-insensitive twin LOWERED the
  tier (risk.ps1, fixed 2026-08-08); the identical defect in `gate.ps1`'s `Get-ReviewVerdict` /
  `Get-EvaluatorVerdict` turned `VERDICT: REJECT` + a line-initial `verdict: ship …` into a SHIP on
  Windows while bash said REJECT — fixed 2026-08-11, 7 mutation-verified assertions per twin.
  **Only LINE-INITIAL lowercase is exploitable** (`^\s*VERDICT:` is anchored), so test that shape —
  prose mid-line never matched under either operator and makes a false-comfort test.
- **Shape-validate a security-shaped config block before trusting it** — absent, scalar-instead-of-
  array, or stringly-typed keys must reach the REFUSING branch, never a silently skipped rule. An
  absent `preconditions` object reached AUTO with a red gate while the audit string still read "all
  preconditions met"; `enabled: "false"` as a string read as ON under PS (non-empty string coerces to
  `$true`).
- **Never return a collection from a PS function you intend to TYPE-CHECK** — the output pipeline
  unrolls a single-element array to a bare scalar, so `["**/payments/**"]` fails `-is [Array]`.
  `return ,$value` survives assignment but NOT an inline `@(f ...)`, and an ArrayList round-trip does
  not help either. Return a bool/int PREDICATE instead (`Test-RiskPropIsArray`, `Get-RiskPropCount`).
- **A PS assertion over a config/schema key checks PRESENCE before content** — `@($null)` has Count 1
  and `-notcontains` anything, so a key-DELETION mutation false-passes. The bash twin catches it.
- **Never type-check a JSON value by concrete .NET type; pin the type in the schema instead** —
  `ConvertFrom-Json` yields `Int32` under Windows PowerShell 5.1 and `Int64` under pwsh, so `-is [int]`
  rejected a valid `maxChangedLines: 1000` on pwsh alone. Test the VALUE (`[Math]::Floor($d) -eq $d`),
  mirroring the sh twin's `jq floor == value`, and declare the type in `harness.schema.json` whenever
  both twins compare it (e.g. `failBelow` is `integer`) — the two shells do not coerce identically and a
  divergence can fail open. The suites run under BOTH hosts in CI — a 5.1-only green is not green.
