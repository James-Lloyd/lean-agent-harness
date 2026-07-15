# Execution plan: cross-vendor per-phase model routing + automatic fallback

**Status: APPROVED 2026-07-14.** Decisions locked (§8): (1) Option A — the orchestrator dispatches to
the codex lib instead of spawning the Claude subagent when a phase routes to codex; (2) tolerant reader
— accept both the legacy flat string and the new `{model,fallback}` so deployed configs keep working;
(3) retry once on the fallback within the same iteration on a usage/limit error (reset a write tree to
base first). Supersedes the model-routing slice of the
[2026-07-13 plan](2026-07-13-model-routing-parallelism-context.md), which shipped per-phase *Claude*
routing plus a **review-only** cross-vendor path. This plan generalizes cross-vendor + fallback to
**every** phase.

Parent fix_plan item: _"Per-phase model selection + CROSS-VENDOR fallback for ALL phases (GPT via
`codex login`)"_. The handoff flagged it large and required it to open with its own decomposition — this
is that decomposition. It replaces the single item with the slices in §7.

---

## 1. Goal (James's clarification, 2026-07-14)
Be able to **run OR fall back to GPT (codex) for any phase** — explore, plan, implement, review,
evaluate, docs — not just review. Fallback fires when the **primary is unavailable or hits a
usage/limit error**. Cost/quality are reasons to *select* a model per phase, **not** auto-fallback
triggers. Interactive per-phase pick (with recommendations) belongs in `/harness-init`;
`/harness-doctor` must validate the new schema; tests must cover the **fallback trigger**.

## 2. What exists today (verified inventory, 2026-07-14)
- **One declared table** `config.models` → three enforcement surfaces: `.claude/settings.json` `model`
  (session), `model:` agent frontmatter (subagents), `--model` flags in loop/fleet (headless).
- **Single runtime chokepoint** `Resolve-PhaseModel` / `phase_model` (`lib/gate.ps1` L42-46 / `gate.sh`
  L23-25) reads `config.models.<phase>` and returns a string. Only **three phases reach a real
  invocation**: `implement` (loop `L303` / fleet `L153`, `.sh` twins), `review` (loop periodic reviewer
  `L139-157`), and `reviewFallback` (the claude arm of the review path). `session/explore/plan/evaluate/
  docs` have **no headless call site** — they are wired only through settings.json + frontmatter.
- **Cross-vendor lives only in review** (`lib/review-codex.*`): read-only sandbox
  (`--sandbox read-only --ask-for-approval never`), external watchdog, `--output-last-message` verdict
  parse, and a **pre-invocation** fallback (codex-unavailable → claude reviewer on `reviewFallback`).
  There is **no** runtime usage/limit fallback, and **no** codex path for any other phase.
- **E1 duplication is still in place:** every engine file exists twice — `harness/` ↔ `plugin/engine/`,
  `.claude/agents` ↔ `plugin/agents`, `.claude/commands` ↔ `plugin/commands`. Until the E2 flip (a
  separate queued task), **every change here lands in both copies.** Line numbers are identical.

## 3. The three hard problems (why this is large)

### 3a. Subagent frontmatter is static — it can't express "codex, or fall back to Claude"
`session/explore/plan/evaluate/docs` run as Claude subagents (or the main window), configured by
**static** `model:` frontmatter. Frontmatter can name a Claude model; it cannot say "run this phase on
codex" nor "fall back on a usage-limit." A Claude subagent also can't *become* codex mid-run. So routing
a non-headless phase cross-vendor **cannot** live in frontmatter — the caller must dispatch to a codex
path *instead of* spawning the subagent. This splits the mechanism in two:
- **Headless (loop + fleet):** already shell out to `claude -p --model`. Generalizing is concrete and
  testable here — a resolver + a dispatcher that runs claude *or* codex with fallback.
- **Interactive (`/work` + subagents):** the **orchestrator** must resolve the phase's model and, when
  it is codex, invoke the codex lib via Bash rather than spawning the Claude subagent. This is a
  documented orchestrator protocol, not a config mechanism. (See Decision 1.)

### 3b. Codex must WRITE for implement/plan/docs — today's codex path is deliberately read-only
The review path hard-codes `--sandbox read-only` because a judge must never mutate what it judges. But
`implement` (and `plan`/`docs` when routed to codex) must be able to edit the tree. That is a **second
codex invocation mode** (`--sandbox workspace-write --ask-for-approval never`). Its output is not a
verdict but a **mutated tree**, which then flows through the existing gate + auto-rollback exactly like a
Claude implement iteration. Safety model is unchanged: a bad codex build goes red → the loop rolls back;
belt-and-braces reset is *not* applied to a write phase (that would discard the intended change) — only
to read-only judge phases.

