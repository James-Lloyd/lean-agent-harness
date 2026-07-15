# S3 build brief — headless cross-vendor dispatcher (`Invoke-Phase`), wired into the loop

**Self-contained EXECUTE brief + sprint contract for fix_plan item "Cross-vendor S3".** The builder starts
here in a fresh context — this file is the contract, not any prior conversation. Parent design (read for
rationale): `docs/execution-plans/2026-07-14-cross-vendor-per-phase-model-routing.md` §3–§4c, §8. This
slice also folds in **S1b** (the `Resolve-PhaseFallback('review')` mixed-config asymmetry).

Component: **root** (the harness engine itself). No app gate; the gate here is the self-test suites.

## Goal (one sentence)
Add a vendor-neutral `Invoke-Phase` dispatcher (primary → fallback across claude↔codex, firing the
fallback ONLY on pre-invocation unavailability or a usage/limit error, write-phase reset-to-base before a
fallback retry, fail-closed on exhaustion) and route the loop's **main implement** call and **periodic
reviewer** through it under the `{model,fallback}` schema — with unit tests that assert the fallback
trigger (unavailable + usage-limit) on both runners.

## Hard rules (violating any = reject)
1. **E1 twin discipline.** Every engine file exists twice: `harness/…` ↔ `plugin/engine/…`. Edit the
   `harness/` copy, then copy it over the `plugin/engine/` twin so they are **byte-identical**. Verify:
   `git diff --no-index harness/<f> plugin/engine/<f>` is EMPTY for every touched file. `.ps1` files carry
   a UTF-8 BOM (a `cp` from the BOM'd `harness/` copy preserves it). Tests live ONLY under `harness/tests/`.
2. **Ratchet (CLAUDE.md Project rules) — usage-limit ONLY on failure.** `Test-UsageLimitError` /
   `usage_limit_error` may be consulted ONLY when an invocation FAILED (not-ok / nonzero rc). It must
   NEVER be evaluated against the output of a SUCCESS. A successful build/review whose text merely mentions
   "overloaded"/"quota"/"429" must be returned as success, never reset+discarded. The parent plan's §4c
   pseudocode (`if ok and not Test-UsageLimitError`) is WRONG on this point — implement the corrected
   logic below.
3. **Fallback trigger is scoped, not "any failure".** The fallback candidate is tried ONLY on (a)
   pre-invocation codex unavailability, or (b) a FAILED invocation that `Test-UsageLimitError` flags. A
   generic non-usage failure (claude crashed, build genuinely red) does NOT advance to the fallback — it
   returns as a failure so the caller handles it exactly as today (implement → rollback+continue; review →
   fail-closed stop). This matches parent §1 ("unavailable or hits a usage/limit error").
4. **Write-phase reset discipline.** In `workspace-write` mode, hard-reset the tree to the iteration base
   BEFORE running a fallback candidate (a usage-limited primary may have left a partial tree). NEVER reset
   before the primary, and NEVER reset in `read-only` mode inside the dispatcher (the caller hard-resets a
   read-only judge afterward, as today). A successful write phase is NOT belt-and-braces reset — that would
   discard the build; the gate + `autoRollbackOnRed` are its safety net.
5. **No behavior change when nothing routes to codex and no usage-limit occurs.** With today's config on a
   machine without codex installed, the implement primary (claude) runs and, on success, the mutated tree
   flows to the gate exactly as before; the periodic reviewer resolves the same way it does today.
6. Do not weaken/delete existing tests. Do not edit `specs/`. Assemble any `git reset --hard` from the
   loop scripts (engine code — allowed there), never as an agent Bash tool call.

## Files to touch (BOTH copies unless noted)
- **NEW** `harness/lib/dispatch.ps1` + `harness/lib/dispatch.sh` (+ `plugin/engine/lib/` twins) — the
  dispatcher. Sourced by the loop AFTER `gate` + `invoke-codex` (it calls `Test-CodexAvailable`,
  `Invoke-Codex`, `Test-UsageLimitError`).
- `harness/lib/gate.ps1` + `gate.sh` (+twins) — **S1b fix** to `Resolve-PhaseFallback` / `phase_fallback`.
- `harness/loop.ps1` + `loop.sh` (+twins) — route the implement call and the periodic reviewer through
  `Invoke-Phase` / `invoke_phase`.
- `harness/tests/run-tests.ps1` + `run-tests.sh` — new dispatcher + S1b assertions.
- `AGENT_NOTES.md`, `state/PROGRESS.md` — learnings (RECORD phase, done by the orchestrator, not builder).

## `Invoke-Phase` — exact contract (PS)
```
Invoke-Phase -Mode <read-only|workspace-write> -Prompt <str> -RepoRoot <path> -LogPath <path>
             [-Primary <model|'codex'|''>] [-Fallback <model|'codex'|''>] [-CodexCfg <obj>]
             [-ResetRef <sha>] [-MaxTurns <int>] [-ClaudeExtraArgs <string[]>]
             [-ClaudeCommand <str>] [-CodexCommand 'codex']
  -> [pscustomobject]@{ Ok=<bool>; Output=<str>; Path=<'codex'|'claude'|$null>;
                        UsedFallback=<bool>; Reason=<''|'invoke-failed'|'exhausted'> }
```
Logic (honors rules 2–4):
```
claudeCmd = ClaudeCommand ?: $env:HARNESS_CLAUDE_CMD ?: 'claude'    # injectable for tests
auth      = CodexCfg.auth ?: 'chatgpt'
candidates = @(Primary) + (Fallback ? @(Fallback) : @())            # Primary '' = inherit ambient claude
lastOut = ''
for idx, cand in candidates:
  isFallback = idx > 0
  if isFallback and Mode == 'workspace-write' and ResetRef:
      git reset --hard ResetRef ; git clean -fd            # write-phase reset BEFORE the fallback
  if cand == 'codex':
      avail = Test-CodexAvailable -Auth auth -CodexCommand CodexCommand
      if not avail.Available: lastOut = "codex unavailable: <reason>"; continue   # (a) advance
      res = Invoke-Codex -Mode Mode -Prompt -RepoRoot -LogPath -CodexCfg -CodexCommand
  else:
      res = Invoke-ClaudePhase -Model cand -Prompt -LogPath -MaxTurns -ExtraArgs ClaudeExtraArgs -ClaudeCommand claudeCmd
  if res.Ok: return { Ok=$true; Output=res.Output; Path=(cand=='codex'?'codex':'claude'); UsedFallback=isFallback; Reason='' }
  lastOut = res.Output
  if Test-UsageLimitError res.Output: continue            # (b) usage-limit -> advance
  return { Ok=$false; Output=res.Output; Path=(...); UsedFallback=isFallback; Reason='invoke-failed' }   # generic failure: stop, DON'T advance
return { Ok=$false; Output=lastOut; Path=$null; UsedFallback=(candidates.Count>1); Reason='exhausted' }
```
Helper `Invoke-ClaudePhase` (in the same lib): runs `claude -p --max-turns <n> [ExtraArgs] [--model <m>]`
with the prompt via STDIN, under the loop's EAP-Continue discipline (native stderr must not throw under
`Stop`; read `$LASTEXITCODE` explicitly). **Preserve live streaming on PS**: pipe through
`Tee-Object -FilePath $LogPath` (no `Out-String` on the live pipe), then read the text back with
`Get-Content $LogPath -Raw` for the return `.Output`. Returns `@{ Ok=($exit -eq 0); Output; Exit }`. Omit
`--model` when `$Model` is ''. When `$LogPath` is empty, skip the file tee.

