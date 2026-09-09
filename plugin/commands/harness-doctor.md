---
description: Re-runnable health check — validate the harness config, gate, hooks, and baseline are still real and consistent.
argument-hint: (no args)
allowed-tools: Read, Bash, Glob, Grep
---

# /harness-doctor — is the harness still wired correctly?

`/harness-init` verifies the setup **once**. But config gets edited, scripts get renamed, a new model
lands, a stack moves — and the harness silently rots. This command re-checks the load-bearing wiring on
demand. It is **read-only**: it diagnoses and reports; it does not fix (it proposes fixes). Run it after
editing `harness.config.json`, after a stack/tooling change, after a model upgrade, or any time the loop
behaves oddly.

## Checks (report each as ✅ / ⚠️ / ❌, with the specific finding and fix)

1. **Config parses & matches the schema.** `harness/harness.config.json` is valid JSON and conforms to
   the schema (required fields present; enums valid; types right). The schema lives at
   `harness/harness.schema.json` in pre-plugin copied-in layouts, else in the plugin engine
   (`${CLAUDE_PLUGIN_ROOT}/engine/harness.schema.json`, or the installed cache under
   `~/.claude/plugins/cache/lean-agent-harness/**/engine/`) — a migrated repo carrying no local schema
   copy is correct, not a finding. Flag unknown keys. Use a **BOM-tolerant** parser (`jq`/PowerShell
   `ConvertFrom-Json` are fine; `node`'s `JSON.parse` chokes on the UTF-8 BOM the config may carry —
   don't report a false "invalid JSON").

2. **No un-filled placeholders, and the map is importable.** Grep the always-loaded files (`AGENTS.md`, any nested
   component `AGENTS.md`, `AGENT_NOTES.md`, `PROMPT.md`, `harness.config.json`) **and `specs/`** (the shipped
   `specs/000-overview.md` carries `{{OWNER}}`/`{{DATE}}`) for `{{...}}` — any remaining means
   `/harness-init` didn't finish. Then check the **import shim**: the root `CLAUDE.md` (and every nested
   `CLAUDE.md` beside a nested `AGENTS.md`) has, as its FIRST non-blank line, exactly `@AGENTS.md` — that import is
   how Claude Code reads the map (docs/design-docs/002). A `CLAUDE.md` with its own map content instead is
   ❌ two sources of truth; a missing shim next to a nested `AGENTS.md` is ❌ (Claude Code never sees that map).

