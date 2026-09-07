# Evidence — vendor-agnostic refit V5: supervised live-fire (2026-09-05)

Branch `worktree-v5-second-reviewer-livefire` (from `main` at `9cdd976`, after PRs #11–#14 merged in
stack order that morning), design-doc `docs/design-docs/002-vendor-agnostic-routing.md` slice V5, plugin
0.3.4 → **0.3.5** (engine fixes below). Codex CLI **0.144.3** (npm, ChatGPT-plan auth) on Windows 11.
James was present and approved each probe that needed Codex's hook-trust bypass flag.

Two halves, both done:

1. **The second reviewer on a real diff, shadow mode** — one real second-review transcript, findings compared.
2. **A real Codex hook denial** — observed, but only after the probe found **four V3 defects**, all fixed here.

## Part 1 — the second reviewer on a real diff

### Diff under review
The three unmerged commits on `origin/worktree-s3-reviewer-identity` after PR #9's merge:
`2a6cf25..d8b5200` — `bedc7d5 feat(promotion): wire the separate reviewer identity into /promote
auto-merge`, `22cffcb fix(promotion): apply fresh-context review findings`, `d8b5200 docs(state): record
reviewer-identity wiring`. 12 files, +185/−46: `lib/risk.{sh,ps1}`, `harness.schema.json`,
`plugin/commands/promote.md`, `docs/promotion.md`, `harness-doctor.md`, both test suites, config,
plugin.json, engine CLAUDE.md, fix_plan. A real, previously single-reviewed engine change.

### Configuration (worktree only, reverted before commit — default routing stays single-vendor)
`models.review` gained `"second": { "model": "codex", "effort": "high" }, "codex": { "model":
"gpt-5.6-sol", "reasoningEffort": "high" }` (global `models.codex` null; auth `chatgpt`, timeout 900).
Resolver proof (`lib/gate.sh`): `primary=claude-fable-5-1 fallback=claude-opus-5 · second_model=codex
second_effort=high · codex_model=gpt-5.6-sol codex_effort=high`. `codex-setup.sh` regenerated `.codex/`
(config.toml, hooks.json, 7 agents) and `--check` said fresh; `reviewer.toml` carried `model =
"gpt-5.6-sol"`, `model_reasoning_effort = "high"`, `sandbox_mode = "read-only"` (V2 override → V3 agent).

### Same prompt to both judges — `review-prompt.txt`
The loop's `periodic_review` prompt with the range made explicit (the batch is not checked out; judges
read it via `git diff 2a6cf25..d8b5200` / `git show d8b5200:<path>`), same READ-ONLY discipline, same
blocker/should-fix/nit contract, same single `VERDICT:` line.

### Primary — `reviewer` subagent, Claude Fable 5.1 @ high — `primary-review-fable-final.md`
20 tool uses, 477 s. Extracted the batch tree and **re-ran the bash suite live: 229/0**; checked twin
parity, the fail-closed default, guardrails; swept sibling surfaces. 1 should-fix (batch claims "PS 239/0,
bash 229/0, mutation-verified" but records no evidence artifacts), 1 nit. **VERDICT: SHIP.** Could not run
the PS suite: the worktree-isolation hook refuses `powershell` from a subagent in this session.

### Second — Codex 0.144.3, `gpt-5.6-sol` @ high, read-only — `second-review-codex-*`
Driven through the REAL dispatcher exactly as `loop.sh`'s `second_review()` does (`run-codex-review.sh`
sources `gate.sh` + `invoke-codex.sh` + `dispatch.sh`, calls `invoke_phase read-only … codex "" "" 20
chatgpt gpt-5.6-sol high 900`):
```
codex_args: --sandbox read-only --ask-for-approval never exec - --cd <repo> --skip-git-repo-check
            --output-last-message <tmp> -m gpt-5.6-sol -c model_reasoning_effort="high"
rc=0 path=codex usedFallback=0 reason= seconds=432   parsed verdict=REJECT   tree after judge: unchanged
```
Transcript 459 KB (it read the diff, both risk twins, tests, schema, promote/promotion prose, the S3
evidence dir and the GitHub REST docs). Four blockers, **VERDICT: REJECT**.