## `invoke_phase` — bash mirror
Same semantics. bash can't return a struct: **stdout = the phase output**, **return 0 = success / nonzero
= failure**, and set globals `INVOKE_PHASE_PATH` (`codex|claude|""`), `INVOKE_PHASE_USED_FALLBACK`
(`0|1`), `INVOKE_PHASE_REASON` (`""|invoke-failed|exhausted`). Extra claude args come via a
caller-set array `INVOKE_PHASE_CLAUDE_ARGS`. Positional args:
`invoke_phase <mode> <prompt> <root> <log> <primary> <fallback> <reset_ref> <max_turns> <codex_auth>
<codex_model> <codex_effort> <codex_timeout> [claude_cmd] [codex_cmd]`. claude_cmd defaults to
`${HARNESS_CLAUDE_CMD:-claude}`. The claude arm uses the accepted capture idiom (parity with today's
`periodic_review`): `if out="$(printf '%s' "$prompt" | "$claude_cmd" "${cargs[@]}" 2>&1 | tee "$log")";
then rc=0; else rc=$?; fi` (buffered — bash is the headless runner; the loop echoes output after). bash
3.2 / BSD-grep safe; guard `"${INVOKE_PHASE_CLAUDE_ARGS[@]}"` with an emptiness check under `set -u`.

