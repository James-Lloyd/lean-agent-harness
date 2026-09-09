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
| `session` | (the main window — you) | `claude-fable-5-1` | `medium` | (n/a) | The **orchestrator**. It dispatches, sequences and reports; the deep thinking belongs to the phase agents — but it also judges *when* a phase is done, so it gets the strongest model at a moderate depth. Anthropic's Fable 5.1 guidance: `medium` roughly matches Fable 5 at lower cost, and at `low` it searches less and batches implied tool calls less — so `medium`, not `low`. **Must be Claude** — the main window can't swap vendor mid-session. |
| `plan` | `planner` | `claude-fable-5-1` | `high` | `claude-opus-5` @ `high` | Design is where a bad call is most expensive. Deepest reasoner at `high` — Anthropic's recommended start; go to `xhigh` only on a measured gain. |
| `implement` | `generator` | `claude-opus-5` | `high` | `null` | The builder. Anthropic's own default is to start on Opus 5 and escalate to Fable only when Opus 5 at higher effort fails; it is also a different model from the Fable judge that reviews it, so the writer never clears its own diff. **No fallback on purpose** — this phase is interactive, so a cap is recoverable by hand; a silent second-choice builder is worse than stopping. Worth an A/B on a real task: Fable 5.1 @ `medium` has cache reads at a quarter of Opus 5's price, so on long cache-heavy builds cost per completed task can come out close. |
| `review` | `reviewer` | `claude-fable-5-1` | `high` | `claude-opus-5` @ `medium` | Fresh-context judge — the doer must never be the judge. Judges get the strongest model. Cap-proof fallback because a headless run can't ask a human mid-review. Accepted tradeoff: the fallback equals the builder's model, so a Fable cap costs model diversity — the fresh-context guarantee still holds. |
| `evaluate` | `evaluator` | `claude-fable-5-1` | `high` | `claude-opus-5` @ `medium` | Rubric scorer at the sprint gate. Same reasoning as `review`. Off by default (`verification.evaluator.enabled: false`) — one judge at the end is enough. |
| `explore` | `explorer` | `haiku` | `low` | `null` | Read-only scout for fan-out searches. High volume, shallow judgment — the one place to spend nothing. |
| `docs` | `doc-gardener` | `haiku` | `low` | `null` | Small, safe documentation edits. |

**Pin full IDs, not aliases, wherever the generation matters.** The bare aliases `opus` and `fable` float
to whatever the current model of that tier is (today: Opus 5 and Fable 5.1), so a phase written as
`fable` silently changes model the moment a new Fable ships — and effort levels do not mean the same
depth across generations, so a floated model also floats its cost. Aliases are fine for `haiku`, where
only the tier matters.

Values may be a **Claude alias** (`opus`/`sonnet`/`haiku`/`fable`), a full `claude-*` ID, or the literal
**`codex`** (supported by the engine, but not routed in the recommended defaults —
see "Cross-vendor" below). Effort is `minimal|low|medium|high|xhigh|max`; absent = the model's own
default. `minimal` is a codex-only level (the Claude CLI rejects it, so the dispatcher omits the flag);
`max` is Claude-only. `fallback: null` = no fallback (the phase just fails when its primary does); a
whole phase set to `null`, or an absent `models` block, = inherit the ambient session model.

**Not every phase can actually run Codex.** `"codex"` is legal syntax everywhere, but only some phases
have code that dispatches it — and a value nothing reads advertises a control that does not exist:

| phase | headless (`loop.*`/`fleet.*`) | interactive (`/work`, `/review`) |
|---|---|---|
| `implement`, `review`, `review.second`, `evaluate` | ✅ | ✅ |
| `plan` | ✗ **silently ignored headlessly** | ✅ `/work` PLAN |
| `explore`, `docs` | ✗ | ✗ — nothing dispatches either |
| `session` | must be Claude (the window cannot swap vendor mid-session) | |

`explore: "codex"` and `docs: "codex"` are read by nothing at all — `/gc` has no routing block, and
although `work.md` lists `explorer`→`explore` in its phase mapping, no `/work` step dispatches an
explore phase and no subagent ever wraps codex. `plan` is the trap instead: it works under `/work` and
is ignored by an overnight loop, so the same config behaves differently on the two paths.
`/harness-doctor` 10(i) grades all of this. **Careful:** only the phase's `model` is dead there — a
`codex{}` block on `explore`/`docs` is still read by `codex-setup.*` to write that agent's
`.codex/agents/<name>.toml`, so do not delete one while `.codex/` exists.

**Per-phase Codex settings.** A phase whose `model` or `fallback` is `codex` — or, on `review`, whose
`second.model` is `codex`, since the second judge runs on the review phase's own codex settings — may add
`"codex": { "model": "gpt-5.6-sol", "reasoningEffort": "high" }`; each key set there wins over the
global `models.codex` block for that phase (keys left null inherit it). `auth` and `timeoutSeconds`
stay global. Don't add the block to a phase that never routes to codex — the engine won't read it and
`/harness-doctor` 10(g) will say so. **Pin or float is a real tradeoff, and both sides have bitten.** Floating (`model: null`) never rots, but it MOVES: measured 2026-09-09, 21 transcripts from one working day split cleanly at ~17:00 UTC - every run before reported `gpt-5.6-sol`, every run after `gpt-6-astra`, same box, same account, same flags (`state/evidence/2026-09-09-v6.3-command-skill-bridge/`; the effort flag was ruled out as the cause). An unpinned judge can change model between one morning and one afternoon, which makes cross-run comparison meaningless. Pinning costs you the opposite: every `*-codex` ID was retired in 2026-07/08, so a pinned ID eventually breaks - loudly, which is the point. **Pin the phases whose output you compare across runs (the judges); float the ones you only ever read once.** Whichever you choose, read the effective model back from the exec transcript header rather than trusting the config: a pin to a non-default model was verified to BIND (`-m` is honoured), but that is a measurement, not an assumption. Once any
phase routes to codex, run `harness/codex-setup.*` to generate Codex's own copies of the guard hooks,
the phase agents, and the harness commands as skills under `<project>/.agents/skills/` - that directory,
not the `[[skills.config]]` stanza in `config.toml`, is what `codex exec` actually reads (measured
2026-09-09; the stanza is inert for exec). See `docs/codex-setup.md`; doctor check 12 keeps them fresh.

