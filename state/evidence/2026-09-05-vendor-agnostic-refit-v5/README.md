# Evidence — vendor-agnostic refit V5: supervised live-fire of the second reviewer (2026-09-05)

Branch `worktree-v5-second-reviewer-livefire` (from `main` at `9cdd976`, after PRs #11–#14 merged in
stack order that morning), plugin 0.3.4, design-doc `docs/design-docs/002-vendor-agnostic-routing.md`
slice V5. **Shadow mode:** the second verdict is advisory; nothing gated on it and the routing change
was reverted before commit (the shipped default stays single-vendor Claude).

Status: **step (1) done** — one real second-review transcript, both judges' findings compared below.
**Step (2) pending** — the real Codex hook denial (see "Step 2" at the end): the probe script is
written and staged here, but running it was refused by the Claude Code auto-mode permission classifier
in this session, so it needs James to run it by hand (supervise-first anyway).

## Step 1 — the second reviewer on a real diff

### Diff under review
The three unmerged commits on `origin/worktree-s3-reviewer-identity` after PR #9's merge:
`2a6cf25..d8b5200` — `bedc7d5 feat(promotion): wire the separate reviewer identity into /promote
auto-merge`, `22cffcb fix(promotion): apply fresh-context review findings`, `d8b5200 docs(state): record
reviewer-identity wiring`. 12 files, +185/−46: `lib/risk.{sh,ps1}`, `harness.schema.json`,
`plugin/commands/promote.md`, `docs/promotion.md`, `harness-doctor.md`, both test suites, config,
plugin.json, engine CLAUDE.md, fix_plan. A real, previously single-reviewed engine change — exactly the
shape the second reviewer exists for.

### Configuration (worktree only, reverted before commit)
`harness/harness.config.json` → `models.review` was changed from the shipped
`{ model: claude-fable-5-1, fallback: claude-opus-5, effort: high, fallbackEffort: medium }` to the same
plus `"second": { "model": "codex", "effort": "high" }, "codex": { "model": "gpt-5.6-sol",
"reasoningEffort": "high" }` (global `models.codex` stays `null`; auth defaults to `chatgpt`, timeout 900).

Resolver proof (`lib/gate.sh`, run against that config):
```
primary=claude-fable-5-1 fallback=claude-opus-5
second_model=codex second_effort=high
codex_model=gpt-5.6-sol codex_effort=high
```
`harness/codex-setup.sh` then regenerated `.codex/` (config.toml, hooks.json, 7 agents) for plugin 0.3.4
and `--check` reported **fresh** (rc 0). The generated `reviewer.toml` carried
`model = "gpt-5.6-sol"`, `model_reasoning_effort = "high"`, `sandbox_mode = "read-only"` — the per-phase
codex override (V2) reaching the generated agent (V3), as designed.

### Same prompt to both judges
`review-prompt.txt` — the loop's `periodic_review` prompt with the range made explicit (the batch is
not checked out; judges read it via `git diff 2a6cf25..d8b5200` / `git show d8b5200:<path>`), the same
READ-ONLY discipline, the same blocker/should-fix/nit contract and the same single `VERDICT:` line.

### Primary judge — `reviewer` subagent, Claude Fable 5.1 @ high
`primary-review-fable-final.md` (verbatim). 20 tool uses, 477 s. It extracted the batch tree and
**re-ran the bash suite live: 229/0**, checked twin parity, the fail-closed default, guardrails, and swept
sibling surfaces. Findings: 1 should-fix (the batch claims "PS 239/0, bash 229/0, mutation-verified" but
records no evidence artifacts), 1 nit (`[bool]` coercion of a positional string in `risk.ps1`).
**VERDICT: SHIP.** It could not run the PowerShell suite: the worktree-isolation hook refuses
`powershell` invocations from a subagent in this session (noted under learnings).

### Second judge — Codex CLI 0.144.3, `gpt-5.6-sol` @ high, read-only sandbox
Driven through the REAL engine dispatcher exactly as `loop.sh`'s `second_review()` does
(`run-codex-review.sh` sources `gate.sh` + `invoke-codex.sh` + `dispatch.sh` and calls
`invoke_phase read-only … codex "" "" 20 chatgpt gpt-5.6-sol high 900`):
```
codex_args: --sandbox read-only --ask-for-approval never exec - --cd <worktree> --skip-git-repo-check
            --output-last-message <tmp> -m gpt-5.6-sol -c model_reasoning_effort="high"
rc=0 path=codex usedFallback=0 reason= seconds=432
parsed verdict=REJECT            (review_verdict, fail-closed last-VERDICT-line parse)
tree after judge: only the deliberate config edit — the judge mutated nothing
```
Full transcript `second-review-codex-transcript.log` (459 KB, 3.9k lines: it read the diff, both risk
twins, tests, schema, promote/promotion prose, the S3 evidence dir and the GitHub REST docs); final
message `second-review-codex-final.md`. Four blockers, **VERDICT: REJECT**.