### Side by side
| # | Finding | Fable (primary) | Codex (second) | Adjudication after checking the batch |
|---|---|---|---|---|
| 1 | No e2e evidence for the new wiring; the only evidence dir predates it (manual `gh auth switch` + raw approve) | **should-fix** (it re-ran bash 229/0 itself) | **blocker** | Agreed finding, graded differently. By this repo's own rule ("unit-green alone is not done") Codex's grade is the stricter reading. |
| 2 | `docs/promotion.md:59` advertises a GitHub App **installation token**, but the batch's new identity step (`promote.md:100`, `gh api user`) uses `GET /user`, which installation tokens cannot call | not raised | **blocker** | **Real and NEW in the batch** (base named installation tokens; the batch added the step that breaks them). Fails closed → should-fix in our grading. |
| 3 | `/promote` never binds the PR it approves/merges to the classified `BASE..HEAD` range (no `headRefOid`, no `baseRefName == staging` check) | not raised | **blocker** | **Real, PRE-EXISTING** (neither check exists at the base; outside the diff the primary was scoped to). Carried on the S3 fix_plan line. |
| 4 | `risk.json`/ledger record `decision: AUTO` *before* acting; approve/merge failure → HUMAN without finalising the record | not raised | **blocker** | **Real, mostly PRE-EXISTING** ("write BEFORE acting" is §6 at the base; the batch widens the window). Carried with #3. |
| 5 | `[bool]$ReviewerConfigured` coerces a non-empty positional string to `$true` | **nit** | not raised | Theoretical; the sh twin is strict. |