**Second reviewer (the recommended first use of Codex).** `review.second: { model, effort }` adds a
second, read-only judge that reviews the SAME batch after the primary SHIPs; SHIP requires both, and both
verdicts land in the ledger. Independent benchmarks (design-doc 002) show Claude Code's and Codex's
reviewers catch mostly *different* bugs, and that a cross-vendor reviewer helps only when it is
comment-only — so the second reviewer is read-only by construction and has **no fallback**: the point is
model diversity, and a substitute is not the configured second opinion (an unreachable second reviewer
fails closed; doctor 10(h) warns). Recommended pair: primary `claude-fable-5-1` @ `high`, second
`codex` @ `high`. The harness repo pins its own Codex side to a single ID (see the pin-or-float note above) precisely because the second reviewer is a phase whose verdicts you compare across runs; read the effective model back from the exec transcript header either way. Off by default; turn it on
in shadow mode first (slice V5) and compare the two judges' findings before letting it gate. The harness
repo itself runs this pair as of 2026-09-09 (`state/evidence/2026-09-09-v6-second-reviewer-routing/`).

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
3. **Don't offer codex unprompted.** The recommended defaults are single-vendor; only route a phase to
   `codex` if the human asks for cross-vendor. If they do, probe first — `codex --version`, then
   its auth the way the engine does (`lib/invoke-codex.*`): `auth: chatgpt` → `codex login status` exits
   0; `auth: api-key` → `CODEX_API_KEY` is set. Don't report an api-key user as "not signed in" for
   failing the chatgpt probe. `codex login status` also false-negatives against Azure/custom providers
   (`AGENT_NOTES.md`) — if the human says codex works, believe them over the probe. If it genuinely
   isn't there, say so and keep the Claude-only default (`implement` = `claude-opus-5` @ `high`) instead
   of writing a route that silently falls back forever.

### Constraints to enforce as you collect
- `session.model` **must be Claude** — `codex` there is invalid, not a preference.
- A `fallback` must not equal a `codex` primary (no `codex → codex`; there's one hop of escape, not two).
- Steer `session.effort` to `low|medium|high|xhigh` — `minimal` and `max` have no `effortLevel`
  equivalent, so neither can be written to settings.json. This is interview guidance, not a validation
  rule: doctor 10(e)(i) reports either there as ⚠️, so don't "fix" the doctor to hard-fail it.
- A phase whose primary is `codex` takes its **depth** from its own `codex.reasoningEffort`, else the
  global `models.codex.reasoningEffort`, and its
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
| `harness/harness.config.json` → `models` | `{model, fallback, effort, fallbackEffort}` per phase, plus an optional per-phase `codex: {model, reasoningEffort}` on codex-routed phases | **Both.** The declared table, and the one that actually routes at runtime. Also the global `models.codex` (`model`, `reasoningEffort`, `auth`, `timeoutSeconds`) if any phase routes to codex. |
| `.claude/settings.json` | `model` = `session.model`, `effortLevel` = `session.effort` | **Both.** `CLAUDE_CODE_EFFORT_LEVEL` and `claude --effort` override `effortLevel` at launch. |
| the plugin's `agents/*.md` frontmatter | `model:` and `effort:` | **Dev repo only.** Tracks the phase's **primary** when that's Claude; when the primary is `codex`, tracks the phase's Claude **`fallback`**/`fallbackEffort` (under the single-vendor defaults every agent tracks its phase's primary — e.g. `generator` = `claude-opus-5`). |

**Never edit agent frontmatter from a consumer repo.** There it lives in the shared plugin cache
(`~/.claude/plugins/…`), so the edit is outside the project (not revertible with `git`), leaks into
every other repo on the machine, and is wiped by the next `/plugin update`. It doesn't need writing
anyway: the frontmatter is only a **default**, and `/work` resolves `config.models` and pins each
subagent per spawn with the Agent `model:` override — the config wins at runtime. In a consumer repo,
config + settings.json *are* the complete write.

The headless loop and fleet read the same config and dispatch `--model` **and** `--effort` on the
Claude arm (since 2026-09-04): the primary runs at the phase's `effort`, a fallback at its
`fallbackEffort` (else the primary's `effort`). What is still **not** enforced by any file, and should
be presented as a preference rather than a guarantee: the `effort` of a codex-primary phase (codex
reads the phase's `codex.reasoningEffort`, else `models.codex.reasoningEffort`), and `fallbackEffort` on
an **interactive** `/work` re-spawn (a
usage-cap re-spawn pins the model, not the depth).

## Verify before you call it done
Run `/harness-doctor` and read **check 10** — it validates value legality, session-is-Claude,
frontmatter agreement, no `codex → codex`, effort agreement, and codex reachability. A clean check 10
is the evidence that the interview actually landed.