## S1b fix — `Resolve-PhaseFallback('review')` / `phase_fallback` symmetry
Today `Resolve-PhaseModel('reviewFallback')` falls through to legacy top-level `models.reviewFallback`
when the nested `review.fallback` is null/absent, but `Resolve-PhaseFallback('review')` does NOT — so on a
**mixed** config (nested `review:{model,fallback:null}` + a legacy top-level `reviewFallback`) the two
disagree (`'fable'` vs `''`). Make them symmetric: for phase `review` ONLY, `Resolve-PhaseFallback`
resolves to `review.fallback` if non-null, ELSE legacy `models.reviewFallback` if non-null, ELSE `''` —
for the nested-null, flat-string, AND absent-review shapes. Other phases are unchanged. Mirror exactly in
`phase_fallback` (jq). Then switch the loop's review path to use `Resolve-PhaseFallback('review')` /
`phase_fallback review` as the claude-arm fallback model (replacing the `reviewFallback` pseudo-phase
lookup at the call site).

## Wiring — loop implement call
Replace the inline `$prompt | & claude @claudeArgs` block (loop.ps1 ~L298-319 / loop.sh ~L249-255) with:
- Resolve `$implementModel = Resolve-PhaseModel 'implement'` (primary) and
  `$implementFallback = Resolve-PhaseFallback 'implement'` at preflight (next to the existing resolves).
- Capture the iteration base: `$baseRef = git rev-parse HEAD` right before the call (tree is clean here).
- Build `ClaudeExtraArgs`: `--dangerously-skip-permissions` when auto+skipPermissions; `--output-format
  json` when meterTokens (same conditions as today).
- Call `Invoke-Phase -Mode workspace-write -Prompt $prompt -RepoRoot $RepoRoot -LogPath $iterLog
  -Primary $implementModel -Fallback $implementFallback -CodexCfg $codexCfg -ResetRef $baseRef
  -MaxTurns $maxTurns -ClaudeExtraArgs $extra`.