3. **Components are real.** Each `config.components[].path` exists. The edit-hook's deepest-prefix routing
   has no ambiguous overlaps (two components can't both own the same file unambiguously).

4. **Every gate command resolves and exits 0 on the untouched tree.** For each component (in its own
   directory) and the cross-cutting root gate, run each non-null `format/lint/typecheck/build/test/e2e`
   command. A gate step that errors (command not found, non-zero on clean code) is a ❌ — the gate is the
   harness; a broken gate is worse than none. (This is the same check `/harness-init` step 5 does, made
   repeatable.) Skip `e2e` if it needs a running service the doctor can't stand up — say so explicitly.

5. **Hooks exist and are wired once.** There are exactly **five** hook scripts (`block-destructive`,
   `protect-specs`, `format-and-check`, `session-start`, `lock-config`); each must exist in **both**
   `.ps1` and `.sh` form in the plugin's `hooks/` dir and be wired in the plugin's `hooks/hooks.json`
   through the `run.mjs` dispatcher (which picks the platform flavor at runtime). A duplicate wiring in
   `.claude/settings.json` fires every hook twice — flag it. (Pre-plugin copied-in layouts instead wire
   `.claude/hooks/*` in `.claude/settings.json`, with the command flavor matching the platform.)

6. **Loop dry-run is clean.** Run `powershell harness/loop.ps1 -DryRun` (Windows) or
   `bash harness/loop.sh --dry-run` (Unix) and confirm it reaches "would invoke" without erroring.

7. **Self-tests pass** *(harness dev repo / pre-plugin layouts only)*. If `harness/tests/` exists, run
   `harness/tests/run-tests.{ps1,sh}` for the current platform — these guard the engine's own logic
   (gate routing, denylist, budget, spec-lock). Plugin-consumer repos don't carry the self-tests
   (they live with the engine source); absence there is ✅ N/A, not a failure.

8. **Baseline integrity (brownfield).** If `project.type == brownfield`: `project.baseline.established`
   is true and `baseline.ref` resolves to a real commit. Warn if `HEAD` has drifted far from it (the
   baseline may be stale and worth re-establishing via `/onboard`).

9. **Autonomy sanity.** If `mode == auto`: warn when `skipPermissions == true` without a documented
   sandbox; when `requireE2EEvidence == true` but no component/root gate defines an `e2e` step; and when
   `reviewEveryNIterations == 0` (the unattended loop will run the deterministic gate with no inferential
   judge — fine, but say so).

10. **Model routing agrees across its surfaces (per-phase `{model, fallback, effort, fallbackEffort}`).**
    `config.models` is the declared table — each phase is `{ "model": <primary>, "fallback": <secondary|null>
    }` plus the optional declared efforts of (e), where every
    value is a **known Claude alias** (`opus`/`sonnet`/`haiku`/`fable`) or a full `claude-*` ID, **or**
    the literal **`"codex"`** (cross-vendor OpenAI Codex CLI). Be **tolerant of the legacy flat shape**:
    a bare `"phase": "alias"` normalizes to `{model:"alias", fallback:null}`, and a legacy top-level
    `reviewFallback` to `review.fallback` — treat both as valid, not drift (the resolver normalizes
    them). A missing `models` block is ✅ (routing is optional — everything inherits the session model), but add
    an ℹ️ that every phase then runs one model, judge included, and name the command that fixes it
    (`/harness-init`'s routing step, or `/harness-migrate` step 5 on an already-migrated repo — this
    check is read-only and runs no interview itself);
    a *partial* mismatch is ❌ (silent drift is exactly what this check exists to catch). Verify, in order:
    - **(a) Value legality.** Every `model`/`fallback` is a known Claude alias/ID or `"codex"`; anything
      else (typo, retired alias) is ❌.
    - **(b) Session is Claude.** `.claude/settings.json` `model` == `models.session.model`, and
      `session.model` must be a **Claude** model — `session.model == "codex"` is ❌ (the main window is
      Claude and can't be swapped mid-session, so `session.fallback` is ignored).
    - **(c) Frontmatter tracks the phase's Claude landing model.** Each agent's `model:` frontmatter must
      match its phase — `planner`→`plan`, `generator`→`implement`, `explorer`→`explore`,
      `reviewer`→`review`, `evaluator`→`evaluate`, `doc-gardener`→`docs`. The rule: frontmatter == the
      phase's **primary** when the primary is a Claude model; when the primary is `"codex"`, frontmatter
      must == the phase's **Claude `fallback`** (so a spawned subagent still lands on the right model) and
      you note "phase is codex-routed — frontmatter tracks its Claude fallback." Illustration only: no
      shipped config has a codex-primary phase (`implement` has been `claude-opus-5` with no fallback
      since 2026-08-11, and the harness repo's own 2026-09-09 cross-vendor routing is `review.second`,
      which spawns no subagent), so this branch is currently unexercised by any config in the repo.
      **Order of operations with (i):** if the codex-primary phase is one (i) grades ❌ — `explore` or
      `docs` — then (i) wins and this sub-check does not apply: the frontmatter model is not a
      "fallback" there, it is the only model the phase will ever run on. Report (i)'s error and stop.
      **Consumer repos:** this is ❌ only where the frontmatter is *writable in-repo* — i.e. the harness
      dev repo. If the agents come from the installed plugin cache (no in-repo `plugin/`), a divergence is
      ℹ️, not drift: nobody may edit that cache from a project (`/plugin update` reverts it, and it's
      shared machine-wide), and `/work` pins each subagent from `config.models` per spawn anyway. Say
      which case you're in before you grade this sub-check.
    - **(d) No `codex → codex` fallback.** A `fallback` equal to a `codex` primary is ❌ — there is no
      cross-vendor escape hatch beyond one hop, so both candidates being codex leaves a usage-limit stop
      nowhere to go.
    - **(e) Declared effort tracks frontmatter — where anything enforces it.** `effort`/`fallbackEffort`
      are optional (`minimal|low|medium|high|xhigh|max`); absent = the model default, and absent everywhere
      is ✅. `minimal` on a **Claude** primary/fallback is ⚠️ (codex-only level; the headless dispatcher
      omits the flag and the model default applies). Two graded cases, both ❌ on mismatch, then one
      that needs no grading:
      **(i) Session** — `.claude/settings.json` `effortLevel` == `models.session.effort` (the settings key
      accepts `low|medium|high|xhigh`; `minimal` and `max` have no settings equivalent, so declaring
      either for `session` is ⚠️, not ❌. `CLAUDE_CODE_EFFORT_LEVEL` and `claude --effort` override the
      file at launch — note if the env var is set to something else, don't fail on it).
      **(ii) Subagents** — the agent whose `model:` lands on a phase (same mapping as (c)) must carry the
      matching `effort:`: the phase's `effort` when frontmatter tracks the primary, its `fallbackEffort`
      when frontmatter tracks the Claude fallback (`generator` → `implement`; an absent `fallbackEffort`
      inherits `effort`).
      **(iii) Headless** — the loop/fleet dispatcher passes `--effort` on its Claude arm (primary at
      `effort`, fallback at `fallbackEffort`, else `effort`) straight from the config, so there is no
      second file to drift from; nothing to grade beyond this sub-check's own enum line above.
      Everything else declared here has **no enforcing file** — report ℹ️, never ❌: a `fallbackEffort` on
      a **Claude-primary** phase under an **interactive** `/work` re-spawn (that re-spawn pins `model:`
      only, so `review`/`evaluate` fallback depth is advisory there, though honored headlessly) and the
      `effort` of a **codex-primary** phase (codex reads the phase's `codex.reasoningEffort`, else the
      global `models.codex.reasoningEffort` — see (g); that phase's
      Claude arm is its *fallback*, governed by `fallbackEffort`).
    - **(f) Codex reachability (⚠️ not ❌), for every codex-routed phase.** For **each** phase whose
      `model`, `fallback`, or (on `review`) `second.model` is `"codex"`, probe `codex --version` and (auth `chatgpt`) `codex login
      status` exit 0, or (auth `api-key`) `CODEX_API_KEY` set. Unavailable is ⚠️ not ❌ — that phase runs
      on (or falls back to) its Claude arm by design; say which path each codex-routed phase would take
      today.
    - **(g) Per-phase codex overrides are read, and legal.** A phase may carry `codex: { model,
      reasoningEffort }` (design-doc 002 D2), merged over the global `models.codex` by the engine's
      `phase_codex_model`/`phase_codex_effort` (sh) and `Resolve-PhaseCodexCfg` (ps1). It is consumed
      ONLY when that phase's `model`, `fallback`, or (on `review`) `second.model` is `"codex"` — on any
      other phase it is a key nothing reads (ratchet 2026-08-11): ⚠️, name the phase, suggest deleting the
      block or routing the phase to codex. **`review.codex` beside a Claude primary and a codex `second`
      is READ — do not warn on it:** `second_review`/`Invoke-SecondReview` pass the review phase's
      `REVIEW_CODEX_MODEL`/`REVIEW_CODEX_EFFORT` to the second judge, which is the pairing the
      model-routing skill recommends as the first use of Codex. **Second carve-out, whenever `.codex/`
      is generated:** `engine/codex-setup.*` resolves `phase_codex_model`/`phase_codex_effort` for every
      mapped agent phase (planner, generator, reviewer, evaluator, explorer, doc-gardener) **ungated by
      that phase's route**, to write `.codex/agents/<name>.toml`. So a `codex{}` block on an unrouted
      phase — `explore` and `docs` included — is read by the generator even when the phase's `model` is
      not. Do not call it dead: say it tunes the generated Codex role only, and never suggest deleting
      it while `.codex/` exists. `reasoningEffort` there must be a codex level (`minimal|low|medium|high|xhigh`; `max` is
      Claude-only) — anything else is ❌. `auth`/`timeoutSeconds` inside a per-phase block are ❌
      (global-only; the engine ignores them there). Report the effective `-m`/effort each codex-routed
      phase would run with, so a stale pinned GPT ID (every `*-codex` ID is retired) is visible.
    - **(h) Second reviewer.** `models.review.second{model,effort}` (design-doc 002 D4) is read by the
      loop's review point and `/review` only: on any other phase it is an unread key - ⚠️. When set:
      `model` must be a legal Claude alias/ID or `"codex"` (❌ otherwise); `second.model` equal to
      `review.model` (or to its resolved Claude fallback) is ⚠️ "self-review - no diversity"; a `codex`
      second is probed like (f) and reported ⚠️ when unreachable, with the consequence spelled out:
      the second reviewer has NO fallback, so an unreachable one stops every review point fail-closed
      until it is reachable or removed. Say which pair will actually judge (e.g. "claude-fable-5-1 then
      codex gpt-5.6-sol").
    - **(i) A codex route must have somewhere to be dispatched FROM.** The literal `"codex"` is legal
      *syntax* on every phase, but only some phases have code that acts on it, and a value nothing reads
      is worse than no value at all (ratchet 2026-08-11) — it advertises a control that does not exist.
      Grade each codex-routed phase against where it is actually honoured:

      | phase | headless (`loop.*`, `fleet.*`) | interactive (`/work`, `/review`) | `"codex"` verdict |
      |---|---|---|---|
      | `session` | — | — | ❌ (see (b)) |
      | `plan` | **no dispatch site** | `/work` PLAN, workspace-write | ⚠️ interactive-only |
      | `explore` | **no dispatch site** | **none** | ❌ unread key |
      | `implement` | `loop.*` iteration + `fleet.*` worker | `/work` EXECUTE | ✅ |
      | `review` | `loop.*` review point | `/review` | ✅ |
      | `review.second` | `loop.*` review point | `/review` step 3 | ✅ |
      | `evaluate` | `loop.*` evaluate point | `/work` | ✅ |
      | `docs` | **no dispatch site** | **none** (`/gc` has no routing block) | ❌ unread key |

      So: **`docs: "codex"` and `explore: "codex"` are ❌** — no path dispatches either, so the
      doc-gardener and explorer run on their frontmatter Claude model whatever the config says. Suggest
      a Claude tier or `null`. `explore` is the one most likely to be *mis*-graded, and was, in this
      check's first draft: `commands/work.md` names `explorer`→`explore` in its phase-mapping list, but
      no `/work` step ever dispatches an explore phase, and `work.md`'s own rule is "**No subagent ever
      wraps codex**" — so the only way exploration happens is an Agent-tool spawn that lands on Claude
      by construction. **`plan` routed to codex is ⚠️, not ❌** — `/work`'s PLAN step really does route
      the planner per the routing table in workspace-write mode, and the headless loop really does
      ignore it, so name BOTH halves rather than calling it broken or fine: a repo that runs the loop
      overnight gets Claude there whatever the config says.
      **Carve-out, so this does not contradict (g):** a `codex{}` block on `explore` or `docs` is NOT an
      unread key even though the phase's `model` is. `engine/codex-setup.*` resolves
      `phase_codex_model`/`phase_codex_effort` for **every** mapped agent phase — planner, generator,
      reviewer, evaluator, explorer, doc-gardener — ungated by that phase's route, to write
      `.codex/agents/<name>.toml`. So those blocks are read whenever the Codex surfaces are generated,
      and telling an operator to delete one silently retunes the generated Codex role. Grade the
      `model`, not the block.
      **How to re-derive this table if the engine has changed** — and derive it from dispatch, not from
      bookkeeping, which is the mistake that produced the wrong `explore` row: a phase is honoured on a
      path only where some code **resolves that phase and invokes the vendor lib**. Headless = the
      phases `loop.{sh,ps1}` and `fleet.{sh,ps1}` resolve into `*_MODEL`/`*_ROUTE` variables and pass to
      `invoke_phase`/`Invoke-Phase`. Interactive = a command STEP that resolves the phase and dispatches
      it (`work.md`'s PLAN/EXECUTE/REVIEW/EVALUATE steps, `review.md` step 3) — **a phase-name mapping
      list is not a dispatch site, and a subagent spawn is not a vendor dispatch.**

11. **Risk-gated promotion (`promotion` block).** Skip entirely (report ℹ️ "not configured") when the
    block is absent — it is opt-in and most repos won't have it. When present:
    - **(a) Prod is unautomatable.** `promotion.prod.autoMerge` must be `false`, and the schema's
      `properties.promotion.properties.prod.properties.autoMerge.const` must still be `false`. Either
      one being otherwise is **❌ and the single most important finding in the report** — it means
      someone has made "auto-merge to prod" expressible, which is a policy change, not a tuning
      change. Same for `promotion.staging.autoMergeAtOrBelow`: legal values are `"low"` or `null`
      only, and the schema enum must not have grown a `medium`/`high` member.
    - **(b) Guarding the money surfaces.** With `enabled: true`, `promotion.alwaysHuman` and
      `promotion.moneySignals` must both be non-empty — ❌ otherwise. An enabled policy with an empty
      money list auto-merges payment code, which is the one outcome this feature exists to prevent.
      Also sanity-check the globs against the repo: if `alwaysHuman` matches **no** path in a codebase
      that clearly handles money (grep for payment/billing/checkout dirs), report ⚠️ with the paths it
      is missing — a glob that matches nothing is indistinguishable from no policy at all.
    - **(c) Branches resolve.** `promotion.staging.branch` and `promotion.prod.branch` must exist
      (`git rev-parse --verify`) — ⚠️ if not (the branch may legitimately not exist yet), and say so.
    - **(d) Preconditions are not disarmed.** With `enabled: true`, all three of
      `preconditions.{gateGreen, reviewShip, e2eEvidence}` should be `true`. Any `false` is ⚠️ with
      the consequence spelled out (e.g. `reviewShip: false` ⇒ a LOW diff auto-merges with no
      fresh-context review at all).
    - **(e) The criteria table matches the skill.** `plugin/skills/risk-tiering/SKILL.md` is the SSOT;
      every `criteria.escalatePaths` category and the `maxChangedLines` value must appear in its
      table. ❌ on drift (the twin self-tests pin this too — if doctor sees drift the suite is red).
    - **(f) `gh` reachability (⚠️ not ❌).** Probe `gh --version` and `gh auth status`. Unavailable
      just means every promotion takes the human path — say so rather than failing. Additionally, if
      `gh auth status` reports the **same** identity that authors commits here, report ⚠️: GitHub
      rejects self-approval, so auto-approval will fail until a separate reviewer identity is
      configured (`docs/promotion.md`).
    - **(g) A separate reviewer identity is wired for auto-merge.** When auto-merge is armed
      (`enabled: true` **and** `staging.autoMergeAtOrBelow == "low"`), `promotion.reviewer.tokenEnv`
      must be a non-empty string naming an environment variable — ❌ otherwise, because without it
      `/promote` fails closed and **nothing can ever auto-merge** (the feature is armed but inert).
      Doctor cannot read the promotion runtime's secrets, so also report ⚠️ reminders: the named
      variable must actually hold a *write*-access token for an identity **other** than the commit
      author, and the repo's "Allow auto-merge" setting must be on for `gh pr merge --auto` to work
      (`docs/promotion.md` §3). When auto-merge is not armed, this is ℹ️ only.

12. **Codex surfaces are generated and fresh (only when anything routes to codex).** Skip with ℹ️
    "no phase routes to codex" when no `models.*.model`, `models.*.fallback` or (on `review`)
    `models.review.second.model` is `"codex"` and there is no `.codex/` dir. **The `second.model` arm of
    that predicate is load-bearing** (added 2026-09-09): a config whose only codex route is the second
    reviewer satisfied the old two-term skip on a machine where `.codex/` had not been generated yet —
    so the check silently disabled itself on exactly the config that needs it, while every loop review
    point invoked the Codex CLI against ungenerated hooks and agents. Otherwise run the generator's own check — `bash harness/codex-setup.sh --check` (or
    `powershell harness/codex-setup.ps1 -Check`; wrappers copied by `/harness-init`, engine script
    `${CLAUDE_PLUGIN_ROOT}/engine/codex-setup.*`; if the wrappers are absent, e.g. a `/harness-migrate`d
    repo, run the engine script with `--project-root <repo>` directly) — and grade its output: `fresh`
    (exit 0) = ✅; `NOT generated` (exit 1) = ❌ when anything routes to codex — a phase's `model`,
    `fallback`, or `review.second.model` (its hooks/agents/skills do not exist for Codex yet — run the
    generator), ⚠️ when nothing routes there; `STALE` (exit 1) = ⚠️ (an
    input changed since generation — re-run). Note `block-destructive` is generated under the
    shell-tool matcher `Bash` (`_shell_matcher_note` in the file; recorded live from Codex 0.144.3 in V5),
    and every hook command carries `run.mjs --codex` — Codex ignores exit code 2, so the dispatcher must
    translate a denial into the JSON `permissionDecision` output; a hooks.json whose commands lack `--codex`
    is stale from before V5 and fails open — ❌. Also confirm `.gitignore` contains a line that is exactly
    `.codex/` — a tracked `.codex/` is ❌ (it embeds this machine's absolute plugin path; ratchet
    2026-07-30). Finally, remind that under headless `codex exec` the repo's `.codex/hooks.json` is
    never loaded (V5-verified, even trusted + bypass flag) — only `--user`'s `~/.codex/hooks.json` fires,
    and only once trusted via `/hooks` or with `--dangerously-bypass-hook-trust` (`docs/codex-setup.md`, first
    paragraph) — an ℹ️, since it is Codex's policy, not drift.

## Output
A short checklist (one line per check, ✅/⚠️/❌/ℹ️ + the finding — ℹ️ for a check that does not apply,
e.g. an opt-in block a repo has not configured) and, at the end, the single most important
thing to fix if anything is red. Recommend `/ratchet` for any failure class that should never recur.
Also advise running Claude Code's native `/doctor`: this command checks *harness* semantics; `/doctor`
validates the settings/hooks/skills at the platform level — the two are complementary, not redundant.