D4 outcome: **REJECT** (SHIP requires both) — advisory here. None of Codex's four blockers was a
hallucination; two were outside the diff, which is the disagreement D4 exists to surface. What the second
opinion bought: one new-in-batch defect the primary missed (#2) and a stricter grade on the one both saw.
Cost: ~7 minutes, one ChatGPT-plan turn, no fallback consumed.

## Part 2 — the real Codex hook denial (and the four V3 defects on the way) — `hook-probe/`

Method: a payload-recording hook (`record-hook.mjs`, allow-all, appends every stdin payload to a file) beside
or instead of the generated hooks; a prompt (`probe-prompt.txt`) asking Codex to run `echo`, then a
denylisted recursive delete against a *nonexistent* scratch path, then `echo`, reporting each call's
outcome verbatim; `--sandbox read-only`, low effort, ~30 s per run. Trust: the worktree (and the main
checkout) were added to `~/.codex/config.toml` as `trust_level = "trusted"` (backup
`config.toml.bak-20260905-v5probe`), and each headless run passed `--dangerously-bypass-hook-trust` (James
approved; the flag is per-invocation and persists nothing).

### Defect 1+2 — the generated `config.toml` did not load on 0.144.3 (fatal, silent)
With the project trusted, Codex read the project `.codex/config.toml` for the first time and died:
```
Error loading config.toml: missing field `enabled` in `skills.config`
```
then, with `enabled = true` added:
```
Error loading config.toml: invalid type: boolean `true`, expected struct AgentRoleToml in `agents`
```
On 0.144.3 `[[skills.config]]` requires `enabled`, and `[agents]` is a table of agent *roles*
(`AgentRoleToml`: `config_file`, `description`, `developer_instructions`, `model_reasoning_effort`,
`sandbox_mode` are the strings in the binary; `default_subagent_model` does **not exist** in it — the
newer docs describe a later version). An untrusted project skips its `.codex/` layer entirely, which is
why the Part 1 review ran fine and why V3's text-asserting tests never saw either error. **Fix (0.3.5):**
generator emits `enabled = true` under the skills path and no `[agents]` block (per-agent model/effort
already lives in `agents/<name>.toml`); tests assert both; docs updated.

### Defect 3 — the project `.codex/hooks.json` is never loaded by headless `exec`
Trusted project + hooks feature on + bypass flag, three file shapes (no matcher / matcher `*` / with the
`_generated_by`,`_shell_matcher_note` keys): **zero events**, not even SessionStart
(`stdout-project-hooks-json-not-loaded.txt`). Then the same recorder in **`~/.codex/hooks.json`** fired
(`transcript-userlevel-hooks-fire.log`, `recorded-payloads-userlevel.jsonl`), and so did hooks passed
inline via `-c 'hooks.SessionStart=[…]'`. Verdict: user-level (`--user`) or inline only; project file is
for interactive sessions. Recorded PreToolUse payload (paths scrubbed):
```json
{"session_id":"01a0714f-…","turn_id":"…","transcript_path":"<home>\\.codex\\sessions\\…","cwd":"<repo>",
 "hook_event_name":"PreToolUse","model":"gpt-5.6-sol","permission_mode":"bypassPermissions",
 "tool_name":"Bash","tool_input":{"command":"echo hello-from-probe"},"tool_use_id":"exec-e9e946dc-…"}
```
So the shell tool is **`Bash`** and the command is `tool_input.command` — `block-destructive` reads the
right field, and `--shell-matcher` now defaults to `Bash` (was a guessed list). Note the rollout shows how
0.144.3 actually runs shell: one `exec` tool executing JavaScript that calls `tools.shell_command(...)`; the
hook layer still presents it as `Bash`.

### Defect 4 — exit code 2 is NOT a denial under Codex (fail-open)
The harness's own `block-destructive` (via `run.mjs`, matcher `Bash`, inline) fired on the `rm -rf`
call, exited 2 with its BLOCKED reason on stderr — and Codex logged
```
hook: PreToolUse
hook: PreToolUse Failed
exec  "…powershell.exe" -Command 'rm -rf <tmp>/probe-dir-does-not-exist' …
```
and **ran the command** (`transcript-exit2-is-NOT-a-denial.log`; it only failed because PowerShell's
`rm` alias has no `-rf`). A probe hook emitting the documented JSON instead
(`deny-hook.mjs`: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
"permissionDecisionReason":"…"}}`, exit 0) produced `hook: PreToolUse Blocked` and
`Command blocked by PreToolUse hook: …` (`transcript-json-deny-blocks.log`). **Fix (0.3.5):**
`run.mjs --codex <hook>` buffers the payload, captures the child's streams, and translates exit 2 +
stderr into that JSON (PreToolUse/PermissionRequest → `hookSpecificOutput`, other events → legacy
`{"decision":"block","reason"}`; exit 0 and other codes pass through). Hook bodies stay single-contract.
`run.test.mjs` grew from 4 to 9 assertions (pure translation table + e2e both ways); the generator emits
`--codex` on every hook command; both suites assert it.

### The denial — `transcript-FINAL-harness-hook-blocks-via-run-mjs-codex.log`, `final-message-FINAL.md`
`node "<repo>/plugin/hooks/run.mjs" --codex block-destructive` under matcher `Bash` (plus `--codex
session-start`), same prompt:
```
hook: SessionStart          hook: SessionStart Completed
hook: PreToolUse            hook: PreToolUse Completed        (echo probe-start — allowed)
hook: PreToolUse
ERROR codex_core::tools::router: error=Command blocked by PreToolUse hook: BLOCKED by harness guardrail: recursive force-delete.
hook: PreToolUse Blocked                                      (rm -rf … — NOT executed)
hook: PreToolUse            hook: PreToolUse Completed        (echo probe-end — allowed)
```
Model's report: *"Blocked before execution … Command blocked by PreToolUse hook: BLOCKED by harness
guardrail: recursive force-delete. Command: rm -rf <tmp>/probe-dir-does-not-exist. If genuinely intended,
ask the human to run it or adjust the harness plugin's hooks/block-destructive.ps1."* — the harness's own
message, verbatim, through Codex.

### Still unverified after V5
- Unknown top-level keys (`_generated_by`, `_shell_matcher_note`) in a **user-level** generated
  hooks.json: the `--user` write was refused by this session's permission classifier (machine-wide file).
  Codex docs show a top-level `description` key, so tolerance is likely. Check: a `--user` install must
  show `hook: SessionStart` in the next transcript.
- `.codex/agents/*.toml` auto-discovery: the second reviewer ran through `codex exec`, not a spawned agent.
  **SETTLED 2026-09-07 → `state/evidence/2026-09-07-codex-agent-role-discovery/` (they are auto-discovered).**

## Gate
bash `harness/tests/run-tests.sh` and PS 5.1 `run-tests.ps1` totals are in the PROGRESS line for this
slice (the config.toml/hooks.json assertions changed shape: +1 net per twin); `run.test.mjs` 9/0.

## Learnings (also in AGENT_NOTES / AGENTS.md ratchets)
- `codex exec` prints two `401 token_expired` ERRORs from the models-cache refresh and runs fine.
- Same prompt, different scope discipline: Fable stayed inside the diff as instructed; Codex judged the
  whole `/promote` flow. The union is the value — do not make the judges agree.
- **A generated config or hook for a foreign tool is verified by making that tool load and act on it**,
  never by asserting the emitted text; and a denial is verified by the command NOT running, not by the
  hook's exit code. V3 was text-green and live-dead on all four counts.
- Trusting the project is necessary but not sufficient for headless hooks; `--user` + bypass/`/hooks`.
- `codex.exe` (npm) lives under `node_modules/@openai/codex-win32-x64/vendor/*/bin/`; grepping it for
  field names (`AgentRoleToml`, `default_subagent_model` absent) settled a docs-vs-installed-version drift
  in a minute. `codex doctor` validates the user config but not project layers.
- The worktree guard refuses inline `source`/`export`/`git -C <other tree>`; the auto-mode classifier
  refused a script writing `~/.codex/hooks.json` machine-wide but allowed the inline `-c hooks.*` route,
  which has no side effects and is the better probe anyway.
