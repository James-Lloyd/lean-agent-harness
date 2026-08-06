---
name: model-routing
description: Choose the model and reasoning effort for each harness phase (orchestrator, planner, implementer, reviewer, evaluator, explorer, docs) and write the choice to every surface that enforces it. Use during /harness-init, during /harness-migrate when a repo has no routing block, and whenever someone asks to change which model runs a phase.
---

# model-routing

The harness runs each phase on a **deliberately different** model. A cheap scout shouldn't cost what a
judge costs; the judge shouldn't be the same context that wrote the code. This skill owns the
recommended table, the interview that offers it, and the contract for writing the answer down.

**This file is the single source of truth for the defaults.** `/harness-init`, `/harness-migrate` and
`/harness-doctor` point here rather than restating the table — one owner, so a retune can't leave a
stale copy behind in a sibling command.

## The recommended defaults

| Phase | Agent | model | effort | fallback | Why this one |
|-------|-------|-------|--------|----------|--------------|
| `session` | (the main window — you) | `opus` | `medium` | (n/a) | The **orchestrator**. It dispatches, sequences and reports; the deep thinking belongs to the phase agents. Medium keeps the cheap work cheap. **Must be Claude** — the main window can't swap vendor mid-session. |
| `plan` | `planner` | `fable` | `high` | `null` | Design is where a bad call is most expensive. Deepest reasoner, highest effort. Interactive, so a usage cap is recoverable by hand — no fallback needed. |
| `implement` | `generator` | `codex` | `high` | `opus` @ `high` | Cross-vendor builder (OpenAI Codex CLI). A second vendor on the build step means a Claude usage cap doesn't stop the loop, and the judge that reviews it is a different model family than the one that wrote it. |
| `review` | `reviewer` | `fable` | `high` | `opus` @ `medium` | Fresh-context judge — the doer must never be the judge. Judges get the strongest model. Cap-proof Claude fallback because headless runs can't ask a human for help. |
| `evaluate` | `evaluator` | `fable` | `high` | `opus` @ `medium` | Rubric scorer at the sprint gate. Same reasoning as `review`. |
| `explore` | `explorer` | `haiku` | `low` | `null` | Read-only scout for fan-out searches. High volume, shallow judgment — the one place to spend nothing. |
| `docs` | `doc-gardener` | `haiku` | `low` | `null` | Small, safe documentation edits. |

Values may be a **Claude alias** (`opus`/`sonnet`/`haiku`/`fable`), a full `claude-*` ID, or the literal
**`codex`**. Effort is `minimal|low|medium|high|xhigh`; absent = the model's own default. `fallback: null`
= no fallback (the phase just fails when its primary does); a whole phase set to `null`, or an absent
`models` block, = inherit the ambient session model.

## Running the interview

**Lead with the table, not with a blank form.** Most people want the defaults; make accepting them one
keystroke and make customizing possible without a seven-question interrogation.

0. **Read what's already there first.** If `harness/harness.config.json` already has a `models` block,
   it is somebody's decision, not drift — never overwrite it because it differs from this table. Show
   **current vs proposed** side by side and make the options: *keep mine unchanged*, *keep mine and
   fill only what's missing* (the honest default for a legacy block — e.g. it declares models but no
   `effort`), or *replace with the recommended table*. Only a repo with **no** block gets step 1's
   phrasing.
1. **One question first (`AskUserQuestion`).** Show the defaults as a compact summary and offer:
   - *Accept the recommended routing* (recommended) — write the table above verbatim.
   - *Customize per phase* — go to step 2.
   - *Inherit everything from the session model* — write no `models` block at all. Legitimate for a
     small repo or an account with one model available; say plainly that the doer/judge split then
     runs on one model, which weakens review independence.
2. **Only if they customize**, ask **one question per phase** — someone who declined the defaults wants
   per-phase control, so don't pair phases into a single question (that makes `review` ≠ `evaluate`
   unexpressible). `AskUserQuestion` takes at most 4 questions per call with 4 options each, so batch
   them across calls in this order: `session`, `plan`, `implement`, `review` — then `evaluate`,
   `explore`, `docs`. Offer each phase's default as the first option, labelled *(Recommended)*. Put
   effort in the option label (e.g. "fable @ high") rather than asking a second question per phase —
   doubling the question count for a value most people never change isn't worth it.
