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

2. **No un-filled placeholders.** Grep the always-loaded files (`CLAUDE.md`, any nested component
   `CLAUDE.md`, `AGENT_NOTES.md`, `PROMPT.md`, `harness.config.json`) **and `specs/`** (the shipped
   `specs/000-overview.md` carries `{{OWNER}}`/`{{DATE}}`) for `{{...}}` — any remaining means
   `/harness-init` didn't finish.

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
    them). A missing `models` block is ✅ (routing is optional — everything inherits the session model);
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
      you note "phase is codex-routed — frontmatter tracks its Claude fallback." With the shipped config
      this is the `generator` branch (`implement = {codex, opus}` → `generator` frontmatter must be `opus`).
    - **(d) No `codex → codex` fallback.** A `fallback` equal to a `codex` primary is ❌ — there is no
      cross-vendor escape hatch beyond one hop, so both candidates being codex leaves a usage-limit stop
      nowhere to go.
    - **(e) Declared effort tracks frontmatter — where anything enforces it.** `effort`/`fallbackEffort`
      are optional (`minimal|low|medium|high|xhigh`); absent = the model default, and absent everywhere
      is ✅. Two enforced cases, both ❌ on mismatch:
      **(i) Session** — `.claude/settings.json` `effortLevel` == `models.session.effort` (the settings key
      accepts `low|medium|high|xhigh`; `minimal` has no settings equivalent, so declaring it for `session`
      is ⚠️. `CLAUDE_CODE_EFFORT_LEVEL` and `claude --effort` override the file at launch — note if the
      env var is set to something else, don't fail on it).
      **(ii) Subagents** — the agent whose `model:` lands on a phase (same mapping as (c)) must carry the
      matching `effort:`: the phase's `effort` when frontmatter tracks the primary, its `fallbackEffort`
      when frontmatter tracks the Claude fallback (`generator` → `implement`; an absent `fallbackEffort`
      inherits `effort`).
      Everything else declared here has **no enforcing file** — report ℹ️, never ❌: a `fallbackEffort` on
      a **Claude-primary** phase (the usage-cap re-spawn pins `model:` only, so `review`/`evaluate`
      fallback depth is advisory) and the `effort` of a **codex-primary** phase (codex reads
      `models.codex.reasoningEffort`; that phase's Claude arm is its *fallback*, governed by
      `fallbackEffort`).
    - **(f) Codex reachability (⚠️ not ❌), for every codex-routed phase.** For **each** phase whose
      `model` OR `fallback` is `"codex"`, probe `codex --version` and (auth `chatgpt`) `codex login
      status` exit 0, or (auth `api-key`) `CODEX_API_KEY` set. Unavailable is ⚠️ not ❌ — that phase runs
      on (or falls back to) its Claude arm by design; say which path each codex-routed phase would take
      today.

## Output
A short checklist (one line per check, ✅/⚠️/❌ + the finding) and, at the end, the single most important
thing to fix if anything is red. Recommend `/ratchet` for any failure class that should never recur.
Also advise running Claude Code's native `/doctor`: this command checks *harness* semantics; `/doctor`
validates the settings/hooks/skills at the platform level — the two are complementary, not redundant.
