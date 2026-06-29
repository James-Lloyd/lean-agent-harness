---
description: Record a real failure as a new, durable harness rule (the ratchet principle).
argument-hint: "<what went wrong / the failure to prevent>"
allowed-tools: Read, Edit, Write, Glob, Grep
---

# /ratchet — turn a failure into a rule

The failure: $ARGUMENTS

A good harness is shaped by *your* failure history. **Every** rule must trace to a specific thing that
went wrong — never a speculative "best practice." This command is how the harness learns. It is also
how it stays small: you add rules here, and you *delete* ones that no longer earn their attention.

## Decide where the rule belongs (don't default to CLAUDE.md)
A rule should live at the cheapest layer that reliably prevents recurrence:

1. **A deterministic sensor (best).** Can a linter, type, test, or hook catch this automatically? If
   so, prefer that — encode it as a check and put the *repair instruction in the failure message*.
   - Add/extend a gate command in `harness/harness.config.json`, or
   - Add a pattern to `.claude/hooks/block-destructive.*`, or
   - Add a structural/architecture test.
2. **A skill** — if it's a recurring *how-to* (a procedure the agent keeps getting wrong), capture it
   as a skill under `.claude/skills/` so it's loaded only when relevant (progressive disclosure).
3. **`CLAUDE.md` "Project rules"** — only if it's a judgment/constraint that can't be mechanized. Add
   one line: `- [YYYY-MM-DD] <rule> — because <the failure>`. Keep CLAUDE.md ≤ ~100 lines; if adding
   this pushes it over, something older has stopped earning its place — remove that.

## Procedure
1. Restate the failure in one sentence and identify the *class* of mistake (not just this instance).
2. Choose the layer above and implement the rule there.
3. If you added a CLAUDE.md line, double-check it's specific and falsifiable, not vague advice.
4. Note it in `state/PROGRESS.md` so there's a trail of how the harness evolved.

## Output
State exactly what rule you added, where, and why a future agent will now avoid this failure.
