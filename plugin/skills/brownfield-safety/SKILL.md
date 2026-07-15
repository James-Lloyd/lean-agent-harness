---
name: brownfield-safety
description: Discipline for changing an existing codebase without breaking it. Use whenever working in a brownfield project (config.project.type = brownfield) — establishing a baseline, adding characterization tests, isolating work, and keeping scope small.
---

# brownfield-safety

An existing codebase is a working system with users and assumptions. The harness's job is to improve it
**without regressions**. This is a different discipline from greenfield: you respect first, change
second. (On existing code the loop is **supervised by default**; full-auto requires explicit opt-in at
the loop's warning prompt — and even opted-in, stay small.)

## The rules

### 1. Never work against an unknown baseline
Before any change, the discovered gate must be green (or its red parts explicitly catalogued as
pre-existing). See `project.baseline`. If you don't know the code was green before you touched it, you
can't prove you didn't break it. Establish the baseline (via `/onboard`) first.

### 2. Characterize before you change
For existing behaviour that lacks a test and you're about to modify, **first write a test that captures
what it does today** (a "characterization test") — even if today's behaviour is weird. Then change the
code. If the characterization test goes red unexpectedly, you've found a regression you'd otherwise ship.
This is the legacy-code safety net: lock current behaviour, then move.

### 3. Search and respect, don't reinvent
The codebase has conventions, helpers, and patterns. Find and reuse them (`docs/principles/golden-
principles.md` captures the ones `/onboard` found). Match the surrounding style so your change is
invisible as "the new code". Don't introduce a second way to do something that already has a way.

### 4. Isolate the work
Do brownfield work on a **branch** (or a git worktree), never directly on the trunk everyone relies on.
Small, reviewable diffs. Keep the blast radius of any one task tight.

### 5. Keep scope small; no broad sweeps
One narrow task per iteration. Resist "while I'm here" refactors — log them to `docs/technical-debt/`
instead. Broad automated sweeps on an existing codebase are how you get subtle, wide regressions.

### 6. Treat existing tests and specs as law
Don't weaken or delete existing tests to make your change pass — a failing existing test usually means
your change is wrong, not the test. Existing documented behaviour is a contract; change it deliberately
and with the human, not as a side effect.

## How this changes the loop
- **Autonomy** defaults to `supervised`. Full-auto on brownfield warns and needs explicit opt-in.
- **Validate phase** = the change's gate **plus** the baseline still green (no regressions elsewhere).
- **Done** requires: characterization/regression tests present, the diff isolated, and a fresh-context
  review confirming no existing behaviour changed unintentionally.
