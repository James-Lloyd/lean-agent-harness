# docs/design-docs

Decisions already made, and **why**. This is the project's memory of *settled* questions so agents
(and you) don't relitigate them every session. Lightweight ADR-style entries.

One file per decision, named `NNN-<slug>.md`:

```markdown
# NNN — <decision title>
- Status: accepted | superseded by NNN | proposed
- Date: YYYY-MM-DD

## Context
<the forces and constraints that made a decision necessary>

## Decision
<what we chose>

## Why (and what we rejected)
<the reasoning; the alternatives and why not — this is the valuable part>

## Consequences
<what this makes easy, what it makes hard, what to revisit later>
```

When a decision is overturned, mark the old one `superseded` and link forward — don't delete the
history.
