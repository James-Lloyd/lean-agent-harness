# Evaluator rubric

The scoring sheet the `evaluator` subagent uses to judge a completed sprint. Each criterion is scored
**0–10** with a one-line justification. The **hard threshold** is `verification.evaluator.failBelow`
in `harness/harness.config.json` (default 7): if *any* applicable criterion scores below it, the sprint
**fails** and the generator gets the per-criterion feedback. There is no averaging away a real defect.

> Calibrate over time. When the evaluator's judgment diverges from yours, add a few-shot example here
> (a short "this scored N because…") so scores stay consistent across runs. The rubric is itself
> ratcheted.

## Criteria

### 1. Correctness (always applies)
Meets the spec's acceptance criteria; edge cases and error paths handled. **Below threshold if** any
acceptance criterion is unmet or any obvious edge case breaks.

### 2. Evidence (always applies)
Real end-to-end evidence exists and demonstrates the actual changed behavior — not just passing unit
tests. **Below threshold if** the only proof is unit tests, or evidence doesn't match the criteria.

### 3. Guardrails (always applies — a breach caps the whole sprint)
No tests weakened/deleted, no `specs/` edited, no destructive ops, no secrets touched. **Any breach =
automatic sprint fail**, regardless of other scores.

### 4. Robustness
Sensible failure modes; inputs validated; no obvious race/leak/timeout. **Below threshold if** it works
only on the happy path.

### 5. Fit & drift
Respects `docs/architecture/` and the golden principles; no dead code or duplicated helpers; reuses
existing utilities. **Below threshold if** it introduces architectural drift or obvious duplication.

### 6. Craft (apply when the output is user-visible)
Coherent whole, not a collection of parts; no generic "AI slop"/template defaults; typography, spacing,
copy, and primary actions are considered. **Below threshold if** it reads as un-finished or generic.

## Output format the evaluator must produce
This format is **load-bearing** when `verification.evaluator.enabled` gates the unattended loop: the loop
parses the final `VERDICT: PASS|FAIL` line **and** the per-criterion `N/10` scores — any score below
`failBelow` stops the loop like a REJECT, even if the summary line said PASS. Keep the scores as `N/10`.
```
VERDICT: PASS | FAIL
1. Correctness   8/10 — <why>
2. Evidence      9/10 — <why>
3. Guardrails    PASS  — <none breached>
4. Robustness    7/10 — <why>
5. Fit & drift   8/10 — <why>
6. Craft         n/a   — <not user-visible>
FIX LIST (if FAIL): <file:line — problem — concrete fix>, ...
```
