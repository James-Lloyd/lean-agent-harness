---
description: Run the full verification gate + capture real end-to-end evidence for the current change.
argument-hint: (optional) "<what behavior to prove>"
allowed-tools: Read, Bash, Glob, Grep, Skill, Agent
context: fork
---

<!-- context: fork — the gate's command output (install logs, test noise) stays out of the main
     conversation; only the evidence report below returns. Evidence files persist on disk either way. -->

# /verify — prove it actually works

Behavior to prove: $ARGUMENTS

Unit-green is not done. This command runs the full deterministic gate **and** produces user-level
evidence — the kind of proof a skeptical human would accept.

## Procedure
1. **Run the full gate** for each affected **component** (its commands, in its own directory) **and**
   the cross-cutting root `gate` from `harness/harness.config.json`, in order:
   `format → lint → typecheck → build → test → e2e`. Report each. Stop and surface details on the
   first failure (with the fix), but try to report all failing steps if cheap to do so.
2. **Capture end-to-end evidence** appropriate to the stack — invoke the **`e2e-evidence` skill**, which
   is the single source for what counts as evidence per surface (Web/UI, API, CLI, library, data/job,
   and the "no automatable surface" fallback). Don't re-derive the list here; follow the skill.
3. **Compare against acceptance criteria** in the relevant `specs/`. Tick only what the evidence
   actually demonstrates — not what "should" work.

## Output
A short evidence report: gate results (pass/fail per step), the captured evidence (path to
screenshot/log/output), and a clear verdict on whether each acceptance criterion is *demonstrably*
met. Save artifacts under `state/evidence/<task-id>/` so the review and the human can see them.
