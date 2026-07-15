# Roadmap

This harness is **v0.1** and honest about it. An adversarial four-lens review (functional, best-in-class,
coherence, safety) shaped this list. The items below are deliberately **not yet built** — they're the
gap between "strong" and "best-in-class." Each says what's true today so nothing here reads as a claim
the code doesn't back. (Ratchet them in as real use demands.)

## Inferential safeguards in the *auto* loop
- **Now wired (opt-in):** `verification.reviewEveryNIterations` (default 0 = off). When > 0, the loop
  spawns a fresh-context **reviewer** headless over the last N commits every N green iterations; a
  *REJECT* verdict records the finding to `state/handoff.md` and stops the loop for a human. This puts
  "doer ≠ judge" into the unattended path, not just supervised `/work`·`/review`.
- **Still deterministic-by-default:** with `reviewEveryNIterations = 0` the loop runs only the gate then
  commits (as before). The loop still can't *manufacture* judgment between review points.
- **The periodic reviewer is read-only and DIFF-ONLY.** It runs with `--disallowedTools` (and the loop
  hard-resets the tree afterward) so a judge can't mutate what it judges, and it **fails closed** (only
  an explicit `VERDICT: SHIP` continues; reject/truncation/crash stop for a human). But it is not granted
  the tools to run the app, so it reviews the diff + specs, not fresh e2e evidence — pair it with a real
  `e2e` gate step. Granting it a sandboxed run-the-app capability is future work.
- **Now wired (2026-07-13):** the periodic judge routes per `models.review` — `"codex"` runs it
  cross-vendor through the OpenAI Codex CLI (read-only sandbox + watchdog, automatic fallback to
  `models.reviewFallback` when codex is missing/unauthenticated); any claude alias pins the internal
  reviewer's model.
- **Planned next:** also run the skeptical **evaluator** (rubric thresholds) at the review point, and
  auto-revert the rejected batch rather than only stopping. For now a *reject* halts for human triage.
- **Planned:** runner-side advancement of `state/tasks.json` after a periodic-review *SHIP* — today only
  an interactive `/review` advances statuses past `validated`, so tasks shipped by the unattended loop
  sit at `validated` until a human-session review picks them up.

## Real token metering
- **Now wired (opt-in):** `autonomy.meterTokens` (default false). When true the loop invokes the model
  with `--output-format json` and the budget parser reads real `usage` (input+output tokens), making
  `tokenBudget` an **exact** cap. Trade-off: the per-iteration log is JSON, not streamed text.
- **Default (meterTokens=false):** `tokenBudget` is a per-run **estimate** (~15k/iteration fallback);
  the hard runaway bounds remain `maxIterations` + `maxTurnsPerIteration`.
- **Planned:** roll cost (`total_cost_usd`) into the ledger and a per-run summary.

## LSP / diagnostics as a live sensor
- **Today:** profiles record `lsp.servers` as *informational*; the real mechanism is the `typecheck`
  gate step. "Prefer LSP over guessing" has no wiring.
- **Planned:** surface IDE/LSP diagnostics (e.g. `mcp__ide__getDiagnostics`) into `/verify` and the
  PostToolUse hook; ship a `.mcp.json` template.

