---
name: sprint-contract
description: Negotiate an explicit definition of done before any code is written for a chunk of work. Use for non-trivial tasks where "done" is ambiguous, so the builder and the judge agree up front.
---

# sprint-contract

Before building a non-trivial chunk of work, the generator and the evaluator (or the human) agree on
what "done" means — *in writing, before any code*. This prevents the most common failure: the builder
declaring victory against criteria it invented after the fact.

## Produce a contract
Write it into the relevant `specs/` file (or `docs/execution-plans/`) as a short, checkable block:

```markdown
## Sprint contract: <chunk name>

### Scope (this sprint)
- <what IS included>

### Out of scope
- <what is explicitly NOT included — prevents scope creep>

### Definition of done (every box must be ticked)
- [ ] <executable acceptance criterion 1 — measurable, e.g. "POST /x returns 201 + Location header">
- [ ] <criterion 2>
- [ ] Verified end-to-end with evidence: <how — screenshot / request / run / log>
- [ ] Gate green: format · lint · typecheck · tests
- [ ] No tests weakened; no specs edited

### How success is verified
<the exact commands / steps a skeptic would run to confirm each criterion>
```

## Rules
- **Criteria must be falsifiable and, where possible, executable.** "Looks good" is not a criterion;
  "p95 latency < 200ms over 100 requests" is.
- **Agree before coding.** If using the evaluator, have it review and accept the contract first; if
  solo, get the human's 👍. Only then start implementation.
- **The contract is the bar.** At review time, work is judged against *this* list — nothing added, and
  nothing quietly dropped. Changing the contract mid-sprint requires the same agreement that set it.
