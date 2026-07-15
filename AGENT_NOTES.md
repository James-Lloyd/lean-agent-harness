# AGENT_NOTES.md — the amnesiac's notebook

Brief, factual entries that a fresh-context agent needs to be productive in *this* repo. Append; do
not rewrite history. Keep it terse — this is loaded often.

This file is the cousin of `CLAUDE.md`: `CLAUDE.md` is the curated map; this is the running scratch of
hard-won operational facts (exact commands, environment quirks, "X looks broken but isn't").

## How to run / build / test
<!-- /harness-init fills one block per component (mirroring the CLAUDE.md components table) from each
     stack profile; a single-root project has just one block. Correct them the moment reality differs. -->
- **{{COMPONENT_NAME}}** (`{{COMPONENT_PATH}}` — run these in that directory):
  - Run: `{{COMPONENT_RUN}}` · Build: `{{COMPONENT_BUILD}}` · Test: `{{COMPONENT_TEST}}`
  - Format / lint / typecheck: `{{FORMAT_COMMAND}}` / `{{LINT_COMMAND}}` / `{{TYPECHECK_COMMAND}}`

## Environment quirks
<!-- e.g. "Dev server takes ~40s to boot; wait for 'listening on' before smoke-testing." -->

## Learnings (append when a loop discovers something)
<!-- Format: "- [YYYY-MM-DD] <what you learned> (cost you: <the failure>)" -->
- [2026-07-13] Codex CLI: put global flags (`--sandbox`, `--ask-for-approval`) BEFORE the `exec`
  subcommand — some versions exit 2 on flags placed after it. `codex exec` has NO --max-turns/--timeout;
  the harness wraps it in an external watchdog (models.codex.timeoutSeconds). `codex login status`
  false-negatives under Azure/custom providers — point models.review at a claude model if you hit that.
- [2026-07-13] Fleet workers must NOT edit state/ files or AGENT_NOTES.md — every worker touching
  tasks.json/fix_plan.md guarantees merge-queue conflicts; the fleet runner records after each merge.
- [2026-07-13] Run dirs under harness/.runs/ are CLAIMED at allocation (mkdir-as-mutex) — a run dir
  existing does not mean the run produced output.