### 3c. Fallback on a usage/limit error is new for the *Claude* side
Today the only fallback is codex-unavailable → claude, decided **before** invocation. "Fall back on a
usage/limit error" requires **post-invocation** detection on both vendors: parse the CLI output/exit for
rate-limit / quota / overloaded markers. This is a new, unit-testable predicate driving the dispatcher.
For a **write** phase, a mid-run usage-limit can leave a partial tree → the dispatcher resets to the
iteration base before retrying on the fallback (see Decision 3).

## 4. Design

### 4a. Config schema — `{model, fallback}` per phase
```jsonc
"models": {
  "session":   { "model": "opus",  "fallback": null    },  // session must be a Claude model (the main window is Claude)
  "explore":   { "model": "haiku", "fallback": null    },
  "plan":      { "model": "fable", "fallback": null    },
  "implement": { "model": "opus",  "fallback": "codex" },  // Claude primary, GPT fallback
  "review":    { "model": "codex", "fallback": "fable" },  // was models.review + models.reviewFallback
  "evaluate":  { "model": "fable", "fallback": null    },
  "docs":      { "model": "haiku", "fallback": null    },
  "codex":     { "model": null, "reasoningEffort": "high", "auth": "chatgpt", "timeoutSeconds": 900 }
}
```
- `model` and `fallback` are each a **Claude alias/ID** *or* the literal `"codex"`. `null` fallback = no
  fallback (behaves like today for phases that don't set one). `codex{}` stays — it configures *how*
  codex runs whenever **any** phase routes to it (no longer review-specific; the schema description
  changes accordingly).
- `review.fallback` replaces the old top-level `reviewFallback`. `session.fallback` is ignored (the main
  window can't be swapped mid-session); doctor flags `session.model == "codex"` as an error.
- **Tolerant reader (Decision 2):** the resolver normalizes a legacy flat value — `"implement": "opus"`
  → `{model:"opus", fallback:null}`, and legacy top-level `reviewFallback` → `review.fallback` — so the
  deployed copies (already-configured projects) keep working without an immediate config rewrite.

### 4b. Resolver returns `{model, fallback}`
`Resolve-PhaseModel` / `phase_model` grow to return both fields (normalized, tolerant of the legacy flat
shape). A thin `Get-PhaseModel`/`phase_model` (primary-only) stays for the settings/frontmatter drift
checks that only care about the primary.

### 4c. Generalized codex lib + a vendor-neutral dispatcher
Extend `lib/review-codex.*` (rename to `lib/invoke-codex.*`; keep a shim so nothing breaks mid-migration)
so `Invoke-Codex` takes a **`-Mode read-only|workspace-write`** parameter that selects the sandbox flag;
everything else (temp-file prompt, flags-before-`exec`, watchdog, `--output-last-message`) is reused. A
new **`Test-UsageLimitError($output,$exitCode)`** predicate (in `lib/gate.*`, vendor-neutral pattern set:
`usage limit`, `rate limit`, `quota`, `overloaded`, HTTP `429`) drives fallback.

A new dispatcher `Invoke-Phase` centralizes the routing:
```
Invoke-Phase(phase, prompt, mode, primary, fallback, repoRoot):
  for candidate in [primary, fallback (if set)]:
    if candidate == 'codex':
        if not Test-CodexAvailable: continue      # pre-invocation unavailability -> next candidate
        out, ok = Invoke-Codex(mode, ...)
    else:
        out, ok = Invoke-Claude(--model candidate, ...)   # claude arm
    if ok and not Test-UsageLimitError(out): return {out, path: candidate, usedFallback: candidate!=primary}
    # unavailable OR usage-limit -> try next candidate (reset a write tree to base first)
  return fail-closed   # both exhausted -> stop for a human (loop records + halts)
```
The loop's periodic reviewer and main implement call, and the fleet worker, all route through
`Invoke-Phase` (review = read-only; implement = workspace-write).

### 4d. Interactive `/work` orchestrator protocol (Decision 1 = Option A)
For a phase whose resolved primary is `codex` (or whose fallback becomes active), the `/work`
orchestrator invokes the codex lib via Bash **instead of** spawning the Claude subagent; when the primary
is a Claude model, it spawns the subagent as today. Subagent frontmatter stays pinned to the phase's
**Claude** model (used when the phase is Claude, and as the model doctor validates). Encoded in the
`/work` command + `planner`/`generator`/`reviewer` agent docs. No subagent ever wraps codex itself.

### 4e. `/harness-doctor` check 10, rewritten
- Every `model`/`fallback` value is a known Claude alias/ID **or** `"codex"`; else ❌.
- `settings.json` `model` == `session.model`; `session.model` must be Claude (❌ if `codex`).
- Each agent frontmatter `model:` == its phase's **primary** if that's Claude; if the phase's primary is
  `codex`, frontmatter must equal the phase's **Claude fallback** (so a spawned subagent still lands on
  the right model) and doctor notes "phase is codex-routed."
- A `fallback` equal to a `codex` primary (codex→codex) is ❌ (no escape hatch). Codex reachability probe
  stays ⚠️ not ❌, and now reports for **every** codex-routed phase, not just review.

### 4f. `/harness-init` interactive per-phase pick
Walk each phase: choose `model` + `fallback` with recommended defaults (the §4a table), then write
`config.models` + the three mechanisms together. Prose interview (as today), no scripted writer.

## 5. Surfaces to touch (each in BOTH copies until E2)
Schema (`harness.schema.json`) · dogfood config (`harness/harness.config.json`) · resolver (`lib/gate.*`)
· codex lib (`lib/invoke-codex.*`) · loop (`loop.ps1/.sh` implement + periodic review) · fleet
(`fleet.ps1/.sh` worker) · 6 agent frontmatters (values unchanged; doctor semantics change) ·
`settings.json` (unchanged) · `/work` + planner/generator/reviewer docs · `harness-doctor.md` (check 10)
· `harness-init.md` (model section) · tests (`run-tests.ps1/.sh`, maybe `fleet-queue-test.*`) ·
AGENT_NOTES + PROGRESS + evidence.

## 6. Safety / risk notes
- **Codex write mode is live-fire-untested** (same caveat as the existing "live-fire the codex invoke
  path" fix_plan item). Ship the arg assembly behind unit tests (injectable `CodexCommand`), gate the
  real write path behind the loop's rollback, and mark it for a supervised first run.
- **No infinite fallback:** a single primary→fallback hop, fallback never `codex→codex`; both exhausted =
  fail-closed stop.
- **Write-phase reset discipline:** read-only judge phases keep the belt-and-braces hard reset; write
  phases must NOT (it would discard the build) — the gate + `autoRollbackOnRed` are their safety net.
- **bash 3.2** (macOS) for all `.sh`; new `.ps1` files carry a UTF-8 BOM (PS 5.1); guardrail hook blocks
  literal `rm -rf`/`git reset --hard` in our own commands — assemble from parts / `git commit -F`.

## 7. Slices (replace the single fix_plan item; one task per iteration)
1. **Schema + config + tolerant resolver** — `{model,fallback}` in both schema files, nested default
   config, `Resolve-PhaseModel`/`phase_model` return both fields and normalize the legacy flat shape +
   `reviewFallback`; unit tests for nested, flat-legacy, and null. *No behavior change yet.*
2. **Usage-limit predicate + generalized codex lib** — `Test-UsageLimitError` (+ tests);
   `lib/invoke-codex.*` with a `-Mode read-only|workspace-write` arg; unit tests assert arg assembly for
   both modes via injectable command; keep a `review-codex` shim.
3. **Headless dispatcher: loop implement + periodic review** — `Invoke-Phase` wired into the main
   implement call and the periodic reviewer under the new schema; claude→codex and usage-limit fallback
   both fire; write-phase reset discipline; tests assert the **fallback trigger** with a stub.
4. **Fleet worker cross-vendor + fallback** — the same dispatcher in `fleet.ps1/.sh` workers; dry-run +
   stub-fallback tests.
5. **Interactive `/work` orchestrator protocol** — encode Option A in the `/work` command + planner/
   generator/reviewer docs; frontmatter semantics documented; doctor already covers the rest.
6. **`/harness-doctor` check 10 + `/harness-init` interview** — rewrite check 10 for the new schema
   across surfaces; add the per-phase init pick with recommended defaults.
7. **Docs + prune** — AGENT_NOTES learnings, this plan → APPROVED, PROGRESS lines, evidence; retire the
   `review-codex` shim once nothing references it.

## 8. Decisions (LOCKED 2026-07-14)
1. **Interactive cross-vendor mechanism → Option A.** The `/work` orchestrator dispatches to the codex
   lib via Bash instead of spawning the Claude subagent when a phase routes to codex; frontmatter stays
   the Claude model. (Rejected: B — subagent internally shells to codex, indirection; C — interactive
   stays Claude-only.)
2. **Schema migration → tolerant reader.** Accept both the legacy flat string and the new
   `{model,fallback}`; normalize flat→nested and `reviewFallback`→`review.fallback` in the resolver, so
   deployed project configs keep working without an immediate rewrite. (the maintainer deferred to
   the recommendation.)
3. **Usage-limit fallback → retry once on the fallback** within the same iteration; reset a write-phase
   tree to the iteration base before the retry; both candidates exhausted = fail-closed stop.

---

## 9. As-built (2026-07-15 — all 7 slices shipped)
The tranche shipped as designed; deltas worth recording against §4/§7:

- **§4b resolver — shipped as two accessors, not one.** `Resolve-PhaseModel`/`phase_model` stayed
  **primary-returning** (tolerant of nested `{model,fallback}` + the legacy flat string) and a **new**
  `Resolve-PhaseFallback`/`phase_fallback` returns the fallback (falling through `review.fallback` →
  legacy top-level `reviewFallback` → `''`). Capability-equivalent to the planned "return both fields";
  the split kept every existing primary-only caller (settings/frontmatter drift checks) untouched. The
  **bash** resolvers take a config **FILE PATH** (jq opens it); the **PS** resolvers take a **parsed
  object**.
- **§4c codex lib — generalized in S2, shim now retired (S7).** `lib/review-codex.*` → `lib/invoke-codex.*`
  with `Invoke-Codex -Mode read-only|workspace-write` + a pure arg-builder (`Get-CodexArgs`/`codex_args`)
  and `Test-UsageLimitError`/`usage_limit_error` in `lib/gate.*`. The read-only back-compat wrappers
  (`codex_review`/`Invoke-CodexReview`) + the `review-codex.*` re-export shims existed only to bridge
  S2→S6; **S7 deleted them** once the live path (loop/fleet → `lib/dispatch.*` → `invoke_codex`) no
  longer referenced them. loop/fleet now `source lib/invoke-codex.*` directly.
- **§4c dispatcher — shipped as `lib/dispatch.*`** (`Invoke-Phase`/`invoke_phase`), wired into loop
  implement (workspace-write) + periodic review (read-only) in **S3** and fleet workers (workspace-write)
  in **S4**. Discipline realized exactly as planned: advance to the fallback **only** on
  codex-unavailable OR a usage-limit **failure** (a generic failure does not switch vendors; a SUCCESS is
  never re-examined for usage markers — CLAUDE.md ratchet); write-phase reset-to-base only before a
  fallback; fail-closed on exhaustion. Bash callers must invoke `invoke_phase` **directly, not in
  `$(...)`** (a subshell drops the `INVOKE_PHASE_*` return globals); PS `Start-Job` fleet workers pass
  `-Quiet` (Out-Host→Out-Null) and re-source the libs inside the job runspace.
- **§4d `/work` protocol (S5)** and **§4e/§4f doctor check 10 + init (S6)** shipped as documented, with
  one clarification baked into the prose: **`/harness-doctor` check 10 is agent-executed PROSE**, not an
  automated self-test — the resolver functions have unit tests, check 10 itself does not. Check 10 maps
  each agent's frontmatter to its phase's **Claude landing model** (the primary when Claude, else the
  phase's Claude *fallback* — the `reviewer`→`fable` branch under `review={codex,fable}`).
- **Codex reality:** codex-cli **0.144.3** is installed + ChatGPT-logged-in; the **read-only** path is
  live-fire-proven repeatedly (incl. every S3/S6/S7 review, run cross-vendor through `Invoke-Phase`). The
  **workspace-write** codex path remains live-fire-**untested** — supervise its first real run.
- **E1 duplication is still live** (every engine change lands in both `harness/` + `plugin/engine/`,
  verified via git blob hash). The **E2 flip** (dev repo consumes its own plugin, delete the in-repo
  engine copies) is the next queued fix_plan item, separate from this tranche.
- **Fallback asymmetry (S6 review):** a **codex-PRIMARY** phase (`review={codex,fable}`) unavailable →
  runs its Claude *fallback*; a **Claude-primary + codex-fallback** phase (`implement={opus,codex}`)
  unavailable → the primary still runs the happy path but loses its safety net, so a primary usage cap
  then **fails closed**. Don't state "any codex-routed phase runs on its Claude arm."
