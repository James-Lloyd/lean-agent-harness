# docs/execution-plans

Versioned plans for larger, multi-sprint pieces of work, with a progress log. This is the long-form
companion to `state/fix_plan.md` (which is the short, live task stack). Use it when a piece of work is
big enough that *how* you'll sequence it is itself worth recording.

One file per initiative, `NNN-<slug>.md`:

```markdown
# NNN — <initiative>
- Status: active | done | paused
- Spec: ../../specs/NNN-<slug>.md

## Approach
<the staged plan; sprints in order, each with a definition of done / sprint contract>

## Progress log
- YYYY-MM-DD: <what shipped, with the commit/evidence>
```

Keep the log append-only. When the initiative is done, mark it and leave it as a record.
