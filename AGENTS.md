<!--
  ROOT CONTEXT MAP — a navigation map, not a manual. Keep it under ~100 lines (shorter is better —
  the shipped map is ~60): every line competes with the task for attention. Point to docs/ and nested
  AGENTS.md files; never inline specs or style guides. Ratchet rules only from real failures (/ratchet)
  — delete rules that stop earning their place. /harness-init fills the {{PLACEHOLDERS}}.
  This file is read natively by Codex, Cursor, Copilot, Gemini CLI and friends; Claude Code reads it
  through the `@AGENTS.md` import in CLAUDE.md. Keep everything vendor-neutral here; anything that only
  Claude Code needs goes in CLAUDE.md's "Claude Code specifics" section.
-->

# {{PROJECT_NAME}}

{{ONE_LINE_DESCRIPTION}}

**Domain:** {{DOMAIN}} · **Type:** {{PROJECT_TYPE}} · **Shape:** {{PROJECT_SHAPE}}

## Components
Each has its own stack and gate, run in its own directory — see `harness/harness.config.json` → `components`.

| Component | Path | Stack | Run | Test |
|-----------|------|-------|-----|------|
| {{COMPONENT_NAME}} | `{{COMPONENT_PATH}}` | {{COMPONENT_STACK}} | `{{COMPONENT_RUN}}` | `{{COMPONENT_TEST}}` |

Cross-cutting e2e: {{ROOT_E2E}}

## The map
- `specs/` — **immutable** requirements; the contract.
- `docs/architecture/` + `docs/design-docs/` — how it fits together, and decisions already made (with the why).
- `docs/principles/workflow.md` — the task lifecycle (plan → execute → validate → review → record)
  that `/work`, `/plan`, `/verify`, `/review`, `/loop` drive.
- `state/` — live work: `fix_plan.md` (priority stack), `tasks.json` (manifest), `PROGRESS.md`,
  `handoff.md`, `evidence/`.
- `AGENT_NOTES.md` — operational gotchas. Append when you learn one.

## How to work
One task per iteration — the top unchecked item in `state/fix_plan.md`. A task is done when the
changed component's full gate **and** the root gate pass (commands in `harness/harness.config.json`)
and end-to-end evidence of the user-visible behavior exists under `state/evidence/` — unit-green
alone is not done. Commit when green (exception: in the headless loop the runner commits —
PROMPT.md wins there); roll back a red tree rather than patching over it. At task boundaries prefer
a written handoff and a fresh context over compaction — state lives in files.
Shell hygiene that keeps permission prompts down: run commands with **absolute paths instead of a
`cd … &&` prefix** (a `cd` inside a compound command defeats the read-only auto-allow and prompts),
and inspect files with the file-read/search tools rather than inline `node`/`python` heredocs (an
interpreter heredoc can never be allowlisted, so each one is a prompt or a classifier round-trip).

## Session isolation — one session = one worktree
Each interactive session runs in its **own git worktree**, so two concurrent sessions on this repo
never share a working tree or git index. Enter a worktree branched from origin's default **before
editing** (Claude Code: see CLAUDE.md; anything else: `git worktree add`). Land work by **PR to
`main`** (state edits included).
- **Task-claim convention.** The shared queue (`state/fix_plan.md`/`tasks.json`) forks per worktree, so
  two sessions branched from `main` see the *same* "next up". Point each session at a **distinct** task,
  and as your first commit stamp the task line with your branch — `- [ ] (wip: <branch>) <task>`. The
  branch stamp makes a double-grab **textually unique**, so the two PRs are guaranteed to conflict at
  merge; a bare identical `[x]` tick would 3-way-merge silently and both could land. Full discipline:
  `docs/principles/workflow.md`.

## Guardrails
- Never weaken or delete a test to go green. Fix the code or escalate.
- Never edit `specs/`. Propose changes to the human (`/plan`, `/onboard`, `/harness-init` may author
  *new* specs with approval).
- Escalate ambiguous product decisions instead of guessing.
- Review in a fresh context (`/review` / the `reviewer` subagent) — the doer is not the judge.
- Destructive commands are hook-blocked; don't route around the hooks.

## Project rules (the ratchet — grows only from real failures)
<!-- Add via /ratchet: "- [YYYY-MM-DD] <rule> — because <the failure it prevents>" -->
- [2026-07-14] A fresh-context judge subagent that dies on its model's usage cap gets re-spawned with
  a `model:` override; `review`/`evaluate` carry a Claude fallback in config for the headless path.
- [2026-07-26 · consolidated 2026-08-11] **A fact you change in one prompt surface exists in others —
  find them before you close.** Grep the whole repo for the literal (path, count, field name, phrase)
  you just edited. Four incidents, one lesson: a stale fact recurred in a sibling surface (07-26); an
  engine edit landed in `loop.ps1` but not the `.sh` twin (07-29); a deleted doc block left inbound
  pointers dangling, so rehome the content or fix the pointer *in the same change* — a pointer into
  deleted content is worse than the verbosity (07-29); and `/harness-migrate` deleted engine files from
  consumers without updating the plugin's own checks against those paths, so harness-doctor checks 1+7
  failed on every correctly-migrated repo (07-30).