### The two verdicts side by side
| # | Finding | Fable 5.1 (primary) | Codex gpt-5.6-sol (second) | Adjudication (James/Claude, after checking the batch) |
|---|---|---|---|---|
| 1 | Batch records no e2e evidence for the new wiring; the only evidence dir predates it and shows manual `gh auth switch` + raw approve, not `reviewer.tokenEnv` → identity compare → decision → audit → conditional merge | **should-fix** (it independently re-ran bash 229/0, so not gating) | **blocker** (violates "every change carries e2e evidence") | **Agreed finding, graded differently.** By this repo's own rule ("unit-green alone is not done") Codex's grading is the stricter reading of the contract. Fix: run the integrated path against a controlled PR and record it. |
| 2 | `docs/promotion.md:59` advertises a GitHub App **installation token** as a valid reviewer identity, but the batch's new identity step (`promote.md:100`, `GH_TOKEN=$tok gh api user`) uses `GET /user`, which installation tokens cannot call — the advertised path always fails closed | not raised | **blocker** | **Real and NEW in this batch** (the base already named installation tokens; the batch added the `gh api user` step that breaks them). Fails closed, so no unsafe merge — should-fix in our grading: drop the installation-token claim or add an installation-specific identity path. |
| 3 | `/promote` classifies local `BASE..HEAD` but never binds the PR it later approves/merges to that range (no `headRefOid == HEAD`, no `baseRefName == promotion.staging.branch` check) — could merge a newer PR, or one targeting `main` | not raised | **blocker** | **Real design gap, PRE-EXISTING** (neither check exists at the base either; the batch did not touch §1/§2). Outside the diff; the primary was told to stay traceable to the diff. Carry as its own fix_plan item. |
| 4 | `risk.json` + ledger record `decision: AUTO` *before* acting; an approve/merge failure then takes HUMAN without finalizing either record, so the durable audit can say AUTO for a promotion that never happened | not raised | **blocker** | **Real, mostly PRE-EXISTING** ("write BEFORE acting" is §6 at the base). The batch's new approve-fail → HUMAN branch widens the window. Carry with #3: append an outcome row after §8. |
| 5 | `[bool]$ReviewerConfigured` coerces a non-empty positional string to `$true` | **nit** | not raised | Theoretical; the sh twin is strict. |

Under D4 the batch's verdict is **REJECT** (SHIP requires both) — advisory here. Read as a
fix-then-ship: #1 and #2 are actionable on the s3 branch; #3 and #4 are `/promote` design gaps to fix
before `promotion.enabled` is ever flipped. None of the four Codex blockers was a hallucination; two
were out of the diff's scope, which is the disagreement D4 was built to surface. **What the second
opinion bought:** one new-in-batch defect the primary missed (#2) and a stricter grade on the one both
saw (#1). What it cost: ~7 minutes and a ChatGPT-plan turn, no fallback consumed.

## Learnings
- **`codex exec` logs two `401 token_expired` ERRORs from `codex_models_manager` on start and then runs
  fine** — they are the models-list cache refresh, not the session; `codex login status` said signed in.
  Do not treat a 401 in the transcript as the usage-limit/unavailable trigger — `codex_available` (the
  login-status probe) and the exit code are what the dispatcher keys on, and they were correct here.
- **Same prompt, different scope discipline.** Fable stayed inside the diff as instructed; Codex judged
  the whole `/promote` flow the diff touches. Both are defensible; the union is the value. The D4 prose
  "note where they disagree" is the right instruction — do not try to make the judges agree.
- **The worktree-isolation hook blocks a reviewer subagent's `powershell` calls**, so a judge on Windows
  can run the bash twin live but not the PS twin from inside a worktree session. CI covers it; a doc
  note belongs in `plugin/engine/AGENTS.md` if this recurs.
- **The auto-mode classifier refuses a script that carries Codex's `--dangerously-bypass-hook-trust`**
  (needed so a headless run honours a repo's `.codex/hooks.json` without persisting trust) even when
  the target is a nonexistent scratch path inside a read-only sandbox. Step 2 is therefore a human-run
  probe — consistent with "supervise-first", and a fact for `docs/codex-setup.md`.

## Step 2 — real Codex hook denial (pending; human-run)
Artifacts staged, unrun: `probe-hooks.sh` (driver), `record-hook.mjs` (allow-all hook that appends every
payload Codex sends to `hook-payloads.jsonl`), `probe-prompt.txt` (asks Codex to run `echo`, then a
denylisted recursive delete against a nonexistent scratch path, then `echo`, and report each tool call's
outcome verbatim). The driver: copies the generated `.codex/hooks.json`, adds the recorder under `*` on
PreToolUse/PostToolUse/SessionStart/UserPromptSubmit/Stop, runs ONE `codex exec` with `--sandbox
read-only -c features.hooks=true --dangerously-bypass-hook-trust`, prints the recorded `tool_name`s and
PreToolUse payloads, greps the transcript for the `BLOCKED by harness guardrail` line, then regenerates
`.codex/` and re-checks it. Expected outputs, in order: (a) whether Codex parses a `hooks.json` with the
`_generated_by`/`_shell_matcher_note` top-level keys (if not, no event is recorded at all), (b)
SessionStart firing, (c) the real shell tool name → pin `--shell-matcher` and drop the "best guess"
wording, (d) the `tool_input` field names → confirm `block-destructive` reads `.tool_input.command`,
(e) the denial itself. Run from Git Bash (not `bash` from PowerShell, which is the WSL launcher):
```
"C:\Program Files\Git\bin\bash.exe" <scratchpad>/probe-hooks.sh     # or the copy in this directory,
                                                                     # after fixing its W= and S= paths
```
