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
- **A `$(pipeline)` assignment under `pipefail` aborts on a no-match `grep`** — `x="$(grep … | sort |
  tail -1)"` fails the assignment when grep finds nothing, and errexit kills the script. Every
  "optional extraction" pipeline ends in `|| true`. Found live 2026-09-04: `update_budget_from_log`
  killed the bash loop after every implement phase whose transcript had no JSON token counts (i.e.
  every `meterTokens=false` run); the unit test fed a log WITH counts, so only the stub-driven
  loop-review live-fire caught it. Feed the no-match shape to any parser test.
- **Dispatcher invariants** (`lib/dispatch.*`) — a per-phase `fallback` fires ONLY on a failed
  invocation, even when the resolved primary is `''` (inherit ambient); the usage-limit sniffer
  (`Test-UsageLimitError`/`usage_limit_error`) is consulted ONLY on failure, never to overturn a
  success — the markers are substrings, and a good build whose output mentions "quota"/"429" must
  not be reset and retried.
- **Multi-judge review point** — when a gate has N sequential judges (primary reviewer, optional second
  reviewer, evaluator — in that order), any externally-visible "passed" marker (the `harness-reviewed`
  tag) advances only after the LAST judge passes — the tag lives in the caller's all-passed branch, not
  inside `Invoke-PeriodicReview`. Adding a judge edits, in the same diff, every surface that enumerates
  the judges or their trigger (this rule, the caller comments, `/review`, the schema, `docs/overnight.md`)
  so they state the same trigger — V4 shipped "after the primary returns its verdict" in `/review` and
  "after the primary SHIPs" in the engine.
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
- **A `[bool]` PARAMETER is not a strict bool, and it fails the OPPOSITE way to the folklore.** An
  ASSIGNMENT coerces (`[bool]$x = '0'` is `$true`); parameter BINDING does not — `-Flag "0"` is a
  `ParameterBindingArgumentTransformationException`. What binding *does* accept is NUMBERS, coercing
  every nonzero one to `$true`, so `Get-PromotionDecision -ReviewerConfigured 2` / `-1` / `0.5` all
  returned AUTO where the sh twin's `[ "$reviewer" != "1" ]` returns HUMAN — a fail-OPEN on the last
  gate before auto-merge. Declare a security-shaped flag UNTYPED and narrow it through an explicit
  predicate (`Test-RiskStrictTrue`), so only a real `[bool] $true` opens the gate and everything else
  fails closed the way the twin does. Two fresh-context reviews asserted the string-coercion version
  and `fix_plan` carried it verbatim for a month; one probe on a real host settled it (2026-09-06).
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
- **Hook exit codes are a Claude Code contract, not a universal one** — Codex logs exit 2 as `Failed` and
  PROCEEDS with the tool call; its denial is JSON `permissionDecision: "deny"` on stdout with exit 0.
  Hook BODIES stay single-contract (exit 2 = deny); `run.mjs --codex` translates per consumer. Any new hook
  consumer gets its own translation in the dispatcher, verified by a real command that did NOT run
  (found live 2026-09-05: the harness hook fired on a real `rm -rf` under Codex and the command ran).
- **A generated config for a foreign tool is load-tested against the INSTALLED tool version before its
  emitter's tests are believed** — Codex treats an unknown/missing TOML key as a fatal load error and silently
  drops the entire project `.codex/` layer, so emit only keys the oldest supported version accepts
  (`[[skills.config]]` needs `enabled`; `[agents]` is a role table on 0.144.3). Text-asserting tests were
  green for a full slice while every generated file was dead.
- **Adding a positional param to a sh lib function updates that function's arg-list header comment in
  the SAME diff** — the PS twin's `param()` block is self-documenting, so the bash `#  $1 … $N` header
  is the one surface that silently goes stale (found in review of `promotion_decision`'s new
  `$8 reviewerConfigured`: PS declared it, the sh header still stopped at `$7`).
- **`printf '%s' "$big" | grep -q` is a fail-open under `set -o pipefail`** — `grep -q` exits at the
  first match while printf is still writing, printf dies of SIGPIPE (141), and pipefail promotes 141
  to the pipeline's status, so a text that DOES match reports "absent". It only bites past the 64 KiB
  pipe buffer, so small unit fixtures stay green while every real input fails. Use a here-string
  (`grep -q PATTERN <<< "$text"`) at every site, not just the ones that look big. Found live
  2026-09-06: `money_signal` reported no money vocabulary in a 167 KiB real diff, so a payments change
  would have classified LOW and become auto-mergeable; `usage_limit_error` and fleet's protected-path
  tamper guard carried the same shape. Any predicate over unbounded text gets a >64 KiB regression test.
  **Converted everywhere as of 2026-09-06** — `plugin/hooks/block-destructive.sh` (10 sites),
  `protect-specs.sh`, `migrate.sh` and `codex-setup.sh` all use here-strings now, so the hooks no
  longer depend on setting no shell options to stay armed. Before that, adding `set -euo pipefail` to
  a guard hook — an obvious-looking hardening — silently disarmed every pattern on a large payload;
  measured, that hook exited **0** on a 195 KB multi-line payload carrying a real `rm -rf /`.
  `codex-setup.sh`'s `tr -d '\r' < "$gi" | grep -qx` was the one site that could fail without anyone
  hardening anything, because that file *does* set `pipefail` — it read "`.codex/` absent" and
  re-appended the line on every run. **But the turnover point is NOT the 64 KiB pipe buffer, and
  assuming it was cost an hour**: with an external producer (`tr`) rather than the `printf` builtin,
  grep's own read buffer absorbs far more. Measured on Git Bash 5.3.9: 114 KB still gives
  `PIPESTATUS=(0 0)`; 289 KB gives `(141 0)`. A 114 KB regression fixture built on the "past 64 KiB"
  assumption passed against the broken code. Every producer/consumer pair has its own threshold —
  bisect it, do not inherit the number from a sibling defect.
  Both suites pin the BEHAVIOUR — including against a copy of the hook with `pipefail` injected — so
  the trap stays caught however the hook is rewritten.
- **A fix applied to N call sites gets its regression test at every site that failed OPEN, not only at
  the site where it was discovered.** The SIGPIPE fix above landed at three places; `money_signal` and
  `usage_limit_error` each got a >64 KiB assertion straight away, while fleet's protected-path guard —
  the site whose failure MERGED a worker's tamper of `specs/` — got the fix and no test, and only
  picked one up in review. Rank the sites by what their failure costs, and test the worst one first.
  The test must also reproduce the failure, and for this defect that takes TWO things, not one.
  (i) The match must sort EARLY, or grep drains the pipe, printf exits cleanly and the broken code
  passes. (ii) The bulk must follow a **newline** — grep cannot match until it has read a complete
  line, so a single 200 KB line forces it to consume everything before it can exit, and again no
  SIGPIPE happens. The hook fixture written for this in PR #16 was one long line and therefore
  passed against the broken form too: it read like a regression test and pinned only the happy path.
  A fixture that cannot fail is worse than no fixture, because it retires the question. Run every new
  guard assertion against the PRE-fix code and confirm it actually goes red.