3. **Ask about codex only if it's real.** Before offering a `codex` route, probe `codex --version`, then
   its auth the way the engine does (`lib/invoke-codex.*`): `auth: chatgpt` → `codex login status` exits
   0; `auth: api-key` → `CODEX_API_KEY` is set. Don't report an api-key user as "not signed in" for
   failing the chatgpt probe. `codex login status` also false-negatives against Azure/custom providers
   (`AGENT_NOTES.md`) — if the human says codex works, believe them over the probe. If it genuinely
   isn't there, say so and offer the Claude-only variant (`implement` = `opus` @ `high`) instead of
   writing a route that silently falls back forever.

### Constraints to enforce as you collect
- `session.model` **must be Claude** — `codex` there is invalid, not a preference.
- A `fallback` must not equal a `codex` primary (no `codex → codex`; there's one hop of escape, not two).
- Steer `session.effort` to `low|medium|high|xhigh` — `minimal` has no `effortLevel` equivalent, so it
  can't be written to settings.json. This is interview guidance, not a validation rule: doctor 10(e)(i)
  reports `minimal` there as ⚠️, so don't "fix" the doctor to hard-fail it.
- A phase whose primary is `codex` takes its **depth** from `models.codex.reasoningEffort`, and its
  Claude arm is the *fallback* — so that phase's agent frontmatter tracks `fallbackEffort`.

## Writing the answer down (all surfaces together, or not at all)

Routing is **declared** in the config and **enforced** by whatever reads it. Write every surface you're
allowed to write in the same change — a partial write is the silent drift `/harness-doctor` check 10
exists to catch.

**Which surfaces you may write depends on where you are.** Check first: does this repo contain
`plugin/.claude-plugin/plugin.json` (you're in the harness dev repo), or does it consume an installed
plugin (there's no in-repo `plugin/`, and `.claude/agents/` is absent or plugin-provided)?

| Surface | Gets | Write it in… |
|---------|------|--------------|
| `harness/harness.config.json` → `models` | `{model, fallback, effort, fallbackEffort}` per phase | **Both.** The declared table, and the one that actually routes at runtime. Also `models.codex` (`model`, `reasoningEffort`, `auth`, `timeoutSeconds`) if any phase routes to codex. |
| `.claude/settings.json` | `model` = `session.model`, `effortLevel` = `session.effort` | **Both.** `CLAUDE_CODE_EFFORT_LEVEL` and `claude --effort` override `effortLevel` at launch. |
| the plugin's `agents/*.md` frontmatter | `model:` and `effort:` | **Dev repo only.** Tracks the phase's **primary** when that's Claude; when the primary is `codex`, tracks the phase's Claude **`fallback`**/`fallbackEffort` (so `generator` = `implement`'s fallback). |

**Never edit agent frontmatter from a consumer repo.** There it lives in the shared plugin cache
(`~/.claude/plugins/…`), so the edit is outside the project (not revertible with `git`), leaks into
every other repo on the machine, and is wiped by the next `/plugin update`. It doesn't need writing
anyway: the frontmatter is only a **default**, and `/work` resolves `config.models` and pins each
subagent per spawn with the Agent `model:` override — the config wins at runtime. In a consumer repo,
config + settings.json *are* the complete write.

The headless loop reads the same config and dispatches `--model` (only — not `--effort`). What is
**not** enforced by any file, and should be presented as a preference rather than a guarantee: the
`effort` of a codex-primary phase, and `fallbackEffort` on a Claude-primary phase (a usage-cap re-spawn
pins the model, not the depth).

## Verify before you call it done
Run `/harness-doctor` and read **check 10** — it validates value legality, session-is-Claude,
frontmatter agreement, no `codex → codex`, effort agreement, and codex reachability. A clean check 10
is the evidence that the interview actually landed.
