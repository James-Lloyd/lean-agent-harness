---
description: Write a compact, structured handoff so a fresh context window can resume with zero loss.
argument-hint: (no args)
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
---

# /handoff — structured context reset

Use this before a context reset, before stepping away mid-task, or when the window is filling and you
want a clean restart. Compaction summarizes in place; a **handoff** lets you clear the window entirely
and rebuild from a small, high-signal file. State is file-based, so the next agent loses nothing.

Write `state/handoff.md`, overwriting the previous one, with exactly these sections (keep it tight —
this is a briefing, not a transcript). **Before overwriting, read the existing file:** the loop and the
`generator` append escalations under "Needs human decision" when they hit an ambiguous call — fold any
such open items into your new file's "Needs human decision" section; never silently drop them.

```markdown
# Handoff — <short title>

## Goal
<the outcome currently being pursued, and the why>

## Done so far
- <fact, with the commit/file that proves it>

## In progress (the ONE current task)
<the single item being worked, where it stands, the next concrete step>

## How to verify
<exact commands + what "working" looks like; link the e2e evidence approach>

## Landmines / learnings
<gotchas the next agent must know — pull the freshest from AGENT_NOTES.md>

## Needs human decision
<only if there's an ambiguous product/architecture call blocking progress; else "none">
```

After writing it: confirm the working tree is committed or cleanly stashed (so the next agent starts
from a known state), update `state/PROGRESS.md` with a one-line marker, and tell the human it's safe to
`/clear` (or start a fresh session) and resume — the SessionStart hook will surface this handoff.