- On `.Ok=false` → same as today's invoke-error: `Write-Ledger {result='invoke-error'; reason;
  path; usedFallback}`, `Restore-Checkpoint`, `continue`. On `.Ok=true` → proceed to tamper-check + gate
  as today. Keep `Update-BudgetFromLog -LogPath $iterLog` (the dispatcher wrote the transcript there).
- Enrich the green/red ledger lines with `path` + `usedFallback` from the result. DryRun output stays.

## Wiring — periodic reviewer
In `Invoke-PeriodicReview` / `periodic_review`, replace the bespoke codex-vs-claude branch (the
`$useCodex` block + the inline claude reviewer invocation) with a single `Invoke-Phase -Mode read-only`
call: `-Primary $Route` (the resolved `review` model, e.g. `codex`), `-Fallback` = the review claude
fallback via the **S1b-fixed** `Resolve-PhaseFallback('review')`, `-ClaudeExtraArgs @('--disallowedTools',
'Edit','Write','MultiEdit','NotebookEdit')`, `-MaxTurns 20`, `-LogPath $reviewLog`, `-CodexCfg $codexCfg`.
Keep everything else: the unconditional `git reset --hard $head` + `git clean -fd` AFTER the call (belt &
braces for a read-only judge), the fail-closed `Get-ReviewVerdict` parse on `.Output`, the ledger `path`
(from `.Path`), and `Write-Reject-Handoff` on non-SHIP / `.Ok=false`. Net effect: the review path now ALSO
falls back to the claude reviewer on a codex **usage-limit** (not just pre-invocation unavailability) — the
new capability — while the unavailable→claude path is preserved.

## Tests to add (both runners) — the fallback trigger is the required assertion
Use a **stub claude** (`HARNESS_CLAUDE_CMD` / `-ClaudeCommand`) and a **stub/absent codex**
(`-CodexCommand 'no-such-codex-xyz'` for unavailable). Assert:
1. **Primary success, no fallback**: stub claude exits 0 with clean output → `Ok=$true`,
   `Path='claude'`, `UsedFallback=$false`.
2. **Usage-limit → fallback fires**: primary (stub claude) exits nonzero with output containing
   `usage limit` → dispatcher advances; fallback (a second stub, or codex made available via a stub codex
   command) succeeds → `Ok=$true`, `UsedFallback=$true`, `Path=` the fallback's vendor.
3. **Codex-primary unavailable → claude fallback**: `Primary='codex'` with `-CodexCommand
   no-such-codex-xyz` (unavailable) + `Fallback=<claude stub>` → `Ok=$true`, `Path='claude'`,
   `UsedFallback=$true`.
4. **Generic (non-usage) failure does NOT advance**: primary stub exits nonzero with clean output (no
   usage marker) → `Ok=$false`, `Reason='invoke-failed'`, `UsedFallback=$false` (fallback NOT consulted —
   assert the fallback stub did not run, e.g. via a marker file it would have created).
5. **Exhaustion**: primary usage-limited + fallback also usage-limited (or unavailable) → `Ok=$false`,
   `Reason='exhausted'`.
6. **Ratchet guard**: primary stub exits **0** with output containing `overloaded`/`quota` → `Ok=$true`,
   `Path='claude'`, `UsedFallback=$false` (a success is NEVER re-examined for usage markers).
7. **S1b symmetry**: on a mixed config (`models.review={model:'codex',fallback:null}` +
   `models.reviewFallback='fable'`), assert `Resolve-PhaseFallback(review) == 'fable'` and equals
   `Resolve-PhaseModel('reviewFallback')`; on nested `review.fallback='sonnet'`, both return `'sonnet'`;
   plain nested non-review with null fallback still returns `''`.
Prefer a stub that is a tiny script echoing a fixed string and exiting a chosen code (mirror the
fleet-queue stub-claude pattern). Keep the dispatcher's git-reset paths OUT of the unit tests (no repo
mutation) — exercise the reset logic via a `read-only` mode call where ResetRef is ignored, or a
workspace-write call with `ResetRef=''`.

## Gate / done-when (the sprint-contract definition of done)
- `powershell -NoProfile -File harness/tests/run-tests.ps1` → all pass (was 99/0; new tests raise it).
- `harness/tests/fleet-queue-test.ps1` → 16/0 (unchanged — S3 doesn't touch the fleet).
- With jq on PATH (POSIX `/c/...` form): `bash harness/tests/run-tests.sh` → all pass (was 90/0);
  `bash harness/tests/fleet-queue-test.sh` → 16/0.
- All touched twins byte-identical (`git diff --no-index` empty).
- E2E evidence (`state/evidence/2026-07-14-cross-vendor-s3/`): the fallback-trigger tests passing on both
  runners (the observable proof), plus a `loop.ps1 -DryRun` transcript showing the loop still starts and
  resolves the implement model under the new dispatcher. **NOTE:** codex CLI IS now installed (v0.144.3,
  logged in via ChatGPT) — but the builder still builds the GATE against **stubs** (deterministic, no
  cost/network); a real live-fire codex run is captured by the orchestrator in VALIDATE, not the builder.
  Keep the write path gated behind the loop's rollback regardless.
