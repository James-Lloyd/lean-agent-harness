# docs/technical-debt

A registry of known issues — so the agent checks here before "discovering" a problem, and so debt is
**tracked, not lost**. `/gc` and the `doc-gardener` add to this when they find drift they shouldn't fix
in the moment. Pay it down in small, continuous installments rather than periodic purges.

One entry per item (a single file `register.md` is fine, or `NNN-<slug>.md` for big ones):

```markdown
- [ ] <issue> — impact: <low/med/high> — where: <file/area> — noted: YYYY-MM-DD
      why deferred: <reason> — fix sketch: <how, roughly>
```

Tick items as `/gc` or normal work clears them. If an item recurs, consider a `/ratchet` rule or a
sensor so it can't come back.