- [2026-07-30] A committed config pointer ($schema, profile, path) is repo-relative or plugin-resolved,
  never an absolute local path — it dies on the next device (a consumer repo's $schema pointed at this
  machine's harness checkout).
- [2026-07-30] Compression may not swap a concrete fact for a pointer unless the pointed-at
  file/skill/command is verified to exist — resolve it before closing (a consumer map lost its model
  names to an unverified skill pointer).
- [2026-08-06] A doc that names a plugin-owned file as a WRITE target must say what a *consumer* repo
  writes instead — the installed cache is outside the project, shared machine-wide, and reverted by
  `/plugin update` (the routing skill told migrate to edit agent frontmatter that consumers can't own).
- [2026-08-06] A test pinning a doc table to a config asserts the value in its own COLUMN (split the
  row) and reads config keys via `PSObject.Properties[...]` — a row-wide match false-passes off a
  neighbouring cell, and a bare `$obj.$key` aborts the whole suite under StrictMode instead of failing.
- [2026-08-11] A bare model **alias** (`opus`, `sonnet`, `fable`) floats to the newest model in that tier
  — it is a moving pointer, not a pin. Write the full `claude-*` ID anywhere the *generation* matters and
  the alias only where the *tier* is the point (`haiku` for scouts). Found live: `settings.json` said
  `"model": "opus"` intending Opus 4.8 while the session was actually running Opus 5.
- [2026-08-11] A config key that nothing reads is worse than no key — it advertises a control that does
  not exist. Before adding one, name the code path that consumes it; when deleting the consumer, delete
  the key in the same change (`verification.freshContextReview` sat in the schema and every config for
  months while `/work` ran the review unconditionally — turning it off disabled nothing).
- [2026-08-12] A change to a shipped engine function's signature or behaviour bumps
  `plugin/.claude-plugin/plugin.json` `version` in the SAME diff — an unbumped version leaves a
  consumer's `/plugin update` serving a cached prose/engine pair from different builds (found in review
  of the promotion-decision signature change: the lib changed but the version stayed 0.2.9).
- [2026-08-12] A doc that offers "git will conflict visibly" as a safety backstop must make the competing
  edits TEXTUALLY UNIQUE — a 3-way merge auto-resolves byte-identical changes silently, so two sessions
  ticking the same `fix_plan.md` line `[ ]`→`[x]` both land with no signal. Stamp the claim with the
  branch so a double-grab diverges and actually conflicts (found reviewing the worktree-isolation change).
- [2026-09-04] A `fix_plan.md` line ticked `[x]` names its `state/evidence/<dir>` in the DONE comment, and
  the PROGRESS line cites both twins' gate counts — a tick with no evidence dir is not done. Found live: V1
  of the vendor refit was ticked on unit-green alone and the fresh-context reviewer rejected it.
- [2026-09-04] When a global config key gains a per-phase override, grep the key name in the skill, the
  doctor check AND the schema description before closing — the sentence "X reads the global key" lives in
  all three (V2 left it in the model-routing skill twice, doctor 10(e), and the schema's effort description).
- [2026-09-04] A doc claim that a guard hook allows or denies a payload shape must be backed by a probe
  carrying the DENYLISTED content, not a benign one — a benign probe never reaches the fallback branch.
  Found in review: `block-destructive` scans the whole payload when `tool_input.command` is absent, so
  the generated Codex hooks under matcher `*` would have denied any edit mentioning `rm -rf`.

- [2026-09-05] A generated config, hook, or agent file for a FOREIGN tool is verified by making that tool LOAD it
  and ACT on it (a one-line `codex exec`), never by asserting the emitted text; and a denial contract is verified by
  the destructive command NOT running, never by the hook's exit code. V3 shipped text-green and live-dead on four
  counts (two fatal config keys, project hooks never loaded headless, exit-2 denials ignored) — all found by V5.
  When a live-fire disproves a fact, sweep the generated artifacts' own runtime output and help text too, not
  just the docs — an operator reads the tool's stdout, not the design doc (the generator kept printing the
  disproved claim as its last line; caught in review).
- [2026-09-06] **A guardrail predicate is not verified until it has run over a REAL input at real size.**
  Unit fixtures are small by nature, and a whole class of shell defect only appears past a buffer
  boundary. `/promote`'s money rule — the one rule the design says must never fail open — passed twelve
  green assertions while reporting no money vocabulary whatsoever in a real 167 KiB diff, because
  `printf | grep -q` loses its match to SIGPIPE under `pipefail` above 64 KiB. Two sibling guards
  (`usage_limit_error`, fleet's protected-path check) carried the same shape. Before trusting any
  classifier, sniffer or tamper guard, run it over a real artifact of the size it will really see, and
  leave that oversized case in the suite.

## Nested context
Subsystems carry their own `AGENTS.md` next to their code (in this repo: `plugin/engine/` holds the
engine's PS-5.1/twin-parity rules). When working in a subsystem, its local map applies too.