- [2026-07-13] (ratchet) A backgrounded bash subshell that must record its exit code needs `set +e`
  inside — inherited errexit kills it on the non-zero exit BEFORE the `echo $?` line runs (cost:
  fleet.sh's exit files were dead code; every claude failure mis-parked as "timeout").
- [2026-07-13] (ratchet) An automated runner never discards a `git commit` exit code — check it or
  park the branch; a silent commit failure turns every downstream record fail-open (cost: fleet's
  merge queue could ledger "merged" pointing at a pre-existing commit and amend an unrelated one).
- [2026-07-13] (ratchet) A fix for a review finding lands WITH a regression test exercising the exact
  failing input — a prose ratchet entry without a test case is not closed (cost: the fleet crash-path
  fix shipped untested until the re-review caught it; now fleet-queue-test.* T-CRASH).
- [2026-07-14] loop/fleet now resolve the PROJECT root from `-ProjectRoot`/`--project-root` → else the
  git top-level of the CWD → else CWD (was: parent of the script dir, CWD-independent). Invoking the
  raw engine script by absolute path from a DIFFERENT repo/`$HOME` now targets the wrong root. Cron and
  bare shells must `cd` into the project first OR pass `-ProjectRoot <repo>` (the thin `harness/`
  wrappers already do this — they derive the root from their own location, so wrapper invocation stays
  CWD-independent). Plugin split: engine lives in the installed plugin; `harness/` holds only
  config + runtime + wrappers.
- [2026-07-14] (ratchet) Capture evidence test counts on the EXACT tree being committed (HEAD + staged),
  re-running after any rebase/merge-back — a worktree captured pre-merge-back can cite stale counts (S1
  evidence said 79/75; the merged tree runs 80/76 because harness-migrate's self-test landed in between).
  Green substance held, but the numbers must match the committed tree.
- [2026-07-14] Model routing is now per-phase `{model, fallback}` (config.models), tolerant of the legacy
  flat `models.<phase>:"alias"` string + top-level `reviewFallback`. Resolver split into two accessors:
  `Resolve-PhaseModel`/`phase_model` return the PRIMARY (unchanged callers); `Resolve-PhaseFallback`/
  `phase_fallback` return the fallback. KNOWN asymmetry to fix in S3: `Resolve-PhaseModel('reviewFallback')`
  falls through to the legacy top-level key, but `Resolve-PhaseFallback('review')` on a nested object does
  NOT — align when the review path adopts `phase_fallback`. `{model,fallback}` values are a Claude alias/ID
  or the literal `codex`; the `codex{}` block configures codex for ANY phase routed to it (not just review).
- [2026-07-14] Cross-vendor S2: the codex lib is now `lib/invoke-codex.*` (was `review-codex.*`, kept as a
  thin back-compat shim that just sources/dots the new file until S7). Arg assembly is a PURE builder
  (`Get-CodexArgs`/`codex_args`) so it's unit-testable with no codex install; `Invoke-Codex -Mode
  read-only|workspace-write` selects the `--sandbox` value (only difference between modes). Read-only
  wrappers (`Invoke-CodexReview`/`codex_review`) preserve every existing call site — loop/fleet untouched.
  `Test-UsageLimitError`/`usage_limit_error` (in `lib/gate.*`) is the vendor-neutral fallback predicate.
- [2026-07-14] (ratchet — recorded in CLAUDE.md Project rules, from S2 review) Output-sniffing predicates (usage-limit detection) must
  be consulted ONLY on a FAILED invocation (not-ok / nonzero exit), never to overturn a SUCCESS. The
  marker set is substring-based, so a *successful* write-phase build whose final message happens to say
  "overloaded"/"quota"/"429" would otherwise be wrongly reset-to-base and retried on the fallback —
  discarding a good build. Wired in S3; noted in the S3 done-when.
- [2026-07-14] Cross-vendor S3: `lib/dispatch.*` adds `Invoke-Phase`/`invoke_phase` — the vendor-neutral
  dispatcher wired into the loop's implement call (workspace-write) and periodic reviewer (read-only).
  Tries `primary → fallback` across claude↔codex; advances to the fallback ONLY on (a) pre-invocation
  codex-unavailability or (b) a usage-limit-flagged FAILURE — a generic non-usage failure returns as a
  failure WITHOUT switching vendors (so implement still rolls-back+continues, review still fail-closes,
  exactly as before). Ratchet honored: a SUCCESS returns immediately and is never re-examined for usage
  markers. Write-phase reset-to-base fires ONLY before a fallback candidate in workspace-write mode
  (`-ResetRef`); read-only judges keep the caller's after-the-fact hard reset. Fail-closed on exhaustion.
  bash: `invoke_phase` must be called DIRECTLY (not in `$(...)` — a subshell would drop its
  `INVOKE_PHASE_PATH/USED_FALLBACK/REASON` globals); stdout is the phase output, extra claude args via a
  caller-set `INVOKE_PHASE_CLAUDE_ARGS` array. PS `Invoke-ClaudePhase` needs `| Out-Host` after
  `Tee-Object` so the passthrough doesn't pollute the return object under StrictMode. S1b resolved here:
  `Resolve-PhaseFallback('review')`/`phase_fallback review` now fall through nested→legacy top-level
  `reviewFallback`→'' (symmetric with `Resolve-PhaseModel('reviewFallback')`). Narrow disclosed behavior
  change (see the new CLAUDE.md project rule): review UNSET + legacy `reviewFallback` now runs the
  happy-path reviewer on the ambient model, reaching `reviewFallback` only on usage-limit — inert on the
  default `review:{model:codex,fallback:fable}` config. PS 113 / bash 104 / fleet-queue 16 both runners.
- [2026-07-14] CORRECTION to the earlier "codex NOT installed here" landmine: codex CLI **IS** installed
  now (codex-cli 0.144.3, logged in via ChatGPT — `codex login status` exits 0). S3 captured a REAL
  live-fire read-only codex run through `Invoke-Phase` (`Ok=True Path=codex`, ~8s; evidence
  live-codex-readonly*.txt). The codex WRITE (workspace-write) path is still live-fire-untested by choice
  — gated behind the loop's gate + autoRollbackOnRed; first real write run should be supervised.
- [2026-07-14] OPERATIONAL landmine (hit this session): the `reviewer` subagent frontmatter is pinned to
  `fable`, and a review run DIED mid-flight on "You've reached your Fable 5 limit." A fresh-context judge
  pinned to a low-tier model can be knocked out by that model's own usage cap — re-spawn the subagent with
  a `model:` override (Agent tool) to finish. See the new CLAUDE.md project rule (candidate for a broader
  subagent-level fallback in a later slice).
- [2026-07-15] S4 fleet workers now route their implement build through the SAME dispatcher as the loop
  (`Invoke-Phase`/`invoke_phase`, workspace-write) — a fleet worker inherits primary→fallback + write-phase
  reset-to-base for free. Reset ref = the worker's OWN batch/branch base (`$baseRef`); the reset runs in
  the worktree cwd, so a usage-limit fallback resets that worker's worktree, not the main tree.
- [2026-07-15] PS **Start-Job gotcha** (de-risked with 4 live experiments before building): a Start-Job
  runs in a FRESH runspace — it does NOT inherit the parent's dot-sourced functions, so the worker
  scriptblock must re-source gate.ps1 + invoke-codex.ps1 + dispatch.ps1 itself (pass the lib dir in via
  -ArgumentList; $PSScriptRoot is not the same inside the job). And `Out-Host` output produced INSIDE a job
  is replayed to the parent console at `Receive-Job` time and CANNOT be suppressed by any stream redirect
  (`6>$null`, `*>$null` all fail). Fix: a `-Quiet` switch on Invoke-ClaudePhase/Invoke-Phase that swaps
  `Out-Host`→`Out-Null` (Tee still writes the log, $LASTEXITCODE preserved). The fleet worker passes
  -Quiet (file-only logging, quiet console); the loop omits it (keeps live streaming). Bash has NO
  equivalent problem — `( )&` subshells inherit sourced functions, and invoke_phase's stdout is just
  redirected away (its tee already wrote $log). Assign Invoke-Phase's result to a var so its returned
  object doesn't leak into the job output stream; emit only `0/1` as the worker exit the merge queue reads.
- [2026-07-15] S5 is the INTERACTIVE twin of the headless dispatcher: the `/work` orchestrator (me, Claude)
  now follows a **resolve-then-route** rule per phase (documented in `/work` → "Model routing per phase" +
  a "Cross-vendor note" in planner/generator/reviewer). Resolve `config.models.<phase>.{model,fallback}`;
  Claude primary → spawn the subagent (pinned via the Agent `model:` override); `codex` primary → do NOT
  spawn the subagent — invoke the codex lib via a **Bash tool call** (`Invoke-Phase`/`invoke_phase` gives
  the Claude fallback for free; `Invoke-Codex`/`invoke_codex -Mode` for the codex arm alone), read-only for
  judges (review/evaluate), workspace-write for writers (plan/execute). No subagent ever wraps codex.
  Frontmatter stays each phase's Claude model — reviewer's is review's Claude *fallback* (review's primary
  is codex in the shipped config). Doc gotcha caught in review: the **bash** resolvers `phase_model`/
  `phase_fallback` take a config **file PATH** ($1 → jq opens it), while the **PS** resolvers take a
  **parsed object** ($cfg = … | ConvertFrom-Json) — a doc that names the bash arg `$cfg_json` would mislead
  an orchestrator into passing JSON text and hitting a jq "no such file" error. When documenting a shell
  call of an engine function, name args by their real type.
- [2026-07-15] Cross-vendor S6 (docs): `/harness-doctor` check 10 is **agent-executed prose**, not an
  automated self-test — the check runner reads the markdown and performs the checks via Read/Bash/Grep.
  There is NO check-10 fixture in `harness/tests/` to extend (the earlier handoff's "there's a doctor
  self-test to extend" was mistaken — the tests cover the resolver functions `Resolve-PhaseModel`/
  `phase_model`/`Resolve-PhaseFallback`/`phase_fallback`, not check 10 itself). So S6 was a pure
  docs/twin edit; suites (PS 115 / fleet 22) just confirm no regression, bash unaffected (no `.sh`).
- [2026-07-15] Doc accuracy (caught by the S6 codex review): when documenting the codex fallback,
  distinguish **codex-as-PRIMARY** (e.g. `review={codex,fable}`: codex unavailable → the phase silently
  runs on its Claude *fallback*) from **codex-as-FALLBACK** (e.g. `implement={opus,codex}`: codex
  unavailable → the Claude *primary* still runs the happy path, but the safety net is gone, so a usage
  cap on the primary then has nowhere to fall back and the dispatcher **fails closed**). "Any codex-routed
  phase runs on its Claude arm when codex is down" is WRONG for the codex-as-fallback case. (Left as a
  learning, not a CLAUDE.md ratchet — narrow/doc-only, same disposition as S5's arg-naming note.)
- [2026-07-15] The S6 review itself was run cross-vendor: `Invoke-Phase -Mode read-only` with the shipped
  `review` primary (`codex`) produced a real verdict (Ok=True, Path=codex, UsedFallback=False) on the
  docs diff — a live-fire confirmation that the codex read-only judge path works from the interactive
  `/work` REVIEW phase exactly as the S5 resolve-then-route protocol documents.
- [2026-07-15] Cross-vendor S7 (prune): the `review-codex` back-compat shim is **retired**. It was safe
  to remove because NO live caller reached the wrappers — the review path runs through `lib/dispatch.*`
  (`invoke_phase`/`Invoke-Phase`) → `invoke_codex`/`Invoke-Codex` directly, and loop/fleet only `source`d
  `review-codex.*` to pull the codex API into scope (the shim just re-sourced `invoke-codex.*`). Fix was
  a pure prune: repoint those 4 source lines (×2 twins) at `lib/invoke-codex.*`, delete the 4
  `review-codex.{sh,ps1}` files, drop `codex_review`/`Invoke-CodexReview` from `invoke-codex.*`, and
  remove the 3 shim-specific test assertions (bash −1, PS −2 wrapper + −1... net PS −3). New baselines:
  **PS 112 / bash 103 / fleet-queue 22** both runners (down from 115/104 — the removed assertions, no
  regression). When you retire a re-export shim, grep for the WRAPPER NAMES (`codex_review`,
  `Invoke-CodexReview`) not just the filename — a live `source` of the file can hide a dead wrapper, and
  vice-versa; here the sources were live but the wrappers dead, so both had to be handled separately.
- [2026-07-15] **Generator worktree base can be STALE.** The S7 generator subagent (`isolation:
  worktree`) was handed a worktree checked out at `0d852c0` — an ancestor ~16 commits behind `main`
  (`0ba6bb8`), predating the entire S2 rename it depended on — so every premise of its task ("the codex
  lib was renamed to invoke-codex, delete the shim") was false against its HEAD: no `invoke-codex.*`, no
  `dispatch.*`, `review-codex.*` still pre-S2. It correctly detected the mismatch (reading the shared
  checkout at `main` first masked it), reverted its edits, left the tree clean, and escalated instead of
  forcing incoherent changes — exactly right. Recovery: implemented the prune **inline in the main tree**
  (fully-mapped mechanical change; the independent codex REVIEW still preserved the build/judge split).
  Watch for this — when a delegated worktree's HEAD doesn't match `main`, don't fight the tooling; either
  confirm the base is intentional or build inline. **Ratchet candidate** (see /work output).
- [2026-07-15] **`loop.ps1` did not PARSE under Windows PowerShell 5.1** — its documented primary runtime.
  In the `$evalPrompt` here-string, `failBelow=$FailBelow:` was read by 5.1 as a scope-qualified variable
  (`$name:` = the `$env:`/`$script:` syntax), so `[Parser]::ParseFile` raised "':' not followed by a valid
  variable name" and the WHOLE script failed to parse — the loop couldn't run at all. Shipped in the
  unpushed evaluator commit `8a3a032`. Fix: delimit — `${FailBelow}:` (renders identically, `failBelow=7:`).
  Root gap: `run-tests.ps1` dot-sources `lib/*.ps1` + runs functions but NEVER parsed the top-level entry
  scripts (loop/fleet/migrate/wrappers), so a here-string syntax error was invisible to a green suite.
  Fixed the net too: an "engine hygiene" block parses every engine script — PS via `[Parser]::ParseFile`,
  bash via `bash -n` — (+11 assertions each: PS 132→143, bash 123→134). Rule: in any PS double-quoted
  string/here-string, a `$Var` immediately followed by `:` must be written `${Var}:`; and a self-test suite
  must PARSE the entry scripts, not just source the libs. (Found by the Overnight Stage 1a dry-run e2e —
  which is exactly why "unit-green is not done; drive it end-to-end" is in the gate.)
- [2026-07-15] Overnight Stage 1a shipped `docs/overnight.md` — the local unattended-run operator recipe
  (config preset + `schtasks`/cron scheduling + morning `ledger.jsonl`→`/review` routine). Mostly docs
  (the loop already implements every knob) PLUS the prerequisite `loop.ps1` parse fix + both-runner
  parse-checks noted directly above (NOT docs-only). Ledger `result` values (verified against loop.{ps1,sh},
  for the
  morning-routine table): `green`, `red`, `review`, `evaluate`, `review-stop`, `invoke-error`,
  `config-tampered`, plus `gate-error` (PowerShell runner only — its gate can THROW; the bash gate returns
  red instead). Stage 1b (one real overnight run, supervise-first) is the wall-clock human tail + live-fire.
- [2026-07-15] **Sandbox detection for unattended `auto` runs** (`Test-Sandboxed`/`is_sandboxed` in
  `plugin/engine/lib/gate.*`, loop guard in `loop.*`). Two lessons worth keeping: (a) **container-marker
  env vars are PRESENCE markers, not truthy** — a runtime SETS `$container`/`$REMOTE_CONTAINERS`/etc. to
  signal itself, and `$container` in particular holds a runtime NAME (`lxc`/`podman`), so test set-ness
  (bash `${VAR+x}`, PS `$null -ne [Environment]::GetEnvironmentVariable(...)`), NOT `${VAR:-}`-non-empty
  and NOT a `1/true/yes` truthy match. Only the explicit `HARNESS_SANDBOX` contract var uses truthy/falsy
  (and it must match EXACTLY across runners — no `.Trim()` on one side only, or `" true "` diverges).
  (b) **A "no container markers ⇒ NOT sandboxed" negative test is host-dependent and will FAIL inside a
  container** (the fs markers `/.dockerenv` + `/proc/1/cgroup` can't be unset in a subshell) — i.e. it
  breaks inside the very devcontainer/CI-container profile this feature ships. Branch the assertion on
  host bareness: bare host ⇒ assert NOT sandboxed; container host ⇒ assert sandboxed. Caught by the
  fresh-context codex review, not by running on this (bare) Windows host.
- [2026-07-15] **Verify a delegated worktree's base before merging back.** The sandboxing generator's
  `isolation: worktree` came up on `ef9bda0` (an ancestor, not tip `2b14209`) — same stale-base class as
  S7. Here it was benign, but I confirmed that RATHER THAN assuming: `git diff --quiet <base> <tip> -- <each
  touched file>` showed all six touched files byte-identical between the two commits, and the two newer
  commits only touched `.github/`+`ci/`+`state/` (files the generator never edited), so `git merge
  --squash` (merge-base = ef9bda0) applied exactly the generator's diff with no reversion. The orchestrator
  must run this check when a worktree base ≠ main, not trust "looks post-flip".
- [2026-07-15] **Evaluator wired into the loop's periodic review point** (`Get-EvaluatorVerdict`/`evaluator_verdict`
  in `plugin/engine/lib/gate.*`; `Invoke-PeriodicEvaluation`/`periodic_evaluation` + green-branch restructure
  in `loop.*`). When `verification.evaluator.enabled`, AFTER the fresh-context reviewer returns SHIP the loop
  scores the SAME `base..HEAD` batch against the rubric via a READ-ONLY `evaluate`-phase judge; the review
  watermark advances only when BOTH pass, else it writes a reject-handoff + ledgers `review-stop` + breaks
  (fails closed exactly like a REJECT). It AUGMENTS the review point — no new cadence — so it inherits
  `reviewEveryNIterations>0` + `commitOnGreen` (honest WARN when enabled but no review point). Two things
  worth keeping: (a) the verdict parser is fail-closed **twice over** — last-`^VERDICT:`-line rule (mirrors
  the reviewer) AND a belt-and-braces scan of the whole text for `N/10`; ANY numerator `< failBelow` returns
  FAIL even if the summary line said PASS, so "any below-threshold criterion stops the loop" is enforced in
  CODE, not trusted from the model's self-summary. Strict `<` (score == failBelow is NOT below). Over-matching
  a stray `N/10` in prose only ever yields a FALSE FAIL — the safe direction (stops for a human). (b) In the
  bash parser the score scan MUST loop in the function's own shell (a `for n in $scores` over command-subst),
  NOT `... | while read`, because a `return` inside a pipe subshell would never fail the function closed.
- [2026-07-15] **Multi-judge review point: advance the EXTERNAL watermark only after ALL judges pass** (evaluator
  fix-then-ship). The loop's internal `$reviewBaseRef`/`REVIEW_BASE` was already gated on both reviewer+evaluator,
  but the git tag `harness-reviewed` was force-advanced INSIDE `Invoke-PeriodicReview`/`periodic_review` on the
  reviewer's SHIP — before the evaluator ran. So a reviewer-SHIP-then-evaluator-FAIL batch got tagged "reviewed"
  while the loop stopped, and a later `/review` (which uses that tag as its fallback base) would skip the rejected
  work. Fix: moved the tag OUT of the reviewer fn into the caller's `if ($ok)` / `review_ok=0` block, so it tags
  only after BOTH judges pass (the disabled path still tags on reviewer SHIP because `$ok`=review result). General
  rule: when a gate has N sequential judges, any externally-visible "passed" marker advances only after the LAST one.
- [2026-07-15] **`failBelow` is schema-INTEGER, not `number`** (evaluator fix-then-ship). Rubric scores are `N/10`
  integers; the bash twin compares with `[ "$n" -lt "$fail_below" ]` (integer-only) and the PS twin coerces
  `[int]$FailBelow`. A schema-legal float like `7.5` DIVERGED: bash `-lt` errors inside `if` → falls through →
  fail-OPEN PASS; PS rounds → FAIL. Fixed by constraining the schema to `"type":"integer","minimum":0,"maximum":10`
  (the contract layer) rather than adding float math to both shells. Lesson: when two twins compare a config value,
  pin the value's TYPE in the schema so the shells can't disagree — don't rely on each shell coercing identically.
