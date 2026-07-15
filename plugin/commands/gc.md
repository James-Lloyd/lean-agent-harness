---
description: Continuous drift control — scan for rot (dead code, stale docs, dup helpers) and fix in small PRs.
argument-hint: (optional) "<area to focus, e.g. docs | deps | dead-code>"
allowed-tools: Read, Edit, Write, Bash, Glob, Grep, Agent, Skill
---

# /gc — garbage collection (pay debt in small installments)

Focus: $ARGUMENTS (default: a broad sweep)

Entropy accrues as agents work fast. Rather than periodic big cleanups, pay it down continuously in
small, safe increments. Spawn the **`doc-gardener`** subagent and/or read-only scanners to find drift,
then make minimal fixes — each independently verifiable through the gate.

## Scan for (pick what's relevant to the focus)
- **Stale docs** — `CLAUDE.md` over ~100 lines, `docs/` entries contradicting the code, broken
  cross-links, rules in CLAUDE.md no longer earning their place (delete them — the ratchet cuts both ways).
- **`AGENT_NOTES.md` bloat** — append-only and always-loaded; compact it (dedupe learnings, drop notes
  about code/commands that no longer exist) so it doesn't silently grow the per-session context.
- **Stale evidence** — `state/evidence/<task-id>/` dirs for tasks that are done **and merged**; propose
  deleting them (per `state/evidence/README.md`, `/gc` is where shipped work's evidence gets pruned).
- **Dead code** — unreferenced files/exports/functions.
- **Duplication** — hand-written helpers that duplicate an existing shared utility (a golden-principle
  violation — prefer the shared one).
- **Dependency hygiene** — unused deps, known-vulnerable versions.
- **Test quality** — assertions that can't fail, skipped tests, units green while behavior is broken.
- **Architecture drift** — layering violations vs. `docs/architecture/`.

## Rules
- **Small and safe.** One concern per change; run the gate after each; never bundle a risky refactor
  with cleanup. Roll back anything that reddens the gate.
- **Don't invent work.** Only fix real drift you can point at. Log what you found but didn't fix to
  `docs/technical-debt/` so it's tracked, not lost.

## Output
A short report: what drift was found, what you fixed (with evidence the gate stayed green), and what
you logged to `docs/technical-debt/` for later. Suggest `/ratchet` rules for any drift that a sensor
could prevent from recurring.