## Parallel task execution across worktrees
- **Now wired (2026-07-13):** both planned steps shipped — see
  `docs/execution-plans/2026-07-13-model-routing-parallelism-context.md`.
  - The **generator** subagent runs with `isolation: worktree`; `/work` Phase 2 squash-merges the
    result back before VALIDATE (a bad build can't dirty the main tree).
  - The **fleet runner** (`harness/fleet.ps1` | `fleet.sh`) executes up to `parallel.maxWorkers`
    (default 3) file-ownership-partitioned tasks in parallel worktrees, then integrates through a
    serialized merge queue: squash-merge → full gate on the combined state → commit; conflict/red/
    policy-tamper parks the branch for a human. Eligibility is declared via each task's `files`
    ownership list in `state/tasks.json` (the planner fills it); overlapping tasks never share a batch.
- **Planned next:** per-worktree dependency install + a `.worktreeinclude`-style env-file copy so
  workers can run heavier gates; re-invoking the authoring worker to resolve its own rebase conflicts
  (today a conflict parks the branch instead).

## Observability beyond the run ledger
- **Today:** each run writes per-iteration `iter-N.log` + a JSONL `ledger.jsonl` (task result, failed
  step). No cost/latency rollup, no cross-run history.
- **Planned:** a run summary (durations, pass-rate, gate-step failure histogram) to debug and score long
  runs, and to feed an eval history.

## Sandboxing for unattended runs
- **Today:** the destructive-command hook is defense-in-depth — it matches **both** shell tools
  (`Bash|PowerShell`), covers PowerShell destructive forms, and fails closed on a denylist hit — but it
  is a denylist, not a sandbox; `--dangerously-skip-permissions` voids the permission deny-list entirely.
- **Planned:** headless hardening — prefer `--permission-mode dontAsk` plus explicit permission `allow`
  rules over `--dangerously-skip-permissions` (deny/ask rules keep their teeth); adopt
  `sandbox.credentials` for secrets; and a documented container/VM profile (no host FS, no outbound
  network, ephemeral, secrets via env) as the supported way to run `auto` unattended. On Windows there is
  **no native sandbox** — document a WSL2/devcontainer path for unattended runs there.

## Distribution as a Claude Code plugin
- **Now wired (2026-07-14):** the reusable engine ships as the `lean-agent-harness` **plugin** served
  from the in-repo marketplace (`.claude-plugin/marketplace.json`), with the per-repo scaffold
  (`CLAUDE.md`, `specs/`, `state/`, `harness/harness.config.json`, `/harness-init`) staying the template
  half. Engine fixes (skills, agents, hooks, doctor, loop/fleet) now arrive via `/plugin update` instead
  of hand re-templating. `plugin/` holds the payload (agents, commands, skills), `plugin/hooks/` the
  guardrails behind a **node dispatcher** (one static `hooks.json` that picks powershell/bash by OS —
  Node is always present), and `plugin/engine/` the loop/fleet runners + thin `wrappers/` that a project
  drops into `harness/` to keep `harness/loop.ps1` working from a bare terminal/cron. Runner scripts were
  refactored to split engine-path from a discovered `--project-root`. Agent frontmatter was audited
  first: none use the `hooks`/`mcpServers`/`permissionMode` fields plugins ignore. Verified end to end by
  a real install (evidence: `state/evidence/2026-07-14-plugin-packaging/`). Upgrade path for deployed
  copies: `docs/plugin-migration.md`.
- **Still E1 (staged):** the dev repo still carries its own `.claude/` + `harness/` engine copies for
  dogfooding; a follow-up flips it to consume its own plugin and deletes the in-repo duplicates.
- **Planned:** migrate `.claude/commands/*.md` into `.claude/skills/*/SKILL.md` directories — commands
  and skills are merged in Claude Code, and skills additionally support bundled supporting files.

## Tracking the Claude Code platform (bets that can expire under us)
- **`--bare` watch:** the docs say `--bare` (skips hooks/skills/`CLAUDE.md` discovery) "will become the
  default for `-p` in a future release." The unattended loop **depends** on that discovery (hooks are
  the guardrails; `CLAUDE.md` is the map). Add a regression check to the self-tests before that flips.
- **Native `/goal` loop:** offer the built-in `/goal <gate condition>` Stop-hook loop as an alternative
  inner loop — `claude -p "/goal …"` runs to completion in one invocation. Keep `loop.ps1`/`loop.sh` for
  what `/goal` doesn't do: budgets, checkpoints, rollback, and git orchestration.
- **`.claude/rules/`:** adopt path-scoped rule files with `paths:` frontmatter (e.g. brownfield rules
  scoped to component dirs) so guidance loads only where it applies and `CLAUDE.md` stays under the
  ~200-line guidance.

## "Re-examine the harness on every new model"
- **Today:** stated as a principle, no artifact.
- **Planned:** a short `docs/principles/model-upgrade-checklist.md` — what to strip/re-test when a new
  model lands (the harness is a set of bets about model weaknesses; some expire).
